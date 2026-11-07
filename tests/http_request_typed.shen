\\ Typed metadata, body completion, response encoding and the one-request driver.
(define request-typed.handler
  {http.request --> http.response}
  Request -> (http.response 200 [["Content-Type" "application/octet-stream"]] (http.body Request)))

(define request-typed.serve
  {io.endpoint --> (io.result number)}
  E -> (http.serve-one E (function request-typed.handler)
                      [[head-limit 4096] [body-limit 1024] [write-timeout 1000]]))

(define request-typed.completed
  {(io.result http.request) --> boolean}
  [error Error] -> false
  [ok Request] ->
    (let Wire (http.encode-response Request (request-typed.handler Request) 4096 1024)
      (and (= (http.method Request) "POST") (> (buffer.length Wire) 3))))

(define request-typed.parsed
  {(io.result http.request) --> boolean}
  [error Error] -> false
  [ok Request] ->
    (let E (io.input-buffer (buffer.from-string "abc"))
         R (io.reader E [])
         B (http.body-reader R Request)
         Result (request-typed.completed (http.read-body B))
         _ (io.close E)
      Result))

(define request-typed.run
  {--> boolean}
  -> (request-typed.parsed (http.parse-request
       (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 3c#13;c#10;c#13;c#10;") 3)))

(output "~A~%" (if (request-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))
