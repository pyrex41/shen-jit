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
