use agent_client_protocol::{
    AcpAgent, Agent, Channel, Client, ConnectTo, ConnectionDriver, TransportFrame,
};
use futures::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, StreamExt};
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Notify, watch};

const MAX_FRAME_BYTES: u64 = 8 * 1024 * 1024;
const STDERR_TAIL_BYTES: usize = 64 * 1024;

// SDK 3.1's process adapter reads into an unbounded channel. Keep its parser and
// process launch rules, but allow only one queued frame ahead of the dispatcher.
pub(super) struct BoundedAgent {
    pub agent: AcpAgent,
    pub received: Arc<Notify>,
}

struct ChildGuard(async_process::Child);

impl ChildGuard {
    fn terminate(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = rustix::process::Pid::from_raw(self.0.id().cast_signed()) {
            let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
        }
        let _ = self.0.kill();
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn io_error(error: impl std::fmt::Display) -> agent_client_protocol::Error {
    agent_client_protocol::Error::new(-32603, error.to_string())
}

impl BoundedAgent {
    fn transport(self) -> (Channel, ConnectionDriver) {
        let (channel, Channel { mut rx, tx }) = Channel::duplex();
        let (finish_tx, mut finish_rx) = watch::channel(false);
        let driver = ConnectionDriver::with_finish(
            async move {
                let mut writer_finish = finish_rx.clone();
                let shutdown = async {
                    if finish_rx.wait_for(|finished| *finished).await.is_err() {
                        std::future::pending::<()>().await;
                    }
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    agent_client_protocol::Error::new(
                        super::TIMEOUT_ERROR_CODE,
                        "Timed out draining ACP stdin during shutdown",
                    )
                };
                let (mut stdin, stdout, mut stderr, child) = self.agent.spawn_process()?;
                let mut child = ChildGuard(child);
                let tail = std::sync::Mutex::new(VecDeque::new());
                let read_stderr = async {
                    let mut buffer = [0; 8192];
                    loop {
                        let count = stderr.read(&mut buffer).await.map_err(io_error)?;
                        if count == 0 {
                            return Ok::<_, agent_client_protocol::Error>(());
                        }
                        {
                            let mut tail = tail
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                            tail.extend(&buffer[..count]);
                            let excess = tail.len().saturating_sub(STDERR_TAIL_BYTES);
                            tail.drain(..excess);
                        }
                        tokio::task::yield_now().await;
                    }
                };
                tokio::pin!(read_stderr);
                let incoming = async {
                    let mut stdout = futures::io::BufReader::new(stdout);
                    loop {
                        while !tx.is_empty() {
                            tokio::select! {
                                () = self.received.notified() => {},
                                // Malformed frames are handled inside the SDK, without our callback.
                                () = tokio::time::sleep(Duration::from_millis(10)) => {},
                            }
                        }
                        let mut line = Vec::new();
                        let count = (&mut stdout)
                            .take(MAX_FRAME_BYTES + 1)
                            .read_until(b'\n', &mut line)
                            .await
                            .map_err(io_error)?;
                        if count == 0 {
                            return Ok::<_, agent_client_protocol::Error>(());
                        }
                        if count as u64 > MAX_FRAME_BYTES {
                            return Err(io_error("ACP frame exceeds 8 MiB"));
                        }
                        let line = std::str::from_utf8(&line).map_err(io_error)?;
                        tx.unbounded_send(TransportFrame::parse_json(line))
                            .map_err(io_error)?;
                    }
                };
                let outgoing = async {
                    loop {
                        let frame = tokio::select! {
                            biased;
                            _ = writer_finish.wait_for(|finished| *finished) => {
                                rx.close();
                                break;
                            },
                            frame = rx.next() => frame,
                        };
                        let Some(frame) = frame else {
                            break;
                        };
                        stdin
                            .write_all(frame.to_json()?.as_bytes())
                            .await
                            .map_err(io_error)?;
                        stdin.write_all(b"\n").await.map_err(io_error)?;
                        stdin.flush().await.map_err(io_error)?;
                    }
                    while let Some(frame) = rx.next().await {
                        stdin
                            .write_all(frame.to_json()?.as_bytes())
                            .await
                            .map_err(io_error)?;
                        stdin.write_all(b"\n").await.map_err(io_error)?;
                    }
                    stdin.close().await.map_err(io_error)
                };
                tokio::pin!(incoming, outgoing, shutdown);
                let drain_deadline = tokio::time::sleep(Duration::from_secs(1));
                tokio::pin!(drain_deadline);
                let mut stderr_done = false;
                let mut exit_status = None;
                let mut write_error = None;
                loop {
                    tokio::select! {
                        biased;
                        result = &mut read_stderr, if !stderr_done => {
                            result?;
                            stderr_done = true;
                        },
                        status = child.0.status(), if exit_status.is_none() => {
                            exit_status = Some(status.map_err(io_error)?);
                            // Close pipes inherited by descendants, then drain stdout to EOF.
                            child.terminate();
                        },
                        result = &mut incoming => {
                            result?;
                            let status = if let Some(status) = exit_status { status } else {
                                tokio::time::timeout(Duration::from_secs(1), async {
                                    loop {
                                        tokio::select! {
                                            status = child.0.status() => return status.map_err(io_error),
                                            result = &mut read_stderr, if !stderr_done => {
                                                result?;
                                                stderr_done = true;
                                            },
                                        }
                                    }
                                }).await
                                    .map_err(|_| io_error("ACP stdout closed before the process exited"))?
                                    ?
                            };
                            if !stderr_done {
                                let _ = tokio::time::timeout(Duration::from_millis(100), &mut read_stderr).await;
                            }
                            if status.success() { return Ok(()); }
                            let mut tail = tail.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                            return Err(io_error(format!("ACP process exited with {status}: {}",
                                String::from_utf8_lossy(tail.make_contiguous()))));
                        },
                        result = &mut outgoing, if write_error.is_none() => {
                            match result {
                                Ok(()) => return Ok(()),
                                Err(error) => {
                                    // A closed stdin can precede the final stdout response.
                                    write_error = Some(error);
                                    drain_deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(1));
                                },
                            }
                        },
                        () = &mut drain_deadline, if write_error.is_some() => {
                            return Err(write_error.take().expect("stdin failed before drain deadline"));
                        },
                        error = &mut shutdown => return Err(error),
                    }
                }
            },
            move || {
                finish_tx.send_replace(true);
            },
        );
        (channel, driver)
    }
}

impl ConnectTo<Client> for BoundedAgent {
    async fn connect_to(self, client: impl ConnectTo<Agent>) -> agent_client_protocol::Result<()> {
        let (channel, mut driver) = self.transport();
        tokio::select! {
            result = client.connect_to(channel) => {
                result?;
                let _ = driver.request_finish();
                driver.await
            },
            result = &mut driver => result,
        }
    }

    fn into_channel_and_future(self) -> (Channel, Option<ConnectionDriver>) {
        let (channel, driver) = self.transport();
        (channel, Some(driver))
    }
}
