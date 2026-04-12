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
SESSIONS_DIR = os.path.expanduser("~/.claude_r_sessions")
_agent_id: Optional[str] = None       # Set in main()
_target_session: Optional[str] = None  # Set by connect_session tool
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
    """Check if a process is running (signal 0 doesn't kill, just checks)."""
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
    stays sticky. Prefers the 'default' session when no target is set."""
    global _target_session
    sessions = discover_sessions()
    if not sessions:
        return R_ADDIN_URL
    if _target_session:
        for s in sessions:
            if s["session_name"] == _target_session:
                return f"http://127.0.0.1:{s['port']}"
        _target_session = None  # bound session gone, re-pick
    # Pick: prefer "default" name, else lowest port
    pick = next((s for s in sessions if s.get("session_name") == "default"), None)
    if not pick:
        sessions.sort(key=lambda s: s.get("port", 99999))
        pick = sessions[0]
    _target_session = pick["session_name"]
    return f"http://127.0.0.1:{pick['port']}"


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
    # If we've already checked, return the cached result immediately.
    if _is_ggplot_installed is not None:
        return _is_ggplot_installed

    result = await execute_r_code_via_addin("print(requireNamespace('ggplot2', quietly = TRUE))")

    if result.get("success") and "TRUE" in result.get("output", ""):
        print("ggplot2 check successful.", file=sys.stderr)
        _is_ggplot_installed = True
    else:
        print("ggplot2 not found in R environment.", file=sys.stderr)
        _is_ggplot_installed = False
    
    return _is_ggplot_installed

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

async def post_to_r_addin(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Send an arbitrary JSON payload to the R addin HTTP server."""
    url = get_r_addin_url()
    if url is None:
        return {"success": False, "error": "No R sessions found. Start the ClaudeR addin in RStudio first."}
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(url, json=payload, timeout=10.0)
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
            response = await client.get(url, timeout=2.0)
            if response.status_code == 200:
                if return_info:
                    return response.json()
                return True
    except:
        pass
    return None if return_info else False


