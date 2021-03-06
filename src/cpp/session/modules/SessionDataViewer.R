#
# SessionData.R
#
# Copyright (C) 2009-12 by RStudio, Inc.
#
# Unless you have received this program directly from RStudio pursuant
# to the terms of a commercial license agreement with RStudio, then
# this program is licensed to you under the terms of version 3 of the
# GNU Affero General Public License. This program is distributed WITHOUT
# ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING THOSE OF NON-INFRINGEMENT,
# MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Please refer to the
# AGPL (http://www.gnu.org/licenses/agpl-3.0.txt) for more details.
#
#

# host environment for cached data; this allows us to continue to view data 
# even if the original object is deleted
.rs.setVar("CachedDataEnv", new.env(parent = emptyenv()))

# host environment for working data; this allows us to sort/filter/page the
# data without recomputing on the original object every time
.rs.setVar("WorkingDataEnv", new.env(parent = emptyenv()))

.rs.addFunction("formatDataColumn", function(x, start, len, ...)
{
   # extract the visible part of the column
   col <- x[start:min(length(x), start+len)]

   if (is.numeric(col)) {
     # show numbers as doubles
     storage.mode(col) <- "double"
   } else {
     # show everything else as characters
     col <- as.character(col)
   }
   format(col, trim = TRUE, justify = "none", ...)
})

.rs.addFunction("describeCols", function(x, maxCols, maxFactors) 
{
  colNames <- names(x)

  # get the variable labels, if any--labels may be provided either by this 
  # global attribute or by a 'label' attribute on an individual column (as in
  # e.g. Hmisc), which takes precedence if both are present
  colLabels <- attr(x, "variable.labels", exact = TRUE)
  if (!is.character(colLabels)) 
  {
    colLabels <- character()
  }

  # truncate to maximum displayed number of columns
  colNames <- colNames[1:min(length(colNames), maxCols)]

  # get the attributes for each column
  colAttrs <- lapply(seq_along(colNames), function(idx) {
    col_name <- if (idx <= length(colNames)) 
                  colNames[idx] 
                else 
                  as.character(idx)
    col_type <- "unknown"
    col_min <- 0
    col_max <- 0
    col_vals <- ""
    col_search_type <- ""

    # extract label, if any, or use global label, if any
    label <- attr(x[[idx]], "label", exact = TRUE)
    if (is.character(label))
      col_label <- label
    else if (idx <= length(colLabels))
      col_label <- colLabels[[idx]]
    else 
      col_label <- ""

    # ensure that the column contains some scalar values we can examine 
    # (treat vector-valued columns as of unknown type) 
    if (length(x[[idx]]) > 0 && length(x[[idx]][1]) == 1)
    {
      val <- x[[idx]][1]
      if (is.factor(val))
      {
        col_type <- "factor"
        if (length(levels(val)) > maxFactors)
        {
          # if the number of factors exceeds the max, search the column as 
          # though it were a character column
          col_search_type <- "character"
        }
        else 
        {
          col_search_type <- "factor"
          col_vals <- levels(val)
        }
      }
      else if (is.numeric(val))
      {
        # ignore missing and infinite values (i.e. let any filter applied
        # implicitly remove those values); if that leaves us with nothing,
        # treat this column as untyped since we can do no meaningful filtering
        # on it
        minmax_vals <- x[[idx]][is.finite(x[[idx]])]
        if (length(minmax_vals) > 1)
        {
          col_min <- round(min(minmax_vals), 5)
          col_max <- round(max(minmax_vals), 5)
          if (col_min < col_max) 
          {
            col_type <- "numeric"
            col_search_type <- "numeric"
          }
        }
      }
      else if (is.character(val))
      {
        col_type <- "character"
        col_search_type <- "character"
      }
    }
    list(
      col_name        = .rs.scalar(col_name),
      col_type        = .rs.scalar(col_type),
      col_min         = .rs.scalar(col_min),
      col_max         = .rs.scalar(col_max),
      col_search_type = .rs.scalar(col_search_type),
      col_label       = .rs.scalar(col_label),
      col_vals        = col_vals
    )
  })
  c(list(list(
      col_name        = .rs.scalar(""),
      col_type        = .rs.scalar("rownames"),
      col_min         = .rs.scalar(0),
      col_max         = .rs.scalar(0),
      col_search_type = .rs.scalar("none"),
      col_label       = .rs.scalar(""),
      col_vals        = ""
    )), colAttrs)
})

