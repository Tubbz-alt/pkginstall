
#' Perform a package installation plan, as created by pkgdepends
#'
#' @param plan Package plan object, returned by pkgdepends
#' @param lib Library directory to install to.
#' @param num_workers Number of worker processes to use.
#' @return Information about the installation process.
#'
#' @importFrom callr poll
#' @export

install_package_plan <- function(plan, lib = .libPaths()[[1]],
                                 num_workers = 1) {

  start <- Sys.time()

  required_columns <- c(
    "type", "binary", "dependencies", "file", "vignettes",
    "needscompilation", "metadata", "package")
  stopifnot(
    inherits(plan, "data.frame"),
    all(required_columns %in% colnames(plan)),
    is_string(lib),
    is_count(num_workers, min = 1L)
  )

  config <- list(lib = lib, num_workers = num_workers)
  state <- make_start_state(plan, config)
  state$progress <- create_progress_bar(state)
  on.exit(done_progress_bar(state), add =  TRUE)

  withCallingHandlers({

    ## Initialise one task for each worker
    for (i in seq_len(state$config$num_workers)) {
      task <- select_next_task(state)
      state <- start_task(state, task)
    }

    repeat {
      if (are_we_done(state)) break;
      update_progress_bar(state)

      events <- poll_workers(state)
      state <- handle_events(state, events)
      task  <- select_next_task(state)
      state <- start_task(state, task)
    }
  }, error = function(e) kill_all_processes(state))

  create_install_result(state)
}

make_start_state <- function(plan, config) {

  ## We store the data about build and installation here
  install_cols <- data.frame(
    stringsAsFactors = FALSE,
    build_done = (plan$type %in% c("deps", "installed")) | plan$binary,
    build_time = I(rep_list(nrow(plan), as.POSIXct(NA))),
    build_error = I(rep_list(nrow(plan), list())),
    build_stdout = I(rep_list(nrow(plan), character())),
    build_stderr = I(rep_list(nrow(plan), character())),
    install_done = plan$type %in% c("deps", "installed"),
    install_time = I(rep_list(nrow(plan), as.POSIXct(NA))),
    install_error = I(rep_list(nrow(plan), list())),
    install_stdout = I(rep_list(nrow(plan), character())),
    install_stderr = I(rep_list(nrow(plan), character())),
    worker_id = NA_character_
  )
  plan <- cbind(plan, install_cols)

  installed <- plan$package[plan$install_done]
  plan$deps_left <- lapply(plan$dependencies, setdiff, installed)

  list(
    plan = plan,
    workers = list(),
    config = config)
}

are_we_done <- function(state) {
  all(state$plan$install_done)
}

#' @importFrom callr poll

poll_workers <- function(state) {
  if (length(state$workers)) {
    timeout <- get_timeout(state)
    procs <- lapply(state$workers, "[[", "process")
    res <- poll(procs, ms = timeout)
    map_lgl(res, function(x) "ready" %in% x)

  } else {
    logical()
  }
}

get_timeout <- function(state) 100

handle_events <- function(state, events) {
  for (i in which(events)) state <- handle_event(state, i)
  state$workers <- drop_nulls(state$workers)
  state
}

handle_event <- function(state, evidx) {
  proc <- state$workers[[evidx]]$process

  ## Read out stdout and stderr. If process is done, then read out all
  if (proc$is_alive()) {
    state$workers[[evidx]]$stdout <-
      c(state$workers[[evidx]]$stdout, out <- proc$read_output(n = 10000))
    state$workers[[evidx]]$stderr <-
      c(state$workers[[evidx]]$stderr, err <- proc$read_error(n = 10000))
  } else {
    state$workers[[evidx]]$stdout <-
      c(state$workers[[evidx]]$stdout, out <- proc$read_all_output())
    state$workers[[evidx]]$stderr <-
      c(state$workers[[evidx]]$stderr, err <- proc$read_all_error())
  }

  ## If there is still output, then wait a bit more
  if (proc$is_alive() ||
      proc$is_incomplete_output() || proc$is_incomplete_error()) {
    return(state)
  }

  ## Otherwise we are done. Remove worker
  worker <- state$workers[[evidx]]
  state$workers[evidx] <- list(NULL)

  ## Post-process, this will throw on error
  if (is.function(proc$get_result)) proc$get_result()

  ## Cut stdout and stderr to lines
  worker$stdout <- cut_into_lines(worker$stdout)
  worker$stderr <- cut_into_lines(worker$stderr)

  ## Record what was done
  stop_task(state, worker)
}

