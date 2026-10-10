use super::{
    ClientConfig, Command, ConfigBackend, ConfigValue, ConfigValueChange, ConnectionState, Event,
    SessionOperationResult, normalize_config_options, normalize_session_configuration,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    AgentCapabilities, AuthMethod, AuthenticateRequest, CancelNotification, ClientCapabilities,
    CloseSessionRequest, ContentBlock, FileSystemCapabilities, Implementation, InitializeRequest,
    McpServer, PermissionOptionId, PromptRequest, ReadTextFileRequest, ReadTextFileResponse,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionNotification, SessionUpdate, SetSessionConfigOptionRequest,
    SetSessionModeRequest, WriteTextFileRequest, WriteTextFileResponse,
};
use agent_client_protocol::util::MatchDispatch;
use agent_client_protocol::{
    AcpAgent, AcpAgentConfig, ActiveSession, Agent, ConnectionTo, Dispatch, JsonRpcRequest,
    Responder, SessionMessage,
};
use futures::FutureExt;
use serde::Serialize;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

const MAX_SESSION_LIST_PAGES: usize = 50;

type Events = Arc<Mutex<Vec<Event>>>;
type Responders = Arc<Mutex<HashMap<u64, PendingResponder>>>;
type Sessions = Arc<Mutex<HashMap<String, SessionHandle>>>;

struct SessionHandle {
    stop: mpsc::UnboundedSender<()>,
    config_backend: Option<ConfigBackend>,
}

fn merge_config_backend(current: &mut Option<ConfigBackend>, incoming: ConfigBackend) {
    if incoming == ConfigBackend::Options || current.is_none() {
        *current = Some(incoming);
    }
}

enum PendingResponder {
    Permission {
        session_id: String,
        responder: Responder<RequestPermissionResponse>,
    },
    Read {
        session_id: String,
        responder: Responder<ReadTextFileResponse>,
    },
    Write {
        session_id: String,
        responder: Responder<WriteTextFileResponse>,
    },
}

impl PendingResponder {
    fn session_id(&self) -> &str {
        match self {
            Self::Permission { session_id, .. }
            | Self::Read { session_id, .. }
            | Self::Write { session_id, .. } => session_id,
        }
    }

    fn cancel(self) -> agent_client_protocol::Result<()> {
        match self {
            Self::Permission { responder, .. } => responder.respond(
                RequestPermissionResponse::new(RequestPermissionOutcome::Cancelled),
            ),
            Self::Read { responder, .. } => responder.respond_with_error(
                agent_client_protocol::Error::invalid_request().data("session closed"),
            ),
            Self::Write { responder, .. } => responder.respond_with_error(
                agent_client_protocol::Error::invalid_request().data("session closed"),
            ),
        }
    }
}

fn client_implementation() -> Implementation {
    Implementation::new("avante.nvim", "unknown")
}

pub(super) fn start(
    config: ClientConfig,
    events: Events,
) -> mlua::Result<mpsc::UnboundedSender<Command>> {
    let (sender, receiver) = mpsc::unbounded_channel();
    std::thread::Builder::new()
        .name("avante-acp".to_string())
        .spawn(move || {
            let result = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .map_err(|error| agent_client_protocol::Error::new(-32603, error.to_string()))
                .and_then(|runtime| runtime.block_on(run(config, receiver, Arc::clone(&events))));
            if let Err(error) = result {
                push(
                    &events,
                    Event::FatalError {
                        error: error.into(),
                    },
                );
            }
            push(
                &events,
                Event::StateChanged {
                    state: ConnectionState::Disconnected,
                },
            );
        })
        .map_err(mlua::Error::external)?;
    Ok(sender)
}

async fn run(
    config: ClientConfig,
    mut commands: mpsc::UnboundedReceiver<Command>,
    events: Events,
) -> agent_client_protocol::Result<()> {
    let session_close_timeout = Duration::from_millis(config.session_close_timeout_ms);
    push(
        &events,
        Event::StateChanged {
            state: ConnectionState::Connecting,
        },
    );
    let agent = AcpAgent::new(
        AcpAgentConfig::new(&config.command)
            .args(config.args.clone())
            .envs(config.env.clone()),
    );
    let responders = Responders::default();
    let sessions = Sessions::default();
    let next_request_id = Arc::new(AtomicU64::new(1));
    let mut pending_commands = VecDeque::new();
    agent_client_protocol::Client
        .builder()
        .connect_with(agent, async move |connection| {
            let client_capabilities = ClientCapabilities::new().fs(FileSystemCapabilities::new()
                .read_text_file(config.read_text_file)
                .write_text_file(config.write_text_file));
            let initialize = InitializeRequest::new(ProtocolVersion::V1)
                .client_capabilities(client_capabilities)
                .client_info(client_implementation());
            let Some(initialized) = wait_for_response_or_stop(
                &mut commands,
                &mut pending_commands,
                connection.send_request(initialize).block_task(),
            )
            .await?
            else {
                return Ok(());
            };

            if initialized.protocol_version != ProtocolVersion::V1 {
                return Err(agent_client_protocol::Error::new(
                    -32600,
                    format!(
                        "agent selected unsupported ACP protocol version {}",
                        initialized.protocol_version
                    ),
                ));
            }
            if let Some(method_id) = config.auth_method {
                let supported = initialized.auth_methods.iter().any(|method| {
                    matches!(method, AuthMethod::Agent(_)) && method.id().0.as_ref() == method_id
                });
                if !supported {
                    return Err(agent_client_protocol::Error::new(
                        -32600,
                        "unsupported ACP authentication method",
                    ));
                }
                if wait_for_response_or_stop(
                    &mut commands,
                    &mut pending_commands,
                    connection
                        .send_request(AuthenticateRequest::new(method_id))
                        .block_task(),
                )
                .await?
                .is_none()
                {
                    return Ok(());
                }
            }

            let capabilities = initialized.agent_capabilities;
            push(
                &events,
                Event::Initialized {
                    supports_load_session: capabilities.load_session,
                    supports_list_sessions: capabilities.session_capabilities.list.is_some(),
                },
            );
            push(
                &events,
                Event::StateChanged {
                    state: ConnectionState::Ready,
                },
            );

            loop {
                let command = if let Some(command) = pending_commands.pop_front() {
                    command
                } else {
                    let Some(command) =
                        wait_for_command_or_close(&mut commands, connection.incoming_closed())
                            .await?
                    else {
                        break;
                    };
                    command
                };
                if matches!(command, Command::Stop) {
                    shutdown_sessions(
                        &connection,
                        &capabilities,
                        &responders,
                        &sessions,
                        session_close_timeout,
                    )
                    .await;
                    break;
                }
                if !dispatch(
                    command,
                    &connection,
                    &capabilities,
                    &events,
                    &responders,
                    &sessions,
                    &next_request_id,
                )? {
                    break;
                }
            }
            Ok(())
        })
        .await
}

async fn wait_for_command_or_close(
    commands: &mut mpsc::UnboundedReceiver<Command>,
    incoming_closed: impl Future<Output = ()>,
) -> agent_client_protocol::Result<Option<Command>> {
    tokio::select! {
        command = commands.recv() => Ok(command),
        () = incoming_closed => Err(agent_client_protocol::Error::new(
            -32603,
            "ACP agent connection closed",
        )),
    }
}

async fn wait_for_response_or_stop<T>(
    commands: &mut mpsc::UnboundedReceiver<Command>,
    pending_commands: &mut VecDeque<Command>,
    response: impl Future<Output = agent_client_protocol::Result<T>>,
) -> agent_client_protocol::Result<Option<T>> {
    tokio::pin!(response);
    loop {
        tokio::select! {
            result = &mut response => return result.map(Some),
            command = commands.recv() => match command {
                Some(Command::Stop) | None => return Ok(None),
                Some(command) => pending_commands.push_back(command),
            },
        }
    }
}

