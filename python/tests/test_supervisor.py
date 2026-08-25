"""Capability interpretation.

ACP advertises a sub-capability by sending an object, which is usually empty.
Treating that as a boolean refuses every capability an agent actually offers,
so these pin the semantics.
"""

from __future__ import annotations

from avante_acp.supervisor import AgentHandle
from avante_acp.terminal import TerminalManager


def handle_with(capabilities):
    handle = AgentHandle("agent-1", "fake", TerminalManager())
    handle.capabilities = capabilities
    return handle


def test_empty_object_means_supported():
    # This is the shape real agents send: sessionCapabilities.list = {}
    handle = handle_with({"sessionCapabilities": {"list": {}}})

    assert handle.supports("sessionCapabilities", "list") is True


def test_missing_key_means_unsupported():
    handle = handle_with({"sessionCapabilities": {}})

    assert handle.supports("sessionCapabilities", "list") is False


def test_null_means_unsupported():
    handle = handle_with({"sessionCapabilities": {"list": None}})

    assert handle.supports("sessionCapabilities", "list") is False


def test_boolean_flags_still_honour_false():
    assert handle_with({"loadSession": True}).supports("loadSession") is True
    assert handle_with({"loadSession": False}).supports("loadSession") is False


def test_populated_object_means_supported():
    handle = handle_with({"promptCapabilities": {"image": True}})

    assert handle.supports("promptCapabilities", "image") is True


def test_missing_parent_is_unsupported():
    handle = handle_with({})

    assert handle.supports("sessionCapabilities", "resume") is False


def test_non_dict_parent_is_unsupported():
    handle = handle_with({"sessionCapabilities": "nonsense"})

    assert handle.supports("sessionCapabilities", "resume") is False
