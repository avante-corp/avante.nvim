"""Vendor extension methods that are not `_`-prefixed.

ACP reserves `_`-prefixed method names for extensions, and the SDK's router
honours that literally::

    if method.startswith("_"):
        return await ext_handler(method[1:], payload)
    route = routes.get(method)
    if route is None:
        raise RequestError.method_not_found(method)

Cursor's extensions are named `cursor/ask_question`, `cursor/create_plan` and
so on -- no leading underscore -- so they never reach `Client.ext_method` and
are rejected with -32601 before we ever see them. The visible symptom is that
Cursor silently gives up on its interactive question UI and asks in plain
markdown instead.

Registering explicit routes for them restores the behaviour. Schemas are from
https://cursor.com/docs/cli/acp#cursor-extension-methods.
"""

from __future__ import annotations

import logging
from typing import Any

from acp.router import Route

from . import forms

log = logging.getLogger(__name__)

# Blocking: the agent waits for a response.
CURSOR_REQUESTS = ("cursor/ask_question", "cursor/create_plan")
# Fire-and-forget.
CURSOR_NOTIFICATIONS = ("cursor/update_todos", "cursor/task", "cursor/generate_image")


def _router_of(conn: Any) -> Any:
    """The MessageRouter behind a ClientSideConnection, if reachable."""
    inner = getattr(conn, "_conn", None)
    return getattr(inner, "_handler", None)


def register_vendor_routes(conn: Any, client: Any) -> list[str]:
    """Route non-underscore vendor methods to the client's ext handlers.

    Returns the method names that were registered, for logging.
    """
    router = _router_of(conn)
    if router is None or not hasattr(router, "add_route"):
        log.warning("Could not reach the SDK router; vendor extensions stay unavailable")
        return []

    registered: list[str] = []

    def add(method: str, kind: str) -> None:
        async def handle(params: Any, _method: str = method) -> Any:
            payload = params if isinstance(params, dict) else {}
            if kind == "request":
                return await client.ext_method(_method, payload)
            await client.ext_notification(_method, payload)
            return None

        try:
            router.add_route(Route(method=method, func=handle, kind=kind))
            registered.append(method)
        except Exception:
            log.exception("Failed to register vendor route %s", method)

    for method in CURSOR_REQUESTS:
        add(method, "request")
    for method in CURSOR_NOTIFICATIONS:
        add(method, "notification")

    return registered


# -- cursor/ask_question ------------------------------------------------
# Translated into the same shape as an ACP form elicitation so Neovim has one
# question UI rather than one per vendor.


def ask_question_to_elicitation(params: dict[str, Any]) -> dict[str, Any]:
    """Convert a cursor/ask_question request into elicitation-style params."""
    raw_questions = params.get("questions") or []
    title = params.get("title")

    questions = []
    # Cursor keys answers by its own question id; remember the mapping so the
    # response can be built back up.
    order: list[str] = []

    for index, question in enumerate(raw_questions):
        if not isinstance(question, dict):
            continue
        order.append(str(question.get("id") or forms.field_name(index)))
        options = tuple(
            forms.Option(value=str(option.get("id")), label=option.get("label") or str(option.get("id")))
            for option in (question.get("options") or [])
            if isinstance(option, dict)
        )
        questions.append(
            forms.Question(
                prompt=question.get("prompt") or "",
                title=title,
                options=options,
                multi=bool(question.get("allowMultiple")),
                # Cursor's response schema carries option ids and has no slot
                # for free text, so there is nowhere to put a custom answer.
                allow_custom=False,
            )
        )

    request = forms.build_form(questions, title=title)
    request["_questionIds"] = order
    return request


def elicitation_to_ask_question(answer: dict[str, Any], question_ids: list[str]) -> dict[str, Any]:
    """Convert an elicitation answer back into a cursor/ask_question response."""
    action = (answer or {}).get("action")
    if action == "decline":
        return {"outcome": {"outcome": "skipped"}}
    if action != "accept":
        return {"outcome": {"outcome": "cancelled"}}

    parsed = forms.read_answers((answer or {}).get("content"), len(question_ids))
    answers = [
        {"questionId": question_id, "selectedOptionIds": list(given.values)}
        for question_id, given in zip(question_ids, parsed)
        # A free-text answer has no option id to report, so it counts as
        # unanswered here even though the user did type something.
        if given.values
    ]

    if not answers:
        return {"outcome": {"outcome": "skipped"}}
    return {"outcome": {"outcome": "answered", "answers": answers}}


# -- cursor/create_plan -------------------------------------------------


def create_plan_summary(params: dict[str, Any]) -> dict[str, Any]:
    """Flatten a cursor/create_plan request for display."""
    todos = list(params.get("todos") or [])
    for phase in params.get("phases") or []:
        if isinstance(phase, dict):
            todos.extend(phase.get("todos") or [])
    return {
        "name": params.get("name"),
        "overview": params.get("overview"),
        "plan": params.get("plan"),
        "todos": todos,
    }


def plan_response(accepted: bool | None) -> dict[str, Any]:
    if accepted is True:
        return {"outcome": {"outcome": "accepted"}}
    if accepted is False:
        return {"outcome": {"outcome": "rejected"}}
    return {"outcome": {"outcome": "cancelled"}}


# -- notifications ------------------------------------------------------


def todos_to_plan_entries(params: dict[str, Any]) -> list[dict[str, Any]]:
    """Convert cursor/update_todos into ACP plan entries.

    Cursor has a `cancelled` status that ACP's PlanEntryStatus lacks; map it to
    `completed` so the entry stops showing as outstanding.
    """
    entries = []
    for todo in params.get("todos") or []:
        if not isinstance(todo, dict):
            continue
        status = todo.get("status") or "pending"
        if status == "cancelled":
            status = "completed"
        if status not in ("pending", "in_progress", "completed"):
            status = "pending"
        entries.append({"content": todo.get("content") or "", "status": status, "priority": "medium"})
    return entries
