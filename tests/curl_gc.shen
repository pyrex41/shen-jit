\\ Libraries and helpers are loaded in the image; every allocation now collects.
(define curl-gc.collect
  Done 0 -> (address-> Done 0 true)
  Done N -> (do (shen-jit.collect) (curl-test.pause) (curl-gc.collect Done (- N 1))))
(define curl-gc.wait
  Done N -> (if (<-address Done 0) true
                (if (= N 0) (error "GC worker did not finish")
                    (do (curl-test.pause) (curl-gc.wait Done (- N 1))))))
(let C (curl.open)
     Done (io.record [false])
     _ (thread (freeze (curl-gc.collect Done 10)))
     Body (buffer.from-string "ac#0;bc#255;")
     Result (curl.request C "POST" (cn (value curl-test.base) "/slow-echo") [] Body [[proxy ""]])
     _ (curl.close C)
     _ (curl-gc.wait Done 1000)
     _ (shen-jit.collect)
     R (hd (tl Result))
  (if (and (= (hd Result) ok) (= (curl.status R) 200)
           (buffer.equal? Body (curl.body R)) (= (curl.header-values R "x-method") ["POST"]))
      (output "curl gc ok~%") (error "curl ownership failed under GC stress")))
