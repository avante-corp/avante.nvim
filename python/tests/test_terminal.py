from __future__ import annotations

import asyncio
import sys

import pytest

from avante_acp.terminal import TerminalManager, TerminalNotFound


@pytest.fixture
async def manager():
    mgr = TerminalManager()
    try:
        yield mgr
    finally:
        await mgr.release_all()


async def test_captures_stdout_and_exit_code(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "print('hello')"])

    assert await manager.wait_for_exit(tid) == {"exitCode": 0, "signal": None}

    out = manager.output(tid)
    assert "hello" in out["output"]
    assert out["truncated"] is False
    assert out["exitStatus"] == {"exitCode": 0, "signal": None}


async def test_captures_stderr_and_nonzero_exit(manager):
    tid = await manager.create(
        "s1", sys.executable, ["-c", "import sys; sys.stderr.write('bad\\n'); sys.exit(3)"]
    )

    assert (await manager.wait_for_exit(tid))["exitCode"] == 3
    assert "bad" in manager.output(tid)["output"]


async def test_output_before_exit_has_no_exit_status(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "import time; time.sleep(5)"])

    assert "exitStatus" not in manager.output(tid)

    await manager.kill(tid)


async def test_cwd_is_honoured(manager, tmp_path):
    tid = await manager.create(
        "s1", sys.executable, ["-c", "import os; print(os.getcwd())"], cwd=str(tmp_path)
    )
    await manager.wait_for_exit(tid)

    assert str(tmp_path) in manager.output(tid)["output"]


async def test_env_variables_are_passed(manager):
    tid = await manager.create(
        "s1",
        sys.executable,
        ["-c", "import os; print(os.environ['AVANTE_TEST_VAR'])"],
        env=[{"name": "AVANTE_TEST_VAR", "value": "present"}],
    )
    await manager.wait_for_exit(tid)

    assert "present" in manager.output(tid)["output"]


async def test_output_is_truncated_to_byte_limit_keeping_the_tail(manager):
    # The end of a build log is what explains the failure, so the tail is kept.
    tid = await manager.create(
        "s1",
        sys.executable,
        ["-c", "for i in range(2000): print(f'line{i}')"],
        output_byte_limit=200,
    )
    await manager.wait_for_exit(tid)

    out = manager.output(tid)
    assert out["truncated"] is True
    assert len(out["output"].encode()) <= 200
    assert "line1999" in out["output"]


async def test_kill_reports_the_signal(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "import time; time.sleep(30)"])

    await manager.kill(tid)

    status = manager.output(tid)["exitStatus"]
    assert status["exitCode"] is None
    assert status["signal"] == "SIGKILL"


async def test_kill_is_idempotent(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "pass"])
    await manager.wait_for_exit(tid)

    await manager.kill(tid)
    await manager.kill(tid)


async def test_release_forgets_the_terminal(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "pass"])
    await manager.wait_for_exit(tid)

    await manager.release(tid)

    with pytest.raises(TerminalNotFound):
        manager.output(tid)


async def test_release_kills_a_still_running_process(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "import time; time.sleep(30)"])

    await manager.release(tid)

    with pytest.raises(TerminalNotFound):
        manager.output(tid)


async def test_release_of_unknown_terminal_is_a_noop(manager):
    await manager.release("term-does-not-exist")


async def test_release_session_only_touches_that_session(manager):
    keep = await manager.create("s1", sys.executable, ["-c", "import time; time.sleep(30)"])
    drop = await manager.create("s2", sys.executable, ["-c", "import time; time.sleep(30)"])

    await manager.release_session("s2")

    manager.output(keep)  # still known
    with pytest.raises(TerminalNotFound):
        manager.output(drop)


async def test_large_output_does_not_deadlock(manager):
    """A child that fills the pipe buffer must not block waiting to be read."""
    tid = await manager.create(
        "s1",
        sys.executable,
        ["-c", "import sys; sys.stdout.write('x' * 5_000_000)"],
    )

    result = await asyncio.wait_for(manager.wait_for_exit(tid), timeout=20)

    assert result["exitCode"] == 0
    assert len(manager.output(tid)["output"]) > 1_000_000


async def test_wait_for_exit_is_safe_to_call_twice(manager):
    tid = await manager.create("s1", sys.executable, ["-c", "pass"])

    first = await manager.wait_for_exit(tid)
    second = await manager.wait_for_exit(tid)

    assert first == second == {"exitCode": 0, "signal": None}


async def test_unknown_terminal_raises(manager):
    with pytest.raises(TerminalNotFound):
        manager.output("nope")
    with pytest.raises(TerminalNotFound):
        await manager.wait_for_exit("nope")
    with pytest.raises(TerminalNotFound):
        await manager.kill("nope")
