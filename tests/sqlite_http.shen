(set counter-test.passed 0)
(set counter-test.failed 0)

(define counter-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Actual)
          (set counter-test.passed (+ 1 (value counter-test.passed)))
          (do (set counter-test.failed (+ 1 (value counter-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define counter-test.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(define counter-test.response
  Method Target ->
    (let Response (counter-app.route (value counter-test.path) Method Target)
      [(<-address Response 1) (buffer.string (<-address Response 3))]))

(counter-app.initialize (value counter-test.path))
(counter-test.check "health" [200 "{c#34;statusc#34;:c#34;okc#34;}"]
  (freeze (counter-test.response "GET" "/health")))
(counter-test.check "health method policy" [405 ""] (freeze (counter-test.response "POST" "/health")))
(counter-test.check "empty list" [200 "[]"] (freeze (counter-test.response "GET" "/counters")))
(counter-test.check "counter creation" [200 "{c#34;valuec#34;:1}"]
  (freeze (counter-test.response "POST" "/counters/hits")))
(counter-test.check "counter increment" [200 "{c#34;valuec#34;:2}"]
  (freeze (counter-test.response "POST" "/counters/hits")))
(counter-test.check "counter read" [200 "{c#34;valuec#34;:2}"]
  (freeze (counter-test.response "GET" "/counters/hits")))
(counter-test.check "bounded counter list" [200 "[{c#34;namec#34;:c#34;hitsc#34;,c#34;valuec#34;:2}]"]
  (freeze (counter-test.response "GET" "/counters")))
(counter-test.check "counter deletion" [204 ""] (freeze (counter-test.response "DELETE" "/counters/hits")))
(counter-test.check "deleted counter" [404 "{c#34;errorc#34;:c#34;counter not foundc#34;}"]
  (freeze (counter-test.response "GET" "/counters/hits")))
(map (/. Target
       (counter-test.check "invalid name" [] (freeze (counter-app.name Target))))
  ["/counters/" "/counters/a/b" "/counters/a%20b" "/counters/a?b" "/counters/a'b"])
(counter-test.check "in-memory database rejected" true
  (freeze (counter-test.raises? (freeze (counter-app.initialize ":memory:")))))
(counter-test.check "numeric CLI port" 65535 (freeze (counter-app.port-number "65535")))
(counter-test.check "oversized CLI port" true
  (freeze (counter-test.raises? (freeze (counter-app.port-number "65536")))))
(counter-test.check "nondecimal CLI port" true
  (freeze (counter-test.raises? (freeze (counter-app.port-number "80junk")))))
(counter-app.with-db (value counter-test.path)
  (/. Db
    (do (sqlite.run Db "INSERT INTO counters VALUES (?, ?)" ["limit" 1000000000000])
        (counter-test.check "constraint failure propagates" true
          (freeze (counter-test.raises? (freeze (counter-app.increment Db "limit")))))
        (counter-test.check "failed increment rolls back" [[1000000000000]]
          (freeze (sqlite.query Db "SELECT value FROM counters WHERE name = ?" ["limit"]))))))
(output "~A passed, ~A failed~%" (value counter-test.passed) (value counter-test.failed))
