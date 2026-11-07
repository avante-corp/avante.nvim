//! `ChatGPT` subscription login and inference through Rig's native OAuth provider.
use super::{Event, Events, ProviderInput, push, run_until_cancelled};
use rig::driver::DynModel;
use rig::operation::Completion;
use rig::providers::chatgpt::{
    DIALECT,
    auth::{
        AuthContext, AuthSource, Authenticator, DeviceCodeHandler, FileTokenStore, SignInMethod,
        SignInPrompt, SignedOut,
    },
};
use rig::providers::openai::OpenAIConfig;
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::watch;

fn authenticator(home: &str, events: &Events) -> Authenticator {
    static AUTHENTICATORS: LazyLock<Mutex<HashMap<String, Authenticator>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));
    // Keep Rig's credential cache across turns without retaining request event handlers.
    let auth = AUTHENTICATORS
        .lock()
        .expect("ChatGPT authenticator lock")
        .entry(home.to_owned())
        .or_insert_with(|| {
            Authenticator::new(
                AuthSource::OAuth,
                FileTokenStore::new(home),
                DeviceCodeHandler::new(|_| {}),
                false, // Inference must never start an interactive sign-in.
            )
        })
        .clone();
    let events = Arc::clone(events);
    auth.with_device_code_handler(DeviceCodeHandler::new(move |prompt| {
        push(
            &events,
            Event::AuthStatus {
                message: format!(
                    "ChatGPT: open {} and enter {}",
                    prompt.verification_uri, prompt.user_code
                ),
                complete: false,
            },
        );
    }))
}

fn config(context: AuthContext) -> OpenAIConfig {
    // Keep credentials on the dialect's fixed endpoint, regardless of OAuth metadata.
    let mut config = OpenAIConfig::with_key(&DIALECT, context.api_key);
    if let Some(account) = context.account_id {
        config = config.with_account_id(account);
    }
    config
}

