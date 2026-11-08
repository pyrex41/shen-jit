\\ A small persistent counter API. Load the public HTTP listener and SQLite libraries first.
\\ Each database connection belongs to the request worker that opens it.

(define counter-app.with-db
  Path F ->
    (let Db (sqlite.open Path)
         Result (trap-error [ok (F Db)] (/. X [error (error-to-string X)]))
         Closed (trap-error (do (sqlite.close Db) [ok]) (/. X [error (error-to-string X)]))
      (counter-app.db-result Result Closed)))

(define counter-app.db-result
  [ok Value] [ok] -> Value
  [error Message] [ok] -> (simple-error Message)
  [ok _] [error Message] -> (simple-error Message)
  [error Message] [error Cleanup] ->
    (simple-error (make-string "~A; closing database: ~A" Message Cleanup)))

(define counter-app.initialize
  Path ->
    (do (if (or (= Path "") (= Path ":memory:")) (error "counter app needs a database file") true)
        (counter-app.with-db Path
          (/. Db (sqlite.exec Db
            "CREATE TABLE IF NOT EXISTS counters (
               name TEXT PRIMARY KEY,
               value INTEGER NOT NULL CHECK(value BETWEEN 0 AND 1000000000000)
             )")))))

(define counter-app.json
  Status Value ->
    (http.response Status [["Content-Type" "application/json"]] (json.encode Value [[byte-limit 65536]])))

(define counter-app.error
  Status Message ->
    (counter-app.json Status [object ["error" Message]]))

(define counter-app.name-byte?
  B -> (or (and (>= B 65) (<= B 90))
           (and (>= B 97) (<= B 122))
           (and (>= B 48) (<= B 57))
           (= B 45) (= B 95)))

(define counter-app.name-range?
  _ At At -> true
  B At End ->
    (and (counter-app.name-byte? (shen-jit.u8 B At)) (counter-app.name-range? B (+ At 1) End)))

(define counter-app.name
  Target ->
    (let B (shen-jit.string->bytes Target)
         N (shen-jit.bytes-length B)
      (if (and (> N 10) (<= N 74)
               (= (shen-jit.bytes->string B 0 10) "/counters/")
               (counter-app.name-range? B 10 N))
          (shen-jit.bytes->string B 10 (- N 10))
          [])))

(define counter-app.row-json
  [Name Value] -> [object ["name" Name] ["value" Value]])

(define counter-app.list
  Db -> (counter-app.json 200
          (map (function counter-app.row-json)
               (sqlite.query Db "SELECT name, value FROM counters ORDER BY name LIMIT 100" []))))

\\ The export owns its statement/database until the response source closes, including HEAD.
(define counter-app.export
  Path ->
    (let Db (sqlite.open Path)
         Stmt (trap-error (sqlite.prepare Db "SELECT name, value FROM counters ORDER BY name LIMIT 100")
                (/. X (counter-app.db-result [error (error-to-string X)]
                         (trap-error (do (sqlite.close Db) [ok])
                           (/. Y [error (error-to-string Y)])))))
         State (io.record [Stmt (buffer.new 0) 0])
      (trap-error
        (http.stream-response 200 [["Content-Type" "application/x-ndjson"]] [chunked]
          (http.source (/. Maximum D (counter-app.export-next State Maximum D))
                       (freeze (counter-app.export-close Db Stmt))))
        (/. X (do (counter-app.export-close Db Stmt) (simple-error (error-to-string X)))))))

(define counter-app.export-close
  Db Stmt ->
    (let Finalized (trap-error (do (sqlite.finalize Stmt) [ok 0])
                      (/. X [error (io.error close "counter export statement" (error-to-string X)) 0]))
         Closed (trap-error (do (sqlite.close Db) [ok])
                   (/. X [error (io.error close "counter export database" (error-to-string X))]))
      (io.close-combine Finalized Closed)))

(define counter-app.export-next
  State Maximum D ->
    (do (deadline.check D)
        (if (= (<-address State 2) (buffer.length (<-address State 1)))
            (if (= (sqlite.step (<-address State 0)) done)
                [eof]
                (let Row (json.encode (counter-app.row-json (sqlite.row (<-address State 0))) [[byte-limit 4096]])
                     Line (buffer.builder 4097)
                     _ (buffer.append! Line Row)
                     _ (buffer.append-byte! Line 10)
                     _ (address-> State 1 (buffer.finish Line))
                     _ (address-> State 2 0)
                  (counter-app.export-span State Maximum)))
            (counter-app.export-span State Maximum))))

(define counter-app.export-span
  State Maximum ->
    (let At (<-address State 2)
         N (io.min Maximum (- (buffer.length (<-address State 1)) At))
         V (buffer.slice (<-address State 1) At N)
      (do (address-> State 2 (+ At N)) [chunk V])))

(define counter-app.found
  [] -> (counter-app.error 404 "counter not found")
  [[Value]] -> (counter-app.json 200 [object ["value" Value]]))

(define counter-app.increment
  Db Name ->
    (sqlite.transaction Db
      (freeze
        (do (sqlite.run Db "INSERT OR IGNORE INTO counters (name, value) VALUES (?, 0)" [Name])
            (sqlite.run Db "UPDATE counters SET value = value + 1 WHERE name = ?" [Name])
            (counter-app.found (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))))))

(define counter-app.counter
  Db "GET" Name -> (counter-app.found (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))
  Db "HEAD" Name -> (counter-app.counter Db "GET" Name)
  Db "POST" Name -> (counter-app.increment Db Name)
  Db "DELETE" Name ->
    (if (= (sqlite.run Db "DELETE FROM counters WHERE name = ?" [Name]) 0)
        (counter-app.error 404 "counter not found")
        (http.response 204 [] (buffer.new 0)))
  _ _ _ -> (http.response 405 [["Allow" "GET, HEAD, POST, PUT, DELETE"]] (buffer.new 0)))

(define counter-app.route
  _ "GET" "/health" -> (counter-app.json 200 [object ["status" "ok"]])
  _ "HEAD" "/health" -> (counter-app.json 200 [object ["status" "ok"]])
  _ _ "/health" -> (http.response 405 [["Allow" "GET, HEAD"]] (buffer.new 0))
  Path Method "/counters.ndjson" ->
    (if (element? Method ["GET" "HEAD"])
        (counter-app.export Path)
        (http.response 405 [["Allow" "GET, HEAD"]] (buffer.new 0)))
  Path Method "/counters" ->
    (if (element? Method ["GET" "HEAD"])
        (counter-app.with-db Path (function counter-app.list))
        (http.response 405 [["Allow" "GET, HEAD"]] (buffer.new 0)))
  Path Method Target ->
    (let Name (counter-app.name Target)
      (if (empty? Name)
          (counter-app.error 404 "route not found")
          (counter-app.with-db Path (/. Db (counter-app.counter Db Method Name))))))

(define counter-app.handle
  Path Request ->
    (let Name (counter-app.name (http.target Request))
      (cond ((and (= (http.method Request) "PUT") (not (empty? Name)))
              (counter-app.set-request Path Name Request))
            ((= (http.content-length Request) 0)
              (counter-app.route Path (http.method Request) (http.target Request)))
            (true (counter-app.error 400 "this route expects an empty body")))))

(define counter-app.lower
  Text ->
    (let B (buffer.from-string Text)
         _ (counter-app.lower-bytes (buffer.owner B) 0 (buffer.length B))
      (buffer.string B)))

(define counter-app.lower-bytes
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
         _ (if (and (>= Byte 65) (<= Byte 90)) (shen-jit.u8! B At (+ Byte 32)) true)
      (counter-app.lower-bytes B (+ At 1) End)))

(define counter-app.json-type?
  [Value] -> (element? (counter-app.lower Value)
                ["application/json" "application/json; charset=utf-8" "application/json;charset=utf-8"])
  _ -> false)

(define counter-app.json-error
  X ->
    (let Text (error-to-string X)
         B (shen-jit.string->bytes Text)
      (if (and (>= (shen-jit.bytes-length B) 6) (= (shen-jit.bytes->string B 0 6) "json: "))
          [invalid] (simple-error Text))))

(define counter-app.input-value
  [object ["value" Value]] ->
    (let N (json.integer Value) (if (and (>= N 0) (<= N 1000000000000)) [ok N] [invalid]))
  _ -> [invalid])

(define counter-app.set-request
  Path Name Request ->
    (if (counter-app.json-type? (http.header-values Request "content-type"))
        (let Value (trap-error
                      (counter-app.input-value (json.decode (http.body Request) [[byte-limit 4096]]))
                      (function counter-app.json-error))
          (counter-app.set-input Path Name Value))
        (counter-app.error 415 "expected application/json")))

(define counter-app.set-input
  _ _ [invalid] -> (counter-app.error 400 "expected an object with one decimal integer value in 0..1000000000000")
  Path Name [ok N] ->
    (counter-app.with-db Path
      (/. Db (sqlite.transaction Db
               (freeze
                 (do (sqlite.run Db "INSERT OR IGNORE INTO counters (name, value) VALUES (?, 0)" [Name])
                     (sqlite.run Db "UPDATE counters SET value = ? WHERE name = ?" [N Name])
                     (counter-app.found (sqlite.query Db "SELECT value FROM counters WHERE name = ?" [Name]))))))))

(define counter-app.start
  Path Host Port Options ->
    (do (counter-app.initialize Path)
        (http.listen Host Port (/. Request (counter-app.handle Path Request)) Options)))

(define counter-app.await
  S -> (counter-app.await-result S (http.wait S 1000)))

(define counter-app.await-result
  S [pending] -> (counter-app.await S)
  _ [ok] -> true
  _ [error Error] -> (error "counter server: ~A" (io.error-message Error)))

(define counter-app.run
  Path Port ->
    (let Stop (io.record [false])
         _ (counter-app.initialize Path)
         S (http.listen "127.0.0.1" Port (/. Q (counter-app.control Path Stop Q))
              [[max-connections 16] [shutdown-grace 1000] [body-limit 4096]
               [response-body-limit 65536]])
         _ (output "Listening on http://127.0.0.1:~A~%" (http.port S))
      (trap-error (counter-app.run-until-stopped S Stop)
        (/. X (do (http.stop S)
                  (counter-app.await S)
                  (simple-error (error-to-string X)))))))

(define counter-app.control
  Path Stop Request ->
    (if (= (http.target Request) "/shutdown")
        (cond ((not (= (http.method Request) "POST"))
                (http.response 405 [["Allow" "POST"]] (buffer.new 0)))
              ((> (http.content-length Request) 0)
                (counter-app.error 400 "this API expects an empty body"))
              (true (do (address-> Stop 0 true)
                        (http.close-after (counter-app.json 202 [object ["stopping" true]])))))
        (counter-app.handle Path Request)))

(define counter-app.run-until-stopped
  S Stop ->
    (if (<-address Stop 0)
        (do (http.stop S) (counter-app.await S))
        (counter-app.control-result S Stop (http.wait S 100))))

(define counter-app.control-result
  S Stop [pending] -> (counter-app.run-until-stopped S Stop)
  _ _ [ok] -> true
  _ _ [error Error] -> (error "counter server: ~A" (io.error-message Error)))

(define counter-app.port-number
  Text ->
    (let B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (> N 0) (counter-app.port-digits B 0 N 0) (error "empty port"))))

(define counter-app.port-digits
  _ At At N -> N
  B At End N ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (and (>= Digit 0) (<= Digit 9) (<= N 6553) (or (< N 6553) (<= Digit 5)))
          (counter-app.port-digits B (+ At 1) End (+ (* N 10) Digit))
          (error "port must be decimal 0..65535"))))

(define counter-app.main
  [_ Path Port] -> (counter-app.run Path (counter-app.port-number Port))
  _ -> (error "usage: shen-jit script example-apps/sqlite-http/run.shen DATABASE PORT"))
