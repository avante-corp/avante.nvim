"""The ask_user_question MCP server.

This exists because agents that cannot ask a question natively give up and ask
in prose instead, so the failure mode these guard against is silent: nothing
errors, the user just never sees a picker.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any
from urllib.parse import urlparse

import pytest

from avante_acp import forms
from avante_acp.ask_server import TOOL_NAME, AskServer


async def post(url: str, message: Any, *, token: str | None, method: str = "POST") -> tuple[int, Any]:
    """One HTTP request against the server, returning (status, parsed body)."""
    parsed = urlparse(url)
    reader, writer = await asyncio.open_connection(parsed.hostname, parsed.port)

    body = json.dumps(message).encode() if message is not None else b""
    head = [
        f"{method} {parsed.path} HTTP/1.1",
        f"Host: {parsed.hostname}:{parsed.port}",
        f"Content-Length: {len(body)}",
        "Content-Type: application/json",
        "Connection: close",
    ]
    if token is not None:
        head.append(f"Authorization: Bearer {token}")

    writer.write("\r\n".join(head).encode() + b"\r\n\r\n" + body)
    await writer.drain()

    raw = await reader.read()
    writer.close()

    head_bytes, _, body_bytes = raw.partition(b"\r\n\r\n")
    status = int(head_bytes.split(b"\r\n")[0].split(b" ")[1])
    return status, (json.loads(body_bytes) if body_bytes else None)


@pytest.fixture
async def server(peer_pair: Any) -> Any:
    """A started server whose peer is the bridge half of `peer_pair`."""
    instance = AskServer("agent-1", peer_pair.left)
    await instance.start()
    try:
        yield instance
    finally:
        await instance.stop()


def answer_with(peer_pair: Any, responder: Any) -> list[dict[str, Any]]:
    """Register the Neovim half's ui/elicitation handler, recording its params."""
    seen: list[dict[str, Any]] = []

    async def handle(params: dict[str, Any]) -> Any:
        seen.append(params)
        return responder(params)

    peer_pair.right.on_request("ui/elicitation", handle)
    return seen


TWO_QUESTIONS = {
    "name": TOOL_NAME,
    "arguments": {
        "questions": [
            {
                "question": "Which backend?",
                "header": "Backend",
                "options": [
                    {"label": "Python", "description": "Full ACP surface"},
                    {"label": "Lua", "description": "Built-in client"},
                ],
            },
            {
                "question": "Which extras?",
                "header": "Extras",
                "multiSelect": True,
                "options": [{"label": "Terminals"}, {"label": "Transcripts"}],
            },
        ]
    },
}


def call(arguments: Any = None, *, request_id: int = 1) -> dict[str, Any]:
    params = arguments if arguments is not None else TWO_QUESTIONS
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/call", "params": params}


# -- transport -----------------------------------------------------------


async def test_rejects_a_request_with_no_token(server: AskServer) -> None:
    status, _ = await post(server.url, {"jsonrpc": "2.0", "id": 1, "method": "ping"}, token=None)
    assert status == 401


async def test_rejects_a_request_with_the_wrong_token(server: AskServer) -> None:
    status, _ = await post(
        server.url, {"jsonrpc": "2.0", "id": 1, "method": "ping"}, token="not-the-token"
    )
    assert status == 401


async def test_refuses_the_sse_stream_rather_than_leaving_it_open(server: AskServer) -> None:
    # A client opening the server-to-client stream must be told no; accepting
    # and never sending anything would leave it waiting forever.
    status, _ = await post(server.url, None, token=server.token, method="GET")
    assert status == 405


async def test_answers_a_notification_with_no_body(server: AskServer) -> None:
    status, body = await post(
        server.url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, token=server.token
    )
    assert status == 202
    assert body is None


async def test_unknown_methods_get_method_not_found(server: AskServer) -> None:
    _, body = await post(
        server.url, {"jsonrpc": "2.0", "id": 1, "method": "resources/list"}, token=server.token
    )
    assert body["error"]["code"] == -32601


async def test_malformed_json_does_not_kill_the_connection(server: AskServer) -> None:
    parsed = urlparse(server.url)
    reader, writer = await asyncio.open_connection(parsed.hostname, parsed.port)
    body = b"{not json"
    writer.write(
        (
            f"POST /mcp HTTP/1.1\r\nAuthorization: Bearer {server.token}\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
        ).encode()
        + body
    )
    await writer.drain()
    raw = await reader.read()
    writer.close()

    _, _, payload = raw.partition(b"\r\n\r\n")
    assert json.loads(payload)["error"]["code"] == -32700


# -- discovery -----------------------------------------------------------


