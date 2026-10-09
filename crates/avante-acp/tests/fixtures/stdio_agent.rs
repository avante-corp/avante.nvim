use std::io::{self, BufRead, Write};

fn request_id(line: &str) -> &str {
    let value = line
        .split_once("\"id\":")
        .expect("request must contain an id")
        .1;
    value
        .split_once(',')
        .or_else(|| value.split_once('}'))
        .expect("request id must be followed by a delimiter")
        .0
}

fn json_string(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
    )
}

fn send(stdout: &mut impl Write, message: &str) {
    writeln!(stdout, "{message}").expect("message must be writable");
    stdout.flush().expect("message must be flushed");
}

fn respond(stdout: &mut impl Write, id: &str, result: &str) {
    send(
        stdout,
        &format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{result}}}"#),
    );
}

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let scenario = std::env::var("AVANTE_ACP_TEST_SCENARIO").unwrap_or_default();
    let exercise_client_requests =
        std::env::var_os("AVANTE_ACP_TEST_EXERCISE_CLIENT_REQUESTS").is_some();
    let root = std::env::var_os("AVANTE_ACP_TEST_ROOT").map(std::path::PathBuf::from);
    let mut pending_prompt_id = None;
    let mut pending_client_responses = 0;
    let mut pending_cancel_messages = 0;

    for line in stdin.lock().lines() {
        let line = line.expect("stdin must be readable");
        if scenario == "exit-on-prompt" && line.contains("\"method\":\"session/prompt\"") {
            return;
        }
        if scenario == "cancel-pending" && line.contains("\"method\":\"session/prompt\"") {
            send(
                &mut stdout,
                r#"{"jsonrpc":"2.0","id":300,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"tool-cancel","title":"Wait","kind":"execute","status":"pending"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}"#,
            );
            pending_prompt_id = Some(request_id(&line).to_string());
            pending_cancel_messages = 2;
            continue;
        }
        if scenario == "invalid-files" && line.contains("\"method\":\"session/prompt\"") {
            let root = root.as_ref().expect("test root must be configured");
            let outside = root.parent().unwrap().join("outside.txt");
            send(
                &mut stdout,
                &format!(
                    r#"{{"jsonrpc":"2.0","id":201,"method":"fs/read_text_file","params":{{"sessionId":"s1","path":{}}}}}"#,
                    json_string(&outside.to_string_lossy())
                ),
            );
            send(
                &mut stdout,
                &format!(
                    r#"{{"jsonrpc":"2.0","id":202,"method":"fs/read_text_file","params":{{"sessionId":"s1","path":{},"line":0}}}}"#,
                    json_string(&root.join("read.txt").to_string_lossy())
                ),
            );
            send(
                &mut stdout,
                &format!(
                    r#"{{"jsonrpc":"2.0","id":203,"method":"fs/write_text_file","params":{{"sessionId":"s1","path":{},"content":"denied"}}}}"#,
                    json_string(&outside.to_string_lossy())
                ),
            );
            pending_prompt_id = Some(request_id(&line).to_string());
            pending_client_responses = 3;
            continue;
        }
        if exercise_client_requests && line.contains("\"method\":\"session/prompt\"") {
            let root = root.as_ref().expect("test root must be configured");
            send(
                &mut stdout,
                r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"thinking","name":"Thinking","category":"thought_level","type":"boolean","currentValue":true}]}}}"#,
            );
            send(
                &mut stdout,
                r#"{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"tool-1","title":"Edit","kind":"edit","status":"pending"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}"#,
            );
            send(
                &mut stdout,
                &format!(
                    r#"{{"jsonrpc":"2.0","id":101,"method":"fs/read_text_file","params":{{"sessionId":"s1","path":{},"line":1,"limit":2}}}}"#,
                    json_string(&root.join("read.txt").to_string_lossy())
                ),
            );
            send(
                &mut stdout,
                &format!(
                    r#"{{"jsonrpc":"2.0","id":102,"method":"fs/write_text_file","params":{{"sessionId":"s1","path":{},"content":"updated"}}}}"#,
                    json_string(&root.join("write.txt").to_string_lossy())
                ),
            );
            pending_prompt_id = Some(request_id(&line).to_string());
            pending_client_responses = 3;
            continue;
        }

        if scenario == "cancel-pending"
            && (line.contains("\"id\":300") || line.contains("\"method\":\"session/cancel\""))
        {
            if line.contains("\"id\":300") {
                assert!(line.contains("\"outcome\":\"cancelled\""));
            } else {
                assert!(line.contains("\"sessionId\":\"s1\""));
            }
            pending_cancel_messages -= 1;
            if pending_cancel_messages == 0 {
                respond(
                    &mut stdout,
                    pending_prompt_id.take().as_deref().unwrap(),
                    r#"{"stopReason":"cancelled"}"#,
                );
            }
            continue;
        }

        if scenario == "invalid-files"
            && ["\"id\":201", "\"id\":202", "\"id\":203"]
                .iter()
                .any(|id| line.contains(id))
        {
            assert!(line.contains("\"code\":-32602"));
            pending_client_responses -= 1;
            if pending_client_responses == 0 {
                std::fs::write(
                    std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                        .expect("scenario marker path must be configured"),
                    "invalid-files",
                )
                .expect("scenario marker must be writable");
                respond(
                    &mut stdout,
                    pending_prompt_id.take().as_deref().unwrap(),
                    r#"{"stopReason":"end_turn"}"#,
                );
            }
            continue;
        }

        let client_response = if exercise_client_requests && line.contains("\"id\":100") {
            assert!(line.contains("\"outcome\":\"selected\""));
            assert!(line.contains("\"optionId\":\"allow\""));
            true
        } else if exercise_client_requests && line.contains("\"id\":101") {
            assert!(line.contains("\"content\":\"from lua\""));
            true
        } else if exercise_client_requests && line.contains("\"id\":102") {
            assert!(line.contains("\"result\":{}"));
            true
        } else {
            false
        };
        if client_response {
            pending_client_responses -= 1;
            if pending_client_responses == 0 {
                send(
                    &mut stdout,
                    r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"live"}}}}"#,
                );
                respond(
                    &mut stdout,
                    pending_prompt_id.take().as_deref().unwrap(),
                    r#"{"stopReason":"end_turn"}"#,
                );
            }
            continue;
        }

        let result = if line.contains("\"method\":\"initialize\"") {
            if let Some(marker) = std::env::var_os("AVANTE_ACP_TEST_INITIALIZE_SEEN_MARKER") {
                std::fs::write(marker, "seen").expect("initialize marker must be writable");
            }
            if let Some(gate) = std::env::var_os("AVANTE_ACP_TEST_INITIALIZE_GATE") {
                while !std::path::Path::new(&gate).exists() {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
            }
            if matches!(
                scenario.as_str(),
                "auth-new" | "auth-pending" | "auth-error"
            ) {
                r#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{}}},"authMethods":[{"id":"test-auth","name":"Test auth"}]}"#
            } else if scenario == "list-pages" || scenario == "list-repeat" {
                r#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{},"list":{}}}}"#
            } else {
                r#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{}}}}"#
            }
        } else if line.contains("\"method\":\"authenticate\"") {
            assert!(matches!(
                scenario.as_str(),
                "auth-new" | "auth-pending" | "auth-error"
            ));
            assert!(line.contains("\"methodId\":\"test-auth\""));
            if scenario == "auth-error" {
                send(
                    &mut stdout,
                    &format!(
                        r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32000,"message":"Authentication required"}}}}"#,
                        request_id(&line)
                    ),
                );
                continue;
            }
            if let Some(marker) = std::env::var_os("AVANTE_ACP_TEST_AUTHENTICATE_SEEN_MARKER") {
                std::fs::write(marker, "seen").expect("authenticate marker must be writable");
            }
            if let Some(gate) = std::env::var_os("AVANTE_ACP_TEST_AUTHENTICATE_GATE") {
                while !std::path::Path::new(&gate).exists() {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
            }
            "{}"
        } else if line.contains("\"method\":\"session/new\"") {
            assert_eq!(scenario, "auth-new");
            r#"{"sessionId":"s1"}"#
        } else if line.contains("\"method\":\"session/list\"") {
            assert!(scenario == "list-pages" || scenario == "list-repeat");
            let root = json_string(
                &root
                    .as_ref()
                    .expect("test root must be configured")
                    .to_string_lossy(),
            );
            if scenario == "list-repeat" {
                respond(
                    &mut stdout,
                    request_id(&line),
                    &format!(
                        r#"{{"sessions":[{{"sessionId":"s1","cwd":{root}}}],"nextCursor":"repeat"}}"#
                    ),
                );
                continue;
            }
            if line.contains("\"cursor\":\"next\"") {
                respond(
                    &mut stdout,
                    request_id(&line),
                    &format!(r#"{{"sessions":[{{"sessionId":"s2","cwd":{root}}}]}}"#),
                );
                continue;
            }
            respond(
                &mut stdout,
                request_id(&line),
                &format!(
                    r#"{{"sessions":[{{"sessionId":"s1","cwd":{root}}}],"nextCursor":"next"}}"#
                ),
            );
            continue;
        } else if line.contains("\"method\":\"session/load\"") {
            stdout
                .write_all(
                    b"{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"replayed\"}}}}\n",
                )
            .expect("replay update must be writable");
            "{}"
        } else if line.contains("\"method\":\"session/set_config_option\"") {
            assert!(line.contains("\"configId\":\"thinking\""));
            assert!(line.contains("\"type\":\"boolean\""));
            assert!(line.contains("\"value\":false"));
            r#"{"configOptions":[{"id":"thinking","name":"Thinking","category":"thought_level","type":"boolean","currentValue":false}]}"#
        } else if line.contains("\"method\":\"session/prompt\"") {
            stdout
                .write_all(
                    b"{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"live\"}}}}\n",
                )
            .expect("live update must be writable");
            r#"{"stopReason":"end_turn"}"#
        } else if line.contains("\"method\":\"session/close\"") {
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_CLOSE_MARKER")
                    .expect("close marker path must be configured"),
                "closed",
            )
            .expect("close marker must be writable");
            "{}"
        } else {
            continue;
        };

        respond(&mut stdout, request_id(&line), result);
    }
}