fn dispatch(
    command: Command,
    connection: &ConnectionTo<Agent>,
    capabilities: &AgentCapabilities,
    events: &Events,
    responders: &Responders,
    sessions: &Sessions,
    next_request_id: &Arc<AtomicU64>,
) -> agent_client_protocol::Result<bool> {
    match command {
        Command::NewSession {
            operation_id,
            request,
        } => {
            if let Err(error) = validate_session_setup(
                &request.additional_directories,
                &request.mcp_servers,
                capabilities,
            ) {
                fail_operation(events, operation_id, error);
                return Ok(true);
            }
            let connection = connection.clone();
            let task_connection = connection.clone();
            let events = Arc::clone(events);
            let responders = Arc::clone(responders);
            let sessions = Arc::clone(sessions);
            let next_request_id = Arc::clone(next_request_id);
            connection.spawn(async move {
                let result = async {
                    let roots = canonical_roots(
                        std::iter::once(request.cwd.as_path())
                            .chain(request.additional_directories.iter().map(PathBuf::as_path)),
                    )?;
                    let session = task_connection
                        .build_session_from(request)
                        .block_task()
                        .start_session()
                        .await?;
                    let configuration =
                        normalize_session_configuration(session.modes(), session.config_options());
                    let response = to_json(SessionOperationResult {
                        session_id: Some(session.session_id().to_string()),
                        config_options: configuration.options,
                    })?;
                    register_session(
                        session,
                        false,
                        roots,
                        configuration.backend,
                        &events,
                        &responders,
                        &sessions,
                        &next_request_id,
                    )
                    .await?;
                    Ok(response)
                }
                .await;
                complete_operation(&events, operation_id, result);
                Ok(())
            })?;
        }
        Command::LoadSession {
            operation_id,
            request,
        } => {
            if !capabilities.load_session {
                fail_operation(
                    events,
                    operation_id,
                    unsupported("agent does not support session/load"),
                );
                return Ok(true);
            }
            if let Err(error) = validate_session_setup(
                &request.additional_directories,
                &request.mcp_servers,
                capabilities,
            ) {
                fail_operation(events, operation_id, error);
                return Ok(true);
            }
            let connection = connection.clone();
            let task_connection = connection.clone();
            let events = Arc::clone(events);
            let responders = Arc::clone(responders);
            let sessions = Arc::clone(sessions);
            let next_request_id = Arc::clone(next_request_id);
            connection.spawn(async move {
                let result = async {
                    let roots = canonical_roots(
                        std::iter::once(request.cwd.as_path())
                            .chain(request.additional_directories.iter().map(PathBuf::as_path)),
                    )?;
                    let restored = task_connection
                        .load_session_from(request)
                        .block_task()
                        .start_session()
                        .await?;
                    let (session, _) = restored.into_parts();
                    let configuration =
                        normalize_session_configuration(session.modes(), session.config_options());
                    let response = to_json(SessionOperationResult {
                        session_id: None,
                        config_options: configuration.options,
                    })?;
                    register_session(
                        session,
                        true,
                        roots,
                        configuration.backend,
                        &events,
                        &responders,
                        &sessions,
                        &next_request_id,
                    )
                    .await?;
                    Ok(response)
                }
                .await;
                complete_operation(&events, operation_id, result);
                Ok(())
            })?;
        }
        Command::ResumeSession {
            operation_id,
            request,
        } => {
            if capabilities.session_capabilities.resume.is_none() {
                fail_operation(
                    events,
                    operation_id,
                    unsupported("agent does not support session/resume"),
                );
                return Ok(true);
            }
            if let Err(error) = validate_session_setup(
                &request.additional_directories,
                &request.mcp_servers,
                capabilities,
            ) {
                fail_operation(events, operation_id, error);
                return Ok(true);
            }
            let connection = connection.clone();
            let task_connection = connection.clone();
            let events = Arc::clone(events);
            let responders = Arc::clone(responders);
            let sessions = Arc::clone(sessions);
            let next_request_id = Arc::clone(next_request_id);
            connection.spawn(async move {
                let result = async {
                    let roots = canonical_roots(
                        std::iter::once(request.cwd.as_path())
                            .chain(request.additional_directories.iter().map(PathBuf::as_path)),
                    )?;
                    let restored = task_connection
                        .resume_session_from(request)
                        .block_task()
                        .start_session()
                        .await?;
                    let (session, _) = restored.into_parts();
                    let configuration =
                        normalize_session_configuration(session.modes(), session.config_options());
                    let response = to_json(SessionOperationResult {
                        session_id: None,
                        config_options: configuration.options,
                    })?;
                    register_session(
                        session,
                        false,
                        roots,
                        configuration.backend,
                        &events,
                        &responders,
                        &sessions,
                        &next_request_id,
                    )
                    .await?;
                    Ok(response)
                }
                .await;
                complete_operation(&events, operation_id, result);
                Ok(())
            })?;
        }
        Command::ListSessions {
            operation_id,
            request,
        } => {
            if capabilities.session_capabilities.list.is_none() {
                fail_operation(
                    events,
                    operation_id,
                    unsupported("agent does not support session/list"),
                );
                return Ok(true);
            }
            let connection = connection.clone();
            let task_connection = connection.clone();
            let events = Arc::clone(events);
            connection.spawn(async move {
                let result = list_all_sessions(&task_connection, request).await;
                complete_operation(&events, operation_id, result);
                Ok(())
            })?;
        }
        Command::CloseSession {
            operation_id,
            request,
        } => {
            if capabilities.session_capabilities.close.is_none() {
                fail_operation(
                    events,
                    operation_id,
                    unsupported("agent does not support session/close"),
                );
                return Ok(true);
            }
            let session_id = request.session_id.to_string();
            spawn_session_request(
                connection,
                operation_id,
                request,
                events,
                responders,
                sessions,
                session_id,
            )?;
        }
        Command::DeleteSession {
            operation_id,
            request,
        } => {
            if capabilities.session_capabilities.delete.is_none() {
                fail_operation(
                    events,
                    operation_id,
                    unsupported("agent does not support session/delete"),
                );
                return Ok(true);
            }
            let session_id = request.session_id.to_string();
            spawn_session_request(
                connection,
                operation_id,
                request,
                events,
                responders,
                sessions,
                session_id,
            )?;
        }
        Command::SetSessionOption {
            operation_id,
            session_id,
            config_id,
            value,
        } => {
            let backend = sessions
                .lock()
                .map_err(|_| state_error())?
                .get(&session_id)
                .and_then(|session| session.config_backend);
            match backend {
                Some(ConfigBackend::Options) => {
                    let request = SetSessionConfigOptionRequest::new(session_id, config_id, value);
                    let connection = connection.clone();
                    let task_connection = connection.clone();
                    let events = Arc::clone(events);
                    connection.spawn(async move {
                        let result = task_connection
                            .send_request(request)
                            .block_task()
                            .await
                            .and_then(|response| {
                                to_json(serde_json::json!({
                                    "configOptions": normalize_config_options(&response.config_options)
                                }))
                            });
                        complete_operation(&events, operation_id, result);
                        Ok(())
                    })?;
                }
                Some(ConfigBackend::Modes) => {
                    let Some(mode_id) = value.as_value_id().map(ToString::to_string) else {
                        fail_operation(
                            events,
                            operation_id,
                            agent_client_protocol::Error::invalid_params()
                                .data("session mode must be a string"),
                        );
                        return Ok(true);
                    };
                    if config_id != "mode" {
                        fail_operation(
                            events,
                            operation_id,
                            agent_client_protocol::Error::invalid_params()
                                .data("legacy sessions only expose the mode option"),
                        );
                        return Ok(true);
                    }
                    let request = SetSessionModeRequest::new(session_id, mode_id.clone());
                    let connection = connection.clone();
                    let task_connection = connection.clone();
                    let events = Arc::clone(events);
                    connection.spawn(async move {
                        let result = task_connection
                            .send_request(request)
                            .block_task()
                            .await
                            .and_then(|_| {
                                to_json(serde_json::json!({
                                    "configValue": ConfigValueChange {
                                        id: "mode".to_string(),
                                        current_value: ConfigValue::Id(mode_id),
                                    }
                                }))
                            });
                        complete_operation(&events, operation_id, result);
                        Ok(())
                    })?;
                }
                None => fail_operation(
                    events,
                    operation_id,
                    unsupported("session does not expose configurable options"),
                ),
            }
        }
        Command::Prompt {
            operation_id,
            request,
        } => {
            if let Err(error) = validate_prompt(&request, capabilities) {
                fail_operation(events, operation_id, error);
                return Ok(true);
            }
            if !session_is_active(sessions, &request.session_id.to_string())? {
                fail_operation(
                    events,
                    operation_id,
                    agent_client_protocol::Error::resource_not_found(None)
                        .data("Session not found"),
                );
                return Ok(true);
            }
            spawn_request(connection, operation_id, request, events)?;
        }
        Command::RespondPermission {
            request_id,
            option_id,
        } => {
            let _ = respond_permission(responders, request_id, option_id);
        }
        Command::RespondRead {
            request_id,
            content,
        } => {
            let _ = respond_read(responders, request_id, content);
        }
        Command::RespondWrite { request_id } => {
            let _ = respond_write(responders, request_id);
        }
        Command::RespondError { request_id, error } => {
            let _ = respond_error(responders, request_id, error);
        }
        Command::Cancel { session_id } => {
            cancel_pending_permissions(responders, &session_id)?;
            connection.send_notification(CancelNotification::new(session_id))?;
        }
        Command::Stop => {
            stop_all_sessions(sessions)?;
            return Ok(false);
        }
    }
    Ok(true)
}

