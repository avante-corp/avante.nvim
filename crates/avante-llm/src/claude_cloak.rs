//! Bridge the subscription plugin's public handler and auth command to Avante.
use super::{Event, Events, HeadersMiddleware, ProviderInput, push, run_until_cancelled};
use rig::serve::ErasedHandler;
use rig_harness::prelude::*;
use std::os::unix::fs::DirBuilderExt;
use std::sync::Arc;
use tokio::sync::watch;

fn app(home: &str) -> Result<App, String> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(home)
        .map_err(|_| "Claude credential directory is unavailable".to_owned())?;
    let mut app = App::new();
    // Isolate Cloak credentials from the user's default Rig home.
    app.insert_resource(RigHome(Home::at(home)))
        .add_plugins(rig_claude_cloak::ClaudeCloakPlugin);
    Ok(app)
}

pub(super) fn connect(provider: &ProviderInput, events: &Events) -> Result<ErasedHandler, String> {
    let mut app = app(provider.auth_home.as_deref().ok_or("missing Cloak home")?)?;
    let events = Arc::clone(events);
    let mut models = app.world_mut().resource_mut::<Models>();
    models.0.wrap_http(move |http| {
        http.with_middleware(HeadersMiddleware {
            request_headers: http::HeaderMap::new(),
            replace_headers: false,
            events: Arc::clone(&events),
        })
    });
    models
        .0
        .connect(&format!("claude-cloak/{}", provider.model))
        .map(|(_, handler)| handler)
        .map_err(|error| format!("Claude Pro/Max: {error}. Sign in with :Avante claude login"))
}

pub(super) async fn authenticate(
    action: String,
    home: String,
    events: Events,
    mut cancelled: watch::Receiver<bool>,
) {
    if *cancelled.borrow() {
        push(&events, Event::Cancelled);
        return;
    }
    let work = async {
        let mut app = app(&home)?;
        app.insert_resource(TokioRuntime(tokio::runtime::Handle::current()))
            .add_plugins(rig_harness::rig_ecs::AgentPlugin);
        app.update();
        let agent = app.world_mut().spawn_empty().id();
        app.world_mut()
            .trigger(RunCommand::new(agent, format!("claude-cloak {action}")));
        loop {
            app.update();
            for notice in app.world_mut().resource_mut::<Messages<Notice>>().drain() {
                if notice.level == NoticeLevel::Error {
                    return Err(notice.text);
                }
                // The plugin's public command reports completion through notices.
                if notice.text.starts_with("Anthropic OAuth signed ") {
                    return Ok(format!(
                        "Claude Pro/Max signed {}.",
                        if action == "login" { "in" } else { "out" }
                    ));
                }
                push(
                    &events,
                    Event::AuthStatus {
                        message: notice.text,
                        complete: false,
                    },
                );
            }
            if let Some(refusal) = app
                .world_mut()
                .resource_mut::<Messages<Recalled>>()
                .drain()
                .next()
            {
                return Err(refusal
                    .why
                    .unwrap_or_else(|| "Claude authentication failed".to_owned()));
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    };
    match run_until_cancelled(&mut cancelled, work).await {
        None => push(&events, Event::Cancelled),
        Some(Ok(message)) => push(
            &events,
            Event::AuthStatus {
                message,
                complete: true,
            },
        ),
        Some(Err(message)) => push(
            &events,
            Event::Error {
                message,
                status: None,
                retry_after: None,
            },
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PendingEvent;
    use std::os::unix::fs::PermissionsExt;

    fn home() -> String {
        std::env::temp_dir()
            .join(format!(
                "avante-cloak-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ))
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn subscription_rejects_transport_and_credential_overrides() {
        let mut provider = crate::tests::provider("anthropic", None);
        provider.api_key = None;
        provider.auth = Some(crate::AuthInput::Subscription);
        provider.auth_home = Some(home());
        let input = crate::Input {
            provider,
            prompt: crate::tests::prompt(),
        };
        input.validate().unwrap();
        let invalid: &[fn(&mut ProviderInput)] = &[
            |p| p.protocol = crate::ProtocolInput::Openai,
            |p| p.auth_home = None,
            |p| p.base_url = Some("https://example.com".into()),
            |p| p.api_key = Some("token".into()),
            |p| {
                p.headers.insert("authorization".into(), "token".into());
            },
            |p| p.replace_headers = true,
            |p| p.proxy = Some("http://localhost:8080".into()),
            |p| p.allow_insecure = true,
        ];
        for change in invalid {
            let mut input = input.clone();
            change(&mut input.provider);
            assert!(input.validate().is_err(), "{:?}", input.provider);
        }
    }

    #[tokio::test]
    async fn cancelled_auth_does_not_create_credentials_or_open_a_browser() {
        let home = home();
        let events = Events::default();
        let (_cancel, cancelled) = watch::channel(true);
        authenticate("login".into(), home.clone(), Arc::clone(&events), cancelled).await;
        assert!(matches!(
            &events.lock().unwrap()[0],
            PendingEvent::Event(Event::Cancelled)
        ));
        assert!(!std::path::Path::new(&home).exists());
    }

    #[tokio::test]
    async fn public_logout_command_finishes_without_an_account() {
        let home = home();
        let events = Events::default();
        let (_cancel, cancelled) = watch::channel(false);
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            authenticate(
                "logout".to_owned(),
                home.clone(),
                Arc::clone(&events),
                cancelled,
            ),
        )
        .await
        .expect("auth command timed out");
        let events = events.lock().unwrap();
        assert!(
            events.iter().any(|event| matches!(
                event,
                PendingEvent::Event(Event::AuthStatus { complete: true, .. })
            )),
            "{events:?}"
        );
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, PendingEvent::Event(Event::Error { .. }))),
            "{events:?}"
        );
        assert_eq!(
            std::fs::metadata(&home).unwrap().permissions().mode() & 0o077,
            0
        );
        std::fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn subscription_handler_reports_missing_credentials_without_inference() {
        let home = home();
        let mut provider = crate::tests::provider("anthropic", None);
        provider.model = "claude-opus-4-8".to_owned();
        provider.api_key = None;
        provider.auth = Some(crate::AuthInput::Subscription);
        provider.auth_home = Some(home.clone());
        let input = crate::Input {
            provider,
            prompt: crate::tests::prompt(),
        };
        input.validate().unwrap();
        let events = Events::default();
        let (_cancel, cancelled) = watch::channel(false);
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            crate::run(input, Arc::clone(&events), cancelled),
        )
        .await
        .expect("missing credentials must fail before network I/O");
        let events = events.lock().unwrap();
        assert!(
            events.iter().any(|event| matches!(
                event,
                PendingEvent::Event(Event::Error { message, .. })
                    if message.contains("not logged in") && message.contains(":Avante claude login")
            )),
            "{events:?}"
        );
        std::fs::remove_dir_all(home).unwrap();
    }
}
