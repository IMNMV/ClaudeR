# Initialize command handlers list

command_handlers <- list()

#' Get session info
#'
#' @export

command_handlers$get_session_info <- function() {
  list(
    r_version = R.version$version.string,
    rstudio_version = rstudioapi::versionInfo()$version,
    working_dir = getwd(),
    packages = as.character(utils::installed.packages()[, "Package"])
  )
}

#' Get dataframe info
#'
#' @export

command_handlers$get_dataframe_info <- function(name) {
  if (!exists(name, envir = .GlobalEnv)) {
    stop(sprintf("Dataframe '%s' does not exist in the global environment", name))
  }

  df <- get(name, envir = .GlobalEnv)

  if (!is.data.frame(df)) {
    stop(sprintf("'%s' is not a dataframe", name))
  }

  list(
    name = name,
    dimensions = dim(df),
    column_names = colnames(df),
    column_types = sapply(df, class),
    head = utils::head(df, 5)
  )
}

#' List available dataframes
#' @export

command_handlers$list_dataframes <- function() {
  objs <- ls(.GlobalEnv)
  dfs <- objs[sapply(objs, function(x) is.data.frame(get(x, envir = .GlobalEnv)))]

  result <- list()
  for (df_name in dfs) {
    df <- get(df_name, envir = .GlobalEnv)
    result[[df_name]] <- list(
      name = df_name,
      dimensions = dim(df),
      column_count = ncol(df),
      row_count = nrow(df)
    )
  }

  return(result)
}

#' Execute R code
#' @export

command_handlers$execute_code <- function(code) {
  # Create an environment to capture the results
  env <- new.env(parent = .GlobalEnv)

  # Capture stdout and stderr
  output <- utils::capture.output({
    result <- tryCatch({
      eval(parse(text = code), envir = env)
    }, error = function(e) {
      list(error = e$message)
    })
  }, type = "output")

  list(
    result = result,
    output = output
  )
}

#' Plot data using ggplot2
#' @export

command_handlers$create_plot <- function(code) {
  # Ensure ggplot2 is available
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("Package 'ggplot2' is required for plotting")
  }

  # Create a temporary file for the plot
  plot_file <- tempfile(fileext = ".png")

  # Evaluate the ggplot code and save
  tryCatch({
    plot_expr <- parse(text = code)
    plot <- eval(plot_expr, envir = .GlobalEnv)

    if (!inherits(plot, "ggplot")) {
      stop("The code did not return a ggplot object")
    }

    ggsave(plot_file, plot, width = 8, height = 6, dpi = 100)

    # Return plot info and base64 encoded image
    list(
      success = TRUE,
      plot_file = plot_file,
      plot_data = base64enc::base64encode(plot_file)
    )
  }, error = function(e) {
    list(
      success = FALSE,
      error = e$message
    )
  })
}

#' Perform data analysis with dplyr
#' @export

command_handlers$analyze_data <- function(dataframe, analysis_code) {
  if (!requireNamespace("dplyr", quietly = TRUE)) {
    stop("Package 'dplyr' is required for data analysis")
  }

  if (!exists(dataframe, envir = .GlobalEnv)) {
    stop(sprintf("Dataframe '%s' does not exist", dataframe))
  }

  df <- get(dataframe, envir = .GlobalEnv)

  # Create modified analysis code with proper dplyr masking
  modified_code <- gsub(
    "([^:])([a-zA-Z_0-9]*)\\(",
    "\\1dplyr::\\2(",
    analysis_code,
    perl = TRUE
  )

  # Execute the analysis
  tryCatch({
    result <- eval(parse(text = paste0("df %>% ", modified_code)), envir = .GlobalEnv)

    if (is.data.frame(result)) {
      return(list(
        success = TRUE,
        result_type = "dataframe",
        dimensions = dim(result),
        head = utils::head(result, 10)
      ))
    } else {
      return(list(
        success = TRUE,
        result_type = class(result),
        value = result
      ))
    }
  }, error = function(e) {
    return(list(
      success = FALSE,
      error = e$message
    ))
  })
}