async fn register_session(
    mut session: ActiveSession<'static, Agent>,
    replayed: bool,
    roots: Vec<PathBuf>,
    config_backend: Option<ConfigBackend>,
    events: &Events,
    responders: &Responders,
    sessions: &Sessions,
    next_request_id: &Arc<AtomicU64>,
) -> agent_client_protocol::Result<()> {
    let session_id = session.session_id().to_string();
    if replayed {
        while let Some(message) = session.read_update().now_or_never() {
            forward_session_message(
                message?,
                true,
                events,
                responders,
                sessions,
                next_request_id,
                &roots,
            )
            .await?;
        }
    }

    let (stop_tx, mut stop_rx) = mpsc::unbounded_channel();
    sessions.lock().map_err(|_| state_error())?.insert(
        session_id,
        SessionHandle {
            stop: stop_tx,
            config_backend,
        },
    );
    let connection = session.connection().clone();
    let events = Arc::clone(events);
    let responders = Arc::clone(responders);
    let session_states = Arc::clone(sessions);
    let next_request_id = Arc::clone(next_request_id);
    connection.clone().spawn(async move {
        loop {
            tokio::select! {
                message = session.read_update() => {
                    forward_session_message(
                        message?,
                        false,
                        &events,
                        &responders,
                        &session_states,
                        &next_request_id,
                        &roots,
                    ).await?;
                }
                _ = stop_rx.recv() => break,
            }
        }
        Ok(())
    })?;
    Ok(())
}

async fn forward_session_message(
    message: SessionMessage,
    replayed: bool,
    events: &Events,
    responders: &Responders,
    sessions: &Sessions,
    next_request_id: &AtomicU64,
    roots: &[PathBuf],
) -> agent_client_protocol::Result<()> {
    let SessionMessage::SessionMessage(dispatch) = message else {
        return Ok(());
    };
    let notification_events = Arc::clone(events);
    let notification_sessions = Arc::clone(sessions);
    let permission_events = Arc::clone(events);
    let read_events = Arc::clone(events);
    let write_events = Arc::clone(events);
    let permission_responders = Arc::clone(responders);
    let read_responders = Arc::clone(responders);
    let write_responders = Arc::clone(responders);
    let read_roots = roots.to_vec();
    let write_roots = roots.to_vec();

    MatchDispatch::new(dispatch)
        .if_notification(async move |notification: SessionNotification| {
            if !replayed {
                let incoming = match &notification.update {
                    SessionUpdate::ConfigOptionUpdate(_) => Some(ConfigBackend::Options),
                    SessionUpdate::CurrentModeUpdate(_) => Some(ConfigBackend::Modes),
                    _ => None,
                };
                if let Some(incoming) = incoming
                    && let Some(session) = notification_sessions
                        .lock()
                        .map_err(|_| state_error())?
                        .get_mut(notification.session_id.0.as_ref())
                {
                    merge_config_backend(&mut session.config_backend, incoming);
                }
            }
            let (config_options, config_value) = match &notification.update {
                SessionUpdate::ConfigOptionUpdate(update) => {
                    (Some(normalize_config_options(&update.config_options)), None)
                }
                SessionUpdate::CurrentModeUpdate(update) => (
                    None,
                    Some(ConfigValueChange {
                        id: "mode".to_string(),
                        current_value: ConfigValue::Id(update.current_mode_id.to_string()),
                    }),
                ),
                _ => (None, None),
            };
            push(
                &notification_events,
                Event::SessionUpdate {
                    notification: to_json(notification)?,
                    replayed,
                    config_options,
                    config_value,
                },
            );
            Ok(())
        })
        .await
        .if_request(async move |request: RequestPermissionRequest, responder| {
            let request_id = next_request_id.fetch_add(1, Ordering::Relaxed);
            permission_responders
                .lock()
                .map_err(|_| state_error())?
                .insert(
                    request_id,
                    PendingResponder::Permission {
                        session_id: request.session_id.to_string(),
                        responder,
                    },
                );
            push(
                &permission_events,
                Event::PermissionRequest {
                    request_id,
                    request: to_json(request)?,
                },
            );
            Ok(())
        })
        .await
        .if_request(async move |mut request: ReadTextFileRequest, responder| {
            if request.line == Some(0) {
                responder.respond_with_error(
                    agent_client_protocol::Error::invalid_params()
                        .data("read line must be 1-based"),
                )?;
                return Ok(());
            }
            request.path = match validate_file_path(&request.path, &read_roots) {
                Ok(path) => path,
                Err(error) => {
                    responder.respond_with_error(error)?;
                    return Ok(());
                }
            };
            let request_id = next_request_id.fetch_add(1, Ordering::Relaxed);
            read_responders.lock().map_err(|_| state_error())?.insert(
                request_id,
                PendingResponder::Read {
                    session_id: request.session_id.to_string(),
                    responder,
                },
            );
            push(
                &read_events,
                Event::ReadTextFileRequest {
                    request_id,
                    request: to_json(request)?,
                },
            );
            Ok(())
        })
        .await
        .if_request(async move |mut request: WriteTextFileRequest, responder| {
            request.path = match validate_file_path(&request.path, &write_roots) {
                Ok(path) => path,
                Err(error) => {
                    responder.respond_with_error(error)?;
                    return Ok(());
                }
            };
            let request_id = next_request_id.fetch_add(1, Ordering::Relaxed);
            write_responders.lock().map_err(|_| state_error())?.insert(
                request_id,
                PendingResponder::Write {
                    session_id: request.session_id.to_string(),
                    responder,
                },
            );
            push(
                &write_events,
                Event::WriteTextFileRequest {
                    request_id,
                    request: to_json(request)?,
                },
            );
            Ok(())
        })
        .await
        .otherwise(async |dispatch| match dispatch {
            Dispatch::Request(_, responder) => responder.respond_with_error(
                agent_client_protocol::Error::method_not_found()
                    .data("unsupported session request"),
            ),
            Dispatch::Notification(_) | Dispatch::Response(_, _) => Ok(()),
        })
        .await
}

