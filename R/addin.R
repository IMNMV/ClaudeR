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


# All shared functions (execute_code_in_session, log_code_to_file,
# log_error_to_file, load_claude_settings, save_claude_settings,
# validate_code_security) are defined in ui.R and resolved via
# the package namespace automatically.
