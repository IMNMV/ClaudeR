# ClaudeR
ClaudeR is an R package that creates a direct connection between RStudio and Claude AI, allowing for interactive coding sessions where Claude can execute code in your active RStudio session and see the results in real-time.

# Features

Direct Code Execution: Claude can write and execute R code in your active RStudio session (including installing packages)
Visualization Creation: Claude can generate, see, and refine plots and visualizations 
Data Analysis: Claude can analyze your datasets and iteratively provide insights
Code Logging: All code executed by Claude can be saved to log files for future reference
Console Printing: Option to print Claude's code to the console before execution
Environment Integration: Claude can access variables and functions in your R environment

# Installation
Prerequisites:

1) R and RStudio: R 4.0+ and RStudio
2) Python 3.8+: For the MCP server component
3) Claude Desktop App: The desktop version of Claude AI

# Step 1: Install R Package Dependencies
```bash
install.packages(c(
  "R6",
  "httpuv",
  "jsonlite", 
  "miniUI",
  "shiny", 
  "base64enc",
  "rstudioapi",
  "devtools"
))
```
# Step 2: Install Python Dependencies

```bash
pip install mcp httpx
```

# Step 3: Install ClaudeR from GitHub
```bash
devtools::install_github("IMNMV/ClaudeR")
```

# Step 4: Configure Claude Desktop
Locate or create the Claude Desktop configuration file:
```bash
Mac: ~/Library/Application Support/Claude/claude_desktop_config.json
Windows: %APPDATA%\Claude\claude_desktop_config.json
```

Add the following to the configuration file:

```bash
{
  "mcpServers": {
    "r-studio": {
      "command": "python",
      "args": ["PATH_TO_REPOSITORY/ClaudeR/inst/scripts/persistent_r_mcp.py"],
      "env": {
        "PYTHONPATH": "PATH_TO_PYTHON_SITE_PACKAGES",
        "PYTHONUNBUFFERED": "1"
      }
    }
  }
}
```

# Usage
Starting the Connection

1) Load the ClaudeR package and start the addin:

```bash
library(ClaudeR)
claudeAddin()
```

2) In the addin interface:

- Click "Start Server" to launch the connection
- Configure logging settings if desired
- Keep the addin window open while using Claude

3) Open Claude Desktop and ask it to execute R code in your session

# Logging Options
The ClaudeR addin provides several logging options:

Print Code to Console: Shows Claude's code in your R console before execution
Log Code to File: Saves all code executed by Claude to a log file
Custom Log Path: Specify where log files should be saved

Each R session gets its own log file with timestamps for all code executed.
