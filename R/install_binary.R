#' Install a R binary package
#'
#' @param filename filename of built binary package to install
#' @param lib library to install packages into
#' @param lock If any value but `FALSE`, use per-package locking when
#'   installing. It defaults to using `getOption("install.lock")` for
#'   compatibility with `utils::install.packages()`.
#' @importFrom archive archive archive_extract
#' @importFrom filelock lock unlock
#' @export
install_binary <- function(filename, lib = .libPaths()[[1L]],
  lock = getOption("install.lock", TRUE)) {

  desc <- verify_binary(filename)
  pkg_name <- desc$get("Package")

  if (is_loaded(pkg_name)) {
    abort(type = "runtime_error",
     "Package {pkg_name} is already loaded and cannot be installed.
      Use `pkgload::unload({pkg_name})` to unload it.")
  }

  lib_cache <- library_cache(lib, pkg_name, lock)

  pkg_cache_dir <- file.path(lib_cache, pkg_name)
  if (file.exists(pkg_cache_dir)) {
    unlink(pkg_cache_dir, recursive = TRUE, force = TRUE)
  }

  archive_extract(filename, dir = lib_cache)

  installed_path <- file.path(lib, pkg_name)
  if (file.exists(installed_path)) {
    # First move the existing library (which still works even if a process has
    # the DLL open), then try to delete it, which may fail if another process
    # has the file open.
    move_to <- file.path(create_temp_dir(), pkg_name)
    ret <- file.rename(installed_path, move_to)
    if (!ret) {
      abort(type = "filesystem",
        "Failed to move installed package at {installed_path}")
    }
    ret <- unlink(move_to, recursive = TRUE, force = TRUE)
    if (ret != 0) {
      warn(type = "filesystem",
        "Failed to remove installed package at {move_to}")
    }
  }
  ret <- file.rename(pkg_cache_dir, installed_path)
  if (!ret) {
    abort(type = "filesystem",
      "Unable to move package from {extract_dir} to {installed_path}")
  }

  installed_path
}


get_archive_pkg_name <- function(tarball) {
  filename <- attr(tarball, "path")

  description_path <- grep("DESCRIPTION$", tarball$path, value = TRUE)

  # If there is more than one DESCRIPTION in the tarball use the shortest one,
  # which should always be the top level DESCRIPTION file.
  # This may happen if there are test packages in the package tests for instance.
  description_path <- head(description_path[order(nchar(description_path))], n = 1)

  if (length(description_path) == 0) {
    abort(type = "invalid_input", "
      {filename} is not a valid binary, it does not contain a `DESCRIPTION` file.
      ")
  }

  pkg <- dirname(description_path)

  nested_directory <- dirname(pkg) != "."
  if (nested_directory) {
    abort(type = "invalid_input", "
      {filename} is not a valid binary, the `DESCRIPTION` file is nested more than 1 level deep {description_path}.
      ")
  }
  pkg
}