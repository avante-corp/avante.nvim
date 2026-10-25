//! Provider configuration and compatibility with Rig 0.45.
//! Keep protocol workarounds here so upstream support can replace them without changing the Lua bridge.

use super::{AuthInput, ProtocolInput, ProviderInput, RouteInput};
use rig::Model;
use rig::catalog::ModelFacts;
use rig::completion::CompletionRequest;
use rig::completion::options::{Effort, OnUnsupported, Reasoning};
use rig::driver::{DynModel, Exchange, Opened, Opening, Transport};
use rig::error::ProviderError;
use rig::http_client::DynHttpClient;
use rig::operation::Completion;
use rig::providers::anthropic::AnthropicConfig;
use rig::providers::cohere::{ChatRoute, CohereConfig};
use rig::providers::gemini::{GeminiConfig, completion::GenerateContent as GeminiGenerateContent};
use rig::providers::ollama::OllamaConfig;
use rig::providers::openai::wire::{AZURE, Auth, OPENAI, OpenAiWire, by_name};
use rig::providers::openai::{OpenAIConfig, Route};
use rig::wire::{Body, Encoded, Wire, WireFrame};
use rig_vertexai::completion::{GenerateContent, rest_chunk};
use serde_json::{Map, Value};

fn trim_suffix(value: &str, suffix: &str) -> String {
    value
        .trim_end_matches('/')
        .strip_suffix(suffix)
        .unwrap_or(value.trim_end_matches('/'))
        .trim_end_matches('/')
        .to_owned()
}

pub(super) fn configure_openai(provider: &ProviderInput) -> OpenAIConfig {
    let api_key = provider.api_key.clone().unwrap_or_default();
    let dialect = if matches!(provider.protocol, ProtocolInput::Copilot) {
        &rig::providers::copilot::wire::DIALECT
    } else {
        by_name(provider.dialect.as_deref().unwrap_or("openai"))
            .expect("OpenAI dialect was validated")
    };
    let mut config = OpenAIConfig::with_key(dialect, api_key);
    if let Some(base_url) = &provider.base_url {
        let base_url = if matches!(dialect.name, "mistral" | "xai") {
            trim_suffix(base_url, "/v1")
        } else {
            base_url.to_owned()
        };
        config = config.with_base_url(base_url);
    }
    config = config.with_route(match provider.route.unwrap_or(RouteInput::Chat) {
        RouteInput::Chat => Route::Chat,
        RouteInput::Responses => Route::Responses,
    });
    if provider.api_key.as_deref().unwrap_or_default().is_empty() {
        config = config.with_auth(Auth::OptionalBearer);
    }
    config
}