.rs.addFunction("formatRowNames", function(x, start, len) 
{
  rownames <- row.names(x)
  rownames[start:min(length(rownames), start+len)]
})

# wrappers for nrow/ncol which will report the class of object for which we
# fail to get dimensions along with the original error
.rs.addFunction("nrow", function(x)
{
  rows <- 0
  tryCatch({
    rows <- nrow(x)
  }, error = function(e) {
    stop("Failed to determine rows for object of class '", class(x), "': ", 
         e$message)
  })
  if (is.null(rows))
    0
  else
    rows
})

.rs.addFunction("ncol", function(x)
{
  cols <- 0
  tryCatch({
    cols <- ncol(x)
  }, error = function(e) {
    stop("Failed to determine columns for object of class '", class(x), "': ", 
         e$message)
  })
  if (is.null(cols))
    0
  else
    cols
})

.rs.addFunction("toDataFrame", function(x, name) {
  if (is.data.frame(x))
    return(x)
  frame <- NULL
  # attempt to coerce to a data frame--this can throw errors in the case where
  # we're watching a named object in an environment and the user replaces an
  # object that can be coerced to a data frame with one that cannot
  tryCatch(
  {
    frame <- as.data.frame(x)
  },
  error = function(e)
  {
  })
  if (!is.null(frame))
    names(frame)[names(frame) == "x"] <- name
  frame
})

.rs.addFunction("applyTransform", function(x, filtered, search, col, dir) 
{
  # coerce argument to data frame--data.table objects (for example) report that
  # they're data frames, but don't actually support the subsetting operations
  # needed for search/sort/filter without an explicit cast
  x <- as.data.frame(x)

  # apply columnwise filters
  for (i in seq_along(filtered)) {
    if (nchar(filtered[i]) > 0 && length(x[[i]]) > 0) {
      # split filter--string format is "type|value" (e.g. "numeric|12-25") 
      filter <- strsplit(filtered[i], split="|", fixed = TRUE)[[1]]
      if (length(filter) < 2) 
      {
        # no filter type information
        next
      }
      filtertype <- filter[1]
      filterval <- filter[2]

      # apply filter appropriate to type
      if (identical(filtertype, "factor")) 
      {
        # apply factor filter: convert to numeric values and discard missing
        filterval <- as.numeric(filterval)
        matches <- as.numeric(x[[i]]) == filterval
        matches[is.na(matches)] <- FALSE
        x <- x[matches, , drop = FALSE]
      }
      else if (identical(filtertype, "character"))
      {
        # apply character filter: non-case-sensitive prefix
        x <- x[grepl(filterval, x[[i]], ignore.case = TRUE), , drop = FALSE]
      } 
      else if (identical(filtertype, "numeric"))
      {
        # apply numeric filter, range ("2-32") or equality ("15")
        filterval <- as.numeric(strsplit(filterval, "-")[[1]])
        if (length(filterval) > 1)
          # range filter
          x <- x[x[[i]] >= filterval[1] & x[[i]] <= filterval[2], , drop = FALSE]
        else
          # equality filter
          x <- x[x[[i]] == filterval, , drop = FALSE]
      }
    }
  }

  # apply global search
  if (!is.null(search) && nchar(search) > 0)
  {
    x <- x[Reduce("|", lapply(x, function(column) { 
             grepl(search, column, ignore.case = TRUE)
           })), , drop = FALSE]
  }

  # apply sort
  if (col > 0 && length(x[[col]]) > 0)
  {
    if (is.list(x[1,col]) || length(x[1,col]) > 1)
    {
      # extract the first value from each cell for ordering (handle
      # vector-valued columns gracefully)
      x <- as.data.frame(x[order(vapply(x[[col]], `[`, 0, 1), 
                                 decreasing = identical(dir, "desc")), ,
                           drop = FALSE])
    }
    else
    {
      # skip the expensive vapply when we're dealing with scalars
      x <- as.data.frame(x[order(x[[col]], 
                                 decreasing = identical(dir, "desc")), ,
                           drop = FALSE])
    }
  }

  return(x)
})

