# ACP native boundary

Lua owns Neovim UI, chat history, user permission decisions and editor buffer access.
Rust owns the agent process, typed ACP requests, session routing, path validation,
pending responders and request deadlines. Lua callbacks are scoped to the chat and
native connection that started the request.
Submission captures its project directory and provider configuration before
asynchronous initialization. Session and configuration pickers discard selections
when their originating tab, chat or provider has changed.

The official SDK supplies protocol parsing, schemas, response correlation and process
launch settings. SDK 3.1's default process and active-session adapters contain
unbounded queues. `transport.rs` therefore reads at most one queued frame ahead of
the SDK dispatcher, and `worker.rs` forwards session events directly into the
bounded Lua event queue. Ordered SDK response callbacks install a new session or
end replay before later notifications are dispatched.

The queue admits at most 4,096 events and uses an 8 MiB serialized-size budget. An
individual event larger than the budget occupies it alone; incoming wire frames
are limited to 8 MiB including their newline. These are buffer limits, not a total
process-memory limit: parsed objects, a frame being processed and Lua's drained
batch also consume memory. Stderr retains only its last 64 KiB. On Unix, teardown
kills the process group, including wrapper-launched descendants; on Windows it
kills the direct child, matching the SDK's process adapter.

An active prompt has a two-second cancellation deadline. Missing that deadline
terminates the connection and reports a timeout to pending Lua operations. Stop
wakes blocked event producers before shutting down sessions; transport shutdown
allows 250 ms to drain stdin before killing a process that will not read it. Normal
cancellation keeps the connection usable after the prompt response arrives.
Prompts enter the outgoing queue before subsequent cancellation commands, and
cancelling sessions automatically decline crossed permission requests. A successful
close/delete settles any remaining prompt as cancelled; responses received before
the close acknowledgment retain their result, while later replies are ignored.
After close/delete, an unanswered prompt gets two seconds to return its protocol
response. Missing that deadline retires the connection, releasing the SDK's
internal callbacks. Other request timeouts also retire the connection, even when
the Lua event queue is full; completed operations are never delivered twice.
Graceful user shutdown still sends session close requests before terminating the
process.

If writing stdin fails, the transport continues reading stdout for up to one
second so a process exiting concurrently can deliver its final response. Explicit
shutdown still applies its stdin drain deadline. Stderr continues draining after
stdout closes, so a final log burst cannot block process exit. Rust rejects
directories and special files as file targets. Lua reads buffers by exact resolved
file identity, rejects special files, checks unsaved edits before writing, and
keeps permission controls on the sidebar that owns the request. ACP permission IDs
are returned unchanged; agent-scoped persistent approval does not enable approval
of every tool in Lua.
Replacing an inline permission explicitly cancels its predecessor, and cancelled
requests cannot approve permissions already queued for Lua processing.
Session initialization must complete before a client can be reused for a prompt
or configuration picker. Updates and permissions from inactive sessions cannot
enter the current conversation. Agent slash commands belong to their session and
are available independently of the completion plugin.

Session imports collect text chunks per message and concatenate them once after
replay, avoiding repeated copies of growing text on Neovim's main thread.

Run `cargo test --offline -p avante-acp` for native tests and
`CARGO_NET_OFFLINE=true make acp-integration-test` for the Lua/native/stdio boundary.
The latter builds a local fixture agent and exercises replay, cancellation,
permission/file callbacks and paused-consumer backpressure.
The Lua test runner reports errors from scheduled callbacks as test failures;
unit fixtures isolate Docker, clipboard and authentication-file side effects.
