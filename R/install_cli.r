#' @title Install and Set Up ClaudeR for CLI Tools
#' @description An installer that configures ClaudeR to be used with command-line
#'   AI tools like the Claude Code CLI, OpenAI Codex CLI, and Google Gemini CLI.
#'
#'   By default, it uses `uvx` to run the `clauder-mcp` PyPI package, which
#'   handles all Python dependencies automatically. No Python path or pip
#'   install needed.
#'
#' @param tools A character vector specifying which CLI tools to configure.
#'   Can be `"claude"`, `"codex"`, `"gemini"`, or a combination like
#'   `c("claude", "codex")`.
#' @param use_uvx Logical. If `TRUE` (the default), generates commands using
#'   `uvx clauder-mcp` which handles Python dependencies automatically. If
#'   `FALSE`, falls back to the legacy method of finding a Python executable
#'   and pointing to the bundled script.
#' @param python_path Optional. Only used when `use_uvx = FALSE`. A character
#'   string specifying the absolute path to the Python executable.
#' @param ... Additional arguments passed to `install.packages` for any
#'   missing R dependencies.
#' @details This function will:
#'   1. Check for and install required R packages.
#'   2. Provide you with the exact command to run (for Claude/Codex) or the exact
#'      JSON to copy (for Gemini) to complete the setup.
#' @export
install_cli <- function(tools = "claude", use_uvx = TRUE, python_path = NULL, ...) {
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

  # --- 3. Resolve the MCP server command ---
  if (use_uvx) {
    message("\n--- Step 2: Using uvx (recommended) ---")
    message("The 'clauder-mcp' PyPI package handles all Python dependencies automatically.")
    mcp_command <- "uvx"
    mcp_args <- "clauder-mcp"
  } else {
    message("\n--- Step 2: Locating Python executable (legacy mode) ---")
    final_python_path <- python_path

    if (is.null(final_python_path)) {
      message("No 'python_path' provided. Searching system PATH...")
      final_python_path <- Sys.which("python3")
      if (final_python_path == "") final_python_path <- Sys.which("python")
      if (final_python_path == "") {
        stop("Could not automatically find a Python executable. Provide the path via 'python_path' or use use_uvx = TRUE.", call. = FALSE)
      }
    } else {
      if (!file.exists(final_python_path)) {
        stop(paste("The provided Python path does not exist:", final_python_path), call. = FALSE)
      }
    }
    message(paste("Using Python executable:", final_python_path))

    # Install Python dependencies
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

    mcp_script_path <- system.file("scripts", "persistent_r_mcp.py", package = "ClaudeR")
    if (mcp_script_path == "") {
      stop("Could not find 'persistent_r_mcp.py'. Please reinstall ClaudeR.", call. = FALSE)
    }

    mcp_command <- final_python_path
    mcp_args <- mcp_script_path
  }

  # --- 4. Generate Final Instructions ---
  step_num <- if (use_uvx) "Step 3" else "Step 4"
  message(paste0("\n--- ", step_num, ": Final Configuration ---"))

  cat("\n====================================================\n")
  cat("ACTION REQUIRED: Please run the following in your terminal.\n")
  cat("====================================================\n")

  for (tool in tools) {
    if (tool == "claude") {
      remove_string <- 'claude mcp remove r-studio -s user 2>/dev/null'
      if (use_uvx) {
        add_string <- 'claude mcp add --transport stdio --scope user r-studio -- uvx clauder-mcp'
      } else {
        add_string <- sprintf(
          'claude mcp add --transport stdio --scope user r-studio -- %s %s',
          shQuote(mcp_command, type = "cmd"),
          shQuote(mcp_args, type = "cmd")
        )
      }
      cat("\n--- For Claude Code CLI ---\n")
      cat("Copy and paste this complete command into your terminal:\n\n")
      cat(remove_string, ";", add_string, "\n\n")
    }

    if (tool == "codex") {
      remove_string <- 'codex mcp remove r-studio 2>/dev/null'
      if (use_uvx) {
        add_string <- 'codex mcp add r-studio -- uvx clauder-mcp'
      } else {
        add_string <- sprintf(
          'codex mcp add r-studio -- %s %s',
          shQuote(mcp_command, type = "cmd"),
          shQuote(mcp_args, type = "cmd")
        )
      }
      cat("\n--- For OpenAI Codex CLI ---\n")
      cat("Copy and paste this complete command into your terminal:\n\n")
      cat(remove_string, ";", add_string, "\n\n")
    }

    if (tool == "gemini") {
      if (use_uvx) {
        gemini_config <- list(
          mcpServers = list(
            `r-studio` = list(
              command = "uvx",
              args = list("clauder-mcp")
            )
          )
        )
      } else {
        gemini_config <- list(
          mcpServers = list(
            `r-studio` = list(
              command = mcp_command,
              args = list(mcp_args),
              env = list(PYTHONUNBUFFERED = "1")
            )
          )
        )
      }
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
