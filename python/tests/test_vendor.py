"""Vendor extension methods.

ACP reserves `_`-prefixed names for extensions and the SDK router enforces that
literally, so Cursor's `cursor/*` methods are rejected with -32601 before
Client.ext_method runs. Cursor then silently falls back to asking in plain
markdown. These pin both the routing fix and the payload translation.

Schemas: https://cursor.com/docs/cli/acp#cursor-extension-methods
"""

from __future__ import annotations

from avante_acp import vendor


# -- routing -------------------------------------------------------------


class FakeRouter:
    def __init__(self):
        self.routes = {}

    def add_route(self, route):
        self.routes[route.method] = route


class FakeConn:
    def __init__(self, router):
        self._conn = type("Inner", (), {"_handler": router})()


class RecordingClient:
    def __init__(self):
        self.requests = []
        self.notifications = []

    async def ext_method(self, method, params):
        self.requests.append((method, params))
        return {"ok": True}

    async def ext_notification(self, method, params):
        self.notifications.append((method, params))


def test_registers_cursors_non_underscore_methods():
    router = FakeRouter()

    registered = vendor.register_vendor_routes(FakeConn(router), RecordingClient())

    # Without these the SDK raises method_not_found: they do not start with "_".
    assert "cursor/ask_question" in registered
    assert "cursor/create_plan" in registered
    assert "cursor/update_todos" in registered
    assert set(registered) == set(router.routes)


def test_blocking_methods_are_requests_and_the_rest_notifications():
    router = FakeRouter()
    vendor.register_vendor_routes(FakeConn(router), RecordingClient())

    assert router.routes["cursor/ask_question"].kind == "request"
    assert router.routes["cursor/create_plan"].kind == "request"
    assert router.routes["cursor/update_todos"].kind == "notification"
    assert router.routes["cursor/task"].kind == "notification"


async def test_routed_request_reaches_ext_method():
    router = FakeRouter()
    client = RecordingClient()
    vendor.register_vendor_routes(FakeConn(router), client)

    result = await router.routes["cursor/ask_question"].func({"toolCallId": "c1"})

    assert result == {"ok": True}
    assert client.requests == [("cursor/ask_question", {"toolCallId": "c1"})]


async def test_routed_notification_reaches_ext_notification():
    router = FakeRouter()
    client = RecordingClient()
    vendor.register_vendor_routes(FakeConn(router), client)

    assert await router.routes["cursor/task"].func({"description": "explore"}) is None
    assert client.notifications == [("cursor/task", {"description": "explore"})]


def test_unreachable_router_is_not_fatal():
    # A future SDK could move the attribute; losing extensions beats crashing.
    assert vendor.register_vendor_routes(object(), RecordingClient()) == []


# -- cursor/ask_question -------------------------------------------------


def ask_request():
    """The documented example request."""
    return {
        "toolCallId": "call_123",
        "title": "Need input",
        "questions": [
            {
                "id": "q1",
                "prompt": "Which mode should I use?",
                "options": [
                    {"id": "agent", "label": "Agent"},
                    {"id": "plan", "label": "Plan"},
                ],
                "allowMultiple": False,
            }
        ],
    }


def test_ask_question_becomes_an_elicitation_form():
    result = vendor.ask_question_to_elicitation(ask_request())

    assert result["message"] == "Which mode should I use?"
    field = result["mode"]["requestedSchema"]["properties"]["question_0"]
    assert field["type"] == "string"
    assert [o["const"] for o in field["oneOf"]] == ["agent", "plan"]
    assert [o["title"] for o in field["oneOf"]] == ["Agent", "Plan"]


def test_multi_select_becomes_an_array_field():
    request = ask_request()
    request["questions"][0]["allowMultiple"] = True

    field = vendor.ask_question_to_elicitation(request)["mode"]["requestedSchema"]["properties"]["question_0"]

    assert field["type"] == "array"
    assert [o["const"] for o in field["items"]["anyOf"]] == ["agent", "plan"]


def test_question_ids_are_preserved_for_the_response():
    # Cursor keys answers by its own question id, not our field name.
    assert vendor.ask_question_to_elicitation(ask_request())["_questionIds"] == ["q1"]


