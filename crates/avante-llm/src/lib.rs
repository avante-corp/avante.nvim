mod rig_compat;

use rig_compat::{StreamingVertex, build_http_model, configure_openai};

use base64::Engine;
use futures::{FutureExt, StreamExt};
use mlua::prelude::*;
use mlua::{LuaSerdeExt, UserData, UserDataMethods};
use rig::Model;
use rig::completion::{
    AssistantContent, AssistantMessage, CompletionRequest, Message, ToolDefinition,
};
use rig::driver::DynModel;
use rig::http_client::middleware::HttpMiddleware;
use rig::message::{
    CallId, ImageMediaType, MimeType, Native, Origin, Reasoning as MessageReasoning, StopReason,
    ToolName, ToolResult, ToolResultContent, UserContent,
};
use rig::operation::Completion;
use rig::providers::openai::wire::{AZURE, by_name};
use rig::streaming::{Item, PartKind, StreamEvent, parse_partial_arguments};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::any::Any;
use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;

// Bump this whenever a breaking native bridge change is introduced.
const NATIVE_API_VERSION: u32 = 2;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    provider: ProviderInput,
    prompt: PromptInput,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderInput {
    name: String,
    dialect: Option<String>,
    protocol: ProtocolInput,
    model: String,
    deployment: Option<String>,
    base_url: Option<String>,
    api_key: Option<String>,
    auth: Option<AuthInput>,
    route: Option<RouteInput>,
    api_version: Option<String>,
    #[serde(default)]
    prompt_caching: bool,
    #[serde(default)]
    headers: BTreeMap<String, String>,
    #[serde(default)]
    replace_headers: bool,
    proxy: Option<String>,
    #[serde(default)]
    allow_insecure: bool,
    bedrock: Option<BedrockInput>,
    vertex: Option<VertexInput>,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ProtocolInput {
    Openai,
    Claude,
    Azure,
    Gemini,
    Vertex,
    Cohere,
    Ollama,
    Bedrock,
    Copilot,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AuthInput {
    Bearer,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RouteInput {
    Chat,
    Responses,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BedrockInput {
    region: Option<String>,
    profile: Option<String>,
    endpoint: Option<String>,
    access_key_id: Option<String>,
    secret_access_key: Option<String>,
    session_token: Option<String>,
    bearer_token: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VertexInput {
    project_id: Option<String>,
    location: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PromptInput {
    turn_id: String,
    system_prompt: String,
    #[serde(default)]
    messages: Vec<AvanteMessage>,
    #[serde(default)]
    image_paths: Vec<String>,
    #[serde(default)]
    tools: Vec<ToolInput>,
    #[serde(default)]
    additional_params: Option<Value>,
}

#[derive(Clone, Debug, Deserialize)]
struct AvanteMessage {
    role: String,
    content: Value,
    phase: Option<String>,
    native: Option<String>,
    origin: Option<Origin>,
    #[serde(default)]
    is_dummy: bool,
}

#[derive(Serialize, Deserialize)]
struct NativeMetadata {
    #[serde(flatten)]
    native: Option<Native>,
    #[serde(skip_serializing_if = "Option::is_none")]
    call_id: Option<CallId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    turn_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    order: Option<usize>,
}

#[derive(Clone, Debug, Deserialize)]
struct ToolInput {
    name: String,
    #[serde(default)]
    description: String,
    parameters: Value,
}

impl Input {
    fn validate(&self) -> Result<(), String> {
        if self.provider.name.trim().is_empty() {
            return Err("provider name must not be empty".to_owned());
        }
        if self.provider.model.trim().is_empty() {
            return Err("model must not be empty".to_owned());
        }
        if matches!(self.provider.protocol, ProtocolInput::Azure)
            && self
                .provider
                .deployment
                .as_deref()
                .is_none_or(|value| value.trim().is_empty())
        {
            return Err("Azure deployment is not set".to_owned());
        }
        if self.prompt.system_prompt.trim().is_empty() {
            return Err("system prompt must not be empty".to_owned());
        }
        if let Some(dialect) = &self.provider.dialect {
            if !matches!(self.provider.protocol, ProtocolInput::Openai) {
                return Err(
                    "dialect is only supported by the OpenAI-compatible protocol".to_owned(),
                );
            }
            if by_name(dialect).is_none() {
                return Err(format!("unknown OpenAI-compatible dialect: {dialect}"));
            }
        }
        if matches!(self.provider.protocol, ProtocolInput::Bedrock) {
            let settings = self
                .provider
                .bedrock
                .as_ref()
                .ok_or_else(|| "Bedrock settings are missing".to_owned())?;
            if settings.access_key_id.is_some() != settings.secret_access_key.is_some() {
                return Err(
                    "Bedrock access key and secret key must be provided together".to_owned(),
                );
            }
            if settings.bearer_token.is_some() && settings.access_key_id.is_some() {
                return Err("Bedrock bearer and SigV4 credentials cannot be combined".to_owned());
            }
            if self.provider.allow_insecure {
                return Err(
                    "Bedrock does not support allow_insecure with the AWS SDK transport".to_owned(),
                );
            }
            if !self.provider.headers.is_empty() {
                return Err(
                    "Bedrock does not support extra headers with the AWS SDK transport".to_owned(),
                );
            }
        }
        if matches!(self.provider.protocol, ProtocolInput::Vertex) {
            if self.provider.base_url.is_some() {
                return Err(
                    "Vertex AI endpoint overrides are not exposed by Rig's SDK transport"
                        .to_owned(),
                );
            }
            if !self.provider.headers.is_empty() {
                return Err(
                    "Vertex AI extra headers are not exposed by Rig's SDK transport".to_owned(),
                );
            }
            if self.provider.proxy.is_some() || self.provider.allow_insecure {
                return Err(
                    "Vertex AI proxy and allow_insecure are not exposed by Rig's SDK transport"
                        .to_owned(),
                );
            }
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    ContentStart {
        index: usize,
        kind: ContentKind,
        name: Option<String>,
    },
    ContentDelta {
        index: usize,
        kind: ContentKind,
        text: String,
    },
    ToolCallDelta {
        index: usize,
        arguments: Value,
    },
    ContentEnd {
        index: usize,
        order: usize,
        content: Value,
        native: Option<String>,
    },
    Done {
        reason: DoneReason,
        usage: Box<Usage>,
        #[serde(rename = "responseId", skip_serializing_if = "Option::is_none")]
        response_id: Option<String>,
        origin: Origin,
    },
    ResponseHeaders {
        headers: BTreeMap<String, String>,
    },
    Error {
        message: String,
        status: Option<u16>,
        #[serde(rename = "retryAfter", skip_serializing_if = "Option::is_none")]
        retry_after: Option<u64>,
    },
    Cancelled,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ContentKind {
    Text,
    Reasoning,
    ToolCall,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum DoneReason {
    Complete,
    Length,
    ToolUse,
}

#[derive(Debug, Default, Serialize)]
struct Usage {
    #[serde(rename = "prompt_tokens", skip_serializing_if = "Option::is_none")]
    prompt: Option<u64>,
    #[serde(rename = "completion_tokens", skip_serializing_if = "Option::is_none")]
    completion: Option<u64>,
    #[serde(rename = "total_tokens", skip_serializing_if = "Option::is_none")]
    total: Option<u64>,
    #[serde(
        rename = "cached_input_tokens",
        skip_serializing_if = "Option::is_none"
    )]
    cached_input: Option<u64>,
    #[serde(
        rename = "cache_creation_input_tokens",
        skip_serializing_if = "Option::is_none"
    )]
    cache_creation_input: Option<u64>,
    #[serde(
        rename = "tool_use_prompt_tokens",
        skip_serializing_if = "Option::is_none"
    )]
    tool_use_prompt: Option<u64>,
    #[serde(rename = "reasoning_tokens", skip_serializing_if = "Option::is_none")]
    reasoning: Option<u64>,
}

impl From<rig::completion::Usage> for Usage {
    fn from(usage: rig::completion::Usage) -> Self {
        Self {
            prompt: usage.input_tokens,
            completion: usage.output_tokens,
            total: usage.total_tokens,
            cached_input: usage.cached_input_tokens,
            cache_creation_input: usage.cache_creation_input_tokens,
            tool_use_prompt: usage.tool_use_prompt_tokens,
            reasoning: usage.reasoning_tokens,
        }
    }
}

#[derive(Debug)]
enum PendingEvent {
    Event(Event),
    ToolArguments { index: usize, json: String },
}

type Events = Arc<Mutex<Vec<PendingEvent>>>;

struct NativeRequest {
    events: Events,
    cancel: watch::Sender<bool>,
    tool_arguments: HashMap<usize, String>,
}

impl Drop for NativeRequest {
    fn drop(&mut self) {
        let _ = self.cancel.send(true);
    }
}

impl UserData for NativeRequest {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("poll", |lua, this, ()| {
            let events = drain_events(&this.events, &mut this.tool_arguments);
            // Neovim's JSON codec preserves vim.NIL and empty objects across the bridge.
            let json: LuaTable = lua.globals().get::<LuaTable>("vim")?.get("json")?;
            json.get::<LuaFunction>("decode")?
                .call::<LuaValue>(serde_json::to_string(&events).map_err(LuaError::external)?)
        });
        methods.add_method("cancel", |_, this, ()| {
            let _ = this.cancel.send(true);
            Ok(())
        });
    }
}

fn push(events: &Events, event: Event) {
    let mut pending = events
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    match (pending.last_mut(), event) {
        (
            Some(PendingEvent::Event(Event::ContentDelta {
                index: pending_index,
                kind: pending_kind,
                text: pending_text,
            })),
            Event::ContentDelta { index, kind, text },
        ) if *pending_index == index && *pending_kind == kind => pending_text.push_str(&text),
        (_, event) => pending.push(PendingEvent::Event(event)),
    }
}

fn push_tool_arguments(events: &Events, index: usize, json: &str) {
    let mut pending = events
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    match pending.last_mut() {
        Some(PendingEvent::ToolArguments {
            index: pending_index,
            json: pending_json,
        }) if *pending_index == index => pending_json.push_str(json),
        _ => pending.push(PendingEvent::ToolArguments {
            index,
            json: json.to_owned(),
        }),
    }
}

fn drain_events(events: &Events, tool_arguments: &mut HashMap<usize, String>) -> Vec<Event> {
    let pending = {
        let mut pending = events
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        std::mem::take(&mut *pending)
    };
    pending
        .into_iter()
        .map(|event| match event {
            PendingEvent::Event(event) => {
                if let Event::ContentEnd { index, .. } = &event {
                    tool_arguments.remove(index);
                }
                event
            }
            PendingEvent::ToolArguments { index, json } => {
                let arguments = tool_arguments.entry(index).or_default();
                arguments.push_str(&json);
                Event::ToolCallDelta {
                    index,
                    arguments: Value::Object(parse_partial_arguments(arguments)),
                }
            }
        })
        .collect()
}

fn panic_message(payload: &(dyn Any + Send)) -> &str {
    payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("unknown panic")
}

fn run_worker_guarded(events: &Events, worker: impl FnOnce()) {
    if let Err(payload) = catch_unwind(AssertUnwindSafe(worker)) {
        push(
            events,
            Event::Error {
                message: format!(
                    "avante-llm worker panicked: {}",
                    panic_message(payload.as_ref())
                ),
                status: None,
                retry_after: None,
            },
        );
    }
}

async fn run_until_cancelled<T>(
    cancelled: &mut watch::Receiver<bool>,
    future: impl Future<Output = T>,
) -> Option<T> {
    tokio::select! {
        biased;
        _ = cancelled.changed() => None,
        result = future => Some(result),
    }
}

fn content_end(
    index: usize,
    content: AssistantContent,
    turn_id: &str,
    order: usize,
) -> Option<Event> {
    let call_id = match &content {
        AssistantContent::ToolCall(call) => Some(call.id.clone()),
        _ => None,
    };
    let (content, native) = match content {
        AssistantContent::Text(text) => (Value::String(text.text), text.native),
        AssistantContent::Reasoning(reasoning) => {
            let content = if reasoning.redacted {
                serde_json::json!({"type": "redacted_thinking", "data": ""})
            } else {
                serde_json::json!({"type": "thinking", "thinking": reasoning.text, "signature": ""})
            };
            (content, reasoning.native)
        }
        AssistantContent::ToolCall(call) => (
            serde_json::json!({
                "type": "tool_use",
                "id": call.id.to_string(),
                "name": call.function.name.to_string(),
                "input": call.function.arguments_value(),
            }),
            call.native,
        ),
        _ => return None,
    };
    Some(Event::ContentEnd {
        index,
        order,
        content,
        native: Some(
            serde_json::to_string(&NativeMetadata {
                native,
                call_id,
                turn_id: Some(turn_id.to_owned()),
                order: Some(order),
            })
            .expect("native metadata is JSON"),
        ),
    })
}

#[derive(Clone, Debug)]
struct HeadersMiddleware {
    request_headers: http::HeaderMap,
    replace_headers: bool,
    events: Events,
}

impl HttpMiddleware for HeadersMiddleware {
    fn before_request_headers<'a>(
        &'a self,
        _exchange: rig::http_client::Exchange<'a>,
        headers: &'a mut http::HeaderMap,
    ) -> rig::wasm_compat::WasmBoxedFuture<'a, rig::http_client::Result<()>> {
        if self.replace_headers {
            headers.clear();
        }
        for (name, value) in &self.request_headers {
            headers.insert(name, value.clone());
        }
        Box::pin(async { Ok(()) })
    }

    fn after_response<'a>(
        &'a self,
        _exchange: rig::http_client::Exchange<'a>,
        _status: http::StatusCode,
        headers: &'a http::HeaderMap,
    ) -> rig::wasm_compat::WasmBoxedFuture<'a, rig::http_client::Result<()>> {
        let headers = headers
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (name.as_str().to_owned(), value.to_owned()))
            })
            .collect();
        push(&self.events, Event::ResponseHeaders { headers });
        Box::pin(async { Ok(()) })
    }
}