fn spawn_session_request<Request>(
    connection: &ConnectionTo<Agent>,
    operation_id: u64,
    request: Request,
    events: &Events,
    responders: &Responders,
    sessions: &Sessions,
    session_id: String,
) -> agent_client_protocol::Result<()>
where
    Request: JsonRpcRequest + Send + 'static,
    Request::Response: Serialize + Send + 'static,
{
    let connection = connection.clone();
    let task_connection = connection.clone();
    let events = Arc::clone(events);
    let responders = Arc::clone(responders);
    let sessions = Arc::clone(sessions);
    connection.spawn(async move {
        let result = async {
            let response = task_connection.send_request(request).block_task().await?;
            stop_session(&sessions, &session_id)?;
            cancel_pending_session(&responders, &session_id)?;
            to_json(response)
        }
        .await;
        complete_operation(&events, operation_id, result);
        Ok(())
    })
}

fn spawn_request<Request>(
    connection: &ConnectionTo<Agent>,
    operation_id: u64,
    request: Request,
    events: &Events,
) -> agent_client_protocol::Result<()>
where
    Request: JsonRpcRequest + Send + 'static,
    Request::Response: Serialize + Send + 'static,
{
    let connection = connection.clone();
    let task_connection = connection.clone();
    let events = Arc::clone(events);
    connection.spawn(async move {
        let result = task_connection
            .send_request(request)
            .block_task()
            .await
            .and_then(to_json);
        complete_operation(&events, operation_id, result);
        Ok(())
    })
}

async fn list_all_sessions(
    connection: &ConnectionTo<Agent>,
    initial: agent_client_protocol::schema::v1::ListSessionsRequest,
) -> agent_client_protocol::Result<serde_json::Value> {
    let cwd = initial.cwd;
    let mut cursor = initial.cursor;
    let mut sessions = Vec::new();
    let mut seen = HashSet::new();

    for _ in 0..MAX_SESSION_LIST_PAGES {
        let request = agent_client_protocol::schema::v1::ListSessionsRequest::new()
            .cwd(cwd.clone())
            .cursor(cursor.take());
        let response = connection.send_request(request).block_task().await?;
        sessions.extend(response.sessions);
        let Some(next_cursor) = response.next_cursor.filter(|value| !value.is_empty()) else {
            return to_json(sessions);
        };
        if !seen.insert(next_cursor.clone()) {
            return Err(agent_client_protocol::Error::internal_error()
                .data("session list returned a repeated cursor"));
        }
        cursor = Some(next_cursor);
    }

    Err(agent_client_protocol::Error::internal_error()
        .data("session list exceeded the pagination limit"))
}

fn validate_session_setup(
    additional_directories: &[PathBuf],
    mcp_servers: &[McpServer],
    capabilities: &AgentCapabilities,
) -> agent_client_protocol::Result<()> {
    if !additional_directories.is_empty()
        && capabilities
            .session_capabilities
            .additional_directories
            .is_none()
    {
        return Err(unsupported("agent does not support additionalDirectories"));
    }
    for server in mcp_servers {
        match server {
            McpServer::Http(_) if !capabilities.mcp_capabilities.http => {
                return Err(unsupported("agent does not support HTTP MCP servers"));
            }
            McpServer::Sse(_) if !capabilities.mcp_capabilities.sse => {
                return Err(unsupported("agent does not support SSE MCP servers"));
            }
            _ => {}
        }
    }
    Ok(())
}

fn validate_prompt(
    request: &PromptRequest,
    capabilities: &AgentCapabilities,
) -> agent_client_protocol::Result<()> {
    for content in &request.prompt {
        let unsupported_type = match content {
            ContentBlock::Text(_) | ContentBlock::ResourceLink(_) => None,
            ContentBlock::Image(_) if !capabilities.prompt_capabilities.image => Some("image"),
            ContentBlock::Audio(_) if !capabilities.prompt_capabilities.audio => Some("audio"),
            ContentBlock::Resource(_) if !capabilities.prompt_capabilities.embedded_context => {
                Some("embedded resource")
            }
            _ => None,
        };
        if let Some(kind) = unsupported_type {
            return Err(unsupported(format!(
                "agent does not support {kind} prompt content"
            )));
        }
    }
    Ok(())
}

fn canonical_roots<'a>(
    paths: impl IntoIterator<Item = &'a Path>,
) -> agent_client_protocol::Result<Vec<PathBuf>> {
    paths
        .into_iter()
        .map(|path| {
            std::fs::canonicalize(path).map_err(|error| {
                agent_client_protocol::Error::invalid_params().data(format!(
                    "cannot resolve session root {}: {error}",
                    path.display()
                ))
            })
        })
        .collect()
}

fn validate_file_path(path: &Path, roots: &[PathBuf]) -> agent_client_protocol::Result<PathBuf> {
    if !path.is_absolute() {
        return Err(
            agent_client_protocol::Error::invalid_params().data("file path must be absolute")
        );
    }
    let canonical = if path.exists() {
        std::fs::canonicalize(path)
    } else {
        let parent = path.parent().ok_or_else(|| {
            agent_client_protocol::Error::invalid_params().data("file path has no parent")
        })?;
        std::fs::canonicalize(parent).map(|parent| {
            path.file_name()
                .map_or_else(|| parent.clone(), |name| parent.join(name))
        })
    }
    .map_err(|error| {
        agent_client_protocol::Error::invalid_params().data(format!(
            "cannot resolve file path {}: {error}",
            path.display()
        ))
    })?;
    if roots.iter().any(|root| canonical.starts_with(root)) {
        Ok(canonical)
    } else {
        Err(agent_client_protocol::Error::invalid_params()
            .data("file path is outside the session roots"))
    }
}

fn respond_permission(
    responders: &Responders,
    request_id: u64,
    option_id: Option<String>,
) -> agent_client_protocol::Result<()> {
    let responder = take_responder(responders, request_id)?;
    let PendingResponder::Permission { responder, .. } = responder else {
        return Err(agent_client_protocol::Error::invalid_request()
            .data("response type does not match permission request"));
    };
    let outcome = option_id.map_or(RequestPermissionOutcome::Cancelled, |option_id| {
        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(PermissionOptionId::new(
            option_id,
        )))
    });
    responder.respond(RequestPermissionResponse::new(outcome))
}

fn respond_read(
    responders: &Responders,
    request_id: u64,
    content: String,
) -> agent_client_protocol::Result<()> {
    let responder = take_responder(responders, request_id)?;
    let PendingResponder::Read { responder, .. } = responder else {
        return Err(agent_client_protocol::Error::invalid_request()
            .data("response type does not match read request"));
    };
    responder.respond(ReadTextFileResponse::new(content))
}

fn respond_write(responders: &Responders, request_id: u64) -> agent_client_protocol::Result<()> {
    let responder = take_responder(responders, request_id)?;
    let PendingResponder::Write { responder, .. } = responder else {
        return Err(agent_client_protocol::Error::invalid_request()
            .data("response type does not match write request"));
    };
    responder.respond(WriteTextFileResponse::new())
}

fn respond_error(
    responders: &Responders,
    request_id: u64,
    error: agent_client_protocol::Error,
) -> agent_client_protocol::Result<()> {
    match take_responder(responders, request_id)? {
        PendingResponder::Permission { responder, .. } => responder.respond_with_error(error),
        PendingResponder::Read { responder, .. } => responder.respond_with_error(error),
        PendingResponder::Write { responder, .. } => responder.respond_with_error(error),
    }
}

