"""Building and reading the question forms Neovim renders.

Two paths end up in the same float -- Cursor's ``cursor/ask_question``
extension and avante's own ``ask_user_question`` MCP tool -- so the schema they
produce has to be identical. ``lua/avante/acp/elicitation.lua`` is the
consumer, and it makes three demands:

* fields are named ``question_<n>``; it orders them by that numeric suffix,
  because ``pairs()`` over the properties table would randomise them
* options live in ``oneOf`` for a single select and ``items.anyOf`` for a
  multi select
* a paired ``question_<n>_custom`` property is what makes it offer a free-text
  "type my own answer" choice

Keeping that knowledge in one place is the point of this module: a divergence
between the two producers shows up as a question that renders with no options.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

CUSTOM_SUFFIX = "_custom"

DEFAULT_MESSAGE = "The agent has a question."


@dataclass(frozen=True)
class Option:
    value: str
    label: str
    description: str | None = None


@dataclass(frozen=True)
class Question:
    prompt: str
    title: str | None = None
    options: tuple[Option, ...] = ()
    multi: bool = False
    #: Whether to offer a free-text answer alongside the options.
    allow_custom: bool = False


@dataclass(frozen=True)
class Answer:
    values: tuple[str, ...] = ()
    custom: str | None = None

    @property
    def answered(self) -> bool:
        return bool(self.values) or bool(self.custom)


def field_name(index: int) -> str:
    return f"question_{index}"


def build_form(
    questions: list[Question],
    *,
    title: str | None = None,
    fallback_message: str = DEFAULT_MESSAGE,
) -> dict[str, Any]:
    """Elicitation params for `questions`, ready to send as ``ui/elicitation``."""
    properties: dict[str, Any] = {}

    for index, question in enumerate(questions):
        options = [
            {
                key: value
                for key, value in (
                    ("const", option.value),
                    ("title", option.label),
                    ("description", option.description),
                )
                if value is not None
            }
            for option in question.options
        ]

        schema: dict[str, Any] = {"title": question.title, "description": question.prompt}
        if question.multi:
            schema["type"] = "array"
            schema["items"] = {"anyOf": options}
        else:
            schema["type"] = "string"
            schema["oneOf"] = options

        properties[field_name(index)] = {k: v for k, v in schema.items() if v is not None}
        if question.allow_custom:
            properties[field_name(index) + CUSTOM_SUFFIX] = {"type": "string", "title": "Other"}

    # A single question reads better as the float's message than as a header
    # above a repeat of itself.
    message = (questions[0].prompt if len(questions) == 1 else None) or title or fallback_message

    return {
        "message": message,
        "mode": {"requestedSchema": {"type": "object", "properties": properties}},
    }


def read_answers(content: dict[str, Any] | None, count: int) -> list[Answer]:
    """Unpack an accepted elicitation's content, one `Answer` per question."""
    content = content or {}
    answers = []

    for index in range(count):
        name = field_name(index)
        raw = content.get(name)
        if isinstance(raw, list):
            values = tuple(str(value) for value in raw)
        elif raw is None:
            values = ()
        else:
            values = (str(raw),)

        custom = content.get(name + CUSTOM_SUFFIX)
        answers.append(
            Answer(values=values, custom=str(custom) if custom is not None else None)
        )

    return answers
