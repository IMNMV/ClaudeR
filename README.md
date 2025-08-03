<div align="center">
  <img src="assets/ClaudeR_logo.png" alt="ClaudeR Logo" width="150"/>
  <h1>ClaudeR</h1>
  <p>
    <b>Connect RStudio directly to Claude, Gemini, and other AI assistants for interactive coding and data analysis.</b>
  </p>
  <p>
    <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <a href="https://github.com/IMNMV/ClaudeR/pulls"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome"></a>
  </p>
</div>

---

**ClaudeR** is an R package that forges a direct link between RStudio and AI assistants like Claude Code and Gemini CLI. This enables interactive coding sessions where the AI can execute code in your active RStudio environment and see the results in real-time. Whether you need an autonomous data explorer or a coding collaborator, ClaudeR adapts to your workflow.

This package is also compatible with Cursor and other services that support MCP servers.

## 🎬 Demo

Check out this YouTube video for a quick demonstration of what to expect when you use ClaudeR:

[![ClaudeR Demo Video](https://img.youtube.com/vi/KSKcuxRSZDY/0.jpg)](https://youtu.be/KSKcuxRSZDY)

## 📋 Table of Contents

- [Features](#-features)
- [How It Works](#-how-it-works)
- [CLI Integration](#-cli-integration)
- [Security Restrictions](#-security-restrictions)
- [Installation](#-installation)
- [Usage](#-usage)
- [Logging Options](#-logging-options)
- [Example Interactions](#-example-interactions)
- [Important Notes](#-important-notes)
- [Troubleshooting](#-troubleshooting)
- [Limitations](#-limitations)
- [License](#-license)
- [Contributing](#-contributing)

## ✨ Features

ClaudeR empowers your AI assistant with a suite of tools to interact with your R environment:

- **`execute_r`**: Execute R code and return the output.
- **`execute_r_with_plot`**: Execute R code that generates a plot.
- **`get_active_document`**: Get the content of the active document in RStudio.
- **`get_r_info`**: Get information about the R environment.
- **`modify_code_section`**: Modify a specific section of code in the active document.
- **`create_task_list`**: Generate a task list based on your prompt to prevent omissions in long-context tasks.
- **`update_task_status`**: Track progress for each task in the generated list.

With these tools, you can:

- **Direct Code Execution**: The AI can write, execute, and install packages in your active RStudio session.
- **Feedback & Assistance**: Get explanations of your R scripts or request edits at specific lines.
- **Visualization**: The AI can generate, view, and refine plots and visualizations.
- **Data Analysis**: Let the AI analyze your datasets and iteratively provide insights.
- **Code Logging**: Save all code executed by the AI to log files for future reference.
- **Console Printing**: Print the AI's code to the console before execution.
- **Environment Integration**: The AI can access variables and functions in your R environment.
- **Dynamic Summaries**: Summaries can dynamically pull results from objects and data frames to safeguard against hallucinations.

> **Note**: The AI can create Quarto Presentations. For best results, open an active `.qmd` file and ask for specific updates. This feature is under active development.

## ⚙️ How It Works

ClaudeR uses the **Model Context Protocol (MCP)** to create a bidirectional connection between an AI assistant and your RStudio environment. MCP is an open protocol from Anthropic that allows the AI to safely interact with local tools and data.

Here’s the workflow:
1.  The Python MCP server acts as a bridge.
2.  The AI sends a code execution request to the MCP server.
3.  The server forwards the request to the R add-in running in RStudio.
4.  The code executes in your R session, and the results are sent back to the AI.

This architecture ensures that the AI can only perform approved operations through well-defined interfaces, keeping you in complete control of your R environment.

## 🔌 CLI Integration

ClaudeR now supports command-line interface (CLI) tools like the **Claude Code CLI** and the **Google Gemini CLI**. This is ideal for developers who prefer a terminal-based workflow, allowing you to interact with your AI assistant directly from the command line while maintaining a live connection to your RStudio session.

## 🔒 Security Restrictions

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

## 🚀 Installation

### Step 1: Install ClaudeR from GitHub

Run this command in your RStudio console:

```R
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")
```

### Step 2: Run the Correct Installer

Choose the option that matches your workflow.

#### Option A: For Desktop Apps (Claude Desktop / Cursor)

This function installs the necessary R and Python libraries and configures the `config` file automatically for desktop applications.

```R
# Load the package
library(ClaudeR)

# Run the installer for Claude Desktop
install_clauder()

# Optional: For Cursor users
# install_clauder(for_cursor = TRUE)
```

For **Conda / Virtual Environment** users, provide the full path to your Python executable:

```R
library(ClaudeR)
my_python_path <- "/path/to/your/conda/envs/my_env/bin/python"
install_clauder(python_path = my_python_path)
```

#### Option B: For CLI Tools (Claude Code / Gemini)

This non-interactive function generates the exact command or JSON configuration needed for your CLI tool.

```R
library(ClaudeR)

# For Claude Code CLI
install_cli(tools = "claude")

# For Google Gemini CLI
install_cli(tools = "gemini")
```

For **Conda / Virtual Environment** users, you **must** provide the path to your Python executable:

```R
# Example for Claude with a specific Python path
install_cli(tools = "claude", python_path = "/path/to/my/python")
```

After running the function, you must **manually apply the configuration**:
- **For Claude**: Copy the command printed in the R console and run it in your terminal.
- **For Gemini**: Copy the generated JSON and manually add it to your `gemini.json` settings file.

After setup, **quit and restart** any active Desktop Apps or terminal sessions for the new settings to load.

## 💡 Usage

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

## 📝 Logging Options

- **Print Code to Console**: See the AI's code in your R console before it runs. The code will be preceded by the header: `### LLM executing the following code ###`.
- **Log Code to File**: Save all executed code to a log file.
- **Custom Log Path**: Specify a custom location for log files.

Each R session gets its own timestamped log file. Saving the log file with a different name that's actively being edited by the AI automatically creates a new log continuing on from the last command that was executed after being saved.

## 💬 Example Interactions

- "I have a dataset named `data` in my environment. Perform exploratory data analysis on it."
- "Load the `mtcars` dataset and create a scatterplot of `mpg` vs. `hp` with a trend line."
- "Fit a linear model to predict `mpg` based on `wt` and `hp`."
- "Generate a correlation matrix for the `iris` dataset and visualize it."
- "I have a qmd file active. Please make a nice quarto presentation on gradient descent. The audience is very technical. Make sure it looks smooth. Save the presentation in /Users/nyk/QuartoDocs/"

If you can do it with R, your AI assistant can too.

## 📌 Important Notes

- **Session Persistence**: Variables, data, and functions created by the AI remain in your R session.
- **Code Visibility**: By default, the AI's code is printed to your console.
- **Port Configuration**: The default port is `8787`, but you can change it if needed.
- **Package Installation**: The AI can install packages. Use clear prompts to guide its behavior.

## 🛠️ Troubleshooting

- **Connection Issues**:
    - Ensure your AI tool is configured correctly.
    - Verify the Python path in your `config` or CLI command.
    - Make sure the server is running in the add-in.
    - Restart RStudio if the port is in use.
- **Python Dependency Issues**:
    - **`could not find function install_clauder`**: Restart your R session (`Session -> Restart R`) and try again.
    - **MCP Server Failed to Start**: This usually means the wrong Python environment was detected. Re-run the installer with the correct `python_path`.
- **AI Can't See Results**:
    - Ensure the add-in window is open and the server is running.
- **Plots Not Displaying**:
    - Instruct the AI to wrap plot objects in `print()` (e.g., `print(my_plot)`).
    - Tell the AI to use the `execute_r_with_plot` function.
- **Server Restart Issues**:
    - If you see an "address already in use" error after restarting the server, it's a UI bug. The server is still active. If you encounter connection issues, switch the port number in the Viewer Pane or restart RStudio.
    - If the AI still can't connect, save your work and click **"Force Kill Server"** in the viewer pane. This will terminate the active RStudio window.

## ⚠️ Limitations

- Each R session can connect to one Claude Desktop/Cursor app at a time. However, multiple agents (Claude Code, Gemini CLI, and Claude Desktop app) can interact on a single session together.
- You can stop the connection to the Shiny UI by clicking the Stop button in the console to make changes alongside the AI, but to stop the connection you will need to restart the RSession.

## 📜 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

## 🙌 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.