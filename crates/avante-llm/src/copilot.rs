//! Copilot device login, session exchange and inference through Rig.
use super::{Event, Events, ProviderInput, RouteInput, push, run_until_cancelled};
use rig::driver::DynModel;
use rig::http_client::{DynHttpClient, HttpClientExt};
use rig::operation::Completion;
use rig::providers::copilot::{
    DIALECT,
    auth::{AuthContext, AuthSource, Authenticator, DeviceCodeHandler, FileTokenStore, TokenStore},
    model_listing::Models,
};
use rig::providers::openai::{OpenAIConfig, Route};
use rig::wire::{Mode, Wire};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;

const BASE_URL: &str = "https://api.githubcopilot.com";

pub(super) fn validate(provider: &ProviderInput) -> Result<(), String> {
    if !matches!(provider.protocol, super::ProtocolInput::Copilot) {
        return Err("Copilot authentication requires the Copilot protocol".into());
    }
    if provider
        .auth_home
        .as_deref()
        .is_none_or(|home| home.trim().is_empty())
    {
        return Err("Copilot credential directory is missing".into());
    }
    if provider
        .base_url
        .as_deref()
        .is_some_and(|url| url.trim_end_matches('/') != BASE_URL)
        || provider.api_key.is_some()
        || !provider.headers.is_empty()
        || provider.replace_headers
        || provider.proxy.is_some()
        || provider.allow_insecure
    {
        return Err("Copilot OAuth uses Rig's GitHub endpoints and credentials; custom endpoints (including GHE), API keys, headers, proxy and insecure TLS settings are unsupported".into());
    }
    Ok(())
}

fn authenticator(home: &str, events: &Events, login: bool) -> Authenticator {
    let events = Arc::clone(events);
    Authenticator::new(
        AuthSource::OAuth,
        FileTokenStore::new(home),
        DeviceCodeHandler::new(move |prompt| {
            push(
                &events,
                Event::AuthStatus {
                    message: format!(
                        "Copilot: open {} and enter {}",
                        prompt.verification_uri, prompt.user_code
                    ),
                    complete: false,
                },
            );
        }),
        // Only the explicit login command may start device authorization.
        login,
    )
}

async fn context(
    home: &str,
    events: &Events,
    http: &DynHttpClient,
    login: bool,
) -> Result<AuthContext, String> {
    authenticator(home, events, login)
        .auth_context(http)
        .await
        .map_err(|error| {
            // GitHub's failed response body can contain credentials; keep it out of Lua notifications.
            let detail = match error {
                rig::providers::copilot::auth::AuthError::Http(error) => {
                    error.non_success_status().map_or_else(
                        || "HTTP transport failed".to_owned(),
                        |status| format!("HTTP {status}"),
                    )
                }
                error => error.to_string(),
            };
            format!("Copilot authentication: {detail}. Run :Avante copilot login")
        })
}

fn config(context: AuthContext, route: Option<RouteInput>) -> Result<OpenAIConfig, String> {
    let base = context.api_base.as_deref().unwrap_or(BASE_URL);
    let url =
        rig_reqwest::reqwest::Url::parse(base).map_err(|_| "Invalid Copilot session endpoint")?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url
            .host_str()
            .is_none_or(|host| !host.ends_with(".githubcopilot.com"))
        || url.port().is_some_and(|port| port != 443)
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("Copilot session endpoint must be an HTTPS githubcopilot.com service".into());
    }
    // The session selects the API host; validate it before attaching credentials.
    let mut config =
        OpenAIConfig::with_key(&DIALECT, context.api_key).with_base_url(base.trim_end_matches('/'));
    if let Some(route) = route {
        config = config.with_route(match route {
            RouteInput::Chat => Route::Chat,
            RouteInput::Responses => Route::Responses,
        });
    }
    Ok(config)
}

pub(super) async fn connect(
    provider: &ProviderInput,
    events: &Events,
    http: DynHttpClient,
) -> Result<DynModel<Completion>, String> {
    let home = provider
        .auth_home
        .as_deref()
        .ok_or("missing Copilot credential directory")?;
    let context = context(home, events, &http, false).await?;
    Ok(config(context, provider.route)?
        .connect(http)
        .completion(&provider.model)
        .erase())
}

