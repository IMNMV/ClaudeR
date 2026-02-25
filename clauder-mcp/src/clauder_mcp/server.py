#!/usr/bin/env python3
# persistent_r_mcp.py

import argparse
import asyncio
import json
import tempfile
import os
import base64
import uuid
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

    lines.append("[End ClaudeR Agent Context]")
    return "\n".join(lines)

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
            description="Get information about the R environment",
            inputSchema={
                "type": "object",
                "properties": {
                    "what": {
                        "type": "string",
                        "description": "What information to get: 'packages', 'variables', 'version', or 'all'"
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
            description="Read the contents of a file from disk. Use this to read R scripts, log files, data files (.csv, .txt), or any text file. The file does not need to be open in RStudio. Returns the file contents with line numbers. To modify and save changes back, use execute_r with writeLines().",
            inputSchema={
                "type": "object",
                "properties": {
                    "file_path": {
                        "type": "string",
                        "description": "Path to the file to read. Supports absolute paths and ~ for home directory."
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
    ]

@server.call_tool()
async def call_tool(name: str, arguments: Dict[str, Any]) -> List[types.TextContent | types.ImageContent]:
    """Handle R tool calls."""
    global _target_session, _agent_introduced

    # These tools check Python-side state only — skip addin check
    _skip_addin_check = {"list_sessions", "connect_session"}
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
            pkg_code = "installed.packages()[,1]"
            pkg_result = await execute_r_code_via_addin(pkg_code)
            if pkg_result.get("success", False):
                result_contents.append(types.TextContent(
                    type="text",
                    text=f"Installed R packages:\n{pkg_result.get('output', '')}"
                ))
        
        if what == "variables" or what == "all":
            var_code = "ls()"
            var_result = await execute_r_code_via_addin(var_code)
            if var_result.get("success", False):
                result_contents.append(types.TextContent(
                    type="text",
                    text=f"R variables in global environment:\n{var_result.get('output', '')}"
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
        return [types.TextContent(
            type="text",
            text=f"Connected to session '{session_name}'. All subsequent tool calls will be routed there."
        )]

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
        read_code = f'''
        tryCatch({{
            fpath <- path.expand("{file_path}")
            if (!file.exists(fpath)) {{
                list(success = FALSE, error = paste0("File not found: ", fpath))
            }} else {{
                lines <- readLines(fpath, warn = FALSE)
                numbered <- paste0(seq_along(lines), ": ", lines)
                list(success = TRUE, output = paste(numbered, collapse = "\\n"))
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

    return [types.TextContent(
        type="text",
        text=f"Unknown tool: {name}"
    )]

# Run the server
async def serve():
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
    asyncio.run(serve())
