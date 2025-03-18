#' @importFrom shiny observeEvent reactiveValues renderText
#' @importFrom miniUI miniPage gadgetTitleBar miniContentPanel
#' @importFrom httpuv startServer stopServer
#' @importFrom jsonlite fromJSON toJSON
#' @importFrom base64enc base64encode

#' Claude R Studio Add-in using HTTP server
#' @export
claudeAddin <- function() {
  # Create server state
  server_state <- NULL
  running <- FALSE
  execution_count <- 0
  
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
  }

  # Start HTTP server function
  start_http_server <- function(port) {
    server <- httpuv::startServer(
      host = "127.0.0.1",
      port = port,
      app = list(
        call = function(req) {
          # Handle POST requests (receiving code from Claude)
          if (req$REQUEST_METHOD == "POST") {
            # Parse the request body
            body_raw <- req$rook.input$read()
            body <- jsonlite::fromJSON(rawToChar(body_raw))
            
            if (!is.null(body$code)) {
              # Execute the code in the global environment
              result <- execute_code_in_session(body$code, settings)
              execution_count <<- execution_count + 1
              
              # Return the result as JSON
              response_body <- jsonlite::toJSON(result, auto_unbox = TRUE, force = TRUE)
              
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
              running = running,
              execution_count = execution_count
            )
            
            return(list(
              status = 200L,
              headers = list('Content-Type' = 'application/json'),
              body = jsonlite::toJSON(status, auto_unbox = TRUE)
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
  ui <- miniUI::miniPage(
    miniUI::gadgetTitleBar("Claude R Connection"),
    miniUI::miniContentPanel(
      shiny::tags$h4("Server Status"),
      shiny::verbatimTextOutput("serverStatus"),
      shiny::tags$hr(),
      shiny::tags$h4("Connection Settings"),
      shiny::numericInput("port", "Port", value = 8787, min = 1024, max = 65535),
      shiny::tags$hr(),
      shiny::tags$h4("Logging Settings"),
      shiny::checkboxInput("print_to_console", "Print code to console before execution",
                           value = settings$print_to_console),
      shiny::checkboxInput("log_to_file", "Log code to file",
                           value = settings$log_to_file),
      shiny::conditionalPanel(
        condition = "input.log_to_file == true",
        shiny::textInput("log_file_path", "Log file path",
                         value = settings$log_file_path),
        shiny::actionButton("open_log", "Open Log File")
      ),
      shiny::tags$hr(),
      shiny::tags$h4("Execution Statistics"),
      shiny::verbatimTextOutput("executionStats"),
      shiny::tags$hr(),
      shiny::actionButton("startServer", "Start Server", class = "btn-primary"),
      shiny::actionButton("stopServer", "Stop Server", class = "btn-danger")
    )
  )
  
  # Server function
  server <- function(input, output, session) {
    # State management
    state <- shiny::reactiveValues(
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
    shiny::observeEvent(input$print_to_console, observe_settings())
    shiny::observeEvent(input$log_to_file, observe_settings())
    shiny::observeEvent(input$log_file_path, observe_settings())
    
    # Open log file button
    shiny::observeEvent(input$open_log, {
      if (file.exists(input$log_file_path)) {
        if (requireNamespace("rstudioapi", quietly = TRUE)) {
          rstudioapi::navigateToFile(input$log_file_path)
        } else {
          file.show(input$log_file_path)
        }
      } else {
        shiny::showNotification("Log file does not exist yet.", type = "warning")
      }
    })
    
    # Update execution stats
    output$executionStats <- shiny::renderText({
      sprintf("Code executions: %d", state$execution_count)
    })
    
    # Server status output
    output$serverStatus <- shiny::renderText({
      if (state$running) {
        sprintf("HTTP Server running on http://127.0.0.1:%d", input$port)
      } else {
        "Server is not running"
      }
    })
    
    # Start server
    shiny::observeEvent(input$startServer, {
      if (!state$running) {
        tryCatch({
          server_state <<- start_http_server(input$port)
          running <<- TRUE
          state$running <- TRUE
          shiny::showNotification("HTTP server started successfully", type = "message")
        }, error = function(e) {
          message("Error starting HTTP server: ", e$message)
          shiny::showNotification(
            paste("Failed to start HTTP server:", e$message),
            type = "error"
          )
        })
      }
    })
    
    # Stop server
    shiny::observeEvent(input$stopServer, {
      if (state$running) {
        tryCatch({
          httpuv::stopServer(server_state)
          running <<- FALSE
          state$running <- FALSE
          server_state <<- NULL
          
          # Force garbage collection to ensure port is released
          gc()
          
          shiny::showNotification("HTTP server stopped", type = "message")
        }, error = function(e) {
          message("Error stopping server: ", e$message)
          shiny::showNotification("Failed to stop server cleanly", type = "error")
        })
      }
    })
    
    # Update execution count periodically
    shiny::observe({
      state$execution_count <- execution_count
      shiny::invalidateLater(1000)
    })
    
    # Close handler
    shiny::observeEvent(input$done, {
      if (state$running) {
        tryCatch({
          httpuv::stopServer(server_state)
          running <<- FALSE
        }, error = function(e) {
          message("Error stopping server: ", e$message)
        })
      }
      invisible(shiny::stopApp())
    })
  }
  
  shiny::runGadget(ui, server, viewer = shiny::paneViewer())
}

#' Execute R code in the active RStudio session
#'
#' This function executes the provided R code in the global environment
#' and captures both the result and any output.
#'
#' @param code The R code to execute
#' @param settings The settings list with logging preferences
#' @return A list containing the execution result and metadata
#' @export
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
  
  # Set up plot capture
  plot_file <- tempfile(fileext = ".png")
  
  tryCatch({
    # Create a connection to capture output
    output_file <- tempfile()
    sink(output_file, split = TRUE)  # split=TRUE sends output to console AND capture
    
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
    
    # Try to capture any plots that were created
    captured_plot <- FALSE
    plot_data <- NULL
    
    tryCatch({
      # For ggplot objects
      if (inherits(result$value, "ggplot")) {
        # Save ggplot to file
        ggplot2::ggsave(plot_file, result$value, width = 8, height = 6)
        if (file.exists(plot_file) && file.info(plot_file)$size > 100) {
          plot_data <- base64enc::base64encode(plot_file)
          captured_plot <- TRUE
        }
      }
      # For base graphics
      else if (!is.null(dev.list())) {
        # Save the current plot
        dev.copy(png, filename = plot_file, width = 800, height = 600)
        dev.off()
        
        if (file.exists(plot_file) && file.info(plot_file)$size > 100) {
          plot_data <- base64enc::base64encode(plot_file)
          captured_plot <- TRUE
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
        mime_type = "image/png"
      )
    }
    
    return(response)
  }, error = function(e) {
    # Make sure to close the sink if there was an error
    if (sink.number() > 0) sink()
    
    # Log error if logging is enabled
    if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
      log_error_to_file(code, e$message, settings$log_file_path)
    }
    
    # Display the error in the console
    cat("Error:", e$message, "\n")
    
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
# Replace the log_code_to_file function with this improved version:

log_code_to_file <- function(code, log_path) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  
  # Format the log entry
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by Claude:\n%s\n\n", timestamp, code)
  
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
