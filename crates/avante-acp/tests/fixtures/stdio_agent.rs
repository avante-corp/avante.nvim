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

fn numbered_updates(stdout: &mut impl Write, count: usize) {
    for index in 1..=count {
        let kind = if index % 2 == 0 {
            "agent_thought_chunk"
        } else {
            "agent_message_chunk"
        };
        writeln!(
            stdout,
            r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{{"sessionUpdate":"{kind}","content":{{"type":"text","text":"{index}"}}}}}}}}"#,
        )
        .expect("session update must be writable");
    }
}

fn kilobyte_updates(stdout: &mut impl Write, count: usize) {
    let padding = "x".repeat(1018);
    for index in 1..=count {
        writeln!(
            stdout,
            r#"{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":"{index:05}:{padding}"}}}}}}}}"#,
        )
        .expect("session update must be writable");
    }
}

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let scenario = std::env::var("AVANTE_ACP_TEST_SCENARIO").unwrap_or_default();
    let exercise_client_requests =
        std::env::var_os("AVANTE_ACP_TEST_EXERCISE_CLIENT_REQUESTS").is_some();
    let root = std::env::var_os("AVANTE_ACP_TEST_ROOT").map(std::path::PathBuf::from);
    let cancel_updates = std::env::var("AVANTE_ACP_TEST_CANCEL_UPDATES")
        .ok()
        .map(|value| {
            value
                .parse()
                .expect("cancel update count must be an integer")
        })
        .unwrap_or(0);
    let mut pending_prompt_id = None;
    let mut pending_client_responses = 0;
    let mut pending_cancel_messages = 0;
    let mut prompt_cancel_order = Vec::new();

    for line in stdin.lock().lines() {
        let line = line.expect("stdin must be readable");
        if scenario == "prompt-cancel-order"
            && (line.contains("\"method\":\"session/prompt\"")
                || line.contains("\"method\":\"session/cancel\""))
        {
            if line.contains("\"method\":\"session/prompt\"") {
                prompt_cancel_order.push("session/prompt");
                pending_prompt_id = Some(request_id(&line).to_string());
            } else {
                prompt_cancel_order.push("session/cancel");
            }
            if prompt_cancel_order.len() == 2 {
                std::fs::write(
                    std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                        .expect("scenario marker path must be configured"),
                    prompt_cancel_order.join("\n"),
                )
                .expect("scenario marker must be writable");
                respond(
                    &mut stdout,
                    pending_prompt_id.take().as_deref().unwrap(),
                    r#"{"stopReason":"cancelled"}"#,
                );
            }
            continue;
        }
        if scenario == "crossed-permission" && line.contains("\"method\":\"session/prompt\"") {
            pending_prompt_id = Some(request_id(&line).to_string());
            pending_cancel_messages = 2;
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_STARTED_MARKER")
                    .expect("started marker path must be configured"),
                "prompt",
            )
            .expect("started marker must be writable");
            let gate = std::env::var_os("AVANTE_ACP_TEST_OUTPUT_GATE")
                .expect("output gate path must be configured");
            while !std::path::Path::new(&gate).exists() {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            send(
                &mut stdout,
                r#"{"jsonrpc":"2.0","id":300,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"crossed","title":"In-flight permission","kind":"execute","status":"pending"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}"#,
            );
            continue;
        }
        if scenario == "crossed-permission"
            && (line.contains("\"id\":300") || line.contains("\"method\":\"session/cancel\""))
        {
            if line.contains("\"id\":300") {
                std::fs::write(
                    std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                        .expect("scenario marker path must be configured"),
                    &line,
                )
                .expect("scenario marker must be writable");
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
        if matches!(scenario.as_str(), "read-directory" | "read-special")
            && line.contains("\"method\":\"session/prompt\"")
        {
            pending_prompt_id = Some(request_id(&line).to_string());
            let root = root.as_ref().expect("test root must be configured");
            let path = if scenario == "read-special" {
                root.join("input.fifo")
            } else {
                root.clone()
            };
            send(
                &mut stdout,
                &format!(
                    r#"{{"jsonrpc":"2.0","id":301,"method":"fs/read_text_file","params":{{"sessionId":"s1","path":{}}}}}"#,
                    json_string(&path.to_string_lossy())
                ),
            );
            continue;
        }
        if matches!(scenario.as_str(), "read-directory" | "read-special")
            && line.contains("\"id\":301")
        {
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                    .expect("scenario marker path must be configured"),
                &line,
            )
            .expect("scenario marker must be writable");
            respond(
                &mut stdout,
                pending_prompt_id.take().as_deref().unwrap(),
                r#"{"stopReason":"end_turn"}"#,
            );
            continue;
        }
        if scenario == "ignore-cancel" {
            if line.contains("\"method\":\"session/prompt\"") {
                std::fs::write(
                    std::env::var_os("AVANTE_ACP_TEST_STARTED_MARKER")
                        .expect("started marker path must be configured"),
                    "prompt",
                )
                .expect("started marker must be writable");
                continue;
            }
            if line.contains("\"method\":\"session/cancel\"") {
                std::fs::write(
                    std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                        .expect("scenario marker path must be configured"),
                    "cancel",
                )
                .expect("scenario marker must be writable");
                continue;
            }
        }
        if scenario == "large-live" && line.contains("\"method\":\"session/prompt\"") {
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_STARTED_MARKER")
                    .expect("started marker path must be configured"),
                "burst",
            )
            .expect("started marker must be writable");
            kilobyte_updates(&mut stdout, 40_000);
            stdout.flush().expect("live burst must be flushed");
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                    .expect("scenario marker path must be configured"),
                "40000",
            )
            .expect("scenario marker must be writable");
            respond(
                &mut stdout,
                request_id(&line),
                r#"{"stopReason":"end_turn"}"#,
            );
            continue;
        }
        if scenario == "oversized-frame" && line.contains("\"method\":\"session/prompt\"") {
            stdout
                .write_all(&vec![b'x'; 8 * 1024 * 1024 + 1])
                .expect("oversized frame must be writable");
            stdout.flush().expect("oversized frame must be flushed");
            continue;
        }
        if matches!(scenario.as_str(), "closed-stdin-tail" | "closed-stdin-hang")
            && line.contains("\"method\":\"session/prompt\"")
        {
            #[cfg(unix)]
            {
                use std::os::fd::{FromRawFd, OwnedFd};
                // No further stdin reads: cancel must fail while stdout remains open.
                unsafe { drop(OwnedFd::from_raw_fd(0)) };
            }
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                    .expect("scenario marker path must be configured"),
                std::process::id().to_string(),
            )
            .expect("scenario marker must be writable");
            if scenario == "closed-stdin-hang" {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(60));
                }
            }
            let gate = std::env::var_os("AVANTE_ACP_TEST_OUTPUT_GATE")
                .expect("output gate path must be configured");
            while !std::path::Path::new(&gate).exists() {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        }
        if matches!(scenario.as_str(), "clean-exit-tail" | "closed-stdin-tail")
            && line.contains("\"method\":\"session/prompt\"")
        {
            let mut batch = Vec::new();
            numbered_updates(&mut batch, 256);
            respond(
                &mut batch,
                request_id(&line),
                r#"{"stopReason":"end_turn"}"#,
            );
            send(
                &mut batch,
                r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"tail"}}}}"#,
            );
            stdout
                .write_all(&batch)
                .expect("exit batch must be writable");
            stdout.flush().expect("exit batch must be flushed");
            return;
        }
        if scenario == "nonzero-exit" && line.contains("\"method\":\"session/prompt\"") {
            eprintln!("fixture-stderr-before-exit-23");
            std::process::exit(23);
        }
        if matches!(
            scenario.as_str(),
            "stdout-close-before-exit" | "stdout-close-stderr-burst"
        ) && line.contains("\"method\":\"session/prompt\"")
        {
            #[cfg(unix)]
            {
                use std::os::fd::{FromRawFd, OwnedFd};
                // No further stdout writes: force EOF before the process exits.
                unsafe { drop(OwnedFd::from_raw_fd(1)) };
                std::thread::sleep(std::time::Duration::from_millis(30));
            }
            if scenario == "stdout-close-stderr-burst" {
                io::stderr()
                    .write_all(&vec![b'x'; 256 * 1024])
                    .expect("stderr burst must be drained");
            }
            eprintln!("fixture-stderr-after-stdout-close");
            std::process::exit(23);
        }
        if scenario == "exit-on-prompt" && line.contains("\"method\":\"session/prompt\"") {
            return;
        }
        if matches!(
            scenario.as_str(),
            "cancel-pending" | "close-pending" | "close-after-prompt" | "close-without-prompt"
        ) && line.contains("\"method\":\"session/prompt\"")
        {
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

        if matches!(
            scenario.as_str(),
            "cancel-pending" | "close-pending" | "close-after-prompt" | "close-without-prompt"
        ) && (line.contains("\"id\":300") || line.contains("\"method\":\"session/cancel\""))
        {
            if line.contains("\"id\":300") {
                assert!(line.contains("\"outcome\":\"cancelled\""));
            } else {
                assert!(line.contains("\"sessionId\":\"s1\""));
            }
            pending_cancel_messages -= 1;
            if pending_cancel_messages == 0 {
                numbered_updates(&mut stdout, cancel_updates);
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
            } else if scenario == "session-methods" {
                r#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{},"delete":{},"resume":{}}}}"#
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
            if scenario == "gated-load" {
                numbered_updates(&mut stdout, 1);
                stdout.flush().expect("first replay update must be flushed");
                let gate = std::env::var_os("AVANTE_ACP_TEST_OUTPUT_GATE")
                    .expect("output gate path must be configured");
                while !std::path::Path::new(&gate).exists() {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                send(
                    &mut stdout,
                    r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"2"}}}}"#,
                );
                respond(&mut stdout, request_id(&line), "{}");
                continue;
            }
            if scenario == "config-update-order" {
                respond(
                    &mut stdout,
                    request_id(&line),
                    r#"{"configOptions":[{"id":"thinking","name":"Thinking","type":"boolean","currentValue":true}]}"#,
                );
                continue;
            }
            if scenario == "batched-replay-live" {
                let mut batch = Vec::new();
                numbered_updates(&mut batch, 2);
                respond(&mut batch, request_id(&line), "{}");
                numbered_updates(&mut batch, 2);
                stdout
                    .write_all(&batch)
                    .expect("load batch must be writable");
                stdout.flush().expect("load batch must be flushed");
                continue;
            }
            if scenario == "large-replay-bytes" {
                kilobyte_updates(&mut stdout, 12_000);
                respond(&mut stdout, request_id(&line), "{}");
                continue;
            }
            if scenario == "large-replay" {
                numbered_updates(&mut stdout, 20_000);
                respond(&mut stdout, request_id(&line), "{}");
                continue;
            }
            stdout
                .write_all(
                    b"{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"replayed\"}}}}\n",
                )
            .expect("replay update must be writable");
            "{}"
        } else if line.contains("\"method\":\"session/resume\"") {
            assert_eq!(scenario, "session-methods");
            "{}"
        } else if line.contains("\"method\":\"session/delete\"") {
            assert_eq!(scenario, "session-methods");
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                    .expect("scenario marker path must be configured"),
                "deleted",
            )
            .expect("scenario marker must be writable");
            "{}"
        } else if line.contains("\"method\":\"session/set_config_option\"") {
            assert!(line.contains("\"configId\":\"thinking\""));
            assert!(line.contains("\"type\":\"boolean\""));
            assert!(line.contains("\"value\":false"));
            if scenario == "config-update-order" {
                send(
                    &mut stdout,
                    &format!(
                        r#"[{{"jsonrpc":"2.0","id":{},"result":{{"configOptions":[{{"id":"thinking","name":"Thinking","type":"boolean","currentValue":false}}]}}}},{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{{"sessionUpdate":"config_option_update","configOptions":[{{"id":"thinking","name":"Thinking","type":"boolean","currentValue":true}}]}}}}}}]"#,
                        request_id(&line),
                    ),
                );
                continue;
            }
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
            if scenario == "hang-close" {
                continue;
            }
            if scenario == "close-pending" {
                respond(&mut stdout, request_id(&line), "{}");
                respond(
                    &mut stdout,
                    pending_prompt_id.take().as_deref().unwrap(),
                    r#"{"stopReason":"cancelled"}"#,
                );
                continue;
            }
            if scenario == "close-after-prompt" {
                respond(
                    &mut stdout,
                    pending_prompt_id.take().as_deref().unwrap(),
                    r#"{"stopReason":"end_turn"}"#,
                );
            }
            "{}"
        } else {
            continue;
        };

        respond(&mut stdout, request_id(&line), result);
        if scenario == "blocked-stdin" && line.contains("\"method\":\"session/load\"") {
            std::fs::write(
                std::env::var_os("AVANTE_ACP_TEST_SCENARIO_MARKER")
                    .expect("scenario marker path must be configured"),
                std::process::id().to_string(),
            )
            .expect("scenario marker must be writable");
            loop {
                std::thread::sleep(std::time::Duration::from_secs(60));
            }
        }
    }
}