fn take_responder(
    responders: &Responders,
    request_id: u64,
) -> agent_client_protocol::Result<PendingResponder> {
    responders
        .lock()
        .map_err(|_| state_error())?
        .remove(&request_id)
        .ok_or_else(|| {
            agent_client_protocol::Error::invalid_request()
                .data("ACP response is no longer pending")
        })
}

fn cancel_pending_session(
    responders: &Responders,
    session_id: &str,
) -> agent_client_protocol::Result<()> {
    let pending = {
        let mut responders = responders.lock().map_err(|_| state_error())?;
        let ids = responders
            .iter()
            .filter_map(|(id, responder)| (responder.session_id() == session_id).then_some(*id))
            .collect::<Vec<_>>();
        ids.into_iter()
            .filter_map(|id| responders.remove(&id))
            .collect::<Vec<_>>()
    };
    for responder in pending {
        responder.cancel()?;
    }
    Ok(())
}

fn cancel_pending_permissions(
    responders: &Responders,
    session_id: &str,
) -> agent_client_protocol::Result<()> {
    let pending = {
        let mut responders = responders.lock().map_err(|_| state_error())?;
        let ids = responders
            .iter()
            .filter_map(|(id, responder)| {
                matches!(
                    responder,
                    PendingResponder::Permission {
                        session_id: pending_session_id,
                        ..
                    } if pending_session_id == session_id
                )
                .then_some(*id)
            })
            .collect::<Vec<_>>();
        ids.into_iter()
            .filter_map(|id| responders.remove(&id))
            .collect::<Vec<_>>()
    };
    for responder in pending {
        responder.cancel()?;
    }
    Ok(())
}

fn session_is_active(sessions: &Sessions, session_id: &str) -> agent_client_protocol::Result<bool> {
    Ok(sessions
        .lock()
        .map_err(|_| state_error())?
        .contains_key(session_id))
}

fn stop_session(sessions: &Sessions, session_id: &str) -> agent_client_protocol::Result<()> {
    if let Some(session) = sessions
        .lock()
        .map_err(|_| state_error())?
        .remove(session_id)
    {
        let _ = session.stop.send(());
    }
    Ok(())
}

fn stop_all_sessions(sessions: &Sessions) -> agent_client_protocol::Result<()> {
    let sessions = std::mem::take(&mut *sessions.lock().map_err(|_| state_error())?);
    for (_, session) in sessions {
        let _ = session.stop.send(());
    }
    Ok(())
}

