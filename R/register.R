#' Generates wrappers for registered C++ functions
#'
#' Functions decorated with `[[cpp11::register]]` in files ending in `.cc`,
#' `.cpp`, `.h` or `.hpp` will be wrapped in generated code and registered to
#' be called from R.
#'
#' In order to use `cpp_register()` the `cli`, `decor`, `desc`, `glue`,
#' `tibble` and `vctrs` packages must also be installed.
#' @param path The path to the package root directory
#' @param quiet If `TRUE` suppresses output from this function
#' @return The paths to the generated R and C++ source files (in that order).
#' @export
#' @examples
#' # create a minimal package
#' dir <- tempfile()
#' dir.create(dir)
#'
#' writeLines("Package: testPkg", file.path(dir, "DESCRIPTION"))
#' writeLines("useDynLib(testPkg, .registration = TRUE)", file.path(dir, "NAMESPACE"))
#'
#' # create a C++ file with a decorated function
#' dir.create(file.path(dir, "src"))
#' writeLines("[[cpp11::register]] int one() { return 1; }", file.path(dir, "src", "one.cpp"))
#'
#' # register the functions in the package
#' cpp_register(dir)
#'
#' # Files generated by registration
#' file.exists(file.path(dir, "R", "cpp11.R"))
#' file.exists(file.path(dir, "src", "cpp11.cpp"))
#'
#' # cleanup
#' unlink(dir, recursive = TRUE)
cpp_register <- function(path = ".", quiet = FALSE) {
  stop_unless_installed(get_cpp_register_needs())

  r_path <- file.path(path, "R", "cpp11.R")
  cpp_path <- file.path(path, "src", "cpp11.cpp")
  unlink(c(r_path, cpp_path))

  suppressWarnings(
    all_decorations <- decor::cpp_decorations(path, is_attribute = TRUE)
  )

  if (nrow(all_decorations) == 0) {
    return(invisible(character()))
  }

  funs <- get_registered_functions(all_decorations, "cpp11::register", quiet)

  package <- desc::desc_get("Package", file = file.path(path, "DESCRIPTION"))

  cpp_functions_definitions <- generate_cpp_functions(funs, package)

  init <- generate_init_functions(get_registered_functions(all_decorations, "cpp11::init", quiet))

  r_functions <- generate_r_functions(funs, package, use_package = TRUE)

  dir.create(dirname(r_path), recursive = TRUE, showWarnings = FALSE)

  brio::write_lines(path = r_path, glue::glue('
      # Generated by cpp11: do not edit by hand

      {r_functions}
      '
  ))
  if (!quiet) {
    cli::cli_alert_success("generated file {.file {basename(r_path)}}")
  }

  call_entries <- get_call_entries(path)

  cpp_function_registration <- glue::glue_data(funs, '    {{
    "_cpp11_{name}", (DL_FUNC) &_{package}_{name}, {n_args}}}, ',
    n_args = viapply(funs$args, nrow)
  )

  cpp_function_registration <- glue::glue_collapse(cpp_function_registration, sep  = "\n")

  extra_includes <-  character()
  if (pkg_links_to_rcpp(path)) {
    extra_includes <- c(extra_includes, "#include <cpp11/R.hpp>", "#include <Rcpp.h>", "using namespace Rcpp;")
  }

  pkg_types <- c(
    file.path(path, "src", paste0(package, "_types.h")),
    file.path(path, "src", paste0(package, "_types.hpp")),
    file.path(path, "inst", "include", paste0(package, "_types.h")),
    file.path(path, "inst", "include", paste0(package, "_types.hpp"))
  )

  pkg_types_exist <- file.exists(pkg_types)
  if (any(pkg_types_exist)) {
    extra_includes <- c(
      sprintf('#include "%s"', basename(pkg_types[pkg_types_exist])),
      extra_includes
    )
  }

  extra_includes <- paste0(extra_includes, collapse = "\n")

  brio::write_lines(path = cpp_path, glue::glue('
      // Generated by cpp11: do not edit by hand
      // clang-format off

      {extra_includes}
      #include "cpp11/declarations.hpp"

      {cpp_functions_definitions}

      extern "C" {{
      {call_entries}
      }}
      {init$declarations}
      extern "C" void R_init_{package}(DllInfo* dll){{
        R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
        R_useDynamicSymbols(dll, FALSE);{init$calls}
      }}
      ',
      call_entries = glue::glue_collapse(call_entries, "\n")
  ))

  if (!quiet) {
    cli::cli_alert_success("generated file {.file {basename(cpp_path)}}")
  }

  invisible(c(r_path, cpp_path))
}

utils::globalVariables(c("name", "return_type", "line", "decoration", "context", ".", "functions", "res"))