select_next_task <- function(state) {

  ## Cannot run more workers?
  if (length(state$workers) >= state$config$num_workers) {
    return(task("idle"))
  }

  ## Can we select a source package build? Do that.
  can_build <- which(
    ! state$plan$build_done &
    map_int(state$plan$deps_left, length) == 0 &
    is.na(state$plan$worker_id))

  if (any(can_build)) {
    pkgidx <- can_build[1]
    return(task("build", pkgidx = pkgidx))
  }

  ## TODO: can we select a binary that is depended on by a source package?

  ## Otherwise select a binary if there is one
  can_install <- which(
    state$plan$build_done &
    ! state$plan$install_done &
    is.na(state$plan$worker_id))

  if (any(can_install)) {
    pkgidx <- can_install[1]
    return(task("install", pkgidx = pkgidx))
  }

  ## Detect internal error
  if (!all(state$plan$install_done) && all(is.na(state$plan$worker_id))) {
    stop("Internal error, no task running and cannot select new task")
  }

  ## Looks like nothing else to do
  task("idle")
}

task <- function(name, ...) {
  list(name = name, args = list(...))
}

start_task <- function(state, task) {
  if (task$name == "idle") {
    state

  } else if (task$name == "build") {
    start_task_build(state, task)

  } else if (task$name == "install") {
    start_task_install(state, task)

  } else {
    stop("Unknown task, internal error")
  }
}

get_worker_id <- (function() {
  id <- 0
  function() {
    id <<- id + 1
    as.character(id)
  }
})()

make_build_process <- function(path, tmp_dir, lib, vignettes,
                               needscompilation) {

  ## with_libpath() is needed for newer callr, which forces the current
  ## lib path in the child process.
  withr::with_libpaths(lib, action = "prefix",
    pkgbuild_process$new(
      path, tmp_dir, binary = TRUE, vignettes = vignettes,
      needs_compilation = needscompilation, compile_attributes = FALSE,
      args = glue("--library={lib}"))
    )
}

#' @importFrom pkgbuild pkgbuild_process

start_task_build <- function(state, task) {
  pkgidx <- task$args$pkgidx
  path <- if (state$plan$type[pkgidx] == "local") {
      sub("^file://", "", state$plan$sources[[pkgidx]])
    } else {
      state$plan$file[pkgidx]
    }
  vignettes <- state$plan$vignettes[pkgidx]
  needscompilation <- !identical(state$plan$needscompilation[pkgidx], "no")
  tmp_dir <- create_temp_dir()
  lib <- state$config$lib

  pkg <- state$plan$package[pkgidx]
  version <- state$plan$version[pkgidx]
  alert("info", "Building {pkg {pkg}} {version {version}}")

  px <- make_build_process(path, tmp_dir, lib, vignettes, needscompilation)
  worker <- list(id = get_worker_id(), task = task, process = px,
                 stdout = character(), stderr = character())
  state$workers <- c(
    state$workers, structure(list(worker), names = worker$id))
  state$plan$worker_id[pkgidx] <- worker$id
  state$plan$build_time[[pkgidx]] <- Sys.time()
  state
}

start_task_install <- function(state, task) {
  pkgidx <- task$args$pkgidx
  filename <- state$plan$file[pkgidx]
  lib <- state$config$lib
  metadata <- state$plan$metadata[[pkgidx]]

  pkg <- state$plan$package[pkgidx]
  version <- state$plan$version[pkgidx]
  update_progress_bar(state)

  px <- make_install_process(filename, lib = lib, metadata = metadata)
  worker <- list(
    id = get_worker_id(), task = task, process = px,
    stdout = character(), stderr = character())

  state$workers <- c(
    state$workers, structure(list(worker), names = worker$id))
  state$plan$worker_id[pkgidx] <- worker$id
  state$plan$install_time[[pkgidx]] <- Sys.time()
  state
}

stop_task <- function(state, worker) {
  if (worker$task$name == "build") {
    stop_task_build(state, worker)

  } else if (worker$task$name == "install") {
    stop_task_install(state, worker)

  } else {
    stop("Unknown task, internal error")
  }
}

#' @importFrom prettyunits pretty_sec

