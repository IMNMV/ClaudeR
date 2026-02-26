<div align="center">
  <img src="assets/ClaudeR_logo.png" alt="ClaudeR Logo" width="150"/>
  <h1>ClaudeR</h1>
  <p>
    <b>Connect RStudio directly to Claude Desktop, Claude Code, Codex, Gemini CLI, or any other MCP based AI assistant for interactive coding and data analysis.</b>
  </p>
  <p>
    <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <a href="https://github.com/IMNMV/ClaudeR/pulls"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome"></a>
    <a href="https://github.com/IMNMV/ClaudeR/stargazers"><img src="https://img.shields.io/github/stars/IMNMV/ClaudeR?style=social" alt="GitHub stars"></a>
    <br/>
    <a href="https://github.com/IMNMV/ClaudeR/commits/main"><img src="https://img.shields.io/github/last-commit/IMNMV/ClaudeR" alt="GitHub last commit"></a>
    <a href="https://pypi.org/project/clauder-mcp/"><img src="https://img.shields.io/pypi/v/clauder-mcp" alt="PyPI version"></a>
    <img src="https://img.shields.io/badge/R-%3E%3D4.0-blue?logo=r" alt="R version">
  </p>
</div>

---

**ClaudeR** is an R package that forges a direct link between RStudio and MCP configured AI assistants like Claude Code or Codex. This enables interactive coding sessions where the AI can execute code in your active RStudio environment and see the results in real-time. Whether you need an autonomous data explorer or a coding collaborator, ClaudeR adapts to your workflow.

This package is also compatible with Cursor and any service that support MCP servers.

## Quick Start

```r
# Install
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")

# Set up your AI tool
library(ClaudeR)
install_clauder()          # For Claude Desktop / Cursor
install_cli(tools = "claude")  # For Claude Code CLI

# Start the server in RStudio
claudeAddin()
```

<details>
<summary><b>Recent Updates</b> (click to expand)</summary>

- **Viewer content capture & `insert_text` tool.** Two new tools: `get_viewer_content` reads HTML from interactive widgets (plotly, DT, leaflet) with pagination so agents can inspect htmlwidget output without blowing up context. `insert_text` inserts text at the cursor position or a specific line/column in the active document. During agent execution, htmlwidgets open in the browser instead of stealing the Shiny addin's viewer pane.
- **Multi-session routing fix.** Agents now prefer the session named "default" when multiple sessions are active, preventing misrouting caused by non-deterministic discovery order. Once bound, agents stay sticky to their session. Non-default agents should call `connect_session` to target a specific session.
- **Reproducibility metadata in logs.** When logging is enabled, each new session log starts with a header containing the date, working directory, and full `sessionInfo()` output (R version, platform, attached packages). Anyone who receives the log can see exactly what environment the code ran in.
- **Export clean script.** Click "Export Clean Script" in the Shiny addin to strip all timestamps, agent labels, and log headers from a session log, producing a runnable `.R` file with just the code. Error blocks are preserved as comments. Also available programmatically via `export_log_as_script()`.
- **PyPI package (`clauder-mcp`).** The Python MCP bridge is now available as a standalone package on PyPI. Run it with `uvx clauder-mcp` for zero-config setup with no Python path or pip install needed. The installers (`install_cli()` and `install_clauder()`) default to uvx, with a `use_uvx = FALSE` fallback for legacy setups.
- **`read_file` tool.** Agents can now read any text file from disk (.R, .qmd, .csv, .log, etc.) without it being open in RStudio. Enables session continuity workflows: point an agent at a previous log file and tell it to pick up where the last session left off.
- **Codex CLI support.** `install_cli(tools = "codex")` generates the setup command for OpenAI Codex. Codex joins Claude Code and Gemini as a supported CLI agent.
- **Multi-agent orchestration.** Run multiple AI agents on the same R session or spread them across separate RStudio windows. Each agent gets a unique ID on startup. Console output, log files, and execution history are all attributed per agent, so you always know who did what. On its very first tool call, each agent receives a context briefing with its own ID, any other agents active on the session, and the log file path, giving it full awareness of the shared environment without any manual setup. Agents can call `get_session_history` to review what other agents have done, or read the shared log file directly. The Shiny viewer tracks connected agents in real-time.
- **Session discovery.** Each RStudio session writes a discovery file to `~/.claude_r_sessions/` on startup. AI agents find sessions automatically with no hardcoded ports. Name your sessions (e.g. "analysis", "modeling") and run them on different ports. When multiple sessions exist, agents automatically route to the session named "default". Non-default agents should call `connect_session` to bind to their target session. Single-session setups work with zero config.
- **Redesigned Shiny viewer.** Cleaner UI with grouped panels for Session, Agents, Logging, and Advanced settings. Shows connected agents and execution count in real-time. Click the `?` button for a built-in guide on multi-session setup and agent identity.
- **Non-blocking async execution.** `execute_r_async` now runs long-running code in a separate R process via `callr`, keeping the main session fully responsive. Other agents can continue working while a job runs. The agent writes self-contained code (explicitly saving/loading data via `saveRDS`), submits it, and polls with `get_async_result`. No environment copying and no memory doubling, only the data the job needs gets serialized.
- **Stale plot detection.** Fixed a bug where the last generated plot image would persist and re-appear on every subsequent `execute_r` call, even when no new plot was created.
- **Reduced plot token usage.** Plot capture now uses smaller dimensions (600x400, dpi 100) to reduce base64 image size and avoid token overflow errors.
- **MCP tool annotations.** All tools now include `readOnlyHint`, `destructiveHint`, and `idempotentHint` annotations per the current MCP spec.
- **Hardened string escaping.** `escape_r_string` now handles backticks, carriage returns, tabs, and null bytes. Applied to task tool inputs to prevent injection.
- **Fixed `install_cli()` command syntax.** Updated to use `--transport stdio` flag and `--` separator for current Claude Code CLI. Now removes stale MCP registrations before adding fresh ones, preventing issues when upgrading R versions.

