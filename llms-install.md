# ClaudeR Installation Guide for AI Agents

This guide provides explicit instructions for installing the ClaudeR package and its dependencies.

## Prerequisites

The target environment must have:
1.  R (version 4.0 or later) installed.
2.  Python (version 3.8 or later) installed and available in the system's PATH.
3.  The `devtools` R package installed. If not present, it can be installed by running `install.packages("devtools")` in R.

## Installation Steps

Execute the following commands in an R environment (e.g., via `Rscript -e "..."` from your terminal).

### Step 1: Install the ClaudeR Package from GitHub

```R
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")
```

### Step 2: Run the Setup Function for Your AI Tool

Ask the user which CLI agent they want to install for (Claude Code, Codex, or Gemini), then run the matching command:

**For Claude Code CLI:**
```R
library(ClaudeR)
install_cli(tools = "claude")
```

**For OpenAI Codex CLI:**
```R
library(ClaudeR)
install_cli(tools = "codex")
```

**For Google Gemini CLI:**
```R
library(ClaudeR)
install_cli(tools = "gemini")
```

**For Claude Desktop or Cursor (desktop apps, not CLI):**
```R
library(ClaudeR)
install_clauder()
# For Cursor: install_clauder(for_cursor = TRUE)
```

Each function prints the exact command or config you need to apply. For CLI tools, copy and run the printed command in your terminal. For Gemini, copy the JSON into your `gemini.json` settings file.

### Step 3: Start the Server in RStudio (Manual Step)

The user must run this in RStudio — it cannot be done from a terminal:

```R
library(ClaudeR)
claudeAddin()
```

Then click **"Start Server"** in the viewer pane. The MCP server will now accept connections from AI agents.
