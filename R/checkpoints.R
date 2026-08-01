# --- Session Checkpoints ---
# Snapshot/restore for the R global environment: an undo button for agent
# sessions. Checkpoints are .RData files under ~/.clauder_checkpoints/<session>/
# and survive R restarts. Exposed both as MCP tools (so agents can checkpoint
# before risky work) and as exported functions (so the user can recover from
# the console when the agent is the thing that broke the environment).

checkpoint_dir_default <- function() {
  session <- .claude_server_env$session_name
  if (is.null(session) || !nzchar(session)) session <- "default"
  file.path(path.expand("~"), ".clauder_checkpoints",
            gsub("[^a-zA-Z0-9_-]", "_", session))
}

#' Checkpoint the R session environment
#'
#' Saves every object in `envir` (default: the global environment) to a
#' timestamped .RData file so the session can be rolled back with
#' [restore_session()]. Old checkpoints beyond `max_keep` are pruned.
#'
#' @param label Optional short label recorded in the filename.
#' @param envir Environment to snapshot. Default `.GlobalEnv`.
#' @param dir Directory for checkpoint files. Default:
#'   `~/.clauder_checkpoints/<session>/`.
#' @param max_keep Maximum checkpoints to retain in `dir` (oldest pruned).
#' @param max_gb Refuse to checkpoint if the objects total more than this
#'   many gigabytes, unless `force = TRUE`.
#' @param force Set TRUE to checkpoint past the `max_gb` guard.
#' @return The checkpoint file path, invisibly.
#' @export
checkpoint_session <- function(label = NULL, envir = .GlobalEnv, dir = NULL,
                               max_keep = 10L, max_gb = 4, force = FALSE) {
  if (is.null(dir)) dir <- checkpoint_dir_default()
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, mode = "0700")

  obj_names <- ls(envir, all.names = TRUE)
  if (length(obj_names) == 0) {
    message("Environment is empty; writing an empty checkpoint.")
  }

  # Size guard: a multi-GB environment means a slow save and a big file.
  total_bytes <- sum(vapply(obj_names, function(nm) {
    as.numeric(tryCatch(utils::object.size(get(nm, envir = envir)),
                        error = function(e) 0))
  }, numeric(1)))
  if (!isTRUE(force) && total_bytes > max_gb * 1e9) {
    stop(sprintf(
      "Environment is ~%.1f GB (guard: %s GB). Pass force = TRUE to checkpoint anyway, or checkpoint after removing large objects.",
      total_bytes / 1e9, max_gb
    ), call. = FALSE)
  }

  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  safe_label <- if (!is.null(label) && nzchar(label)) {
    paste0("_", gsub("[^a-zA-Z0-9_-]", "_", substr(label, 1, 40)))
  } else ""
  path <- file.path(dir, paste0("chk_", stamp, safe_label, ".RData"))

  save(list = obj_names, envir = envir, file = path, compress = TRUE)
  try(Sys.chmod(path, mode = "0600"), silent = TRUE)

  # Prune oldest beyond max_keep.
  all_chk <- sort(list.files(dir, pattern = "^chk_.*\\.RData$", full.names = TRUE))
  if (length(all_chk) > max_keep) {
    old <- utils::head(all_chk, length(all_chk) - max_keep)
    try(file.remove(old), silent = TRUE)
  }

  message(sprintf("Checkpoint saved: %s (%d objects, %.1f MB)",
                  basename(path), length(obj_names),
                  file.info(path)$size / 1e6))
  invisible(path)
}

#' Restore the R session environment from a checkpoint
#'
#' Rolls `envir` back to a checkpoint written by [checkpoint_session()].
#' By default the current state is checkpointed first (labelled
#' `pre_restore`), so a restore is itself undoable.
#'
#' @param checkpoint Path to a checkpoint file, or a filename returned by
#'   [list_session_checkpoints()]. Default `NULL` restores the most recent.
#' @param envir Environment to restore into. Default `.GlobalEnv`.
#' @param dir Directory holding checkpoints. Default:
#'   `~/.clauder_checkpoints/<session>/`.
#' @param clear If TRUE (default), objects created since the checkpoint are
#'   removed so the environment matches the snapshot exactly. If FALSE, the
#'   checkpoint is loaded over the current environment (merge).
#' @param backup If TRUE (default), checkpoint the current state before
#'   restoring.
#' @return The checkpoint path that was restored, invisibly.
#' @export
restore_session <- function(checkpoint = NULL, envir = .GlobalEnv, dir = NULL,
                            clear = TRUE, backup = TRUE) {
  if (is.null(dir)) dir <- checkpoint_dir_default()

  # Resolve the target BEFORE the pre-restore backup so "latest" cannot
  # resolve to the backup we are about to write.
  if (is.null(checkpoint)) {
    all_chk <- sort(list.files(dir, pattern = "^chk_.*\\.RData$", full.names = TRUE))
    if (length(all_chk) == 0) {
      stop("No checkpoints found in ", dir, ". Create one with checkpoint_session().",
           call. = FALSE)
    }
    checkpoint <- all_chk[length(all_chk)]
  } else if (!file.exists(checkpoint)) {
    candidate <- file.path(dir, checkpoint)
    if (!file.exists(candidate)) {
      stop("Checkpoint not found: ", checkpoint, call. = FALSE)
    }
    checkpoint <- candidate
  }

  if (isTRUE(backup)) {
    checkpoint_session(label = "pre_restore", envir = envir, dir = dir,
                       force = TRUE)
  }

  if (isTRUE(clear)) {
    rm(list = ls(envir, all.names = TRUE), envir = envir)
  }
  loaded <- load(checkpoint, envir = envir)

  message(sprintf("Restored %d objects from %s%s",
                  length(loaded), basename(checkpoint),
                  if (isTRUE(backup)) " (previous state saved as pre_restore)" else ""))
  invisible(checkpoint)
}

#' List available session checkpoints
#'
#' @param dir Directory holding checkpoints. Default:
#'   `~/.clauder_checkpoints/<session>/`.
#' @return A data frame with one row per checkpoint (file, time, size),
#'   newest last. Empty data frame if none exist.
#' @export
list_session_checkpoints <- function(dir = NULL) {
  if (is.null(dir)) dir <- checkpoint_dir_default()
  files <- sort(list.files(dir, pattern = "^chk_.*\\.RData$", full.names = TRUE))
  if (length(files) == 0) {
    message("No checkpoints in ", dir)
    return(invisible(data.frame(file = character(0), time = character(0),
                                size_mb = numeric(0))))
  }
  info <- file.info(files)
  out <- data.frame(
    file = basename(files),
    time = format(info$mtime, "%Y-%m-%d %H:%M:%S"),
    size_mb = round(info$size / 1e6, 1),
    stringsAsFactors = FALSE
  )
  out
}
