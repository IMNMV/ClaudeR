library(ClaudeR)

capture_install_cli <- function(...) {
  paste(capture.output(suppressMessages(ClaudeR::install_cli(...))), collapse = "\n")
}

output <- capture_install_cli(tools = c("copilot", "qwen"))

stopifnot(grepl("GitHub Copilot CLI", output, fixed = TRUE))
stopifnot(grepl("copilot mcp add r-studio --transport stdio --tools", output, fixed = TRUE))
stopifnot(grepl("~/.copilot/mcp-config.json", output, fixed = TRUE))
stopifnot(grepl('"type": "local"', output, fixed = TRUE))

stopifnot(grepl("Qwen Code CLI", output, fixed = TRUE))
stopifnot(grepl("qwen mcp add --scope user --transport stdio r-studio uvx clauder-mcp", output, fixed = TRUE))

invalid <- try(ClaudeR::install_cli(tools = "not-a-cli"), silent = TRUE)
stopifnot(inherits(invalid, "try-error"))
