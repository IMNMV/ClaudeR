# --- Discovery File System ---
# Allows Python MCP servers to discover active R sessions dynamically.

DISCOVERY_DIR <- file.path(path.expand("~"), ".claude_r_sessions")

write_discovery_file <- function(session_name, port) {
  if (!dir.exists(DISCOVERY_DIR)) dir.create(DISCOVERY_DIR, recursive = TRUE)
  info <- list(
    session_name = session_name,
    port = port,
    pid = Sys.getpid(),
    started_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  )
  jsonlite::write_json(info, file.path(DISCOVERY_DIR, paste0(session_name, ".json")),
                       auto_unbox = TRUE, pretty = TRUE)
}

remove_discovery_file <- function(session_name) {
  f <- file.path(DISCOVERY_DIR, paste0(session_name, ".json"))
  if (file.exists(f)) file.remove(f)
}

cleanup_stale_discovery_files <- function() {
  if (!dir.exists(DISCOVERY_DIR)) return(invisible(NULL))
  files <- list.files(DISCOVERY_DIR, pattern = "\\.json$", full.names = TRUE)
  for (f in files) {
    tryCatch({
      info <- jsonlite::fromJSON(f)
      # signal = 0 checks if PID exists without killing it
      pid_alive <- tools::pskill(info$pid, signal = 0)
      if (!isTRUE(pid_alive)) file.remove(f)
    }, error = function(e) {
      # Corrupted file, remove it
      file.remove(f)
    })
  }
  invisible(NULL)
}

# --- Agent History Environment ---
# Package-level environment for tracking per-agent execution history.
.claude_history_env <- new.env(parent = emptyenv())
.claude_history_env$entries <- list()
.claude_history_env$max_entries <- 500L

# --- Viewer Tracking ---
# Wraps RStudio's viewer to capture the last URL displayed.
.claude_viewer_env <- new.env(parent = emptyenv())
.claude_viewer_env$last_url <- NULL
.claude_viewer_env$original_viewer <- NULL
.claude_viewer_env$suppress <- FALSE

wrap_viewer <- function() {
  orig <- getOption("viewer")
  if (is.function(orig)) {
    .claude_viewer_env$original_viewer <- orig
    options(viewer = function(url, height = NULL) {
      .claude_viewer_env$last_url <- url
      if (isTRUE(.claude_viewer_env$suppress)) {
        # Agent execution: open in browser instead of stealing the viewer pane
        # Ensure file:// prefix so browser can load local temp files
        if (file.exists(url) && !grepl("^(http|file):", url)) {
          url <- paste0("file://", normalizePath(url, winslash = "/"))
        }
        utils::browseURL(url)
      } else {
        .claude_viewer_env$original_viewer(url, height)
      }
    })
  }
}

unwrap_viewer <- function() {
  if (!is.null(.claude_viewer_env$original_viewer)) {
    options(viewer = .claude_viewer_env$original_viewer)
    .claude_viewer_env$original_viewer <- NULL
  }
}

# --- Background Jobs (callr) ---
# Package-level environment for non-blocking async execution.
.claude_bg_jobs <- new.env(parent = emptyenv())

#' Start a background R job via callr
#' @param code R code to execute in a separate process
#' @param job_id Unique identifier for the job
#' @param settings ClaudeR settings list
#' @param agent_id Optional agent identifier
start_background_job <- function(code, job_id, settings = NULL, agent_id = NULL) {
  if (is.null(settings)) settings <- load_claude_settings()

  # Security check
  validation <- validate_code_security(code)
  if (validation$blocked) {
    return(list(success = FALSE, error = validation$reason))
  }

  # Log / print
  if (settings$print_to_console) {
    agent_label <- if (!is.null(agent_id)) paste0(" [", agent_id, "]") else ""
    cat(sprintf("\n### LLM%s submitted async job %s ###\n", agent_label, job_id))
    cat(code, "\n")
    cat("### End of async job code ###\n\n")
  }
  if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
    log_code_to_file(paste0("# [ASYNC JOB ", job_id, "]\n", code), settings$log_file_path, agent_id = agent_id)
  }

  # Launch in a separate R process (skip .Rprofile to avoid startup noise in stderr)
  job <- callr::r_bg(function(code) {
    output_lines <- utils::capture.output({
      result <- withVisible(eval(parse(text = code)))
      if (result$visible) print(result$value)
    })
    list(success = TRUE, output = paste(output_lines, collapse = "\n"))
  }, args = list(code = code), supervise = TRUE, user_profile = FALSE)

  .claude_bg_jobs[[job_id]] <- list(
    process = job,
    started = Sys.time(),
    code = code,
    agent_id = agent_id
  )

  # Record in history
  history_entry <- list(
    timestamp = Sys.time(),
    agent_id = if (!is.null(agent_id)) agent_id else "unknown",
    code = code,
    success = TRUE,
    has_plot = FALSE
  )
  .claude_history_env$entries <- c(.claude_history_env$entries, list(history_entry))

  list(success = TRUE, job_id = job_id)
}

