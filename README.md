<div align="center">
  <img src="assets/ClaudeR_logo.png" alt="ClaudeR Logo" width="150"/>
  <h1>ClaudeR</h1>
  <p>
    <b>Connect RStudio directly to Claude AI for interactive coding and data analysis.</b>
  </p>
  <p>
    <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <a href="https://github.com/IMNMV/ClaudeR/pulls"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome"></a>
  </p>
</div>

---

**ClaudeR** is an R package that forges a direct link between RStudio and Claude AI. This enables interactive coding sessions where Claude can execute code in your active RStudio environment and see the results in real-time. Whether you need an autonomous data explorer or a coding collaborator, ClaudeR adapts to your workflow.

This package is also compatible with Cursor and other services that support MCP servers and can run RStudio.

## 🎬 Demo

Check out this YouTube video for a quick demonstration of what to expect when you use ClaudeR:

[![ClaudeR Demo Video](https://img.youtube.com/vi/KSKcuxRSZDY/0.jpg)](https://youtu.be/KSKcuxRSZDY)

## 📋 Table of Contents

- [Features](#-features)
- [How It Works](#-how-it-works)
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

ClaudeR empowers Claude with a suite of tools to interact with your R environment:

- **`execute_r`**: Execute R code and return the output.
- **`execute_r_with_plot`**: Execute R code that generates a plot.
- **`get_active_document`**: Get the content of the active document in RStudio.
- **`get_r_info`**: Get information about the R environment.
- **`modify_code_section`**: Modify a specific section of code in the active document.
- **`create_task_list`**: Generate a task list based on your prompt to prevent omissions in long-context tasks.
- **`update_task_status`**: Track progress for each task in the generated list.

With these tools, you can:

- **Direct Code Execution**: Claude can write, execute, and install packages in your active RStudio session.
- **Feedback & Assistance**: Get explanations of your R scripts or request edits at specific lines.
- **Visualization**: Claude can generate, view, and refine plots and visualizations.
- **Data Analysis**: Let Claude analyze your datasets and iteratively provide insights.
- **Code Logging**: Save all code executed by Claude to log files for future reference.
- **Console Printing**: Print Claude's code to the console before execution.
- **Environment Integration**: Claude can access variables and functions in your R environment.
- **Dynamic Summaries**: Summaries can dynamically pull results from objects and data frames to safeguard against hallucinations.

> **Note**: Claude can create Quarto Presentations. For best results, open an active `.qmd` file and ask for specific updates. This feature is under active development.

## ⚙️ How It Works

ClaudeR uses the **Model Context Protocol (MCP)** to create a bidirectional connection between Claude AI and your RStudio environment. MCP is an open protocol from Anthropic that allows Claude to safely interact with local tools and data.

Here’s the workflow:
1.  The Python MCP server acts as a bridge.
2.  Claude sends a code execution request to the MCP server.
3.  The server forwards the request to the R add-in running in RStudio.
4.  The code executes in your R session, and the results are sent back to Claude.

This architecture ensures that Claude can only perform approved operations through well-defined interfaces, keeping you in complete control of your R environment.

## 🔒 Security Restrictions

For your safety, ClaudeR implements strict restrictions on code execution:

- **System Commands**: All `system()`, `system2()`, `shell()`, and other methods of executing system commands are **blocked**.
- **File Deletion**: Operations that could delete files (like `unlink()`, `file.remove()`, or system commands containing `rm`) are **prohibited**.
- **Error Messages**: When Claude attempts to run restricted code, the operation is blocked, and a specific error message is returned explaining why.

### Why These Restrictions Matter

1.  **Data Protection**: Prevents accidental deletion or modification of important files.
2.  **Controlled Environment**: Ensures Claude remains a safe tool for collaboration.
3.  **Principle of Least Privilege**: Grants only the necessary permissions for data analysis tasks.
4.  **Predictable Behavior**: Creates clear boundaries for automated actions.

> These restrictions only apply to code executed by Claude. Your manually executed R code is not affected.

## 🚀 Installation

### Prerequisites

- **For Claude Desktop App**:
    1.  R 4.0+ and RStudio
    2.  Python 3.8+
    3.  Claude Desktop App
- **For Cursor**:
    1.  R Extension for Visual Studio Code
    2.  Python 3.8+

### Step 1: Install ClaudeR from GitHub

Run this command in your RStudio console:

```R
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")
```

### Step 2: Run the All-in-One Setup

This function installs the necessary R and Python libraries and configures the `config` file automatically.

For most users:

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

# Define the path to your Python executable
my_python_path <- "/path/to/your/conda/envs/my_env/bin/python"

# Run the installer with the specified path
install_clauder(python_path = my_python_path)
# Or for Cursor:
# install_clauder(for_cursor = TRUE, python_path = my_python_path)
```

After the script finishes, **quit and restart** Claude Desktop and/or Cursor for the new settings to load.

## 💡 Usage

Launch the ClaudeR connection from your RStudio console:

```r
library(ClaudeR)
claudeAddin()
```

The ClaudeR add-in will appear in your RStudio Viewer pane.

![ClaudeR Addin Interface](assets/ui_interface.png)

- Click **"Start Server"** to launch the connection.
- Configure logging settings as desired.
- Keep the add-in window active while using Claude.

Now, open Claude Desktop or Cursor and start asking it to execute R code!

Note: You can gain console/active document control by clicking the stop button in the console window. This will disable the shiny app in the viewer pane made by claudeAddin(), but the server will remain active. To bring the viewer pane back, simply re-run claudeAddin().

## 📝 Logging Options

- **Print Code to Console**: See Claude's code in your R console before it runs.
- **Log Code to File**: Save all executed code to a log file.
- **Custom Log Path**: Specify a custom location for log files.

Each R session gets its own timestamped log file.
Saving the log file with a different name that's actively being edited by Claude automatically creates a new log continuing on from the last command that was executed after being saved.

## 💬 Example Interactions

- "I have a dataset named `data` in my environment. Perform exploratory data analysis on it."
- "Load the `mtcars` dataset and create a scatterplot of `mpg` vs. `hp` with a trend line."
- "Fit a linear model to predict `mpg` based on `wt` and `hp`."
- "Generate a correlation matrix for the `iris` dataset and visualize it."
- "I have a qmd file active. Please make a nice quarto presentation on gradient descent. The audience is very technical. Make sure it looks smooth. Save the presentation in /Users/nyk/QuartoDocs/"

If you can do it with R, Claude (or any other LLM you're using Cursor with) can too.

## 📌 Important Notes

- **Session Persistence**: Variables, data, and functions created by Claude remain in your R session.
- **Code Visibility**: By default, Claude's code is printed to your console.
- **Port Configuration**: The default port is `8787`, but you can change it if needed.
- **Package Installation**: Claude can install packages. Use clear prompts to guide its behavior.

## 🛠️ Troubleshooting

- **Connection Issues**:
    - Ensure Claude Desktop is configured correctly.
    - Verify the Python path in your `config` file.
    - Make sure the server is running in the add-in.
    - Restart RStudio if the port is in use.
- **Python Dependency Issues**:
    - **`could not find function install_clauder`**: Restart your R session (`Session -> Restart R`) and try again.
    - **MCP Server Failed to Start**: This usually means the wrong Python environment was detected. Re-run `install_clauder()` with the correct `python_path`.
- **Claude Can't See Results**:
    - Ensure the add-in window is open and the server is running.
- **Plots Not Displaying**:
    - Instruct Claude to wrap plot objects in `print()` (e.g., `print(my_plot)`).
    - Tell Claude to use the `execute_r_with_plot` function.
- **Server Restart Issues**:
    - If you see an "address already in use" error after restarting the server, it's a UI bug. The server is still active. If you encounter connection issues, switch the port number in the Viewer Pane or restart RStudio.
    - If Claude still can't connect, save your work and click **"Force Kill Server"** in the viewer pane. This will terminate the active RStudio window.

## ⚠️ Limitations

- Each R session can only connect to one Claude session at a time.
- You can stop the connection to the Shiny UI by clicking the Stop button in the console to make changes alongside Claude, but to stop the connection you will need to restart the RSession. 

## 📜 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

## 🙌 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
