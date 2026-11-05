\\ SQLite, over the FFI. It stays out of the image until asked for; load it after
\\ lib/ffi.shen, under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l lib/sqlite.shen -l program.shen
\\
\\ (let Db (sqlite.open "people.db")
\\   (do (sqlite.exec Db "CREATE TABLE IF NOT EXISTS people (name TEXT, age INTEGER)")
\\       (sqlite.run Db "INSERT INTO people VALUES (?, ?)" ["Ann" 30])
\\       (output "~S~%" (sqlite.query Db "SELECT name, age FROM people WHERE age > ?" [20]))
\\       (sqlite.close Db)))
\\
\\ sqlite.open            (sqlite.open Path), ":memory:" for a database in memory
\\ sqlite.close           raises if a prepared statement is still open
\\ sqlite.exec            (sqlite.exec Db Sql) runs statements with no parameters or results
\\ sqlite.run             (sqlite.run Db Sql Params) runs one, and gives the rows it changed
\\ sqlite.query           (sqlite.query Db Sql Params) gives its rows, each a list
\\ sqlite.each            (sqlite.each Db Sql Params F) calls F on each row, keeping none
\\ sqlite.transaction     (sqlite.transaction Db (freeze ...)) commits, or rolls back on an error
\\ sqlite.last-insert-id  (sqlite.last-insert-id Db)
\\ sqlite.version         the library's version, as a string
\\
\\ To use a statement many times: sqlite.prepare, sqlite.bind, sqlite.step, which gives row or
\\ done, sqlite.row, sqlite.reset and sqlite.finalize.
\\
\\ Values go in and come out as Shen values: a number is an INTEGER or a REAL, a string is TEXT,
\\ a byte buffer is a BLOB, and [] is NULL. true and false go in as 1 and 0. An integer past 62
\\ bits raises when it is read.
\\
\\ Errors raise, with SQLite's message. A database or statement that has been closed is dead, and
\\ raises when used. Other threads run during sqlite.step and sqlite.exec, so a connection belongs
\\ to one thread: some builds of SQLite, Apple's among them, do not allow two threads on one.

(shen-jit.library sqlite.lib ["libsqlite3.so.0" "libsqlite3.dylib" "libsqlite3-0.dll" "sqlite3.dll" "winsqlite3.dll"])

(define-foreign sqlite.version sqlite.lib "sqlite3_libversion" () --> string)
(define-foreign sqlite.c-open sqlite.lib "sqlite3_open" (string bytes) --> int32)
(define-foreign sqlite.c-close sqlite.lib "sqlite3_close" (pointer) --> int32)
(define-foreign sqlite.c-errmsg sqlite.lib "sqlite3_errmsg" (pointer) --> string)
(define-foreign sqlite.c-busy-timeout sqlite.lib "sqlite3_busy_timeout" (pointer int32) --> int32)
(define-foreign sqlite.c-exec sqlite.lib "sqlite3_exec" (pointer string pointer pointer pointer) --> int32 blocking)
(define-foreign sqlite.c-prepare sqlite.lib "sqlite3_prepare_v2" (pointer string int32 bytes pointer) --> int32)
(define-foreign sqlite.c-finalize sqlite.lib "sqlite3_finalize" (pointer) --> int32)
(define-foreign sqlite.c-reset sqlite.lib "sqlite3_reset" (pointer) --> int32)
(define-foreign sqlite.c-clear-bindings sqlite.lib "sqlite3_clear_bindings" (pointer) --> int32)
(define-foreign sqlite.c-step sqlite.lib "sqlite3_step" (pointer) --> int32 blocking)
(define-foreign sqlite.c-db-handle sqlite.lib "sqlite3_db_handle" (pointer) --> pointer)
(define-foreign sqlite.c-parameter-count sqlite.lib "sqlite3_bind_parameter_count" (pointer) --> int32)
(define-foreign sqlite.c-bind-int64 sqlite.lib "sqlite3_bind_int64" (pointer int32 int64) --> int32)
(define-foreign sqlite.c-bind-double sqlite.lib "sqlite3_bind_double" (pointer int32 double) --> int32)
(define-foreign sqlite.c-bind-null sqlite.lib "sqlite3_bind_null" (pointer int32) --> int32)
\\ The last argument of these two is SQLITE_TRANSIENT, the pointer value -1: SQLite takes a copy.
(define-foreign sqlite.c-bind-text sqlite.lib "sqlite3_bind_text" (pointer int32 string int32 int64) --> int32)
(define-foreign sqlite.c-bind-blob sqlite.lib "sqlite3_bind_blob" (pointer int32 bytes int32 int64) --> int32)
(define-foreign sqlite.c-column-count sqlite.lib "sqlite3_column_count" (pointer) --> int32)
(define-foreign sqlite.c-column-type sqlite.lib "sqlite3_column_type" (pointer int32) --> int32)
(define-foreign sqlite.c-column-int64 sqlite.lib "sqlite3_column_int64" (pointer int32) --> int64)
(define-foreign sqlite.c-column-double sqlite.lib "sqlite3_column_double" (pointer int32) --> double)
(define-foreign sqlite.c-column-text sqlite.lib "sqlite3_column_text" (pointer int32) --> string)
(define-foreign sqlite.c-column-blob sqlite.lib "sqlite3_column_blob" (pointer int32) --> pointer)
(define-foreign sqlite.c-column-bytes sqlite.lib "sqlite3_column_bytes" (pointer int32) --> int32)
(define-foreign sqlite.c-changes sqlite.lib "sqlite3_changes" (pointer) --> int32)
(define-foreign sqlite.c-last-insert-rowid sqlite.lib "sqlite3_last_insert_rowid" (pointer) --> int64)

