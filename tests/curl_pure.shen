(set curl-pure.passed 0)
(set curl-pure.failed 0)
(define curl-pure.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set curl-pure.passed (+ 1 (value curl-pure.passed)))
          (do (set curl-pure.failed (+ 1 (value curl-pure.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(curl-pure.check "scheme canonicalized" "https://example.test/a"
  (freeze (curl.url-check "hTtPs://example.test/a")))
(curl-pure.check "response fields preserve repeats and unfold older curl lines"
  [["x-a" "one two"] ["x-a" "three"]]
  (freeze (curl.parse-fields
            (buffer.from-string "HTTP/1.1 200 OKc#13;c#10;X-A: onec#13;c#10;c#9;twoc#13;c#10;X-A: threec#13;c#10;c#13;c#10;") true)))
(curl-pure.check "LF-only fields" [["x" "one"]]
  (freeze (curl.parse-fields (buffer.from-string "HTTP/2 200c#10;X: onec#10;c#10;") true)))
(curl-pure.check "empty outgoing header uses libcurl's explicit-empty syntax" ["X;"]
  (freeze (curl.request-fields [["X" ""]] 0 0 [])))
(map (/. Text
       (curl-pure.check "bad URL refused before native open" true
         (freeze (trap-error (do (curl.get Text []) false) (/. X true)))))
  ["file:///not-read" "ftp://not-used" "http://ac#0;b"])
(map (/. Text
       (curl-pure.check "malformed response fields refused" true
         (freeze (trap-error (do (curl.parse-fields (buffer.from-string Text) false) false) (/. X true)))))
  ["X: ac#0;bc#10;" "X: ac#13;bc#10;" "Bad Name: ac#10;" "foldedc#10;" "c#9;orphanedc#10;"])
(map (/. Options
       (curl-pure.check "pure configuration rejects invalid input" true
         (freeze (trap-error (do (curl.options Options) false) (/. X true)))))
  [[[timeout 0]] [[connect-timeout 0]] [[body-limit -1]] [[request-limit 268435457]]
   [[header-limit 1048577]] [[redirect-limit 21]] [[timeout (+ 0.5 0.5)]]
   [[proxy "ac#0;b"]] [[ca-file ""]] [[unknown 1]] [[body-limit 1] [body-limit 2]]])
(output "~A passed, ~A failed~%" (value curl-pure.passed) (value curl-pure.failed))
