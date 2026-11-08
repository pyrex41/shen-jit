(shen-jit.library curl-test.wait ["libc.so.6" "libSystem.dylib" "kernel32.dll"])
(define-foreign curl-test.poll curl-test.wait "poll" (pointer int64 int32) --> int32 blocking)
(define-foreign curl-test.sleep curl-test.wait "Sleep" (int32) --> void blocking)
(define curl-test.pause
  -> (if (= (value *os*) "Windows") (curl-test.sleep 10) (curl-test.poll [] 0 10)))
(define curl-test.join
  Cell N ->
    (cond ((not (empty? (<-address Cell 0))) (<-address Cell 0))
          ((= N 0) (error "curl worker did not complete"))
          (true (do (curl-test.pause) (curl-test.join Cell (- N 1))))))

(let C (curl.open)
     Result (io.record [[]])
     _ (thread (freeze (address-> Result 0 (curl.get (cn (value curl-test.base) "/await-hold") [[proxy ""]]))))
     Original (io.record [[]])
     _ (thread (freeze (address-> Original 0
                        (curl.request C "GET" (cn (value curl-test.base) "/hold") [] (buffer.new 0) [[proxy ""]]))))
     Ready (curl-test.join Result 1000)
     Close (curl.close C)
     Duplicate (curl.request C "GET" (value curl-test.base) [] (buffer.new 0) [[proxy ""]])
     Released (curl.get (cn (value curl-test.base) "/release-hold") [[proxy ""]])
     Final (curl-test.join Original 1000)
     Closed (curl.close C)
  (if (and (= (hd Ready) ok) (= (hd Close) error) (= (hd Duplicate) error)
           (= (hd Released) ok) (= (hd Final) ok) (= Closed [ok]))
      (output "6 passed, 0 failed~%") (error "curl in-flight ownership failed")))
