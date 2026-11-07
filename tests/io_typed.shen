\\ Load libraries with tc off, then this client with tc on.
(define io-typed.chunk
  {io.chunk-result --> string}
  [chunk V] -> (buffer.string V)
  [eof] -> "end"
  [error E] -> (io.error-message E))
(define io-typed.transfer
  {io.transfer-result --> number}
  [ok N] -> N
  [eof N] -> N
  [error E N] -> (+ N (io.error-progress E)))
(define io-typed.value
  {(io.result string) --> string}
  [ok S] -> S
  [error E] -> (io.error-message E))
(define io-typed.file
  {string --> (io.result buffer.view)}
  Path -> (io.read-file Path 1024))
(define io-typed.make
  {--> io.endpoint}
  -> (io.endpoint "typed" read 4 (/. B [eof]) (function io.no-write) (freeze [ok])))
(define io-typed.run
  {--> boolean}
  -> (let E (io.input-buffer (buffer.from-string "abc")) R (io.reader E [[chunk-size 2]])
          A (io-typed.chunk (io.read-chunk R)) B (io-typed.chunk (io.read-chunk R))
          C (io-typed.chunk (io.read-chunk R)) _ (io.close E)
          V (buffer.new 3) Sink (io.output-buffer V)
          N (io-typed.transfer (io.write-all Sink (buffer.from-string "xyz") [])) _ (io.close Sink)
          Scope (io.with-endpoint (io-typed.make) (/. X [ok "scope"]))
       (and (and (= [A B C] ["ab" "c" "end"]) (= N 3))
            (and (= (buffer.string V) "xyz") (= (io-typed.value Scope) "scope")))))
(output "~A~%" (if (io-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))
