mod worker;

use agent_client_protocol::schema::v1::{
    CloseSessionRequest, ContentBlock, DeleteSessionRequest, ListSessionsRequest,
    LoadSessionRequest, McpServer, NewSessionRequest, PromptRequest, ResumeSessionRequest,
    SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory, SessionConfigOptionValue,
    SessionConfigSelectOption, SessionConfigSelectOptions, SessionModeState,
};
use mlua::prelude::*;
use mlua::{LuaSerdeExt, UserData, UserDataMethods};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

const NATIVE_API_VERSION: u32 = 2;
const DEFAULT_SESSION_CLOSE_TIMEOUT_MS: u64 = 500;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClientConfig {
    command: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    auth_method: Option<String>,
    #[serde(default)]
    read_text_file: bool,
    #[serde(default)]
    write_text_file: bool,
    #[serde(default = "default_session_close_timeout_ms")]
    session_close_timeout_ms: u64,
}

const fn default_session_close_timeout_ms() -> u64 {
    DEFAULT_SESSION_CLOSE_TIMEOUT_MS
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionSetup {
    cwd: PathBuf,
    #[serde(default)]
    mcp_servers: Vec<McpServer>,
    #[serde(default)]
    additional_directories: Vec<PathBuf>,
}

impl SessionSetup {
    fn validate(&self) -> agent_client_protocol::Result<()> {
        if !self.cwd.is_absolute() {
            return Err(agent_client_protocol::Error::invalid_params()
                .data("session cwd must be an absolute path"));
        }
        if self
            .additional_directories
            .iter()
            .any(|path| !path.is_absolute())
        {
            return Err(agent_client_protocol::Error::invalid_params()
                .data("additional session directories must be absolute paths"));
        }
        for server in &self.mcp_servers {
            if let McpServer::Stdio(server) = server
                && !server.command.is_absolute()
            {
                return Err(agent_client_protocol::Error::invalid_params()
                    .data("MCP stdio commands must be absolute paths"));
            }
        }
        Ok(())
    }

    fn new_request(&self) -> agent_client_protocol::Result<NewSessionRequest> {
        self.validate()?;
        Ok(NewSessionRequest::new(&self.cwd)
            .mcp_servers(self.mcp_servers.clone())
            .additional_directories(self.additional_directories.clone()))
    }

    fn load_request(
        &self,
        session_id: String,
    ) -> agent_client_protocol::Result<LoadSessionRequest> {
        self.validate()?;
        validate_session_id(&session_id)?;
        Ok(LoadSessionRequest::new(session_id, &self.cwd)
            .mcp_servers(self.mcp_servers.clone())
            .additional_directories(self.additional_directories.clone()))
    }

    fn resume_request(
        &self,
        session_id: String,
    ) -> agent_client_protocol::Result<ResumeSessionRequest> {
        self.validate()?;
        validate_session_id(&session_id)?;
        Ok(ResumeSessionRequest::new(session_id, &self.cwd)
            .mcp_servers(self.mcp_servers.clone())
            .additional_directories(self.additional_directories.clone()))
    }
}

fn validate_session_id(session_id: &str) -> agent_client_protocol::Result<()> {
    if session_id.is_empty() {
        Err(agent_client_protocol::Error::invalid_params().data("session ID must not be empty"))
    } else {
        Ok(())
    }
}

#[derive(Debug)]
enum Command {
    NewSession {
        operation_id: u64,
        request: NewSessionRequest,
    },
    LoadSession {
        operation_id: u64,
        request: LoadSessionRequest,
    },
    ResumeSession {
        operation_id: u64,
        request: ResumeSessionRequest,
    },
    ListSessions {
        operation_id: u64,
        request: ListSessionsRequest,
    },
    CloseSession {
        operation_id: u64,
        request: CloseSessionRequest,
    },
    DeleteSession {
        operation_id: u64,
        request: DeleteSessionRequest,
    },
    SetSessionOption {
        operation_id: u64,
        session_id: String,
        config_id: String,
        value: SessionConfigOptionValue,
    },
    Prompt {
        operation_id: u64,
        request: PromptRequest,
    },
    RespondPermission {
        request_id: u64,
        option_id: Option<String>,
    },
    RespondRead {
        request_id: u64,
        content: String,
    },
    RespondWrite {
        request_id: u64,
    },
    RespondError {
        request_id: u64,
        error: agent_client_protocol::Error,
    },
    Cancel {
        session_id: String,
    },
    Stop,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum ConnectionState {
    Disconnected,
    Connecting,
    Ready,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ErrorKind {
    InvalidRequest,
    InvalidInput,
    Unsupported,
    NotFound,
    SessionNotFound,
    Cancelled,
    Authentication,
    Internal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConfigBackend {
    Options,
    Modes,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
enum ConfigValue {
    Id(String),
    Boolean(bool),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigOptionValue {
    value: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
}

impl From<&SessionConfigSelectOption> for ConfigOptionValue {
    fn from(option: &SessionConfigSelectOption) -> Self {
        Self {
            value: option.value.to_string(),
            name: option.name.clone(),
            description: option.description.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigOption {
    id: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    #[serde(rename = "type")]
    option_type: &'static str,
    current_value: ConfigValue,
    #[serde(skip_serializing_if = "Option::is_none")]
    options: Option<Vec<ConfigOptionValue>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SessionConfiguration {
    backend: Option<ConfigBackend>,
    options: Vec<ConfigOption>,
}

fn config_category(category: &SessionConfigOptionCategory) -> Option<String> {
    match category {
        SessionConfigOptionCategory::Mode => Some("mode".to_string()),
        SessionConfigOptionCategory::Model => Some("model".to_string()),
        SessionConfigOptionCategory::ModelConfig => Some("model_config".to_string()),
        SessionConfigOptionCategory::ThoughtLevel => Some("thought_level".to_string()),
        SessionConfigOptionCategory::Other(value) => Some(value.clone()),
        _ => None,
    }
}

fn select_options(options: &SessionConfigSelectOptions) -> Vec<ConfigOptionValue> {
    match options {
        SessionConfigSelectOptions::Ungrouped(options) => {
            options.iter().map(ConfigOptionValue::from).collect()
        }
        SessionConfigSelectOptions::Grouped(groups) => groups
            .iter()
            .flat_map(|group| group.options.iter().map(ConfigOptionValue::from))
            .collect(),
        _ => Vec::new(),
    }
}

fn normalize_config_options(options: &[SessionConfigOption]) -> Vec<ConfigOption> {
    options
        .iter()
        .map(|option| {
            let (option_type, current_value, options) = match &option.kind {
                SessionConfigKind::Select(select) => (
                    "select",
                    ConfigValue::Id(select.current_value.to_string()),
                    Some(select_options(&select.options)),
                ),
                SessionConfigKind::Boolean(boolean) => {
                    ("boolean", ConfigValue::Boolean(boolean.current_value), None)
                }
                _ => ("unknown", ConfigValue::Id(String::new()), None),
            };
            ConfigOption {
                id: option.id.to_string(),
                name: option.name.clone(),
                description: option.description.clone(),
                category: option.category.as_ref().and_then(config_category),
                option_type,
                current_value,
                options,
            }
        })
        .collect()
}

fn normalize_session_configuration(
    modes: Option<&SessionModeState>,
    config_options: Option<&[SessionConfigOption]>,
) -> SessionConfiguration {
    if let Some(options) = config_options {
        return SessionConfiguration {
            backend: Some(ConfigBackend::Options),
            options: normalize_config_options(options),
        };
    }
    if let Some(modes) = modes {
        return SessionConfiguration {
            backend: Some(ConfigBackend::Modes),
            options: vec![ConfigOption {
                id: "mode".to_string(),
                name: "Mode".to_string(),
                description: None,
                category: Some("mode".to_string()),
                option_type: "select",
                current_value: ConfigValue::Id(modes.current_mode_id.to_string()),
                options: Some(
                    modes
                        .available_modes
                        .iter()
                        .map(|mode| ConfigOptionValue {
                            value: mode.id.to_string(),
                            name: mode.name.clone(),
                            description: mode.description.clone(),
                        })
                        .collect(),
                ),
            }],
        };
    }
    SessionConfiguration {
        backend: None,
        options: Vec::new(),
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionOperationResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    config_options: Vec<ConfigOption>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigValueChange {
    id: String,
    current_value: ConfigValue,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ClientError {
    kind: ErrorKind,
    code: i32,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationStart {
    #[serde(skip_serializing_if = "Option::is_none")]
    operation_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ClientError>,
}

impl From<agent_client_protocol::Result<u64>> for OperationStart {
    fn from(result: agent_client_protocol::Result<u64>) -> Self {
        match result {
            Ok(operation_id) => Self {
                operation_id: Some(operation_id),
                error: None,
            },
            Err(error) => Self {
                operation_id: None,
                error: Some(error.into()),
            },
        }
    }
}

impl From<agent_client_protocol::Error> for ClientError {
    fn from(error: agent_client_protocol::Error) -> Self {
        use agent_client_protocol::ErrorCode;

        let session_not_found = error.message.starts_with("Session not found")
            || error.data.as_ref().is_some_and(|data| {
                data.as_str()
                    .is_some_and(|value| value.starts_with("Session not found"))
                    || data
                        .get("details")
                        .and_then(serde_json::Value::as_str)
                        .is_some_and(|value| value.starts_with("Session not found"))
            });
        let kind = if session_not_found {
            ErrorKind::SessionNotFound
        } else {
            match error.code {
                ErrorCode::InvalidRequest | ErrorCode::ParseError => ErrorKind::InvalidRequest,
                ErrorCode::InvalidParams => ErrorKind::InvalidInput,
                ErrorCode::MethodNotFound => ErrorKind::Unsupported,
                ErrorCode::ResourceNotFound => ErrorKind::NotFound,
                ErrorCode::RequestCancelled => ErrorKind::Cancelled,
                ErrorCode::AuthRequired => ErrorKind::Authentication,
                ErrorCode::InternalError | ErrorCode::Other(_) => ErrorKind::Internal,
                _ => ErrorKind::Internal,
            }
        };
        Self {
            kind,
            code: error.code.into(),
            message: error.message,
            data: error.data,
        }
    }
}

fn protocol_error(kind: &str, message: String) -> agent_client_protocol::Error {
    let error = match kind {
        "invalid_request" => agent_client_protocol::Error::invalid_request(),
        "invalid_input" => agent_client_protocol::Error::invalid_params(),
        "unsupported" => agent_client_protocol::Error::method_not_found(),
        "not_found" | "session_not_found" => agent_client_protocol::Error::resource_not_found(None),
        "cancelled" => agent_client_protocol::Error::request_cancelled(),
        "authentication" => agent_client_protocol::Error::auth_required(),
        _ => agent_client_protocol::Error::internal_error(),
    };
    error.data(message)
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    StateChanged {
        state: ConnectionState,
    },
    Initialized {
        #[serde(rename = "supportsLoadSession")]
        supports_load_session: bool,
        #[serde(rename = "supportsListSessions")]
        supports_list_sessions: bool,
    },
    OperationCompleted {
        #[serde(rename = "operationId")]
        operation_id: u64,
        result: serde_json::Value,
    },
    OperationFailed {
        #[serde(rename = "operationId")]
        operation_id: u64,
        error: ClientError,
    },
    FatalError {
        error: ClientError,
    },
    SessionUpdate {
        notification: serde_json::Value,
        replayed: bool,
        #[serde(rename = "configOptions", skip_serializing_if = "Option::is_none")]
        config_options: Option<Vec<ConfigOption>>,
        #[serde(rename = "configValue", skip_serializing_if = "Option::is_none")]
        config_value: Option<ConfigValueChange>,
    },
    PermissionRequest {
        #[serde(rename = "requestId")]
        request_id: u64,
        request: serde_json::Value,
    },
    ReadTextFileRequest {
        #[serde(rename = "requestId")]
        request_id: u64,
        request: serde_json::Value,
    },
    WriteTextFileRequest {
        #[serde(rename = "requestId")]
        request_id: u64,
        request: serde_json::Value,
    },
}

struct NativeClient {
    config: ClientConfig,
    commands: Mutex<Option<mpsc::UnboundedSender<Command>>>,
    events: Arc<Mutex<Vec<Event>>>,
    next_operation_id: AtomicU64,
}

impl NativeClient {
    fn new(config: ClientConfig) -> LuaResult<Self> {
        if config.command.is_empty() {
            return Err(LuaError::RuntimeError(
                "ACP agent command must not be empty".to_string(),
            ));
        }
        Ok(Self {
            config,
            commands: Mutex::new(None),
            events: Arc::new(Mutex::new(Vec::new())),
            next_operation_id: AtomicU64::new(1),
        })
    }

    fn lock_error() -> LuaError {
        LuaError::RuntimeError("ACP client state is poisoned; create a new client".to_string())
    }

    fn send(&self, command: Command) -> LuaResult<()> {
        self.commands
            .lock()
            .map_err(|_| Self::lock_error())?
            .as_ref()
            .ok_or_else(|| LuaError::RuntimeError("ACP client is not started".to_string()))?
            .send(command)
            .map_err(|_| LuaError::RuntimeError("ACP client connection is closed".to_string()))
    }

    fn next_operation_id(&self) -> u64 {
        self.next_operation_id.fetch_add(1, Ordering::Relaxed)
    }

    fn operation<T>(
        &self,
        request: agent_client_protocol::Result<T>,
        command: impl FnOnce(u64, T) -> Command,
    ) -> OperationStart {
        OperationStart::from(request.and_then(|request| {
            let operation_id = self.next_operation_id();
            self.send(command(operation_id, request)).map_err(|error| {
                agent_client_protocol::Error::internal_error().data(error.to_string())
            })?;
            Ok(operation_id)
        }))
    }
}

impl UserData for NativeClient {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("start", |_, this, ()| {
            let mut sender = this.commands.lock().map_err(|_| Self::lock_error())?;
            if sender.is_some() {
                return Ok(false);
            }
            *sender = Some(worker::start(
                this.config.clone(),
                Arc::clone(&this.events),
            )?);
            Ok(true)
        });
        methods.add_method("new_session", |lua, this, setup: LuaValue| {
            let request = lua
                .from_value::<SessionSetup>(setup)
                .map_err(|error| {
                    agent_client_protocol::Error::invalid_params().data(error.to_string())
                })
                .and_then(|setup| setup.new_request());
            lua.to_value(
                &this.operation(request, |operation_id, request| Command::NewSession {
                    operation_id,
                    request,
                }),
            )
        });
        methods.add_method(
            "load_session",
            |lua, this, (session_id, setup): (String, LuaValue)| {
                let request = lua
                    .from_value::<SessionSetup>(setup)
                    .map_err(|error| {
                        agent_client_protocol::Error::invalid_params().data(error.to_string())
                    })
                    .and_then(|setup| setup.load_request(session_id));
                lua.to_value(&this.operation(request, |operation_id, request| {
                    Command::LoadSession {
                        operation_id,
                        request,
                    }
                }))
            },
        );
        methods.add_method(
            "resume_session",
            |lua, this, (session_id, setup): (String, LuaValue)| {
                let request = lua
                    .from_value::<SessionSetup>(setup)
                    .map_err(|error| {
                        agent_client_protocol::Error::invalid_params().data(error.to_string())
                    })
                    .and_then(|setup| setup.resume_request(session_id));
                lua.to_value(&this.operation(request, |operation_id, request| {
                    Command::ResumeSession {
                        operation_id,
                        request,
                    }
                }))
            },
        );
        methods.add_method("list_sessions", |lua, this, cwd: Option<String>| {
            let cwd = cwd.map(PathBuf::from);
            let request = if cwd.as_ref().is_some_and(|path| !path.is_absolute()) {
                Err(agent_client_protocol::Error::invalid_params()
                    .data("session list cwd must be an absolute path"))
            } else {
                Ok(ListSessionsRequest::new().cwd(cwd))
            };
            lua.to_value(
                &this.operation(request, |operation_id, request| Command::ListSessions {
                    operation_id,
                    request,
                }),
            )
        });
        methods.add_method("close_session", |lua, this, session_id: String| {
            let request =
                validate_session_id(&session_id).map(|()| CloseSessionRequest::new(session_id));
            lua.to_value(
                &this.operation(request, |operation_id, request| Command::CloseSession {
                    operation_id,
                    request,
                }),
            )
        });
        methods.add_method("delete_session", |lua, this, session_id: String| {
            let request =
                validate_session_id(&session_id).map(|()| DeleteSessionRequest::new(session_id));
            lua.to_value(
                &this.operation(request, |operation_id, request| Command::DeleteSession {
                    operation_id,
                    request,
                }),
            )
        });
        methods.add_method(
            "set_session_option",
            |lua, this, (session_id, config_id, value): (String, String, LuaValue)| {
                let request = validate_session_id(&session_id).and_then(|()| {
                    let value = match value {
                        LuaValue::Boolean(value) => SessionConfigOptionValue::boolean(value),
                        LuaValue::String(value) => SessionConfigOptionValue::value_id(
                            value
                                .to_str()
                                .map_err(|error| {
                                    agent_client_protocol::Error::invalid_params()
                                        .data(error.to_string())
                                })?
                                .to_string(),
                        ),
                        _ => {
                            return Err(agent_client_protocol::Error::invalid_params()
                                .data("config option value must be a string or boolean"));
                        }
                    };
                    Ok((session_id, config_id, value))
                });
                lua.to_value(&this.operation(
                    request,
                    |operation_id, (session_id, config_id, value)| Command::SetSessionOption {
                        operation_id,
                        session_id,
                        config_id,
                        value,
                    },
                ))
            },
        );
        methods.add_method(
            "prompt",
            |lua, this, (session_id, prompt): (String, LuaValue)| {
                let request = validate_session_id(&session_id)
                    .and_then(|()| {
                        lua.from_value::<Vec<ContentBlock>>(prompt)
                            .map_err(|error| {
                                agent_client_protocol::Error::invalid_params()
                                    .data(error.to_string())
                            })
                    })
                    .map(|prompt| PromptRequest::new(session_id, prompt));
                lua.to_value(
                    &this.operation(request, |operation_id, request| Command::Prompt {
                        operation_id,
                        request,
                    }),
                )
            },
        );
        methods.add_method(
            "respond_permission",
            |_, this, (request_id, option_id): (u64, Option<String>)| {
                this.send(Command::RespondPermission {
                    request_id,
                    option_id,
                })
            },
        );
        methods.add_method(
            "respond_read_text_file",
            |_, this, (request_id, content): (u64, String)| {
                this.send(Command::RespondRead {
                    request_id,
                    content,
                })
            },
        );
        methods.add_method("respond_write_text_file", |_, this, request_id: u64| {
            this.send(Command::RespondWrite { request_id })
        });
        methods.add_method(
            "respond_error",
            |_, this, (request_id, kind, message): (u64, String, String)| {
                this.send(Command::RespondError {
                    request_id,
                    error: protocol_error(&kind, message),
                })
            },
        );
        methods.add_method("cancel", |_, this, session_id: String| {
            validate_session_id(&session_id).map_err(LuaError::external)?;
            this.send(Command::Cancel { session_id })
        });
        methods.add_method("stop", |_, this, ()| this.send(Command::Stop));
        methods.add_method("poll", |lua, this, ()| {
            let events = std::mem::take(&mut *this.events.lock().map_err(|_| Self::lock_error())?);
            lua.to_value_with(
                &events,
                LuaSerializeOptions::new()
                    .serialize_none_to_null(false)
                    .serialize_unit_to_null(false),
            )
        });
    }
}

#[mlua::lua_module]
fn avante_acp(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set("api_version", NATIVE_API_VERSION)?;
    exports.set(
        "new",
        lua.create_function(|lua, value: LuaValue| {
            let config = lua.from_value(value)?;
            lua.create_userdata(NativeClient::new(config)?)
        })?,
    )?;
    Ok(exports)
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::v1::{
        SessionConfigOption, SessionConfigOptionCategory, SessionConfigSelectOption, SessionMode,
        SessionModeState,
    };

    #[test]
    fn client_errors_have_stable_application_kinds() {
        let missing = ClientError::from(
            agent_client_protocol::Error::internal_error()
                .data(serde_json::json!({ "details": "Session not found: abc" })),
        );
        let not_found = ClientError::from(agent_client_protocol::Error::resource_not_found(None));
        let invalid = ClientError::from(agent_client_protocol::Error::invalid_params());

        assert_eq!(missing.kind, ErrorKind::SessionNotFound);
        assert_eq!(not_found.kind, ErrorKind::NotFound);
        assert_eq!(invalid.kind, ErrorKind::InvalidInput);
    }

    #[test]
    fn responder_error_kinds_map_to_official_protocol_errors() {
        use agent_client_protocol::ErrorCode;

        assert_eq!(
            protocol_error("unsupported", "missing handler".to_string()).code,
            ErrorCode::MethodNotFound
        );
        assert_eq!(
            protocol_error("not_found", "missing file".to_string()).code,
            ErrorCode::ResourceNotFound
        );
    }

    #[test]
    fn session_configuration_normalizes_modes_and_config_values() {
        let modes = SessionModeState::new(
            "code",
            vec![
                SessionMode::new("code", "Code"),
                SessionMode::new("plan", "Plan").description("Plan before editing"),
            ],
        );
        let legacy = normalize_session_configuration(Some(&modes), None);
        let legacy_json = serde_json::to_value(&legacy.options).unwrap();
        assert_eq!(legacy.backend, Some(ConfigBackend::Modes));
        assert_eq!(legacy_json[0]["currentValue"], "code");
        assert_eq!(legacy_json[0]["options"][1]["value"], "plan");

        let options = vec![
            SessionConfigOption::select(
                "model",
                "Model",
                "fast",
                vec![SessionConfigSelectOption::new("fast", "Fast")],
            )
            .category(SessionConfigOptionCategory::Model),
            SessionConfigOption::boolean("thinking", "Thinking", true),
        ];
        let current = normalize_session_configuration(Some(&modes), Some(&options));
        let current_json = serde_json::to_value(&current.options).unwrap();
        assert_eq!(current.backend, Some(ConfigBackend::Options));
        assert_eq!(current_json[0]["currentValue"], "fast");
        assert_eq!(current_json[1]["currentValue"], true);
    }

    #[test]
    fn config_requires_a_command() {
        let err =
            serde_json::from_value::<ClientConfig>(serde_json::json!({ "args": [] })).unwrap_err();
        assert!(err.to_string().contains("command"));
    }

    #[test]
    fn config_rejects_an_empty_command() {
        let config = serde_json::from_value(serde_json::json!({ "command": "" })).unwrap();
        let err = NativeClient::new(config).err().unwrap();
        assert!(err.to_string().contains("must not be empty"));
    }

    #[test]
    fn config_uses_a_bounded_default_close_timeout() {
        let config: ClientConfig =
            serde_json::from_value(serde_json::json!({ "command": "agent" })).unwrap();
        assert_eq!(config.session_close_timeout_ms, 500);
    }

    #[test]
    fn new_client_has_no_synthetic_connection_events() {
        let config = serde_json::from_value(serde_json::json!({ "command": "agent" })).unwrap();
        let client = NativeClient::new(config).unwrap();
        assert!(client.events.lock().unwrap().is_empty());
    }

    #[test]
    fn commands_use_official_request_types() {
        let command = Command::NewSession {
            operation_id: 7,
            request: NewSessionRequest::new("/tmp"),
        };
        assert!(matches!(
            command,
            Command::NewSession {
                operation_id: 7,
                ..
            }
        ));
    }

    #[test]
    fn commands_accept_official_stdio_mcp_shape() {
        let setup: SessionSetup = serde_json::from_value(serde_json::json!({
            "cwd": "/tmp",
            "mcpServers": [{
                "type": "stdio",
                "name": "test",
                "command": "/bin/true",
                "args": [],
                "env": []
            }]
        }))
        .unwrap();
        assert_eq!(setup.new_request().unwrap().mcp_servers.len(), 1);
    }

    #[test]
    fn commands_use_official_delete_session_type() {
        let command = Command::DeleteSession {
            operation_id: 7,
            request: DeleteSessionRequest::new("s1"),
        };
        assert!(matches!(
            command,
            Command::DeleteSession {
                operation_id: 7,
                ..
            }
        ));
    }

    #[test]
    fn events_are_application_messages() {
        let event = serde_json::to_value(Event::OperationCompleted {
            operation_id: 7,
            result: serde_json::json!({}),
        })
        .unwrap();
        assert_eq!(event["type"], "operation_completed");
        assert_eq!(event["operationId"], 7);
        assert!(event.get("jsonrpc").is_none());
    }

    #[test]
    fn native_operations_allocate_ids_in_rust() {
        let config = serde_json::from_value(serde_json::json!({ "command": "agent" })).unwrap();
        let client = NativeClient::new(config).unwrap();

        assert_eq!(client.next_operation_id(), 1);
        assert_eq!(client.next_operation_id(), 2);
    }

    #[test]
    fn operation_start_serializes_validation_errors() {
        let start = OperationStart::from(Err(
            agent_client_protocol::Error::invalid_params().data("session ID must not be empty")
        ));
        let value = serde_json::to_value(start).unwrap();

        assert!(value.get("operationId").is_none());
        assert_eq!(value["error"]["kind"], "invalid_input");
        assert_eq!(value["error"]["code"], -32602);
    }

    #[test]
    fn session_setup_builds_official_requests() {
        let setup: SessionSetup = serde_json::from_value(serde_json::json!({
            "cwd": "/tmp/project",
            "mcpServers": [],
            "additionalDirectories": ["/tmp/shared"]
        }))
        .unwrap();

        let request = setup.new_request().unwrap();
        assert_eq!(request.cwd, std::path::PathBuf::from("/tmp/project"));
        assert_eq!(
            request.additional_directories,
            vec![std::path::PathBuf::from("/tmp/shared")]
        );
    }

    #[test]
    fn session_setup_rejects_relative_roots() {
        let setup: SessionSetup = serde_json::from_value(serde_json::json!({
            "cwd": "relative",
            "mcpServers": []
        }))
        .unwrap();

        assert!(
            setup
                .new_request()
                .unwrap_err()
                .to_string()
                .contains("absolute")
        );
    }
}
