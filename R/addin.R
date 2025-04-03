#' Claude RStudio Connection Addin
#'
#' @param port the local port at which to run the server.
#' @importFrom httpuv startServer
#' @importFrom jsonlite fromJSON toJSON
#' @importFrom shiny observeEvent reactiveValues renderText verbatimTextOutput
#'   actionButton numericInput checkboxInput textInput conditionalPanel
#'   showNotification invalidateLater runGadget paneViewer stopApp
#'   observe tags
#' @importFrom miniUI gadgetTitleBar miniContentPanel miniPage
#' @export

claude_rstudio_addin <- function(port = 8787) {
  # Create reactive values for state
  state <- list(
    running = TRUE,
    last_result = NULL,
    last_error = NULL,
    execution_count = 0
  )

  # Load settings or set defaults
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
  }

  # Create the HTTP server
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

          if (!is.null(body$code)) {
            # Execute the code in the global environment
            result <- execute_code_in_session(body$code, settings)
            state$execution_count <- state$execution_count + 1

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
            body = '{"error": "Missing code parameter"}'
          ))
        }

        # Handle GET requests (status checks)
        if (req$REQUEST_METHOD == "GET") {
          status <- list(
            running = state$running,
            execution_count = state$execution_count
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

  # Create the UI
  ui <- miniPage(
    gadgetTitleBar("Claude RStudio Connection"),
    miniContentPanel(
      tags$h4("Server Status"),
      verbatimTextOutput("serverStatus"),
      tags$hr(),
      tags$h4("Logging Settings"),
      checkboxInput("print_to_console", "Print code to console before execution",
                           value = settings$print_to_console),
      checkboxInput("log_to_file", "Log code to file",
                           value = settings$log_to_file),
      conditionalPanel(
        condition = "input.log_to_file == true",
        textInput("log_file_path", "Log file path",
                         value = settings$log_file_path),
        actionButton("open_log", "Open Log File")
      ),
      tags$hr(),
      tags$h4("Execution Statistics"),
      verbatimTextOutput("executionStats"),
      tags$hr(),
      tags$p("Keep this window open to maintain the connection with Claude.")
    )
  )

  # Create the server function
  server_func <- function(input, output, session) {
    # Update server status
    output$serverStatus <- renderText({
      sprintf("HTTP Server running on http://127.0.0.1:%d", port)
    })

    # Update execution stats
    output$executionStats <- renderText({
      sprintf("Code executions: %d", state$execution_count)
    })

    # Update settings when inputs change
    observeEvent(input$print_to_console, {
      settings$print_to_console <- input$print_to_console
      save_claude_settings(settings)
    })

    observeEvent(input$log_to_file, {
      settings$log_to_file <- input$log_to_file
      save_claude_settings(settings)
    })

    observeEvent(input$log_file_path, {
      settings$log_file_path <- input$log_file_path
      save_claude_settings(settings)
    })

    # Open log file button
    observeEvent(input$open_log, {
      if (file.exists(settings$log_file_path)) {
        if (requireNamespace("rstudioapi", quietly = TRUE)) {
          navigateToFile(settings$log_file_path)
        } else {
          file.show(settings$log_file_path)
        }
      } else {
        showNotification("Log file does not exist yet.", type = "warning")
      }
    })

    # Handle closing the app
    observeEvent(input$done, {
      # Stop the server
      httpuv::stopServer(server)
      state$running <- FALSE

      # Close the app
      stopApp()
    })
  }

  # Run the gadget
  runGadget(ui, server_func, viewer = paneViewer())
}

#' Execute R code in the active RStudio session
#'
#' This function executes the provided R code in the global environment
#' and captures both the result and any output.
#'
#' @param code The R code to execute
#' @param settings The current settings for Claude addin
#' @return A list containing the execution result and metadata

execute_code_in_session <- function(code, settings = NULL) {
  # Default settings if not provided
  if (is.null(settings)) {
    settings <- load_claude_settings()
  }

  # Print code to console if enabled
  if (settings$print_to_console) {
    cat("\n### Claude executing the following code ###\n")
    cat(code, "\n")
    cat("### End of Claude code ###\n\n")
  }

  # Log code to file if enabled
  if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
    log_code_to_file(code, settings$log_file_path)
  }

  # Create a temporary environment for evaluation
  env <- .GlobalEnv

  # Set up plot capture if needed
  plot_file <- NULL
  has_plot <- FALSE

  tryCatch({
    # Create a temporary file for plot capture
    plot_file <- tempfile(fileext = ".png")

    # Capture all output
    output <- utils::capture.output({
      # Open the graphics device
      grDevices::png(filename = plot_file, width = 800, height = 600)

      # Execute the code with the graphics device open
      result <- withVisible(eval(parse(text = code), envir = env))

      # Close the graphics device
      grDevices::dev.off()

      # Check if a plot was created
      has_plot <- file.exists(plot_file) && file.info(plot_file)$size > 100

      # Print the result if it's visible
      if (result$visible) {
        print(result$value)
      }
    })

    # Prepare the response
    response <- list(
      success = TRUE,
      output = paste(output, collapse = "\n")
    )

    # Include the result value if available
    if (exists("result") && !is.null(result$value)) {
      response$result <- if (is.data.frame(result$value)) {
        # For dataframes, convert to a readable format
        list(
          is_dataframe = TRUE,
          dimensions = dim(result$value),
          head = utils::head(result$value, 10)
        )
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
    if (has_plot) {
      # Read the plot file and encode it
      plot_data <- base64enc::base64encode(plot_file)
      response$plot <- list(
        data = plot_data,
        mime_type = "image/png"
      )
    }

    return(response)
  }, error = function(e) {
    # Log the error if logging is enabled
    if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
      log_error_to_file(code, e$message, settings$log_file_path)
    }

    return(list(
      success = FALSE,
      error = e$message
    ))
  }, finally = {
    # Clean up temporary files
    if (!is.null(plot_file) && file.exists(plot_file)) {
      try(file.remove(plot_file), silent = TRUE)
    }
  })
}

#' Log code to file
#'
#' @param code The R code to log
#' @param log_path The path to the log file
#' @return Invisible NULL

log_code_to_file <- function(code, log_path) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Format the log entry
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by Claude:\n%s\n\n", timestamp, code)

  # Create directory if it doesn't exist
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Append to the log file
  cat(log_entry, file = log_path, append = TRUE)

  invisible(NULL)
}

#' Log error to file
#'
#' @param code The R code that caused the error
#' @param error_message The error message
#' @param log_path The path to the log file
#' @return Invisible NULL

log_error_to_file <- function(code, error_message, log_path) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Format the log entry
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by Claude (ERROR):\n%s\n# Error: %s\n\n",
                      timestamp, code, error_message)

  # Create directory if it doesn't exist
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Append to the log file
  cat(log_entry, file = log_path, append = TRUE)

  invisible(NULL)
}

#' Load Claude settings
#'
#' @return A list containing Claude settings
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