(define sqlite.fail
  Db -> (error "sqlite: ~A" (sqlite.c-errmsg Db)))

(define sqlite.statement-fail
  Stmt -> (sqlite.fail (sqlite.c-db-handle Stmt)))

\\ Opening can fail and still give a handle, which holds the message and must be closed.
(define sqlite.open
  Path -> (let Out (shen-jit.bytes 8)
               Rc (sqlite.c-open Path Out)
               Db (shen-jit.bytes->pointer Out 0 sqlite3)
            (if (= Rc 0)
                (do (sqlite.c-busy-timeout Db 5000) Db)
                (let Message (if (= Db []) "out of memory" (sqlite.c-errmsg Db))
                  (do (sqlite.c-close Db)
                      (error "sqlite: cannot open ~A: ~A" Path Message))))))

(define sqlite.close
  Db -> (if (= (sqlite.c-close Db) 0)
            (do (shen-jit.pointer-kill Db) true)
            (sqlite.fail Db)))

(define sqlite.exec
  Db Sql -> (if (= (sqlite.c-exec Db Sql [] [] []) 0) true (sqlite.fail Db)))

(define sqlite.last-insert-id
  Db -> (sqlite.c-last-insert-rowid Db))

\\ Statements.

\\ SQL with nothing to run, only a comment for instance, gives no statement.
(define sqlite.prepare
  Db Sql -> (let Out (shen-jit.bytes 8)
                 Rc (sqlite.c-prepare Db Sql -1 Out [])
                 Stmt (shen-jit.bytes->pointer Out 0 sqlite3-statement)
              (cases (not (= Rc 0)) (sqlite.fail Db)
                     (= Stmt []) (error "sqlite: no statement in ~S" Sql)
                     true Stmt)))

(define sqlite.finalize
  Stmt -> (do (sqlite.c-finalize Stmt) (shen-jit.pointer-kill Stmt) true))

(define sqlite.reset
  Stmt -> (do (sqlite.c-reset Stmt) (sqlite.c-clear-bindings Stmt) true))

(define sqlite.bind
  Stmt Params -> (let Wanted (sqlite.c-parameter-count Stmt)
                   (if (= Wanted (length Params))
                       (sqlite.bind-from Stmt 1 Params)
                       (error "sqlite: expected ~A parameters, got ~A" Wanted (length Params)))))

(define sqlite.bind-from
  _ _ [] -> true
  Stmt I [V | Vs] -> (if (= (sqlite.bind-one Stmt I V) 0)
                         (sqlite.bind-from Stmt (+ I 1) Vs)
                         (sqlite.statement-fail Stmt)))

