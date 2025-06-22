<table>
<tr>
<td>

# ClaudeR

</td>
<td align="right">
<img src="assets/ClaudeR_logo.png" alt="ClaudeR Logo" width="100"/>
</td>
</tr>
</table>

- ClaudeR is an R package that creates a direct connection between RStudio and Claude AI, allowing for interactive coding sessions where Claude can execute code in your active RStudio session and see the results in real-time.

- It can explore the data autonomously, or be a collaborator. The choice is yours.

- This will also work with Cursor or any service that allows for MCP servers and can run RStudio.

# Features

Claude has the following MCP tools:
- execute_r – Execute R code and return the output.
- execute_r_with_plot – Execute R code that generates a plot.
- get_active_document – Get the content of the active document in RStudio.
- get_r_info – Get information about the R environment.
- modify_code_section – Modify a specific section of code in the active document.

From these, you are able to do the following:

- Direct Code Execution: Claude can write and execute R code in your active RStudio session (including installing packages)
- Feedback/Assistance: Receive explanations of what your current R script does, and/or ask for edits at specific lines.
- Visualization Creation: Claude can generate, see, and refine plots and visualizations 
- Data Analysis: Claude can analyze your datasets and iteratively provide insights
- Code Logging: All code executed by Claude can be saved to log files for future reference
- Console Printing: Option to print Claude's code to the console before execution
- Environment Integration: Claude can access variables and functions in your R environment

* Note: Claude is able to create Quarto Presentations. I recommend opening an active qmd file and asking for specific updates there. It is not perfect but I am actively working on improving this feature.

# How It Works

- ClaudeR leverages the Model Context Protocol (MCP) to create a bidirectional connection between Claude AI and your RStudio environment. 

- MCP is an open protocol developed by Anthropic that allows Claude to safely interact with local tools and data sources.

In this case:

1. The Python MCP server acts as a bridge between Claude and RStudio
2. When Claude wants to execute R code, it sends the request to the MCP server
3. The MCP server forwards this to the R addin running in RStudio
4. The code executes in your R session and results are sent back to Claude

- This architecture ensures Claude can only perform approved operations through well-defined interfaces while maintaining complete control over your R environment.

Check out the youtube video below for a quick example of what to expect when you use it

[![ClaudeR Demo Video](https://img.youtube.com/vi/KSKcuxRSZDY/0.jpg)](https://youtu.be/KSKcuxRSZDY)


# Security Restrictions

For security reasons, ClaudeR implements strict restrictions on code execution:

- **System commands**: All `system()` and `system2()` calls are blocked, `shell()`, and other methods of executing system commands.

- **File deletion**: Operations that could delete files (like `unlink()`, `file.remove()`, or system commands containing `rm`) are prohibited.

- **Error messages**: When Claude attempts to run restricted code, the operation will be blocked and a specific error message will be returned explaining why.

## Why These Restrictions Matter

These security measures exist to protect your system from unintended consequences when using an AI assistant:

1. **Data Protection**: While Claude is designed to be helpful, allowing unrestricted system access could potentially lead to accidental deletion or modification of important files.

2. **Controlled Environment**: By limiting operations to data analysis, visualization, and non-destructive R functions, we ensure Claude remains a safe tool for collaboration.

3. **Principle of Least Privilege**: Following security best practices, Claude is given only the permissions necessary to assist with data analysis tasks, not full system access.

4. **Predictable Behavior**: These restrictions create clear boundaries around what actions can be performed automatically versus what requires manual user intervention.

These restrictions only apply to code executed through the Claude integration. Normal R code you, the human, run directly is not affected by these limitations. If you need to perform restricted operations, you can do so directly in the R console. These restrictions are in place to protect you from any unexpected behavior. Claude is generally safe, but it's always better to be safe than sorry.


# Installation
Prerequisites:

For Claude Desktop App use:

1) R 4.0+ and RStudio
2) Python 3.8+ For the MCP server component
3) Claude Desktop App: The desktop version of Claude AI

For Cursor:

1) R Extension for Visual Studio Code
2) Python 3.8+ For the MCP server component

# Step 1: Install ClaudeR from GitHub
Run this line inside your RStudio console. This command will download and install the ClaudeR package.

```R
if (!require("devtools")) install.packages("devtools")
devtools::install_github("IMNMV/ClaudeR")
```
# Step 2: Run the All-in-One Setup
Now, run the setup function in your RStudio Console. This will install all needed R and Python libraries and automatically configure the config file.

For most users, the script will automatically find your system's Python. Simply run:

```R
# First, load the package into your r session
library(ClaudeR)

# Now, run the installer for Claude Desktop:
install_clauder()

# Optional: If you are a Cursor user:
install_clauder(for_cursor = TRUE)
```


