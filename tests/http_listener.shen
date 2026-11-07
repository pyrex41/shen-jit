(set listener-test.passed 0)
(set listener-test.failed 0)

(define listener-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set listener-test.passed (+ 1 (value listener-test.passed)))
          (do (set listener-test.failed (+ 1 (value listener-test.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Actual)))))

(define listener-test.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(define listener-test.handler
  Q -> (http.response 200 [] (buffer.from-string "ok")))

(define listener-test.available
  -> (trap-error (do (clock.monotonic) true)
       (/. X (if (= (error-to-string X) "foreign: this static build cannot load libraries")
                 false (simple-error (error-to-string X))))))

(if (listener-test.available) true
    (do (output "0 passed, 0 failed (static build: native listener unavailable)~%") (shen-jit.exit 0)))

(define listener-test.listen
  Options -> (http.listen "127.0.0.1" 0 (function listener-test.handler) Options))

(define listener-test.client
  S -> (socket.connect "127.0.0.1" (http.port S)))

(define listener-test.wait-active
  S N D ->
    (cond ((= (hd (http.stats S)) N) true)
          ((deadline.expired? D) (error "listener did not reach expected active count"))
          (true (do (http.pause 10) (listener-test.wait-active S N D)))))

(define listener-test.wait-cell
  Cell D ->
    (cond ((<-address Cell 0) true)
          ((deadline.expired? D) (error "worker did not start"))
          (true (do (http.pause 10) (listener-test.wait-cell Cell D)))))

(define listener-test.reply
  S Target ->
    (let C (listener-test.client S)
         _ (socket.closing-on-error C
             (freeze (socket.send C (make-string "GET ~A HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;" Target))))
         E (io.socket C "listener test client")
         Result (io.with-endpoint E (/. Peer (io.read-all (io.reader Peer []) 4096)))
      (listener-test.body Result)))

(define listener-test.body
  [ok V] ->
    (let B (buffer.owner V)
         N (buffer.length V)
      (shen-jit.bytes->string B (- N 2) 2))
  [error Error] -> (error "client read: ~A" (io.error-message Error)))

(define listener-test.progress
  [error Error N] -> [(io.error-domain Error) N (io.error-progress Error)])

(define listener-test.wait-prefix
  V Result D ->
    (cond ((= (buffer.string (buffer.slice V 0 3)) "abc") true)
          ((or (not (empty? (<-address Result 0))) (deadline.expired? D))
            (error "partial read did not arrive"))
          (true (do (http.pause 10) (listener-test.wait-prefix V Result D)))))

(define listener-test.wait-result
  Result D ->
    (cond ((not (empty? (<-address Result 0))) (<-address Result 0))
          ((deadline.expired? D) (error "socket read did not finish"))
          (true (do (http.pause 10) (listener-test.wait-result Result D)))))

(map (/. Options
       (listener-test.check "invalid options rejected" true
         (freeze (listener-test.raises? (freeze (listener-test.listen Options))))))
  [[[max-connections 0]] [[max-connections 1025]] [[shutdown-grace -1]]
   [[shutdown-grace 600001]] [[unknown 1]] [[max-connections 2] [max-connections 3]]
   [[body-limit -1]] [[head-limit 3]] [[max-connections nope]]])

(let S (listener-test.listen [[shutdown-grace 0]])
     _ (http.stop S)
     _ (http.stop S)
     Result (http.wait S 2000)
  (do (listener-test.check "empty listener stops" [ok] (freeze Result))
      (listener-test.check "stopped state" stopped (freeze (http.state S)))
      (listener-test.check "empty statistics" [0 0 0 0 0 0] (freeze (http.stats S)))
      (listener-test.check "wait caches final result" [ok] (freeze (http.wait S 0)))
      (listener-test.check "listener port is closed" true
        (freeze (listener-test.raises? (freeze (listener-test.client S)))))))

(let S (listener-test.listen [[max-connections 2] [shutdown-grace 0]])
     A (listener-test.client S)
     B (listener-test.client S)
     _ (socket.send A "GET /")
     _ (socket.send B "GET /")
     _ (listener-test.wait-active S 2 (clock.deadline 2000))
     C (listener-test.client S)
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     _ (http.pause 100)
     _ (shen-jit.collect)
     _ (listener-test.check "capacity applies backpressure" false (freeze (socket.readable? C 0)))
     _ (socket.close A)
     _ (listener-test.check "queued connection admitted after completion" true
         (freeze (socket.readable? C 2000)))
     _ (socket.close C)
     _ (http.stop S)
     Result (http.wait S 2000)
     _ (socket.close B)
  (do (listener-test.check "cancelled listener joins workers" [ok] (freeze Result))
      (listener-test.check "connection cap never exceeded" 2 (freeze (hd (reverse (http.stats S)))))
      (listener-test.check "no active workers remain" 0 (freeze (hd (http.stats S))))
      (listener-test.check "three connections accepted" 3 (freeze (hd (tl (http.stats S)))))
      (listener-test.check "cancelled peer closes without a fabricated HTTP response" true
        (freeze (not (= (http.state S) listening))))))

(let Started (io.record [false])
     Handler (/. Q (do (address-> Started 0 true) (http.pause 150) (listener-test.handler Q)))
     S (http.listen "127.0.0.1" 0 Handler [[shutdown-grace 1000]])
     C (listener-test.client S)
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     _ (listener-test.wait-cell Started (clock.deadline 2000))
     _ (http.stop S)
     Result (http.wait S 2000)
     E (io.socket C "graceful client")
     Reply (io.with-endpoint E (/. Peer (io.read-all (io.reader Peer []) 4096)))
  (do (listener-test.check "in-flight handler finishes within grace" [ok] (freeze Result))
      (listener-test.check "graceful result has no cancellations" [0 1 1 0 0 1] (freeze (http.stats S)))
      (listener-test.check "graceful response remains complete" "ok"
        (freeze (listener-test.body Reply)))))

(let S (listener-test.listen [[shutdown-grace 0]])
     C (listener-test.client S)
     _ (socket.send C "POST / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Content-Length: 4c#13;c#10;c#13;c#10;a")
     _ (listener-test.wait-active S 1 (clock.deadline 2000))
     _ (http.pause 100)
     _ (http.stop S)
     _ (listener-test.check "bounded wait can report pending" [pending] (freeze (http.wait S 0)))
     Result (http.wait S 2000)
     Reply (socket.recv C 4096)
     _ (socket.close C)
  (do (listener-test.check "blocked body cancelled" [ok] (freeze Result))
      (listener-test.check "cancellation is counted" [0 1 1 1 1 1] (freeze (http.stats S)))
      (listener-test.check "cancelled body gets EOF, not an error response" 0
        (freeze (shen-jit.bytes-length Reply)))))

(let S (http.listen "127.0.0.1" 0
          (/. Q (if (= (http.target Q) "/fail") (error "worker failed") (listener-test.handler Q)))
          [[max-connections 1]])
     _ (listener-test.reply S "/fail")
     Good (listener-test.reply S "/ok")
     _ (http.stop S)
     Result (http.wait S 2000)
  (do (listener-test.check "handler failure does not stop admission" "ok" (freeze Good))
      (listener-test.check "server survives a failed worker" [ok] (freeze Result))
      (listener-test.check "request failure is counted separately" [0 2 2 1 0 1] (freeze (http.stats S)))))

(let L (socket.listen "127.0.0.1" 0)
     C (io.socket (socket.connect "127.0.0.1" (socket.port L)) "cancel client")
     E (io.socket (socket.accept L) "cancel server")
     _ (socket.close L)
     V (buffer.new 4)
     Result (io.record [[]])
     _ (thread (freeze (address-> Result 0 (io.read-exact C V []))))
     _ (io.write-all E (buffer.from-string "abc") [])
     _ (listener-test.wait-prefix V Result (clock.deadline 2000))
     _ (io.socket-cancel C)
     Read (listener-test.wait-result Result (clock.deadline 2000))
     _ (io.socket-unlimited C)
     _ (io.socket-deadline C (clock.deadline 1000))
  (do (listener-test.check "cancellation retains partial read progress" [cancelled 3 3]
        (freeze (listener-test.progress Read)))
      (listener-test.check "cancellation does not discard acknowledged bytes" "abc"
        (freeze (buffer.string (buffer.slice V 0 3))))
      (listener-test.check "new deadline does not undo cancellation" [cancelled 0 0]
        (freeze (listener-test.progress (io.write-all C (buffer.from-string "x") []))))
      (io.close C)
      (listener-test.check "cancelling an already closed socket is harmless" true
        (freeze (io.socket-cancel C)))
      (io.close E)))

(let Started (io.record [false])
     Handler (/. Q (do (address-> Started 0 true) (http.pause 250) (listener-test.handler Q)))
     S (http.listen "127.0.0.1" 0 Handler [[shutdown-grace 0]])
     C (listener-test.client S)
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     _ (listener-test.wait-cell Started (clock.deadline 2000))
     _ (http.stop S)
     Early (http.wait S 80)
     Later (http.wait S 2000)
     _ (socket.close C)
  (do (listener-test.check "application work is not killed after grace" [pending] (freeze Early))
      (listener-test.check "worker cleanup is observed when application work returns" [ok] (freeze Later))
      (listener-test.check "cancelled response does not write after handler returns" [0 1 1 1 1 1]
        (freeze (http.stats S)))))

\\ Force a supervisor failure with one worker blocked, without closing a foreign descriptor.
(set listener-test.poll-failure false)
(define socket.readable?
  S N -> (if (value listener-test.poll-failure)
             (error "forced listener poll failure")
             (socket.wait-for S (socket.readable-event) N)))

(let S (listener-test.listen [[shutdown-grace 1000]])
     C (listener-test.client S)
     _ (socket.send C "GET /")
     _ (listener-test.wait-active S 1 (clock.deadline 2000))
     _ (set listener-test.poll-failure true)
     Result (http.wait S 2000)
     _ (set listener-test.poll-failure false)
     _ (socket.close C)
  (do (listener-test.check "supervisor error is retained" serve
        (freeze (io.error-operation (hd (tl Result)))))
      (listener-test.check "supervisor error cancels and collects workers" [0 1 1 1 1 1]
        (freeze (http.stats S)))
      (listener-test.check "supervisor error closes listener" true
        (freeze (listener-test.raises? (freeze (listener-test.client S)))))))

(output "~A passed, ~A failed~%" (value listener-test.passed) (value listener-test.failed))