</details>

## Demo

Check out this YouTube video for a quick demonstration of what to expect when you use ClaudeR:

[![ClaudeR Demo Video](https://img.youtube.com/vi/KSKcuxRSZDY/0.jpg)](https://youtu.be/KSKcuxRSZDY)

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [How It Works](#how-it-works)
- [CLI Integration](#cli-integration)
- [Security Restrictions](#security-restrictions)
- [Installation](#installation)
- [Usage](#usage)
- [Logging Options](#logging-options)
- [Example Interactions](#example-interactions)
- [Important Notes](#important-notes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [License](#license)
- [Contributing](#contributing)

## Features

ClaudeR empowers your AI assistant with a suite of tools to interact with your R environment:

- **`execute_r`**: Execute R code and return the output.
- **`execute_r_with_plot`**: Execute R code that generates a plot.
- **`execute_r_async`**: Execute long-running R code asynchronously (>25 seconds). Returns a job ID for polling.
- **`get_async_result`**: Poll for the result of an async job. Includes a built-in delay to throttle polling.
- **`list_sessions`**: List all active RStudio sessions the agent can connect to.
- **`connect_session`**: Connect to a specific RStudio session by name for multi-session workflows.
- **`get_session_history`**: View execution history filtered by agent ID.
- **`read_file`**: Read any text file from disk (.R, .qmd, .csv, .log, etc.) without needing it open in RStudio.
- **`get_active_document`**: Get the content of the active document in RStudio.
- **`get_r_info`**: Get information about the R environment.
- **`modify_code_section`**: Modify a specific section of code in the active document.
- **`insert_text`**: Insert text at the current cursor position or a specific line/column in the active document.
- **`get_viewer_content`**: Read HTML content from the viewer pane (plotly, DT, leaflet widgets) with pagination support.
- **`create_task_list`**: Generate a task list based on your prompt to prevent omissions in long-context tasks.
- **`update_task_status`**: Track progress for each task in the generated list.

With these tools, you can:

- **Direct Code Execution**: The AI can write, execute, and install packages in your active RStudio session.
- **Feedback & Assistance**: Get explanations of your R scripts or request edits at specific lines.
- **Visualization**: The AI can generate, view, and refine plots and visualizations.
- **Data Analysis**: Let the AI analyze your datasets and iteratively provide insights.
- **Multi-Agent Workflows**: Run Claude Desktop, Claude Code, and Gemini CLI on the same R session simultaneously. Each agent is uniquely identified, and they can see each other's work through shared history and log files.
- **Long-Running Analysis**: Async execution handles model fitting, simulations, and large data processing without timing out.
- **Code Logging**: Save all code executed by the AI to log files for future reference. Every entry is tagged with the agent that ran it.
- **Console Printing**: Print the AI's code to the console before execution.
- **Environment Integration**: The AI can access variables and functions in your R environment.
- **Dynamic Summaries**: Summaries can dynamically pull results from objects and data frames to safeguard against hallucinations.
- **Quarto Renders**: The AI can create and render Quarto presentations. For best results, ask for a .qmd file and for it to be rendered in HTML when it's finished.

## How It Works

ClaudeR uses the **Model Context Protocol (MCP)** to create a bidirectional connection between an AI assistant and your RStudio environment. MCP is an open protocol from Anthropic that allows the AI to safely interact with local tools and data.

Here's the workflow:
1.  The Python MCP server acts as a bridge.
2.  The AI sends a code execution request to the MCP server.
3.  The server forwards the request to the R add-in running in RStudio.
4.  The code executes in your R session, and the results are sent back to the AI.

This architecture ensures that the AI can only perform approved operations through well-defined interfaces, keeping you in complete control of your R environment.

## CLI Integration

ClaudeR now supports command-line interface (CLI) tools like the **Claude Code CLI**, the **OpenAI Codex CLI**, and the **Google Gemini CLI**. This is ideal for developers who prefer a terminal-based workflow, allowing you to interact with your AI assistant directly from the command line while maintaining a live connection to your RStudio session.

## Security Restrictions

For your safety, ClaudeR implements strict restrictions on code execution:

- **System Commands**: All `system()`, `system2()`, `shell()`, and other methods of executing system commands are **blocked**.
- **File Deletion**: Operations that could delete files (like `unlink()`, `file.remove()`, or system commands containing `rm`) are **prohibited**.
- **Error Messages**: When the AI attempts to run restricted code, the operation is blocked, and a specific error message is returned explaining why.

### Why These Restrictions Matter

1.  **Data Protection**: Prevents accidental deletion or modification of important files.
2.  **Controlled Environment**: Ensures the AI remains a safe tool for collaboration.
3.  **Principle of Least Privilege**: Grants only the necessary permissions for data analysis tasks.
4.  **Predictable Behavior**: Creates clear boundaries for automated actions.

> These restrictions only apply to code executed by the AI. Your manually executed R code is not affected.

## Installation

### Step 1: Install ClaudeR from GitHub

Run this command in your RStudio console:

```R
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")
```

### Step 2: Run the Correct Installer

Choose the option that matches your workflow.

#### Option A: For Desktop Apps (Claude Desktop / Cursor)

This function configures the MCP config file automatically for desktop applications. By default it uses `uvx` to run the `clauder-mcp` PyPI package, which handles all Python dependencies automatically.

```R
# Load the package
library(ClaudeR)

# Run the installer for Claude Desktop
install_clauder()

# Optional: For Cursor users
# install_clauder(for_cursor = TRUE)
```

For users who cannot use `uvx` (e.g. restricted environments), fall back to the legacy Python path method:

```R
library(ClaudeR)
install_clauder(use_uvx = FALSE, python_path = "/path/to/your/python")
```

#### Option B: For CLI Tools (Claude Code / Codex / Gemini)

This non-interactive function generates the exact command or JSON configuration needed for your CLI tool.

```R
library(ClaudeR)

# For Claude Code CLI
install_cli(tools = "claude")

# For OpenAI Codex CLI
install_cli(tools = "codex")

# For Google Gemini CLI
install_cli(tools = "gemini")
```

For users who cannot use `uvx`, fall back to the legacy Python path method:

```R
install_cli(tools = "claude", use_uvx = FALSE, python_path = "/path/to/my/python")
```

After running the function, you must **manually apply the configuration**:
- **For Claude / Codex**: Copy the command printed in the R console and run it in your terminal.
- **For Gemini**: Copy the generated JSON and manually add it to your `gemini.json` settings file.

After setup, **quit and restart** any active Desktop Apps or terminal sessions for the new settings to load.

> **Note**: If you upgrade R versions, re-run `install_cli()` or `install_clauder()` to update the MCP server path. The CLI installer automatically removes stale registrations before adding fresh ones.

## Usage

### Part 1: In RStudio

For **all** workflows, you must first start the ClaudeR server from RStudio.

```r
library(ClaudeR)
claudeAddin()
```

The ClaudeR add-in will appear in your RStudio Viewer pane. Click **"Start Server"**. Keep this window active while using your preferred tool.

![ClaudeR Addin Interface](assets/ui_interface.png)

### Part 2: In Your AI Tool

- **For Desktop Apps**: Open the Claude Desktop App or Cursor and begin your session.
- **For CLI Tools**: Open your terminal and use the `claude` or `gemini` commands to start interacting with your AI assistant.

> Note: You can regain console/active document control by clicking the stop button in the RStudio console. This will disable the Shiny app in the viewer pane, but the server will remain active. To bring the viewer pane back, simply re-run `claudeAddin()`.

## Logging Options

- **Print Code to Console**: See the AI's code in your R console before it runs. The code will be preceded by the header: `### LLM [agent-id] executing the following code ###`.
- **Log Code to File**: Save all executed code to a log file. Each entry is tagged with the agent ID that executed it, so you can trace which AI agent ran what.
- **Custom Log Path**: Specify a custom location for log files.
- **Reproducibility Header**: Each new session log automatically starts with a header containing the date, working directory, and full `sessionInfo()` output (R version, platform, attached/loaded packages). This makes logs self-documenting for reproducibility.
- **Export Clean Script**: Click "Export Clean Script" in the logging panel to produce a runnable `.R` file stripped of all timestamps and log headers. Error blocks are kept as comments so you can see what went wrong. Also callable from the console with `export_log_as_script()`.

Each R session gets its own timestamped log file. Saving the log file with a different name that's actively being edited by the AI automatically creates a new log continuing on from the last command that was executed after being saved.

## Example Interactions

- "I have a dataset named `data` in my environment. Perform exploratory data analysis on it."
- "Load the `mtcars` dataset and create a scatterplot of `mpg` vs. `hp` with a trend line."
- "Fit a linear model to predict `mpg` based on `wt` and `hp`."
- "Generate a correlation matrix for the `iris` dataset and visualize it."
- "I have a qmd file active. Please make a nice quarto presentation on gradient descent. The audience is very technical. Make sure it looks smooth. Save the presentation in /Users/nyk/QuartoDocs/"

If you can do it with R, your AI assistant can too.

## Important Notes

- **Session Persistence**: Variables, data, and functions created by the AI remain in your R session.
- **Code Visibility**: By default, the AI's code is printed to your console.
- **Port Configuration**: The default port is `8787`, but you can change it if needed.
- **Package Installation**: The AI can install packages. Use clear prompts to guide its behavior.

## Troubleshooting

- **Connection Issues**:
    - Ensure your AI tool is configured correctly.
    - Verify the Python path in your `config` or CLI command.
    - Make sure the server is running in the add-in.
    - Restart RStudio if the port is in use.
- **Python Dependency Issues**:
    - **`could not find function install_clauder`**: Restart your R session (`Session -> Restart R`) and try again.
    - **MCP Server Failed to Start**: If using `uvx`, ensure `uv` is installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`). If using the legacy method, this usually means the wrong Python environment was detected. Re-run the installer with the correct `python_path` or switch to `use_uvx = TRUE`.
- **AI Can't See Results**:
    - Ensure the add-in window is open and the server is running.
- **Plots Not Displaying**:
    - Instruct the AI to wrap plot objects in `print()` (e.g., `print(my_plot)`).
    - Tell the AI to use the `execute_r_with_plot` function.
- **Long-Running Code Timing Out**:
    - Ask the AI to use `execute_r_async` for code that takes longer than 25 seconds.
    - The AI will automatically poll for results using `get_async_result`.
    - Async jobs run in a separate R process via `callr` and do **not** have access to your main session's environment. The AI must write self-contained code that uses `saveRDS()` to pass data in and write results out, then loads them back into the main session after the job completes.
- **Server Restart Issues**:
    - If you see an "address already in use" error after restarting the server, it's a UI bug. The server is still active. If you encounter connection issues, switch the port number in the Viewer Pane or restart RStudio.
    - If the AI still can't connect, save your work and click **"Force Kill Server"** in the viewer pane. This will terminate the active RStudio window.
- **Stale MCP Path After R Upgrade**:
    - If tools stop working after upgrading R, re-run `install_cli()` or `install_clauder()` to update the script path.

## Limitations

- Each R session can connect to one Claude Desktop/Cursor app at a time. However, multiple CLI agents (Claude Code, Gemini CLI) can share the same session alongside a Desktop app. To isolate agents, run separate RStudio windows with different session names and ports.
- You can stop the connection to the Shiny UI by clicking the Stop button in the console to make changes alongside the AI, but to stop the connection you will need to restart the RSession.
- R is single-threaded, but async jobs run in a separate process via `callr` so the main session stays responsive. The background process does not share the main session's environment, so async code must be self-contained.

## License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