def test_multiple_questions_keep_order_and_use_the_title_as_message():
    request = {
        "title": "Two things",
        "questions": [
            {"id": "a", "prompt": "First?", "options": [{"id": "1", "label": "One"}]},
            {"id": "b", "prompt": "Second?", "options": [{"id": "2", "label": "Two"}]},
        ],
    }

    result = vendor.ask_question_to_elicitation(request)

    assert result["message"] == "Two things"
    assert result["_questionIds"] == ["a", "b"]
    assert set(result["mode"]["requestedSchema"]["properties"]) == {"question_0", "question_1"}


def test_answer_becomes_cursors_response_shape():
    response = vendor.elicitation_to_ask_question(
        {"action": "accept", "content": {"question_0": "plan"}}, ["q1"]
    )

    assert response == {
        "outcome": {"outcome": "answered", "answers": [{"questionId": "q1", "selectedOptionIds": ["plan"]}]}
    }


def test_multi_select_answer_keeps_every_option():
    response = vendor.elicitation_to_ask_question(
        {"action": "accept", "content": {"question_0": ["agent", "plan"]}}, ["q1"]
    )

    assert response["outcome"]["answers"][0]["selectedOptionIds"] == ["agent", "plan"]


def test_decline_is_skipped_and_cancel_is_cancelled():
    assert vendor.elicitation_to_ask_question({"action": "decline"}, ["q1"])["outcome"]["outcome"] == "skipped"
    assert vendor.elicitation_to_ask_question({"action": "cancel"}, ["q1"])["outcome"]["outcome"] == "cancelled"


def test_accept_with_no_answers_is_skipped():
    # e.g. the user chose the free-text "other" box, which has no option id.
    result = vendor.elicitation_to_ask_question({"action": "accept", "content": {}}, ["q1"])

    assert result["outcome"]["outcome"] == "skipped"


# -- cursor/create_plan --------------------------------------------------


def test_create_plan_flattens_phase_todos():
    summary = vendor.create_plan_summary(
        {
            "name": "Refactor",
            "overview": "Tighten layout",
            "plan": "1. Inspect\n2. Update",
            "todos": [{"id": "t1", "content": "Inspect", "status": "completed"}],
            "phases": [{"name": "Phase 2", "todos": [{"id": "t2", "content": "Update", "status": "pending"}]}],
        }
    )

    assert summary["name"] == "Refactor"
    assert [t["content"] for t in summary["todos"]] == ["Inspect", "Update"]


def test_plan_response_maps_the_three_outcomes():
    assert vendor.plan_response(True)["outcome"]["outcome"] == "accepted"
    assert vendor.plan_response(False)["outcome"]["outcome"] == "rejected"
    assert vendor.plan_response(None)["outcome"]["outcome"] == "cancelled"


# -- cursor/update_todos -------------------------------------------------


def test_todos_become_acp_plan_entries():
    entries = vendor.todos_to_plan_entries(
        {
            "todos": [
                {"id": "1", "content": "Set up", "status": "completed"},
                {"id": "2", "content": "Auth", "status": "in_progress"},
                {"id": "3", "content": "Tests", "status": "pending"},
            ]
        }
    )

    assert [e["content"] for e in entries] == ["Set up", "Auth", "Tests"]
    assert [e["status"] for e in entries] == ["completed", "in_progress", "pending"]


def test_cancelled_todo_maps_to_a_status_acp_understands():
    # ACP's PlanEntryStatus has no "cancelled"; leaving it through would render
    # as an outstanding item forever.
    entries = vendor.todos_to_plan_entries({"todos": [{"content": "Dropped", "status": "cancelled"}]})

    assert entries[0]["status"] == "completed"


def test_unknown_status_falls_back_to_pending():
    entries = vendor.todos_to_plan_entries({"todos": [{"content": "x", "status": "weird"}]})

    assert entries[0]["status"] == "pending"


def test_empty_todos_is_empty():
    assert vendor.todos_to_plan_entries({}) == []