For Conda / Virtual Environment Users:
If you need to use a specific Python from a Conda or virtual environment, you must provide the full path to that Python executable.

```R
library(ClaudeR)

# Define the path to your specific Python
my_python_path <- "/path/to/your/conda/envs/my_env/bin/python"

# Run the installer with that path
install_clauder(python_path = my_python_path)
# Or
install_clauder(for_cursor = TRUE, python_path = my_python_path)
```

The script will guide you through the process. When it's finished, you must completely quit and restart the Claude Desktop and/or Cursor for the new settings to load.

# Usage
After installation, launch the ClaudeR connection from your RStudio console


```r
library(ClaudeR)
claudeAddin()
```

The ClaudeR add-in will appear in your RStudio Viewer pane.

In the addin interface:
![ClaudeR Addin Interface](assets/ui_interface.png)

- Click "Start Server" to launch the connection
- Configure logging settings if desired
- Keep the addin window active while using Claude (you can switch to other views like Files, Plots, Viewers, etc. - just don't hit the stop sign/stop button)

Open Claude Desktop (or Cursor) and ask it to execute R code in your session

# Logging Options
The ClaudeR addin provides several logging options:

- Print Code to Console: Shows Claude's code in your R console before execution
- Log Code to File: Saves all code executed by Claude to a log file
- Custom Log Path: Specify where log files should be saved

Each R session gets its own log file with timestamps for all code executed. All code generated through chats will be saved to a single log file until the R session is restarted.

# Example Interactions
Once connected, you can ask Claude things like:

- "I have a dataset loaded in my env named data, please perform exploratory data analysis on it and run relevant statistical analyses"
- "Load the mtcars dataset and create a scatterplot of mpg vs. hp with a trend line"
- "Fit a linear model to predict mpg based on weight and horsepower"
- "Generate a correlation matrix for the iris dataset and visualize it"
- "Create a function to calculate moving averages of a time series"

All in all, if you (a human) can do it with R, Claude can do it with R. Go nuts with it. 

# Important Notes

- Session Persistence: All variables, data, and functions created by Claude remain in your R session even after you close the connection
- Code Visibility: By default, code executed by Claude is printed to your console for transparency
- Port Configuration: The default port is 8787, but you can change it if needed
- Log Files: Each R session gets its own log file when logging is enabled
- Claude can install packages if you ask it to. Be careful with this - good prompting is very important. By default it tends to try other methods if it fails, but telling it what it should or shouldn't do as part of the initial prompt is good practice.

# Troubleshooting

For Connection Issues:

- Make sure Claude Desktop is properly configured
- Check that the Python path is correct in your config file
- Verify that you've started the server in the addin interface
- Try restarting RStudio if the port is already in use
- Most server issues can be solved by restarting the R session. Make sure to save your work before you do. 

For Python Dependency Issues:

- **"could not find function install_clauder" Error:** If you see this after installing, restart your R session (`Session -> Restart R` or `Cmd/Ctrl + Shift + F10`) and try again. This ensures the newest version of the package is loaded.
- Check that your Python environment is accessible
- **MCP Server Failed to Start in Claude/Cursor:** This usually means the installer picked up a system Python that doesn't have the necessary libraries (`mcp`, `httpx`). Re-run the installer and provide a specific path to the correct Python environment, like a Conda or venv Python, using the `python_path` argument.

    ```R
    install_clauder(python_path = "/path/to/your/conda/envs/my_env/bin/python")
    ```

Claude Can't See Results:

- Make sure the addin is running (the window must stay open)
- Check that the server status shows "Running"
- Verify there are no error messages in the R console

Warnings:

- You may see a warning after installing dev tools, but it won't affect functionality. Bugs still exist, but I will work on fixing them as they arise.


- If you stop the server then re-start it in the same R session, you may see the following:


"Listening on http://127.0.0.1:3071

createTcpServer: address already in use

Error starting HTTP server: Failed to create server"

This is a UI bug. The server is still active, and you can have Claude run code like normal. However, if you run into issues with Claude not being able to connect then the server you will need to switch the port to a different number in the Viewer Pane, or restart RStudio.
If this issue causes Claude to not access the R environment please SAVE your work and click the 'Force Kill Server response' in the viewer pane. This will run the kill command on the backend: 

```bash
kill -9 [PID] 
```

This happens because the MCP server is made within the active R Studio session and thus that port is binded to it. So, by forcing this termination it will also terminate RStudio. It will only terminate the active RStudio window. Other active windows will not be affected. Switching the port number will also fix this issue. 


# Limitations

- The addin window must remain open for the connection to work
- Each R session can only connect to one Claude session at a time

# License
MIT

# Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

  