pub(super) async fn connect(
    provider: &ProviderInput,
    events: &Events,
    http: rig::http_client::DynHttpClient,
) -> Result<DynModel<Completion>, String> {
    let auth = authenticator(
        provider
            .auth_home
            .as_deref()
            .ok_or("missing ChatGPT credential directory")?,
        events,
    );
    let context = auth
        .auth_context(&http)
        .await
        .map_err(|error| format!("ChatGPT authentication: {error}. Run :Avante chatgpt login"))?;
    Ok(config(context)
        .connect(http)
        .completion(&provider.model)
        .erase())
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
        let client = rig_reqwest::reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(30))
            .read_timeout(Duration::from_secs(120))
            .build()
            .map_err(|error| error.to_string())?;
        let http = rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(client));
        let auth = authenticator(&home, &events);
        if action == "login" {
            auth.sign_in(&http, SignInMethod::detect(false), |prompt| {
                let message = match prompt {
                    SignInPrompt::Browser(page) => {
                        format!("ChatGPT: sign in at {}", page.authorize_url)
                    }
                    SignInPrompt::BrowserUnavailable(_) => {
                        "ChatGPT browser callback is unavailable; using a device code.".to_owned()
                    }
                };
                push(
                    &events,
                    Event::AuthStatus {
                        message,
                        complete: false,
                    },
                );
            })
            .await
            .map_err(|error| error.to_string())?;
            Ok("ChatGPT signed in.".to_owned())
        } else {
            match auth.sign_out(&http).await.map_err(|error| error.to_string())? {
                SignedOut::Forgotten { revoked: Err(_) } => Ok(
                    "ChatGPT credentials removed locally; server revocation could not be confirmed.".to_owned(),
                ),
                _ => Ok("ChatGPT signed out.".to_owned()),
            }
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
    use crate::{AuthInput, Input, PendingEvent, ProtocolInput, RouteInput};
    use rig::providers::chatgpt::auth::TokenStore;
    use rig::wire::{Body, Mode, Wire};
    use serde_json::{Value, json};

    fn provider() -> ProviderInput {
        let mut provider = crate::tests::provider("openai", Some(RouteInput::Responses));
        provider.model = "gpt-6.1-sol".into();
        provider.api_key = None;
        provider.auth = Some(AuthInput::Chatgpt);
        provider.auth_home = Some(
            std::env::temp_dir()
                .join(format!(
                    "avante-chatgpt-{}-{}",
                    std::process::id(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                ))
                .to_string_lossy()
                .into_owned(),
        );
        provider
    }

    #[test]
    fn subscription_rejects_credential_leaks_and_wrong_protocols() {
        let provider = provider();
        let input = Input {
            provider,
            prompt: crate::tests::prompt(),
        };
        input.validate().unwrap();
        let invalid: &[fn(&mut ProviderInput)] = &[
            |p| p.protocol = ProtocolInput::Claude,
            |p| p.route = Some(RouteInput::Chat),
            |p| p.dialect = Some("openrouter".into()),
            |p| p.auth_home = None,
            |p| p.auth_home = Some(" ".into()),
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
        assert!(
            crate::request_headers(input)
                .unwrap_err()
                .contains("managed by Rig")
        );
    }

    #[test]
    fn subscription_wire_uses_codex_auth_and_replays_tool_history_without_server_state() {
        let context = AuthContext {
            api_key: "oauth-token".into(),
            account_id: Some("account-1".into()),
            api_base: Some("https://untrusted.example".into()),
        };
        let provider = provider();
        let mut prompt = crate::tests::prompt();
        prompt.messages.push(crate::AvanteMessage {
            role: "assistant".into(), phase: None, native: None, origin: None, is_dummy: false,
            content: json!({ "type": "tool_use", "id": "call-1", "name": "lookup", "input": { "query": "rust" } }),
        });
        prompt.messages.push(crate::AvanteMessage {
            role: "user".into(),
            phase: None,
            native: None,
            origin: None,
            is_dummy: false,
            content: json!({ "type": "tool_result", "tool_use_id": "call-1", "content": "found" }),
        });
        prompt.additional_params =
            Some(json!({ "previous_response_id": "resp-old", "conversation": "conv-old" }));
        let request = crate::completion_request(&provider, prompt).unwrap();
        let wire = rig::providers::openai::wire::OpenAiWire::new(config(context), &provider.model);
        let encoded = wire.encode(request, Mode::Streaming).unwrap();
        assert_eq!(
            encoded.request.uri(),
            "https://chatgpt.com/backend-api/codex/responses"
        );
        assert_eq!(
            encoded.request.headers()["authorization"],
            "Bearer oauth-token"
        );
        assert_eq!(encoded.request.headers()["chatgpt-account-id"], "account-1");
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("expected JSON body")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["store"], false);
        assert_eq!(body["stream"], true);
        assert!(
            body["instructions"]
                .as_str()
                .unwrap()
                .contains("You are concise.")
        );
        assert!(body.get("previous_response_id").is_none());
        assert!(body.get("conversation").is_none());
        let input = body["input"].as_array().unwrap();
        assert!(
            input
                .iter()
                .any(|item| item["type"] == "function_call" && item["call_id"] == "call-1"),
            "{body}"
        );
        assert!(
            input
                .iter()
                .any(|item| item["type"] == "function_call_output" && item["output"] == "found")
        );
    }

    #[tokio::test]
    async fn cancelled_login_does_not_open_a_browser_or_write_credentials() {
        let home = provider().auth_home.unwrap();
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
    async fn missing_credentials_require_explicit_login_without_a_prompt_or_request() {
        let provider = provider();
        let home = provider.auth_home.clone().unwrap();
        let events = Events::default();
        let captured = Arc::new(Mutex::new(None));
        let http = crate::build_http(&provider, &events)
            .unwrap()
            .with_middleware(crate::CaptureHeaders(Arc::clone(&captured)));
        let result = connect(&provider, &events, http).await;
        let Err(error) = result else {
            panic!("missing credentials must fail")
        };
        assert!(error.contains(":Avante chatgpt login"), "{error}");
        assert!(captured.lock().unwrap().is_none());
        assert!(events.lock().unwrap().is_empty());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn turns_reuse_rig_credentials_until_logout() {
        let provider = provider();
        let home = provider.auth_home.clone().unwrap();
        let store = FileTokenStore::new(&home);
        let events = Events::default();
        let http = crate::build_http(&provider, &events).unwrap();
        store
            .save(
                "chatgpt",
                &json!({ "access_token": "test-token", "expires_at": 4_000_000_000_i64 })
                    .to_string(),
            )
            .await
            .unwrap();
        connect(&provider, &events, http.clone()).await.unwrap();
        store.delete("chatgpt").await.unwrap();
        connect(&provider, &events, http.clone()).await.unwrap();
        let (_cancel, cancelled) = watch::channel(false);
        authenticate(
            "logout".into(),
            home.clone(),
            Arc::clone(&events),
            cancelled,
        )
        .await;
        assert!(events.lock().unwrap().iter().any(|event| matches!(
            event,
            PendingEvent::Event(Event::AuthStatus { complete: true, .. })
        )));
        let Err(error) = connect(&provider, &events, http).await else {
            panic!("logout must clear cached credentials")
        };
        assert!(error.contains(":Avante chatgpt login"), "{error}");
        std::fs::remove_dir_all(home).unwrap();
    }
}