#[derive(Clone, Debug)]
struct CaptureHeaders(Arc<Mutex<Option<http::HeaderMap>>>);

impl HttpMiddleware for CaptureHeaders {
    fn before_request_headers<'a>(
        &'a self,
        _exchange: rig::http_client::Exchange<'a>,
        headers: &'a mut http::HeaderMap,
    ) -> rig::wasm_compat::WasmBoxedFuture<'a, rig::http_client::Result<()>> {
        *self.0.lock().expect("header capture lock") = Some(headers.clone());
        // Stop before I/O: Lua needs the generated headers before applying its callback.
        Box::pin(async { Err(rig::http_client::Error::StreamEnded) })
    }
}

fn request_headers(input: Input) -> Result<BTreeMap<String, String>, String> {
    input.validate()?;
    if matches!(
        input.provider.protocol,
        ProtocolInput::Bedrock | ProtocolInput::Vertex
    ) {
        return Err("SDK transports do not expose request headers".to_owned());
    }
    let captured = Arc::new(Mutex::new(None));
    let http = build_http(&input.provider, &Events::default())?
        .with_middleware(CaptureHeaders(Arc::clone(&captured)));
    let model = build_http_model(&input.provider, http)?;
    let request = completion_request(&input.provider, input.prompt)?;
    let mut stream = model.stream(request).map_err(|error| error.to_string())?;
    let _ = stream.next().now_or_never();
    let headers = captured
        .lock()
        .expect("header capture lock")
        .take()
        .ok_or_else(|| "Rig did not generate request headers".to_owned())?;
    headers
        .iter()
        .map(|(name, value)| {
            let name = match name.as_str() {
                "authorization" => "Authorization",
                "content-type" => "Content-Type",
                "accept" => "Accept",
                "user-agent" => "User-Agent",
                "editor-version" => "Editor-Version",
                "editor-plugin-version" => "Editor-Plugin-Version",
                "copilot-integration-id" => "Copilot-Integration-Id",
                "openai-intent" => "Openai-Intent",
                "x-initiator" => "X-Initiator",
                "http-referer" => "HTTP-Referer",
                "x-title" => "X-Title",
                name => name,
            };
            value
                .to_str()
                .map(|value| (name.to_owned(), value.to_owned()))
                .map_err(|error| error.to_string())
        })
        .collect()
}

fn build_http(
    provider: &ProviderInput,
    events: &Events,
) -> Result<rig::http_client::DynHttpClient, String> {
    build_http_with_read_timeout(provider, events, Duration::from_secs(120))
}

fn build_http_with_read_timeout(
    provider: &ProviderInput,
    events: &Events,
    read_timeout: Duration,
) -> Result<rig::http_client::DynHttpClient, String> {
    let mut headers = rig_reqwest::reqwest::header::HeaderMap::new();
    for (name, value) in &provider.headers {
        let name = rig_reqwest::reqwest::header::HeaderName::from_bytes(name.as_bytes())
            .map_err(|error| format!("invalid HTTP header name {name}: {error}"))?;
        let value = rig_reqwest::reqwest::header::HeaderValue::from_str(value)
            .map_err(|error| format!("invalid HTTP header value: {error}"))?;
        headers.insert(name, value);
    }

    let mut builder = rig_reqwest::reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .read_timeout(read_timeout)
        .danger_accept_invalid_certs(provider.allow_insecure);
    if let Some(proxy) = &provider.proxy {
        builder =
            builder.proxy(rig_reqwest::reqwest::Proxy::all(proxy).map_err(|e| e.to_string())?);
    }
    let client = builder.build().map_err(|error| error.to_string())?;
    Ok(
        rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(client))
            .with_middleware(HeadersMiddleware {
                request_headers: headers,
                replace_headers: provider.replace_headers,
                events: Arc::clone(events),
            }),
    )
}

async fn bedrock_runtime(
    settings: &BedrockInput,
    proxy: Option<&str>,
) -> Result<rig_bedrock::client::BedrockRuntime, String> {
    let mut loader = aws_config::defaults(aws_config::BehaviorVersion::latest());
    if let Some(proxy) = proxy {
        let proxy = aws_smithy_http_client::proxy::ProxyConfig::all(proxy)
            .map_err(|error| error.to_string())?;
        let http = aws_smithy_http_client::Builder::new().build_with_connector_fn(
            move |settings, _components| {
                let mut builder =
                    aws_smithy_http_client::Connector::builder().proxy_config(proxy.clone());
                builder.set_connector_settings(settings.cloned());
                builder
                    .tls_provider(aws_smithy_http_client::tls::Provider::Rustls(
                        aws_smithy_http_client::tls::rustls_provider::CryptoMode::AwsLc,
                    ))
                    .build()
            },
        );
        loader = loader.http_client(http);
    }
    if let Some(region) = &settings.region {
        loader = loader.region(aws_config::Region::new(region.clone()));
    }
    if let Some(profile) = settings
        .profile
        .as_ref()
        .filter(|profile| !profile.trim().is_empty())
    {
        loader = loader.profile_name(profile);
    }
    if let (Some(access_key), Some(secret_key)) =
        (&settings.access_key_id, &settings.secret_access_key)
    {
        loader = loader.credentials_provider(aws_sdk_bedrockruntime::config::Credentials::new(
            access_key,
            secret_key,
            settings.session_token.clone(),
            None,
            "avante",
        ));
    }
    let shared = loader.load().await;
    let mut service = aws_sdk_bedrockruntime::config::Builder::from(&shared);
    if let Some(endpoint) = &settings.endpoint {
        service = service.endpoint_url(endpoint);
    }
    if let Some(token) = &settings.bearer_token {
        service = service
            .bearer_token(aws_sdk_bedrockruntime::config::Token::new(token, None))
            .auth_scheme_preference([
                aws_smithy_runtime_api::client::auth::http::HTTP_BEARER_AUTH_SCHEME_ID,
            ]);
    }
    Ok(rig_bedrock::client::BedrockRuntime::from(
        aws_sdk_bedrockruntime::Client::from_conf(service.build()),
    ))
}

async fn build_model(
    provider: &ProviderInput,
    events: &Events,
) -> Result<DynModel<Completion>, String> {
    let model = provider.model.as_str();
    if matches!(provider.protocol, ProtocolInput::Bedrock) {
        let settings = provider
            .bedrock
            .as_ref()
            .expect("Bedrock settings were validated");
        return Ok(bedrock_runtime(settings, provider.proxy.as_deref())
            .await?
            .completion(model)
            .erase());
    }
    if matches!(provider.protocol, ProtocolInput::Vertex) {
        let settings = provider.vertex.clone().unwrap_or_default();
        let mut builder = rig_vertexai::VertexAi::builder();
        if let Some(project) = settings.project_id {
            builder = builder.with_project(project);
        }
        if let Some(location) = settings.location {
            builder = builder.with_location(location);
        }
        let client = builder.build().map_err(|error| error.to_string())?;
        return Ok(Model::new(
            rig_vertexai::completion::GenerateContent::new(model),
            StreamingVertex(client),
        )
        .erase());
    }

    build_http_model(provider, build_http(provider, events)?)
}

fn value_items(value: Value) -> Result<Vec<Value>, String> {
    match value {
        Value::String(text) => Ok(vec![Value::String(text)]),
        Value::Array(items) => Ok(items),
        Value::Object(_) => Ok(vec![value]),
        _ => Err("message content must be a string, object, or array".to_owned()),
    }
}

fn item_type(item: &Map<String, Value>) -> Option<&str> {
    item.get("type").and_then(Value::as_str)
}

