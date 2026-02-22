#' @title Install and Set Up ClaudeR for CLI Tools
#' @description An installer that configures ClaudeR to be used with command-line
#'   AI tools like the Claude Code CLI, OpenAI Codex CLI, and Google Gemini CLI.
#'
#'   It follows a simple, non-interactive setup process. It will attempt to
#'   find a system Python automatically, or you can provide a specific path for
#'   custom environments (like Conda).
#'
#' @param tools A character vector specifying which CLI tools to configure.
#'   Can be `"claude"`, `"codex"`, `"gemini"`, or a combination like
#'   `c("claude", "codex")`.
#' @param python_path Optional. A character string specifying the absolute path
#'   to the Python executable to use. If `NULL` (the default), the script will
#'   attempt to find a system Python on the PATH. **This is the recommended
#'   argument for users with specific Conda or virtual environments.**
#' @param ... Additional arguments passed to `install.packages` for any
#'   missing R dependencies.
#' @details This function will:
#'   1. Check for and install required R packages.
#'   2. Attempt to install required Python packages (`mcp`, `httpx`) using the
#'      specified or found Python executable.
#'   3. Provide you with the exact command to run (for Claude/Codex) or the exact
#'      JSON to copy (for Gemini) to complete the setup.
#' @export
install_cli <- function(tools = "claude", python_path = NULL, ...) {
  # --- 1. Parameter Validation ---
  tools <- try(match.arg(tools, choices = c("claude", "codex", "gemini"), several.ok = TRUE), silent = TRUE)
  if (inherits(tools, "try-error")) {
    stop("Invalid 'tools' argument. Please choose 'claude', 'codex', 'gemini', or a combination.", call. = FALSE)
  }

  # --- 2. Check R Dependencies ---
  message("--- Step 1: Checking R dependencies ---")
  r_deps <- c("jsonlite", "httpuv", "shiny", "miniUI", "callr")
  missing_r_deps <- r_deps[!sapply(r_deps, requireNamespace, quietly = TRUE)]

  if (length(missing_r_deps) > 0) {
    message(paste("Installing missing R packages:", paste(missing_r_deps, collapse = ", ")))
    utils::install.packages(missing_r_deps, ...)
  } else {
    message("All required R dependencies are already installed.")
  }

  # --- 3. Find the Python Executable ---
  message("\n--- Step 2: Locating Python executable ---")
  final_python_path <- python_path

  if (is.null(final_python_path)) {
    message("No 'python_path' provided. Searching system PATH...")
    final_python_path <- Sys.which("python3")
    if (final_python_path == "") final_python_path <- Sys.which("python")
    if (final_python_path == "") {
      stop("Could not automatically find a Python executable. For custom environments (like Conda), please provide the path via the 'python_path' argument.", call. = FALSE)
    }
  } else {
    if (!file.exists(final_python_path)) {
      stop(paste("The provided Python path does not exist:", final_python_path), call. = FALSE)
    }
  }
  message(paste("Using Python executable:", final_python_path))

  # --- 4. Install Python Dependencies ---
  message("\n--- Step 3: Installing Python dependencies ---")
  message("Attempting to install 'mcp' and 'httpx' using pip...")
  tryCatch({
    system2(final_python_path, args = c("-m", "pip", "install", "--upgrade", "mcp", "httpx"))
    message("Python dependencies installed successfully.")
  }, warning = function(w) {
    message("\nWarning during pip install: ", w$message)
  }, error = function(e) {
    message("\nError during pip install. Please ensure pip is available or install 'mcp' and 'httpx' manually.", call. = FALSE)
  })

  # --- 5. Generate Final Instructions for the User ---
  message("\n--- Step 4: Final Configuration ---")
  mcp_script_path <- system.file("scripts", "persistent_r_mcp.py", package = "ClaudeR")
  if (mcp_script_path == "") {
    stop("Could not find 'persistent_r_mcp.py'. Please reinstall ClaudeR.", call. = FALSE)
  }

  cat("\n====================================================\n")
  cat("ACTION REQUIRED: Please run the following in your terminal.\n")
  cat("====================================================\n")

  for (tool in tools) {
    if (tool == "claude") {
      remove_string <- 'claude mcp remove r-studio -s user 2>/dev/null'
      add_string <- sprintf(
        'claude mcp add --transport stdio --scope user r-studio -- %s %s',
        shQuote(final_python_path, type = "cmd"),
        shQuote(mcp_script_path, type = "cmd")
      )
      cat("\n--- For Claude Code CLI ---\n")
      cat("Copy and paste this complete command into your terminal:\n\n")
      cat(remove_string, ";", add_string, "\n\n")
    }

    if (tool == "codex") {
      remove_string <- 'codex mcp remove r-studio 2>/dev/null'
      add_string <- sprintf(
        'codex mcp add r-studio -- %s %s',
        shQuote(final_python_path, type = "cmd"),
        shQuote(mcp_script_path, type = "cmd")
      )
      cat("\n--- For OpenAI Codex CLI ---\n")
      cat("Copy and paste this complete command into your terminal:\n\n")
      cat(remove_string, ";", add_string, "\n\n")
    }

    if (tool == "gemini") {
      gemini_config <- list(
        mcpServers = list(
          `r-studio` = list(
            command = final_python_path,
            args = list(mcp_script_path),
            env = list(PYTHONUNBUFFERED = "1")
          )
        )
      )
      gemini_json_string <- jsonlite::toJSON(gemini_config, pretty = TRUE, auto_unbox = TRUE)
      cat("\n--- For Google Gemini CLI ---\n")
      cat("Edit your Gemini settings file (usually at '~/.gemini/settings.json').\n")
      cat("Add or merge the following 'mcpServers' block into that file:\n\n")
      cat(gemini_json_string, "\n\n")
    }
  }

  cat("====================================================\n")
  cat("Setup is complete after you run the commands above.\n")
  cat("====================================================\n\n")

  invisible()
}