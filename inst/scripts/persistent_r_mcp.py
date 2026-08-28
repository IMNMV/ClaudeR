#!/usr/bin/env python3
# persistent_r_mcp.py

import argparse
import asyncio
import json
import tempfile
import os
import base64
import uuid
import re
import shutil
import subprocess
import threading
from typing import Any, Dict, List, Optional
import httpx
import sys
from datetime import datetime
from mcp.server import Server
from mcp.server.stdio import stdio_server
import mcp.types as types

# Configure the server instance
server = Server("r-studio")

# Configuration — overwritten in main() after arg parsing
R_ADDIN_URL = "http://127.0.0.1:8787"  # Fallback if no discovery files found

# Session discovery
# On Windows, prefer USERPROFILE explicitly. Python's expanduser already does
# this internally, but being explicit guards against odd HOME settings (e.g.
# OneDrive-redirected Documents) and matches the R-side discovery_dir().
if sys.platform == "win32":
    SESSIONS_DIR = os.path.join(
        os.environ.get("USERPROFILE") or os.path.expanduser("~"),
        ".claude_r_sessions",
    )
else:
    SESSIONS_DIR = os.path.expanduser("~/.claude_r_sessions")
_agent_id: Optional[str] = None       # Set in main()
_agent_id_source: str = "unset"       # Where the identity came from (for the intro)
_target_session: Optional[str] = None  # Set by connect_session tool
_target_token: Optional[str] = None    # Per-session auth token from the discovery file
_agent_introduced: bool = False        # First-call introduction flag

# Cache variable to store the result of the ggplot2 check
_is_ggplot_installed = None

# Annotation job state — keyed by job_id, for subprocess-per-row batch mode
_annot_jobs: Dict[str, Any] = {}

# Annotation state — persists across load_annotation_data / annotate calls
_annot_state: Dict[str, Any] = {
    "rows": None,        # list of dicts (full CSV rows)
    "fieldnames": None,  # original column order
    "path": None,        # path to working copy
    "index": 0,          # current row index
    "schema": None,      # parsed schema dict
    "total": 0,          # total row count
}


def _pid_alive(pid: int) -> bool:
    """Check if a process is running.

    On POSIX, signal 0 is the canonical liveness probe. On Windows, os.kill(pid, 0)
    raises even for live processes, so we use OpenProcess(SYNCHRONIZE, ...) which
    is the minimum-privilege Windows equivalent and only succeeds for live PIDs.
    """
    if pid <= 0:
        return False
    if sys.platform == "win32":
        import ctypes
        SYNCHRONIZE = 0x00100000
        handle = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, False, pid)
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def discover_sessions() -> List[Dict[str, Any]]:
    """Read discovery files, pruning any whose R process is dead."""
    sessions = []
    if not os.path.isdir(SESSIONS_DIR):
        return sessions
    for f in os.listdir(SESSIONS_DIR):
        if not f.endswith(".json"):
            continue
        fpath = os.path.join(SESSIONS_DIR, f)
        try:
            with open(fpath) as fh:
                info = json.load(fh)
            if not _pid_alive(info.get("pid", -1)):
                os.remove(fpath)
                continue
            sessions.append(info)
        except Exception:
            try:
                os.remove(fpath)
            except OSError:
                pass
    return sessions


def get_r_addin_url() -> Optional[str]:
    """Get the URL for the active R session. Binds on first resolution and
    stays sticky. Prefers the 'default' session when no target is set.

    Also latches the session's auth token, which the R server requires on
    every request (see _auth_headers)."""
    global _target_session, _target_token
    sessions = discover_sessions()
    if not sessions:
        _target_token = None
        return R_ADDIN_URL
    if _target_session:
        for s in sessions:
            if s["session_name"] == _target_session:
                _target_token = s.get("token")
                return f"http://127.0.0.1:{s['port']}"
        _target_session = None  # bound session gone, re-pick
    # Pick: prefer "default" name, else lowest port
    pick = next((s for s in sessions if s.get("session_name") == "default"), None)
    if not pick:
        sessions.sort(key=lambda s: s.get("port", 99999))
        pick = sessions[0]
    _target_session = pick["session_name"]
    _target_token = pick.get("token")
    return f"http://127.0.0.1:{pick['port']}"


def _auth_headers() -> Dict[str, str]:
    """Token proving we read the discovery file, which only this user can read.
    The R server rejects any request without it — localhost alone is not a
    security boundary (any local process, and any webpage via a no-preflight
    cross-origin POST, can otherwise reach the execute endpoint)."""
    return {"X-Clauder-Token": _target_token} if _target_token else {}


def parse_args():
    parser = argparse.ArgumentParser(description="R Studio MCP Server")
    parser.add_argument("--agent-id", type=str,
                        default=os.environ.get("CLAUDER_AGENT_ID", None),
                        help="Unique identifier for this agent instance")
    return parser.parse_args()



async def check_ggplot_installed() -> bool:
    """
    Performs a one-time check to see if ggplot2 is installed in the R environment.
    Caches the result for subsequent calls.
    """
    global _is_ggplot_installed
    # Only a positive result is cached. Caching a negative would keep refusing
    # plot calls for the rest of the session even after the agent installs
    # ggplot2 — which it is explicitly allowed to do.
    if _is_ggplot_installed:
        return True

    result = await execute_r_code_via_addin("print(requireNamespace('ggplot2', quietly = TRUE))")

    if result.get("success") and "TRUE" in result.get("output", ""):
        print("ggplot2 check successful.", file=sys.stderr)
        _is_ggplot_installed = True
        return True

    print("ggplot2 not found in R environment.", file=sys.stderr)
    return False

def escape_r_string(s: str) -> str:
    """Escape special characters for safe inclusion in R double-quoted strings."""
    s = s.replace("\\", "\\\\")   # Backslashes first (order matters)
    s = s.replace('"', '\\"')      # Double quotes
    s = s.replace("'", "\\'")      # Single quotes
    s = s.replace("`", "\\`")      # Backticks (R evaluation)
    s = s.replace("\n", "\\n")     # Newlines
    s = s.replace("\r", "\\r")     # Carriage returns
    s = s.replace("\t", "\\t")     # Tabs
    s = s.replace("\0", "")        # Null bytes (strip entirely)
    return s

# Function to execute R code via the HTTP addin
async def execute_r_code_via_addin(code: str) -> Dict[str, Any]:
    """Execute R code through the RStudio addin HTTP server."""
    url = get_r_addin_url()
    if url is None:
        return {
            "success": False,
            "error": "No R sessions found. Start the ClaudeR addin in RStudio first."
        }
    try:
        payload: Dict[str, Any] = {"code": code}
        if _agent_id:
            payload["agent_id"] = _agent_id
        async with httpx.AsyncClient() as client:
            response = await client.post(
                url,
                json=payload,
                headers=_auth_headers(),
                timeout=120.0
            )
            response.raise_for_status()
            return response.json()
    except httpx.HTTPError as e:
        print(f"HTTP error: {str(e)}", file=sys.stderr)
        return {
            "success": False,
            "error": f"HTTP error communicating with RStudio: {str(e)}"
        }
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        return {
            "success": False,
            "error": f"Error communicating with RStudio: {str(e)}"
        }

async def post_to_r_addin(payload: Dict[str, Any], timeout: float = 10.0) -> Dict[str, Any]:
    """Send an arbitrary JSON payload to the R addin HTTP server."""
    url = get_r_addin_url()
    if url is None:
        return {"success": False, "error": "No R sessions found. Start the ClaudeR addin in RStudio first."}
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(url, json=payload,
                                         headers=_auth_headers(), timeout=timeout)
            response.raise_for_status()
            return response.json()
    except Exception as e:
        return {"success": False, "error": f"Error communicating with RStudio: {str(e)}"}


# Check if the R addin is running and return status info
async def check_addin_status(return_info: bool = False):
    """Check if the RStudio addin is running.
    If return_info is True, returns the full status dict or None.
    Otherwise returns a bool."""
    url = get_r_addin_url()
    if url is None:
        return None if return_info else False
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(url, headers=_auth_headers(), timeout=5.0)
            if response.status_code == 200:
                if return_info:
                    return response.json()
                return True
    except httpx.TimeoutException:
        # R is single-threaded: a timeout here usually means the session is
        # busy running another agent's synchronous code, not that the addin
        # is down. Treat it as alive so callers queue instead of erroring.
        return None if return_info else True
    except Exception:
        pass
    return None if return_info else False


async def get_agent_introduction() -> str:
    """Build a one-time context message for the agent's first tool call."""
    info = await check_addin_status(return_info=True)

    lines = [
        f"[ClaudeR Agent Context]",
        f"Your agent ID: {_agent_id} ({_agent_id_source})",
        "If other agents or personas share this connection, do NOT rename the "
        "shared identity with set_agent_name; pass as_agent on each "
        "coordination call instead, so every persona keeps its own name and "
        "read cursor.",
        f"This ID uniquely identifies you in this R session. All code you execute is attributed to this ID.",
    ]

    if info:
        agents = info.get("connected_agents", [])
        if isinstance(agents, str):
            # Older R servers unbox a single-element array to a bare string;
            # without this guard we'd iterate it character by character.
            agents = [agents]
        other_agents = [a for a in agents if a != _agent_id and a != "unknown"]
        if other_agents:
            lines.append(f"Other agents active on this session: {', '.join(other_agents)}")
            lines.append("These are other AI agents executing code in the same R environment. Coordinate to avoid conflicts.")

        log_path = info.get("log_file_path")
        if log_path:
            lines.append(f"Session log file: {log_path}")
            lines.append("This log contains all code executed by all agents. Read it to see what others have done.")

        session_name = info.get("session_name", "unknown")
        lines.append(f"Session: {session_name}")

    lines.append("")
    lines.append("[Quick Reference]")
    lines.append("Available protocol prompts (run in R to read):")
    lines.append("  ClaudeR::reviewer_zero_prompt()     - Manuscript auditing protocol")
    lines.append("  ClaudeR::referee_prompt()            - Substantive review (logic, methods, framing) as Word comments")
    lines.append("  ClaudeR::grant_panel_prompt()        - Mock study section for a grant proposal (nih or nsf rubric)")
    lines.append("  ClaudeR::screening_prompt()          - Systematic-review screening with dual-model agreement")
    lines.append("  ClaudeR::reviewer_response_prompt()  - Point-by-point response to a revise-and-resubmit")
    lines.append("  ClaudeR::r_best_practices_prompt()   - Statistical analysis protocol")
    lines.append("  ClaudeR::multi_agent_prompt()        - Multi-agent coordination protocol")
    lines.append("")
    lines.append("Multi-agent identity: call set_agent_name with your working name (e.g.")
    lines.append("'Claude-Stasis') BEFORE other work, so history and messages carry a name")
    lines.append("your partners recognize instead of the random id above.")
    lines.append("")
    lines.append("Safety: call checkpoint_session before risky changes (overwrites, removals,")
    lines.append("destructive transformations); restore_session rolls the environment back.")
    lines.append("")
    lines.append("Context-saving rules:")
    lines.append("  - Do NOT use installed.packages(). Use requireNamespace('pkg') to check for a specific package.")
    lines.append("  - Do NOT use bare ls(). Use head(ls(), 20) or search for specific objects with exists('name').")
    lines.append("  - Do NOT use bare list.files(). Use head(list.files(), 20) or list.files(pattern = 'specific').")
    lines.append("  - These commands can return hundreds of items and fill up your context window.")
    lines.append("[End ClaudeR Agent Context]")
    return "\n".join(lines)

# --- Coordination v2: shared JSONL event log ---
# The R package and this bridge read/write the same append-only file, so
# coordination works even while the R session is busy executing code, and
# wait_for_message can long-poll without a single R roundtrip.

def _coord_dir() -> str:
    get_r_addin_url()  # latch a session if not bound yet
    session = _target_session or "default"
    safe = re.sub(r"[^a-zA-Z0-9_-]", "_", session)
    d = os.path.join(os.path.expanduser("~"), ".clauder_coord", safe)
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _coord_log_path() -> str:
    return os.path.join(_coord_dir(), "events.jsonl")