#' Check the status of a background job
#' @param job_id The job identifier to check
check_background_job <- function(job_id) {
  if (!exists(job_id, envir = .claude_bg_jobs)) {
    return(list(status = "not_found"))
  }

  job_info <- .claude_bg_jobs[[job_id]]
  job <- job_info$process

  if (job$is_alive()) {
    elapsed <- as.numeric(difftime(Sys.time(), job_info$started, units = "secs"))
    return(list(status = "running", elapsed_seconds = round(elapsed)))
  }

  # Job finished — get result
  tryCatch({
    result <- job$get_result()
    rm(list = job_id, envir = .claude_bg_jobs)
    return(c(list(status = "complete"), result))
  }, error = function(e) {
    # callr wraps errors — dig out the original message
    err_msg <- if (!is.null(e$parent)) e$parent$message else e$message
    rm(list = job_id, envir = .claude_bg_jobs)
    return(list(status = "complete", success = FALSE, error = err_msg))
  })
}

#' Claude R Studio Add-in using HTTP server
#'
#' @importFrom shiny observeEvent reactiveValues renderText verbatimTextOutput
#'   actionButton numericInput checkboxInput textInput conditionalPanel
#'   showNotification invalidateLater runGadget paneViewer stopApp
#'   observe tags wellPanel
#' @importFrom miniUI gadgetTitleBar miniContentPanel miniPage
#' @importFrom httpuv startServer stopServer
#' @importFrom jsonlite fromJSON toJSON
#' @importFrom rstudioapi navigateToFile
#' @export