fn item_text(item: &Map<String, Value>) -> Option<String> {
    item.get("text")
        .or_else(|| item.get("content"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn image_type(mime: Option<&str>) -> Option<ImageMediaType> {
    mime.and_then(ImageMediaType::from_mime_type)
}

fn is_deepseek_chat(provider: &ProviderInput) -> bool {
    matches!(provider.protocol, ProtocolInput::Openai)
        && !matches!(provider.route, Some(RouteInput::Responses))
        && provider.dialect.as_deref() == Some(rig::providers::deepseek::PROVIDER_NAME)
}

fn user_content(
    value: Value,
    tool_calls: &HashMap<String, (CallId, ToolName)>,
) -> Result<Option<UserContent>, String> {
    match value {
        Value::String(text) => Ok(Some(UserContent::text(text))),
        Value::Object(item) => match item_type(&item) {
            Some("text") => Ok(item_text(&item).map(UserContent::text)),
            Some("image") => {
                let source = item
                    .get("source")
                    .and_then(Value::as_object)
                    .ok_or_else(|| "image content has no source".to_owned())?;
                let data = source
                    .get("data")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "image content has no base64 data".to_owned())?;
                Ok(Some(UserContent::image_base64(
                    data,
                    image_type(source.get("media_type").and_then(Value::as_str)),
                    None,
                )))
            }
            Some("tool_result") => {
                let id = item
                    .get("tool_use_id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "tool result has no tool_use_id".to_owned())?;
                let (call, name) = tool_calls
                    .get(id)
                    .cloned()
                    .ok_or_else(|| format!("tool result {id} has no preceding tool call"))?;
                let text = item
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let result = ToolResult {
                    call,
                    name,
                    content: vec![ToolResultContent::text(text)],
                    is_error: item
                        .get("is_error")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                };
                Ok(Some(UserContent::ToolResult(result)))
            }
            Some("thinking" | "redacted_thinking" | "reasoning") => Ok(None),
            Some(kind) => Err(format!("unsupported user content type: {kind}")),
            None => Err("message content object has no type".to_owned()),
        },
        _ => Err("message content item must be a string or object".to_owned()),
    }
}

fn assistant_content(
    value: Value,
    provider: &ProviderInput,
    origin: &mut Option<Origin>,
) -> Result<Option<AssistantContent>, String> {
    match value {
        Value::String(text) => Ok(Some(AssistantContent::text(text))),
        Value::Object(item) => match item_type(&item) {
            Some("text") => Ok(item_text(&item).map(AssistantContent::text)),
            Some("thinking") => {
                let thinking = item
                    .get("thinking")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let content = AssistantContent::reasoning(thinking);
                if is_deepseek_chat(provider) {
                    *origin = Some(Origin::new(
                        "openai.chat",
                        rig::providers::deepseek::PROVIDER_NAME,
                        &provider.model,
                    ));
                    return Ok(Some(content));
                }
                if matches!(provider.protocol, ProtocolInput::Bedrock)
                    && let Some(signature) = item
                        .get("signature")
                        .and_then(Value::as_str)
                        .filter(|signature| !signature.is_empty())
                {
                    *origin = Some(Origin::new(
                        "bedrock.converse",
                        rig_bedrock::completion::PROVIDER_NAME,
                        &provider.model,
                    ));
                    return Ok(Some(content.with_native(serde_json::json!({
                        "reasoningContent": {"reasoningText": {"text": thinking, "signature": signature}}
                    }))));
                }
                let Some(item_origin) = legacy_origin(provider, "thinking") else {
                    return Ok(Some(content));
                };
                *origin = Some(item_origin);
                Ok(Some(content.with_native(Value::Object(item))))
            }
            Some("redacted_thinking") => {
                let content = AssistantContent::Reasoning(MessageReasoning {
                    text: String::new(),
                    redacted: true,
                    native: None,
                });
                let Some(item_origin) = legacy_origin(provider, "redacted_thinking") else {
                    return Ok(Some(content));
                };
                *origin = Some(item_origin);
                Ok(Some(content.with_native(Value::Object(item))))
            }
            Some("reasoning") => {
                let text = item
                    .get("summary")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|part| part.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n");
                let content = AssistantContent::reasoning(text);
                let Some(item_origin) = legacy_origin(provider, "reasoning") else {
                    return Ok((!content.is_blank()).then_some(content));
                };
                *origin = Some(item_origin);
                Ok(Some(content.with_native(Value::Object(item))))
            }
            Some("tool_use") => {
                let id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "tool call has no id".to_owned())?;
                let name = ToolName::new(
                    item.get("name")
                        .and_then(Value::as_str)
                        .ok_or_else(|| "tool call has no name".to_owned())?,
                )
                .map_err(|error| error.to_string())?;
                Ok(Some(AssistantContent::tool_call(
                    id,
                    name,
                    item.get("input").cloned().unwrap_or(Value::Null),
                )))
            }
            Some(kind) => Err(format!("unsupported assistant content type: {kind}")),
            None => Err("message content object has no type".to_owned()),
        },
        _ => Err("message content item must be a string or object".to_owned()),
    }
}

fn legacy_origin(provider: &ProviderInput, kind: &str) -> Option<Origin> {
    let descriptor = match kind {
        "thinking" | "redacted_thinking" if matches!(provider.protocol, ProtocolInput::Claude) => {
            return Some(Origin::new(
                "anthropic.messages",
                "anthropic",
                &provider.model,
            ));
        }
        "reasoning" | "phase"
            if matches!(provider.protocol, ProtocolInput::Copilot)
                && matches!(provider.route, Some(RouteInput::Responses)) =>
        {
            rig::providers::copilot::PROVIDER_NAME
        }
        "reasoning" | "phase"
            if matches!(provider.protocol, ProtocolInput::Azure)
                && matches!(provider.route, Some(RouteInput::Responses)) =>
        {
            AZURE.name
        }
        "reasoning" | "phase"
            if matches!(provider.protocol, ProtocolInput::Openai)
                && matches!(provider.route, Some(RouteInput::Responses)) =>
        {
            configure_openai(provider).dialect.name
        }
        _ => return None,
    };
    Some(Origin::new("openai.responses", descriptor, &provider.model))
}

fn messages(prompt: &PromptInput, provider: &ProviderInput) -> Result<Vec<Message>, String> {
    let mut messages = Vec::with_capacity(prompt.messages.len() + 1);
    messages.push(Message::system(prompt.system_prompt.clone()));
    let mut tool_calls = HashMap::new();
    let continues_stored_response = matches!(provider.route, Some(RouteInput::Responses))
        && prompt
            .additional_params
            .as_ref()
            .and_then(|params| params.get("previous_response_id"))
            .is_some_and(|value| !value.is_null());
    let mut continuation_start = 1;
    let mut history = prompt
        .messages
        .iter()
        .map(|message| {
            let metadata = if message.role == "assistant" {
                message
                    .native
                    .as_deref()
                    .map(serde_json::from_str::<NativeMetadata>)
                    .transpose()
                    .map_err(|error| format!("invalid native message metadata: {error}"))?
            } else {
                None
            };
            Ok((message, metadata))
        })
        .collect::<Result<Vec<_>, String>>()?;
    for turn in history.chunk_by_mut(|(left, left_metadata), (right, right_metadata)| {
        left.role == "assistant"
            && right.role == "assistant"
            && left.origin == right.origin
            && matches!((left_metadata, right_metadata), (Some(left), Some(right))
                if left.turn_id.is_some() && left.turn_id == right.turn_id
                    && left.order.is_some() && right.order.is_some())
    }) {
        turn.sort_by_key(|(_, metadata)| metadata.as_ref().and_then(|metadata| metadata.order));
    }
    for (message, metadata) in history {
        let items = value_items(message.content.clone())?;
        match message.role.as_str() {
            "user" => {
                let content = items
                    .into_iter()
                    .map(|item| user_content(item, &tool_calls))
                    .collect::<Result<Vec<_>, _>>()?
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>();
                if !content.is_empty() {
                    messages.push(Message::User { content });
                }
            }
            "assistant" => {
                let mut origin = None;
                let mut content = items
                    .into_iter()
                    .map(|item| assistant_content(item, provider, &mut origin))
                    .collect::<Result<Vec<_>, _>>()?
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>();
                if !content.is_empty() {
                    if let Some(metadata) = metadata {
                        if content.len() != 1 {
                            return Err(
                                "native metadata requires one assistant content block".to_owned()
                            );
                        }
                        match &mut content[0] {
                            AssistantContent::Text(text) => text.native = metadata.native,
                            AssistantContent::Reasoning(reasoning) => {
                                reasoning.native = metadata.native;
                            }
                            AssistantContent::ToolCall(call) => {
                                if let Some(id) = metadata.call_id
                                    && id.to_string() == call.id.to_string()
                                {
                                    call.id = id;
                                }
                                call.native = metadata.native;
                            }
                            _ => {}
                        }
                    }
                    if message.native.is_none()
                        && let Some(phase) = &message.phase
                        && let Some(responses_origin) = legacy_origin(provider, "phase")
                        && message
                            .origin
                            .as_ref()
                            .is_none_or(|origin| origin == &responses_origin)
                    {
                        for block in &mut content {
                            if let AssistantContent::Text(text) = block {
                                *block = AssistantContent::text(&text.text).with_native(serde_json::json!({
                                    "type": "message",
                                    "role": "assistant",
                                    "phase": phase,
                                    "status": "completed",
                                    "content": [{"type": "output_text", "text": text.text, "annotations": []}],
                                }));
                            }
                        }
                        origin = Some(responses_origin);
                    }
                    for block in &content {
                        if let AssistantContent::ToolCall(call) = block {
                            tool_calls.insert(
                                call.id.to_string(),
                                (call.id.clone(), call.function.name.clone()),
                            );
                        }
                    }
                    let mut turn = AssistantMessage::new(content)
                        .with_origin(message.origin.clone().or(origin));
                    // Keep synthetic content outside the stored server response.
                    let can_merge = !continues_stored_response
                        || !message.is_dummy
                        || messages.len() != continuation_start;
                    if can_merge
                        && let Some(Message::Assistant(previous)) = messages.last_mut()
                        && (previous.origin.is_none()
                            || turn.origin.is_none()
                            || previous.origin == turn.origin)
                    {
                        if previous.origin.is_none() {
                            previous.origin = turn.origin.take();
                        }
                        previous.content.extend(turn.content);
                    } else {
                        messages.push(Message::Assistant(turn));
                    }
                    if !message.is_dummy {
                        continuation_start = messages.len();
                    }
                }
            }
            role => return Err(format!("unsupported message role: {role}")),
        }
    }
    append_images(&mut messages, &prompt.image_paths)?;
    let has_tool_results = messages.iter().skip(continuation_start).any(|message| {
        matches!(message, Message::User { content } if content.iter().any(|item| matches!(item, UserContent::ToolResult(_))))
    });
    if continues_stored_response && has_tool_results {
        messages.drain(1..continuation_start);
    }
    Ok(messages)
}

fn append_images(messages: &mut Vec<Message>, paths: &[String]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut images = Vec::with_capacity(paths.len());
    for path in paths {
        let bytes = std::fs::read(path).map_err(|error| format!("read image {path}: {error}"))?;
        let mime = match Path::new(path)
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("jpg" | "jpeg") => Some(ImageMediaType::JPEG),
            Some("gif") => Some(ImageMediaType::GIF),
            Some("webp") => Some(ImageMediaType::WEBP),
            Some("heic") => Some(ImageMediaType::HEIC),
            Some("heif") => Some(ImageMediaType::HEIF),
            Some("svg") => Some(ImageMediaType::SVG),
            _ => Some(ImageMediaType::PNG),
        };
        images.push(UserContent::image_base64(
            base64::engine::general_purpose::STANDARD.encode(bytes),
            mime,
            None,
        ));
    }
    if let Some(Message::User { content }) = messages
        .iter_mut()
        .rev()
        .find(|message| matches!(message, Message::User { .. }))
    {
        content.extend(images);
    } else {
        messages.push(Message::User { content: images });
    }
    Ok(())
}

fn completion_request(
    provider: &ProviderInput,
    prompt: PromptInput,
) -> Result<CompletionRequest, String> {
    let mut history = messages(&prompt, provider)?;
    if history.len() == 1 {
        return Err("prompt has no user or assistant messages".to_owned());
    }
    let last = history
        .pop()
        .expect("history contains a non-system message");
    let mut request = CompletionRequest::new(last).messages(history);
    let tools = prompt
        .tools
        .into_iter()
        .map(|tool| {
            Ok(ToolDefinition::new(
                ToolName::new(tool.name).map_err(|error| error.to_string())?,
                tool.description,
                tool.parameters,
            ))
        })
        .collect::<Result<Vec<_>, String>>()?;
    request = request.tools(tools);
    rig_compat::apply_generation_params(provider, &mut request, prompt.additional_params)?;
    Ok(request)
}

fn retry_after(error: &rig::error::ProviderError) -> Option<u64> {
    error
        .provider_response_headers()?
        .get("retry-after")?
        .to_str()
        .ok()?
        .parse()
        .ok()
}

fn report_error(events: &Events, error: &rig::error::ProviderError, provider: &ProviderInput) {
    let mut message = error.to_string();
    // Gemini includes its API key in request URLs, which transport errors can echo.
    if let Some(key) = provider.api_key.as_deref().filter(|key| !key.is_empty()) {
        message = message.replace(key, "[REDACTED]");
    }
    push(
        events,
        Event::Error {
            message,
            status: error
                .provider_response_status()
                .map(|status| status.as_u16()),
            retry_after: retry_after(error),
        },
    );
}

async fn run(input: Input, events: Events, mut cancelled: watch::Receiver<bool>) {
    let Some(model) = Box::pin(run_until_cancelled(
        &mut cancelled,
        build_model(&input.provider, &events),
    ))
    .await
    else {
        push(&events, Event::Cancelled);
        return;
    };
    let model = match model {
        Ok(model) => model,
        Err(message) => {
            push(
                &events,
                Event::Error {
                    message,
                    status: None,
                    retry_after: None,
                },
            );
            return;
        }
    };
    let turn_id = input.prompt.turn_id.clone();
    let request = match completion_request(&input.provider, input.prompt) {
        Ok(request) => request,
        Err(message) => {
            push(
                &events,
                Event::Error {
                    message,
                    status: None,
                    retry_after: None,
                },
            );
            return;
        }
    };
    let mut stream = match model.stream(request) {
        Ok(stream) => stream,
        Err(error) => {
            report_error(&events, &error, &input.provider);
            return;
        }
    };

    let mut parts = BTreeMap::new();
    loop {
        let next = tokio::select! {
            _ = cancelled.changed() => {
                push(&events, Event::Cancelled);
                return;
            }
            next = stream.next() => next,
        };
        let Some(item) = next else { break };
        let item = match item {
            Ok(item) => item,
            Err(error) => {
                report_error(&events, &error, &input.provider);
                return;
            }
        };
        let Item::Event(event) = item else { continue };
        match event {
            StreamEvent::Start { part, kind, name } => {
                let kind = match kind {
                    PartKind::Text => ContentKind::Text,
                    PartKind::Reasoning => ContentKind::Reasoning,
                    PartKind::ToolCall => ContentKind::ToolCall,
                    _ => continue,
                };
                push(
                    &events,
                    Event::ContentStart {
                        index: part.index(),
                        kind,
                        name: name.map(|name| name.to_string()),
                    },
                );
            }
            StreamEvent::Text { part, text } => push(
                &events,
                Event::ContentDelta {
                    index: part.index(),
                    kind: ContentKind::Text,
                    text,
                },
            ),
            StreamEvent::Reasoning { part, text } => push(
                &events,
                Event::ContentDelta {
                    index: part.index(),
                    kind: ContentKind::Reasoning,
                    text,
                },
            ),
            StreamEvent::Arguments { part, json } => {
                push_tool_arguments(&events, part.index(), &json);
            }
            StreamEvent::End { part, content } => {
                parts.insert(part.index(), content.fingerprint());
            }
        }
    }

    let Some(finished) = run_until_cancelled(&mut cancelled, stream.finish()).await else {
        push(&events, Event::Cancelled);
        return;
    };
    match finished {
        Ok(response) => {
            let response_id = response.response_id().map(str::to_owned);
            let reason = match response.stop() {
                StopReason::Length => DoneReason::Length,
                StopReason::ToolUse => DoneReason::ToolUse,
                StopReason::Stop => DoneReason::Complete,
                StopReason::Error(message) | StopReason::Aborted(message) => {
                    push(
                        &events,
                        Event::Error {
                            message,
                            status: None,
                            retry_after: None,
                        },
                    );
                    return;
                }
                other => {
                    push(
                        &events,
                        Event::Error {
                            message: format!("unsupported provider stop reason: {other:?}"),
                            status: None,
                            retry_after: None,
                        },
                    );
                    return;
                }
            };
            if matches!(reason, DoneReason::ToolUse)
                && let Some(call) = response
                    .tool_calls()
                    .find(|call| call.function.invalid_arguments.is_some())
            {
                push(
                    &events,
                    Event::Error {
                        message: format!("invalid JSON arguments for tool {}", call.function.name),
                        status: None,
                        retry_after: None,
                    },
                );
                return;
            }
            for (order, content) in response.choice.into_iter().enumerate() {
                let fingerprint = content.fingerprint();
                let index = parts
                    .iter()
                    .find_map(|(&index, &previous)| (previous == fingerprint).then_some(index))
                    .expect("completed content has a streamed part");
                parts.remove(&index);
                if let Some(event) = content_end(index, content, &turn_id, order) {
                    push(&events, event);
                }
            }
            push(
                &events,
                Event::Done {
                    reason,
                    usage: Box::new(response.usage.into()),
                    response_id,
                    origin: response.origin,
                },
            );
        }
        Err(error) => report_error(&events, &error, &input.provider),
    }
}

fn start(input: Input) -> LuaResult<NativeRequest> {
    input.validate().map_err(LuaError::external)?;
    let events = Events::default();
    let (cancel, cancelled) = watch::channel(false);
    let worker_events = Arc::clone(&events);
    std::thread::Builder::new()
        .name("avante-rig".to_owned())
        .spawn(move || {
            let panic_events = Arc::clone(&worker_events);
            run_worker_guarded(&panic_events, || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                match runtime {
                    Ok(runtime) => runtime.block_on(run(input, worker_events, cancelled)),
                    Err(error) => push(
                        &worker_events,
                        Event::Error {
                            message: error.to_string(),
                            status: None,
                            retry_after: None,
                        },
                    ),
                }
            });
        })
        .map_err(LuaError::external)?;
    Ok(NativeRequest {
        events,
        cancel,
        tool_arguments: HashMap::new(),
    })
}