pub(super) fn build_http_model(
    provider: &ProviderInput,
    http: rig::http_client::DynHttpClient,
) -> Result<DynModel<Completion>, String> {
    let model = provider.model.as_str();
    let key = provider.api_key.clone().unwrap_or_default();
    match provider.protocol {
        ProtocolInput::Bedrock | ProtocolInput::Vertex => unreachable!(),
        ProtocolInput::Claude => {
            let mut config = AnthropicConfig::new(key);
            if let Some(base_url) = &provider.base_url {
                config = config.with_base_url(base_url);
            }
            let mut completion = config.connect(http).completion(model);
            if provider.prompt_caching {
                completion.wire = completion.wire.with_prompt_caching();
            }
            Ok(completion.erase())
        }
        ProtocolInput::Gemini => {
            let mut api_key =
                http::HeaderValue::from_str(&key).map_err(|error| error.to_string())?;
            api_key.set_sensitive(true);
            let mut config = GeminiConfig::new("");
            let use_v1 = provider
                .base_url
                .as_deref()
                .is_some_and(|url| url.trim_end_matches('/').ends_with("/v1/models"));
            if let Some(base_url) = &provider.base_url {
                let suffix = if use_v1 {
                    "/v1/models"
                } else {
                    "/v1beta/models"
                };
                config = config.with_base_url(trim_suffix(base_url, suffix));
            }
            let completion = config.connect(http).completion(model);
            Ok(Model::new(
                completion.wire,
                GeminiTransport {
                    http: completion.transport,
                    api_key,
                    use_v1,
                },
            )
            .erase())
        }
        ProtocolInput::Cohere => {
            let mut config = CohereConfig::new(key);
            if let Some(base_url) = &provider.base_url {
                config = config.with_base_url(trim_suffix(base_url, "/v2"));
            }
            Ok(Model::new(config.completion(model).with_route(ChatRoute::Native), http).erase())
        }
        ProtocolInput::Ollama => {
            let mut config = OllamaConfig::new().with_api_key(key);
            if let Some(base_url) = &provider.base_url {
                config = config.with_base_url(base_url);
            }
            Ok(config.connect(http).native_completion(model).erase())
        }
        ProtocolInput::Copilot => Ok(configure_openai(provider)
            .connect(http)
            .completion(model)
            .erase()),
        ProtocolInput::Azure => {
            let deployment = provider
                .deployment
                .as_deref()
                .expect("Azure deployment was validated");
            let base_url = provider
                .base_url
                .as_ref()
                .ok_or_else(|| "Azure base URL is missing".to_owned())?;
            let version = provider
                .api_version
                .as_ref()
                .ok_or_else(|| "Azure API version is missing".to_owned())?;
            let mut dialect = AZURE;
            // shortcut: Rig Azure uses a legacy output cap, remove when it supports OpenAI model capabilities.
            dialect.quirks.output_cap = OPENAI.quirks.output_cap;
            let mut config = OpenAIConfig::with_key(&dialect, key)
                .with_base_url(base_url)
                .with_api_version(version)
                .with_route(match provider.route.unwrap_or(RouteInput::Chat) {
                    RouteInput::Chat => Route::Chat,
                    RouteInput::Responses => Route::Responses,
                });
            if matches!(provider.auth, Some(AuthInput::Bearer)) {
                config = config.with_auth(Auth::Bearer);
            }
            if matches!(provider.route, Some(RouteInput::Responses)) {
                let completion = config.connect(http).completion(model);
                return Ok(Model::new(
                    completion.wire,
                    AzureResponsesTransport {
                        http: completion.transport,
                        uri: azure_responses_uri(base_url, version)?,
                        deployment: deployment.to_owned(),
                    },
                )
                .erase());
            }
            Ok(config.connect(http).completion(deployment).erase())
        }
        ProtocolInput::Openai => Ok(configure_openai(provider)
            .connect(http)
            .completion(model)
            .erase()),
    }
}

// shortcut: Rig hardcodes v1beta and query-key auth; remove when it supports v1 and header auth.
#[derive(Clone, Debug)]
struct GeminiTransport {
    http: DynHttpClient,
    api_key: http::HeaderValue,
    use_v1: bool,
}

impl Transport<GeminiGenerateContent> for GeminiTransport {
    fn send(&self, mut payload: Encoded, exchange: Exchange) -> Opening<WireFrame> {
        let mut url = match rig_reqwest::reqwest::Url::parse(&payload.request.uri().to_string()) {
            Ok(url) => url,
            Err(error) => return Opening::failed(ProviderError::request(error)),
        };
        if self.use_v1 {
            let Some((prefix, model)) = url.path().rsplit_once("/v1beta/models/") else {
                return Opening::failed(ProviderError::request("Invalid Gemini model URL"));
            };
            url.set_path(&format!("{prefix}/v1/models/{model}"));
        }
        let query: Vec<_> = url
            .query_pairs()
            .filter(|(name, _)| name != "key")
            .map(|(name, value)| (name.into_owned(), value.into_owned()))
            .collect();
        url.query_pairs_mut().clear().extend_pairs(query);
        *payload.request.uri_mut() = match url.as_str().parse() {
            Ok(uri) => uri,
            Err(error) => return Opening::failed(ProviderError::request(error)),
        };
        payload
            .request
            .headers_mut()
            .insert("x-goog-api-key", self.api_key.clone());
        <DynHttpClient as Transport<GeminiGenerateContent>>::send(&self.http, payload, exchange)
    }
}

// shortcut: Rig lacks Azure-specific Responses routing, remove when it handles the endpoint and deployment separately from model capabilities.
#[derive(Clone, Debug)]
struct AzureResponsesTransport {
    http: DynHttpClient,
    uri: http::Uri,
    deployment: String,
}