# returns envName as an environment, or NULL if the conversion failed
.rs.addFunction("safeAsEnvironment", function(envName)
{
  env <- NULL
  tryCatch(
  {
    env <- as.environment(envName)
  }, 
  error = function(e) { })
  env
})

.rs.addFunction("findDataFrame", function(envName, objName, cacheKey, cacheDir) 
{
  env <- NULL

  # do we have an object name? if so, check in a named environment
  if (!is.null(objName) && nchar(objName) > 0) 
  {
    if (is.null(envName) || identical(envName, "R_GlobalEnv") || 
        nchar(envName) == 0)
    {
      # global environment
      env <- globalenv()
    }
    else 
    {
      env <- .rs.safeAsEnvironment(envName)
      if (is.null(env))
        env <- emptyenv()
    }

    # if the object exists in this environment, return it (avoid creating a
    # temporary here)
    if (exists(objName, where = env, inherits = FALSE))
    {
      # attempt to coerce the object to a data frame--note that a null return
      # value here may indicate that the object exists in the environment but
      # is no longer a data frame (we want to fall back on the cache in this
      # case)
      dataFrame <- .rs.toDataFrame(get(objName, envir = env, inherits = FALSE), objName)
      if (!is.null(dataFrame)) 
        return(dataFrame)
    }
  }

  # if the object exists in the cache environment, return it. Objects
  # in the cache environment have already been coerced to data frames.
  if (exists(cacheKey, where = .rs.CachedDataEnv, inherits = FALSE))
    return(get(cacheKey, envir = .rs.CachedDataEnv, inherits = FALSE))

  # perhaps the object has been saved? attempt to load it into the
  # cached environment
  cacheFile <- file.path(cacheDir, paste(cacheKey, "Rdata", sep = "."))
  if (file.exists(cacheFile))
  { 
    load(cacheFile, envir = .rs.CachedDataEnv)
    if (exists(cacheKey, where = .rs.CachedDataEnv, inherits = FALSE))
      return(get(cacheKey, envir = .rs.CachedDataEnv, inherits = FALSE))
  }
  
  # failure
  return(NULL)
})

# given a name, return the first environment on the search list that contains
# an object bearing that name. 
.rs.addFunction("findViewingEnv", function(name)
{
   # default to searching from the global environment
   env <- globalenv()
   
   # attempt to find a callframe from which View was invoked; this will allow
   # us to locate viewing environments further in the callstack (e.g. in the
   # debugger)
   for (i in seq_along(sys.calls()))
   {
     if (identical(deparse(sys.call(i)[[1]]), "View"))
     {
       env <- sys.frame(i - 1)
       break
     }
   }

   while (environmentName(env) != "R_EmptyEnv" && 
          !exists(name, where = env, inherits = FALSE)) 
   {
     env <- parent.env(env)
   }
   env
})

# attempts to determine whether the View(...) function the user has an 
# override (i.e. it's not the handler RStudio uses)
.rs.addFunction("isViewOverride", function() {
   # check to see if View has been overridden: find the View() call in the 
   # stack and examine the function being evaluated there
   for (i in seq_along(sys.calls()))
   {
     if (identical(deparse(sys.call(i)[[1]]), "View"))
     {
       # the first statement in the override function should be a call to 
       # .rs.callAs
       return(!identical(deparse(body(sys.function(i))[[1]]), ".rs.callAs"))
     }
   }
   # if we can't find View on the callstack, presume the common case (no
   # override)
   FALSE
})