stop_task_build <- function(state, worker) {

  ## TODO: make sure exit status is non-zero on build error!
  success <- worker$process$get_exit_status() == 0

  pkgidx <- worker$task$args$pkgidx
  pkg <- state$plan$package[pkgidx]
  version <- state$plan$version[pkgidx]
  time <- Sys.time() - state$plan$build_time[[pkgidx]]
  ptime <- pretty_sec(as.numeric(time, units = "secs"))

  if (success) {
    alert("success", "Built {pkg {pkg}} {version {version}} \\
           {timestamp {ptime}}")
    ## Need to save the name of the built package
    state$plan$file[pkgidx] <- worker$process$get_built_file()
  } else {
    alert("danger", "Failed to build {pkg {pkg}} \\
           {version {version}} {timestamp {ptime}}")
  }
  update_progress_bar(state, 1L)

  state$plan$build_done[[pkgidx]] <- TRUE
  state$plan$build_time[[pkgidx]] <- time
  state$plan$build_error[[pkgidx]] <- ! success
  state$plan$build_stdout[[pkgidx]] <- worker$stdout
  state$plan$build_stderr[[pkgidx]] <- worker$stderr
  state$plan$worker_id[[pkgidx]] <- NA_character_

  if (!success) {
    abort("Failed to build source package {pkg}.")
  }

  state
}

installed_note <- function(pkg) {

  standard_note <- function() {
    if (pkg$type %in% c("cran", "standard")) {
      ""
    } else {
      paste0("(", pkg$type, ")")
    }
  }

  github_note <- function() {
    meta <- pkg$metadata[[1]]
    paste0("(github::", meta[["RemoteUsername"]], "/", meta[["RemoteRepo"]],
           "@", substr(meta[["RemoteSha"]], 1, 7), ")")
  }

  switch(
    pkg$type,
    cran = "",
    bioc = "(BioC)",
    standard = standard_note(),
    local = "(local)",
    github = github_note()
  )
}

#' @importFrom prettyunits pretty_sec

stop_task_install <- function(state, worker) {

  ## TODO: make sure the install status is non-zero on exit
  success <- worker$process$get_exit_status() == 0

  pkgidx <- worker$task$args$pkgidx
  pkg <- state$plan$package[pkgidx]
  version <- state$plan$version[pkgidx]
  time <- Sys.time() - state$plan$install_time[[pkgidx]]
  ptime <- pretty_sec(as.numeric(time, units = "secs"))
  note <- installed_note(state$plan[pkgidx,])

  if (success) {
    alert("success", "Installed {pkg {pkg}} \\
             {version {version}} {note} {timestamp {ptime}}")
  } else {
    alert("danger", "Failed to install  {pkg pkg}} {version {version}}")
  }
  update_progress_bar(state, 1L)

  state$plan$install_done[[pkgidx]] <- TRUE
  state$plan$install_time[[pkgidx]] <- time
  state$plan$install_error[[pkgidx]] <- ! success
  state$plan$install_stdout[[pkgidx]] <- worker$stdout
  state$plan$install_stderr[[pkgidx]] <- worker$stderr
  state$plan$worker_id[[pkgidx]] <- NA_character_

  if (!success) {
    abort("Failed to install binary package {pkg}.")
  }

  ## Need to remove from the dependency list
  state$plan$deps_left <- lapply(state$plan$deps_left, setdiff, pkg)

  state
}

create_install_result <-  function(state) {
  result <- state$plan
  class(result) <- c("pkginstall_result", class(result))
  result
}

#' @export
#' @importFrom prettyunits pretty_sec

print.pkginstall_result <- function(x, ...) {
  newly <- sum(x$lib_status == "new")
  upd   <- sum(x$lib_status == "update")
  noupd <- sum(x$lib_status == "no-update")
  curr  <- sum(x$lib_status == "current")
  if (newly) cat("Installed: ",  newly, "\n", sep = "")
  if (upd)   cat("Updated: ",    upd,   "\n", sep = "")
  if (noupd) cat("Not updated:", noupd, "\n", sep = "")
  if (curr)  cat("Current: ",    curr,  "\n", sep = "")

  ## TODO
  build_time <- sum(unlist(x$build_time), na.rm = TRUE)
  inst_time <- sum(unlist(x$install_time), na.rm = TRUE)

  cat("Build time:  ", pretty_sec(build_time), "\n", sep = "")
  cat("Intall time: ", pretty_sec(inst_time), "\n", sep = "")

  invisible(x)
}

kill_all_processes <- function(state) {
  alive <- FALSE
  for (i in seq_along(state$workers)) {
    proc <- state$workers[[i]]$process
    proc$signal(tools::SIGINT)
    alive <- alive || proc$is_alive()
  }

  if (alive) {
    for (i in seq_along(state$workers)) {
      proc <- state$workers[[i]]$process
      proc$wait(200)
      proc$kill_tree()
    }
  }
}