impl Transport<OpenAiWire> for AzureResponsesTransport {
    fn send(&self, mut payload: Encoded, exchange: Exchange) -> Opening<WireFrame> {
        // Let Rig apply model capabilities before replacing the model with Azure's deployment.
        let Body::Bytes(body) = payload.request.body() else {
            return Opening::failed(ProviderError::request(
                "Azure Responses requires a JSON body",
            ));
        };
        let body = serde_json::from_slice::<serde_json::Value>(body).and_then(|mut body| {
            body["model"] = self.deployment.clone().into();
            serde_json::to_vec(&body)
        });
        let body = match body {
            Ok(body) => body,
            Err(error) => return Opening::failed(ProviderError::request(error)),
        };
        *payload.request.body_mut() = Body::Bytes(body);
        *payload.request.uri_mut() = self.uri.clone();
        <DynHttpClient as Transport<OpenAiWire>>::send(&self.http, payload, exchange)
    }
}

pub(super) fn azure_responses_uri(base_url: &str, version: &str) -> Result<http::Uri, String> {
    let mut url = rig_reqwest::reqwest::Url::parse(base_url).map_err(|error| error.to_string())?;
    let base = url.path().trim_end_matches('/');
    let v1 = version == "v1" || base.ends_with("/openai/v1");
    if !v1 && version < "2025-03-01" {
        return Err(format!(
            "Azure Responses requires api_version = \"v1\" or 2025-03-01-preview or newer; got {version}"
        ));
    }
    let base = base
        .strip_suffix("/openai/v1")
        .or_else(|| base.strip_suffix("/openai"))
        .unwrap_or(base);
    url.set_path(&format!(
        "{base}/openai/{suffix}",
        suffix = if v1 { "v1/responses" } else { "responses" }
    ));
    if !v1 {
        url.query_pairs_mut().append_pair("api-version", version);
    }
    url.as_str()
        .parse()
        .map_err(|error: http::uri::InvalidUri| error.to_string())
}

// shortcut: Rig 0.45 replays unary Vertex replies, remove when its transport uses the streaming SDK RPC.
#[derive(Clone, Debug)]
pub(super) struct StreamingVertex(pub(super) rig_vertexai::VertexAi);

impl Transport<GenerateContent> for StreamingVertex {
    fn send(
        &self,
        mut request: <GenerateContent as Wire>::Payload,
        _exchange: Exchange,
    ) -> Opening<<GenerateContent as Wire>::Frame> {
        // Rig re-emits unary replies; keep its wire format and use the SDK's streaming RPC.
        request.model = format!(
            "projects/{}/locations/{}/publishers/google/models/{}",
            self.0.project(),
            self.0.location(),
            request.model
        );
        let client = self.0.clone();
        Opening::new(async move {
            let service = client.inner().await.map_err(ProviderError::request)?;
            let frames = service
                .stream_generate_content()
                .with_request(request)
                .send()
                .await
                .map_err(|error| vertex_sdk_error(&error))?;
            Ok(Opened::new(futures::stream::unfold(
                frames,
                |mut frames| async move {
                    frames.next().await.map(|frame| {
                        let chunk = match frame {
                            Ok(frame) => rest_chunk(&frame),
                            Err(error) => Err(vertex_sdk_error(&error)),
                        };
                        (chunk, frames)
                    })
                },
            )))
        })
    }
}

fn vertex_sdk_error(error: &google_cloud_aiplatform_v1::Error) -> ProviderError {
    let status = error
        .http_status_code()
        .and_then(|code| rig::http_client::StatusCode::from_u16(code).ok());
    ProviderError::from_provider_body(error.to_string()).with_provider_status(status)
}

fn take_f64(params: &mut Map<String, Value>, key: &str) -> Result<Option<f64>, String> {
    let Some(value) = params.shift_remove(key) else {
        return Ok(None);
    };
    value
        .as_f64()
        .map(Some)
        .ok_or_else(|| format!("{key} must be a number"))
}

fn take_u64(params: &mut Map<String, Value>, keys: &[&str]) -> Result<Option<u64>, String> {
    let mut result = None;
    for key in keys {
        if let Some(value) = params.shift_remove(*key) {
            let value = value
                .as_u64()
                .ok_or_else(|| format!("{key} must be a non-negative integer"))?;
            if result.is_none() {
                result = Some(value);
            }
        }
    }
    Ok(result)
}