fn input_from_lua(lua: &Lua, input: LuaValue) -> LuaResult<Input> {
    let json: LuaTable = lua.globals().get::<LuaTable>("vim")?.get("json")?;
    let encoded: String = json.get::<LuaFunction>("encode")?.call(input)?;
    serde_json::from_str(&encoded).map_err(LuaError::external)
}

#[mlua::lua_module]
fn avante_llm(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set("api_version", NATIVE_API_VERSION)?;
    exports.set(
        "start",
        lua.create_function(|lua, input: LuaValue| start(input_from_lua(lua, input)?))?,
    )?;
    exports.set(
        "request_headers",
        lua.create_function(|lua, input: LuaValue| {
            let headers =
                request_headers(input_from_lua(lua, input)?).map_err(LuaError::external)?;
            lua.to_value(&headers)
        })?,
    )?;
    Ok(exports)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rig_compat::azure_responses_uri;
    use google_cloud_aiplatform_v1 as vertexai;
    use google_cloud_gax::streaming::ResponseStream;
    use rig::completion::options::{Effort, Reasoning};
    use rig::providers::openai::wire::OPENAI;
    use rig::providers::openai::{OpenAIConfig, Route};
    use rig::streaming::CompletionStream;
    use rig::wire::{Body, Mode, Wire};
    use serde_json::json;
    use std::time::Duration;
    use tokio::sync::mpsc;

    fn prompt() -> PromptInput {
        PromptInput {
            system_prompt: "You are concise.".to_owned(),
            messages: vec![AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "user".to_owned(),
                content: Value::String("hello".to_owned()),
            }],
            image_paths: Vec::new(),
            tools: vec![ToolInput {
                name: "lookup".to_owned(),
                description: "Look something up".to_owned(),
                parameters: json!({
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"]
                }),
            }],
            turn_id: "test-turn".to_owned(),
            additional_params: Some(json!({
                "temperature": 0.5,
                "max_completion_tokens": 42,
                "reasoning_context": {"mode": "preserve"}
            })),
        }
    }

    fn provider(name: &str, route: Option<RouteInput>) -> ProviderInput {
        ProviderInput {
            name: name.to_owned(),
            dialect: None,
            protocol: if name == "anthropic" {
                ProtocolInput::Claude
            } else {
                ProtocolInput::Openai
            },
            model: "test-model".to_owned(),
            deployment: None,
            base_url: None,
            api_key: Some("token".to_owned()),
            auth: None,
            route,
            api_version: None,
            prompt_caching: false,
            headers: BTreeMap::new(),
            replace_headers: false,
            proxy: None,
            allow_insecure: false,
            bedrock: None,
            vertex: None,
        }
    }

    #[test]
    fn http_times_out_stalled_headers_and_body() {
        use rig::http_client::{HttpClientExt, NoBody};
        use std::io::{Read, Write};
        use std::net::TcpListener;

        for send_headers in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}/", listener.local_addr().unwrap());
            let (finish_server, finished) = std::sync::mpsc::channel();
            let server = std::thread::spawn(move || {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut request = Vec::new();
                let mut byte = [0];
                while !request.ends_with(b"\r\n\r\n") {
                    socket.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                }
                if send_headers {
                    socket
                        .write_all(
                            b"HTTP/1.1 200 OK\r\ncontent-length: 10\r\nconnection: close\r\n\r\n",
                        )
                        .unwrap();
                }
                finished.recv_timeout(Duration::from_secs(3)).unwrap();
            });
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async {
                let client = build_http_with_read_timeout(
                    &provider("openai", None),
                    &Events::default(),
                    Duration::from_millis(200),
                )
                .unwrap();
                let request = http::Request::builder().uri(url).body(NoBody).unwrap();
                let result = tokio::time::timeout(Duration::from_secs(2), async {
                    let response = client.send_streaming(request).await?;
                    response.into_body().next().await.unwrap().map(|_| ())
                })
                .await
                .expect("HTTP idle timeout must fire before the test deadline");
                assert!(result.is_err(), "a stalled HTTP operation must fail");
            });
            drop(runtime);
            finish_server.send(()).unwrap();
            server.join().unwrap();
        }
    }

    #[tokio::test]
    async fn http_read_timeout_resets_when_streaming_data_arrives() {
        use rig::http_client::{HttpClientExt, NoBody};
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                socket.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            socket
                .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 6\r\nconnection: close\r\n\r\n")
                .unwrap();
            for _ in 0..6 {
                std::thread::sleep(Duration::from_millis(100));
                socket.write_all(b"x").unwrap();
            }
        });
        let client = build_http_with_read_timeout(
            &provider("openai", None),
            &Events::default(),
            Duration::from_millis(300),
        )
        .unwrap();
        let request = http::Request::builder().uri(url).body(NoBody).unwrap();
        let body = tokio::time::timeout(Duration::from_secs(3), async {
            let response = client.send_streaming(request).await.unwrap();
            let mut stream = response.into_body();
            let mut body = Vec::new();
            while let Some(chunk) = stream.next().await {
                body.extend_from_slice(&chunk.unwrap());
            }
            body
        })
        .await
        .expect("active stream must finish");
        assert_eq!(body, b"xxxxxx");
        server.join().unwrap();
    }

    #[test]
    fn captures_rig_headers_without_a_runtime_or_network_request() {
        let headers = request_headers(Input {
            provider: provider("openai", Some(RouteInput::Chat)),
            prompt: prompt(),
        })
        .unwrap();
        assert_eq!(
            headers.get("Authorization").map(String::as_str),
            Some("Bearer token")
        );
        assert_eq!(
            headers.get("Content-Type").map(String::as_str),
            Some("application/json")
        );
        assert_eq!(
            headers.get("Accept").map(String::as_str),
            Some("text/event-stream")
        );
    }

    #[test]
    fn coalesces_adjacent_content_events() {
        let events = Events::default();
        push(
            &events,
            Event::ContentDelta {
                index: 0,
                kind: ContentKind::Text,
                text: "hel".to_owned(),
            },
        );
        push(
            &events,
            Event::ContentDelta {
                index: 0,
                kind: ContentKind::Text,
                text: "lo".to_owned(),
            },
        );
        push(
            &events,
            Event::ContentDelta {
                index: 1,
                kind: ContentKind::Reasoning,
                text: "think".to_owned(),
            },
        );
        push(
            &events,
            Event::ContentDelta {
                index: 1,
                kind: ContentKind::Reasoning,
                text: "ing".to_owned(),
            },
        );
        push(
            &events,
            Event::ContentDelta {
                index: 2,
                kind: ContentKind::Reasoning,
                text: "next".to_owned(),
            },
        );

        let pending = events.lock().unwrap();
        assert_eq!(pending.len(), 3);
        assert!(matches!(
            &pending[0],
            PendingEvent::Event(Event::ContentDelta { index: 0, kind: ContentKind::Text, text }) if text == "hello"
        ));
        assert!(matches!(
            &pending[1],
            PendingEvent::Event(Event::ContentDelta { index: 1, kind: ContentKind::Reasoning, text }) if text == "thinking"
        ));
    }

    #[test]
    fn coalesces_raw_tool_argument_fragments_before_parsing() {
        let events = Events::default();
        push_tool_arguments(&events, 0, r#"{"path":"README"#);
        push_tool_arguments(&events, 0, r#".md"}"#);

        let pending = events.lock().unwrap();
        assert_eq!(pending.len(), 1);
        assert!(matches!(
            &pending[0],
            PendingEvent::ToolArguments { index: 0, json } if json == r#"{"path":"README.md"}"#
        ));
        drop(pending);

        let mut arguments = HashMap::new();
        let emitted = drain_events(&events, &mut arguments);
        assert!(matches!(
            &emitted[0],
            Event::ToolCallDelta { index: 0, arguments } if *arguments == json!({"path": "README.md"})
        ));
    }

    #[test]
    fn reports_worker_panics_as_terminal_errors() {
        let events = Events::default();

        run_worker_guarded(&events, || panic!("worker failed"));

        let pending = events.lock().unwrap();
        assert!(matches!(
            &pending[0],
            PendingEvent::Event(Event::Error { message, .. }) if message.contains("worker failed")
        ));
    }

    #[tokio::test]
    async fn cancels_a_pending_operation() {
        let (cancel, mut cancelled) = watch::channel(false);
        tokio::spawn(async move {
            tokio::task::yield_now().await;
            cancel.send(true).unwrap();
        });

        let result = run_until_cancelled(&mut cancelled, std::future::pending::<()>()).await;

        assert!(result.is_none());
    }

    #[test]
    fn builds_a_rig_request_from_semantic_avante_input() {
        let request =
            completion_request(&provider("openai", Some(RouteInput::Chat)), prompt()).unwrap();

        assert_eq!(request.chat_history.len(), 2);
        assert_eq!(request.temperature, Some(0.5));
        assert_eq!(request.max_tokens, Some(42));
        assert_eq!(request.tools[0].name.as_str(), "lookup");
        assert_eq!(
            request.additional_params,
            Some(json!({"reasoning_context": {"mode": "preserve"}}))
        );
    }

    #[test]
    fn does_not_add_native_compaction_options() {
        let mut openai = provider("openai", Some(RouteInput::Responses));
        openai.model = "gpt-5.6-sol".to_owned();
        let request = completion_request(&openai, prompt()).unwrap();
        assert_eq!(
            request.additional_params.unwrap(),
            json!({"reasoning_context": {"mode": "preserve"}, "reasoning": {"summary": "auto"}})
        );
    }

    #[test]
    fn openai_protocols_omit_temperature_for_models_that_forbid_sampling() {
        for protocol in [
            ProtocolInput::Openai,
            ProtocolInput::Copilot,
            ProtocolInput::Azure,
        ] {
            for route in [RouteInput::Chat, RouteInput::Responses] {
                for (model, temperature) in [
                    ("gpt-5", None),
                    ("gpt-5-2025-08-07", None),
                    ("custom-chat-model", Some(0.5)),
                ] {
                    let mut provider = provider("private_openai", Some(route));
                    provider.protocol = protocol;
                    provider.model = model.to_owned();
                    let mut prompt = prompt();
                    prompt.additional_params.as_mut().unwrap()["top_p"] = json!(0.9);
                    let request = completion_request(&provider, prompt).unwrap();
                    assert_eq!(
                        request.temperature, temperature,
                        "{protocol:?} {route:?} {model}"
                    );
                    assert_eq!(request.options.top_p, temperature.map(|_| 0.9));
                }
            }
        }
    }

    #[test]
    fn claude_protocols_fit_sampling_to_the_provider_catalog() {
        for protocol in [ProtocolInput::Claude, ProtocolInput::Bedrock] {
            for (claude_model, bedrock_model, temperature) in [
                ("claude-opus-4-7", "anthropic.claude-opus-4-7", None),
                ("claude-opus-4-8", "us.anthropic.claude-opus-4-8", None),
                (
                    "us.anthropic.claude-opus-4-8-v1:0",
                    "us.anthropic.claude-opus-4-8-v1:0",
                    Some(0.5),
                ),
                (
                    "claude-haiku-4-5-20251001",
                    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
                    Some(0.5),
                ),
                (
                    "claude-sonnet-4-6",
                    "us.anthropic.claude-sonnet-4-6",
                    Some(0.5),
                ),
                ("custom-claude", "custom-claude", Some(0.5)),
            ] {
                let mut provider = provider("anthropic", None);
                provider.protocol = protocol;
                let model = if matches!(protocol, ProtocolInput::Bedrock) {
                    bedrock_model
                } else {
                    claude_model
                };
                provider.model = model.to_owned();
                let request = completion_request(&provider, prompt()).unwrap();
                assert_eq!(request.temperature, temperature, "{protocol:?} {model}");
            }
        }
    }

    #[test]
    fn azure_responses_preserves_explicit_reasoning() {
        for (model, supports_reasoning) in [
            ("gpt-5", true),
            ("gpt-6-sol", true),
            ("production-deployment", true),
        ] {
            for effort in ["none", "medium"] {
                for explicit in [false, true] {
                    let mut provider = provider("azure", Some(RouteInput::Responses));
                    provider.protocol = ProtocolInput::Azure;
                    provider.model = model.to_owned();
                    let mut prompt = prompt();
                    let mut params = json!({"reasoning_effort": effort});
                    if explicit {
                        params["reasoning"] = json!({"effort": "low"});
                    }
                    prompt.additional_params = Some(params);
                    let request = completion_request(&provider, prompt).unwrap();
                    let actual = request
                        .additional_params
                        .as_ref()
                        .and_then(|params| params.pointer("/reasoning/effort"))
                        .and_then(Value::as_str);
                    let expected = if explicit {
                        Some("low")
                    } else if supports_reasoning {
                        Some(effort)
                    } else {
                        None
                    };
                    assert_eq!(actual, expected, "{model} {effort} explicit={explicit}");
                }
            }
        }
    }

    #[test]
    fn azure_responses_rejects_api_versions_that_predate_the_route() {
        for version in ["2024-12-01-preview", "2025-02-01-preview"] {
            let error =
                azure_responses_uri("https://example.openai.azure.com", version).unwrap_err();
            assert!(error.contains("api_version"), "{error}");
            assert!(error.contains("v1"), "{error}");
            assert!(error.contains(version), "{error}");
        }
        for version in ["2025-03-01-preview", "2025-04-01-preview", "v1"] {
            assert!(azure_responses_uri("https://example.openai.azure.com", version).is_ok());
        }
        assert_eq!(
            azure_responses_uri(
                "https://example.openai.azure.com/openai/v1/",
                "2024-12-01-preview",
            )
            .unwrap()
            .to_string(),
            "https://example.openai.azure.com/openai/v1/responses"
        );
    }

    #[test]
    fn deepseek_responses_encodes_reasoning_effort_without_overriding_explicit_values() {
        let mut provider = provider("private_deepseek", Some(RouteInput::Responses));
        provider.dialect = Some("deepseek".to_owned());
        provider.model = "deepseek-flash".to_owned();
        for effort in ["none", "minimal", "low", "medium", "high", "xhigh", "max"] {
            for explicit in [false, true] {
                let mut prompt = prompt();
                let mut params = json!({"reasoning_effort": effort});
                if explicit {
                    params["reasoning"] = json!({"effort": "low"});
                }
                prompt.additional_params = Some(params);
                let wire = rig::providers::openai::wire::OpenAiWire::new(
                    configure_openai(&provider),
                    &provider.model,
                );
                let encoded = wire
                    .encode(
                        completion_request(&provider, prompt).unwrap(),
                        Mode::Streaming,
                    )
                    .unwrap();
                let Body::Bytes(bytes) = encoded.request.into_body() else {
                    panic!("JSON request")
                };
                let body: Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(
                    body["reasoning"]["effort"],
                    if explicit { "low" } else { effort },
                    "{body}"
                );
                assert!(body.get("reasoning_effort").is_none(), "{body}");
            }
        }
    }

    #[test]
    fn responses_requests_reasoning_summaries_without_overriding_explicit_choices() {
        for (model, route, params, expected) in [
            (
                "gpt-5.6-sol",
                RouteInput::Responses,
                json!({}),
                json!("auto"),
            ),
            (
                "gpt-5.6-sol",
                RouteInput::Responses,
                json!({"reasoning_effort": "high"}),
                json!("auto"),
            ),
            (
                "gpt-5.6-sol",
                RouteInput::Responses,
                json!({"reasoning": {"summary": "detailed", "effort": "low"}}),
                json!("detailed"),
            ),
            (
                "gpt-5.6-sol",
                RouteInput::Responses,
                json!({"reasoning": {"summary": null}}),
                Value::Null,
            ),
            (
                "gpt-5.6-sol",
                RouteInput::Responses,
                json!({"reasoning_effort": "none"}),
                Value::Null,
            ),
            (
                "gpt-5.6-sol",
                RouteInput::Responses,
                json!({"reasoning": {"effort": "none"}}),
                Value::Null,
            ),
            (
                "custom-chat-model",
                RouteInput::Responses,
                json!({}),
                Value::Null,
            ),
            (
                "custom-chat-model",
                RouteInput::Responses,
                json!({"reasoning_effort": "high"}),
                Value::Null,
            ),
            ("gpt-5.6-sol", RouteInput::Chat, json!({}), Value::Null),
        ] {
            let mut provider = provider("openai", Some(route));
            provider.model = model.to_owned();
            let mut prompt = prompt();
            let effort = params.get("reasoning_effort").cloned();
            prompt.additional_params = Some(params);
            let request = completion_request(&provider, prompt).unwrap();
            let http = rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(
                rig_reqwest::reqwest::Client::new(),
            ));
            let wire = configure_openai(&provider)
                .connect(http)
                .completion(model)
                .wire;
            let encoded = wire.encode(request, Mode::Streaming).unwrap();
            let Body::Bytes(bytes) = encoded.request.into_body() else {
                panic!("JSON request")
            };
            let body: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(body["reasoning"]["summary"], expected, "{body}");
            if expected == "auto"
                && let Some(effort) = effort
            {
                assert_eq!(body["reasoning"]["effort"], effort, "{body}");
            }
            if body["reasoning"]["summary"] == "detailed" {
                assert_eq!(body["reasoning"]["effort"], "low", "{body}");
            }
        }
    }

    #[test]
    fn removes_all_max_token_aliases_after_selecting_one() {
        let mut prompt = prompt();
        prompt.additional_params = Some(json!({
            "max_tokens": 10,
            "max_completion_tokens": 20,
            "max_output_tokens": 30,
            "custom": true
        }));

        let request =
            completion_request(&provider("mistral", Some(RouteInput::Chat)), prompt).unwrap();

        assert_eq!(request.max_tokens, Some(10));
        assert_eq!(request.additional_params, Some(json!({"custom": true})));
    }

    #[test]
    fn rejects_invalid_typed_generation_parameters() {
        for (params, expected) in [
            (json!({"temperature": "hot"}), "temperature"),
            (json!({"max_tokens": -1}), "max_tokens"),
            (json!({"reasoning_effort": true}), "reasoning_effort"),
        ] {
            let mut prompt = prompt();
            prompt.additional_params = Some(params);

            let error = completion_request(&provider("openai", Some(RouteInput::Chat)), prompt)
                .unwrap_err();

            assert!(error.contains(expected), "{error}");
        }
    }

    #[test]
    fn accepts_all_openai_reasoning_effort_levels() {
        for (effort, expected) in [("xhigh", Effort::XHigh), ("max", Effort::Max)] {
            let mut prompt = prompt();
            prompt.additional_params = Some(json!({"reasoning_effort": effort}));

            let request =
                completion_request(&provider("openai", Some(RouteInput::Chat)), prompt).unwrap();

            assert_eq!(request.options.reasoning, Some(Reasoning::Effort(expected)));
        }
    }

    #[test]
    fn rejects_unknown_protocol_at_the_lua_boundary() {
        let error = serde_json::from_value::<Input>(json!({
            "provider": {
                "name": "custom",
                "protocol": "unknown",
                "model": "test-model"
            },
            "prompt": {
                "systemPrompt": "system"
            }
        }))
        .unwrap_err();

        assert!(error.to_string().contains("unknown variant `unknown`"));
    }

    #[test]
    fn moonshot_generation_options_use_the_provider_mapping() {
        for model in [rig::providers::moonshot::KIMI_K3, "kimi-k2.6"] {
            let mut provider = provider("private_moonshot", Some(RouteInput::Chat));
            provider.dialect = Some("moonshot".to_owned());
            provider.model = model.to_owned();
            let mut prompt = prompt();
            prompt.additional_params =
                Some(json!({"temperature": 0.75, "max_completion_tokens": 42}));
            let request = completion_request(&provider, prompt).unwrap();
            assert_eq!(request.temperature, Some(0.75));
            assert_eq!(request.max_tokens, Some(42));
            assert_eq!(request.additional_params, None);
        }
    }

    #[test]
    fn azure_preserves_an_explicit_completion_cap_for_unknown_deployments() {
        let mut provider = provider("azure", Some(RouteInput::Chat));
        provider.protocol = ProtocolInput::Azure;
        provider.deployment = Some("production-deployment".to_owned());
        let request = completion_request(&provider, prompt()).unwrap();
        assert_eq!(request.model.as_deref(), Some("test-model"));
        assert_eq!(request.max_tokens, None);
        assert_eq!(
            request.additional_params.unwrap()["max_completion_tokens"],
            42
        );
    }

    #[test]
    fn rejects_missing_or_blank_azure_deployments() {
        for deployment in [None, Some(""), Some("  ")] {
            let mut provider = provider("azure", Some(RouteInput::Chat));
            provider.protocol = ProtocolInput::Azure;
            provider.deployment = deployment.map(str::to_owned);
            let input = Input {
                provider,
                prompt: prompt(),
            };
            assert_eq!(input.validate().unwrap_err(), "Azure deployment is not set");
        }
    }

    #[test]
    fn rejects_missing_bedrock_settings_before_building_a_model() {
        let mut provider = provider("bedrock", None);
        provider.protocol = ProtocolInput::Bedrock;
        provider
            .headers
            .insert("invalid header".to_owned(), "x".to_owned());

        let error = Input {
            provider,
            prompt: prompt(),
        }
        .validate()
        .unwrap_err();
        assert_eq!(error, "Bedrock settings are missing");
    }

    #[test]
    fn rejects_configuration_not_supported_by_sdk_transports() {
        let mut vertex = provider("vertex", None);
        vertex.protocol = ProtocolInput::Vertex;
        vertex.vertex = Some(VertexInput::default());
        vertex.base_url = Some("https://vertex.example.test".to_owned());
        let error = Input {
            provider: vertex,
            prompt: prompt(),
        }
        .validate()
        .unwrap_err();
        assert!(error.contains("endpoint"), "{error}");

        let mut bedrock = provider("bedrock", None);
        bedrock.protocol = ProtocolInput::Bedrock;
        bedrock.bedrock = Some(BedrockInput::default());
        bedrock.headers.insert("x-test".to_owned(), "x".to_owned());
        let error = Input {
            provider: bedrock,
            prompt: prompt(),
        }
        .validate()
        .unwrap_err();
        assert!(error.contains("headers"), "{error}");
    }

    #[test]
    fn rejects_invalid_explicit_dialects() {
        let mut custom = provider("custom", None);
        custom.dialect = Some("not-registered".to_owned());
        let error = Input {
            provider: custom,
            prompt: prompt(),
        }
        .validate()
        .unwrap_err();
        assert!(error.contains("unknown"), "{error}");

        let mut anthropic = provider("anthropic", None);
        anthropic.dialect = Some("mistral".to_owned());
        let error = Input {
            provider: anthropic,
            prompt: prompt(),
        }
        .validate()
        .unwrap_err();
        assert!(error.contains("OpenAI-compatible"), "{error}");
    }

    #[tokio::test]
    async fn dropping_a_native_request_cancels_its_worker() {
        let (cancel, mut cancelled) = watch::channel(false);
        let request = NativeRequest {
            events: Events::default(),
            cancel,
            tool_arguments: HashMap::new(),
        };

        drop(request);

        assert!(cancelled.changed().await.is_ok());
        assert!(*cancelled.borrow());
    }

    #[test]
    fn rig_openai_wire_encodes_messages_tools_and_custom_fields() {
        let wire = OpenAIConfig::with_key(&OPENAI, "token").chat("test-model");
        let encoded = wire
            .encode(
                completion_request(&provider("openai", Some(RouteInput::Chat)), prompt()).unwrap(),
                Mode::Streaming,
            )
            .unwrap();
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("OpenAI request body must be JSON")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();

        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["content"], "hello");
        assert_eq!(body["tools"][0]["function"]["name"], "lookup");
        assert_eq!(body["reasoning_context"], json!({"mode": "preserve"}));
    }

    #[test]
    fn mistral_endpoint_does_not_duplicate_the_api_version() {
        let mut provider = provider("private_mistral", Some(RouteInput::Chat));
        provider.dialect = Some("mistral".to_owned());
        provider.base_url = Some("https://api.mistral.ai/v1".to_owned());
        let config = configure_openai(&provider);
        assert_eq!(config.dialect.name, "mistral");
        let wire = config.chat("test-model");
        let encoded = wire
            .encode(
                completion_request(&provider, prompt()).unwrap(),
                Mode::Streaming,
            )
            .unwrap();

        assert_eq!(
            encoded.request.uri().to_string(),
            "https://api.mistral.ai/v1/chat/completions"
        );
    }

    #[test]
    fn xai_endpoints_do_not_duplicate_the_api_version() {
        for base_url in [
            "https://api.x.ai",
            "https://api.x.ai/v1",
            "https://api.x.ai/v1/",
        ] {
            for (route, path) in [
                (RouteInput::Chat, "/v1/chat/completions"),
                (RouteInput::Responses, "/v1/responses"),
            ] {
                let mut provider = provider("private_xai", Some(route));
                provider.dialect = Some("xai".to_owned());
                provider.model = "grok-4.7".to_owned();
                provider.base_url = Some(base_url.to_owned());
                let wire = rig::providers::openai::wire::OpenAiWire::new(
                    configure_openai(&provider),
                    &provider.model,
                );
                let encoded = wire
                    .encode(
                        completion_request(&provider, prompt()).unwrap(),
                        Mode::Streaming,
                    )
                    .unwrap();
                assert_eq!(
                    encoded.request.uri().to_string(),
                    format!("https://api.x.ai{path}")
                );
            }
        }
    }

    #[test]
    fn copilot_honors_explicit_routes_and_keeps_editor_headers() {
        for (model, route, path) in [
            ("gpt-5.4-mini", RouteInput::Responses, "/responses"),
            ("claude-haiku-4.5", RouteInput::Chat, "/chat/completions"),
        ] {
            let mut provider = provider("copilot", Some(route));
            provider.protocol = ProtocolInput::Copilot;
            provider.model = model.to_owned();
            let wire = rig::providers::openai::wire::OpenAiWire::new(
                configure_openai(&provider),
                &provider.model,
            );
            let encoded = wire
                .encode(
                    completion_request(&provider, prompt()).unwrap(),
                    Mode::Streaming,
                )
                .unwrap();

            assert_eq!(encoded.request.uri().path(), path);
            assert!(encoded.request.headers().contains_key("editor-version"));
            assert!(
                encoded
                    .request
                    .headers()
                    .contains_key("copilot-integration-id")
            );
        }
    }

    #[test]
    fn responses_previous_id_sends_only_the_tool_result() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: json!([{
                        "type": "tool_use",
                        "id": "call-1",
                        "name": "lookup",
                        "input": {"query": "x"}
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: json!([{
                        "type": "tool_result",
                        "tool_use_id": "call-1",
                        "content": "answer"
                    }]),
                },
            ],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: Some(json!({"previous_response_id": "resp_1"})),
        };
        let http = rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(
            rig_reqwest::reqwest::Client::new(),
        ));
        let wire = OpenAIConfig::with_key(&OPENAI, "token")
            .with_route(Route::Responses)
            .connect(http)
            .completion("test-model")
            .wire;
        let encoded = wire
            .encode(
                completion_request(&provider("openai", Some(RouteInput::Responses)), prompt)
                    .unwrap(),
                Mode::Streaming,
            )
            .unwrap();
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("Responses request body must be JSON")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();

        assert_eq!(body["previous_response_id"], "resp_1");
        assert_eq!(body["input"].as_array().unwrap().len(), 1, "{body}");
        assert_eq!(body["input"][0]["type"], "function_call_output", "{body}");
        assert_eq!(body["input"][0]["call_id"], "call-1", "{body}");
    }

    #[test]
    fn responses_previous_id_keeps_real_results_and_synthetic_tool_calls() {
        let mut prompt = prompt();
        prompt.messages = serde_json::from_value(json!([
            {"role": "assistant", "content": [{"type": "tool_use", "id": "edit-1", "name": "edit_file", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "edit-1", "content": "edited"}]},
            {"role": "assistant", "is_dummy": true, "content": "Viewing the updated file"},
            {"role": "assistant", "is_dummy": true, "content": [{"type": "tool_use", "id": "view-1", "name": "view", "input": {}}]},
            {"role": "user", "is_dummy": true, "content": [{"type": "tool_result", "tool_use_id": "view-1", "content": "updated file"}]}
        ])).unwrap();
        prompt.additional_params = Some(json!({"previous_response_id": "resp_1"}));
        for adjacent in [false, true] {
            let mut prompt = prompt.clone();
            if adjacent {
                prompt.messages.swap(1, 2);
            }
            let request =
                completion_request(&provider("openai", Some(RouteInput::Responses)), prompt)
                    .unwrap();
            assert!(
                request
                    .chat_history
                    .iter()
                    .any(|message| matches!(message.as_ref(),
                        Message::User { content } if content.iter().any(|item| matches!(item,
                            UserContent::ToolResult(result) if result.call.to_string() == "edit-1"
                        ))
                    )),
                "missing edit result: {:?}",
                request.chat_history
            );
            assert!(
                request
                    .chat_history
                    .iter()
                    .any(|message| matches!(message.as_ref(),
                        Message::Assistant(turn) if turn.content.iter().any(|item| matches!(item,
                            AssistantContent::ToolCall(call) if call.id.to_string() == "view-1"
                        ))
                    )),
                "missing synthetic call: {:?}",
                request.chat_history
            );
            assert!(
                request
                    .chat_history
                    .iter()
                    .any(|message| matches!(message.as_ref(),
                        Message::Assistant(turn) if turn.content.iter().any(|item| matches!(item,
                            AssistantContent::Text(text) if text.text == "Viewing the updated file"
                        ))
                    ))
            );
        }
    }

    #[test]
    fn responses_previous_id_sends_only_the_latest_tool_results() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: json!([{
                        "type": "tool_use",
                        "id": "call-1",
                        "name": "lookup",
                        "input": {"query": "first"}
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: json!([{
                        "type": "tool_result",
                        "tool_use_id": "call-1",
                        "content": "first answer"
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: json!([{
                        "type": "tool_use",
                        "id": "call-2",
                        "name": "lookup",
                        "input": {"query": "second"}
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: json!([{
                        "type": "tool_result",
                        "tool_use_id": "call-2",
                        "content": "second answer"
                    }]),
                },
            ],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: Some(json!({"previous_response_id": "resp_2"})),
        };
        let http = rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(
            rig_reqwest::reqwest::Client::new(),
        ));
        let wire = OpenAIConfig::with_key(&OPENAI, "token")
            .with_route(Route::Responses)
            .connect(http)
            .completion("test-model")
            .wire;
        let encoded = wire
            .encode(
                completion_request(&provider("openai", Some(RouteInput::Responses)), prompt)
                    .unwrap(),
                Mode::Streaming,
            )
            .unwrap();
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("Responses request body must be JSON")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();

        assert_eq!(body["input"].as_array().unwrap().len(), 1, "{body}");
        assert_eq!(body["input"][0]["call_id"], "call-2", "{body}");
    }

    #[test]
    fn responses_previous_id_keeps_user_text_after_a_tool_result() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: json!([{
                        "type": "tool_use",
                        "id": "call-1",
                        "name": "lookup",
                        "input": {"query": "x"}
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: json!([{
                        "type": "tool_result",
                        "tool_use_id": "call-1",
                        "content": "answer"
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: Value::String("also explain why".to_owned()),
                },
            ],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: Some(json!({"previous_response_id": "resp_1"})),
        };
        let http = rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(
            rig_reqwest::reqwest::Client::new(),
        ));
        let wire = OpenAIConfig::with_key(&OPENAI, "token")
            .with_route(Route::Responses)
            .connect(http)
            .completion("test-model")
            .wire;
        let encoded = wire
            .encode(
                completion_request(&provider("openai", Some(RouteInput::Responses)), prompt)
                    .unwrap(),
                Mode::Streaming,
            )
            .unwrap();
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("Responses request body must be JSON")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();

        assert_eq!(body["previous_response_id"], "resp_1");
        assert!(body.to_string().contains("also explain why"), "{body}");
    }

    #[test]
    fn responses_previous_id_keeps_an_ordinary_user_message() {
        let mut prompt = prompt();
        prompt.additional_params = Some(json!({"previous_response_id": "resp_1"}));
        let http = rig::http_client::DynHttpClient::new(rig_reqwest::ReqwestClient::from(
            rig_reqwest::reqwest::Client::new(),
        ));
        let wire = OpenAIConfig::with_key(&OPENAI, "token")
            .with_route(Route::Responses)
            .connect(http)
            .completion("test-model")
            .wire;
        let encoded = wire
            .encode(
                completion_request(&provider("openai", Some(RouteInput::Responses)), prompt)
                    .unwrap(),
                Mode::Streaming,
            )
            .unwrap();
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("Responses request body must be JSON")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();

        assert_eq!(body["previous_response_id"], "resp_1");
        assert_eq!(body["input"][0]["role"], "user", "{body}");
    }

    #[test]
    fn responses_previous_id_ignores_stale_tool_results_for_a_new_user_message() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: json!([{
                        "type": "tool_use",
                        "id": "call-1",
                        "name": "lookup",
                        "input": {"query": "old"}
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: json!([{
                        "type": "tool_result",
                        "tool_use_id": "call-1",
                        "content": "old answer"
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: Value::String("finished".to_owned()),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: Value::String("new question".to_owned()),
                },
            ],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: Some(json!({"previous_response_id": "resp_2"})),
        };
        let request =
            completion_request(&provider("openai", Some(RouteInput::Responses)), prompt).unwrap();

        assert!(matches!(
            request.chat_history.last().map(Arc::as_ref),
            Some(Message::User { .. })
        ));
    }

    #[test]
    fn converts_tool_calls_and_results_to_rig_history() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "assistant".to_owned(),
                    content: json!([{
                        "type": "tool_use",
                        "id": "call-1",
                        "name": "lookup",
                        "input": {"query": "x"}
                    }]),
                },
                AvanteMessage {
                    is_dummy: false,
                    phase: None,
                    native: None,
                    origin: None,
                    role: "user".to_owned(),
                    content: json!([{
                        "type": "tool_result",
                        "tool_use_id": "call-1",
                        "content": "answer"
                    }]),
                },
            ],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: None,
        };
        let history = messages(&prompt, &provider("openai", Some(RouteInput::Chat))).unwrap();

        assert!(matches!(
            &history[1],
            Message::Assistant(message)
                if matches!(&message.content[0], AssistantContent::ToolCall(call) if call.function.name.as_str() == "lookup")
        ));
        assert!(matches!(
            &history[2],
            Message::User { content }
                if matches!(&content[0], UserContent::ToolResult(result) if result.name.as_str() == "lookup")
        ));
    }

    #[test]
    fn deepseek_replays_reasoning_with_its_tool_call() {
        let mut prompt = prompt();
        prompt.messages = vec![
            AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "user".to_owned(),
                content: Value::String("hello".to_owned()),
            },
            AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "assistant".to_owned(),
                content: json!([{
                    "type": "thinking",
                    "thinking": "plan",
                    "signature": ""
                }]),
            },
            AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "assistant".to_owned(),
                content: json!([{
                    "type": "tool_use",
                    "id": "call-1",
                    "name": "lookup",
                    "input": {"query": "rust"}
                }]),
            },
            AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "user".to_owned(),
                content: json!([{
                    "type": "tool_result",
                    "tool_use_id": "call-1",
                    "content": "answer"
                }]),
            },
        ];
        let mut provider = provider("deepseek", Some(RouteInput::Chat));
        provider.dialect = Some("deepseek".to_owned());
        provider.model = "deepseek-flash".to_owned();
        let wire = configure_openai(&provider).chat(&provider.model);
        let mut request = completion_request(&provider, prompt).unwrap();
        let history: Vec<_> = request
            .chat_history
            .iter()
            .map(|message| message.as_ref().clone())
            .collect();
        request.chat_history = rig::completion::history::adapt(&history, &wire)
            .into_iter()
            .map(Arc::new)
            .collect();
        let encoded = wire.encode(request, Mode::Streaming).unwrap();
        let Body::Bytes(bytes) = encoded.request.into_body() else {
            panic!("DeepSeek request body must be JSON")
        };
        let body: Value = serde_json::from_slice(&bytes).unwrap();

        let assistant = &body["messages"][2];
        assert_eq!(assistant["reasoning_content"], "plan", "{body}");
        assert_eq!(
            assistant["tool_calls"][0]["function"]["name"], "lookup",
            "{body}"
        );
    }

    #[test]
    fn preserves_anthropic_thinking_signature_for_tool_continuation() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "assistant".to_owned(),
                content: json!([{
                    "type": "thinking",
                    "thinking": "plan",
                    "signature": "signed"
                }]),
            }],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: None,
        };
        let history = messages(&prompt, &provider("anthropic", None)).unwrap();
        let Message::Assistant(message) = &history[1] else {
            panic!("assistant history")
        };

        assert_eq!(
            message.origin.as_ref().unwrap().api.to_string(),
            "anthropic.messages"
        );
        assert_eq!(message.origin.as_ref().unwrap().provider, "anthropic");
        assert!(matches!(
            &message.content[0],
            AssistantContent::Reasoning(reasoning)
                if reasoning.text == "plan" && message.content[0].native_item() == Some(&json!({
                    "type": "thinking",
                    "thinking": "plan",
                    "signature": "signed"
                }))
        ));
    }

    #[test]
    fn preserves_responses_reasoning_item_for_tool_continuation() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "assistant".to_owned(),
                content: json!([{
                    "type": "reasoning",
                    "id": "rs_1",
                    "encrypted_content": "enc",
                    "summary": [{"type": "summary_text", "text": "plan"}]
                }]),
            }],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: None,
        };
        let provider = provider("openai", Some(RouteInput::Responses));
        let history = messages(&prompt, &provider).unwrap();
        let Message::Assistant(message) = &history[1] else {
            panic!("assistant history")
        };

        assert_eq!(
            message.origin.as_ref().unwrap().api.to_string(),
            "openai.responses"
        );
        assert_eq!(message.origin.as_ref().unwrap().provider, "openai");
        assert!(matches!(
            &message.content[0],
            AssistantContent::Reasoning(reasoning)
                if reasoning.text == "plan" && message.content[0].native_item().is_some()
        ));
    }

    #[test]
    fn keeps_native_fingerprints_through_the_avante_history_projection() {
        for content in [
            AssistantContent::text("plain answer"),
            AssistantContent::Reasoning(MessageReasoning {
                text: String::new(),
                redacted: true,
                native: None,
            })
            .with_native(json!({"reasoningContent": {"redactedContent": "Y2lwaGVy"}})),
            AssistantContent::reasoning("plan")
                .with_native(json!({"type": "thinking", "signature": "sig"})),
            AssistantContent::reasoning("plan")
                .with_native(json!({"thought": true, "thoughtSignature": "sig"})),
            AssistantContent::reasoning("")
                .with_native(json!({"type": "reasoning", "encrypted_content": "cipher"})),
            AssistantContent::text("answer")
                .with_native(json!({"type": "message", "id": "msg_1", "phase": "final_answer"})),
            AssistantContent::tool_call("call-1", ToolName::new("lookup").unwrap(), json!({}))
                .with_native(json!({"thoughtSignature": "tool-sig"})),
            AssistantContent::tool_call("", ToolName::new("lookup").unwrap(), json!({}))
                .with_native(json!({"thoughtSignature": "local-tool-sig"})),
        ] {
            let Event::ContentEnd {
                content: projected,
                native,
                ..
            } = content_end(0, content.clone(), "test-turn", 0).unwrap()
            else {
                panic!("content end")
            };
            let mut prompt = prompt();
            prompt.messages = vec![AvanteMessage {
                is_dummy: false,
                phase: None,
                role: "assistant".to_owned(),
                content: projected,
                native,
                origin: Some(Origin::new(
                    "gemini.generate_content",
                    "gcp.gemini",
                    "test-model",
                )),
            }];
            let history = messages(&prompt, &provider("openai", Some(RouteInput::Chat))).unwrap();
            let Message::Assistant(message) = &history[1] else {
                panic!("assistant history")
            };
            assert_eq!(message.content[0].native_item(), content.native_item());
            assert_eq!(message.origin.as_ref().unwrap().provider, "gcp.gemini");
        }
    }

    #[test]
    fn tool_results_reuse_the_full_restored_call_identity() {
        let content = AssistantContent::tool_call("", ToolName::new("lookup").unwrap(), json!({}));
        let AssistantContent::ToolCall(call) = &content else {
            panic!("tool call")
        };
        let expected_id = call.id.clone();
        let Event::ContentEnd {
            content, native, ..
        } = content_end(0, content, "turn", 0).unwrap()
        else {
            panic!("content end")
        };
        let mut prompt = prompt();
        prompt.messages = serde_json::from_value(json!([
            {"role": "assistant", "content": content, "native": native},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": expected_id.to_string(), "content": "answer"}]}
        ])).unwrap();
        let history = messages(&prompt, &provider("openai", Some(RouteInput::Chat))).unwrap();
        let Message::User { content } = history.last().unwrap() else {
            panic!("tool result")
        };
        let UserContent::ToolResult(result) = &content[0] else {
            panic!("tool result")
        };
        assert_eq!(result.call, expected_id);
        assert_eq!(result.name.as_str(), "lookup");
    }

    #[test]
    fn restores_final_content_order_without_mixing_turns() {
        let mut prompt = prompt();
        for (turn, order, text) in [
            ("first-turn", 1, "second"),
            ("first-turn", 0, "first"),
            ("second-turn", 1, "fourth"),
            ("second-turn", 0, "third"),
        ] {
            let Event::ContentEnd {
                content, native, ..
            } = content_end(order, AssistantContent::text(text), turn, order).unwrap()
            else {
                panic!("content end")
            };
            prompt.messages.push(AvanteMessage {
                is_dummy: false,
                phase: None,
                role: "assistant".to_owned(),
                content,
                native,
                origin: Some(Origin::new("openai.responses", "openai", "test-model")),
            });
        }
        let history = messages(&prompt, &provider("openai", Some(RouteInput::Responses))).unwrap();
        let Message::Assistant(message) = &history[2] else {
            panic!("assistant history")
        };
        assert_eq!(
            message.content,
            ["first", "second", "third", "fourth"].map(AssistantContent::text)
        );
    }

    #[test]
    fn migrates_legacy_responses_phases_only_for_responses() {
        for phase in ["commentary", "final_answer"] {
            let mut prompt = prompt();
            prompt.messages.push(
                serde_json::from_value(json!({
                    "role": "assistant", "content": "answer", "phase": phase,
                }))
                .unwrap(),
            );
            for (protocol, route) in [
                ("openai", Some(RouteInput::Responses)),
                ("openai", Some(RouteInput::Chat)),
                ("anthropic", None),
            ] {
                let history = messages(&prompt, &provider(protocol, route)).unwrap();
                let Message::Assistant(message) = &history[2] else {
                    panic!("assistant history")
                };
                if matches!(route, Some(RouteInput::Responses)) {
                    let item = message.content[0].native_item().unwrap();
                    assert_eq!(item["phase"], phase);
                    assert_eq!(item["content"][0]["text"], "answer");
                    assert_eq!(
                        message.origin.as_ref().unwrap().api,
                        "openai.responses".into()
                    );
                } else {
                    assert!(message.content[0].native_item().is_none());
                    assert!(message.origin.is_none());
                }
            }
        }
    }

    #[test]
    fn loads_native_metadata_saved_without_ordering_fields() {
        let content = AssistantContent::text("answer")
            .with_native(json!({"type": "message", "id": "msg-1", "phase": "final_answer"}));
        let mut prompt = prompt();
        prompt.messages.push(AvanteMessage {
            is_dummy: false,
            phase: Some("commentary".to_owned()),
            role: "assistant".to_owned(),
            content: json!("answer"),
            native: Some(
                json!({"item": content.native_item().unwrap(), "fingerprint": content.fingerprint()})
                    .to_string(),
            ),
            origin: Some(Origin::new("openai.responses", "openai", "test-model")),
        });
        let history = messages(&prompt, &provider("openai", Some(RouteInput::Responses))).unwrap();
        let Message::Assistant(message) = &history[2] else {
            panic!("assistant history")
        };
        assert_eq!(message.content[0].native_item(), content.native_item());
    }

    #[test]
    fn editing_content_or_call_ids_invalidates_native_metadata() {
        for content in [
            AssistantContent::text("answer")
                .with_native(json!({"text": "answer", "thoughtSignature": "sig"})),
            AssistantContent::tool_call("", ToolName::new("lookup").unwrap(), json!({}))
                .with_native(json!({"thoughtSignature": "sig"})),
        ] {
            let Event::ContentEnd {
                mut content,
                native,
                ..
            } = content_end(0, content, "test-turn", 0).unwrap()
            else {
                panic!("content end")
            };
            match &mut content {
                Value::String(text) => *text = "edited".to_owned(),
                Value::Object(fields) => {
                    fields.insert("id".to_owned(), json!("edited-id"));
                }
                _ => unreachable!(),
            }
            let mut prompt = prompt();
            prompt.messages = vec![AvanteMessage {
                is_dummy: false,
                phase: None,
                role: "assistant".to_owned(),
                content,
                native,
                origin: Some(Origin::new(
                    "gemini.generate_content",
                    "gcp.gemini",
                    "test-model",
                )),
            }];
            let history = messages(&prompt, &provider("openai", Some(RouteInput::Chat))).unwrap();
            let Message::Assistant(message) = &history[1] else {
                panic!("assistant history")
            };
            assert!(message.content[0].native_item().is_none());
        }
    }

    #[test]
    fn provider_name_does_not_select_the_openai_dialect() {
        let custom = configure_openai(&provider("deepseek", Some(RouteInput::Chat)));
        assert_eq!(custom.dialect.name, "openai");

        let mut explicit = provider("renamed-provider", Some(RouteInput::Chat));
        explicit.dialect = Some("deepseek".to_owned());
        assert_eq!(configure_openai(&explicit).dialect.name, "deepseek");
    }

    #[test]
    fn rejects_tool_results_without_their_call() {
        let prompt = PromptInput {
            system_prompt: "system".to_owned(),
            messages: vec![AvanteMessage {
                is_dummy: false,
                phase: None,
                native: None,
                origin: None,
                role: "user".to_owned(),
                content: json!([{
                    "type": "tool_result",
                    "tool_use_id": "missing",
                    "content": "answer"
                }]),
            }],
            image_paths: Vec::new(),
            tools: Vec::new(),
            turn_id: "test-turn".to_owned(),
            additional_params: None,
        };

        assert_eq!(
            messages(&prompt, &provider("openai", Some(RouteInput::Chat))).unwrap_err(),
            "tool result missing has no preceding tool call"
        );
    }

    #[test]
    fn preserves_usage_details_and_distinguishes_unreported_counters_from_zero() {
        let usage = rig::completion::Usage::new()
            .input_tokens(100)
            .output_tokens(20)
            .total_tokens(120)
            .cached_input_tokens(60)
            .cache_creation_input_tokens(0)
            .tool_use_prompt_tokens(5)
            .reasoning_tokens(8);
        assert_eq!(
            serde_json::to_value(Usage::from(usage)).unwrap(),
            json!({
                "prompt_tokens": 100,
                "completion_tokens": 20,
                "total_tokens": 120,
                "cached_input_tokens": 60,
                "cache_creation_input_tokens": 0,
                "tool_use_prompt_tokens": 5,
                "reasoning_tokens": 8,
            })
        );
        assert_eq!(
            serde_json::to_value(Usage::from(rig::completion::Usage::new())).unwrap(),
            json!({})
        );
    }

    #[test]
    fn serializes_lua_event_keys_in_the_expected_case() {
        let event = serde_json::to_value(Event::Done {
            reason: DoneReason::Complete,
            usage: Box::new(Usage {
                prompt: Some(1),
                completion: Some(2),
                ..Usage::default()
            }),
            response_id: Some("resp_1".to_owned()),
            origin: Origin::new("openai.responses", "openai", "test-model"),
        })
        .unwrap();

        assert_eq!(event["usage"]["prompt_tokens"], 1);
        assert_eq!(event["responseId"], "resp_1");
    }

    type Frame = vertexai::model::GenerateContentResponse;
    type FrameSender = mpsc::Sender<vertexai::Result<Frame>>;

    #[derive(Debug)]
    struct ScriptedService(Mutex<Option<mpsc::Receiver<vertexai::Result<Frame>>>>);

    impl vertexai::stub::PredictionService for ScriptedService {
        fn stream_generate_content(
            &self,
            request: vertexai::model::GenerateContentRequest,
            _options: google_cloud_gax::options::RequestOptions,
        ) -> impl Future<Output = vertexai::Result<ResponseStream<Frame>>> {
            assert_eq!(
                request.model,
                "projects/test-project/locations/us-central1/publishers/google/models/gemini-2.5-flash"
            );
            let receiver = self.0.lock().unwrap().take().expect("one SDK request");
            std::future::ready(Ok(ResponseStream::from(receiver)))
        }
    }

    fn model() -> (DynModel<Completion>, FrameSender) {
        let (sender, receiver) = mpsc::channel(2);
        let service = vertexai::client::PredictionService::from_stub(ScriptedService(Mutex::new(
            Some(receiver),
        )));
        let client = rig_vertexai::VertexAi::builder()
            .with_project("test-project")
            .with_location("us-central1")
            .with_prediction_service(service)
            .build()
            .unwrap();
        let model = rig::Model::new(
            rig_vertexai::completion::GenerateContent::new("gemini-2.5-flash"),
            crate::StreamingVertex(client),
        );
        (model.erase(), sender)
    }

    fn text_frame(text: &str, finished: bool) -> Frame {
        let content = vertexai::model::Content::new()
            .set_role("model")
            .set_parts([vertexai::model::Part::new().set_text(text)]);
        let mut candidate = vertexai::model::Candidate::new().set_content(content);
        if finished {
            candidate = candidate.set_finish_reason(vertexai::model::candidate::FinishReason::Stop);
        }
        Frame::new().set_candidates([candidate])
    }

    async fn next_text(stream: &mut CompletionStream) -> String {
        tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(item) = stream.next().await {
                if let Item::Event(StreamEvent::Text { text, .. }) = item.expect("streaming frame")
                {
                    return text;
                }
            }
            panic!("reply ended before its text arrived");
        })
        .await
        .expect("first text must arrive while the SDK stream remains open")
    }

    #[tokio::test]
    async fn vertex_delivers_first_frame_before_second_arrives() {
        let (model, sender) = model();
        sender.send(Ok(text_frame("first", false))).await.unwrap();
        let mut stream = model.stream(CompletionRequest::new("hello")).unwrap();

        assert_eq!(next_text(&mut stream).await, "first");
        assert!(!sender.is_closed());

        sender.send(Ok(text_frame("second", true))).await.unwrap();
        drop(sender);
        assert_eq!(next_text(&mut stream).await, "second");
        while let Some(item) = stream.next().await {
            item.expect("remaining frames");
        }
        let response = stream.finish().await.expect("completed streaming reply");
        assert_eq!(response.stop(), StopReason::Stop);
        assert_eq!(
            response.raw["candidates"][0]["content"]["parts"][0]["text"],
            "firstsecond"
        );
        assert_eq!(
            response
                .choice
                .iter()
                .map(AssistantContent::canonical)
                .collect::<Vec<_>>(),
            vec![AssistantContent::Text(rig::message::Text::new(
                "firstsecond"
            ))]
        );
    }

    #[tokio::test]
    async fn vertex_dropping_reply_cancels_sdk_stream() {
        let (model, sender) = model();
        sender.send(Ok(text_frame("first", false))).await.unwrap();
        let mut stream = model.stream(CompletionRequest::new("hello")).unwrap();
        assert_eq!(next_text(&mut stream).await, "first");

        drop(stream);
        assert!(sender.is_closed(), "cancellation must drop the SDK stream");
    }

    #[tokio::test]
    async fn vertex_propagates_mid_stream_failure() {
        let (model, sender) = model();
        sender.send(Ok(text_frame("first", false))).await.unwrap();
        let mut stream = model.stream(CompletionRequest::new("hello")).unwrap();
        assert_eq!(next_text(&mut stream).await, "first");
        sender
            .send(Err(google_cloud_gax::error::Error::io(
                std::io::Error::other("vertex stream interrupted"),
            )))
            .await
            .unwrap();
        drop(sender);

        let error = tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(item) = stream.next().await {
                if let Err(error) = item {
                    return error;
                }
            }
            panic!("interrupted SDK stream must report an error");
        })
        .await
        .expect("stream error arrives promptly");
        assert!(error.to_string().contains("vertex stream interrupted"));
        assert!(stream.finish().await.is_err());
    }
}