async def test_initialize_echoes_the_requested_protocol_version(server: AskServer) -> None:
    _, body = await post(
        server.url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-03-26"},
        },
        token=server.token,
    )
    assert body["result"]["protocolVersion"] == "2025-03-26"
    assert body["result"]["capabilities"] == {"tools": {}}


async def test_tools_list_offers_exactly_the_ask_tool(server: AskServer) -> None:
    _, body = await post(
        server.url, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token=server.token
    )
    tools = body["result"]["tools"]
    assert [tool["name"] for tool in tools] == [TOOL_NAME]
    assert tools[0]["inputSchema"]["required"] == ["questions"]


async def test_the_entry_carries_the_token_as_a_header(server: AskServer) -> None:
    entry = server.mcp_server_entry()
    assert entry["type"] == "http"
    assert entry["url"] == server.url
    assert entry["headers"] == [{"name": "Authorization", "value": f"Bearer {server.token}"}]


# -- asking --------------------------------------------------------------


async def test_a_question_reaches_neovim_in_the_shape_the_float_reads(
    server: AskServer, peer_pair: Any
) -> None:
    seen = answer_with(peer_pair, lambda _: {"action": "decline"})

    await post(server.url, call(), token=server.token)

    params = seen[0]
    assert params["agentId"] == "agent-1"
    properties = params["mode"]["requestedSchema"]["properties"]
    # Single select via oneOf, multi select via items.anyOf, and a paired
    # _custom field so the float offers a free-text answer.
    assert [option["const"] for option in properties["question_0"]["oneOf"]] == ["Python", "Lua"]
    assert properties["question_1"]["items"]["anyOf"][0]["const"] == "Terminals"
    assert properties["question_0" + forms.CUSTOM_SUFFIX]["type"] == "string"


async def test_an_accepted_answer_comes_back_as_text(server: AskServer, peer_pair: Any) -> None:
    answer_with(
        peer_pair,
        lambda _: {
            "action": "accept",
            "content": {"question_0": "Python", "question_1": ["Terminals", "Transcripts"]},
        },
    )

    _, body = await post(server.url, call(), token=server.token)

    text = body["result"]["content"][0]["text"]
    assert "Which backend?" in text and "Python" in text
    assert "Terminals, Transcripts" in text
    assert "isError" not in body["result"]


async def test_a_free_text_answer_wins_over_the_options(server: AskServer, peer_pair: Any) -> None:
    answer_with(
        peer_pair,
        lambda _: {
            "action": "accept",
            "content": {"question_0" + forms.CUSTOM_SUFFIX: "Neither, use the Zed one"},
        },
    )

    _, body = await post(server.url, call(), token=server.token)

    assert "Neither, use the Zed one" in body["result"]["content"][0]["text"]


async def test_a_skip_is_not_an_error(server: AskServer, peer_pair: Any) -> None:
    answer_with(peer_pair, lambda _: {"action": "decline"})

    _, body = await post(server.url, call(), token=server.token)

    assert "isError" not in body["result"]
    assert "skipped" in body["result"]["content"][0]["text"]


async def test_accepting_with_nothing_filled_in_reads_as_a_skip(
    server: AskServer, peer_pair: Any
) -> None:
    answer_with(peer_pair, lambda _: {"action": "accept", "content": {}})

    _, body = await post(server.url, call(), token=server.token)

    assert "isError" not in body["result"]
    assert "skipped" in body["result"]["content"][0]["text"]


async def test_a_dismissal_is_an_error_so_the_agent_does_not_invent_an_answer(
    server: AskServer, peer_pair: Any
) -> None:
    answer_with(peer_pair, lambda _: {"action": "cancel"})

    _, body = await post(server.url, call(), token=server.token)

    assert body["result"]["isError"] is True
    assert "dismissed" in body["result"]["content"][0]["text"]


async def test_a_question_with_too_few_options_is_a_tool_error(server: AskServer) -> None:
    # Rejected as a tool error rather than a protocol error, so the agent can
    # read the reason and retry.
    _, body = await post(
        server.url,
        call(
            {
                "name": TOOL_NAME,
                "arguments": {"questions": [{"question": "Yes?", "options": [{"label": "Yes"}]}]},
            }
        ),
        token=server.token,
    )
    assert body["result"]["isError"] is True


async def test_calling_an_unknown_tool_is_method_not_found(server: AskServer) -> None:
    _, body = await post(
        server.url, call({"name": "something_else", "arguments": {}}), token=server.token
    )
    assert body["error"]["code"] == -32601


async def test_a_dead_neovim_does_not_leave_the_agent_waiting(
    server: AskServer, peer_pair: Any
) -> None:
    # No ui/elicitation handler registered, so the peer answers -32601.
    _, body = await post(server.url, call(), token=server.token)

    assert body["result"]["isError"] is True
    assert "could not be shown" in body["result"]["content"][0]["text"]