pub(super) fn apply_generation_params(
    provider: &ProviderInput,
    request: &mut CompletionRequest,
    additional_params: Option<Value>,
) -> Result<(), String> {
    // A set policy enables Rig's catalog checks even when no other typed option is supplied.
    request.options.on_unsupported = Some(OnUnsupported::Ignore);
    if matches!(provider.protocol, ProtocolInput::Azure) {
        // Rig uses the handle for deployment routing and this override for model capabilities.
        request.model = Some(provider.model.clone());
    }
    let facts = ModelFacts::default();
    let openai_model = facts.for_model(OPENAI.name, &provider.model);

    if let Some(Value::Object(mut params)) = additional_params {
        request.temperature = take_f64(&mut params, "temperature")?;
        request.options.top_p = take_f64(&mut params, "top_p")?;
        let explicit_completion_cap = matches!(provider.protocol, ProtocolInput::Azure)
            && !matches!(provider.route, Some(RouteInput::Responses))
            && params.contains_key("max_completion_tokens");
        request.max_tokens = take_u64(
            &mut params,
            &["max_tokens", "max_completion_tokens", "max_output_tokens"],
        )?;
        if explicit_completion_cap && let Some(cap) = request.max_tokens.take() {
            params.insert("max_completion_tokens".to_owned(), cap.into());
        }
        let effort = match params.shift_remove("reasoning_effort") {
            Some(Value::String(effort)) => Some(effort),
            Some(_) => return Err("reasoning_effort must be a string".to_owned()),
            None => None,
        };
        if let Some(effort) = effort {
            if matches!(provider.route, Some(RouteInput::Responses))
                && ((matches!(provider.protocol, ProtocolInput::Azure)
                    && openai_model.is_none_or(|model| model.reasoning.supported()))
                    || (matches!(provider.protocol, ProtocolInput::Openai)
                        && provider.dialect.as_deref() == Some("deepseek")))
                && let Some(reasoning) = params
                    .entry("reasoning")
                    .or_insert_with(|| serde_json::json!({}))
                    .as_object_mut()
            {
                // shortcut: Rig lacks Azure/DeepSeek Responses reasoning mapping, remove when its typed options support both.
                reasoning
                    .entry("effort")
                    .or_insert_with(|| Value::String(effort.clone()));
            }
            let reasoning = match effort.as_str() {
                "none" => Reasoning::Off,
                "minimal" => Reasoning::Effort(Effort::Minimal),
                "low" => Reasoning::Effort(Effort::Low),
                "medium" => Reasoning::Effort(Effort::Medium),
                "high" => Reasoning::Effort(Effort::High),
                "xhigh" => Reasoning::Effort(Effort::XHigh),
                "max" => Reasoning::Effort(Effort::Max),
                other => return Err(format!("unsupported reasoning effort: {other}")),
            };
            request.options.reasoning = Some(reasoning);
        }
        if !params.is_empty() {
            request.additional_params = Some(Value::Object(params));
        }
    } else if additional_params.is_some() {
        return Err("additionalParams must be a JSON object".to_owned());
    }
    let vendor = match provider.protocol {
        ProtocolInput::Openai => provider.dialect.as_deref().unwrap_or(OPENAI.name),
        ProtocolInput::Azure | ProtocolInput::Copilot => OPENAI.name,
        ProtocolInput::Claude => rig::providers::anthropic::PROVIDER_NAME,
        ProtocolInput::Gemini => rig::providers::gemini::PROVIDER_NAME,
        ProtocolInput::Vertex => "vertexai",
        ProtocolInput::Cohere => rig::providers::cohere::PROVIDER_NAME,
        ProtocolInput::Ollama => rig::providers::ollama::PROVIDER_NAME,
        ProtocolInput::Bedrock => rig_bedrock::completion::PROVIDER_NAME,
    };
    if let Some(model) = facts.for_model(vendor, &provider.model) {
        model.fit(request);
    }
    let reasoning_off = matches!(request.options.reasoning, Some(Reasoning::Off))
        || request
            .additional_params
            .as_ref()
            .and_then(|params| params.pointer("/reasoning/effort"))
            .and_then(Value::as_str)
            == Some("none");
    // Older reasoning model families do not all support summaries.
    if matches!(provider.route, Some(RouteInput::Responses))
        && !reasoning_off
        && provider.model.starts_with("gpt-")
        && openai_model.is_some_and(|model| model.reasoning.supported())
    {
        let params = request
            .additional_params
            .get_or_insert_with(|| Value::Object(Map::new()));
        if let Some(reasoning) = params
            .as_object_mut()
            .expect("validated additional params")
            .entry("reasoning")
            .or_insert_with(|| serde_json::json!({}))
            .as_object_mut()
        {
            reasoning
                .entry("summary")
                .or_insert_with(|| Value::String("auto".to_owned()));
        }
    }
    Ok(())
}
