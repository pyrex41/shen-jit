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
  Status Text ->
    (http.response Status [["Content-Type" "application/json"]] (buffer.from-string Text)))

(define counter-app.error
  Status Message ->
    (counter-app.json Status (make-string "{c#34;errorc#34;:c#34;~Ac#34;}" Message)))

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
  [Name Value] -> (make-string "{c#34;namec#34;:c#34;~Ac#34;,c#34;valuec#34;:~A}" Name Value))

(define counter-app.join
  [] -> ""
  [Text] -> Text
  [Text | Rest] -> (cn Text (cn "," (counter-app.join Rest))))

(define counter-app.list
  Db ->
    (let Rows (sqlite.query Db "SELECT name, value FROM counters ORDER BY name LIMIT 100" [])
      (counter-app.json 200 (cn "[" (cn (counter-app.join (map (function counter-app.row-json) Rows)) "]")))))

(define counter-app.found
  [] -> (counter-app.error 404 "counter not found")
  [[Value]] -> (counter-app.json 200 (make-string "{c#34;valuec#34;:~A}" Value)))

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
  _ _ _ -> (http.response 405 [["Allow" "GET, HEAD, POST, DELETE"]] (buffer.new 0)))

(define counter-app.route
  _ "GET" "/health" -> (counter-app.json 200 "{c#34;statusc#34;:c#34;okc#34;}")
  _ "HEAD" "/health" -> (counter-app.json 200 "{c#34;statusc#34;:c#34;okc#34;}")
  _ _ "/health" -> (http.response 405 [["Allow" "GET, HEAD"]] (buffer.new 0))
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
    (if (= (http.content-length Request) 0)
        (counter-app.route Path (http.method Request) (http.target Request))
        (counter-app.error 400 "this API expects an empty body")))

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
                        (counter-app.json 202 "{c#34;stoppingc#34;:true}"))))
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