.rs.registerReplaceHook("View", "utils", function(original, x, title) 
{
   # generate title if necessary
   if (missing(title))
      title <- deparse(substitute(x))[1]

   name <- ""
   env <- emptyenv()


   if (.rs.isViewOverride()) 
   {
     # if the View() invoked wasn't our own, we have no way of knowing what's
     # been done to the data since the user invoked View() on it, so just view
     # a snapshot of the data
     name <- title
   }
   else if (is.name(substitute(x)))
   {
     # if the argument is the name of a variable, we can monitor it in its
     # environment, and don't need to make a copy for viewing
     name <- deparse(substitute(x))
     env <- .rs.findViewingEnv(name)
   }

   # is this a function? if it is, view as a function instead
   if (is.function(x)) 
   {
     namespace <- environmentName(env)
     if (identical(namespace, "R_EmptyEnv") || identical(namespace, ""))
       namespace <- "viewing"
     else if (identical(namespace, "R_GlobalEnv"))
       namespace <- ".GlobalEnv"
     invisible(.Call("rs_viewFunction", x, title, namespace))
     return(invisible(NULL))
   }

   # test for coercion to data frame 
   as.data.frame(x)

   # save a copy into the cached environment
   cacheKey <- .rs.addCachedData(force(x), name)
   
   # call viewData 
   invisible(.Call("rs_viewData", x, title, name, env, cacheKey))
})

.rs.addFunction("initializeDataViewer", function(server) {
    if (server) {
        .rs.registerReplaceHook("edit", "utils", function(original, name, ...) {
            if (is.data.frame(name) || is.matrix(name))
                stop("Editing of data frames and matrixes is not supported in RStudio.", call. = FALSE)
            else
                original(name, ...)
        })
    }
})

.rs.addFunction("addCachedData", function(obj, objName) 
{
   cacheKey <- paste(sample(c(letters, 0:9), 10, replace = TRUE), collapse = "")
   .rs.assignCachedData(cacheKey, obj, objName)
   cacheKey
})

.rs.addFunction("assignCachedData", function(cacheKey, obj, objName) 
{
   # coerce to data frame before assigning, and don't assign if we can't coerce
   frame <- .rs.toDataFrame(obj, objName)
   if (!is.null(frame))
      assign(cacheKey, frame, .rs.CachedDataEnv)
})

.rs.addFunction("removeCachedData", function(cacheKey, cacheDir)
{
  # remove data from the cache environment
  if (exists(".rs.CachedDataEnv") &&
      exists(cacheKey, where = .rs.CachedDataEnv, inherits = FALSE))
    rm(list = cacheKey, envir = .rs.CachedDataEnv, inherits = FALSE)

  # remove data from the cache directory
  cacheFile <- file.path(cacheDir, paste(cacheKey, "Rdata", sep = "."))
  if (file.exists(cacheFile))
    file.remove(cacheFile)

  # remove any working data
  .rs.removeWorkingData(cacheKey)
 
  invisible(NULL)
})

.rs.addFunction("saveCachedData", function(cacheDir)
{
  # no work to do if we have no cache
  if (!exists(".rs.CachedDataEnv")) 
    return(invisible(NULL))

  # create the cache directory if it doesn't already exist
  dir.create(cacheDir, recursive = TRUE, showWarnings = FALSE, mode = "0700")

  # save each active cache file from the cache environment
  lapply(ls(.rs.CachedDataEnv), function(cacheKey) {
    save(list = cacheKey, 
         file = file.path(cacheDir, paste(cacheKey, "Rdata", sep = ".")),
         envir = .rs.CachedDataEnv)
  })

  # clean the cache environment
  # can generate warnings if .rs.CachedDataEnv disappears (we call this on
  # shutdown); suppress these
  suppressWarnings(rm(list = ls(.rs.CachedDataEnv), where = .rs.CachedDataEnv))

  invisible(NULL)
})

.rs.addFunction("findWorkingData", function(cacheKey)
{
  if (exists(".rs.WorkingDataEnv") &&
      exists(cacheKey, where = .rs.WorkingDataEnv, inherits = FALSE))
    get(cacheKey, envir = .rs.WorkingDataEnv, inherits = FALSE)
  else
    NULL
})

.rs.addFunction("removeWorkingData", function(cacheKey)
{
  if (exists(".rs.WorkingDataEnv") &&
      exists(cacheKey, where = .rs.WorkingDataEnv, inherits = FALSE))
    rm(list = cacheKey, envir = .rs.WorkingDataEnv, inherits = FALSE)
  invisible(NULL)
})

.rs.addFunction("assignWorkingData", function(cacheKey, obj)
{
  assign(cacheKey, obj, .rs.WorkingDataEnv)
})