claudeAddin <- function() {
  # Create server state
  server_state <- NULL
  running <- FALSE
  execution_count <- 0
  active_session_name <- NULL  # tracks discovery file for cleanup

  # Load settings
  settings <- load_claude_settings()

  # Create a unique log file name for this session if logging is enabled
  if (settings$log_to_file) {
    session_timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
    settings$log_file_path <- file.path(
      dirname(settings$log_file_path),
      paste0("claude_r_session_", session_timestamp, ".R")
    )
    # Save updated settings
    save_claude_settings(settings)

    # Write reproducibility header with session info
    write_log_header(settings$log_file_path)
  }

  # Start HTTP server function
  start_http_server <- function(port) {
    server <- startServer(
      host = "127.0.0.1",
      port = port,
      app = list(
        call = function(req) {
          # Handle POST requests (receiving code from Claude)
          if (req$REQUEST_METHOD == "POST") {
            # Parse the request body
            body_raw <- req$rook.input$read()
            body <- fromJSON(rawToChar(body_raw))

            # --- Check background job status ---
            if (!is.null(body$check_job)) {
              result <- check_background_job(body$check_job)
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            # --- Get viewer content (paginated) ---
            if (!is.null(body$get_viewer)) {
              max_length <- if (!is.null(body$max_length)) as.integer(body$max_length) else 10000L
              offset <- if (!is.null(body$offset)) as.integer(body$offset) else 0L

              last_url <- .claude_viewer_env$last_url
              if (is.null(last_url) || !file.exists(last_url)) {
                result <- list(success = FALSE, error = "No viewer content available.")
              } else {
                html <- paste(readLines(last_url, warn = FALSE), collapse = "\n")
                total <- nchar(html)
                start_pos <- offset + 1L
                end_pos <- min(offset + max_length, total)
                chunk <- if (start_pos > total) "" else substr(html, start_pos, end_pos)
                result <- list(success = TRUE, content = chunk,
                               total_chars = total, offset = offset,
                               returned_chars = nchar(chunk))
              }
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            if (!is.null(body$code)) {
              agent_id <- body$agent_id  # NULL if not provided (backwards compatible)

              # --- Async: launch in background via callr ---
              if (isTRUE(body$async) && !is.null(body$job_id)) {
                result <- start_background_job(body$code, body$job_id, settings, agent_id = agent_id)
                execution_count <<- execution_count + 1
                response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
                return(list(
                  status = 200L,
                  headers = list('Content-Type' = 'application/json'),
                  body = response_body
                ))
              }

              # --- Sync: execute in main session ---
              result <- execute_code_in_session(body$code, settings, agent_id = agent_id)
              execution_count <<- execution_count + 1

              # Return the result as JSON
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)

              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            return(list(
              status = 400L,
              headers = list('Content-Type' = 'application/json'),
              body = '{"error": "Missing code or check_job parameter"}'
            ))
          }

          # Handle GET requests (status checks)
          if (req$REQUEST_METHOD == "GET") {
            agent_ids <- unique(vapply(
              .claude_history_env$entries,
              function(e) e$agent_id, character(1)
            ))
            status <- list(
              running = running,
              execution_count = execution_count,
              connected_agents = agent_ids,
              history_size = length(.claude_history_env$entries),
              session_name = active_session_name,
              log_file_path = if (settings$log_to_file) settings$log_file_path else NULL
            )

            return(list(
              status = 200L,
              headers = list('Content-Type' = 'application/json'),
              body = toJSON(status, auto_unbox = TRUE)
            ))
          }

          # Default response for other request types
          return(list(
            status = 405L,
            headers = list('Content-Type' = 'application/json'),
            body = '{"error": "Method not allowed"}'
          ))
        }
      )
    )
    return(server)
  }

  # UI definition
  ui <- miniPage(
    gadgetTitleBar("Claude R Connection"),
    miniContentPanel(
      tags$style("
        .section-label { font-weight: 600; font-size: 13px; margin-bottom: 8px; color: #555; }
        .well { padding: 12px; margin-bottom: 10px; }
        .status-text { font-family: monospace; font-size: 12px; margin: 4px 0; }
        .btn { margin-right: 4px; }
      "),

      # --- Session ---
      tags$div(class = "section-label",
        "SESSION",
        actionButton("session_help", "?",
          class = "btn-default btn-xs",
          style = "margin-left: 6px; padding: 1px 6px; font-size: 11px; vertical-align: middle;"
        )
      ),
      wellPanel(
        textInput("session_name", "Session Name", value = "default"),
        numericInput("port", "Port", value = 8787, min = 1024, max = 65535),
        verbatimTextOutput("serverStatus"),
        actionButton("startServer", "Start Server", class = "btn-primary btn-sm"),
        actionButton("stopServer", "Stop Server", class = "btn-danger btn-sm"),
        tags$div(style = "display: flex; align-items: center; gap: 6px;",
          checkboxInput("fresh_start", "Fresh start on restart", value = FALSE),
          actionButton("fresh_start_help", "?",
            class = "btn-default btn-xs",
            style = "padding: 1px 6px; font-size: 11px; margin-top: -15px;"
          )
        )
      ),

      # --- Agents ---
      tags$div(class = "section-label",
        "AGENTS",
        actionButton("agents_help", "?",
          class = "btn-default btn-xs",
          style = "margin-left: 6px; padding: 1px 6px; font-size: 11px; vertical-align: middle;"
        )
      ),
      wellPanel(
        verbatimTextOutput("agentInfo")
      ),

      # --- Logging ---
      tags$div(class = "section-label", "LOGGING"),
      wellPanel(
        checkboxInput("print_to_console", "Print code to console before execution",
                             value = settings$print_to_console),
        checkboxInput("log_to_file", "Log code to file",
                             value = settings$log_to_file),
        conditionalPanel(
          condition = "input.log_to_file == true",
          textInput("log_file_path", "Log file path",
                           value = settings$log_file_path),
          actionButton("open_log", "Open Log File", class = "btn-sm"),
          actionButton("export_script", "Export Clean Script", class = "btn-sm")
        )
      ),

      # --- Advanced ---
      tags$div(class = "section-label", "ADVANCED"),
      wellPanel(
        actionButton("kill_process", "Force Kill Server Process", class = "btn-warning btn-sm"),
        tags$br(), tags$br(),
        shiny::helpText("Use only if you're experiencing 'address already in use' errors.")
      )
    )
  )

  # Server function
  server <- function(input, output, session) {
    # State management
    state <- reactiveValues(
      running = FALSE,
      execution_count = 0
    )

    # Update settings reactively
    observe_settings <- function() {
      settings$print_to_console <- input$print_to_console
      settings$log_to_file <- input$log_to_file
      settings$log_file_path <- input$log_file_path
      save_claude_settings(settings)
    }

    # Watch for settings changes
    observeEvent(input$print_to_console, observe_settings())
    observeEvent(input$log_to_file, observe_settings())
    observeEvent(input$log_file_path, observe_settings())

    # Open log file button
    observeEvent(input$open_log, {
      if (file.exists(input$log_file_path)) {
        if (requireNamespace("rstudioapi", quietly = TRUE)) {
          navigateToFile(input$log_file_path)
        } else {
          file.show(input$log_file_path)
        }
      } else {
        showNotification("Log file does not exist yet.", type = "warning")
      }
    })

    # Export clean script button
    observeEvent(input$export_script, {
      if (file.exists(input$log_file_path)) {
        tryCatch({
          out <- export_log_as_script(input$log_file_path)
          showNotification(paste("Exported to:", basename(out)), type = "message")
          if (requireNamespace("rstudioapi", quietly = TRUE)) {
            navigateToFile(out)
          }
        }, error = function(e) {
          showNotification(paste("Export failed:", e$message), type = "error")
        })
      } else {
        showNotification("Log file does not exist yet.", type = "warning")
      }
    })

    # Server status output
    output$serverStatus <- renderText({
      invalidateLater(2000)
      if (state$running) {
        sprintf("Running on http://127.0.0.1:%d", input$port)
      } else {
        "Not running"
      }
    })

    # Agent info output
    output$agentInfo <- renderText({
      invalidateLater(2000)
      entries <- .claude_history_env$entries
      agent_ids <- unique(vapply(entries, function(e) e$agent_id, character(1)))
      n_agents <- length(agent_ids)
      n_exec <- length(entries)

      if (n_agents == 0) {
        "No agents connected yet"
      } else {
        agents_str <- paste(agent_ids, collapse = ", ")
        sprintf("Connected: %s\nExecutions: %d", agents_str, n_exec)
      }
    })

    # Session help popup
    observeEvent(input$session_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Multi-Session & Agent Guide",
        tags$div(
          tags$h5("Single Session (Default)"),
          tags$p("Just click Start Server. AI agents will auto-discover your session."),

          tags$h5("Multiple Sessions"),
          tags$p("To run separate RStudio windows with different AI agents:"),
          tags$ol(
            tags$li(tags$b("Window 1:"), " Set Session Name to e.g. 'analysis', keep port 8787, click Start."),
            tags$li(tags$b("Window 2:"), " Set Session Name to e.g. 'modeling', change port to 8788, click Start."),
            tags$li("Each agent auto-connects to the first available session. To assign an agent to a specific session, tell it: ",
              tags$em("\"Connect to the 'modeling' session using connect_session.\""))
          ),

          tags$h5("Agent Identity"),
          tags$p("Each AI agent is assigned a unique ID (e.g. agent-a3f92b1c) on startup.",
            "All code it executes is logged under that ID.",
            "If you see multiple agent IDs in the Agents panel, multiple AI tools are sharing this R session."),

          tags$h5("Checking Agent Activity"),
          tags$p("Agents can call ", tags$code("get_session_history"),
            " to see what other agents have done.",
            "If logging is enabled, the log file also shows which agent executed each block of code.")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Fresh start help popup
    observeEvent(input$fresh_start_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Fresh Start",
        tags$div(
          tags$p("Check this box before clicking ", tags$b("Start Server"), " to reset the session to a clean state."),
          tags$p("What gets reset:"),
          tags$ul(
            tags$li(tags$b("Log file"), " - a new timestamped log is created with a fresh sessionInfo() header."),
            tags$li(tags$b("Agent history"), " - the execution history is cleared. get_session_history returns empty."),
            tags$li(tags$b("Execution count"), " - resets to 0."),
            tags$li(tags$b("Console history"), " - clears the R console command history.")
          ),
          tags$p("Your R environment (variables, loaded packages) is ", tags$b("not"), " cleared.",
            "To also clear the environment, run ", tags$code("rm(list = ls())"), " before restarting.")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Agents help popup
    observeEvent(input$agents_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Agents Panel",
        tags$div(
          tags$p("This panel shows AI agents that have executed code in the current session."),
          tags$h5("What you'll see"),
          tags$ul(
            tags$li(tags$b("Connected:"), " lists the unique agent IDs (e.g. agent-a3f92b1c) that have run code this session."),
            tags$li(tags$b("Executions:"), " total number of code blocks executed across all agents.")
          ),
          tags$h5("How it works"),
          tags$p("Each AI tool (Claude Code, Codex, Gemini, etc.) is assigned a unique agent ID when it first connects.",
            "If you see multiple IDs, multiple agents are sharing this R session.",
            "They can see each other's work through ", tags$code("get_session_history"), " and the shared log file."),
          tags$p("Use ", tags$b("Fresh start on restart"), " to clear agent history when starting a new task.")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Start server
    observeEvent(input$startServer, {
      if (!state$running) {
        tryCatch({
          # Clean up any stale discovery files from crashed sessions
          cleanup_stale_discovery_files()

          # Fresh start: reset log, agent history, execution count, console history
          if (isTRUE(input$fresh_start)) {
            execution_count <<- 0
            state$execution_count <- 0
            .claude_history_env$entries <- list()

            # Create a new log file
            if (settings$log_to_file) {
              session_timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
              settings$log_file_path <- file.path(
                dirname(settings$log_file_path),
                paste0("claude_r_session_", session_timestamp, ".R")
              )
              save_claude_settings(settings)
              write_log_header(settings$log_file_path)
              updateTextInput(session, "log_file_path", value = settings$log_file_path)
            }

            # Clear R console history
            tryCatch({
              tmp_hist <- tempfile()
              writeLines("", tmp_hist)
              utils::loadhistory(tmp_hist)
              unlink(tmp_hist)
            }, error = function(e) NULL)  # silently skip if not supported

            showNotification("Fresh start: log, history, and agents reset", type = "message")
          }

          server_state <<- start_http_server(input$port)
          running <<- TRUE
          state$running <- TRUE

          # Write discovery file so Python MCP servers can find us
          session_name <- trimws(input$session_name)
          if (session_name == "") session_name <- paste0("session_", input$port)
          active_session_name <<- session_name
          write_discovery_file(session_name, input$port)

          # Wrap viewer to capture HTML widget URLs
          wrap_viewer()

          showNotification("HTTP server started successfully", type = "message")
        }, error = function(e) {
          message("Error starting HTTP server: ", e$message)
          showNotification(
            paste("Failed to start HTTP server:", e$message),
            type = "error"
          )
        })
      }
    })

    # Stop server
    observeEvent(input$stopServer, {
      if (state$running) {
        tryCatch({
          stopServer(server_state)
          running <<- FALSE
          state$running <- FALSE
          server_state <<- NULL

          # Remove discovery file
          if (!is.null(active_session_name)) {
            remove_discovery_file(active_session_name)
            active_session_name <<- NULL
          }

          # Restore original viewer
          unwrap_viewer()

          # Force garbage collection to ensure port is released
          gc()

          showNotification("HTTP server stopped", type = "message")
        }, error = function(e) {
          message("Error stopping server: ", e$message)
          showNotification("Failed to stop server cleanly", type = "error")
        })
      }
    })

    
    # Kill process button handler
    shiny::observeEvent(input$kill_process, {
      # Create a confirmation dialog
      shiny::showModal(shiny::modalDialog(
        title = "Warning: This will restart your R session",
        "Please make sure to save your work before continuing as it will restart the current R session.",
        footer = shiny::tagList(
          shiny::modalButton("Cancel"),
          shiny::actionButton("confirm_kill", "Continue", class = "btn-danger")
        ),
        easyClose = FALSE
      ))
    })
    
    # Handle confirmation of process kill
    shiny::observeEvent(input$confirm_kill, {
      # Close the modal dialog
      shiny::removeModal()
      
      # Proceed with killing the process
      tryCatch({
        # Run system command to find the process using port 8787
        port_to_kill <- input$port
        cmd_result <- system(paste0("lsof -i :", port_to_kill, " | grep LISTEN"), intern = TRUE)
        
        if (length(cmd_result) > 0) {
          # Extract PID from the result (typically the second column)
          pid <- strsplit(cmd_result, "\\s+")[[1]][2]
          
          if (!is.na(pid) && pid != "") {
            # Kill the process
            kill_result <- system(paste0("kill -9 ", pid), intern = TRUE)
            shiny::showNotification(paste0("Process ", pid, " using port ", port_to_kill, " terminated."), type = "message")
            
            # Reset server state
            if (!is.null(server_state)) {
              try(httpuv::stopServer(server_state), silent = TRUE)
              server_state <<- NULL
            }
            running <<- FALSE
            state$running <- FALSE

            # Remove discovery file
            if (!is.null(active_session_name)) {
              remove_discovery_file(active_session_name)
              active_session_name <<- NULL
            }

            # Force garbage collection
            gc()
          } else {
            shiny::showNotification("Could not identify process ID.", type = "warning")
          }
        } else {
          shiny::showNotification(paste0("No process found using port ", port_to_kill), type = "warning")
        }
      }, error = function(e) {
        shiny::showNotification(paste0("Error killing process: ", e$message), type = "error")
      })
    })
    # Update execution count periodically
    observe({
      state$execution_count <- execution_count
      invalidateLater(2000)
    })

    # Close handler
    observeEvent(input$done, {
      if (state$running) {
        tryCatch({
          stopServer(server_state)
          running <<- FALSE
        }, error = function(e) {
          message("Error stopping server: ", e$message)
        })
      }
      # Clean up discovery file and viewer
      if (!is.null(active_session_name)) {
        remove_discovery_file(active_session_name)
        active_session_name <<- NULL
      }
      unwrap_viewer()
      invisible(stopApp())
    })
  }

  runGadget(ui, server, viewer = paneViewer())
}

#' Execute R code in the active RStudio session
#'
#' This function executes the provided R code in the global environment
#' and captures both the result and any output.
#'
#' @param code The R code to execute
#' @param settings The settings list with logging preferences
#' @param agent_id Optional agent identifier for attribution
#' @return A list containing the execution result and metadata
#' @importFrom ggplot2 ggplot aes geom_bar geom_line theme_minimal ggsave
#' @importFrom base64enc base64encode
#' @importFrom grDevices dev.copy dev.list dev.off png jpeg recordPlot
#' @export

execute_code_in_session <- function(code, settings = NULL, agent_id = NULL) {
  # Default settings if not provided
  if (is.null(settings)) {
    settings <- load_claude_settings()
  }

  # Validate the code to block dangerous operations
  validation_result <- validate_code_security(code)
  if (validation_result$blocked) {
    return(list(
      success = FALSE,
      error = validation_result$reason
    ))
  }

  # Print code to console if enabled
  if (settings$print_to_console) {
    agent_label <- if (!is.null(agent_id)) paste0(" [", agent_id, "]") else ""
    cat(sprintf("\n### LLM%s executing the following code ###\n", agent_label))
    cat(code, "\n")
    cat("### End of LLM code ###\n\n")
  }

  # Log code to file if enabled
  if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
    log_code_to_file(code, settings$log_file_path, agent_id = agent_id)
  }

  # Create a temporary environment for evaluation
  env <- .GlobalEnv

  # Set up plot capture files (PNG primary, JPEG fallback)
  plot_file_png <- tempfile(fileext = ".png")
  plot_file_jpeg <- tempfile(fileext = ".jpeg")

  tryCatch({
    # Create a connection to capture output
    output_file <- tempfile()
    sink(output_file, split = TRUE)  # split=TRUE sends output to console AND capture

    # --- BEFORE eval: snapshot device state to detect stale plots ---
    devices_before <- dev.list()
    baseline_plot <- tryCatch(recordPlot(), error = function(e) NULL)

    # Suppress viewer during agent execution so htmlwidgets don't steal the pane
    # Reset last_url so viewer_captured only flags for THIS execution
    .claude_viewer_env$last_url <- NULL
    .claude_viewer_env$suppress <- TRUE
    on.exit(.claude_viewer_env$suppress <- FALSE, add = TRUE)

    # Execute code in the global environment
    result <- withVisible(eval(parse(text = code), envir = env))

    # Print the result if it would be auto-printed in console
    if (result$visible) {
      print(result$value)
    }

    # Stop capturing output
    sink()

    # Read the captured output
    output <- readLines(output_file, warn = FALSE)

    # --- AFTER eval: only capture if a NEW plot was actually created ---
    captured_plot <- FALSE
    plot_data <- NULL
    plot_mime <- "image/png"

    tryCatch({
      # For ggplot objects: always a new plot
      if (inherits(result$value, "ggplot")) {
        # Try PNG first (sharp lines/text, often smaller for plots)
        tryCatch({
          ggsave(plot_file_png, result$value,
                 device = "png", width = 6, height = 4, dpi = 100)
          if (file.exists(plot_file_png) && file.info(plot_file_png)$size > 100) {
            plot_data <- base64encode(plot_file_png)
            plot_mime <- "image/png"
            captured_plot <- TRUE
          }
        }, error = function(e) {
          # JPEG fallback for ggplot
          message("PNG ggsave failed, trying JPEG: ", e$message)
          tryCatch({
            ggsave(plot_file_jpeg, result$value,
                   device = "jpeg", width = 6, height = 4,
                   dpi = 100, quality = 80)
            if (file.exists(plot_file_jpeg) && file.info(plot_file_jpeg)$size > 100) {
              plot_data <<- base64encode(plot_file_jpeg)
              plot_mime <<- "image/jpeg"
              captured_plot <<- TRUE
            }
          }, error = function(e2) {
            message("JPEG ggsave fallback also failed: ", e2$message)
          })
        })
      }
      # For base graphics: only capture if device state actually changed
      else if (!is.null(dev.list())) {
        devices_after <- dev.list()
        current_plot <- tryCatch(recordPlot(), error = function(e) NULL)

        # Determine if a NEW plot was actually drawn by this execution
        new_plot_exists <- FALSE
        if (!identical(devices_before, devices_after)) {
          new_plot_exists <- TRUE
        } else if (!is.null(current_plot) && !identical(current_plot, baseline_plot)) {
          new_plot_exists <- TRUE
        }

        if (new_plot_exists) {
          # Try PNG first (sharp lines/text, often smaller for plots)
          tryCatch({
            dev.copy(png, filename = plot_file_png,
                     width = 600, height = 400)
            dev.off()
            if (file.exists(plot_file_png) && file.info(plot_file_png)$size > 100) {
              plot_data <- base64encode(plot_file_png)
              plot_mime <- "image/png"
              captured_plot <- TRUE
            }
          }, error = function(e) {
            # JPEG fallback for base graphics
            message("PNG dev.copy failed, trying JPEG: ", e$message)
            tryCatch({
              dev.copy(jpeg, filename = plot_file_jpeg,
                       width = 600, height = 400, quality = 80)
              dev.off()
              if (file.exists(plot_file_jpeg) && file.info(plot_file_jpeg)$size > 100) {
                plot_data <<- base64encode(plot_file_jpeg)
                plot_mime <<- "image/jpeg"
                captured_plot <<- TRUE
              }
            }, error = function(e2) {
              message("JPEG fallback also failed: ", e2$message)
            })
          })
        }
      }
    }, error = function(e) {
      message("Note: Could not capture plot: ", e$message)
    })

    # Prepare the response
    response <- list(
      success = TRUE,
      output = paste(output, collapse = "\n")
    )

    # Include the result value if available
    if (exists("result") && !is.null(result$value)) {
      # Add result to response
      response$result <- if (is.data.frame(result$value)) {
        # For dataframes, convert to a readable format
        list(
          is_dataframe = TRUE,
          dimensions = dim(result$value),
          head = utils::head(result$value, 10)
        )
      } else if (inherits(result$value, "ggplot")) {
        # For ggplot objects
        "ggplot object - see plot output"
      } else {
        # For other objects, try to convert to JSON
        tryCatch({
          result$value
        }, error = function(e) {
          as.character(result$value)
        })
      }
    }

    # Include plot if available
    if (captured_plot && !is.null(plot_data)) {
      response$plot <- list(
        data = plot_data,
        mime_type = plot_mime
      )
    }

    # Flag if viewer content was captured (htmlwidgets)
    if (!is.null(.claude_viewer_env$last_url) &&
        file.exists(.claude_viewer_env$last_url)) {
      response$viewer_captured <- TRUE
    }

    # Record to agent history
    history_entry <- list(
      timestamp = Sys.time(),
      agent_id = if (!is.null(agent_id)) agent_id else "unknown",
      code = code,
      success = TRUE,
      has_plot = captured_plot
    )
    .claude_history_env$entries <- c(.claude_history_env$entries, list(history_entry))
    if (length(.claude_history_env$entries) > .claude_history_env$max_entries) {
      .claude_history_env$entries <- tail(.claude_history_env$entries, .claude_history_env$max_entries)
    }

    return(response)
  }, error = function(e) {
    # Make sure to close the sink if there was an error
    if (sink.number() > 0) sink()

    # Log error if logging is enabled
    if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
      log_error_to_file(code, e$message, settings$log_file_path, agent_id = agent_id)
    }

    # Display the error in the console
    cat("Error:", e$message, "\n")

    # Record error to agent history
    history_entry <- list(
      timestamp = Sys.time(),
      agent_id = if (!is.null(agent_id)) agent_id else "unknown",
      code = code,
      success = FALSE,
      has_plot = FALSE
    )
    .claude_history_env$entries <- c(.claude_history_env$entries, list(history_entry))
    if (length(.claude_history_env$entries) > .claude_history_env$max_entries) {
      .claude_history_env$entries <- tail(.claude_history_env$entries, .claude_history_env$max_entries)
    }

    return(list(
      success = FALSE,
      error = e$message
    ))
  }, finally = {
    # Make sure sink is restored
    if (sink.number() > 0) sink()

    # Clean up temporary files
    if (exists("output_file") && file.exists(output_file)) {
      try(file.remove(output_file), silent = TRUE)
    }

    if (!is.null(plot_file_jpeg) && file.exists(plot_file_jpeg)) {
      try(file.remove(plot_file_jpeg), silent = TRUE)
    }

    if (!is.null(plot_file_png) && file.exists(plot_file_png)) {
      try(file.remove(plot_file_png), silent = TRUE)
    }
  })
}

#' Query agent execution history
#'
#' @param agent_filter "all", or a specific agent ID to filter by
#' @param requesting_agent The agent making the request (for context)
#' @param last_n Number of entries to return
#' @return Character string with formatted history

query_agent_history <- function(agent_filter = "all", requesting_agent = NULL, last_n = 20) {
  entries <- .claude_history_env$entries

  if (length(entries) == 0) {
    return("No execution history recorded yet.")
  }

  # Filter by agent if requested
  if (agent_filter != "all") {
    entries <- Filter(function(e) e$agent_id == agent_filter, entries)
  }

  if (length(entries) == 0) {
    return(sprintf("No history found for agent '%s'.", agent_filter))
  }

  # Take last N
  if (length(entries) > last_n) {
    entries <- tail(entries, last_n)
  }

  # Format output
  lines <- vapply(entries, function(e) {
    status <- if (e$success) "OK" else "ERR"
    plot_flag <- if (e$has_plot) " [plot]" else ""
    code_preview <- substr(gsub("\n", " ", e$code), 1, 80)
    sprintf("[%s] %s (%s%s): %s",
            format(e$timestamp, "%H:%M:%S"), e$agent_id, status, plot_flag, code_preview)
  }, character(1))

  paste(lines, collapse = "\n")
}

#' Validate code for security issues
#'
#' @param code The R code to validate
#' @return A list with blocked (logical) and reason (character) fields

validate_code_security <- function(code) {
  # System command calls to block completely
  if (grepl("\\bsystem\\s*\\(", code) ||
      grepl("\\bsystem2\\s*\\(", code) ||
      grepl("\\bshell\\s*\\(", code) ||
      grepl("\\bshell\\.exec\\s*\\(", code)) {
    return(list(
      blocked = TRUE,
      reason = "Security restriction: System command execution is not allowed"
    ))
  }
      
  if (grepl("rstudioapi::terminal", code)) {
    return(list(
      blocked = TRUE,
      reason = "Security restriction: Direct terminal access via `rstudioapi` is disabled."
    ))
  }

  # File deletion via base functions
  file_deletion_patterns <- c(
    "\\bunlink\\s*\\([^)]*['\"]\\*['\"][^)]*\\)",  # unlink("*")
    "\\bunlink\\s*\\([^)]*recursive\\s*=\\s*TRUE[^)]*\\)",
    "\\bunlink\\s*\\([^)]*force\\s*=\\s*TRUE[^)]*\\)",
    "\\bfile\\.remove\\s*\\([^)]*['\"]\\*['\"][^)]*\\)"  # file.remove("*")
  )

  # Check file deletion calls
  for (pattern in file_deletion_patterns) {
    if (grepl(pattern, code, ignore.case = TRUE)) {
      return(list(
        blocked = TRUE,
        reason = paste0("Security restriction: Potentially dangerous file deletion operation detected")
      ))
    }
  }

  # Allow everything else
  return(list(blocked = FALSE))
}

#' Log code to file
#'
#' @param code The R code to log
#' @param log_path The path to the log file
#' @return Invisible NULL

log_code_to_file <- function(code, log_path, agent_id = NULL) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Format the log entry with agent attribution
  agent_label <- if (!is.null(agent_id)) agent_id else "Claude"
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by %s:\n%s\n\n", timestamp, agent_label, code)

  # Create directory if it doesn't exist
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    tryCatch({
      dir.create(log_dir, recursive = TRUE)
    }, error = function(e) {
      warning("Could not create log directory: ", e$message)
      return(invisible(NULL))
    })
  }

  # Append to the log file with better error handling
  tryCatch({
    cat(log_entry, file = log_path, append = TRUE)
    # If this is the first entry, print a confirmation message
    if (!file.exists(log_path) || file.info(log_path)$size < 100) {
      message("Created log file at: ", normalizePath(log_path))
    }
  }, error = function(e) {
    warning("Could not write to log file: ", e$message)
  })

  invisible(NULL)
}

#' Log error to file
#'
#' @param code The R code that caused the error
#' @param error_message The error message
#' @param log_path The path to the log file
#' @return Invisible NULL

log_error_to_file <- function(code, error_message, log_path, agent_id = NULL) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Format the log entry with agent attribution
  agent_label <- if (!is.null(agent_id)) agent_id else "Claude"
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by %s (ERROR):\n%s\n# Error: %s\n\n",
                      timestamp, agent_label, code, error_message)

  # Create directory if it doesn't exist
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Append to the log file
  cat(log_entry, file = log_path, append = TRUE)

  invisible(NULL)
}

#' Write reproducibility header to a new log file
#'
#' Captures sessionInfo(), working directory, and timestamp at the top of the log.
#' Called once when a new log file is created.
#'
#' @param log_path The path to the log file
#' @return Invisible NULL

write_log_header <- function(log_path) {
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Capture sessionInfo as text
  si <- utils::capture.output(utils::sessionInfo())

  header <- paste0(
    "# ============================================================\n",
    "# ClaudeR Session Log\n",
    "# Date: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), "\n",
    "# Working Directory: ", getwd(), "\n",
    "# ============================================================\n",
    "#\n",
    "# Session Info:\n",
    paste0("# ", si, collapse = "\n"), "\n",
    "#\n",
    "# ============================================================\n\n"
  )

  cat(header, file = log_path, append = FALSE)
  invisible(NULL)
}

#' Export a ClaudeR log file as a clean, runnable R script
#'
#' Strips timestamps, agent labels, and comment headers from a session log,
#' leaving only the executed R code. Error blocks are included as comments.
#'
#' @param log_path Path to the ClaudeR session log file. If NULL, uses the
#'   current session's log file from settings.
#' @param output_path Path to write the clean script. If NULL, writes to
#'   the same directory with "_clean.R" suffix.
#' @param include_errors If TRUE (default), include errored code blocks as
#'   comments. If FALSE, skip them entirely.
#' @return The output path (invisibly).
#' @export

export_log_as_script <- function(log_path = NULL, output_path = NULL, include_errors = TRUE) {
  # Default to current session log

  if (is.null(log_path)) {
    settings <- load_claude_settings()
    if (!settings$log_to_file || is.null(settings$log_file_path)) {
      stop("Logging is not enabled. Pass a log_path explicitly.")
    }
    log_path <- settings$log_file_path
  }

  if (!file.exists(log_path)) {
    stop("Log file not found: ", log_path)
  }

  # Default output path
  if (is.null(output_path)) {
    output_path <- sub("\\.R$", "_clean.R", log_path)
    if (output_path == log_path) {
      output_path <- paste0(log_path, "_clean.R")
    }
  }

  lines <- readLines(log_path, warn = FALSE)

  # Parse log into blocks
  # Blocks start with "# --- [timestamp] ---"
  block_starts <- grep("^# --- \\[", lines)

  if (length(block_starts) == 0) {
    message("No code blocks found in log file.")
    return(invisible(output_path))
  }

  # Determine block boundaries
  block_ends <- c(block_starts[-1] - 1, length(lines))

  clean_lines <- character(0)

  # Write a header for the clean script
  clean_lines <- c(
    "# Clean R script exported from ClaudeR session log",
    paste0("# Source: ", basename(log_path)),
    paste0("# Exported: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    ""
  )

  for (i in seq_along(block_starts)) {
    block <- lines[block_starts[i]:block_ends[i]]

    # Check if this is an error block
    is_error <- any(grepl("(ERROR)", block, fixed = TRUE))

    # Extract code lines (skip the header comments)
    # Header lines: "# --- [timestamp] ---", "# Code executed by ...", "# Error: ..."
    code_lines <- block[!grepl("^# --- \\[|^# Code executed by |^# Error: |^#\\s*$", block)]

    # Remove trailing blank lines
    while (length(code_lines) > 0 && code_lines[length(code_lines)] == "") {
      code_lines <- code_lines[-length(code_lines)]
    }

    if (length(code_lines) == 0) next

    if (is_error && include_errors) {
      clean_lines <- c(clean_lines, "# [The following block produced an error]", paste0("# ", code_lines), "")
    } else if (!is_error) {
      clean_lines <- c(clean_lines, code_lines, "")
    }
  }

  writeLines(clean_lines, output_path)
  message("Exported clean script to: ", output_path)
  invisible(output_path)
}

#' Load Claude settings
#'
#' @return A list containing Claude settings
#' @importFrom utils modifyList

load_claude_settings <- function() {
  # Default settings
  default_settings <- list(
    print_to_console = TRUE,
    log_to_file = FALSE,
    log_file_path = file.path(path.expand("~"), "claude_r_logs.R")
  )

  # Try to load settings from a settings file
  settings_file <- file.path(path.expand("~"), ".claude_r_settings.rds")

  if (file.exists(settings_file)) {
    tryCatch({
      settings <- readRDS(settings_file)
      # Merge with defaults to ensure all fields exist
      settings <- modifyList(default_settings, settings)
      return(settings)
    }, error = function(e) {
      return(default_settings)
    })
  } else {
    return(default_settings)
  }
}

#' Save Claude settings
#'
#' @param settings A list containing Claude settings
#' @return Invisible NULL

save_claude_settings <- function(settings) {
  # Save settings to a settings file
  settings_file <- file.path(path.expand("~"), ".claude_r_settings.rds")
  saveRDS(settings, settings_file)
  invisible(NULL)
}