fn client(timeout: Duration) -> Result<DynHttpClient, String> {
    let client = rig_reqwest::reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .read_timeout(timeout)
        .build()
        .map_err(|error| error.to_string())?;
    Ok(DynHttpClient::new(rig_reqwest::ReqwestClient::from(client)))
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
        if action == "login" {
            let http = client(Duration::from_secs(120))?;
            let context = context(&home, &events, &http, true).await?;
            config(context, None)?;
            Ok("Copilot signed in.".to_owned())
        } else {
            let store = FileTokenStore::new(home);
            let _held = store
                .lock("copilot")
                .await
                .map_err(|error| error.to_string())?;
            store
                .delete("copilot")
                .await
                .map_err(|error| error.to_string())?;
            Ok("Copilot credentials removed locally. Revoke GitHub authorization in your account settings if needed.".to_owned())
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

pub(super) async fn list_models(home: &str, timeout: u64) -> Result<Vec<Value>, String> {
    let http = client(Duration::from_millis(timeout))?;
    tokio::time::timeout(Duration::from_millis(timeout), models(home, &http))
        .await
        .map_err(|_| "Copilot model listing timed out".to_owned())?
}

async fn models(home: &str, http: &DynHttpClient) -> Result<Vec<Value>, String> {
    let context = context(home, &Events::default(), http, false).await?;
    let wire = Models::new(config(context, None)?);
    let encoded = wire
        .encode(None, Mode::Unary)
        .map_err(|error| error.to_string())?;
    // Rig's normalized listing omits policy and token limits used by Avante's picker.
    let response = http
        .send::<_, Vec<u8>>(encoded.request.map(|_| Vec::<u8>::new()))
        .await
        .map_err(|error| {
            error.non_success_status().map_or_else(
                || "Copilot model listing request failed".to_owned(),
                |status| format!("Copilot model listing: HTTP {status}"),
            )
        })?;
    let bytes = response
        .into_body()
        .await
        .map_err(|_| "Copilot model listing body could not be read")?;
    let body: Value =
        serde_json::from_slice(&bytes).map_err(|_| "Invalid Copilot model listing")?;
    model_entries(&body)
}

fn model_entries(body: &Value) -> Result<Vec<Value>, String> {
    let data = body
        .get("data")
        .and_then(Value::as_array)
        .ok_or("Invalid Copilot model listing")?;
    Ok(data.iter().filter_map(|model| {
        let id = model.get("id")?.as_str()?;
        if model.pointer("/capabilities/type")?.as_str()? != "chat" || id.ends_with("paygo") { return None; }
        let name = model.get("name").and_then(Value::as_str).unwrap_or(id);
        let mut entry = json!({
            "id": id, "display_name": name, "name": format!("copilot/{name} ({id})"), "provider_name": "copilot",
            "tokenizer": model.pointer("/capabilities/tokenizer"),
            "max_input_tokens": model.pointer("/capabilities/limits/max_prompt_tokens"),
            "max_output_tokens": model.pointer("/capabilities/limits/max_output_tokens"),
            "policy": model.get("policy").is_none_or(|policy| policy.get("state").and_then(Value::as_str) == Some("enabled")),
            "version": model.get("version").and_then(Value::as_str).unwrap_or(""),
        });
        entry.as_object_mut().unwrap().retain(|_, value| !value.is_null());
        Some(entry)
    }).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthInput, Input, PendingEvent, ProtocolInput};
    use futures::StreamExt;
    use rig::http_client::{Bytes, LazyBody, MultipartForm, Request, Response, StreamingResponse};
    use std::collections::VecDeque;
    use std::future::Future;
    use std::sync::Mutex;

    #[derive(Clone)]
    struct CapturedRequest {
        uri: String,
        headers: http::HeaderMap,
    }

    type TestResponse = Result<String, (http::StatusCode, String)>;

    #[derive(Clone, Default)]
    struct TestHttp {
        requests: Arc<Mutex<Vec<CapturedRequest>>>,
        responses: Arc<Mutex<VecDeque<TestResponse>>>,
    }

    impl TestHttp {
        fn new(responses: impl IntoIterator<Item = TestResponse>) -> Self {
            Self {
                responses: Arc::new(Mutex::new(responses.into_iter().collect())),
                ..Self::default()
            }
        }
    }

    impl HttpClientExt for TestHttp {
        fn send<T, U>(
            &self,
            request: Request<T>,
        ) -> impl Future<Output = rig::http_client::Result<Response<LazyBody<U>>>> + Send + 'static
        where
            T: Into<Bytes> + Send,
            U: From<Bytes> + Send + 'static,
        {
            let (parts, _) = request.into_parts();
            self.requests.lock().unwrap().push(CapturedRequest {
                uri: parts.uri.to_string(),
                headers: parts.headers,
            });
            let response = self
                .responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected HTTP request");
            async move {
                match response {
                    Ok(body) => {
                        let body: LazyBody<U> =
                            Box::pin(async move { Ok(U::from(Bytes::from(body))) });
                        Ok(Response::new(body))
                    }
                    Err((status, body)) => Err(rig::http_client::Error::non_success_with_details(
                        status,
                        http::HeaderMap::new(),
                        body,
                    )),
                }
            }
        }
        fn send_multipart<U>(
            &self,
            _: Request<MultipartForm>,
        ) -> impl Future<Output = rig::http_client::Result<Response<LazyBody<U>>>> + Send + 'static
        where
            U: From<Bytes> + Send + 'static,
        {
            std::future::ready(Err(rig::http_client::Error::StreamEnded))
        }
        fn send_streaming<T>(
            &self,
            _: Request<T>,
        ) -> impl Future<Output = rig::http_client::Result<StreamingResponse>> + Send
        where
            T: Into<Bytes> + Send,
        {
            std::future::ready(Err(rig::http_client::Error::StreamEnded))
        }
    }
    use rig::wire::Body;

    fn provider() -> ProviderInput {
        let mut provider = crate::tests::provider("copilot", Some(RouteInput::Responses));
        provider.protocol = ProtocolInput::Copilot;
        provider.auth = Some(AuthInput::Copilot);
        provider.api_key = None;
        provider.model = "gpt-6-luna".into();
        provider.auth_home = Some(
            std::env::temp_dir()
                .join(format!(
                    "avante-copilot-{}-{}",
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

    fn session(token: &str) -> String {
        json!({"token": token, "expires_at": 4_000_000_000_i64,
            "endpoints": {"api": "https://api.individual.githubcopilot.com"}})
        .to_string()
    }

    #[test]
    fn validates_subscription_settings_and_session_destinations() {
        let input = Input {
            provider: provider(),
            prompt: crate::tests::prompt(),
        };
        input.validate().unwrap();
        let invalid: &[fn(&mut ProviderInput)] = &[
            |p| p.protocol = ProtocolInput::Openai,
            |p| p.auth_home = None,
            |p| p.auth_home = Some(" ".into()),
            |p| p.base_url = Some("https://tenant.ghe.com".into()),
            |p| p.api_key = Some("secret".into()),
            |p| {
                p.headers.insert("authorization".into(), "secret".into());
            },
            |p| p.replace_headers = true,
            |p| p.proxy = Some("http://localhost:8080".into()),
            |p| p.allow_insecure = true,
        ];
        for change in invalid {
            let mut input = input.clone();
            change(&mut input.provider);
            assert!(input.validate().is_err());
        }
        assert!(
            crate::request_headers(input)
                .unwrap_err()
                .contains("managed by Rig")
        );
        for base in [
            "http://api.githubcopilot.com",
            "https://githubcopilot.com.evil.test",
            "https://api.githubcopilot.com@evil.test",
            "https://secret@api.githubcopilot.com",
            "https://api.githubcopilot.com/path",
            "https://api.githubcopilot.com:8443",
            "https://api.githubcopilot.com?token=secret",
            "https://api.githubcopilot.com/#secret",
        ] {
            assert!(
                config(
                    AuthContext {
                        api_key: "secret".into(),
                        api_base: Some(base.into()),
                        account_id: None
                    },
                    None
                )
                .is_err(),
                "{base}"
            );
        }
    }

    #[tokio::test]
    async fn device_login_refreshes_and_uses_private_credentials_without_exposing_them_to_lua() {
        let provider = provider();
        let home = provider.auth_home.as_deref().unwrap();
        let events = Events::default();
        let fake = TestHttp::new([
            Ok(
                r#"{"device_code":"device-secret","user_code":"ABCD","verification_uri":"https://github.com/login/device"}"#.to_owned(),
            ),
            Ok(r#"{"access_token":"github-secret"}"#.to_owned()),
            Ok(session("first-session")),
            Ok(session("refreshed-session")),
        ]);
        let http = DynHttpClient::new(fake.clone());
        let signed_in = context(home, &events, &http, true).await.unwrap();
        let store = FileTokenStore::new(home);
        let mut record: Value =
            serde_json::from_str(&store.load("copilot").await.unwrap().unwrap()).unwrap();
        assert_eq!(record["github_token"], "github-secret");
        assert_eq!(record["token"], "first-session");
        record["expires_at"] = json!(1);
        store.save("copilot", &record.to_string()).await.unwrap();
        let refreshed = context(home, &events, &http, false).await.unwrap();
        assert_eq!(signed_in.api_key.expose(), "first-session");
        assert_eq!(refreshed.api_key.expose(), "refreshed-session");
        let requests = fake.requests.lock().unwrap().clone();
        assert_eq!(requests.len(), 4);
        assert_eq!(requests[0].uri, "https://github.com/login/device/code");
        assert_eq!(
            requests[1].uri,
            "https://github.com/login/oauth/access_token"
        );
        assert_eq!(
            requests[3].uri,
            "https://api.github.com/copilot_internal/v2/token"
        );
        assert_eq!(requests[3].headers["authorization"], "token github-secret");
        for route in [RouteInput::Chat, RouteInput::Responses] {
            let wire = rig::providers::openai::wire::OpenAiWire::new(
                config(refreshed.clone(), Some(route)).unwrap(),
                &provider.model,
            );
            let encoded = wire
                .encode(
                    crate::completion_request(&provider, crate::tests::prompt()).unwrap(),
                    Mode::Streaming,
                )
                .unwrap();
            assert_eq!(
                encoded.request.uri().host(),
                Some("api.individual.githubcopilot.com")
            );
            assert_eq!(
                encoded.request.uri().path(),
                if matches!(route, RouteInput::Chat) {
                    "/chat/completions"
                } else {
                    "/responses"
                }
            );
            assert_eq!(
                encoded.request.headers()["authorization"],
                "Bearer refreshed-session"
            );
            assert!(encoded.request.headers().contains_key("editor-version"));
            let Body::Bytes(body) = encoded.request.into_body() else {
                panic!("expected JSON");
            };
            assert!(
                serde_json::from_slice::<Value>(&body)
                    .unwrap()
                    .get("model")
                    .is_some()
            );
        }
        let captured = Arc::new(std::sync::Mutex::new(None));
        let http = DynHttpClient::new(TestHttp::default())
            .with_middleware(crate::CaptureHeaders(Arc::clone(&captured)));
        let model = connect(&provider, &events, http).await.unwrap();
        let mut stream = model
            .stream(crate::completion_request(&provider, crate::tests::prompt()).unwrap())
            .unwrap();
        let _ = stream.next().await;
        assert_eq!(
            captured.lock().unwrap().as_ref().unwrap()["authorization"],
            "Bearer refreshed-session"
        );
        let events_json = format!("{:?}", events.lock().unwrap());
        assert!(events_json.contains("ABCD"));
        for secret in [
            "github-secret",
            "first-session",
            "refreshed-session",
            "device-secret",
        ] {
            assert!(!events_json.contains(secret));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(store.path("copilot"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o077,
                0
            );
            assert_eq!(
                std::fs::metadata(home).unwrap().permissions().mode() & 0o077,
                0
            );
        }
        let (_cancel, cancelled) = watch::channel(false);
        authenticate("logout".into(), home.into(), Arc::clone(&events), cancelled).await;
        assert!(store.load("copilot").await.unwrap().is_none());
        assert!(events.lock().unwrap().iter().any(|event| matches!(
            event,
            PendingEvent::Event(Event::AuthStatus { complete: true, .. })
        )));
        std::fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn missing_credentials_never_start_device_login_during_inference() {
        let provider = provider();
        let fake = TestHttp::default();
        let events = Events::default();
        let result = connect(&provider, &events, DynHttpClient::new(fake.clone())).await;
        let Err(error) = result else {
            panic!("expected login requirement");
        };
        assert!(error.contains(":Avante copilot login"));
        assert!(fake.requests.lock().unwrap().is_empty());
        assert!(events.lock().unwrap().is_empty());
        std::fs::remove_dir_all(provider.auth_home.unwrap()).unwrap();
    }

    #[tokio::test]
    async fn authentication_http_errors_do_not_expose_response_bodies() {
        let provider = provider();
        let fake = TestHttp::new([Err((
            http::StatusCode::UNAUTHORIZED,
            "private-github-token".into(),
        ))]);
        let error = context(
            provider.auth_home.as_deref().unwrap(),
            &Events::default(),
            &DynHttpClient::new(fake),
            true,
        )
        .await
        .unwrap_err();
        assert!(error.contains("401"));
        assert!(!error.contains("private-github-token"));
        std::fs::remove_dir_all(provider.auth_home.unwrap()).unwrap();
    }

    #[tokio::test]
    async fn model_listing_http_errors_preserve_status_without_exposing_response_bodies() {
        let home = provider().auth_home.unwrap();
        FileTokenStore::new(&home)
            .save("copilot", &session("session-secret"))
            .await
            .unwrap();
        for status in [
            http::StatusCode::UNAUTHORIZED,
            http::StatusCode::FORBIDDEN,
            http::StatusCode::TOO_MANY_REQUESTS,
        ] {
            let fake = TestHttp::new([Err((status, "private-response-body".into()))]);
            let error = models(&home, &DynHttpClient::new(fake)).await.unwrap_err();
            assert!(error.contains(&status.as_u16().to_string()), "{error}");
            assert!(!error.contains("private-response-body"));
        }
        std::fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn cancelled_login_does_not_touch_credentials_or_start_authorization() {
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
    async fn account_model_listing_preserves_policy_and_limits_and_refreshes_auth() {
        let home = provider().auth_home.unwrap();
        let store = FileTokenStore::new(&home);
        store
            .save(
                "copilot",
                r#"{"github_token":"github-secret","expires_at":1}"#,
            )
            .await
            .unwrap();
        let body = json!({ "data": [
            {"id":"chat", "name":"Chat", "version":"1", "capabilities":{"type":"chat", "tokenizer":"o200k_base", "limits":{"max_prompt_tokens":128_000,"max_output_tokens":16_000}}, "policy":{"state":"disabled"}},
            {"id":"allowed", "capabilities":{"type":"chat"}},
            {"id":"chat-paygo", "capabilities":{"type":"chat"}},
            {"id":"embedding", "capabilities":{"type":"embeddings"}}
        ]});
        let fake = TestHttp::new([Ok(session("session-secret")), Ok(body.to_string())]);
        let models = models(&home, &DynHttpClient::new(fake.clone()))
            .await
            .unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["policy"], false);
        assert_eq!(models[0]["max_input_tokens"], 128_000);
        assert_eq!(models[0]["max_output_tokens"], 16_000);
        assert_eq!(models[0]["tokenizer"], "o200k_base");
        assert_eq!(models[1]["policy"], true);
        assert!(models[1].get("tokenizer").is_none());
        assert_eq!(
            fake.requests.lock().unwrap()[1].uri,
            "https://api.individual.githubcopilot.com/models"
        );
        assert_eq!(
            fake.requests.lock().unwrap()[1].headers["authorization"],
            "Bearer session-secret"
        );
        assert!(
            fake.requests.lock().unwrap()[1]
                .headers
                .contains_key("editor-version")
        );
        assert!(model_entries(&json!({"error":"invalid"})).is_err());
        std::fs::remove_dir_all(home).unwrap();
    }
}
