"""Unit tests for clauder-mcp's pure functions.

These cover the layers where escaping and validation bugs live — no R
session or MCP client required. Run with: python -m pytest tests -q
"""

import pytest

from clauder_mcp.server import (
    escape_r_string,
    _extract_json,
    _parse_annotation_schema,
    _validate_annotation,
)


# --- escape_r_string ---------------------------------------------------

class TestEscapeRString:
    def test_plain_text_unchanged(self):
        assert escape_r_string("hello world") == "hello world"

    def test_double_quotes(self):
        assert escape_r_string('say "hi"') == 'say \\"hi\\"'

    def test_single_quotes(self):
        assert escape_r_string("it's") == "it\\'s"

    def test_backslashes_first(self):
        # A windows path: each backslash becomes exactly two
        assert escape_r_string(r"C:\temp\new") == r"C:\\temp\\new"

    def test_backslash_then_quote_ordering(self):
        # \" in input -> \\ + \" in output, not \\\" mangled
        assert escape_r_string('\\"') == '\\\\\\"'

    def test_newlines_tabs_cr(self):
        assert escape_r_string("a\nb\tc\rd") == "a\\nb\\tc\\rd"

    def test_backticks(self):
        # \` is a valid escape inside double-quoted R strings
        assert escape_r_string("`x`") == "\\`x\\`"

    def test_null_bytes_stripped(self):
        assert escape_r_string("a\0b") == "ab"


class TestGsubReplacementEscaping:
    """modify_code_section escapes replacements once for gsub() semantics
    (backslash is a metacharacter: backrefs \\1..\\9), then once more for
    the R string literal. Original backslash -> 4 in the emitted source."""

    def test_backslash_quadruples(self):
        emitted = escape_r_string(r"C:\temp".replace("\\", "\\\\"))
        assert emitted == r"C:\\\\temp"

    def test_backref_stays_literal(self):
        emitted = escape_r_string(r"keep \1 literal".replace("\\", "\\\\"))
        # gsub sees \\1 (literal backslash-one), not a backreference
        assert emitted == r"keep \\\\1 literal"


# --- _extract_json ------------------------------------------------------

class TestExtractJson:
    def test_bare_json(self):
        assert _extract_json('{"a": 1}') == {"a": 1}

    def test_markdown_fenced(self):
        text = '```json\n{"label": "positive"}\n```'
        assert _extract_json(text) == {"label": "positive"}

    def test_fence_without_language(self):
        text = '```\n{"x": true}\n```'
        assert _extract_json(text) == {"x": True}

    def test_json_embedded_in_prose(self):
        text = 'Here is my answer:\n{"score": 0.5}\nHope that helps!'
        assert _extract_json(text) == {"score": 0.5}

    def test_garbage_returns_none(self):
        assert _extract_json("no json here") is None

    def test_multiline_object(self):
        text = '{\n  "a": 1,\n  "b": [1, 2]\n}'
        assert _extract_json(text) == {"a": 1, "b": [1, 2]}


# --- annotation schema parsing ------------------------------------------

class TestParseAnnotationSchema:
    def test_full_schema(self):
        s = _parse_annotation_schema(
            "sentiment:choice[positive,negative,neutral];confidence:float[0,1];notes:text"
        )
        assert s["sentiment"] == {"type": "choice", "constraint": "positive,negative,neutral"}
        assert s["confidence"] == {"type": "float", "constraint": "0,1"}
        assert s["notes"] == {"type": "text", "constraint": None}

    def test_whitespace_tolerated(self):
        s = _parse_annotation_schema(" flag : bool ; n : int[0,10] ")
        assert set(s) == {"flag", "n"}
        assert s["flag"]["type"] == "bool"

    def test_missing_colon_raises(self):
        with pytest.raises(ValueError):
            _parse_annotation_schema("justaname")

    def test_trailing_semicolon_ok(self):
        s = _parse_annotation_schema("a:text;")
        assert list(s) == ["a"]


# --- annotation validation ----------------------------------------------

SCHEMA = _parse_annotation_schema(
    "label:choice[yes,no];score:float[0,1];count:int[1,5];flag:bool;note:text"
)
GOOD = {"label": "yes", "score": "0.5", "count": "3", "flag": "true", "note": ""}


