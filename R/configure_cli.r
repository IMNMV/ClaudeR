#' @title Configure ClaudeR for CLI Tools
#' @description This interactive helper function generates the necessary
#'   configuration for using ClaudeR with command-line AI tools like the Google
#'   Gemini CLI and the Claude Code CLI.
#'
#'   It intelligently tries to find the correct Python executable by first
#'   checking the `reticulate` package's configuration, then searching the
#'   system PATH. It will ask for confirmation before proceeding.
#'
#' @param cli_tool A character string specifying the CLI tool to configure.
#'   Must be either "claude" or "gemini".
#' @param python_path Optional. The absolute path to the Python executable. If
#'   provided, this will bypass the automatic detection and interactive prompts.
#' @return Invisibly prints instructions and configuration details to the console.
#' @export
#' @importFrom utils install.packages
configure_cli <- function(cli_tool = c("claude", "gemini"), python_path = NULL) {
  cli_tool <- match.arg(cli_tool)

  final_python_path <- python_path

  if (is.null(final_python_path)) {
    # --- Interactive Python Path Detection ---
    message("Searching for your Python executable...")
    found_path <- ""

    # 1. Prioritize the 'reticulate' package configuration
    if (requireNamespace("reticulate", quietly = TRUE)) {
      message("Checking your reticulate configuration (this can take a moment)...")
      tryCatch({
        py_config <- reticulate::py_config()
        if (!is.null(py_config$python) && file.exists(py_config$python)) {
          found_path <- py_config$python
        }
      }, error = function(e) {
        message("Could not get path from reticulate, will check system PATH.")
      })
    } else {
       message("Install 'reticulate' for better Python detection? [y/N]")
       if(tolower(readline()) == 'y') install.packages("reticulate")
    }

    # 2. Fallback to system PATH if reticulate doesn't yield a path
    if (found_path == "") {
      message("Checking system PATH for python3...")
      found_path <- Sys.which("python3")
      if (found_path == "") {
        message("Checking system PATH for python...")
        found_path <- Sys.which("python")
      }
    }

    # 3. Interactive Confirmation Loop
    if (found_path == "") {
      stop("Could not automatically find Python. Please re-run the function specifying the path, e.g., configure_cli(python_path = '/path/to/your/python')", call. = FALSE)
    }

    while (TRUE) {
      cat("\n----------------------------------------------------\n")
      cat("I found a Python executable at this location:\n")
      cat("  ", found_path, "\n")
      cat("----------------------------------------------------\n")
      answer <- readline("Is this the correct Python to use with your CLI tool? [Y/n/m(anual)] ")
      answer <- tolower(trimws(answer))

      if (answer %in% c("y", "")) {
        final_python_path <- found_path
        break
      } else if (answer == "n") {
        stop("Operation cancelled. Please re-run the function and specify the correct path using the 'python_path' argument.", call. = FALSE)
      } else if (answer == "m") {
        manual_path <- readline("Please enter the full, absolute path to your Python executable: ")
        if (file.exists(manual_path)) {
          found_path <- manual_path
          # Loop will repeat to confirm the manually entered path
        } else {
          message("That file path does not exist. Please try again.")
        }
      } else {
        message("Invalid input. Please enter Y, n, or m.")
      }
    }
  }

  message(paste("Using Python path:", final_python_path))

  # --- Find the MCP Script Path ---
  mcp_script_path <- system.file("scripts", "persistent_r_mcp.py", package = "ClaudeR")
  if (mcp_script_path == "") {
    stop("Could not find 'persistent_r_mcp.py'. Please try reinstalling ClaudeR.", call. = FALSE)
  }
  message(paste("Found MCP script at:", mcp_script_path))

  # --- Generate and Print Final Instructions ---
  cat("\n====================================================\n")
  cat("Success! Here is your final configuration command.\n")
  cat("====================================================\n")
  cat("1. Ensure the ClaudeR Add-in is running in RStudio.\n\n")
  cat(paste0("2. Open your terminal and run the following command to configure '", cli_tool, "':\n\n"))

  if (cli_tool == "claude") {
    claude_command <- sprintf(
      'claude mcp add r-studio --scope user %s %s',
      shQuote(final_python_path, type = "cmd"),
      shQuote(mcp_script_path, type = "cmd")
    )
    cat("--- Claude Code CLI Setup ---\n")
    cat("Copy and paste this into your terminal:\n\n")
    cat(claude_command, "\n\n")

  } else if (cli_tool == "gemini") {
    gemini_config <- list(
      mcpServers = list(
        `r-studio` = list(
          command = final_python_path,
          args = list(mcp_script_path),
          env = list(PYTHONUNBUFFERED = "1")
        )
      )
    )
    # To avoid overwriting other settings, we show how to merge
    gemini_json_string <- jsonlite::toJSON(gemini_config, pretty = TRUE, auto_unbox = TRUE)

    cat("--- Google Gemini CLI Setup ---\n")
    cat("Edit your Gemini settings file (usually at '~/.gemini/settings.json').\n")
    cat("Add or merge the following 'mcpServers' block into that file:\n")
    cat("(Make sure the final file is still valid JSON)\n\n")
    cat(gemini_json_string, "\n\n")
  }

  cat("3. You can now use the CLI tool to interact with your R session.\n")
  cat("====================================================\n\n")

  invisible()
}