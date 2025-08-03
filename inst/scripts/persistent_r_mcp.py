#!/usr/bin/env python3
# persistent_r_mcp.py

import asyncio
import json
import tempfile
import os
import base64
from typing import Any, Dict, List
import httpx
import sys
from datetime import datetime
from mcp.server import Server
from mcp.server.stdio import stdio_server
import mcp.types as types

# Configure the server instance
server = Server("r-studio")

# Configuration
R_ADDIN_URL = "http://127.0.0.1:8787"  # URL of the R addin server


# Cache variable to store the result of the ggplot2 check
_is_ggplot_installed = None



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
    """Escape special characters for R strings."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("'", "\\'").replace("\n", "\\n")

# Function to execute R code via the HTTP addin
async def execute_r_code_via_addin(code: str) -> Dict[str, Any]:
    """Execute R code through the RStudio addin HTTP server."""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                R_ADDIN_URL,
                json={"code": code},
                timeout=30.0
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

# Check if the R addin is running
async def check_addin_status() -> bool:
    """Check if the RStudio addin is running."""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(R_ADDIN_URL, timeout=2.0)
            if response.status_code == 200:
                return True
    except:
        pass
    return False

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
            }
        ),
        types.Tool(
            name="get_active_document",
            description="Get the content of the active document in RStudio",
            inputSchema={
                "type": "object",
                "properties": {}
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
            }
        ),
    ]

@server.call_tool()
async def call_tool(name: str, arguments: Dict[str, Any]) -> List[types.TextContent | types.ImageContent]:
    """Handle R tool calls."""
    
    # Check if the R addin is running
    if not await check_addin_status():
        return [types.TextContent(
            type="text",
            text="Error: RStudio addin is not running. Please start the Claude RStudio Connection addin in RStudio."
        )]
    
    result_contents = []
    
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
        result = await execute_r_code_via_addin(f'cat("{task_list_code}")')
        
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
        task_id = arguments.get("task_id")
        status = arguments.get("status")
        notes = arguments.get("notes", "")
        
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
    
    return [types.TextContent(
        type="text",
        text=f"Unknown tool: {name}"
    )]

# Run the server
async def main():
    print("Starting R Studio MCP server...", file=sys.stderr)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options()
        )

if __name__ == "__main__":
    asyncio.run(main())
