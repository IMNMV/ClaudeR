#!/usr/bin/env python3
# persistent_r_mcp.py

import asyncio
import base64
import json
import os
import sys
import tempfile
from typing import Any, Dict, List

import httpx
import mcp.types as types
from mcp.server import Server
from mcp.server.stdio import stdio_server

# Configure the server instance
server = Server("r-studio")

# Configuration
R_ADDIN_URL = "http://127.0.0.1:8787"  # URL of the R addin server


# Function to execute R code via the HTTP addin
async def execute_r_code_via_addin(code: str) -> Dict[str, Any]:
    """Execute R code through the RStudio addin HTTP server."""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(R_ADDIN_URL, json={"code": code}, timeout=30.0)
            response.raise_for_status()
            return response.json()
    except httpx.HTTPError as e:
        print(f"HTTP error: {str(e)}", file=sys.stderr)
        return {
            "success": False,
            "error": f"HTTP error communicating with RStudio: {str(e)}",
        }
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        return {
            "success": False,
            "error": f"Error communicating with RStudio: {str(e)}",
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
                    "code": {"type": "string", "description": "R code to execute"}
                },
                "required": ["code"],
            },
        ),
        types.Tool(
            name="execute_r_with_plot",
            description="Execute R code that generates a plot",
            inputSchema={
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "R code to execute that generates a plot",
                    }
                },
                "required": ["code"],
            },
        ),
        types.Tool(
            name="get_r_info",
            description="Get information about the R environment",
            inputSchema={
                "type": "object",
                "properties": {
                    "what": {
                        "type": "string",
                        "description": "What information to get: 'packages', 'variables', 'version', or 'all'",
                    }
                },
                "required": ["what"],
            },
        ),
        types.Tool(
            name="get_active_document",
            description="Get the content of the active document in RStudio",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="modify_code_section",
            description="Modify a specific section of code in the active document",
            inputSchema={
                "type": "object",
                "properties": {
                    "search_pattern": {
                        "type": "string",
                        "description": "Pattern to identify the section of code to be modified",
                    },
                    "replacement": {
                        "type": "string",
                        "description": "New code to replace the identified section",
                    },
                    "line_start": {
                        "type": "number",
                        "description": "Optional: Start line number for the search (1-based indexing)",
                    },
                    "line_end": {
                        "type": "number",
                        "description": "Optional: End line number for the search (1-based indexing)",
                    },
                },
                "required": ["search_pattern", "replacement"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(
    name: str, arguments: Dict[str, Any]
) -> List[types.TextContent | types.ImageContent]:
    """Handle R tool calls."""

    # Check if the R addin is running
    if not await check_addin_status():
        return [
            types.TextContent(
                type="text",
                text="Error: RStudio addin is not running. Please start the Claude RStudio Connection addin in RStudio.",
            )
        ]

    result_contents = []

    if name == "execute_r":
        if "code" not in arguments:
            return [
                types.TextContent(
                    type="text", text="Error: 'code' parameter is required"
                )
            ]

        result = await execute_r_code_via_addin(arguments["code"])

        if not result.get("success", False):
            return [
                types.TextContent(
                    type="text", text=f"R Error: {result.get('error', 'Unknown error')}"
                )
            ]

        # Add text output
        if "output" in result and result["output"]:
            result_contents.append(
                types.TextContent(type="text", text=result["output"])
            )

        # Add plot if available
        if "plot" in result:
            result_contents.append(
                types.ImageContent(
                    type="image",
                    data=result["plot"]["data"],
                    mimeType=result["plot"]["mime_type"],
                )
            )

        return result_contents or [
            types.TextContent(
                type="text", text="Code executed successfully but produced no output."
            )
        ]

    elif name == "execute_r_with_plot":
        if "code" not in arguments:
            return [
                types.TextContent(
                    type="text", text="Error: 'code' parameter is required"
                )
            ]

        # For plots, we'll ensure there's a plot device opened
        plot_code = f"""
        # Ensure plot is displayed in RStudio
        if (!("package:ggplot2" %in% search())) {{
          if (requireNamespace("ggplot2", quietly = TRUE)) {{
            library(ggplot2)
          }}
        }}
        
        # Execute the plot code
        {arguments["code"]}
        """

        result = await execute_r_code_via_addin(plot_code)

        # Add text output
        if "output" in result and result["output"]:
            result_contents.append(
                types.TextContent(type="text", text=result["output"])
            )

        # Add error if any
        if not result.get("success", False):
            result_contents.append(
                types.TextContent(
                    type="text", text=f"R Error: {result.get('error', 'Unknown error')}"
                )
            )

        # Add plot if available
        if "plot" in result:
            result_contents.append(
                types.ImageContent(
                    type="image",
                    data=result["plot"]["data"],
                    mimeType=result["plot"]["mime_type"],
                )
            )

        return result_contents or [
            types.TextContent(
                type="text",
                text="Code executed but no plot was generated. Make sure your code creates a plot.",
            )
        ]

    elif name == "get_r_info":
        what = arguments.get("what", "all")

        if what == "packages" or what == "all":
            pkg_code = "installed.packages()[,1]"
            pkg_result = await execute_r_code_via_addin(pkg_code)
            if pkg_result.get("success", False):
                result_contents.append(
                    types.TextContent(
                        type="text",
                        text=f"Installed R packages:\n{pkg_result.get('output', '')}",
                    )
                )

        if what == "variables" or what == "all":
            var_code = "ls()"
            var_result = await execute_r_code_via_addin(var_code)
            if var_result.get("success", False):
                result_contents.append(
                    types.TextContent(
                        type="text",
                        text=f"R variables in global environment:\n{var_result.get('output', '')}",
                    )
                )

        if what == "version" or what == "all":
            ver_code = "R.version.string"
            ver_result = await execute_r_code_via_addin(ver_code)
            if ver_result.get("success", False):
                result_contents.append(
                    types.TextContent(
                        type="text", text=f"R version:\n{ver_result.get('output', '')}"
                    )
                )

        return result_contents or [
            types.TextContent(type="text", text=f"Unknown info type: {what}")
        ]

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
            return [
                types.TextContent(
                    type="text",
                    text=f"Error retrieving active document: {result.get('error', 'Unknown error')}",
                )
            ]

        return [
            types.TextContent(
                type="text", text=result.get("output", "No document content retrieved")
            )
        ]

    elif name == "modify_code_section":
        if not all(k in arguments for k in ["search_pattern", "replacement"]):
            return [
                types.TextContent(
                    type="text",
                    text="Error: Both 'search_pattern' and 'replacement' parameters are required",
                )
            ]

        # Escape special characters for R string
        search_pattern = (
            arguments["search_pattern"]
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("'", "\\'")
        )
        replacement = (
            arguments["replacement"]
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("'", "\\'")
        )

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
            return [
                types.TextContent(
                    type="text",
                    text=f"Error modifying code: {result.get('error', 'Unknown error')}",
                )
            ]

        return [
            types.TextContent(
                type="text",
                text=result.get("output", "No result returned from code modification"),
            )
        ]

    return [types.TextContent(type="text", text=f"Unknown tool: {name}")]


# Run the server
async def serve():
    print("Starting R Studio MCP server...", file=sys.stderr)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream, write_stream, server.create_initialization_options()
        )


def main() -> None:
    """Main function to start the server."""
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        print("Server stopped by user.", file=sys.stderr)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)

if __name__ == "__main__":
    main()
