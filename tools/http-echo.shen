\\ One connected request, bounded bodies, Content-Length and Connection: close.
\\ Load the HTTP server libraries before this example. No listener loop or task pool is created.

(define http-echo.handler
  Request ->
    (if (element? (http.method Request) ["GET" "HEAD" "POST" "PUT" "PATCH" "DELETE" "OPTIONS"])
        (if (= (http.target Request) "/health")
            (http.response 200 [["Content-Type" "text/plain"]] (buffer.from-string "ok"))
            (http.response 200 [["Content-Type" "application/octet-stream"]] (http.body Request)))
        (http.response 501 [] (buffer.new 0))))

(define http-echo.serve
  E Options -> (http.serve-one E (function http-echo.handler) Options))
