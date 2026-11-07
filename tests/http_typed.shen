\\ Load libraries with tc off, then check this client.
(define http-typed.value
  {http.head-result --> string}
  [head V] -> (buffer.string V)
  [eof] -> "end"
  [error Error] -> (io.error-message Error))

(define http-typed.install
  {io.endpoint --> number --> io.endpoint}
  E Milliseconds -> (io.socket-deadline E (clock.deadline Milliseconds)))

(define http-typed.run
  {--> boolean}
  ->
    (let D (deadline.after (freeze 0) 20)
         E (io.input-buffer (buffer.from-string "xc#13;c#10;c#13;c#10;body"))
         R (io.reader E [[chunk-size 1]])
         F (http.head-reader R 8)
         Head (http-typed.value (http.read-head-until F D))
         Next (io.peek-some R)
         Left (deadline.remaining D)
         _ (io.close E)
      (and (= Head "xc#13;c#10;c#13;c#10;") (= Left 20))))

(output "~A~%" (if (http-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))
