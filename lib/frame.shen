\\ Bounded binary messages over our own I/O reader. Load buffer.shen and io.shen first.
\\ Wire format: unsigned big-endian tag (2 bytes), payload length (4 bytes), payload.
\\ One task owns the framer and its reader. EOF and framing/transport errors are terminal.

(define frame.limit
  Limit ->
    (let N (buffer.index Limit)
      (if (<= N 4294967295) N (error "frame: payload limit exceeds the wire format"))))

(define frame.tag
  Tag ->
    (let N (buffer.index Tag)
      (if (<= N 65535) N (error "frame: tag exceeds 65535"))))

(define frame.header
  Tag Length ->
    (let H (buffer.new 6)
         _ (buffer.u8! H 0 (shen-jit.shift-right Tag 8))
         _ (buffer.u8! H 1 (shen-jit.bit-and Tag 255))
      (frame.put-uint H 2 4 Length)))

(define frame.put-uint
  V _ 0 _ -> V
  V Start Count N ->
    (do (buffer.u8! V (+ Start (- Count 1)) (shen-jit.bit-and N 255))
        (frame.put-uint V Start (- Count 1) (shen-jit.shift-right N 8))))

(define frame.uint
  _ _ 0 N -> N
  V At Count N -> (frame.uint V (+ At 1) (- Count 1) (+ (* N 256) (buffer.u8 V At))))

(define frame.encode
  Tag Payload Limit ->
    (let T (frame.tag Tag)
         Max (frame.limit Limit)
         N (buffer.length Payload)
         _ (if (<= N Max) true (error "frame: payload exceeds limit"))
         Out (buffer.new (+ 6 N))
      (do (buffer.copy! Out 0 (frame.header T N) 0 6)
          (buffer.copy! Out 6 Payload 0 N)
          Out)))

\\ Framer slots: tag, borrowed I/O reader, payload limit, terminal result, in-flight flag.
(define frame.reader
  R Limit ->
    (let Max (frame.limit Limit)
         _ (io.reader-check R)
      (io.record [frame.reader R Max [] false])))

(define frame.check
  F ->
    (let _ (if (io.tag? F frame.reader) true (error "frame: not a reader"))
         _ (if (<-address F 4) (error "frame: operation is already in flight") true)
         _ (io.reader-check (<-address F 1))
      F))

(define frame.position
  F -> (io.position (<-address (frame.check F) 1)))

(define frame.error
  Message Progress ->
    [error (io.progress (io.error frame "binary frame" Message) Progress)])

(define frame.finish
  F [frame Tag Payload] -> [frame Tag Payload]
  F Terminal -> (do (address-> F 3 Terminal) Terminal))

(define frame.next
  F ->
    (let _ (frame.check F)
         Terminal (<-address F 3)
      (if (not (empty? Terminal))
          Terminal
          (let H (buffer.new 6)
               _ (address-> F 4 true)
               Result (trap-error (frame.read-header F H (io.reader-exact (<-address F 1) H))
                        (/. X (do (address-> F 4 false)
                                  (address-> F 3 (frame.error (error-to-string X) 0))
                                  (simple-error (error-to-string X)))))
            (do (address-> F 4 false) (frame.finish F Result))))))

(define frame.read-header
  _ _ [eof 0] -> [eof]
  _ _ [eof N] -> (frame.error "incomplete header" N)
  _ _ [error Error N] -> [error (io.progress Error N)]
  F H [ok 6] ->
    (let Tag (frame.uint H 0 2 0)
         N (frame.uint H 2 4 0)
      (if (> N (<-address F 2))
          (frame.error "payload exceeds limit" 6)
          (let Payload (buffer.new N)
            (frame.read-payload Tag Payload (io.reader-exact (<-address F 1) Payload))))))

(define frame.read-payload
  Tag Payload [ok _] -> [frame Tag Payload]
  _ _ [eof N] -> (frame.error "incomplete payload" (+ 6 N))
  _ _ [error Error N] -> [error (io.progress Error (+ 6 N))])

(datatype frame-results
  Tag : number; Payload : buffer.view;
  ===================================
  [frame Tag Payload] : frame.result;

  ___________________
  [eof] : frame.result;

  Error : io.error;
  ===========================
  [error Error] : frame.result;)

(declare frame.encode [number --> [buffer.view --> [number --> buffer.view]]])
(declare frame.reader [io.reader --> [number --> frame.reader]])
(declare frame.position [frame.reader --> number])
(declare frame.next [frame.reader --> frame.result])