get_registered_functions <- function(decorations, tag, quiet = FALSE) {
  if (NROW(decorations) == 0) {
    return(tibble::tibble(file = character(), line = integer(), decoration = character(), params = list(), context = list(), name = character(), return_type = character(), args = list()))
  }

  out <- decorations[decorations$decoration == tag, ]
  out$functions <- lapply(out$context, decor::parse_cpp_function, is_attribute = TRUE)
  out <- vctrs::vec_cbind(out, vctrs::vec_rbind(!!!out$functions))

  out <- out[!(names(out) %in% "functions")]
  out$decoration <- sub("::[[:alpha:]]+", "", out$decoration)

  n <- nrow(out)

  if (!quiet && n > 0) {
    cli::cli_alert_info(glue::glue("{n} functions decorated with [[{tag}]]"))
  }

  out
}

generate_cpp_functions <- function(funs, package = "cpp11") {
  funs <- funs[c("name", "return_type", "args", "file", "line", "decoration")]
  funs$real_params <- vcapply(funs$args, glue_collapse_data, "{type} {name}")
  funs$sexp_params <- vcapply(funs$args, glue_collapse_data, "SEXP {name}")
  funs$calls <- mapply(wrap_call, funs$name, funs$return_type, funs$args, SIMPLIFY = TRUE)
  funs$package <- package

  out <- glue::glue_data(funs,
    '
    // {basename(file)}
    {return_type} {name}({real_params});
    extern "C" SEXP _{package}_{name}({sexp_params}) {{
      BEGIN_CPP11
      {calls}
      END_CPP11
    }}
    '
  )
  out <- glue::glue_collapse(out, sep = "\n")
  unclass(out)
}

generate_init_functions <- function(funs) {
  if (nrow(funs) == 0) {
    return(list(declarations = "", calls = ""))
  }

  funs <- funs[c("name", "return_type", "args", "file", "line", "decoration")]
  funs$declaration_params <- vcapply(funs$args, glue_collapse_data, "{type} {name}")
  funs$call_params <- vcapply(funs$args, `[[`, "name")

  declarations <- glue::glue_data(funs,
    '
    {return_type} {name}({declaration_params});
    '
  )

  declarations <- paste0("\n", glue::glue_collapse(declarations, "\n"), "\n")

  calls <- glue::glue_data(funs,
    '
      {name}({call_params});
    '
  )
  calls <- paste0("\n", glue::glue_collapse(calls, "\n"));

  list(
    declarations = declarations,
    calls = calls
  )
}

generate_r_functions <- function(funs, package = "cpp11", use_package = FALSE) {
  if (use_package) {
    package_call <- glue::glue(', PACKAGE = "{package}"')
  } else {
    package_call <- ""
  }

  funs <- funs[c("name", "return_type", "args")]
  funs$package <- package
  funs$package_call <- package_call
  funs$list_params <- vcapply(funs$args, glue_collapse_data, "{name}")
  funs$params <- vcapply(funs$list_params, function(x) if (nzchar(x)) paste0(", ", x) else x)
  is_void <- funs$return_type == "void"
  funs$calls <- ifelse(is_void,
    glue::glue_data(funs, 'invisible(.Call("_{package}_{name}"{params}{package_call}))'),
    glue::glue_data(funs, '.Call("_{package}_{name}"{params}{package_call})')
  )

  out <- glue::glue_data(funs, '
    {name} <- function({list_params}) {{
      {calls}
    }}
    ')
  out <- glue::glue_collapse(out, sep = "\n\n")
  unclass(out)
}

wrap_call <- function(name, return_type, args) {
  call <- glue::glue('{name}({list_params})', list_params = glue_collapse_data(args, "cpp11::as_cpp<cpp11::decay_t<{type}>>({name})"))
  if (return_type == "void") {
    unclass(glue::glue("  {call};\n    return R_NilValue;", .trim = FALSE))
  } else {
    unclass(glue::glue("  return cpp11::as_sexp({call});"))
  }
}

get_call_entries <- function(path) {
  con <- textConnection("res", local = TRUE, open = "w")

  tools::package_native_routine_registration_skeleton(path,
    con,
    character_only = FALSE,
    include_declarations = TRUE
  )

  close(con)

  start <- grep("/* .Call calls */", res, fixed = TRUE)
  end <- grep("};", res, fixed = TRUE)

  if (length(start) == 0) {
    return("")
  }
  res[seq(start, end)]
}

pkg_links_to_rcpp <- function(path) {
  deps <- desc::desc_get_deps(file.path(path, "DESCRIPTION"))

  any(deps$type == "LinkingTo" & deps$package == "Rcpp")
}

get_cpp_register_needs <- function() {
  res <- read.dcf(system.file("DESCRIPTION", package = "cpp11"))[, "Config/Needs/cpp11/cpp_register"]
  strsplit(res, "[[:space:]]*,[[:space:]]*")[[1]]
}
