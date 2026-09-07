# 独立临时目录验证；不读取或清理用户的实际 discovery。
local({
  env <- new.env(parent = globalenv())
  funcs <- c("discovery_path", "with_discovery_lock", "pid_is_alive",
             "write_discovery_file", "remove_discovery_file", "cleanup_stale_discovery_files")
  if (file.exists("R/ui.R")) {
    for (expr in parse("R/ui.R")) {
      if (is.call(expr) && identical(expr[[1]], as.name("<-")) &&
          is.symbol(expr[[2]]) && as.character(expr[[2]]) %in% funcs) eval(expr, env)
    }
  } else {
    for (name in funcs) {
      fn <- getFromNamespace(name, "ClaudeR")
      environment(fn) <- env
      assign(name, fn, env)
    }
  }
  root <- tempfile("clauder-discovery-test-")
  dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  env$discovery_dir <- function() root
  env$load_claude_settings <- function() list(plot_auto=TRUE, tool_sets=c('core','edit'))
  write <- env$write_discovery_file
  write("A", 48878L, "test-token")
  f <- file.path(root, "A.json")
  original <- readLines(f)
  info <- jsonlite::fromJSON(f)
  stopifnot(isTRUE(info$plot_auto), identical(info$tool_sets, c('core','edit')))
  write("A", 48878L, "test-token")
  stopifnot(identical(original, readLines(f)))
  stopifnot(identical(env$pid_is_alive(Sys.getpid()), TRUE))
  stopifnot(is.na(env$pid_is_alive(NULL)))
  corrupt <- file.path(root, "partial.json")
  writeLines("{", corrupt)
  env$cleanup_stale_discovery_files()
  stopifnot(file.exists(corrupt), file.exists(f))
  dir.create(paste0(f, ".lock"))
  stopifnot(inherits(try(write("A", 48878L, "test-token"), silent = TRUE), "try-error"))
  unlink(paste0(f, ".lock"), recursive = TRUE)
  stopifnot(inherits(try(write("../bad", 48878L, "token"), silent = TRUE), "try-error"))
  for (name in c("bad\\name", "bad\nname", ".", "..", "bad:name")) {
    stopifnot(inherits(try(write(name, 48878L, "token"), silent = TRUE), "try-error"))
  }
  write("科研 x-1", 48878L, "test")
  children <- list(callr::r_bg(function() Sys.sleep(60)), callr::r_bg(function() Sys.sleep(60)))
  on.exit(for (child in children) if (child$is_alive()) child$kill(), add = TRUE)
  for (i in seq_along(children)) {
    jsonlite::write_json(list(session_name=paste0("child",i), port=48880L+i,
                             pid=children[[i]]$get_pid(), token="test"),
                        file.path(root,paste0("child",i,".json")), auto_unbox=TRUE)
  }
  env$cleanup_stale_discovery_files()
  stopifnot(all(vapply(children, function(p) p$is_alive(), logical(1))))
  owned <- file.path(root, "child1.json")
  bytes <- readLines(owned)
  stopifnot(inherits(try(write("child1", 48881L, "new"), silent=TRUE), "try-error"))
  env$remove_discovery_file("child1")
  stopifnot(identical(bytes, readLines(owned)))
  children[[1]]$kill()
  children[[1]]$wait(5000)
  env$cleanup_stale_discovery_files()
  stopifnot(!file.exists(owned), children[[2]]$is_alive(), file.exists(corrupt))
  env$remove_discovery_file("A")
  stopifnot(!file.exists(f))
  cat("DISCOVERY_RELIABILITY_OK: atomic refresh, locks, corrupt retention, two live processes, ownership, dead cleanup\n")
})