def _coord_append(ev_type: str, body: Any, to: str = "all",
                  reply_to: Optional[int] = None,
                  as_agent: Optional[str] = None) -> None:
    ev = {
        "ts": datetime.now().strftime("%Y-%m-%dT%H:%M:%S.") +
              f"{datetime.now().microsecond // 1000:03d}",
        "from": as_agent or _agent_id,
        "type": ev_type,
        "to": to,
        "body": body,
    }
    if reply_to is not None:
        ev["reply_to"] = int(reply_to)
    line = json.dumps(ev, ensure_ascii=False)
    if len(line) > 4000:
        raise ValueError("Coordination event too large (> 4000 chars).")
    with open(_coord_log_path(), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def _coord_events() -> List[Dict[str, Any]]:
    path = _coord_log_path()
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as f:
        for i, raw in enumerate(f, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
                ev["id"] = i
                out.append(ev)
            except json.JSONDecodeError:
                continue
    return out


def _coord_cursor_path(as_agent: Optional[str] = None) -> str:
    safe = re.sub(r"[^a-zA-Z0-9_-]", "_", (as_agent or _agent_id) or "unknown")
    return os.path.join(_coord_dir(), f"cursor_{safe}.txt")


def _coord_cursor(as_agent: Optional[str] = None) -> int:
    try:
        with open(_coord_cursor_path(as_agent)) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 0


def _coord_set_cursor(through_id: int, as_agent: Optional[str] = None) -> None:
    with open(_coord_cursor_path(as_agent), "w") as f:
        f.write(str(int(through_id)))


def _coord_unread(from_agent: Optional[str] = None,
                  ev_type: Optional[str] = None,
                  as_agent: Optional[str] = None) -> List[Dict[str, Any]]:
    cur = _coord_cursor(as_agent)
    me = as_agent or _agent_id
    out = []
    for ev in _coord_events():
        if ev["id"] <= cur or ev.get("from") == me:
            continue
        if ev.get("to") not in ("all", me):
            continue
        if ev.get("type") == "heartbeat":
            continue
        if from_agent and ev.get("from") != from_agent:
            continue
        if ev_type and ev.get("type") != ev_type:
            continue
        out.append(ev)
    return out


def _coord_format(events: List[Dict[str, Any]]) -> str:
    lines = []
    for ev in events:
        body = ev.get("body")
        if isinstance(body, dict) and set(body.keys()) == {"text"}:
            body_txt = body["text"]
        else:
            body_txt = json.dumps(body, ensure_ascii=False)
        reply = f" (reply to #{ev['reply_to']})" if ev.get("reply_to") else ""
        lines.append(f"[#{ev['id']} {ev.get('ts','')} {ev.get('from','?')} "
                     f"-> {ev.get('to','all')} | {ev.get('type','message')}{reply}] {body_txt}")
    return "\n".join(lines)


_coord_bound: Optional[str] = None  # session whose log the last coordination call used


def _coord_target() -> tuple:
    """Resolve which session's log a coordination call will touch.

    Returns (note, error), at most one non-None. Coordination logs are keyed
    by session name on disk, so a bridge still bound to a dead session would
    write to a log no live agent reads while reporting success (field bug:
    get_r_addin_url keeps the stale name when zero sessions are alive). Fail
    loudly in that case, and say so when the binding moves to a different
    live session, because earlier traffic sits in the old log unseen."""
    global _coord_bound
    get_r_addin_url()  # re-binds _target_session to a live session if any exists
    if not discover_sessions():
        stale = _target_session or _coord_bound or "default"
        return (None,
                "FAILED: no live R session is running, so this call would use a "
                f"stale coordination log (session '{stale}') that no live agent "
                "reads. Nothing was written or read. Start the ClaudeR addin in "
                "RStudio, confirm with list_sessions, then retry.")
    session = _target_session or "default"
    note = None
    if _coord_bound is not None and _coord_bound != session:
        note = (f"NOTE: this connection re-bound from session '{_coord_bound}' "
                f"(gone) to live session '{session}' and now uses that session's "
                "coordination log. Earlier sends may sit in the old log unseen. "
                "Resend anything the other agents did not acknowledge.")
    _coord_bound = session
    return (note, None)


# --- Annotation job helpers (subprocess-per-row batch mode) ---

def _find_cli_path(tool: str) -> Optional[str]:
    """Auto-detect the path for claude or codex CLI."""
    return shutil.which(tool)


def _build_subprocess_prompt(row: Dict, schema: Dict[str, Any], annot_fields: List[str]) -> str:
    """Build a lean one-shot prompt for a single row annotation subprocess."""
    field_lines = []
    for field, spec in schema.items():
        t, constraint = spec["type"], spec["constraint"]
        if t == "choice":
            field_lines.append(f"- {field}: one of [{constraint}]")
        elif t in ("float", "int"):
            lo, hi = constraint.split(",")
            field_lines.append(f"- {field}: {t} between {lo} and {hi}")
        elif t == "bool":
            field_lines.append(f"- {field}: true or false")
        else:
            field_lines.append(f"- {field}: text (can be empty string \"\")")

    row_data = {k: v for k, v in row.items() if k not in annot_fields and k != "_schema"}
    row_json = json.dumps(row_data, ensure_ascii=False, indent=2)
    field_names = list(schema.keys())

    return (
        "Annotate the following data row.\n"
        "Return ONLY a valid JSON object — no explanation, no markdown, no code blocks.\n\n"
        "Fields to annotate:\n"
        + "\n".join(field_lines)
        + f"\n\nRow:\n{row_json}\n\n"
        f"Return a JSON object with exactly these keys: {field_names}"
    )


def _extract_json(text: str) -> Optional[Dict]:
    """Extract a JSON object from model output, handling markdown code blocks."""
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    # Strip markdown fences
    cleaned = re.sub(r"^```(?:json)?\s*", "", text, flags=re.MULTILINE)
    cleaned = re.sub(r"```\s*$", "", cleaned, flags=re.MULTILINE).strip()
    try:
        return json.loads(cleaned)
    except Exception:
        pass
    # Find first {...} block
    match = re.search(r"\{.*\}", cleaned, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())
        except Exception:
            pass
    return None


def _run_subprocess_row(
    prompt: str, tool: str, tool_path: str,
    model: Optional[str], timeout: int, reasoning_effort: str = "high",
    ollama_base_url: str = "http://localhost:11434"
) -> tuple:
    """Run a single annotation subprocess (or HTTP call for ollama). Returns (result_dict or None, raw_output, error_msg)."""
    try:
        if tool == "claude":
            command = [tool_path, "-p", "--no-session-persistence"]
            if model:
                command.extend(["--model", model])
            completed = subprocess.run(
                command, input=prompt, text=True,
                capture_output=True, timeout=timeout
            )
            output = completed.stdout

        elif tool == "gemini":
            command = [tool_path, "-p", prompt]
            if model:
                command.extend(["-m", model])
            completed = subprocess.run(
                command, text=True,
                capture_output=True, timeout=timeout
            )
            output = completed.stdout

        elif tool == "agy":
            # Antigravity CLI. -p is an alias for --print (headless one-shot).
            # Verified working against agy 1.0.5.
            command = [tool_path, "-p", prompt]
            if model:
                command.extend(["--model", model])
            completed = subprocess.run(
                command, text=True,
                capture_output=True, timeout=timeout
            )
            output = completed.stdout

        elif tool == "qwen":
            command = [tool_path, "--prompt", prompt]
            if model:
                command.extend(["--model", model])
            completed = subprocess.run(
                command, text=True,
                capture_output=True, timeout=timeout
            )
            output = completed.stdout

        elif tool == "ollama":
            # No subprocess; POST to Ollama's HTTP API. format=json puts the model in
            # JSON mode (still requires the prompt to instruct JSON output, which it does).
            payload = {
                "model": model or "qwen2.5",
                "prompt": prompt,
                "stream": False,
                "format": "json",
                "options": {"temperature": 0},
                "think": False,           # thinking models would otherwise hide the answer in the `thinking` field
                "keep_alive": "5m",
            }
            try:
                with httpx.Client(timeout=timeout) as client:
                    resp = client.post(f"{ollama_base_url.rstrip('/')}/api/generate", json=payload)
                    resp.raise_for_status()
                    output = resp.json().get("response", "")
            except httpx.ConnectError:
                return None, "", (
                    f"Could not reach Ollama at {ollama_base_url}. "
                    f"Is `ollama serve` running? Or set ollama_base_url to a different host."
                )
            except httpx.HTTPStatusError as e:
                body = (e.response.text or "")[:300]
                return None, "", f"Ollama returned HTTP {e.response.status_code}: {body}"

        else:  # codex
            fd, last_msg_path = tempfile.mkstemp(suffix=".txt")
            os.close(fd)
            command = [
                tool_path, "exec",
                "-c", "mcp_servers={}",
                "-c", f"model_reasoning_effort={reasoning_effort}",
                "--skip-git-repo-check",
                "--output-last-message", last_msg_path,
                "-",
            ]
            if model:
                command.extend(["--model", model])
            completed = subprocess.run(
                command, input=prompt, text=True,
                capture_output=True, timeout=timeout
            )
            if os.path.exists(last_msg_path):
                with open(last_msg_path) as f:
                    output = f.read()
                os.remove(last_msg_path)
            else:
                output = completed.stdout

        parsed = _extract_json(output)
        if parsed is None:
            return None, output, f"Could not parse JSON from output: {output[:300]}"
        return parsed, output, None

    except subprocess.TimeoutExpired:
        return None, "", f"Subprocess timed out after {timeout}s"
    except Exception as e:
        return None, "", str(e)


def _annotation_job_worker(
    job_id: str, rows: List[Dict], fieldnames: List[str],
    unannotated_indices: List[int], schema: Dict[str, Any],
    work_path: str, tool: str, tool_path: str,
    model: Optional[str], timeout: int, reasoning_effort: str = "high",
    ollama_base_url: str = "http://localhost:11434"
) -> None:
    """Background thread: annotate each row with a fresh subprocess."""
    import csv as csv_module

    annot_fields = list(schema.keys())
    job = _annot_jobs[job_id]
    job["status"] = "running"

    for row_idx in unannotated_indices:
        if job.get("cancelled"):
            job["status"] = "cancelled"
            return

        row = rows[row_idx]
        prompt = _build_subprocess_prompt(row, schema, annot_fields)
        result, raw, err = _run_subprocess_row(prompt, tool, tool_path, model, timeout, reasoning_effort, ollama_base_url)

        if err or result is None:
            job["errors"].append({
                "row_id": row.get("row_id", row_idx),
                "error": err or "No result"
            })
            job["done"] += 1
            continue

        valid, validation_err = _validate_annotation(
            {k: str(v) for k, v in result.items()}, schema
        )
        if not valid:
            job["errors"].append({
                "row_id": row.get("row_id", row_idx),
                "error": f"Validation failed: {validation_err}"
            })
            job["done"] += 1
            continue

        for field in annot_fields:
            if field in result:
                rows[row_idx][field] = result[field]

        # Save immediately after each row
        with open(work_path, "w", newline="", encoding="utf-8") as f:
            writer = csv_module.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

        job["done"] += 1

    job["status"] = "complete"


# --- Annotation helpers ---

def _parse_annotation_schema(schema_str: str) -> Dict[str, Any]:
    """Parse 'field:type[constraint];...' into {field: {type, constraint}}."""
    fields: Dict[str, Any] = {}
    for part in schema_str.strip().split(";"):
        part = part.strip()
        if not part:
            continue
        if ":" not in part:
            raise ValueError(f"Invalid schema entry '{part}'. Expected 'field:type' or 'field:type[constraint]'.")
        name, rest = part.split(":", 1)
        name, rest = name.strip(), rest.strip()
        if "[" in rest:
            type_name, constraint_str = rest.split("[", 1)
            constraint_str = constraint_str.rstrip("]").strip()
        else:
            type_name, constraint_str = rest, None
        fields[name] = {"type": type_name.strip(), "constraint": constraint_str}
    return fields


def _validate_annotation(fields: Dict[str, str], schema: Dict[str, Any]) -> tuple:
    """Returns (True, '') or (False, error_message)."""
    missing = [f for f in schema if f not in fields]
    if missing:
        return False, f"Missing fields: {missing}. Required: {list(schema.keys())}"
    extra = [f for f in fields if f not in schema]
    if extra:
        return False, f"Unexpected fields: {extra}. Only allowed: {list(schema.keys())}"
    for field, spec in schema.items():
        value = str(fields[field]).strip()
        t, constraint = spec["type"], spec["constraint"]
        if t == "choice":
            choices = [c.strip() for c in constraint.split(",")]
            if value not in choices:
                return False, f"Field '{field}': '{value}' must be one of {choices}."
        elif t == "float":
            try:
                v = float(value)
                if constraint:
                    lo, hi = constraint.split(",")
                    if not (float(lo) <= v <= float(hi)):
                        return False, f"Field '{field}': {v} out of range [{lo}, {hi}]."
            except ValueError:
                return False, f"Field '{field}': '{value}' is not a valid float."
        elif t == "int":
            try:
                v = int(value)
                if constraint:
                    lo, hi = constraint.split(",")
                    if not (int(lo) <= v <= int(hi)):
                        return False, f"Field '{field}': {v} out of range [{lo}, {hi}]."
            except ValueError:
                return False, f"Field '{field}': '{value}' is not a valid integer."
        elif t == "bool":
            if value.lower() not in ("true", "false", "1", "0", "yes", "no"):
                return False, f"Field '{field}': '{value}' is not a valid boolean (true/false)."
        elif t == "text":
            pass
        else:
            return False, f"Unknown type '{t}' for field '{field}'."
    return True, ""


def _row_display(row: Dict, schema_fields: List[str]) -> str:
    """Return a readable string of non-annotation, non-schema columns."""
    lines = []
    for k, v in row.items():
        if k == "_schema" or k in schema_fields:
            continue
        lines.append(f"  {k}: {v}")
    return "\n".join(lines)


def _save_annotation_csv() -> None:
    """Write current annotation state back to the working CSV."""
    import csv as csv_module
    with open(_annot_state["path"], "w", newline="", encoding="utf-8") as f:
        writer = csv_module.DictWriter(f, fieldnames=_annot_state["fieldnames"])
        writer.writeheader()
        writer.writerows(_annot_state["rows"])


# Define available tools
@server.list_tools()
async def list_tools() -> List[types.Tool]:
    """List available R tools."""
    return [
        types.Tool(
            name="execute_r",
            description="Execute R code and return the output",
            inputSchema={
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "R code to execute. Avoid hardcoding values pulled from analyses. Always dynamically pull the value from the object or dataframe."
                    }
                },
                "required": ["code"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="execute_r_with_plot",
            description="Execute R code that generates a plot",
            inputSchema={
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "R code to execute that generates a plot"
                    }
                },
                "required": ["code"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="get_r_info",
            description="Get a summary of the R environment. Returns package count (not full list), first 20 variables, and R version. Use requireNamespace('pkg') to check for specific packages.",
            inputSchema={
                "type": "object",
                "properties": {
                    "what": {
                        "type": "string",
                        "description": "What information to get: 'packages' (count only), 'variables' (first 20), 'version', or 'all'"
                    }
                },
                "required": ["what"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="get_active_document",
            description=(
                "Read the focused RStudio editor BUFFER (not the file on disk). Returns the content, "
                "the document path, and 'unsaved_changes' telling you whether the buffer differs from disk. "
                "Use this as the source of truth while editing; read_file reports the DISK state, which "
                "will be stale until the edit is saved. Errors loudly if no document is open or focused."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Optional: absolute path of the file to read. If it is not the focused document, ClaudeR tries to open and focus it first."
                    }
                }
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="modify_code_section",
            description=(
                "Regex find-and-replace in an RStudio editor document. Saves to disk by default "
                "(save=false stages the edit in the buffer only). Pass 'path' to target a specific file "
                "instead of whatever happens to be focused. The replacement may change the number of lines. "
                "Returns 'saved_to_disk' so you know whether read_file will reflect the change."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "search_pattern": {
                        "type": "string",
                        "description": "Pattern to identify the section of code to be modified"
                    },
                    "replacement": {
                        "type": "string",
                        "description": "New code to replace the identified section"
                    },
                    "line_start": {
                        "type": "number",
                        "description": "Optional: Start line number for the search (1-based indexing)"
                    },
                    "line_end": {
                        "type": "number",
                        "description": "Optional: End line number for the search (1-based indexing)"
                    },
                    "path": {
                        "type": "string",
                        "description": "Optional: absolute path of the file to edit. ClaudeR opens/focuses it and refuses to edit a different document."
                    },
                    "save": {
                        "type": "boolean",
                        "description": "Save the document to disk after the edit (default true). Set false to leave the change unsaved in the buffer."
                    }
                },
                "required": ["search_pattern", "replacement"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": True,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="insert_text",
            description=(
                "Insert text into an RStudio editor document at the cursor, or at a given line/column. "
                "Saves to disk by default (save=false leaves it unsaved in the buffer). Pass 'path' to "
                "target a specific file rather than whatever is focused."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "The text to insert"
                    },
                    "line": {
                        "type": "number",
                        "description": "Optional: Line number to insert at (1-based). If omitted, inserts at current cursor position."
                    },
                    "column": {
                        "type": "number",
                        "description": "Optional: Column number to insert at (1-based). Defaults to 1 if line is specified but column is omitted."
                    },
                    "path": {
                        "type": "string",
                        "description": "Optional: absolute path of the file to insert into. ClaudeR opens/focuses it and refuses to write to a different document."
                    },
                    "save": {
                        "type": "boolean",
                        "description": "Save the document to disk after inserting (default true)."
                    }
                },
                "required": ["text"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="suggest_edit",
            description=(
                "Propose an edit for the user to APPROVE before it is applied, instead of writing it "
                "directly. Uses rstudioapi::showEditSuggestion() when the RStudio build provides it; "
                "otherwise stages the change in the editor buffer and deliberately does NOT save, so the "
                "user accepts by saving or rejects with Undo. Use this when the user asked to review "
                "changes first. After calling it, STOP and wait for the user's decision."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "search_pattern": {
                        "type": "string",
                        "description": "Regex pattern identifying the code to change"
                    },
                    "replacement": {
                        "type": "string",
                        "description": "Replacement text"
                    },
                    "path": {
                        "type": "string",
                        "description": "Optional: absolute path of the file to edit"
                    }
                },
                "required": ["search_pattern", "replacement"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="create_task_list",
            description="Create a task list for the current analysis",
            inputSchema={
                "type": "object",
                "properties": {
                    "tasks": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {"type": "string"},
                                "description": {"type": "string"},
                                "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}
                            }
                        },
                        "description": "List of tasks to complete"
                    }
                },
                "required": ["tasks"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="update_task_status",
            description="Update the status of a task and optionally add notes",
            inputSchema={
                "type": "object",
                "properties": {
                    "task_id": {
                        "type": "string",
                        "description": "ID of the task to update"
                    },
                    "status": {
                        "type": "string",
                        "enum": ["pending", "in_progress", "completed"],
                        "description": "New status for the task"
                    },
                    "notes": {
                        "type": "string",
                        "description": "Optional notes about the task progress"
                    }
                },
                "required": ["task_id", "status"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="clean_error_log",
            description="Clean a ClaudeR session log by removing error blocks and their duplicates. Parses the log, finds errors, checks if a fix follows each error, removes the error blocks and any duplicate code blocks that preceded them. Returns a report of what was found and removed.",
            inputSchema={
                "type": "object",
                "properties": {
                    "log_path": {
                        "type": "string",
                        "description": "Path to the ClaudeR session log file"
                    },
                    "output_path": {
                        "type": "string",
                        "description": "Optional path to write the cleaned log. If omitted, overwrites the original file."
                    }
                },
                "required": ["log_path"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": True,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="execute_r_async",
            description=(
                "Execute long-running R code in a separate background R process. Returns a job ID immediately and the main session stays fully responsive. "
                "Use this for code that may take longer than 25 seconds (e.g., model fitting, simulations, large data processing).\n\n"
                "TWO MODES:\n"
                "1. Auto-marshaled (recommended). Pass `inputs` (object names from the main session to copy into the background) and `outputs` (object names the background code creates that should be loaded back into the main session). The tool handles all saveRDS/readRDS plumbing. Inputs are snapshotted at submit time, so changes in the main session after submit do not affect the running job. Outputs are auto-loaded into the main session when get_async_result returns complete.\n"
                "2. Manual. Omit `inputs` and `outputs` and write self-contained code that uses saveRDS()/readRDS() to pass data in and out yourself. Backwards-compatible with existing patterns.\n\n"
                "The background process never has access to the main session's environment except via the marshaled `inputs`. Connection objects (DB connections, open file handles) cannot be marshaled. The background process must `library()` any packages it needs.\n\n"
                "You can continue executing other code with execute_r while the job runs. Use get_async_result to check status when ready."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "R code to execute asynchronously."
                    },
                    "inputs": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional. Names of objects in the main R session to copy into the background process before running `code`. Connection objects cannot be marshaled."
                    },
                    "outputs": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional. Names of objects the background code will create that should be loaded back into the main R session when get_async_result reports complete."
                    }
                },
                "required": ["code"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="get_async_result",
            description="Check the result of an async R job. Waits ~10 seconds before checking to avoid excessive polling. If the job is still running, call this again.",
            inputSchema={
                "type": "object",
                "properties": {
                    "job_id": {
                        "type": "string",
                        "description": "The job ID returned by execute_r_async"
                    }
                },
                "required": ["job_id"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="cancel_async_job",
            description=(
                "Terminate a running execute_r_async job. Sends SIGTERM (then SIGKILL after a "
                "brief grace period) to the background R process and cleans up any marshaled "
                "input/output tempfiles. Use this when an async job is hung, taking far longer "
                "than expected, or you realized the code has a bug. Safe to call on jobs that "
                "have already finished — returns 'not_found' in that case."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "job_id": {
                        "type": "string",
                        "description": "The job ID returned by execute_r_async"
                    }
                },
                "required": ["job_id"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": True,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="list_sessions",
            description="List available RStudio sessions that this agent can connect to. Shows session name, port, and PID for each active session.",
            inputSchema={
                "type": "object",
                "properties": {}
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="connect_session",
            description="Connect to a specific RStudio session by name. Use list_sessions first to see available sessions. Subsequent tool calls will be routed to this session.",
            inputSchema={
                "type": "object",
                "properties": {
                    "session_name": {
                        "type": "string",
                        "description": "Name of the R session to connect to"
                    }
                },
                "required": ["session_name"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="read_file",
            description="Read the contents of a file from disk. Handles plain text (R scripts, logs, CSVs) and manuscripts: .docx and .pdf are transparently extracted as structured text with headings prefixed by #s and table cells emitted row-wise as '[Table k, row j] cell | cell | cell', so table content is never lost or concatenated. Returns numbered lines; supports pagination via start_line/end_line for large files. To modify and save changes back, use execute_r with writeLines().",
            inputSchema={
                "type": "object",
                "properties": {
                    "file_path": {
                        "type": "string",
                        "description": "Path to the file to read. Supports absolute paths and ~ for home directory."
                    },
                    "start_line": {
                        "type": "number",
                        "description": "Optional: first line to return (1-based). Omit to start from beginning."
                    },
                    "end_line": {
                        "type": "number",
                        "description": "Optional: last line to return (1-based, inclusive). Omit to read to end of file."
                    }
                },
                "required": ["file_path"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="search_project_code",
            description="Search for a regex pattern across project source files (.R, .Rmd, .qmd). Returns matching file, line number, and code snippet. Uses base R grep — safe to use even with system() blocked.",
            inputSchema={
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                        "description": "Regular expression pattern to search for."
                    },
                    "file_extensions": {
                        "type": "string",
                        "description": "Comma-separated file extensions to search. Default: 'R,Rmd,qmd'"
                    },
                    "root_dir": {
                        "type": "string",
                        "description": "Root directory to search from. Default: current working directory."
                    },
                    "max_results": {
                        "type": "number",
                        "description": "Maximum number of matching lines to return. Default: 50."
                    },
                    "ignore_case": {
                        "type": "boolean",
                        "description": "Whether to ignore case. Default: false."
                    }
                },
                "required": ["pattern"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="probe_scripts",
            description="Source one or more R scripts in a clean background session and report what objects are created (names, classes, dimensions). Does NOT affect the main R session. With capture_output=true it also returns the statistics the script prints when run — a clean-room evaluation that stale objects in the live session cannot contaminate. Use that mode to build the ground-truth corpus for reconcile_values and for final audit verdicts.",
            inputSchema={
                "type": "object",
                "properties": {
                    "script_paths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Paths to R scripts to source, each in isolation."
                    },
                    "timeout": {
                        "type": "number",
                        "description": "Seconds before timing out per script. Default: 60."
                    },
                    "capture_output": {
                        "type": "boolean",
                        "description": "Also return the printed output of running each script (capped). Default: false."
                    }
                },
                "required": ["script_paths"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="verify_references",
            description="Verify academic references by looking up DOIs in the CrossRef API. Extracts DOIs from a manuscript or references file, queries CrossRef for each, and returns metadata (title, authors, year, journal) for comparison against manuscript claims. References without DOIs are flagged for manual web search verification. Can be used standalone or as part of a Reviewer Zero audit.",
            inputSchema={
                "type": "object",
                "properties": {
                    "file": {
                        "type": "string",
                        "description": "Path to the manuscript or references file"
                    },
                    "text": {
                        "type": "string",
                        "description": "Raw text containing references (alternative to file)"
                    },
                    "start_line": {
                        "type": "integer",
                        "description": "Start reading from this line (optional, for targeting the references section)"
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "Stop reading at this line (optional)"
                    }
                }
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": True,
            }
        ),
        types.Tool(
            name="get_viewer_content",
            description="Get HTML content from the RStudio Viewer pane (HTML widgets like plotly, DT, leaflet). Returns paginated chunks. Call with offset to get more.",
            inputSchema={
                "type": "object",
                "properties": {
                    "max_length": {
                        "type": "number",
                        "description": "Maximum characters to return (default 10000)"
                    },
                    "offset": {
                        "type": "number",
                        "description": "Character offset to start from (default 0). Use to paginate through large content."
                    }
                }
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="get_session_history",
            description="Get execution history for the current R session. Can filter by agent to see what a specific agent has done.",
            inputSchema={
                "type": "object",
                "properties": {
                    "agent_filter": {
                        "type": "string",
                        "description": "Filter history by agent ID. Use 'self' for own history, 'all' for everything, or a specific agent ID."
                    },
                    "last_n": {
                        "type": "number",
                        "description": "Number of recent entries to return (default 20)"
                    },
                    "include_past": {
                        "type": "boolean",
                        "description": "Also parse prior session log files on disk, so the audit trail survives R restarts. Entries from past logs are tagged {logfile}. Default false."
                    }
                }
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="run_annotation_job",
            description=(
                "Annotate a CSV dataset using a fresh subprocess (or Ollama HTTP call) per row, with no context bleed between rows. "
                "Each row is scored by a brand-new claude, codex, gemini, agy (Antigravity), qwen, or ollama process that sees only that row. "
                "Runs in the background; returns a job ID immediately. "
                "Use get_annotation_job_status to check progress and cancel_annotation_job to stop. "
                "The original CSV is never modified; results go to {name}_annotating.csv. "
                "Resumable: rows already annotated are skipped automatically."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "csv_path": {
                        "type": "string",
                        "description": "Path to the CSV file. Must have a '_schema' column in the first row."
                    },
                    "tool": {
                        "type": "string",
                        "description": "Backend to use: 'claude' (default), 'codex', 'gemini', 'agy' (Antigravity CLI, Google's replacement for Gemini CLI starting 2026-06-18), 'qwen' (Qwen Code CLI), or 'ollama' (local Ollama HTTP server). The CLI tools require their respective binary on PATH; ollama requires `ollama serve` running locally."
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name to pass to the backend (optional). For ollama, this is the model tag (e.g. 'qwen2.5', 'llama3.2'). Defaults to 'qwen2.5' for ollama; uses each CLI's own default for the others."
                    },
                    "timeout": {
                        "type": "number",
                        "description": "Seconds to wait per row before giving up (default: 60)."
                    },
                    "reasoning_effort": {
                        "type": "string",
                        "description": "Codex only: reasoning effort level: 'low', 'medium', 'high' (default), or 'none'."
                    },
                    "ollama_base_url": {
                        "type": "string",
                        "description": "Ollama only: base URL of the Ollama server. Defaults to 'http://localhost:11434'. Set this to point at a remote Ollama instance (e.g. a LAN GPU box)."
                    }
                },
                "required": ["csv_path"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="get_annotation_job_status",
            description="Check the status of a running or completed annotation job started with run_annotation_job.",
            inputSchema={
                "type": "object",
                "properties": {
                    "job_id": {
                        "type": "string",
                        "description": "Job ID returned by run_annotation_job."
                    }
                },
                "required": ["job_id"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="cancel_annotation_job",
            description="Cancel a running annotation job. The current row finishes before stopping. Already-saved rows are kept and the job is resumable.",
            inputSchema={
                "type": "object",
                "properties": {
                    "job_id": {
                        "type": "string",
                        "description": "Job ID returned by run_annotation_job."
                    }
                },
                "required": ["job_id"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="load_annotation_data",
            description=(
                "Load a CSV file for annotation. Creates a working copy (original is never modified), "
                "reads the '_schema' column to determine annotation fields, and displays the first "
                "unannotated row. Resumes from where it left off if the working copy already exists. "
                "After calling this, use the `annotate` tool to annotate each row."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "csv_path": {
                        "type": "string",
                        "description": "Path to the CSV file to annotate. Must contain a '_schema' column in the first row."
                    }
                },
                "required": ["csv_path"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="annotate",
            description=(
                "Annotate the current row. Pass each schema field as a key inside the 'annotations' object. "
                "Validates values against the schema, saves to the working CSV, then automatically loads "
                "the next row. When all rows are done, returns 'Annotation complete'. "
                "If validation fails, returns an error describing the expected format — read it and retry."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "annotations": {
                        "type": "object",
                        "description": "Key-value pairs matching the schema fields (e.g. {\"sentiment\": \"positive\", \"confidence\": \"0.9\"})",
                        "additionalProperties": {"type": "string"}
                    }
                },
                "required": ["annotations"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="checkpoint_session",
            description=(
                "Save a snapshot of the R global environment to disk so it can be rolled back "
                "later with restore_session. Use this BEFORE risky operations: overwriting or "
                "removing objects, destructive data transformations, or loading files into "
                "existing names. Checkpoints survive R restarts; only the 10 most recent are kept."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "label": {
                        "type": "string",
                        "description": "Optional short label recorded in the checkpoint filename (e.g. 'before_refit')."
                    }
                }
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="restore_session",
            description=(
                "Roll the R global environment back to a checkpoint created with "
                "checkpoint_session. Restores the most recent checkpoint unless one is named. "
                "The current state is saved as a 'pre_restore' checkpoint first, so the restore "
                "itself is undoable. Objects created after the checkpoint are removed."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "checkpoint": {
                        "type": "string",
                        "description": "Optional checkpoint filename from list_checkpoints. Omit to restore the most recent."
                    }
                }
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": True,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="list_checkpoints",
            description="List saved R session checkpoints (file, time, size MB) for the current session, newest last.",
            inputSchema={
                "type": "object",
                "properties": {}
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="screening_report",
            description=(
                "Summarize systematic-review screening passes produced by run_annotation_job: "
                "decision counts, exclusion reasons, and PRISMA flow numbers. With two passes "
                "from DIFFERENT model families, also computes percent agreement and Cohen's "
                "kappa between the screeners and assigns the conflict set to "
                "'screening_conflicts' in the R session, so the human only adjudicates "
                "disagreements. Run ClaudeR::screening_prompt() first for the full protocol."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "pass_a": {
                        "type": "string",
                        "description": "Path to the first screened CSV (the _annotating.csv output)."
                    },
                    "pass_b": {
                        "type": "string",
                        "description": "Optional second screened CSV from a different model family."
                    },
                    "include_field": {
                        "type": "string",
                        "description": "Decision column name. Default 'include'."
                    },
                    "reason_field": {
                        "type": "string",
                        "description": "Exclusion reason column name. Default 'reason'."
                    }
                },
                "required": ["pass_a"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="set_agent_name",
            description=(
                "Set this agent's working identity for the rest of the session. Call this "
                "FIRST in any multi-agent work, before executing code or sending messages, "
                "so execution history, message attribution, presence, and your read cursor "
                "all carry your working name (e.g. 'Claude-Stasis') instead of a random "
                "per-connection id. Critical when several agents or personas share one MCP "
                "connection (subagents), where the default id cannot tell them apart. Pick "
                "a short name unique to you and reuse it across sessions. For a permanent "
                "name, set the CLAUDER_AGENT_ID environment variable in the MCP server "
                "registration instead. A second rename to a different name is refused "
                "unless force is true, because that pattern usually means personas "
                "sharing one connection, who should pass as_agent per call instead."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "The identity to use: 1-40 chars, letters, digits, dash, underscore; must start with a letter or digit."
                    },
                    "force": {
                        "type": "boolean",
                        "description": "Rename a connection that an earlier set_agent_name call already named. Only use this when you are certain you are the only agent on this connection."
                    }
                },
                "required": ["name"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="send_message",
            description=(
                "Send a typed message to other agents on this session's coordination log. "
                "Prefer typed signals over prose for anything machine-checkable: "
                "type='signal' with body={'name': 'KIT_READY', 'tile': '3094,3493'} beats "
                "hoping the other agent greps your prose. Works even while the R session "
                "is busy (the log is a shared file, not R state), and survives restarts."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "body": {
                        "description": "Message payload: a string, or an object for typed signals.",
                        "anyOf": [{"type": "string"}, {"type": "object"}]
                    },
                    "to": {"type": "string", "description": "Recipient agent id, or 'all' (default)."},
                    "type": {"type": "string", "description": "Event type: message (default), signal, status, handoff, question."},
                    "reply_to": {"type": "number", "description": "Event id this replies to (threading)."},
                    "as_agent": {"type": "string", "description": "Send as this identity, for this call only. Use when several agents or personas share one MCP connection: each passes its own name per call instead of fighting over set_agent_name."}
                },
                "required": ["body"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="check_messages",
            description=(
                "Read unread coordination events addressed to you (or to all), then advance "
                "your read cursor. Each agent has its own cursor; reading never mutates "
                "shared state, so agents cannot clobber each other."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "ack": {"type": "boolean", "description": "Advance the cursor past returned events (default true)."},
                    "as_agent": {"type": "string", "description": "Read as this identity, using its own separate cursor. For personas sharing one MCP connection."}
                }
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="wait_for_message",
            description=(
                "Block until a matching coordination event arrives, or the timeout passes. "
                "Use this instead of repeated polling: it returns the instant another agent "
                "writes, which removes coordination latency, crossed messages, and the need "
                "for a human to schedule polls. Does not touch the R session, so the other "
                "agent can keep executing code while you wait. Filter by sender and/or type "
                "for rendezvous ('wait until beta sends signal HANDOFF_READY')."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "timeout_s": {"type": "number", "description": "Max seconds to wait (default 300, cap 1800)."},
                    "from_agent": {"type": "string", "description": "Only return events from this agent."},
                    "type": {"type": "string", "description": "Only return events of this type."},
                    "as_agent": {"type": "string", "description": "Wait as this identity, using its own cursor. For personas sharing one MCP connection."}
                }
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="coordination_roster",
            description=(
                "List agents seen on this session's coordination log with last-seen times "
                "and staleness. Presence is stamped by every write, so liveness does not "
                "depend on manual heartbeats."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "stale_after_s": {"type": "number", "description": "Seconds after which an agent is flagged stale (default 900)."}
                }
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="check_cross_references",
            description=(
                "Check a manuscript's internal cross-references: inventories declared "
                "tables, figures, theorems/lemmas, appendices, and numbered sections, then "
                "verifies every in-text mention ('see Table 4', 'Figures 2 and 3') against "
                "that inventory. Flags dangling references (mentioned but nonexistent) and "
                "tables/figures never referenced in the text. Classes whose numbering does "
                "not survive Word extraction are reported as unverifiable rather than "
                "false-flagged. Assigns crossref_registry to the R global environment. "
                "Part of Referee Mode; also useful standalone after any manuscript revision."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "document": {
                        "type": "string",
                        "description": "Path to the manuscript (.docx, .pdf, or plain text)."
                    }
                },
                "required": ["document"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="reconcile_values",
            description=(
                "Audit backbone: extract EVERY numeric value from a manuscript (.docx/.pdf/"
                "text; docx tables cell-separated) and reconcile each against the corpus of "
                "numbers in the given source files (analysis logs, generated tables, script "
                "outputs, CSVs). Matching respects displayed precision (5038.5 matches "
                "5038.46; 0.967 matches 0.9668), handles commas, percents (also checked as "
                "proportions), scientific notation, and thresholds like '< .001'. Assigns a "
                "per-value 'values_registry' data.frame to the R global environment; every "
                "'unmatched' row must then be adjudicated (recompute it with execute_r, or "
                "record why it cannot come from the sources) before an audit may conclude. "
                "Completeness by construction: do not rely on reading carefully."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "document": {
                        "type": "string",
                        "description": "Path to the manuscript or supplement (.docx, .pdf, or plain text)."
                    },
                    "sources": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Files whose numbers form the ground-truth corpus: session logs, generated table files, script outputs, CSVs."
                    },
                    "ignore_years": {
                        "type": "boolean",
                        "description": "Skip 4-digit integers 1900-2100 (citation years). Default true."
                    }
                },
                "required": ["document", "sources"]
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="generate_codebook",
            description=(
                "Generate a codebook / reproducibility README for a project: scans scripts "
                "for library() calls, data-read sites, and saved outputs; reads each data "
                "file (.csv/.tsv/.txt/.rds); and writes markdown with a versioned package "
                "list, script inventory, per-variable codebook (name, class, n, missingness, "
                "summary), and outputs produced. This is the codebook OSF and many journals "
                "require alongside shared data."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "project_dir": {
                        "type": "string",
                        "description": "Project root to scan. Default: current working directory."
                    },
                    "data_files": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional explicit data files to document instead of scanning scripts."
                    },
                    "output_path": {
                        "type": "string",
                        "description": "Output markdown path. Default: <project_dir>/CODEBOOK.md"
                    }
                }
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="generate_notebook",
            description=(
                "Transform a ClaudeR session log into a Quarto lab notebook (.qmd): each "
                "executed block becomes a runnable chunk with its timestamp and agent, errored "
                "blocks are preserved as non-evaluated chunks, and rendering re-runs the code "
                "so outputs and plots regenerate. The generated file contains "
                "'<!-- TODO: narration -->' markers: AFTER calling this tool, read the .qmd "
                "and replace every marker with a short explanation of what was tried and why "
                "(use read_file + execute_r with writeLines, or your own file tools). Then "
                "optionally render with quarto to produce the final HTML notebook."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "log_path": {
                        "type": "string",
                        "description": "Path to the session log. Omit to use the current session's log."
                    },
                    "output_path": {
                        "type": "string",
                        "description": "Optional output .qmd path. Default: alongside the log with a _notebook.qmd suffix."
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional notebook title."
                    }
                }
            },
            annotations={
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            }
        ),
        types.Tool(
            name="search_citations",
            description=(
                "Search the OpenAlex scholarly index for works matching a free-text query "
                "(title fragments, topic + author, etc.). Returns candidate citations with "
                "title, authors, year, venue, DOI, and citation count. Use this to find the "
                "correct reference for a claim instead of writing one from memory, then call "
                "get_bibtex with the chosen DOI."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Free-text search query (e.g. 'chain of thought prompting Wei 2022')."
                    },
                    "max_results": {
                        "type": "number",
                        "description": "Maximum candidates to return (default 5)."
                    }
                },
                "required": ["query"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": True,
            }
        ),
        types.Tool(
            name="get_bibtex",
            description=(
                "Fetch the canonical BibTeX entry for a DOI via doi.org content negotiation. "
                "This returns the registered metadata, not a reconstruction — use it to insert "
                "citations after finding the right work with search_citations or verify_references."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "doi": {
                        "type": "string",
                        "description": "The DOI, with or without the https://doi.org/ prefix."
                    }
                },
                "required": ["doi"]
            },
            annotations={
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": True,
            }
        ),
    ]

@server.call_tool()
async def call_tool(name: str, arguments: Dict[str, Any]) -> List[types.TextContent | types.ImageContent]:
    """Handle R tool calls."""
    global _target_session, _agent_introduced, _agent_id

    # These tools check Python-side state only — skip addin check
    _skip_addin_check = {"list_sessions", "connect_session", "load_annotation_data", "annotate", "run_annotation_job", "get_annotation_job_status", "cancel_annotation_job",
                         # File-based coordination must work while R is busy or down
                         "send_message", "check_messages", "wait_for_message", "coordination_roster",
                         # Identity is Python-side state, settable while R is down
                         "set_agent_name"}
    if name not in _skip_addin_check:
        # Check if the R addin is running
        if not await check_addin_status():
            return [types.TextContent(
                type="text",
                text="Error: RStudio addin is not running. Please start the Claude RStudio Connection addin in RStudio."
            )]

    result_contents = []

    # First tool call: prepend agent context so the model knows its identity
    if not _agent_introduced:
        _agent_introduced = True
        try:
            intro = await get_agent_introduction()
            result_contents.append(types.TextContent(type="text", text=intro))
        except Exception:
            pass  # Don't block tool execution if introduction fails

    if name == "execute_r":
        if "code" not in arguments:
            return [types.TextContent(
                type="text",
                text="Error: 'code' parameter is required"
            )]
        
        result = await execute_r_code_via_addin(arguments["code"])

        if not result.get("success", False):
            err_text = f"R Error: {result.get('error', 'Unknown error')}"
            # Include whatever printed before the error — often the context
            # the agent needs to fix the code
            if result.get("output"):
                err_text = f"{result['output']}\n\n{err_text}"
            result_contents.append(types.TextContent(type="text", text=err_text))
            return result_contents

        # Add text output
        if "output" in result and result["output"]:
            result_contents.append(types.TextContent(
                type="text",
                text=result["output"]
            ))
        
        # Add plot if available
        if "plot" in result:
            result_contents.append(types.ImageContent(
                type="image",
                data=result["plot"]["data"],
                mimeType=result["plot"]["mime_type"]
            ))

        # Hint about captured viewer content (htmlwidgets)
        if result.get("viewer_captured"):
            result_contents.append(types.TextContent(
                type="text",
                text="[Interactive HTML widget was rendered. Use get_viewer_content tool to read the HTML.]"
            ))

        return result_contents or [types.TextContent(
            type="text",
            text="Code executed successfully but produced no output."
        )]

    elif name == "execute_r_with_plot":
        if "code" not in arguments:
            return [types.TextContent(
                type="text",
                text="Error: 'code' parameter is required"
            )]

        # First, perform the one-time check for ggplot2.
        if not await check_ggplot_installed():
            return [types.TextContent(
                type="text",
                text="Error: The 'ggplot2' package is required for this tool but is not installed. Please install it in RStudio."
            )]

        # The package is available, so just execute the user's code directly.
        result = await execute_r_code_via_addin(arguments["code"])
        
        # Add text output
        if "output" in result and result["output"]:
            result_contents.append(types.TextContent(
                type="text",
                text=result["output"]
            ))
        
        # Add error if any
        if not result.get("success", False):
            result_contents.append(types.TextContent(
                type="text",
                text=f"R Error: {result.get('error', 'Unknown error')}"
            ))
        
        # Add plot if available
        if "plot" in result:
            result_contents.append(types.ImageContent(
                type="image",
                data=result["plot"]["data"],
                mimeType=result["plot"]["mime_type"]
            ))

        # Hint about captured viewer content (htmlwidgets)
        if result.get("viewer_captured"):
            result_contents.append(types.TextContent(
                type="text",
                text="[Interactive HTML widget was rendered. Use get_viewer_content tool to read the HTML.]"
            ))

        return result_contents or [types.TextContent(
            type="text",
            text="Code executed but no plot was generated. Make sure your code creates a plot."
        )]

    elif name == "get_r_info":
        what = arguments.get("what", "all")

        if what == "packages" or what == "all":
            pkg_code = "cat(sprintf('Installed packages: %d\\nUse requireNamespace(\"pkg\") to check for a specific package.', nrow(installed.packages())))"
            pkg_result = await execute_r_code_via_addin(pkg_code)
            if pkg_result.get("success", False):
                result_contents.append(types.TextContent(
                    type="text",
                    text=f"{pkg_result.get('output', '')}"
                ))

        if what == "variables" or what == "all":
            var_code = "obj <- ls(); cat(sprintf('Global environment: %d objects\\n', length(obj))); if (length(obj) > 0) cat('First 20:', paste(head(obj, 20), collapse=', ')); if (length(obj) > 20) cat(sprintf('\\n... and %d more. Use exists(\"name\") to check for specific objects.', length(obj) - 20))"
            var_result = await execute_r_code_via_addin(var_code)
            if var_result.get("success", False):
                result_contents.append(types.TextContent(
                    type="text",
                    text=f"{var_result.get('output', '')}"
                ))

        if what == "version" or what == "all":
            ver_code = "R.version.string"
            ver_result = await execute_r_code_via_addin(ver_code)
            if ver_result.get("success", False):
                result_contents.append(types.TextContent(
                    type="text",
                    text=f"R version:\n{ver_result.get('output', '')}"
                ))
        
        return result_contents or [types.TextContent(
            type="text",
            text=f"Unknown info type: {what}"
        )]
    
    elif name == "get_active_document":
        target = escape_r_string(arguments.get("path", "") or "")
        result = await execute_r_code_via_addin(f"""
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
            want <- "{target}"
            ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
            if (is.null(ctx) || is.null(ctx$id) || !nzchar(ctx$id)) {{
                list(error = paste("No source document is open or focused in RStudio.",
                                   "Open the target file in the Source pane first, then retry."))
            }} else {{
                p <- ctx$path; if (is.null(p)) p <- ""
                if (nzchar(want)) {{
                    a <- normalizePath(want, mustWork = FALSE)
                    b <- if (nzchar(p)) normalizePath(p, mustWork = FALSE) else ""
                    if (!identical(a, b)) {{
                        tryCatch({{ rstudioapi::documentOpen(want); Sys.sleep(0.3)
                                   ctx <- rstudioapi::getSourceEditorContext()
                                   p <- ctx$path; if (is.null(p)) p <- "" }},
                                 error = function(e) NULL)
                    }}
                }}
                buf <- paste(ctx$contents, collapse = "\n")
                disk <- if (nzchar(p) && file.exists(p)) paste(readLines(p, warn = FALSE), collapse = "\n") else NA_character_
                dirty <- if (is.na(disk)) NA else !identical(sub("\n+$", "", buf), sub("\n+$", "", disk))
                list(
                    content = buf,
                    path = if (nzchar(p)) p else "(unsaved / untitled buffer)",
                    document_id = ctx$id,
                    line_count = length(ctx$contents),
                    unsaved_changes = dirty,
                    source_of_truth = if (isTRUE(dirty))
                        "EDITOR BUFFER differs from the file on disk (unsaved edits). read_file would return the OLDER disk version."
                      else if (isFALSE(dirty)) "Buffer matches the file on disk."
                      else "Buffer has never been saved to disk."
                )
            }}
        }} else {{
            list(error = "RStudio API not available")
        }}
        """)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error retrieving active document: {result.get('error', 'Unknown error')}"
            )]

        return [types.TextContent(
            type="text",
            text=result.get("output", "No document content retrieved")
        )]

    elif name == "suggest_edit":
        if not all(k in arguments for k in ["search_pattern", "replacement"]):
            return [types.TextContent(
                type="text",
                text="Error: Both 'search_pattern' and 'replacement' parameters are required"
            )]
        search_pattern = escape_r_string(arguments["search_pattern"])
        replacement = escape_r_string(arguments["replacement"].replace("\\", "\\\\"))
        target = escape_r_string(arguments.get("path", "") or "")

        suggest_code = f"""
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
            want <- "{target}"
            ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
            if (is.null(ctx) || is.null(ctx$id) || !nzchar(ctx$id)) {{
                list(success = FALSE,
                     error = "No source document is open or focused in RStudio. Open the target file first.")
            }} else {{
                p <- ctx$path; if (is.null(p)) p <- ""
                if (nzchar(want)) {{
                    a <- normalizePath(want, mustWork = FALSE)
                    b <- if (nzchar(p)) normalizePath(p, mustWork = FALSE) else ""
                    if (!identical(a, b)) {{
                        tryCatch({{ rstudioapi::documentOpen(want); Sys.sleep(0.3)
                                   ctx <- rstudioapi::getSourceEditorContext()
                                   p <- ctx$path; if (is.null(p)) p <- "" }},
                                 error = function(e) NULL)
                    }}
                }}
                content <- ctx$contents
                full_text <- paste(content, collapse = "\n")
                proposed <- gsub("{search_pattern}", "{replacement}", full_text, perl = TRUE)
                if (identical(proposed, full_text)) {{
                    list(success = FALSE, error = "Pattern not found; nothing to suggest.")
                }} else {{
                    has_api <- exists("showEditSuggestion",
                                      where = asNamespace("rstudioapi"), inherits = FALSE)
                    if (has_api) {{
                        fn <- get("showEditSuggestion", envir = asNamespace("rstudioapi"))
                        rng <- rstudioapi::document_range(
                            rstudioapi::document_position(1, 1),
                            rstudioapi::document_position(length(content) + 1, 1))
                        ok <- tryCatch(isTRUE(fn(rng, proposed, id = ctx$id)) ||
                                       is.null(fn(rng, proposed, id = ctx$id)),
                                       error = function(e) FALSE)
                        if (ok) {{
                            list(success = TRUE, mode = "showEditSuggestion",
                                 path = if (nzchar(p)) p else "(untitled buffer)",
                                 message = "Edit suggestion shown in RStudio. WAIT for the user to accept or reject it before continuing.")
                        }} else {{
                            list(success = FALSE, error = "showEditSuggestion() exists but failed.")
                        }}
                    }} else {{
                        # Fallback: stage the change in the buffer WITHOUT saving, so the
                        # user reviews it in the editor and accepts (save) or rejects (undo).
                        rstudioapi::setDocumentContents(proposed, id = ctx$id)
                        old_n <- length(content)
                        new_n <- length(strsplit(proposed, "\n", fixed = TRUE)[[1]])
                        list(success = TRUE, mode = "staged-unsaved",
                             path = if (nzchar(p)) p else "(untitled buffer)",
                             lines = paste0(old_n, " -> ", new_n),
                             message = paste("rstudioapi::showEditSuggestion() is not available in this RStudio/rstudioapi build,",
                                             "so the change was STAGED IN THE EDITOR BUFFER and deliberately NOT saved.",
                                             "The user reviews it in RStudio and accepts by saving (Cmd/Ctrl-S) or rejects with Undo (Cmd/Ctrl-Z).",
                                             "Do NOT save it yourself and do NOT continue until the user confirms."))
                    }}
                }}
            }}
        }} else {{
            list(success = FALSE, error = "RStudio API not available")
        }}
        """

        result = await execute_r_code_via_addin(suggest_code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error suggesting edit: {result.get('error', 'Unknown error')}"
            )]
        return [types.TextContent(
            type="text",
            text=result.get("output", "Edit suggestion submitted")
        )]

    elif name == "create_task_list":
        if "tasks" not in arguments:
            return [types.TextContent(
                type="text",
                text="Error: 'tasks' parameter is required"
            )]
        
        # Format the task list as R comments
        task_list_code = """
    # ===== TASK LIST CREATED =====
    # Generated: {}
    # 
    """.format(datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        
        for i, task in enumerate(arguments["tasks"], 1):
            task_list_code += f"# Task {task['id']}: {task['description']} [{task['status'].upper()}]\n"
        
        task_list_code += "# ===========================\n"
        
        # Execute to print in console and log
        result = await execute_r_code_via_addin(f'cat("{escape_r_string(task_list_code)}")')
        
        # Convert tasks to R list format with proper escaping
        r_tasks = "list(\n"
        for i, task in enumerate(arguments["tasks"]):
            if i > 0:
                r_tasks += ",\n"
            r_tasks += f"""  list(
        id = "{escape_r_string(task['id'])}",
        description = "{escape_r_string(task['description'])}",
        status = "{escape_r_string(task['status'])}"
    )"""
        r_tasks += "\n)"
        
        # Store task list in R environment for tracking
        store_code = f"""
    .claude_task_list <- list(
    created = Sys.time(),
    tasks = {r_tasks}
    )
    """
        await execute_r_code_via_addin(store_code)
        
        return [types.TextContent(
            type="text",
            text=f"Task list created with {len(arguments['tasks'])} tasks"
        )]

    elif name == "update_task_status":
        task_id = escape_r_string(arguments.get("task_id", ""))
        status = escape_r_string(arguments.get("status", ""))
        notes = escape_r_string(arguments.get("notes", ""))
        
        # Update the task in R environment and print update
        update_code = f"""
    if (exists(".claude_task_list")) {{
        # Update task status
        for (i in seq_along(.claude_task_list$tasks)) {{
            if (.claude_task_list$tasks[[i]]$id == "{task_id}") {{
                .claude_task_list$tasks[[i]]$status <- "{status}"
                
                # Print update to console
                update_msg <- paste0(
                    "\\n# ===== TASK UPDATE =====\\n",
                    "# Time: ", format(Sys.time(), "%H:%M:%S"), "\\n",
                    "# Task {task_id}: ", .claude_task_list$tasks[[i]]$description, "\\n",
                    "# Status: {status.upper()}\\n"
                )
                
                if ("{notes}" != "") {{
                    update_msg <- paste0(update_msg, "# Notes: {notes}\\n")
                }}
                
                update_msg <- paste0(update_msg, "# ======================\\n")
                cat(update_msg)
                
                break
            }}
        }}
        
        # Return current task summary
        completed <- sum(sapply(.claude_task_list$tasks, function(t) t$status == "completed"))
        total <- length(.claude_task_list$tasks)
        paste0("Progress: ", completed, "/", total, " tasks completed")
    }} else {{
        "No task list found"
    }}
    """
        
        result = await execute_r_code_via_addin(update_code)
        
        return [types.TextContent(
            type="text",
            text=result.get("output", "Task updated")
        )]
    

    elif name == "clean_error_log":
        log_path = arguments.get("log_path", "")
        output_path = arguments.get("output_path")
        if not log_path:
            return [types.TextContent(type="text", text="Error: 'log_path' parameter is required")]
        escaped_log = log_path.replace("\\", "\\\\").replace('"', '\\"')
        code = f'ClaudeR::clean_clauder_log("{escaped_log}"'
        if output_path:
            escaped_out = output_path.replace("\\", "\\\\").replace('"', '\\"')
            code += f', output_path = "{escaped_out}"'
        code += ")"
        result = await execute_r_code_via_addin(code)
        if result.get("success", False):
            output = result.get("output", "Log cleaned successfully.")
            return [types.TextContent(type="text", text=output)]
        else:
            return [types.TextContent(type="text", text=f"Error: {result.get('error', 'Unknown error')}")]

    elif name == "search_project_code":
        pattern = arguments.get("pattern", "")
        if not pattern:
            return [types.TextContent(type="text", text="Error: 'pattern' parameter is required")]
        extensions = arguments.get("file_extensions", "R,Rmd,qmd")
        root_dir = arguments.get("root_dir", ".")
        max_results = int(arguments.get("max_results", 50))
        ignore_case = arguments.get("ignore_case", False)
        escaped_pattern = escape_r_string(pattern)
        escaped_root = escape_r_string(root_dir)
        escaped_extensions = escape_r_string(extensions)
        code = f'ClaudeR:::search_project_code_impl("{escaped_pattern}", extensions = "{escaped_extensions}", root_dir = "{escaped_root}", max_results = {max_results}L, ignore_case = {"TRUE" if ignore_case else "FALSE"})'
        result = await execute_r_code_via_addin(code)
        if result.get("success", False):
            output = result.get("output", "No results.")
            return [types.TextContent(type="text", text=output)]
        else:
            return [types.TextContent(type="text", text=f"Error: {result.get('error', 'Unknown error')}")]

    elif name == "probe_scripts":
        script_paths = arguments.get("script_paths", [])
        if not script_paths:
            return [types.TextContent(type="text", text="Error: 'script_paths' parameter is required")]
        timeout = int(arguments.get("timeout", 60))
        import json
        paths_json = json.dumps(script_paths)
        escaped_json = escape_r_string(paths_json)
        capture = "TRUE" if arguments.get("capture_output") else "FALSE"
        code = f'ClaudeR:::probe_scripts_impl(jsonlite::fromJSON(\'{escaped_json}\'), timeout = {timeout}, capture_output = {capture})'
        result = await execute_r_code_via_addin(code)
        if result.get("success", False):
            output = result.get("output", "No results.")
            return [types.TextContent(type="text", text=output)]
        else:
            return [types.TextContent(type="text", text=f"Error: {result.get('error', 'Unknown error')}")]

    elif name == "verify_references":
        file_path = arguments.get("file", "")
        text_input = arguments.get("text", "")
        start_line = arguments.get("start_line")
        end_line = arguments.get("end_line")

        if not file_path and not text_input:
            return [types.TextContent(type="text", text="Error: Either 'file' or 'text' parameter is required")]

        # Build the R call
        parts = []
        if file_path:
            escaped_path = escape_r_string(file_path)
            parts.append(f"file_path = '{escaped_path}'")
        if text_input:
            escaped_text = escape_r_string(text_input)
            parts.append(f"text = '{escaped_text}'")
        if start_line is not None:
            parts.append(f"start_line = {int(start_line)}")
        if end_line is not None:
            parts.append(f"end_line = {int(end_line)}")

        code = f"ClaudeR:::verify_references_impl({', '.join(parts)})"
        result = await execute_r_code_via_addin(code)
        if result.get("success", False):
            output = result.get("output", "No results.")
            return [types.TextContent(type="text", text=output)]
        else:
            return [types.TextContent(type="text", text=f"Error: {result.get('error', 'Unknown error')}")]

    elif name == "execute_r_async":
        if "code" not in arguments:
            return [types.TextContent(
                type="text",
                text="Error: 'code' parameter is required"
            )]

        code = arguments["code"]
        inputs = arguments.get("inputs") or []
        outputs = arguments.get("outputs") or []
        if not isinstance(inputs, list) or not isinstance(outputs, list):
            return [types.TextContent(
                type="text",
                text="Error: 'inputs' and 'outputs' must be arrays of object names if provided."
            )]
        job_id = uuid.uuid4().hex[:8]

        # Send to R — R launches callr::r_bg() and returns immediately
        payload = {
            "code": code,
            "async": True,
            "job_id": job_id,
            "input_names": inputs,
            "output_names": outputs,
        }
        if _agent_id:
            payload["agent_id"] = _agent_id

        # Generous timeout: submission synchronously saveRDS()es the marshaled
        # inputs in the main session, which can be slow for large objects. A
        # premature timeout would make the agent resubmit a job that started.
        result = await post_to_r_addin(payload, timeout=120.0)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error starting async job: {result.get('error', 'Unknown error')}"
            )]

        marshaling_note = ""
        if inputs:
            marshaling_note += f" Inputs marshaled from main session: {', '.join(inputs)}."
        if outputs:
            marshaling_note += f" Outputs ({', '.join(outputs)}) will auto-load into the main session when the job completes."

        return [types.TextContent(
            type="text",
            text=(
                f"Job {job_id} started in a background R process.{marshaling_note} "
                f"The main R session remains available — you can continue running other code with execute_r while this job runs. "
                f"Use get_async_result(\"{job_id}\") to check status when ready."
            )
        )]

    elif name == "get_async_result":
        job_id = arguments.get("job_id", "")

        # Throttle polling — wait before checking
        await asyncio.sleep(10)

        # Ask R for the job status. Collection loads outputs back into the
        # main session (readRDS + assign), which can be slow for big results.
        result = await post_to_r_addin({"check_job": job_id}, timeout=120.0)

        status = result.get("status", "unknown")

        if status == "not_found":
            return [types.TextContent(
                type="text",
                text=f"No job found with ID '{job_id}'. It may have already completed or the ID is incorrect."
            )]

        if status == "running":
            elapsed = result.get("elapsed_seconds", "?")
            return [types.TextContent(
                type="text",
                text=f"Job {job_id} is still running ({elapsed}s elapsed). Call get_async_result(\"{job_id}\") again to check."
            )]

        # Job is complete
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Async job error: {result.get('error', 'Unknown error')}"
            )]

        result_contents = []
        if "output" in result and result["output"]:
            result_contents.append(types.TextContent(
                type="text",
                text=result["output"]
            ))

        marshaled = result.get("marshaled_outputs")
        if marshaled:
            if isinstance(marshaled, str):
                marshaled = [marshaled]
            result_contents.append(types.TextContent(
                type="text",
                text="--- Outputs loaded into main session ---\n" + "\n".join(marshaled)
            ))

        return result_contents or [types.TextContent(
            type="text",
            text="Async job completed successfully but produced no output."
        )]

    elif name == "cancel_async_job":
        job_id = arguments.get("job_id", "")
        if not job_id:
            return [types.TextContent(type="text", text="Error: 'job_id' parameter is required")]

        result = await post_to_r_addin({"cancel_job": job_id})
        status = result.get("status", "unknown")

        if status == "not_found":
            return [types.TextContent(
                type="text",
                text=f"No job found with ID '{job_id}'. It may have already completed, been cancelled, or the ID is wrong."
            )]

        if status == "cancelled":
            elapsed = result.get("elapsed_seconds", "?")
            was_alive = result.get("was_alive", False)
            if was_alive:
                msg = f"Cancelled job {job_id} after {elapsed}s. Background process killed and tempfiles cleaned up."
            else:
                msg = f"Job {job_id} had already finished but had not been collected (it ran for {elapsed}s). Cleaned up tempfiles and removed it."
            return [types.TextContent(type="text", text=msg)]

        return [types.TextContent(
            type="text",
            text=f"Cancel returned unexpected status '{status}': {result}"
        )]

    elif name == "list_sessions":
        sessions = discover_sessions()
        if not sessions:
            return [types.TextContent(
                type="text",
                text="No active R sessions found. Start the ClaudeR addin in RStudio first."
            )]

        lines = []
        for s in sessions:
            target_marker = " (connected)" if _target_session == s.get("session_name") else ""
            lines.append(
                f"  {s.get('session_name', '?')} — port {s.get('port', '?')}, "
                f"pid {s.get('pid', '?')}, started {s.get('started_at', '?')}{target_marker}"
            )

        header = f"Active R sessions ({len(sessions)}):"
        current = f"Current agent: {_agent_id}"
        target = f"Connected to: {_target_session or 'auto (first available)'}"
        return [types.TextContent(
            type="text",
            text=f"{header}\n" + "\n".join(lines) + f"\n\n{current}\n{target}"
        )]

    elif name == "connect_session":
        session_name = arguments.get("session_name", "")
        if not session_name:
            return [types.TextContent(
                type="text",
                text="Error: 'session_name' is required"
            )]

        sessions = discover_sessions()
        found = any(s.get("session_name") == session_name for s in sessions)

        if not found:
            available = [s.get("session_name", "?") for s in sessions]
            return [types.TextContent(
                type="text",
                text=f"Session '{session_name}' not found. Available: {available or 'none'}"
            )]

        _target_session = session_name

        connect_msg = f"Connected to session '{session_name}'. All subsequent tool calls will be routed there."
        contents = [types.TextContent(type="text", text=connect_msg)]

        # Deliver agent introduction right after connecting
        if not _agent_introduced:
            _agent_introduced = True
            try:
                intro = await get_agent_introduction()
                contents.append(types.TextContent(type="text", text=intro))
            except Exception:
                pass

        return contents

    elif name == "get_session_history":
        agent_filter = arguments.get("agent_filter", "all")
        last_n = int(arguments.get("last_n", 20))

        # Translate "self" to this agent's actual ID
        if agent_filter == "self":
            filter_value = escape_r_string(_agent_id or "unknown")
        elif agent_filter == "all":
            filter_value = "all"
        else:
            filter_value = escape_r_string(agent_filter)

        include_past = "TRUE" if arguments.get("include_past") else "FALSE"
        r_code = f'ClaudeR:::query_agent_history("{filter_value}", "{escape_r_string(_agent_id or "unknown")}", {last_n}, include_past = {include_past})'
        result = await execute_r_code_via_addin(r_code)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error querying history: {result.get('error', 'Unknown error')}"
            )]

        return [types.TextContent(
            type="text",
            text=result.get("output", "No history available")
        )]

    elif name == "read_file":
        if "file_path" not in arguments:
            return [types.TextContent(type="text", text="Error: 'file_path' parameter is required")]

        file_path = escape_r_string(arguments["file_path"])
        start_line = arguments.get("start_line")
        end_line = arguments.get("end_line")
        start_r = str(int(start_line)) if start_line else "NULL"
        end_r = str(int(end_line)) if end_line else "NULL"
        read_code = f'''
        tryCatch({{
            fpath <- path.expand("{file_path}")
            if (!file.exists(fpath)) {{
                list(success = FALSE, error = paste0("File not found: ", fpath))
            }} else {{
                ext <- tolower(tools::file_ext(fpath))
                lines <- if (ext %in% c("docx", "pdf")) {{
                    ClaudeR::extract_manuscript_text(fpath)
                }} else {{
                    readLines(fpath, warn = FALSE)
                }}
                total <- length(lines)
                if (total == 0L) {{
                    list(success = TRUE, output = "[File exists but is empty (0 lines)]")
                }} else {{
                    sl <- {start_r}
                    el <- {end_r}
                    if (is.null(sl)) sl <- 1L
                    if (is.null(el)) el <- total
                    sl <- max(1L, min(sl, total))
                    el <- max(sl, min(el, total))
                    subset_lines <- lines[sl:el]
                    numbered <- paste0("[L", sprintf("%04d", sl:el), "] ", subset_lines)
                    hint <- sprintf("\\n[Lines %d-%d of %d total]", sl, el, total)
                    list(success = TRUE, output = paste0(paste(numbered, collapse = "\\n"), hint))
                }}
            }}
        }}, error = function(e) {{
            list(success = FALSE, error = e$message)
        }})
        '''
        result = await execute_r_code_via_addin(read_code)

        if not result.get("success", False):
            error_msg = result.get("error", "Unknown error")
            result_contents.append(types.TextContent(type="text", text=f"Error reading file: {error_msg}"))
            return result_contents

        result_contents.append(types.TextContent(
            type="text",
            text=result.get("output", "File is empty")
        ))
        return result_contents

    elif name == "get_viewer_content":
        max_length = int(arguments.get("max_length", 10000))
        offset = int(arguments.get("offset", 0))

        result = await post_to_r_addin({
            "get_viewer": True,
            "max_length": max_length,
            "offset": offset
        })

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error: {result.get('error', 'No viewer content available')}"
            )]

        total = result.get("total_chars", 0)
        returned = result.get("returned_chars", 0)
        content = result.get("content", "")

        result_contents.append(types.TextContent(
            type="text",
            text=f"HTML content ({offset}-{offset + returned} of {total} chars):\n\n{content}"
        ))
        return result_contents

    elif name == "modify_code_section":
        if not all(k in arguments for k in ["search_pattern", "replacement"]):
            return [types.TextContent(
                type="text",
                text="Error: Both 'search_pattern' and 'replacement' parameters are required"
            )]

        # search_pattern is a regex by design: escape for the R string
        # literal only, so the user's regex reaches gsub() intact.
        search_pattern = escape_r_string(arguments["search_pattern"])
        # replacement is literal text, but gsub() treats backslash as a
        # metacharacter (backrefs \\1..\\9). Escape once for gsub semantics,
        # then once more for the R string literal.
        replacement = escape_r_string(arguments["replacement"].replace("\\", "\\\\"))

        line_start = arguments.get("line_start", "NULL")
        line_end = arguments.get("line_end", "NULL")
        target = escape_r_string(arguments.get("path", "") or "")
        do_save = "TRUE" if arguments.get("save", True) else "FALSE"

        modify_code = f"""
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
            want <- "{target}"
            do_save <- {do_save}
            ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
            if (is.null(ctx) || is.null(ctx$id) || !nzchar(ctx$id)) {{
                list(success = FALSE,
                     error = paste("No source document is open or focused in RStudio.",
                                   "Open the target file in the Source pane (or pass 'path'), then retry."))
            }} else {{
                p <- ctx$path; if (is.null(p)) p <- ""
                if (nzchar(want)) {{
                    a <- normalizePath(want, mustWork = FALSE)
                    b <- if (nzchar(p)) normalizePath(p, mustWork = FALSE) else ""
                    if (!identical(a, b)) {{
                        tryCatch({{ rstudioapi::documentOpen(want); Sys.sleep(0.3)
                                   ctx <- rstudioapi::getSourceEditorContext()
                                   p <- ctx$path; if (is.null(p)) p <- "" }},
                                 error = function(e) NULL)
                    }}
                }}
                b2 <- if (nzchar(p)) normalizePath(p, mustWork = FALSE) else ""
                if (nzchar(want) && !identical(normalizePath(want, mustWork = FALSE), b2)) {{
                    list(success = FALSE,
                         error = paste0("Refusing to edit: you targeted '", want,
                                        "' but the focused document is '",
                                        if (nzchar(p)) p else "(untitled)",
                                        "'. Open the target file and retry."))
                }} else {{
                    content <- ctx$contents
                    ls_ <- {line_start}; le_ <- {line_end}
                    sp <- "{search_pattern}"; rp <- "{replacement}"
                    res <- NULL
                    if (!is.null(ls_) && !is.null(le_)) {{
                        if (ls_ > 0 && le_ <= length(content) && ls_ <= le_) {{
                            sub_txt <- paste(content[ls_:le_], collapse = "\n")
                            mod <- gsub(sp, rp, sub_txt, perl = TRUE)
                            if (identical(mod, sub_txt)) {{
                                res <- list(success = FALSE,
                                            error = paste0("Pattern not found within lines ", ls_, "-", le_))
                            }} else {{
                                # line count may change: splice, do not require equality
                                new_lines <- strsplit(mod, "\n", fixed = TRUE)[[1]]
                                before <- if (ls_ > 1) content[1:(ls_ - 1)] else character(0)
                                after <- if (le_ < length(content)) content[(le_ + 1):length(content)] else character(0)
                                new_content <- c(before, new_lines, after)
                                rstudioapi::setDocumentContents(paste(new_content, collapse = "\n"), id = ctx$id)
                                res <- list(success = TRUE,
                                            message = paste0("Modified lines ", ls_, "-", le_,
                                                             " (", length(content), " -> ", length(new_content), " lines)"))
                            }}
                        }} else {{
                            res <- list(success = FALSE,
                                        error = paste0("Invalid line range: ", ls_, "-", le_,
                                                       ". Document has ", length(content), " lines."))
                        }}
                    }} else {{
                        full_text <- paste(content, collapse = "\n")
                        mod <- gsub(sp, rp, full_text, perl = TRUE)
                        if (identical(mod, full_text)) {{
                            res <- list(success = FALSE, error = "Pattern not found in document")
                        }} else {{
                            rstudioapi::setDocumentContents(mod, id = ctx$id)
                            res <- list(success = TRUE, message = "Modified code in the document")
                        }}
                    }}
                    if (isTRUE(res$success)) {{
                        saved <- FALSE
                        if (do_save && nzchar(p)) {{
                            saved <- tryCatch({{ rstudioapi::documentSave(id = ctx$id); TRUE }},
                                              error = function(e) FALSE)
                        }}
                        res$path <- if (nzchar(p)) p else "(untitled buffer)"
                        res$saved_to_disk <- saved
                        res$note <- if (saved) "Edit applied and file SAVED to disk; read_file now reflects it."
                                    else "Edit applied to the EDITOR BUFFER ONLY. The file on disk is unchanged, so read_file will still show the old content until it is saved."
                    }}
                    res
                }}
            }}
        }} else {{
            list(success = FALSE, error = "RStudio API not available")
        }}
        """

        result = await execute_r_code_via_addin(modify_code)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error modifying code: {result.get('error', 'Unknown error')}"
            )]

        return [types.TextContent(
            type="text",
            text=result.get("output", "No result returned from code modification")
        )]

    elif name == "insert_text":
        if "text" not in arguments:
            return [types.TextContent(type="text", text="Error: 'text' parameter is required")]

        text = escape_r_string(arguments["text"])
        line = arguments.get("line")
        column = arguments.get("column")
        target = escape_r_string(arguments.get("path", "") or "")
        do_save = "TRUE" if arguments.get("save", True) else "FALSE"
        if line is not None:
            col = int(column) if column is not None else 1
            loc = f"rstudioapi::document_position({int(line)}, {col})"
            where = f'paste0("line ", {int(line)}, ", column ", {col})'
        else:
            loc = "NULL"
            where = '"the cursor position"'

        insert_code = f"""
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
            want <- "{target}"
            do_save <- {do_save}
            ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
            if (is.null(ctx) || is.null(ctx$id) || !nzchar(ctx$id)) {{
                list(success = FALSE,
                     error = paste("No source document is open or focused in RStudio.",
                                   "Open the target file in the Source pane (or pass 'path'), then retry."))
            }} else {{
                p <- ctx$path; if (is.null(p)) p <- ""
                if (nzchar(want)) {{
                    a <- normalizePath(want, mustWork = FALSE)
                    b <- if (nzchar(p)) normalizePath(p, mustWork = FALSE) else ""
                    if (!identical(a, b)) {{
                        tryCatch({{ rstudioapi::documentOpen(want); Sys.sleep(0.3)
                                   ctx <- rstudioapi::getSourceEditorContext()
                                   p <- ctx$path; if (is.null(p)) p <- "" }},
                                 error = function(e) NULL)
                    }}
                }}
                b2 <- if (nzchar(p)) normalizePath(p, mustWork = FALSE) else ""
                if (nzchar(want) && !identical(normalizePath(want, mustWork = FALSE), b2)) {{
                    list(success = FALSE,
                         error = paste0("Refusing to insert: you targeted '", want,
                                        "' but the focused document is '",
                                        if (nzchar(p)) p else "(untitled)", "'."))
                }} else {{
                    loc <- {loc}
                    if (is.null(loc)) rstudioapi::insertText(text = "{text}", id = ctx$id)
                    else rstudioapi::insertText(location = loc, text = "{text}", id = ctx$id)
                    saved <- FALSE
                    if (do_save && nzchar(p)) {{
                        saved <- tryCatch({{ rstudioapi::documentSave(id = ctx$id); TRUE }},
                                          error = function(e) FALSE)
                    }}
                    list(success = TRUE,
                         message = paste0("Inserted text at ", {where}),
                         path = if (nzchar(p)) p else "(untitled buffer)",
                         saved_to_disk = saved,
                         note = if (saved) "Insert applied and file SAVED to disk."
                                else "Insert applied to the EDITOR BUFFER ONLY; the file on disk is unchanged until saved.")
                }}
            }}
        }} else {{
            list(success = FALSE, error = "RStudio API not available")
        }}
        """

        result = await execute_r_code_via_addin(insert_code)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error inserting text: {result.get('error', 'Unknown error')}"
            )]

        return [types.TextContent(
            type="text",
            text=result.get("output", "Text inserted")
        )]

    elif name == "cancel_annotation_job":
        job_id = arguments.get("job_id", "").strip()
        if not job_id:
            return [types.TextContent(type="text", text="Error: 'job_id' is required.")]
        if job_id not in _annot_jobs:
            return [types.TextContent(type="text", text=f"No job found with ID: {job_id}")]
        job = _annot_jobs[job_id]
        if job["status"] == "complete":
            return [types.TextContent(type="text", text=f"Job {job_id} already completed ({job['done']}/{job['total']} rows).")]
        job["cancelled"] = True
        return [types.TextContent(type="text", text=(
            f"Cancellation requested for job {job_id}. "
            f"Will stop after the current row finishes. "
            f"{job['done']}/{job['total']} rows saved so far. "
            f"Resume anytime with run_annotation_job using the same csv_path."
        ))]

    elif name == "run_annotation_job":
        import csv as csv_module

        csv_path = arguments.get("csv_path", "").strip()
        tool = arguments.get("tool", "claude").strip().lower()
        model = arguments.get("model") or None
        timeout = int(arguments.get("timeout", 60))
        reasoning_effort = arguments.get("reasoning_effort", "high")
        ollama_base_url = (arguments.get("ollama_base_url") or "http://localhost:11434").rstrip("/")

        if not csv_path:
            return [types.TextContent(type="text", text="Error: 'csv_path' is required.")]
        if not os.path.exists(csv_path):
            return [types.TextContent(type="text", text=f"Error: File not found: {csv_path}")]
        if tool not in ("claude", "codex", "gemini", "agy", "qwen", "ollama"):
            return [types.TextContent(type="text", text="Error: 'tool' must be 'claude', 'codex', 'gemini', 'agy', 'qwen', or 'ollama'.")]

        if tool == "ollama":
            # No CLI binary; verify the Ollama server is reachable instead.
            try:
                with httpx.Client(timeout=5) as _hc:
                    _hc.get(f"{ollama_base_url}/api/version").raise_for_status()
            except Exception as _e:
                return [types.TextContent(type="text", text=(
                    f"Error: Ollama not reachable at {ollama_base_url} ({_e}). "
                    f"Start it with `ollama serve`, or pass a different `ollama_base_url`."
                ))]
            tool_path = ollama_base_url  # placeholder; ollama branch ignores it
        else:
            tool_path = _find_cli_path(tool)
            if not tool_path:
                return [types.TextContent(type="text", text=(
                    f"Error: '{tool}' CLI not found on PATH. "
                    f"Install it or make sure it's accessible from this environment."
                ))]

        # Working copy
        base, ext = os.path.splitext(csv_path)
        work_path = f"{base}_annotating{ext}"
        if not os.path.exists(work_path):
            shutil.copy2(csv_path, work_path)

        try:
            with open(work_path, newline="", encoding="utf-8") as f:
                reader = csv_module.DictReader(f)
                rows = list(reader)
                fieldnames = list(reader.fieldnames or [])
        except Exception as e:
            return [types.TextContent(type="text", text=f"Error reading CSV: {e}")]

        if not rows:
            return [types.TextContent(type="text", text="Error: CSV has no data rows.")]
        if "_schema" not in rows[0]:
            return [types.TextContent(type="text", text="Error: CSV must have a '_schema' column.")]

        schema_str = rows[0].get("_schema", "").strip()
        if not schema_str:
            return [types.TextContent(type="text", text="Error: '_schema' column is empty.")]

        try:
            schema = _parse_annotation_schema(schema_str)
        except ValueError as e:
            return [types.TextContent(type="text", text=f"Error parsing schema: {e}")]

        annot_fields = list(schema.keys())
        unannotated = [
            i for i, r in enumerate(rows)
            if all(str(r.get(f, "")).strip() == "" for f in annot_fields)
        ]

        if not unannotated:
            return [types.TextContent(type="text", text=f"All {len(rows)} rows already annotated.")]

        job_id = f"annot-{uuid.uuid4().hex[:8]}"
        _annot_jobs[job_id] = {
            "status": "starting",
            "total": len(unannotated),
            "done": 0,
            "errors": [],
            "work_path": work_path,
            "tool": tool,
            "cancelled": False,
        }

        t = threading.Thread(
            target=_annotation_job_worker,
            args=(job_id, rows, fieldnames, unannotated, schema, work_path, tool, tool_path, model, timeout, reasoning_effort, ollama_base_url),
            daemon=True
        )
        t.start()

        return [types.TextContent(type="text", text=(
            f"Annotation job started.\n"
            f"Job ID: {job_id}\n"
            f"Tool: {tool} ({tool_path})\n"
            f"Rows to annotate: {len(unannotated)} of {len(rows)}\n"
            f"Working file: {work_path}\n\n"
            f"Use get_annotation_job_status(job_id='{job_id}') to check progress."
        ))]

    elif name == "get_annotation_job_status":
        job_id = arguments.get("job_id", "").strip()
        if not job_id:
            return [types.TextContent(type="text", text="Error: 'job_id' is required.")]
        if job_id not in _annot_jobs:
            return [types.TextContent(type="text", text=f"No job found with ID: {job_id}")]

        job = _annot_jobs[job_id]
        done = job["done"]
        total = job["total"]
        pct = round(100 * done / total) if total else 0
        errors = job["errors"]

        lines = [
            f"Job: {job_id}",
            f"Status: {job['status']}",
            f"Progress: {done}/{total} rows ({pct}%)",
            f"Tool: {job['tool']}",
            f"Output: {job['work_path']}",
        ]
        if errors:
            lines.append(f"Errors ({len(errors)}):")
            for e in errors[-5:]:  # show last 5
                lines.append(f"  row {e['row_id']}: {e['error']}")
            if len(errors) > 5:
                lines.append(f"  ... and {len(errors) - 5} more")

        return [types.TextContent(type="text", text="\n".join(lines))]

    elif name == "load_annotation_data":
        import csv as csv_module

        csv_path = arguments.get("csv_path", "").strip()
        if not csv_path:
            return [types.TextContent(type="text", text="Error: 'csv_path' is required.")]
        if not os.path.exists(csv_path):
            return [types.TextContent(type="text", text=f"Error: File not found: {csv_path}")]

        # Working copy — original is never touched
        base, ext = os.path.splitext(csv_path)
        work_path = f"{base}_annotating{ext}"
        if not os.path.exists(work_path):
            shutil.copy2(csv_path, work_path)

        try:
            with open(work_path, newline="", encoding="utf-8") as f:
                reader = csv_module.DictReader(f)
                rows = list(reader)
                fieldnames = list(reader.fieldnames or [])
        except Exception as e:
            return [types.TextContent(type="text", text=f"Error reading CSV: {e}")]

        if not rows:
            return [types.TextContent(type="text", text="Error: CSV has no data rows.")]
        if "_schema" not in rows[0]:
            return [types.TextContent(type="text", text=(
                "Error: CSV must have a '_schema' column. "
                "Put the schema string in that column's first row, e.g. "
                "'sentiment:choice[positive,negative,neutral];confidence:float[0,1]'"
            ))]

        schema_str = rows[0].get("_schema", "").strip()
        if not schema_str:
            return [types.TextContent(type="text", text="Error: '_schema' column is empty in the first row.")]

        try:
            schema = _parse_annotation_schema(schema_str)
        except ValueError as e:
            return [types.TextContent(type="text", text=f"Error parsing schema: {e}")]

        annot_fields = list(schema.keys())

        # Find first unannotated row
        start_index = None
        for i, row in enumerate(rows):
            if all(str(row.get(f, "")).strip() == "" for f in annot_fields):
                start_index = i
                break

        if start_index is None:
            return [types.TextContent(type="text", text=f"All {len(rows)} rows are already annotated. Nothing to do.")]

        _annot_state["rows"] = rows
        _annot_state["fieldnames"] = fieldnames
        _annot_state["path"] = work_path
        _annot_state["index"] = start_index
        _annot_state["schema"] = schema
        _annot_state["total"] = len(rows)

        schema_display = "; ".join(
            f"{f}: {s['type']}[{s['constraint']}]" if s["constraint"] else f"{f}: {s['type']}"
            for f, s in schema.items()
        )
        row_display = _row_display(rows[start_index], annot_fields)
        already_done = start_index

        msg = (
            f"Annotation session loaded.\n"
            f"Working file: {work_path}\n"
            f"Total rows: {len(rows)} | Already annotated: {already_done} | Remaining: {len(rows) - already_done}\n"
            f"Schema: {schema_display}\n\n"
            f"--- Row {start_index + 1}/{len(rows)} ---\n"
            f"{row_display}\n\n"
            f"Call `annotate` with: {annot_fields}"
        )
        return [types.TextContent(type="text", text=msg)]

    elif name == "annotate":
        if _annot_state["rows"] is None:
            return [types.TextContent(type="text", text=(
                "No annotation session active. Call `load_annotation_data` first."
            ))]

        # Accept both nested {"annotations": {...}} and flat {"field": "value", ...}
        schema_keys = set(_annot_state["schema"].keys())
        if "annotations" in arguments and isinstance(arguments["annotations"], dict):
            annotations = arguments["annotations"]
        elif schema_keys.intersection(arguments.keys()):
            annotations = {k: v for k, v in arguments.items() if k in schema_keys}
        else:
            annotations = arguments.get("annotations")
        if not isinstance(annotations, dict):
            return [types.TextContent(type="text", text=(
                "Error: pass annotation fields directly or nested under 'annotations'. "
                f"Expected fields: {list(_annot_state['schema'].keys())}"
            ))]

        valid, err = _validate_annotation(annotations, _annot_state["schema"])
        if not valid:
            schema_display = "; ".join(
                f"{f}: {s['type']}[{s['constraint']}]" if s["constraint"] else f"{f}: {s['type']}"
                for f, s in _annot_state["schema"].items()
            )
            return [types.TextContent(type="text", text=(
                f"Validation error: {err}\n"
                f"Schema: {schema_display}\n"
                "Please call `annotate` again with the correct values."
            ))]

        # Write annotation into current row
        idx = _annot_state["index"]
        for field, value in annotations.items():
            _annot_state["rows"][idx][field] = value

        _save_annotation_csv()

        # Advance to next unannotated row
        annot_fields = list(_annot_state["schema"].keys())
        next_index = None
        for i in range(idx + 1, _annot_state["total"]):
            if all(str(_annot_state["rows"][i].get(f, "")).strip() == "" for f in annot_fields):
                next_index = i
                break

        if next_index is None:
            _annot_state["rows"] = None  # reset state
            return [types.TextContent(type="text", text=(
                f"Annotation complete. All {_annot_state['total']} rows annotated.\n"
                f"Results saved to: {_annot_state['path']}"
            ))]

        _annot_state["index"] = next_index
        row_display = _row_display(_annot_state["rows"][next_index], annot_fields)

        msg = (
            f"Saved row {idx + 1}. "
            f"--- Row {next_index + 1}/{_annot_state['total']} ---\n"
            f"{row_display}\n\n"
            f"Call `annotate` with: {annot_fields}"
        )
        return [types.TextContent(type="text", text=msg)]

    elif name == "checkpoint_session":
        label = arguments.get("label")
        code = (
            f'ClaudeR::checkpoint_session(label = "{escape_r_string(label)}")'
            if label else "ClaudeR::checkpoint_session()"
        )
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error creating checkpoint: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "Checkpoint saved.")
        ))
        return result_contents

    elif name == "restore_session":
        chk = arguments.get("checkpoint")
        code = (
            f'ClaudeR::restore_session(checkpoint = "{escape_r_string(chk)}")'
            if chk else "ClaudeR::restore_session()"
        )
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error restoring checkpoint: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "Session restored.")
        ))
        return result_contents

    elif name == "list_checkpoints":
        result = await execute_r_code_via_addin("print(ClaudeR::list_session_checkpoints())")
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error listing checkpoints: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "No checkpoints.")
        ))
        return result_contents

    elif name == "screening_report":
        pass_a = arguments.get("pass_a", "").strip()
        if not pass_a:
            return [types.TextContent(type="text", text="Error: 'pass_a' is required")]
        parts = [f'pass_a = "{escape_r_string(pass_a)}"']
        if arguments.get("pass_b"):
            parts.append(f'pass_b = "{escape_r_string(arguments["pass_b"])}"')
        if arguments.get("include_field"):
            parts.append(f'include_field = "{escape_r_string(arguments["include_field"])}"')
        if arguments.get("reason_field"):
            parts.append(f'reason_field = "{escape_r_string(arguments["reason_field"])}"')
        code = f"ClaudeR::screening_report({', '.join(parts)})"
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error building screening report: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "Screening report complete.")
        ))
        return result_contents

    elif name == "set_agent_name":
        new_name = (arguments.get("name") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,39}", new_name):
            return [types.TextContent(
                type="text",
                text="Error: invalid name. Use 1-40 characters: letters, digits, dash, underscore; start with a letter or digit."
            )]
        if (_agent_id_source == "set_agent_name" and new_name != _agent_id
                and not arguments.get("force")):
            return [types.TextContent(
                type="text",
                text=(
                    f"REFUSED: an earlier set_agent_name call already named this "
                    f"connection '{_agent_id}'. A second, different name usually means "
                    f"several personas share this MCP connection, and renaming it would "
                    f"change every persona's identity at once (the name tug-of-war bug). "
                    f"If you share this connection, do not rename it. Pass "
                    f"as_agent = \"{new_name}\" on every send_message, check_messages, "
                    f"and wait_for_message call instead; each name keeps its own read "
                    f"cursor. If you are the only agent on this connection and the "
                    f"rename is deliberate, call set_agent_name again with force = true."
                )
            )]
        old_name = _agent_id
        _agent_id = new_name
        globals()["_agent_id_source"] = "set_agent_name"
        return [types.TextContent(
            type="text",
            text=(
                f"Agent identity set: {old_name} -> {new_name}. Execution history, "
                f"coordination messages, presence, and your read cursor now use this name. "
                f"If you had already sent messages as {old_name}, mention the rename to "
                f"your partners so they can map the two. CAUTION: this renames the whole "
                f"connection. If another agent or persona shares this connection, its "
                f"identity just changed too; personas sharing a connection should pass "
                f"as_agent per coordination call instead of renaming."
            )
        )]

    elif name == "send_message":
        body = arguments.get("body")
        if body is None or (isinstance(body, str) and not body.strip()):
            return [types.TextContent(type="text", text="Error: 'body' is required")]
        if isinstance(body, str):
            body = {"text": body}
        note, coord_err = _coord_target()
        if coord_err:
            return [types.TextContent(type="text", text=coord_err)]
        try:
            _coord_append(arguments.get("type", "message"), body,
                          to=arguments.get("to", "all"),
                          reply_to=arguments.get("reply_to"),
                          as_agent=arguments.get("as_agent"))
        except ValueError as e:
            return [types.TextContent(type="text", text=f"Error: {e}")]
        sender = arguments.get("as_agent") or _agent_id
        reply = f"Message sent to the coordination log as '{sender}'."
        if not arguments.get("as_agent") and _agent_id_source in (
                "set_agent_name", "randomly assigned for this connection"):
            reply += (" If that name is not you, this connection is shared: pass "
                      "as_agent = \"YourName\" on every coordination call.")
        if note:
            reply = note + "\n" + reply
        result_contents.append(types.TextContent(type="text", text=reply))
        return result_contents

    elif name == "check_messages":
        persona = arguments.get("as_agent")
        note, coord_err = _coord_target()
        if coord_err:
            return [types.TextContent(type="text", text=coord_err)]
        unread = _coord_unread(as_agent=persona)
        if not unread:
            reply = "No unread coordination events."
            if note:
                reply = note + "\n" + reply
            result_contents.append(types.TextContent(type="text", text=reply))
            return result_contents
        if arguments.get("ack", True):
            _coord_set_cursor(max(ev["id"] for ev in unread), as_agent=persona)
        reply = f"{len(unread)} unread event(s):\n" + _coord_format(unread)
        if note:
            reply = note + "\n" + reply
        result_contents.append(types.TextContent(type="text", text=reply))
        return result_contents

    elif name == "wait_for_message":
        timeout_s = min(float(arguments.get("timeout_s", 300)), 1800.0)
        from_agent = arguments.get("from_agent")
        ev_type = arguments.get("type")
        persona = arguments.get("as_agent")
        note, coord_err = _coord_target()
        if coord_err:
            return [types.TextContent(type="text", text=coord_err)]
        waited = 0.0
        while waited < timeout_s:
            unread = _coord_unread(from_agent=from_agent, ev_type=ev_type,
                                   as_agent=persona)
            if unread:
                _coord_set_cursor(max(ev["id"] for ev in unread), as_agent=persona)
                reply = (f"Event arrived after {round(waited)}s:\n" +
                         _coord_format(unread))
                if note:
                    reply = note + "\n" + reply
                result_contents.append(types.TextContent(type="text", text=reply))
                return result_contents
            await asyncio.sleep(2)
            waited += 2
            late_note, coord_err = _coord_target()
            if coord_err:
                return [types.TextContent(
                    type="text",
                    text=f"Aborted after {round(waited)}s of waiting. " + coord_err
                )]
            note = note or late_note
        result_contents.append(types.TextContent(
            type="text",
            text=(f"No matching event within {round(timeout_s)}s. The other "
                  f"agent may be busy or offline; use coordination_roster to "
                  f"check presence, or wait again.")
        ))
        return result_contents

    elif name == "coordination_roster":
        stale_after = float(arguments.get("stale_after_s", 900))
        note, coord_err = _coord_target()
        if coord_err:
            return [types.TextContent(type="text", text=coord_err)]
        events = _coord_events()
        if not events:
            reply = "No coordination activity yet on this session."
            if note:
                reply = note + "\n" + reply
            return [types.TextContent(type="text", text=reply)]
        last: Dict[str, str] = {}
        for ev in events:
            last[ev.get("from", "?")] = ev.get("ts", "")
        lines = []
        now = datetime.now()
        for agent_name, ts in sorted(last.items()):
            try:
                seen = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
                ago = (now - seen).total_seconds()
                flag = " [STALE]" if ago > stale_after else ""
                lines.append(f"  {agent_name}: last seen {round(ago)}s ago{flag}")
            except ValueError:
                lines.append(f"  {agent_name}: last seen {ts}")
        reply = "Coordination roster:\n" + "\n".join(lines)
        if note:
            reply = note + "\n" + reply
        result_contents.append(types.TextContent(type="text", text=reply))
        return result_contents

    elif name == "check_cross_references":
        document = arguments.get("document", "").strip()
        if not document:
            return [types.TextContent(type="text", text="Error: 'document' parameter is required")]
        code = f'ClaudeR::check_cross_references("{escape_r_string(document)}")'
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error checking cross-references: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "Cross-reference check complete.")
        ))
        return result_contents

    elif name == "reconcile_values":
        document = arguments.get("document", "").strip()
        sources = arguments.get("sources") or []
        if not document or not sources:
            return [types.TextContent(
                type="text",
                text="Error: 'document' and a non-empty 'sources' array are required"
            )]
        src_r = ", ".join(f'"{escape_r_string(s)}"' for s in sources)
        parts = [f'document = "{escape_r_string(document)}"', f"sources = c({src_r})"]
        if arguments.get("ignore_years") is False:
            parts.append("ignore_years = FALSE")
        code = f"ClaudeR::reconcile_values({', '.join(parts)})"
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error reconciling values: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "Reconciliation complete.")
        ))
        return result_contents

    elif name == "generate_codebook":
        parts = []
        if arguments.get("project_dir"):
            parts.append(f'project_dir = "{escape_r_string(arguments["project_dir"])}"')
        if arguments.get("data_files"):
            files = ", ".join(f'"{escape_r_string(f)}"' for f in arguments["data_files"])
            parts.append(f"data_files = c({files})")
        if arguments.get("output_path"):
            parts.append(f'output_path = "{escape_r_string(arguments["output_path"])}"')
        code = f"ClaudeR::generate_codebook({', '.join(parts)})"
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error generating codebook: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "Codebook generated.")
        ))
        return result_contents

    elif name == "generate_notebook":
        parts = []
        if arguments.get("log_path"):
            parts.append(f'log_path = "{escape_r_string(arguments["log_path"])}"')
        if arguments.get("output_path"):
            parts.append(f'output_path = "{escape_r_string(arguments["output_path"])}"')
        if arguments.get("title"):
            parts.append(f'title = "{escape_r_string(arguments["title"])}"')
        code = f"ClaudeR::export_log_as_notebook({', '.join(parts)})"
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error generating notebook: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text",
            text=(result.get("output", "Notebook generated.") +
                  "\n\nNext: read the .qmd and replace each '<!-- TODO: narration -->' "
                  "marker with a short explanation of that step, then render with quarto "
                  "if an HTML notebook is wanted.")
        ))
        return result_contents

    elif name == "search_citations":
        query = arguments.get("query", "").strip()
        if not query:
            return [types.TextContent(type="text", text="Error: 'query' parameter is required")]
        max_results = int(arguments.get("max_results", 5))
        code = (
            f'ClaudeR:::search_citations_impl("{escape_r_string(query)}", '
            f'max_results = {max_results}L)'
        )
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error searching citations: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "No results.")
        ))
        return result_contents

    elif name == "get_bibtex":
        doi = arguments.get("doi", "").strip()
        if not doi:
            return [types.TextContent(type="text", text="Error: 'doi' parameter is required")]
        code = f'cat(ClaudeR:::get_bibtex_impl("{escape_r_string(doi)}"))'
        result = await execute_r_code_via_addin(code)
        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error fetching BibTeX: {result.get('error', 'Unknown error')}"
            )]
        result_contents.append(types.TextContent(
            type="text", text=result.get("output", "No BibTeX returned.")
        ))
        return result_contents

    return [types.TextContent(
        type="text",
        text=f"Unknown tool: {name}"
    )]

# Run the server
async def main():
    global _agent_id

    args = parse_args()
    global _agent_id_source
    if os.environ.get("CLAUDER_AGENT_ID"):
        _agent_id_source = "CLAUDER_AGENT_ID environment variable"
    elif args.agent_id:
        _agent_id_source = "--agent-id argument"
    else:
        _agent_id_source = "randomly assigned for this connection"
    _agent_id = args.agent_id or f"agent-{uuid.uuid4().hex[:8]}"

    # Discover sessions
    sessions = discover_sessions()
    session_info = f", {len(sessions)} session(s) found" if sessions else ", no sessions yet"

    print(f"Starting R Studio MCP server (agent={_agent_id}{session_info})...", file=sys.stderr)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options()
        )

if __name__ == "__main__":
    asyncio.run(main())
