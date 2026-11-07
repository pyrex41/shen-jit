\\ One bounded HTTP head through CRLFCRLF, over our own reader. Load buffer.shen and io.shen.
\\ This frames bytes; request-line/field semantics and body framing belong to a complete parser.
\\ deadline.shen is needed only by http.read-head-until.

(define http.head-reader
  R Limit ->
    (let N (buffer.index Limit)
         _ (if (and (>= N 4) (<= N 1048576)) true
               (error "http: head limit must be 4..1048576 bytes"))
         _ (io.reader-check R)
      (io.record [http.head-reader R N (buffer.new N) 0 0 [] false])))

\\ Slots: tag, borrowed reader, byte limit, accumulator, used count, CRLF state, result, busy.
(define http.head-check
  F ->
    (let _ (if (io.tag? F http.head-reader) true (error "http: not a head reader"))
         _ (if (<-address F 7) (error "http: head read is already in flight") true)
         _ (io.reader-check (<-address F 1))
      F))

(define http.head-error
  F Message -> [error (io.progress (io.error http-head "HTTP head" Message) (<-address F 4))])

(define http.head-budget
  _ [] -> [ok]
  F D ->
    (if (deadline.expired? D)
        [error (io.progress (io.native-error read timeout 0 "HTTP head" "deadline expired")
                           (<-address F 4))]
        [ok]))

(define http.read-head
  F -> (http.head-run F []))

(define http.read-head-until
  F D -> (do (deadline.check D) (http.head-run F D)))

(define http.head-run
  F D ->
    (let _ (http.head-check F)
         Saved (<-address F 6)
      (if (not (empty? Saved))
          Saved
          (do (address-> F 7 true)
              (let Result (trap-error (http.head-loop F D)
                             (/. X (do (address-> F 7 false)
                                       (http.head-finish F (http.head-error F (error-to-string X)))
                                       (simple-error (error-to-string X)))))
                (do (address-> F 7 false) (http.head-finish F Result)))))))

(define http.head-finish
  F Result ->
    (do (address-> F 6 Result)
        (address-> F 3 [])
        Result))

(define http.head-loop
  F D -> (http.head-ready F D (http.head-budget F D)))

(define http.head-ready
  _ _ [error Error] -> [error Error]
  F D [ok] ->
    (if (= (<-address F 4) (<-address F 2))
        (http.head-error F "head exceeds byte limit")
        (http.head-input F D (io.peek-some (<-address F 1)))))

(define http.head-input
  F _ [eof] ->
    (if (= (<-address F 4) 0) [eof] (http.head-error F "incomplete head"))
  F _ [error Error] -> [error (io.progress Error (<-address F 4))]
  F D [ok V] ->
    (let Result (http.head-scan (buffer.owner V) (buffer.offset V) (buffer.end V)
                                (<-address F 5) (- (<-address F 2) (<-address F 4)) 0)
      (http.head-scanned F D V Result)))

\\ Scan each new span once. A partial CR or CRLFCR is retained as state, never rescanned.
(define http.head-scan
  _ At At State _ Count -> [more Count State]
  _ _ _ _ 0 Count -> [limit Count]
  B At End State Left Count ->
    (let Byte (shen-jit.u8 B At)
         N (+ Count 1)
      (cond ((and (element? State [1 3]) (not (= Byte 10))) [invalid N "CR without LF"])
            ((and (= Byte 10) (not (element? State [1 3]))) [invalid N "bare LF"])
            ((or (= Byte 127) (and (< Byte 32) (not (element? Byte [9 10 13]))))
              [invalid N "control byte in head"])
            ((and (= State 3) (= Byte 10)) [done N])
            (true
              (let Next (cond ((= Byte 13) (if (= State 2) 3 1))
                               ((= Byte 10) 2)
                               (true 0))
                (http.head-scan B (+ At 1) End Next (- Left 1) N))))))

(define http.head-copy
  F V Count ->
    (let Used (<-address F 4)
      (do (buffer.copy! (<-address F 3) Used V 0 Count)
          (io.consume (<-address F 1) Count)
          (address-> F 4 (+ Used Count))
          F)))

(define http.head-scanned
  F D V [more Count State] ->
    (do (http.head-copy F V Count)
        (address-> F 5 State)
        (http.head-loop F D))
  F _ V [limit Count] ->
    (do (http.head-copy F V Count) (http.head-error F "head exceeds byte limit"))
  F _ V [invalid Count Message] ->
    (do (http.head-copy F V Count) (http.head-error F Message))
  F D V [done Count] ->
    (do (http.head-copy F V Count) (http.head-complete F (http.head-budget F D))))

(define http.head-complete
  _ [error Error] -> [error Error]
  F [ok] -> [head (buffer.wrap (buffer.bytes (buffer.slice (<-address F 3) 0 (<-address F 4))))])

(datatype http-head-results
  V : buffer.view;
  ===========================
  [head V] : http.head-result;

  _______________________
  [eof] : http.head-result;

  Error : io.error;
  ================================
  [error Error] : http.head-result;)

(declare http.head-reader [io.reader --> [number --> http.head-reader]])
(declare http.read-head [http.head-reader --> http.head-result])
(declare http.read-head-until [http.head-reader --> [deadline --> http.head-result]])
