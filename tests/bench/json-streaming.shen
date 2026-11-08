\\ A JSON value arriving in chunks, decoded by restarting or after framing it. Load buffer.shen,
\\ grammar.shen and json.shen first; SHEN_JIT_STATS=1 adds the collections at exit:
\\
\\   shen-jit eval -l lib/buffer.shen -l lib/grammar.shen -l lib/json.shen \\
\\     -l tests/bench/json-streaming.shen -e '(stream.run restart string 65536 1)'
\\
\\ Strategy is restart or frame, Kind string (a string of N letters) or api (N objects), and the
\\ last argument the size of each chunk. It prints attempts, bytes decoded or scanned, and the time.

(define stream.text
  string N -> (cn "[c#34;" (cn (stream.letters N) "c#34;]"))
  api N -> (cn "[" (cn (stream.objects N "") "]")))

(define stream.letters
  N -> (let B (shen-jit.bytes N) _ (stream.fill B 0 N) (shen-jit.bytes->string B 0 N)))

(define stream.fill
  _ I I -> true
  B I N -> (do (shen-jit.u8! B I 97) (stream.fill B (+ I 1) N)))

(define stream.objects
  0 Acc -> Acc
  N Acc -> (stream.objects (- N 1)
             (cn "{c#34;idc#34;: 1234, c#34;namec#34;: c#34;counter-visitsc#34;, c#34;valuec#34;: 98765, c#34;activec#34;: true}"
                 (if (= Acc "") "" (cn ", " Acc)))))

\\ Restart: decode all that has arrived; an error at the end of it means the value is not complete yet.
(define stream.restart
  V Have Chunk Attempts Decoded ->
    (let Now (stream.min (+ Have Chunk) (buffer.length V))
         Prefix (buffer.slice V 0 Now)
         Result (trap-error [ok (json.decode Prefix [])] (/. E [error (error-to-string E)]))
      (if (and (= (hd Result) error) (stream.at-end? (hd (tl Result)) Now) (< Now (buffer.length V)))
          (stream.restart V Now Chunk (+ Attempts 1) (+ Decoded Now))
          [(+ Attempts 1) (+ Decoded Now) (hd Result)])))

(define stream.at-end?
  Message Now -> (= Message (make-string "json: byte ~A: unexpected end" Now)))

\\ Frame: scan only the bytes that arrived for the newline that ends a value, then decode once.
(define stream.frame
  V Have Chunk Scanned ->
    (let Now (stream.min (+ Have Chunk) (buffer.length V))
         Line (stream.newline (buffer.owner V) (+ (buffer.offset V) Have) (+ (buffer.offset V) Now))
      (if (< Line 0)
          (stream.frame V Now Chunk (+ Scanned (- Now Have)))
          (let Value (json.decode (buffer.slice V 0 (- Line (buffer.offset V))) [])
            [1 (+ Scanned (- (+ Line 1) (+ (buffer.offset V) Have)) (- Line (buffer.offset V))) ok]))))

(define stream.newline
  _ At At -> -1
  B At End -> (if (= (shen-jit.u8 B At) 10) At (stream.newline B (+ At 1) End)))

(define stream.min
  A B -> (if (< A B) A B))

(define stream.run
  Strategy Kind N Chunk ->
    (let V (buffer.from-string (cn (stream.text Kind N) "c#10;"))
         Value (buffer.slice V 0 (- (buffer.length V) 1))
         T0 (get-time unix)
         Result (if (= Strategy restart) (stream.restart Value 0 Chunk 0 0) (stream.frame V 0 Chunk 0))
         T1 (get-time unix)
      (output "~A ~A ~A bytes, chunks of ~A: ~A attempts, ~A bytes decoded, ~A, ~A ms~%"
        Strategy Kind (buffer.length Value) Chunk (hd Result) (hd (tl Result)) (hd (tl (tl Result)))
        (/ (stream.floor (* 10000 (- T1 T0))) 10))))

(define stream.floor X -> (- X (shen.mod X 1)))
