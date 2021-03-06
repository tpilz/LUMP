# lumpR/db_create.R
# Copyright (C) 2015, 2017 Tobias Pilz
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.



#' Create parameter database
#' 
#' Function creates tables in a pre-defined database to store parameters relevant
#' for modelling applications with the WASA model.
#'
#' @param dbname Name of the data source (DSN) registered at ODBC. See \code{Details}.
#' @param overwrite  \code{c(NULL,"drop","empty")}. Delete and re-create (\code{"drop"}) or empty  (\code{"empty"}) any tables already existing in db. Default: NULL (keep all existing tables). In any case, tables included in \emph{keep_tables} remain untouched.
#' @param keep_tables Vector of type \code{character}. Preserves the specified tables, if existing. Overrides \emph{overwrite}. Default: NULL.
#' @param db_ver \code{numeric}. If \code{Inf} (default) the database will be updated
#' to the latest version calling \code{\link[lumpR]{db_update}} internally. Otherwise, the
#' specified version is created. The earliest possible version is 19.
#' @details
#'  This package uses the ODBC interface to connect to a database. Creating the database
#'requires the following prior steps which are OS dependent:
#'  \itemize{
#'    \item{Install a \emph{Database Management System} and respective \emph{ODBC-driver} and on your computer.
#'      Currently supported (tested) are: SQLite (v. 3.8.9), MariaDB/MySQL (v. 10.0.17), 
#'      MS Access.}
#'    \item{Register an empty database at your ODBC configuration.}
#'  }  
#'Calling \emph{db_create} creates the necessary tables in the database. These are then filled and processed by subsequent function of \emph{lumpR}.
#'More information can be found at the lumpR package wiki: \url{https://github.com/tpilz/lumpR/wiki}
#' 
#' @references 
#'      lumpR package introduction with literature study and sensitivity analysis:\cr
#'      Pilz, T.; Francke, T.; Bronstert, A. (2017): lumpR 2.0.0: an R package facilitating
#'      landscape discretisation for hillslope-based hydrological models.
#'      \emph{Geosci. Model Dev.}, 10, 3001-3023, doi: 10.5194/gmd-10-3001-2017
#'      
#' @author 
#'  Tobias Pilz \email{tpilz@@uni-potsdam.de}, Till Francke \email{francke@@uni-potsdam.de}
#' 
db_create <- function(
  dbname, overwrite=NULL, keep_tables=NULL, db_ver=Inf
) {
  
  if(db_ver < 19) {
    stop("Argument 'db_ver' less than 19 is not possible.")
  }
  
  if (is.null(overwrite)) overwrite="" #facilitates following conditionals
  
  # connect to ODBC registered database
  con <- connect_db(dbname)
  
  dbs_name = odbcGetInfo(con)["DBMS_Name"] #determine the kind of database used
  # ensure MySQL/MariaDB uses ANSI quotation (double quotes instead of back ticks)
  if(grepl("MariaDB", dbs_name, ignore.case=T))
    sqlQuery(con, "SET sql_mode='ANSI';")
  
  if(grepl("ACCESS", dbs_name, ignore.case=T) && overwrite=="drop")
    warning("You are using an Access database and option overwrite='drop'. Due to technical restrictions, this may cause errors. In this case, please delete the tables manually using MS Access and re-run without this option.")
    
  #get current version of DB, if any
  db_ver_init = sqlQuery(con, "select version from db_version;")
  if (is.data.frame(db_ver_init))
    db_ver_init = db_ver_init$version[nrow(db_ver_init)] #use last row
  else
    db_ver_init = 19 #no current version available, assume the first of db_update
  
  
  if (overwrite == "empty")
    keep_tables = unique(c(keep_tables, "db_version")) #conserve table "db_version" anyway
  
  if (overwrite == "drop" && ("db_version" %in% keep_tables))
    warning("Dropping all tables but keeping 'db_version' will likely corrupt the updating process. Please do not conserve this table or reset db_version manually.")
  
  
  # read file with sql statements to create tables of the database
  sql_file <- system.file("database/create_db.sql", package="lumpR")
  script  <- readLines(sql_file)
  
  # identify individual queries of the script
  script <- gsub("--.*", "", script)
  script <- gsub("\t", "", script)
  script <- paste(script, collapse=" ")
  scriptparts <- strsplit(script, ";")[[1]]
  scriptparts <- scriptparts[-length(scriptparts)]
  
  if (overwrite=="") 
    keep_tables = sqlTables(con)$TABLE_NAME #keep all existing tables
  
  # loop over queries
  tbls_created <- NULL
  for(i in seq(along=scriptparts)){
    
    statement <- scriptparts[i]
    
    # identify table name
    is_create_statement = grepl(statement, pattern="^[[:space:]]*CREATE|create")
    
    if (is_create_statement) {
      tablename <- gsub("CREATE TABLE *([[:alpha:]_]+).*","\\1",statement)
      tbls_created <- c(tbls_created, gsub("[[:space:]]*", "", tablename))
    } else
      tablename <- gsub("INSERT INTO *([[:alpha:]_]+).*","\\1",statement) #extract name of table from CREATE statements
    if (tablename == statement) tablename="(none)"   #set to "(none)" for non-CREATE statements
    tablename <- gsub("[[:space:]]*", "", tablename)
    
    
    # adjust to specific SQL dialects
    statement <- sql_dialect(con, statement)

    skip=TRUE
    if(is_create_statement & tablename %in% sqlTables(con)$TABLE_NAME) 
    {
      if (!is.null(overwrite) &  !(tablename %in% keep_tables)) #delete / empty existing table
      {
        if (overwrite %in% c("drop","empty"))
        {
          if (overwrite=="drop")
          {  
            s2 = paste0("drop table ", tablename,";")
            skip = FALSE
          }  
          if (overwrite=="empty")
          {  
            s2 = paste0("DELETE FROM ", tablename,";")
            message(paste0("Found existing table ", tablename, ", emptying..."))
            #browser()
          }
          res <- sqlQuery2(con, s2, info = "deleting (from) table")
        }  
      } 
    } else {
      skip <- FALSE
    } 

    if (!is_create_statement & (tablename %in% keep_tables)) #don't alter tables that are to be kept
      skip = TRUE
    
    
    if (skip & !is.null(overwrite) && (overwrite!="empty"))    
      message(paste0("Found existing table ", tablename, ", preserved. Use overwrite=... to drop or empty it."))
    else
    if (!skip)
    {  
      #browser()
      # create table in database if it does not yet exist
      res <- sqlQuery2(con, statement, info = "(creating db)")
  
    } # skip?
    
  } # loop over scriptparts
  
  # delete other tables (those that shall not be preserved and are not part of the base version 19 which is created here)
  tbls <- sqlTables(con, tableType="TABLE")[,"TABLE_NAME"]
  tbls = tbls[!grepl(x = tbls, "^MSys")] #ignore MS Access internal tables
  
  r_tbls_del <- which(!(tbls %in% c(keep_tables, tbls_created)))
  for (tbl in tbls[r_tbls_del] ) {
    statement = paste0("drop table ", tbl,";")
    res <- sqlQuery2(con, statement, info="deleting superfluous tables")
  }
  
  # update table meta_info
  meta_dat <- sqlFetch(con, "meta_info")
  if(any(meta_dat$pid)) {
    pid_new <- max(meta_dat$pid) +1
  } else {
    pid_new <- 1
  }
  
  db_ver_cur = sqlQuery(con, "select version from db_version;")
  db_ver_cur = db_ver_cur$version[nrow(db_ver_cur)] #use last row
  
  meta_out <- data.frame(pid=pid_new,
                         mod_date=as.POSIXct(Sys.time()),
                         mod_user=paste0("db_create(), v. ", installed.packages()["lumpR","Version"]),
                         affected_tables="all",
                         affected_columns="all",
                         remarks=paste0("Created database version ", db_ver_cur, " using R package lumpR."))
  write_datetabs(con, meta_out, tab="meta_info", verbose=F)
  
  # update database if desired
  # close connection
  tryCatch(odbcClose(con), error=function(e){})
  
  if (db_ver > 19)
  {  
    if (!is.null(keep_tables)) #first, update until version encountered before, keeping protected tables
      db_update(dbname = dbname, to_ver = db_ver_init, keep_tables = keep_tables)

    db_update(dbname, to_ver = db_ver)
  }
  
    
  
  
} # EOF
