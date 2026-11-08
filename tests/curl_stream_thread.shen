\\ Start the runtime's first worker inside a native write callback, then resume the transfer.
(define curl-stream-thread.write
  C Done Count Bytes ->
    (let _ (if (= (<-address Count 0) 0)
               (let _ (thread (freeze (do (shen-jit.collect) (address-> Done 0 [ok]))))
                    _ (curl-test.join Done 1000)
                    Close (curl.close C)
                    Request (curl.request C "GET" (value curl-test.base) [] (buffer.new 0) [[proxy ""]])
                 (if (and (= (hd Close) error) (= (hd Request) error))
                     true (error "reentrant use bypassed the busy guard"))) true)
         N (shen-jit.bytes-length Bytes)
         _ (address-> Count 0 (+ (<-address Count 0) N))
      [written N]))

(let C (curl.open)
     Done (io.record [[]])
     Count (io.record [0])
     Sink (io.endpoint "first-thread sink" write 128 (function io.no-read)
            (/. Bytes (curl-stream-thread.write C Done Count Bytes)) (freeze [ok]))
     Result (curl.request-to C "GET" (cn (value curl-test.base) "/binary") [] (buffer.new 0) Sink [[proxy ""]])
     _ (io.close Sink)
     Close (curl.close C)
  (if (and (= (hd Result) ok) (= (<-address Count 0) 1024) (= Close [ok]))
      (output "3 passed, 0 failed~%") (error "first-thread callback failed")))
