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


# --- get_async_result waits for the job ------------------------------------

import time


def _fake_r(monkeypatch, replies):
    """Bind to a pretend live R session whose check_job answers come from
    `replies` in order (the last one repeats). Returns the list of calls."""
    calls = []

    async def fake_post(payload, timeout=10.0):
        calls.append(payload)
        return replies[min(len(calls), len(replies)) - 1]

    async def fake_status(return_info=False):
        return True

    monkeypatch.setattr(_srv, "_session_language", lambda: "r")
    monkeypatch.setattr(_srv, "get_r_addin_url", lambda: "http://127.0.0.1:1")
    monkeypatch.setattr(_srv, "check_addin_status", fake_status)
    monkeypatch.setattr(_srv, "_agent_introduced", True)
    monkeypatch.setattr(_srv, "_rebind_note", None)
    monkeypatch.setattr(_srv, "post_to_r_addin", fake_post)
    return calls


RUNNING = {"status": "running", "elapsed_seconds": 5}
DONE = {"status": "complete", "success": True, "output": "fit done"}


class TestAsyncWait:
    """One call should wait for the job instead of making the agent poll
    every 10 s (a 20-minute fit used to cost ~120 calls)."""

    def test_returns_as_soon_as_job_finishes(self, monkeypatch):
        calls = _fake_r(monkeypatch, [RUNNING, RUNNING, DONE])
        t0 = time.monotonic()
        out = asyncio.run(_srv.call_tool("get_async_result",
                                         {"job_id": "j1", "wait_s": 60}))
        assert out[0].text == "fit done"
        assert len(calls) == 3
        assert time.monotonic() - t0 < 10   # 2 s + 3 s of back-off, not 60

    def test_already_finished_job_has_no_delay(self, monkeypatch):
        calls = _fake_r(monkeypatch, [DONE])
        t0 = time.monotonic()
        out = asyncio.run(_srv.call_tool("get_async_result", {"job_id": "j1"}))
        assert out[0].text == "fit done"
        assert len(calls) == 1
        assert time.monotonic() - t0 < 1    # the old code always slept 10 s

    def test_wait_zero_checks_once(self, monkeypatch):
        calls = _fake_r(monkeypatch, [RUNNING])
        out = asyncio.run(_srv.call_tool("get_async_result",
                                         {"job_id": "j1", "wait_s": 0}))
        assert len(calls) == 1
        assert "still running" in out[0].text

    def test_gives_up_at_wait_s_and_says_to_call_again(self, monkeypatch):
        calls = _fake_r(monkeypatch, [RUNNING])
        t0 = time.monotonic()
        out = asyncio.run(_srv.call_tool("get_async_result",
                                         {"job_id": "j1", "wait_s": 3}))
        took = time.monotonic() - t0
        assert 2.5 < took < 5
        assert "still running" in out[0].text and "again" in out[0].text
        assert len(calls) >= 2

    def test_unknown_job_stops_waiting(self, monkeypatch):
        calls = _fake_r(monkeypatch, [{"status": "not_found"}])
        out = asyncio.run(_srv.call_tool("get_async_result",
                                         {"job_id": "nope", "wait_s": 60}))
        assert len(calls) == 1
        assert "No job found" in out[0].text

    def test_lost_connection_stops_waiting(self, monkeypatch):
        calls = _fake_r(monkeypatch, [{"success": False,
                                       "error": "Error communicating with RStudio: refused"}])
        out = asyncio.run(_srv.call_tool("get_async_result",
                                         {"job_id": "j1", "wait_s": 60}))
        assert len(calls) == 1
        assert "refused" in out[0].text

    def test_bad_wait_value_falls_back(self, monkeypatch):
        calls = _fake_r(monkeypatch, [DONE])
        out = asyncio.run(_srv.call_tool("get_async_result",
                                         {"job_id": "j1", "wait_s": "soon"}))
        assert out[0].text == "fit done"