class TestValidateAnnotation:
    def test_valid_row(self):
        ok, err = _validate_annotation(GOOD, SCHEMA)
        assert ok, err

    def test_missing_field(self):
        row = {k: v for k, v in GOOD.items() if k != "score"}
        ok, err = _validate_annotation(row, SCHEMA)
        assert not ok and "Missing" in err

    def test_extra_field(self):
        ok, err = _validate_annotation({**GOOD, "bogus": "x"}, SCHEMA)
        assert not ok and "Unexpected" in err

    def test_bad_choice(self):
        ok, err = _validate_annotation({**GOOD, "label": "maybe"}, SCHEMA)
        assert not ok and "label" in err

    def test_float_out_of_range(self):
        ok, err = _validate_annotation({**GOOD, "score": "1.5"}, SCHEMA)
        assert not ok and "out of range" in err

    def test_float_not_numeric(self):
        ok, err = _validate_annotation({**GOOD, "score": "high"}, SCHEMA)
        assert not ok

    def test_int_out_of_range(self):
        ok, err = _validate_annotation({**GOOD, "count": "0"}, SCHEMA)
        assert not ok and "out of range" in err

    def test_int_rejects_float(self):
        ok, err = _validate_annotation({**GOOD, "count": "2.5"}, SCHEMA)
        assert not ok

    def test_bool_variants(self):
        for v in ("true", "FALSE", "1", "0", "Yes", "no"):
            ok, err = _validate_annotation({**GOOD, "flag": v}, SCHEMA)
            assert ok, f"{v}: {err}"
        ok, _ = _validate_annotation({**GOOD, "flag": "affirmative"}, SCHEMA)
        assert not ok

    def test_text_accepts_anything(self):
        ok, _ = _validate_annotation({**GOOD, "note": "free text, with, commas"}, SCHEMA)
        assert ok


# --- _coord_target (stale-session guard) --------------------------------

from clauder_mcp import server as _srv


class TestCoordTarget:
    """A bridge bound to a dead session must not silently write to a log
    no live agent reads (field bug, 0.14.1)."""

    def test_dead_session_fails_loudly(self, monkeypatch):
        monkeypatch.setattr(_srv, "discover_sessions", lambda: [])
        monkeypatch.setattr(_srv, "_target_session", "runescape")
        monkeypatch.setattr(_srv, "_coord_bound", None)
        note, err = _srv._coord_target()
        assert note is None
        assert err is not None
        assert "FAILED" in err and "runescape" in err

    def test_rebind_to_live_session_produces_note(self, monkeypatch):
        live = [{"session_name": "live", "port": 8790, "token": "t", "pid": 1}]
        monkeypatch.setattr(_srv, "discover_sessions", lambda: live)
        monkeypatch.setattr(_srv, "_target_session", None)
        monkeypatch.setattr(_srv, "_coord_bound", "runescape")
        note, err = _srv._coord_target()
        assert err is None
        assert note is not None
        assert "runescape" in note and "live" in note
        assert _srv._coord_bound == "live"

    def test_stable_binding_is_quiet(self, monkeypatch):
        live = [{"session_name": "live", "port": 8790, "token": "t", "pid": 1}]
        monkeypatch.setattr(_srv, "discover_sessions", lambda: live)
        monkeypatch.setattr(_srv, "_target_session", "live")
        monkeypatch.setattr(_srv, "_coord_bound", "live")
        note, err = _srv._coord_target()
        assert note is None
        assert err is None


# --- set_agent_name tug-of-war guard -------------------------------------

import asyncio


class TestSetAgentNameGuard:
    """A second, different rename on an already-named connection is the
    signature of personas sharing one connection. Refuse it (field bug)."""

    def test_second_rename_refused_without_force(self, monkeypatch):
        monkeypatch.setattr(_srv, "_agent_introduced", True)
        monkeypatch.setattr(_srv, "_agent_id", "Claude-Stasis")
        monkeypatch.setattr(_srv, "_agent_id_source", "set_agent_name")
        out = asyncio.run(_srv.call_tool(
            "set_agent_name", {"name": "Claude-Wanderlark"}))
        text = out[0].text
        assert "REFUSED" in text and "as_agent" in text
        assert _srv._agent_id == "Claude-Stasis"

    def test_force_rename_allowed(self, monkeypatch):
        monkeypatch.setattr(_srv, "_agent_introduced", True)
        monkeypatch.setattr(_srv, "_agent_id", "Claude-Stasis")
        monkeypatch.setattr(_srv, "_agent_id_source", "set_agent_name")
        asyncio.run(_srv.call_tool(
            "set_agent_name", {"name": "Claude-Wanderlark", "force": True}))
        assert _srv._agent_id == "Claude-Wanderlark"

    def test_same_name_reaffirm_ok(self, monkeypatch):
        monkeypatch.setattr(_srv, "_agent_introduced", True)
        monkeypatch.setattr(_srv, "_agent_id", "Claude-Stasis")
        monkeypatch.setattr(_srv, "_agent_id_source", "set_agent_name")
        out = asyncio.run(_srv.call_tool(
            "set_agent_name", {"name": "Claude-Stasis"}))
        assert "REFUSED" not in out[0].text
        assert _srv._agent_id == "Claude-Stasis"

    def test_first_rename_from_random_id_allowed(self, monkeypatch):
        monkeypatch.setattr(_srv, "_agent_introduced", True)
        monkeypatch.setattr(_srv, "_agent_id", "agent-071254d2")
        monkeypatch.setattr(_srv, "_agent_id_source",
                            "randomly assigned for this connection")
        asyncio.run(_srv.call_tool(
            "set_agent_name", {"name": "Claude-Gatherers"}))
        assert _srv._agent_id == "Claude-Gatherers"