async def get_agent_introduction() -> str:
    """Build a one-time context message for the agent's first tool call."""
    info = await check_addin_status(return_info=True)

    lines = [
        f"[ClaudeR Agent Context]",
        f"Your agent ID: {_agent_id}",
        f"This ID uniquely identifies you in this R session. All code you execute is attributed to this ID.",
    ]

    if info:
        other_agents = [a for a in info.get("connected_agents", []) if a != _agent_id and a != "unknown"]
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
    lines.append("  ClaudeR::r_best_practices_prompt()   - Statistical analysis protocol")
    lines.append("  ClaudeR::multi_agent_prompt()        - Multi-agent coordination protocol")
    lines.append("")
    lines.append("Context-saving rules:")
    lines.append("  - Do NOT use installed.packages(). Use requireNamespace('pkg') to check for a specific package.")
    lines.append("  - Do NOT use bare ls(). Use head(ls(), 20) or search for specific objects with exists('name').")
    lines.append("  - Do NOT use bare list.files(). Use head(list.files(), 20) or list.files(pattern = 'specific').")
    lines.append("  - These commands can return hundreds of items and fill up your context window.")
    lines.append("[End ClaudeR Agent Context]")
    return "\n".join(lines)

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
    model: Optional[str], timeout: int
) -> tuple:
    """Run a single annotation subprocess. Returns (result_dict or None, raw_output, error_msg)."""
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

        else:  # codex
            last_msg_path = tempfile.mktemp(suffix=".txt")
            command = [
                tool_path, "exec",
                "-c", "mcp_servers={}",
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
    model: Optional[str], timeout: int
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
        result, raw, err = _run_subprocess_row(prompt, tool, tool_path, model, timeout)

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
            description="Get the content of the active document in RStudio",
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
            name="modify_code_section",
            description="Modify a specific section of code in the active document",
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
            description="Insert text at the current cursor position in the active RStudio document, or at a specific line and column.",
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
            description="Execute long-running R code in a separate background R process. Returns a job ID immediately and the main session stays fully responsive. Use this for code that may take longer than 25 seconds (e.g., model fitting, simulations, large data processing). IMPORTANT: The background process does NOT have access to the main session's environment. Write self-contained code: use saveRDS() to pass data in and write results out, then load them back in the main session after the job completes. You can continue executing other code with execute_r while the job runs. Use get_async_result to check status when ready.",
            inputSchema={
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "R code to execute asynchronously"
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
            description="Read the contents of a file from disk. Use this to read R scripts, log files, data files (.csv, .txt), or any text file. The file does not need to be open in RStudio. Returns the file contents with line numbers. Supports pagination via start_line/end_line for large files. To modify and save changes back, use execute_r with writeLines().",
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
            description="Source one or more R scripts in a clean background session and report what objects are created (names, classes, dimensions). Does NOT affect the main R session. Useful for understanding what a script produces before sourcing it.",
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
                "Annotate a CSV dataset using a fresh subprocess per row — no context bleed between rows. "
                "Each row is scored by a brand-new claude or codex process that sees only that row. "
                "Runs in the background; returns a job ID immediately. "
                "Use get_annotation_job_status to check progress. "
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
                        "description": "CLI tool to use: 'claude' (default) or 'codex'."
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name to pass to the CLI (optional, uses CLI default if omitted)."
                    },
                    "timeout": {
                        "type": "number",
                        "description": "Seconds to wait per row before giving up (default: 60)."
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
    ]

@server.call_tool()
async def call_tool(name: str, arguments: Dict[str, Any]) -> List[types.TextContent | types.ImageContent]:
    """Handle R tool calls."""
    global _target_session, _agent_introduced

    # These tools check Python-side state only — skip addin check
    _skip_addin_check = {"list_sessions", "connect_session", "load_annotation_data", "annotate", "run_annotation_job", "get_annotation_job_status"}
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
            return [types.TextContent(
                type="text",
                text=f"R Error: {result.get('error', 'Unknown error')}"
            )]
        
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
        # Get active document content
        result = await execute_r_code_via_addin("""
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
            context <- rstudioapi::getActiveDocumentContext()
            list(
                content = paste(context$contents, collapse = "\n"),
                path = context$path,
                line_count = length(context$contents)
            )
        } else {
            list(error = "RStudio API not available")
        }
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
        code = f'ClaudeR:::search_project_code_impl("{escaped_pattern}", extensions = "{extensions}", root_dir = "{escaped_root}", max_results = {max_results}L, ignore_case = {"TRUE" if ignore_case else "FALSE"})'
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
        code = f'ClaudeR:::probe_scripts_impl(jsonlite::fromJSON(\'{escaped_json}\'), timeout = {timeout})'
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
        job_id = uuid.uuid4().hex[:8]

        # Send to R — R launches callr::r_bg() and returns immediately
        payload = {
            "code": code,
            "async": True,
            "job_id": job_id,
        }
        if _agent_id:
            payload["agent_id"] = _agent_id

        result = await post_to_r_addin(payload)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error starting async job: {result.get('error', 'Unknown error')}"
            )]

        return [types.TextContent(
            type="text",
            text=f"Job {job_id} started in a background R process. The main R session remains available — you can continue running other code with execute_r while this job runs. Use get_async_result(\"{job_id}\") to check status when ready."
        )]

    elif name == "get_async_result":
        job_id = arguments.get("job_id", "")

        # Throttle polling — wait before checking
        await asyncio.sleep(10)

        # Ask R for the job status
        result = await post_to_r_addin({"check_job": job_id})

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

        return result_contents or [types.TextContent(
            type="text",
            text="Async job completed successfully but produced no output."
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

        r_code = f'ClaudeR:::query_agent_history("{filter_value}", "{escape_r_string(_agent_id or "unknown")}", {last_n})'
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
                lines <- readLines(fpath, warn = FALSE)
                total <- length(lines)
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
        
        # Escape special characters for R string
        search_pattern = arguments["search_pattern"].replace("\\", "\\\\").replace("\"", "\\\"").replace("'", "\\'")
        replacement = arguments["replacement"].replace("\\", "\\\\").replace("\"", "\\\"").replace("'", "\\'")
        
        # Get line constraints if provided
        line_start = arguments.get("line_start", "NULL")
        line_end = arguments.get("line_end", "NULL")
        
        modify_code = f"""
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
            context <- rstudioapi::getActiveDocumentContext()
            content <- context$contents
            
            # Convert to a single string for pattern matching
            full_text <- paste(content, collapse = "\\n")
            
            # Apply line constraints if provided
            line_start <- {line_start}
            line_end <- {line_end}
            
            if (!is.null(line_start) && !is.null(line_end)) {{
                # Work with a subset of lines
                if (line_start > 0 && line_end <= length(content) && line_start <= line_end) {{
                    subset_lines <- content[line_start:line_end]
                    subset_text <- paste(subset_lines, collapse = "\\n")
                    
                    # Apply replacement in the subset
                    search_pattern <- "{search_pattern}"
                    modified_subset <- gsub(search_pattern, "{replacement}", subset_text, perl = TRUE)
                    
                    # Split back into lines
                    modified_lines <- strsplit(modified_subset, "\\n")[[1]]
                    
                    # Update the content
                    if (length(modified_lines) == length(subset_lines)) {{
                        content[line_start:line_end] <- modified_lines
                        rstudioapi::setDocumentContents(paste(content, collapse = "\\n"), id = context$id)
                        list(
                            success = TRUE, 
                            message = paste0("Modified code between lines ", line_start, " and ", line_end)
                        )
                    }} else {{
                        list(
                            success = FALSE,
                            error = "Replacement resulted in different number of lines"
                        )
                    }}
                }} else {{
                    list(
                        success = FALSE,
                        error = paste0("Invalid line range: ", line_start, "-", line_end, 
                                      ". Document has ", length(content), " lines.")
                    )
                }}
            }} else {{
                # Apply replacement to entire document
                modified_text <- gsub("{search_pattern}", "{replacement}", full_text, perl = TRUE)
                
                if (modified_text != full_text) {{
                    rstudioapi::setDocumentContents(modified_text, id = context$id)
                    list(
                        success = TRUE,
                        message = "Modified code in the document"
                    )
                }} else {{
                    list(
                        success = FALSE,
                        error = "Pattern not found in document"
                    )
                }}
            }}
        }} else {{
            list(
                success = FALSE,
                error = "RStudio API not available"
            )
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

        if line is not None:
            col = int(column) if column is not None else 1
            insert_code = f'''
if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
    pos <- rstudioapi::document_position({int(line)}, {col})
    rstudioapi::insertText(location = pos, text = "{text}")
    paste0("Inserted text at line ", {int(line)}, ", column ", {col})
}} else {{
    stop("RStudio API not available")
}}
'''
        else:
            insert_code = f'''
if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {{
    rstudioapi::insertText(text = "{text}")
    "Inserted text at current cursor position"
}} else {{
    stop("RStudio API not available")
}}
'''

        result = await execute_r_code_via_addin(insert_code)

        if not result.get("success", False):
            return [types.TextContent(
                type="text",
                text=f"Error inserting text: {result.get('error', 'Unknown error')}"
            )]

        result_contents.append(types.TextContent(
            type="text",
            text=result.get("output", "Text inserted successfully")
        ))
        return result_contents

    elif name == "run_annotation_job":
        import csv as csv_module

        csv_path = arguments.get("csv_path", "").strip()
        tool = arguments.get("tool", "claude").strip().lower()
        model = arguments.get("model") or None
        timeout = int(arguments.get("timeout", 60))

        if not csv_path:
            return [types.TextContent(type="text", text="Error: 'csv_path' is required.")]
        if not os.path.exists(csv_path):
            return [types.TextContent(type="text", text=f"Error: File not found: {csv_path}")]
        if tool not in ("claude", "codex"):
            return [types.TextContent(type="text", text="Error: 'tool' must be 'claude' or 'codex'.")]

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
            args=(job_id, rows, fieldnames, unannotated, schema, work_path, tool, tool_path, model, timeout),
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

    return [types.TextContent(
        type="text",
        text=f"Unknown tool: {name}"
    )]

# Run the server
async def main():
    global _agent_id

    args = parse_args()
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
