#' @title Configure ClaudeR for MCP (Cross-Platform)
#' @description This function automatically configures the Claude Desktop or Cursor
#' app to use the ClaudeR MCP server. It handles path differences
#' for macOS, Windows, and Linux.
#' @param for_cursor Logical. If TRUE, configures for Cursor instead of Claude Desktop.
#'   Defaults to FALSE.
#' @param use_uvx Logical. If TRUE (the default), configures using `uvx clauder-mcp`
#'   which handles Python dependencies automatically. If FALSE, falls back to
#'   finding a Python executable and pointing to the bundled script.
#' @param python_path Optional. Only used when `use_uvx = FALSE`. A character
#'   string specifying the absolute path to the Python executable.
#' @return Invisibly returns the path to the configuration file that was modified.
#' @keywords internal
configure <- function(for_cursor = FALSE, use_uvx = TRUE, python_path = NULL) {
  message("Starting ClaudeR configuration...")

  if (use_uvx) {
    message("Using uvx (recommended). Python dependencies are handled automatically.")
    mcp_command <- "uvx"
    mcp_args <- list("clauder-mcp")
  } else {
    # --- Legacy: Find the Python executable ---
    if (is.null(python_path)) {
      message("No specific Python path provided. Searching system PATH...")
      python_path <- Sys.which("python3")
      if (python_path == "" || !nzchar(python_path)) {
        python_path <- Sys.which("python")
      }
      if (python_path == "" || !nzchar(python_path)) {
        stop("Could not automatically find a Python executable. Please provide the path via the 'python_path' argument in install_clauder().")
      }
    } else {
      if (!file.exists(python_path)) {
        stop(paste("The provided Python path does not exist:", python_path))
      }
      message(paste("Using user-specified Python path:", python_path))
    }
    message(paste("Found Python at:", python_path))

    # --- Find the Python MCP script within the R package ---
    mcp_script_path <- system.file("scripts", "persistent_r_mcp.py", package = "ClaudeR")
    if (mcp_script_path == "") {
      stop("Could not find the MCP script in the ClaudeR package. Please try reinstalling ClaudeR.")
    }
    message(paste("Found MCP script at:", mcp_script_path))

    mcp_command <- unname(python_path)
    mcp_args <- list(mcp_script_path)
  }


  # --- Determine the config file path based on the OS and application ---
  os <- Sys.info()["sysname"]
  config_dir <- ""
  config_file <- "claude_desktop_config.json"

  if (for_cursor) {
    message("Configuring for Cursor...")
    config_file <- "mcp.json"
    if (os == "Darwin")   config_dir <- file.path(Sys.getenv("HOME"), "Library", "Application Support", "Cursor")
    if (os == "Windows")  config_dir <- file.path(Sys.getenv("APPDATA"), "Cursor")
    if (os == "Linux")    config_dir <- file.path(Sys.getenv("HOME"), ".config", "Cursor")
  } else {
    message("Configuring for Claude Desktop...")
    if (os == "Darwin")   config_dir <- file.path(Sys.getenv("HOME"), "Library", "Application Support", "Claude")
    if (os == "Windows")  config_dir <- file.path(Sys.getenv("APPDATA"), "Claude")
    if (os == "Linux")    config_dir <- file.path(Sys.getenv("HOME"), ".config", "Claude")
  }

  if (config_dir == "") {
    stop("Could not determine configuration directory for your operating system.")
  }
  
  config_path <- file.path(config_dir, config_file)
  message(paste("Targeting configuration file:", config_path))


  # --- Create the file and directory if they don't exist ---
  if (!dir.exists(dirname(config_path))) {
    message("Configuration directory not found. Creating it...")
    dir.create(dirname(config_path), recursive = TRUE)
  }
  if (!file.exists(config_path)) {
    message("Configuration file not found. Creating a new one...")
    write("{}", config_path)
  }

  
  # --- Read existing config safely ---
  config <- tryCatch(jsonlite::fromJSON(config_path, simplifyVector = FALSE), error = function(e) list())
  if (!is.list(config)) config <- list()
  if (is.null(config$mcpServers)) config$mcpServers <- list()

  
  # --- Add or update the r-studio server entry ---
  config$mcpServers$`r-studio` <- list(
    command = mcp_command,
    args = mcp_args
  )

  
  # --- Write the updated config back to the file ---
  jsonlite::write_json(config, config_path, pretty = TRUE, auto_unbox = TRUE)

  message("\nConfiguration complete! ✨")
  message("Please completely QUIT and RESTART the Claude Desktop (or Cursor) app.")
  invisible(config_path)
}


