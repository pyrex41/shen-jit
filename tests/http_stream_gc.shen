\\ All libraries are loaded in the image; every allocation below collects.
(let Chunks (io.record [false])
     Closed (io.record [0])
     Source (http.source (/. N D (if (<-address Chunks 0) [eof]
                                  (do (address-> Chunks 0 true) [chunk (buffer.from-string "hello")])))
                         (freeze (do (address-> Closed 0 (+ 1 (<-address Closed 0))) [ok])))
     Response (http.stream-response 200 [] [chunked] Source)
     Q (hd (tl (http.parse-request
                 (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") 0)))
     Out (buffer.new 256)
     E (io.output-buffer Out)
     Result (http.send-response E Q Response (deadline.after (freeze 0) 100) [])
     _ (io.close E)
  (if (and (= (hd Result) ok) (= (<-address Closed 0) 1)
           (= (buffer.string (buffer.slice Out 0 (hd (tl Result))))
              "HTTP/1.1 200 OKc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;Connection: closec#13;c#10;c#13;c#10;5c#13;c#10;helloc#13;c#10;0c#13;c#10;c#13;c#10;"))
      (output "stream gc ok~%") (error "response stream failed under GC stress")))