async fn shutdown_sessions(
    connection: &ConnectionTo<Agent>,
    capabilities: &AgentCapabilities,
    responders: &Responders,
    sessions: &Sessions,
    close_timeout: Duration,
) {
    let session_ids = sessions
        .lock()
        .map(|sessions| sessions.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    if capabilities.session_capabilities.close.is_some() {
        let close_all = async {
            for session_id in &session_ids {
                let _ = connection
                    .send_request(CloseSessionRequest::new(session_id.clone()))
                    .block_task()
                    .await;
            }
        };
        let _ = tokio::time::timeout(close_timeout, close_all).await;
    }
    for session_id in &session_ids {
        let _ = cancel_pending_session(responders, session_id);
    }
    let _ = stop_all_sessions(sessions);
}

fn complete_operation(
    events: &Events,
    operation_id: u64,
    result: agent_client_protocol::Result<serde_json::Value>,
) {
    match result {
        Ok(result) => push(
            events,
            Event::OperationCompleted {
                operation_id,
                result,
            },
        ),
        Err(error) => fail_operation(events, operation_id, error),
    }
}

fn fail_operation(events: &Events, operation_id: u64, error: agent_client_protocol::Error) {
    push(
        events,
        Event::OperationFailed {
            operation_id,
            error: error.into(),
        },
    );
}

fn unsupported(message: impl Into<String>) -> agent_client_protocol::Error {
    agent_client_protocol::Error::method_not_found().data(message.into())
}

fn state_error() -> agent_client_protocol::Error {
    agent_client_protocol::Error::internal_error().data("ACP worker state is poisoned")
}

fn to_json(value: impl Serialize) -> agent_client_protocol::Result<serde_json::Value> {
    serde_json::to_value(value)
        .map_err(|error| agent_client_protocol::Error::new(-32603, error.to_string()))
}

fn push(events: &Events, event: Event) {
    if let Ok(mut events) = events.lock() {
        events.push(event);
    }
}

#[cfg(test)]
mod tests {
    use super::{ClientConfig, Command, ConnectionState, Event};
    use agent_client_protocol::schema::v1::{
        AgentCapabilities, CloseSessionRequest, ListSessionsRequest, LoadSessionRequest,
        NewSessionRequest, PromptCapabilities, PromptRequest, SessionConfigOptionValue,
    };
    use std::collections::BTreeMap;
    use std::path::Path;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant, SystemTime};

    fn wait_for_event(
        events: &Arc<Mutex<Vec<Event>>>,
        description: &str,
        predicate: impl Fn(&Event) -> bool,
    ) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if events.lock().unwrap().iter().any(&predicate) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {description}; events: {:?}",
                events.lock().unwrap()
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn compile_stdio_agent(directory: &Path) -> std::path::PathBuf {
        let executable = directory.join(format!("stdio-agent{}", std::env::consts::EXE_SUFFIX));
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/stdio_agent.rs");
        let status =
            std::process::Command::new(std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
                .args(["--edition=2024", "-o"])
                .arg(&executable)
                .arg(source)
                .status()
                .unwrap();
        assert!(status.success(), "failed to compile the fake ACP agent");
        executable
    }

    struct TestAgent {
        directory: std::path::PathBuf,
        root: std::path::PathBuf,
        close_marker: std::path::PathBuf,
        scenario_marker: std::path::PathBuf,
        authenticate_seen: std::path::PathBuf,
        authenticate_gate: std::path::PathBuf,
        events: Arc<Mutex<Vec<Event>>>,
        commands: tokio::sync::mpsc::UnboundedSender<Command>,
    }

    impl TestAgent {
        fn start(
            label: &str,
            scenario: &str,
            auth_method: Option<&str>,
            read_text_file: bool,
            write_text_file: bool,
        ) -> Self {
            let nonce = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let directory = std::env::temp_dir()
                .join(format!("avante-acp-{label}-{}-{nonce}", std::process::id()));
            let root = directory.join("root");
            std::fs::create_dir_all(&root).unwrap();
            let executable = compile_stdio_agent(&directory);
            let close_marker = directory.join("closed");
            let scenario_marker = directory.join("scenario-checked");
            let authenticate_seen = directory.join("authenticate-seen");
            let authenticate_gate = directory.join("authenticate-gate");
            let mut env = BTreeMap::from([
                ("AVANTE_ACP_TEST_SCENARIO".to_string(), scenario.to_string()),
                (
                    "AVANTE_ACP_TEST_ROOT".to_string(),
                    root.to_string_lossy().into_owned(),
                ),
                (
                    "AVANTE_ACP_TEST_CLOSE_MARKER".to_string(),
                    close_marker.to_string_lossy().into_owned(),
                ),
                (
                    "AVANTE_ACP_TEST_SCENARIO_MARKER".to_string(),
                    scenario_marker.to_string_lossy().into_owned(),
                ),
            ]);
            if scenario == "auth-pending" {
                env.insert(
                    "AVANTE_ACP_TEST_AUTHENTICATE_SEEN_MARKER".to_string(),
                    authenticate_seen.to_string_lossy().into_owned(),
                );
                env.insert(
                    "AVANTE_ACP_TEST_AUTHENTICATE_GATE".to_string(),
                    authenticate_gate.to_string_lossy().into_owned(),
                );
            }
            let events = Arc::new(Mutex::new(Vec::new()));
            let commands = super::start(
                ClientConfig {
                    command: executable.to_string_lossy().into_owned(),
                    args: Vec::new(),
                    env,
                    auth_method: auth_method.map(ToString::to_string),
                    read_text_file,
                    write_text_file,
                    session_close_timeout_ms: 1_000,
                },
                Arc::clone(&events),
            )
            .unwrap();
            Self {
                directory,
                root,
                close_marker,
                scenario_marker,
                authenticate_seen,
                authenticate_gate,
                events,
                commands,
            }
        }

        fn wait_ready(&self) {
            wait_for_event(&self.events, "ready state", |event| {
                matches!(
                    event,
                    Event::StateChanged {
                        state: ConnectionState::Ready
                    }
                )
            });
        }

        fn load(&self, operation_id: u64) {
            self.commands
                .send(Command::LoadSession {
                    operation_id,
                    request: LoadSessionRequest::new("s1", &self.root),
                })
                .unwrap();
            wait_for_event(&self.events, "load completion", |event| {
                matches!(
                    event,
                    Event::OperationCompleted {
                        operation_id: completed_id,
                        ..
                    } if *completed_id == operation_id
                )
            });
        }

        fn prompt(&self, operation_id: u64, text: &str) {
            let request: PromptRequest = serde_json::from_value(serde_json::json!({
                "sessionId": "s1",
                "prompt": [{ "type": "text", "text": text }]
            }))
            .unwrap();
            self.commands
                .send(Command::Prompt {
                    operation_id,
                    request,
                })
                .unwrap();
        }

        fn stop(&self) {
            self.commands.send(Command::Stop).unwrap();
            wait_for_event(&self.events, "disconnected state", |event| {
                matches!(
                    event,
                    Event::StateChanged {
                        state: ConnectionState::Disconnected
                    }
                )
            });
        }

        fn cleanup(self) {
            std::fs::remove_dir_all(self.directory).unwrap();
        }
    }

    #[test]
    fn stdio_worker_replays_load_updates_prompts_and_closes() {
        let nonce = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory =
            std::env::temp_dir().join(format!("avante-acp-stdio-{}-{nonce}", std::process::id()));
        let root = directory.join("root");
        std::fs::create_dir_all(&root).unwrap();
        let executable = compile_stdio_agent(&directory);
        let close_marker = directory.join("closed");
        let events = Arc::new(Mutex::new(Vec::new()));
        let commands = super::start(
            ClientConfig {
                command: executable.to_string_lossy().into_owned(),
                args: Vec::new(),
                env: BTreeMap::from([(
                    "AVANTE_ACP_TEST_CLOSE_MARKER".to_string(),
                    close_marker.to_string_lossy().into_owned(),
                )]),
                auth_method: None,
                read_text_file: false,
                write_text_file: false,
                session_close_timeout_ms: 1_000,
            },
            Arc::clone(&events),
        )
        .unwrap();

        wait_for_event(&events, "ready state", |event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Ready
                }
            )
        });
        commands
            .send(Command::LoadSession {
                operation_id: 1,
                request: LoadSessionRequest::new("s1", &root),
            })
            .unwrap();
        wait_for_event(&events, "load completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 1,
                    ..
                }
            )
        });

        {
            let events = events.lock().unwrap();
            let replay = events
                .iter()
                .position(|event| {
                    matches!(
                        event,
                        Event::SessionUpdate {
                            notification,
                            replayed: true,
                            ..
                        } if notification["update"]["content"]["text"] == "replayed"
                    )
                })
                .expect("load must emit its replayed update");
            let completed = events
                .iter()
                .position(|event| {
                    matches!(
                        event,
                        Event::OperationCompleted {
                            operation_id: 1,
                            ..
                        }
                    )
                })
                .unwrap();
            assert!(replay < completed, "replay must precede load completion");
        }

        let prompt: PromptRequest = serde_json::from_value(serde_json::json!({
            "sessionId": "s1",
            "prompt": [{ "type": "text", "text": "hello" }]
        }))
        .unwrap();
        commands
            .send(Command::Prompt {
                operation_id: 2,
                request: prompt,
            })
            .unwrap();
        wait_for_event(&events, "prompt completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 2,
                    result,
                } if result["stopReason"] == "end_turn"
            )
        });
        assert!(events.lock().unwrap().iter().any(|event| {
            matches!(
                event,
                Event::SessionUpdate {
                    notification,
                    replayed: false,
                    ..
                } if notification["update"]["content"]["text"] == "live"
            )
        }));

        commands.send(Command::Stop).unwrap();
        wait_for_event(&events, "disconnected state", |event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Disconnected
                }
            )
        });
        assert_eq!(std::fs::read_to_string(close_marker).unwrap(), "closed");
        assert!(
            !events
                .lock()
                .unwrap()
                .iter()
                .any(|event| matches!(event, Event::FatalError { .. }))
        );

        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn stdio_worker_authenticates_and_creates_a_session() {
        let agent = TestAgent::start("auth-new", "auth-new", Some("test-auth"), false, false);
        agent.wait_ready();
        agent
            .commands
            .send(Command::NewSession {
                operation_id: 1,
                request: NewSessionRequest::new(&agent.root),
            })
            .unwrap();
        wait_for_event(&agent.events, "new session completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 1,
                    result,
                } if result["sessionId"] == "s1"
            )
        });
        agent.prompt(2, "hello");
        wait_for_event(&agent.events, "prompt completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 2,
                    result,
                } if result["stopReason"] == "end_turn"
            )
        });
        agent.stop();
        assert_eq!(
            std::fs::read_to_string(&agent.close_marker).unwrap(),
            "closed"
        );
        assert!(
            !agent
                .events
                .lock()
                .unwrap()
                .iter()
                .any(|event| matches!(event, Event::FatalError { .. }))
        );
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_reports_authentication_failures() {
        let agent = TestAgent::start("auth-error", "auth-error", Some("test-auth"), false, false);
        wait_for_event(&agent.events, "authentication failure", |event| {
            matches!(event, Event::FatalError { .. })
        });
        wait_for_event(&agent.events, "disconnected state", |event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Disconnected
                }
            )
        });
        let events = agent.events.lock().unwrap();
        let error = events
            .iter()
            .find_map(|event| match event {
                Event::FatalError { error } => Some(error),
                _ => None,
            })
            .unwrap();
        assert_eq!(error.code, -32000);
        assert!(!events.iter().any(|event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Ready
                }
            )
        }));
        drop(events);
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_round_trips_client_requests_and_config() {
        let nonce = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "avante-acp-client-requests-{}-{nonce}",
            std::process::id()
        ));
        let root = directory.join("root");
        std::fs::create_dir_all(&root).unwrap();
        let executable = compile_stdio_agent(&directory);
        let close_marker = directory.join("closed");
        let events = Arc::new(Mutex::new(Vec::new()));
        let commands = super::start(
            ClientConfig {
                command: executable.to_string_lossy().into_owned(),
                args: Vec::new(),
                env: BTreeMap::from([
                    (
                        "AVANTE_ACP_TEST_EXERCISE_CLIENT_REQUESTS".to_string(),
                        "1".to_string(),
                    ),
                    (
                        "AVANTE_ACP_TEST_ROOT".to_string(),
                        root.to_string_lossy().into_owned(),
                    ),
                    (
                        "AVANTE_ACP_TEST_CLOSE_MARKER".to_string(),
                        close_marker.to_string_lossy().into_owned(),
                    ),
                ]),
                auth_method: None,
                read_text_file: true,
                write_text_file: true,
                session_close_timeout_ms: 1_000,
            },
            Arc::clone(&events),
        )
        .unwrap();

        wait_for_event(&events, "ready state", |event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Ready
                }
            )
        });
        commands
            .send(Command::LoadSession {
                operation_id: 1,
                request: LoadSessionRequest::new("s1", &root),
            })
            .unwrap();
        wait_for_event(&events, "load completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 1,
                    ..
                }
            )
        });

        let prompt: PromptRequest = serde_json::from_value(serde_json::json!({
            "sessionId": "s1",
            "prompt": [{ "type": "text", "text": "exercise client requests" }]
        }))
        .unwrap();
        commands
            .send(Command::Prompt {
                operation_id: 2,
                request: prompt,
            })
            .unwrap();

        wait_for_event(&events, "permission request", |event| {
            matches!(event, Event::PermissionRequest { .. })
        });
        let permission_id = {
            let events = events.lock().unwrap();
            let event = events
                .iter()
                .find(|event| matches!(event, Event::PermissionRequest { .. }))
                .unwrap();
            let value = serde_json::to_value(event).unwrap();
            assert_eq!(value["request"]["toolCall"]["toolCallId"], "tool-1");
            assert_eq!(value["request"]["options"][0]["optionId"], "allow");
            value["requestId"].as_u64().unwrap()
        };
        commands
            .send(Command::RespondPermission {
                request_id: permission_id,
                option_id: Some("allow".to_string()),
            })
            .unwrap();

        wait_for_event(&events, "read request", |event| {
            matches!(event, Event::ReadTextFileRequest { .. })
        });
        let read_id = {
            let events = events.lock().unwrap();
            let event = events
                .iter()
                .find(|event| matches!(event, Event::ReadTextFileRequest { .. }))
                .unwrap();
            let value = serde_json::to_value(event).unwrap();
            assert_eq!(
                value["request"]["path"],
                root.join("read.txt").to_string_lossy().as_ref()
            );
            assert_eq!(value["request"]["line"], 1);
            assert_eq!(value["request"]["limit"], 2);
            value["requestId"].as_u64().unwrap()
        };
        commands
            .send(Command::RespondRead {
                request_id: read_id,
                content: "from lua".to_string(),
            })
            .unwrap();

        wait_for_event(&events, "write request", |event| {
            matches!(event, Event::WriteTextFileRequest { .. })
        });
        let write_id = {
            let events = events.lock().unwrap();
            let event = events
                .iter()
                .find(|event| matches!(event, Event::WriteTextFileRequest { .. }))
                .unwrap();
            let value = serde_json::to_value(event).unwrap();
            assert_eq!(
                value["request"]["path"],
                root.join("write.txt").to_string_lossy().as_ref()
            );
            assert_eq!(value["request"]["content"], "updated");
            value["requestId"].as_u64().unwrap()
        };
        commands
            .send(Command::RespondWrite {
                request_id: write_id,
            })
            .unwrap();

        wait_for_event(&events, "config update", |event| {
            matches!(
                event,
                Event::SessionUpdate {
                    config_options: Some(_),
                    ..
                }
            )
        });
        {
            let events = events.lock().unwrap();
            let event = events
                .iter()
                .find(|event| {
                    matches!(
                        event,
                        Event::SessionUpdate {
                            config_options: Some(_),
                            ..
                        }
                    )
                })
                .unwrap();
            let value = serde_json::to_value(event).unwrap();
            assert_eq!(
                value["notification"]["update"]["sessionUpdate"],
                "config_option_update"
            );
            assert_eq!(value["configOptions"][0]["id"], "thinking");
            assert_eq!(value["configOptions"][0]["currentValue"], true);
        }
        commands
            .send(Command::SetSessionOption {
                operation_id: 3,
                session_id: "s1".to_string(),
                config_id: "thinking".to_string(),
                value: SessionConfigOptionValue::boolean(false),
            })
            .unwrap();

        wait_for_event(&events, "config option completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 3,
                    result,
                } if result["configOptions"][0]["currentValue"] == false
            )
        });
        wait_for_event(&events, "prompt completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 2,
                    result,
                } if result["stopReason"] == "end_turn"
            )
        });

        commands.send(Command::Stop).unwrap();
        wait_for_event(&events, "disconnected state", |event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Disconnected
                }
            )
        });
        assert_eq!(std::fs::read_to_string(close_marker).unwrap(), "closed");
        assert!(
            !events
                .lock()
                .unwrap()
                .iter()
                .any(|event| matches!(event, Event::FatalError { .. }))
        );
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn stdio_worker_rejects_invalid_file_requests_before_lua() {
        let agent = TestAgent::start("invalid-files", "invalid-files", None, true, true);
        agent.wait_ready();
        agent.load(1);
        agent.prompt(2, "exercise invalid file requests");
        wait_for_event(
            &agent.events,
            "prompt completion after file rejections",
            |event| {
                matches!(
                    event,
                    Event::OperationCompleted {
                        operation_id: 2,
                        ..
                    }
                )
            },
        );
        assert!(agent.events.lock().unwrap().iter().all(|event| {
            !matches!(
                event,
                Event::ReadTextFileRequest { .. } | Event::WriteTextFileRequest { .. }
            )
        }));
        assert_eq!(
            std::fs::read_to_string(&agent.scenario_marker).unwrap(),
            "invalid-files"
        );
        agent.stop();
        assert_eq!(
            std::fs::read_to_string(&agent.close_marker).unwrap(),
            "closed"
        );
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_reports_an_agent_that_exits_during_a_prompt() {
        let agent = TestAgent::start("agent-exit", "exit-on-prompt", None, false, false);
        agent.wait_ready();
        agent.load(1);
        agent.prompt(2, "exit now");
        wait_for_event(&agent.events, "fatal error", |event| {
            matches!(event, Event::FatalError { .. })
        });
        wait_for_event(&agent.events, "disconnected state", |event| {
            matches!(
                event,
                Event::StateChanged {
                    state: ConnectionState::Disconnected
                }
            )
        });
        assert!(!agent.events.lock().unwrap().iter().any(|event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 2,
                    ..
                }
            )
        }));
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_cancels_pending_permissions_and_closes_the_session() {
        let agent = TestAgent::start("cancel-close", "cancel-pending", None, false, false);
        agent.wait_ready();
        agent.load(1);
        agent.prompt(2, "wait for cancellation");
        wait_for_event(&agent.events, "permission request", |event| {
            matches!(event, Event::PermissionRequest { .. })
        });
        agent
            .commands
            .send(Command::Cancel {
                session_id: "s1".to_string(),
            })
            .unwrap();
        wait_for_event(&agent.events, "cancelled prompt", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 2,
                    result,
                } if result["stopReason"] == "cancelled"
            )
        });

        agent
            .commands
            .send(Command::CloseSession {
                operation_id: 3,
                request: CloseSessionRequest::new("s1"),
            })
            .unwrap();
        wait_for_event(&agent.events, "close completion", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 3,
                    ..
                }
            )
        });
        assert_eq!(
            std::fs::read_to_string(&agent.close_marker).unwrap(),
            "closed"
        );
        agent.stop();
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_paginates_session_lists() {
        let agent = TestAgent::start("list", "list-pages", None, false, false);
        agent.wait_ready();
        agent
            .commands
            .send(Command::ListSessions {
                operation_id: 1,
                request: ListSessionsRequest::new().cwd(agent.root.clone()),
            })
            .unwrap();
        wait_for_event(&agent.events, "session list result", |event| {
            matches!(
                event,
                Event::OperationCompleted {
                    operation_id: 1,
                    ..
                } | Event::OperationFailed {
                    operation_id: 1,
                    ..
                }
            )
        });
        {
            let events = agent.events.lock().unwrap();
            let event = events
                .iter()
                .find(|event| {
                    matches!(
                        event,
                        Event::OperationCompleted {
                            operation_id: 1,
                            ..
                        } | Event::OperationFailed {
                            operation_id: 1,
                            ..
                        }
                    )
                })
                .unwrap();
            let Event::OperationCompleted { result, .. } = event else {
                panic!("session list failed: {event:?}");
            };
            assert_eq!(result.as_array().unwrap().len(), 2);
            assert_eq!(result[0]["sessionId"], "s1");
            assert_eq!(result[1]["sessionId"], "s2");
        }
        agent.stop();
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_rejects_repeated_session_list_cursors() {
        let agent = TestAgent::start("list-repeat", "list-repeat", None, false, false);
        agent.wait_ready();
        agent
            .commands
            .send(Command::ListSessions {
                operation_id: 1,
                request: ListSessionsRequest::new().cwd(agent.root.clone()),
            })
            .unwrap();
        wait_for_event(&agent.events, "repeated cursor failure", |event| {
            matches!(
                event,
                Event::OperationFailed {
                    operation_id: 1,
                    ..
                }
            )
        });
        {
            let events = agent.events.lock().unwrap();
            let error = events
                .iter()
                .find_map(|event| match event {
                    Event::OperationFailed {
                        operation_id: 1,
                        error,
                    } => Some(error),
                    _ => None,
                })
                .unwrap();
            assert_eq!(
                error.data.as_ref().and_then(serde_json::Value::as_str),
                Some("session list returned a repeated cursor")
            );
        }
        agent.stop();
        agent.cleanup();
    }

    #[test]
    fn stdio_worker_stops_while_initialize_is_pending() {
        let nonce = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "avante-acp-initialize-stop-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let executable = compile_stdio_agent(&directory);
        let initialize_seen = directory.join("initialize-seen");
        let initialize_gate = directory.join("initialize-gate");
        let events = Arc::new(Mutex::new(Vec::new()));
        let commands = super::start(
            ClientConfig {
                command: executable.to_string_lossy().into_owned(),
                args: Vec::new(),
                env: BTreeMap::from([
                    (
                        "AVANTE_ACP_TEST_INITIALIZE_SEEN_MARKER".to_string(),
                        initialize_seen.to_string_lossy().into_owned(),
                    ),
                    (
                        "AVANTE_ACP_TEST_INITIALIZE_GATE".to_string(),
                        initialize_gate.to_string_lossy().into_owned(),
                    ),
                ]),
                auth_method: None,
                read_text_file: false,
                write_text_file: false,
                session_close_timeout_ms: 1_000,
            },
            Arc::clone(&events),
        )
        .unwrap();

        let marker_deadline = Instant::now() + Duration::from_secs(10);
        while !initialize_seen.exists() {
            assert!(
                Instant::now() < marker_deadline,
                "agent did not receive initialize"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        commands.send(Command::Stop).unwrap();

        let stop_deadline = Instant::now() + Duration::from_secs(2);
        let stopped_while_pending = loop {
            if events.lock().unwrap().iter().any(|event| {
                matches!(
                    event,
                    Event::StateChanged {
                        state: ConnectionState::Disconnected
                    }
                )
            }) {
                break true;
            }
            if Instant::now() >= stop_deadline {
                break false;
            }
            std::thread::sleep(Duration::from_millis(10));
        };

        if !stopped_while_pending {
            std::fs::write(&initialize_gate, "continue").unwrap();
            wait_for_event(&events, "cleanup after releasing initialize", |event| {
                matches!(
                    event,
                    Event::StateChanged {
                        state: ConnectionState::Disconnected
                    }
                )
            });
        }
        assert!(
            stopped_while_pending,
            "stop must interrupt a pending initialize request"
        );
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn stdio_worker_stops_while_authentication_is_pending() {
        let agent = TestAgent::start("auth-stop", "auth-pending", Some("test-auth"), false, false);
        let marker_deadline = Instant::now() + Duration::from_secs(10);
        while !agent.authenticate_seen.exists() {
            assert!(
                Instant::now() < marker_deadline,
                "agent did not receive authenticate; events: {:?}",
                agent.events.lock().unwrap()
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        agent.commands.send(Command::Stop).unwrap();

        let stop_deadline = Instant::now() + Duration::from_secs(2);
        let stopped_while_pending = loop {
            if agent.events.lock().unwrap().iter().any(|event| {
                matches!(
                    event,
                    Event::StateChanged {
                        state: ConnectionState::Disconnected
                    }
                )
            }) {
                break true;
            }
            if Instant::now() >= stop_deadline {
                break false;
            }
            std::thread::sleep(Duration::from_millis(10));
        };

        if !stopped_while_pending {
            std::fs::write(&agent.authenticate_gate, "continue").unwrap();
            wait_for_event(
                &agent.events,
                "cleanup after releasing authentication",
                |event| {
                    matches!(
                        event,
                        Event::StateChanged {
                            state: ConnectionState::Disconnected
                        }
                    )
                },
            );
        }
        assert!(
            stopped_while_pending,
            "stop must interrupt a pending authentication request"
        );
        agent.cleanup();
    }

    #[tokio::test]
    async fn command_wait_fails_when_the_agent_connection_closes() {
        let (_sender, mut commands) = tokio::sync::mpsc::unbounded_channel();

        let error = super::wait_for_command_or_close(&mut commands, std::future::ready(()))
            .await
            .unwrap_err();

        assert!(error.to_string().contains("connection closed"));
    }

    #[test]
    fn client_info_uses_unknown_version() {
        let value = serde_json::to_value(super::client_implementation()).unwrap();

        assert_eq!(value["name"], "avante.nvim");
        assert_eq!(value["version"], "unknown");
    }

    #[test]
    fn prompt_content_is_checked_against_negotiated_capabilities() {
        let request: PromptRequest = serde_json::from_value(serde_json::json!({
            "sessionId": "s1",
            "prompt": [{ "type": "image", "data": "AA==", "mimeType": "image/png" }]
        }))
        .unwrap();

        let error = super::validate_prompt(&request, &AgentCapabilities::new()).unwrap_err();
        assert!(error.data.unwrap().to_string().contains("image"));
        assert!(
            super::validate_prompt(
                &request,
                &AgentCapabilities::new()
                    .prompt_capabilities(PromptCapabilities::new().image(true))
            )
            .is_ok()
        );
    }

    #[test]
    fn additional_directories_require_agent_support() {
        let request = agent_client_protocol::schema::v1::NewSessionRequest::new("/tmp")
            .additional_directories(vec!["/shared".into()]);

        let error = super::validate_session_setup(
            &request.additional_directories,
            &request.mcp_servers,
            &AgentCapabilities::new(),
        )
        .unwrap_err();
        assert!(
            error
                .data
                .unwrap()
                .to_string()
                .contains("additionalDirectories")
        );
    }

    #[test]
    fn current_config_options_take_precedence_over_legacy_modes() {
        let mut backend = None;

        super::merge_config_backend(&mut backend, super::ConfigBackend::Modes);
        assert_eq!(backend, Some(super::ConfigBackend::Modes));

        super::merge_config_backend(&mut backend, super::ConfigBackend::Options);
        assert_eq!(backend, Some(super::ConfigBackend::Options));

        super::merge_config_backend(&mut backend, super::ConfigBackend::Modes);
        assert_eq!(backend, Some(super::ConfigBackend::Options));
    }

    #[test]
    fn file_paths_are_confined_to_canonical_session_roots() {
        let root = std::env::temp_dir().join(format!("avante-acp-root-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let roots = super::canonical_roots([root.as_path()]).unwrap();

        assert_eq!(
            super::validate_file_path(&root.join("new.txt"), &roots).unwrap(),
            root.join("new.txt")
        );
        assert!(super::validate_file_path(&root.join("../outside.txt"), &roots).is_err());

        std::fs::remove_dir_all(root).unwrap();
    }
}