#' @title Install and Set Up ClaudeR
#' @description A helper function that installs all necessary R and Python
#'   dependencies, and then automatically configures ClaudeR for the user.
#' @param for_cursor Logical. If TRUE, configures for Cursor. Defaults to FALSE.
#' @param use_uvx Logical. If TRUE (the default), configures using `uvx clauder-mcp`
#'   which handles Python dependencies automatically. If FALSE, falls back to
#'   finding a Python executable and installing dependencies via pip.
#' @param python_path Optional. Only used when `use_uvx = FALSE`. A character
#'   string specifying the absolute path to the Python executable.
#' @param ... Additional arguments passed to `install.packages`.
#' @details This function will:
#'   1. Check for and install required R packages.
#'   2. If `use_uvx = FALSE`, attempt to install required Python packages.
#'   3. Call `configure()` to set up the MCP connection automatically.
#' @export
install_clauder <- function(for_cursor = FALSE, use_uvx = TRUE, python_path = NULL, ...) {
  # --- 1. Install R Dependencies ---
  message("--- Step 1: Checking R dependencies ---")
  r_deps <- c("base64enc", "httpuv", "jsonlite", "miniUI", "rstudioapi", "shiny")
  missing_r_deps <- r_deps[!sapply(r_deps, requireNamespace, quietly = TRUE)]

  if (length(missing_r_deps) > 0) {
    message(paste("Installing missing R packages:", paste(missing_r_deps, collapse = ", ")))
    install.packages(missing_r_deps, ...)
  } else {
    message("All required R dependencies are already installed.")
  }

  if (!use_uvx) {
    # --- 2. Install Python Dependencies (legacy mode) ---
    message("\n--- Step 2: Checking Python dependencies ---")
    if (is.null(python_path)) {
      temp_python_path <- Sys.which("python3")
      if (temp_python_path == "" || !nzchar(temp_python_path)) {
        temp_python_path <- Sys.which("python")
      }
    } else {
      temp_python_path <- python_path
    }

    if (nzchar(temp_python_path)) {
      message(paste("Attempting to install 'mcp' and 'httpx' using pip from:", temp_python_path))
      tryCatch({
        system2(temp_python_path, args = c("-m", "pip", "install", "--upgrade", "mcp", "httpx"))
      }, warning = function(w) {
        message("\nWarning during pip install: ", w$message)
        if (grepl("externally-managed-environment", w$message)) {
          message("This Python is system-managed. If you need to install packages, please use a virtual environment and provide its path to `install_clauder(python_path = ...)`.")
        }
      }, error = function(e) {
        message("\nError during pip install: ", e$message)
      })
    } else {
      warning("Could not find a Python executable. Please install 'mcp' and 'httpx' manually using pip.")
    }
  } else {
    message("\n--- Step 2: Using uvx (recommended) ---")
    message("Python dependencies are handled automatically by uvx. No pip install needed.")
  }

  # --- 3. Run Automatic Configuration ---
  step_num <- if (use_uvx) "Step 3" else "Step 3"
  message(paste0("\n--- ", step_num, ": Running automatic MCP configuration ---"))
  tryCatch({
    ClaudeR:::configure(for_cursor = for_cursor, use_uvx = use_uvx, python_path = python_path)
  }, error = function(e) {
    message("\nConfiguration failed with an error:")
    stop(e$message)
  })

  message("\n----------------------------------------------------")
  message("ClaudeR installation and setup is complete!")
  message("After restarting Claude/Cursor, start the add-in by running:")
  message("  library(ClaudeR)")
  message("  claudeAddin()")
  message("----------------------------------------------------")
}
