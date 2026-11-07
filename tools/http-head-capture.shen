\\ A bounded one-connection header capture, useful before adding HTTP request semantics.
\\ Load ffi/socket/buffer/io/deadline/clock/io-socket/http-head first. This sends no HTTP response.

(define http-head.capture
  E Limit Milliseconds ->
    (io.with-endpoint E
      (/. Connection
        (let D (clock.deadline Milliseconds)
             _ (io.socket-deadline Connection D)
             F (http.head-reader (io.reader Connection []) Limit)
          (http-head.capture-result (http.read-head-until F D))))))

(define http-head.capture-result
  [head V] -> [ok V]
  [error Error] -> [error Error]
  [eof] -> [error (io.error http-head "HTTP head" "connection ended before a head")])
