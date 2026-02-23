# clauder-mcp

MCP server that connects AI assistants to RStudio for interactive R coding and data analysis.

This is the Python MCP bridge component of [ClaudeR](https://github.com/IMNMV/ClaudeR). It works with Claude Desktop, Claude Code, Codex CLI, Gemini CLI, Cursor, and any other MCP-compatible client.

## Prerequisites

You need the ClaudeR R package installed and running in RStudio:

```r
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")
library(ClaudeR)
claudeAddin()
```

Start the server from the RStudio Viewer pane before connecting your AI tool.

## Usage

### Claude Code

```bash
claude mcp add --transport stdio --scope user r-studio -- uvx clauder-mcp
```

### Codex CLI

```bash
codex mcp add r-studio -- uvx clauder-mcp
```

### Gemini CLI

Add to your `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "r-studio": {
      "command": "uvx",
      "args": ["clauder-mcp"]
    }
  }
}
```

### Claude Desktop / Cursor

Add to your MCP config file:

```json
{
  "mcpServers": {
    "r-studio": {
      "command": "uvx",
      "args": ["clauder-mcp"]
    }
  }
}
```

## Tools

- **execute_r** - Execute R code and return output
- **execute_r_with_plot** - Execute R code that generates a plot
- **execute_r_async** - Run long-running code in a background process
- **get_async_result** - Poll for async job results
- **read_file** - Read any text file from disk
- **get_active_document** - Get the active document in RStudio
- **modify_code_section** - Edit code in the active document
- **get_r_info** - Get R environment information
- **list_sessions** - List available RStudio sessions
- **connect_session** - Connect to a specific session
- **get_session_history** - View execution history by agent
- **create_task_list** - Create a task list for analysis
- **update_task_status** - Update task progress

## Links

- [ClaudeR R Package](https://github.com/IMNMV/ClaudeR) - Full documentation, installation guide, and features
- [License](https://github.com/IMNMV/ClaudeR/blob/main/LICENSE) - MIT