(define sqlite.bind-one
  Stmt I [] -> (sqlite.c-bind-null Stmt I)
  Stmt I true -> (sqlite.c-bind-int64 Stmt I 1)
  Stmt I false -> (sqlite.c-bind-int64 Stmt I 0)
  Stmt I V -> (sqlite.c-bind-text Stmt I V -1 -1) where (string? V)
  Stmt I V -> (sqlite.c-bind-blob Stmt I V (shen-jit.bytes-length V) -1) where (shen-jit.bytes? V)
  Stmt I V -> (sqlite.c-bind-int64 Stmt I V) where (sqlite.fixnum? V)
  Stmt I V -> (sqlite.c-bind-double Stmt I V) where (number? V)
  _ _ V -> (error "sqlite: cannot store ~S" V))

\\ Bit operations take only fixnums, and a real may have no fraction.
(define sqlite.fixnum?
  V -> (trap-error (= V (shen-jit.bit-or V 0)) (/. E false)))

(define sqlite.step
  Stmt -> (let Rc (sqlite.c-step Stmt)
            (cases (= Rc 100) row
                   (= Rc 101) done
                   true (sqlite.statement-fail Stmt))))

(define sqlite.row
  Stmt -> (sqlite.columns Stmt (- (sqlite.c-column-count Stmt) 1) []))

(define sqlite.columns
  _ -1 Row -> Row
  Stmt I Row -> (sqlite.columns Stmt (- I 1) [(sqlite.value Stmt I (sqlite.c-column-type Stmt I)) | Row]))

\\ By SQLite's codes for INTEGER, FLOAT, TEXT and BLOB; 5 is NULL.
(define sqlite.value
  Stmt I 1 -> (sqlite.c-column-int64 Stmt I)
  Stmt I 2 -> (sqlite.c-column-double Stmt I)
  Stmt I 3 -> (sqlite.c-column-text Stmt I)
  Stmt I 4 -> (sqlite.blob Stmt I)
  _ _ _ -> [])

\\ In this order, as SQLite asks. An empty blob's pointer is NULL.
(define sqlite.blob
  Stmt I -> (let P (sqlite.c-column-blob Stmt I)
                 N (sqlite.c-column-bytes Stmt I)
              (if (= P []) (shen-jit.bytes 0) (shen-jit.pointer->bytes P 0 N))))

\\ One statement, finalized however F ends.
(define sqlite.with-statement
  Db Sql Params F
  -> (let Stmt (sqlite.prepare Db Sql)
          Result (trap-error (do (sqlite.bind Stmt Params) (F Stmt))
                             (/. E (do (sqlite.finalize Stmt) (simple-error (error-to-string E)))))
       (do (sqlite.finalize Stmt) Result)))

(define sqlite.query
  Db Sql Params -> (sqlite.with-statement Db Sql Params (/. Stmt (sqlite.rows Stmt []))))

(define sqlite.rows
  Stmt Rows -> (if (= (sqlite.step Stmt) row)
                   (sqlite.rows Stmt [(sqlite.row Stmt) | Rows])
                   (reverse Rows)))

(define sqlite.each
  Db Sql Params F -> (sqlite.with-statement Db Sql Params (/. Stmt (sqlite.each-row Stmt F))))

(define sqlite.each-row
  Stmt F -> (if (= (sqlite.step Stmt) row)
                (do (F (sqlite.row Stmt)) (sqlite.each-row Stmt F))
                true))

(define sqlite.run
  Db Sql Params -> (sqlite.with-statement Db Sql Params
                     (/. Stmt (do (sqlite.each-row Stmt (/. Row skip)) (sqlite.c-changes Db)))))

(define sqlite.transaction
  Db F -> (do (sqlite.exec Db "BEGIN")
              (let Result (trap-error (thaw F)
                                      (/. E (do (sqlite.exec Db "ROLLBACK")
                                                (simple-error (error-to-string E)))))
                (do (sqlite.exec Db "COMMIT") Result))))
