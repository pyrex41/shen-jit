\\ Complete HTTP/1.1 request heads and bounded in-memory bodies over our I/O reader.
\\ Load buffer.shen, io.shen and http-head.shen first. No socket or kernel I/O dependency.

(define http.problem
  Status Message -> [error (io.native-error http-request http Status "HTTP request" Message)])

(define http.invalid
  Message -> (simple-error (cn "http syntax: " Message)))

(define http.ascii-letter?
  B -> (or (and (>= B 65) (<= B 90)) (and (>= B 97) (<= B 122))))

(define http.digit?
  B -> (and (>= B 48) (<= B 57)))

(define http.hex?
  B -> (or (http.digit? B) (and (>= B 65) (<= B 70)) (and (>= B 97) (<= B 102))))

(define http.token-byte?
  B -> (or (http.ascii-letter? B)
           (http.digit? B)
           (element? B [33 35 36 37 38 39 42 43 45 46 94 95 96 124 126])))

(define http.token-range?
  _ At At -> true
  B At End -> (and (http.token-byte? (shen-jit.u8 B At)) (http.token-range? B (+ At 1) End)))

(define http.ows?
  B -> (or (= B 32) (= B 9)))

(define http.trim-start
  B At End -> (if (and (< At End) (http.ows? (shen-jit.u8 B At)))
                  (http.trim-start B (+ At 1) End)
                  At))

(define http.trim-end
  B At End -> (if (and (< At End) (http.ows? (shen-jit.u8 B (- End 1))))
                  (http.trim-end B At (- End 1))
                  End))

(define http.text
  B Start End -> (shen-jit.bytes->string B Start (- End Start)))

(define http.lower
  Text ->
    (let B (shen-jit.string->bytes Text)
         _ (http.lower-bytes B 0 (shen-jit.bytes-length B))
      (shen-jit.bytes->string B 0 (shen-jit.bytes-length B))))

(define http.lower-bytes
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
         _ (if (and (>= Byte 65) (<= Byte 90)) (shen-jit.u8! B At (+ Byte 32)) true)
      (http.lower-bytes B (+ At 1) End)))

(define http.line-end
  B At End ->
    (if (>= At End)
        (http.invalid "unterminated line")
        (let Byte (shen-jit.u8 B At)
          (cond ((= Byte 13)
                  (if (and (< (+ At 1) End) (= (shen-jit.u8 B (+ At 1)) 10))
                      At
                      (http.invalid "CR without LF")))
                ((or (= Byte 10) (= Byte 127) (and (< Byte 32) (not (= Byte 9))))
                  (http.invalid "control byte in head"))
                (true (http.line-end B (+ At 1) End))))))

(define http.find-byte
  _ At End _ -> End where (>= At End)
  B At End Byte -> (if (= (shen-jit.u8 B At) Byte) At (http.find-byte B (+ At 1) End Byte)))

(define http.uri-byte?
  B -> (or (http.ascii-letter? B)
           (http.digit? B)
           (element? B [33 36 38 39 40 41 42 43 44 45 46 47 58 59 61 63 64 95 126])))

(define http.target-range?
  _ At At -> true
  B At End ->
    (if (= (shen-jit.u8 B At) 37)
        (and (< (+ At 2) End)
             (http.hex? (shen-jit.u8 B (+ At 1)))
             (http.hex? (shen-jit.u8 B (+ At 2)))
             (http.target-range? B (+ At 3) End))
        (and (http.uri-byte? (shen-jit.u8 B At)) (http.target-range? B (+ At 1) End))))

(define http.request-line
  B At End ->
    (let _ (if (<= (- End At) 8192) true (http.invalid "request line too long"))
         First (http.find-byte B At End 32)
         Second (http.find-byte B (+ First 1) End 32)
         _ (if (and (> First At) (< First End) (> Second (+ First 1)) (< Second End))
               true (http.invalid "invalid request line"))
         _ (if (http.token-range? B At First) true (http.invalid "invalid method"))
         Method (http.text B At First)
         Target (http.text B (+ First 1) Second)
         Version (http.text B (+ Second 1) End)
         _ (if (= Method "CONNECT")
               true
               (if (or (and (= Method "OPTIONS") (= Target "*"))
                       (and (= (shen-jit.u8 B (+ First 1)) 47)
                            (http.target-range? B (+ First 1) Second)))
                   true (http.invalid "unsupported or invalid request target")))
         V (shen-jit.string->bytes Version)
         _ (if (and (= (shen-jit.bytes-length V) 8)
                    (= (http.text V 0 5) "HTTP/")
                    (http.digit? (shen-jit.u8 V 5))
                    (= (shen-jit.u8 V 6) 46)
                    (http.digit? (shen-jit.u8 V 7)))
               true (http.invalid "invalid HTTP version"))
      [Method Target Version]))

(define http.field
  B At End ->
    (let _ (if (<= (- End At) 8192) true (http.invalid "field line too long"))
         Colon (http.find-byte B At End 58)
         _ (if (and (> Colon At) (< Colon End) (http.token-range? B At Colon))
               true (http.invalid "invalid field name or whitespace before colon"))
         Start (http.trim-start B (+ Colon 1) End)
         Finish (http.trim-end B Start End)
      [(http.lower (http.text B At Colon)) (http.text B Start Finish)]))

(define http.fields
  B At End Count Acc ->
    (let Line (http.line-end B At End)
      (if (= At Line)
          (if (= (+ Line 2) End) (reverse Acc) (http.invalid "trailing bytes after head"))
          (if (>= Count 100)
              (http.invalid "too many fields")
              (http.fields B (+ Line 2) End (+ Count 1) [(http.field B At Line) | Acc])))))

(define http.field-values
  [] _ -> []
  [[Name Value] | Rest] Name -> [Value | (http.field-values Rest Name)]
  [_ | Rest] Name -> (http.field-values Rest Name))

\\ A conservative authority subset: DNS-style ASCII labels or hex IPv6, with an optional port.
(define http.host-labels?
  _ At At Count Last -> (and (> Count 0) (not (= Last 45)))
  B At End Count Last ->
    (let Byte (shen-jit.u8 B At)
      (if (= Byte 46)
          (and (> Count 0)
               (not (= Last 45))
               (or (= (+ At 1) End) (http.host-labels? B (+ At 1) End 0 0)))
          (and (< Count 63)
               (or (http.ascii-letter? Byte) (http.digit? Byte) (= Byte 45))
               (or (> Count 0) (not (= Byte 45)))
               (http.host-labels? B (+ At 1) End (+ Count 1) Byte)))))

(define http.ipv6?
  B Start End ->
    (and (> (- End Start) 1)
         (if (= (shen-jit.u8 B Start) 58)
             (and (< (+ Start 1) End)
                  (= (shen-jit.u8 B (+ Start 1)) 58)
                  (http.ipv6-groups? B (+ Start 2) End 0 0 true))
             (http.ipv6-groups? B Start End 0 0 false))))

(define http.ipv6-groups?
  _ At At Groups Width Compressed ->
    (let Total (+ Groups (if (> Width 0) 1 0))
      (if Compressed (< Total 8) (and (> Width 0) (= Total 8))))
  B At End Groups Width Compressed ->
    (let Byte (shen-jit.u8 B At)
      (cond ((http.hex? Byte)
              (and (< Width 4) (http.ipv6-groups? B (+ At 1) End Groups (+ Width 1) Compressed)))
            ((and (= Byte 58) (> Width 0))
              (if (and (< (+ At 1) End) (= (shen-jit.u8 B (+ At 1)) 58))
                  (and (not Compressed) (http.ipv6-groups? B (+ At 2) End (+ Groups 1) 0 true))
                  (and (< (+ At 1) End)
                       (http.ipv6-groups? B (+ At 1) End (+ Groups 1) 0 Compressed))))
            (true false))))

(define http.digits?
  _ At At -> true
  B At End -> (and (http.digit? (shen-jit.u8 B At)) (http.digits? B (+ At 1) End)))

\\ Split at 2^60 on the rare large-limit path: the kernel's mod doubles its divisor,
\\ which would overflow near the largest fixnum. Every intermediate here stays in range.
(define http.decimal-bound
  N ->
    (if (<= N 1152921504606846975)
        (let R (shen.mod N 10) (@p (/ (- N R) 10) R))
        (let Low (- N 1152921504606846976)
             R (shen.mod Low 10)
             Sum (+ R 6)
             Carry (if (>= Sum 10) 1 0)
          (@p (+ 115292150460684697 (/ (- Low R) 10) Carry)
              (if (= Carry 1) (- Sum 10) Sum)))))

(define http.decimal
  B Start End Limit ->
    (let Bound (http.decimal-bound Limit)
      (http.decimal-loop B Start End 0 (fst Bound) (snd Bound))))

(define http.decimal-loop
  _ At At N _ _ -> N
  B At End N Tens Remainder ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (or (> N Tens) (and (= N Tens) (> Digit Remainder)))
          too-large
          (http.decimal-loop B (+ At 1) End (+ (* N 10) Digit) Tens Remainder))))

(define http.host-port?
  _ At At -> true
  B At End ->
    (and (= (shen-jit.u8 B At) 58)
         (< (+ At 1) End)
         (http.digits? B (+ At 1) End)
         (not (= (http.decimal B (+ At 1) End 65535) too-large))))

(define http.host?
  Text ->
    (let B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (and (> N 0)
           (if (= (shen-jit.u8 B 0) 91)
               (let Close (http.find-byte B 1 N 93)
                 (and (< Close N)
                      (http.ipv6? B 1 Close)
                      (http.host-port? B (+ Close 1) N)))
               (let Colon (http.find-byte B 0 N 58)
                 (and (<= Colon 253)
                      (http.host-labels? B 0 Colon 0 0)
                      (http.host-port? B Colon N)))))))

(define http.connection-tokens
  Values -> (http.connection-values Values []))

(define http.connection-values
  [] Acc -> Acc
  [Value | Rest] Acc ->
    (let B (shen-jit.string->bytes Value)
         Tokens (http.connection-parts B 0 (shen-jit.bytes-length B) Acc)
      (http.connection-values Rest Tokens)))

(define http.connection-parts
  B At End Acc ->
    (let Comma (http.find-byte B At End 44)
         Start (http.trim-start B At Comma)
         Finish (http.trim-end B Start Comma)
         _ (if (and (< Start Finish) (http.token-range? B Start Finish))
               true (http.invalid "invalid Connection token"))
         Next [(http.lower (http.text B Start Finish)) | Acc]
      (if (= Comma End) Next (http.connection-parts B (+ Comma 1) End Next))))

(define http.connection-framing?
  [] -> false
  [Name | Rest] ->
    (or (element? Name ["host" "content-length" "transfer-encoding" "expect" "trailer"])
        (http.connection-framing? Rest)))

(define http.length
  [] _ -> 0
  [Value] Limit ->
    (let B (shen-jit.string->bytes Value)
         N (shen-jit.bytes-length B)
         _ (if (and (> N 0) (http.digits? B 0 N)) true (http.invalid "invalid Content-Length"))
      (http.decimal B 0 N Limit))
  _ _ -> (http.invalid "duplicate Content-Length"))

(define http.validate-request
  [Method Target Version] Fields Limit ->
    (let Hosts (http.field-values Fields "host")
         _ (if (and (= (length Hosts) 1) (http.host? (hd Hosts)))
               true (http.invalid "one valid Host is required"))
         Lengths (http.field-values Fields "content-length")
         Coding (http.field-values Fields "transfer-encoding")
         Connection (http.connection-tokens (http.field-values Fields "connection"))
         _ (if (http.connection-framing? Connection)
               (http.invalid "Connection nominates a framing field") true)
      (cond ((not (= Version "HTTP/1.1")) (http.problem 505 "only HTTP/1.1 is supported"))
            ((and (not (empty? Coding)) (not (empty? Lengths)))
              (http.problem 400 "Transfer-Encoding with Content-Length"))
            ((not (empty? Coding)) (http.problem 501 "transfer coding is unsupported"))
            ((not (empty? (http.field-values Fields "expect")))
              (http.problem 417 "expectations are unsupported"))
            ((or (= Method "CONNECT")
                 (element? "upgrade" Connection)
                 (not (empty? (http.field-values Fields "upgrade"))))
              (http.problem 501 "tunnels and upgrades are unsupported"))
            ((not (empty? (http.field-values Fields "trailer")))
              (http.problem 400 "trailers are unsupported"))
            (true
              (let N (http.length Lengths Limit)
                (cond ((= N too-large) (http.problem 413 "request body exceeds limit"))
                      ((and (= Method "TRACE") (> N 0)) (http.problem 400 "TRACE cannot have a body"))
                      (true [ok (io.record [http.request Method Target Version Fields N unread])])))))))

(define http.syntax-error
  X ->
    (let Text (error-to-string X)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (>= N 13) (= (http.text B 0 13) "http syntax: "))
          (let Message (http.text B 13 N)
               Status (cond ((= Message "request line too long") 414)
                            ((element? Message ["field line too long" "too many fields"]) 431)
                            (true 400))
            (http.problem Status Message))
          (simple-error Text))))

(define http.parse-request
  V BodyLimit ->
    (let Limit (buffer.index BodyLimit)
         B (buffer.owner V)
         At (buffer.offset V)
         End (buffer.end V)
      (if (> (- End At) 1048576)
          (http.problem 431 "request head exceeds limit")
          (trap-error
            (let Line (http.line-end B At End)
                 RequestLine (http.request-line B At Line)
                 Fields (http.fields B (+ Line 2) End 0 [])
              (http.validate-request RequestLine Fields Limit))
            (function http.syntax-error)))))

\\ Requests retain immutable metadata; a body read returns a new request with owned body bytes.
(define http.request-check
  Request -> (if (io.tag? Request http.request) Request (error "http: not a request")))

(define http.method
  Request -> (<-address (http.request-check Request) 1))

(define http.target
  Request -> (<-address (http.request-check Request) 2))

(define http.version
  Request -> (<-address (http.request-check Request) 3))

(define http.headers
  Request -> (<-address (http.request-check Request) 4))

(define http.content-length
  Request -> (<-address (http.request-check Request) 5))

(define http.header-values
  Request Name -> (http.field-values (http.headers Request) (http.lower Name)))

(define http.body
  Request ->
    (let Body (<-address (http.request-check Request) 6)
      (if (= Body unread) (error "http: request body has not been read") (buffer.check Body))))

(define http.complete-request
  Request Body ->
    (io.record [http.request (http.method Request) (http.target Request) (http.version Request)
                (http.headers Request) (http.content-length Request) Body]))

(define http.body-reader
  R Request ->
    (let _ (io.reader-check R)
         N (http.content-length Request)
         _ (if (= (<-address Request 6) unread) true (error "http: request already has a body"))
      (io.record [http.body-reader R Request N [] false])))

(define http.body-check
  B ->
    (let _ (if (io.tag? B http.body-reader) true (error "http: not a body reader"))
         _ (if (<-address B 5) (error "http: body read is already in flight") true)
         _ (io.reader-check (<-address B 1))
      B))

(define http.body-budget
  _ [] _ -> [ok]
  _ D Progress ->
    (if (deadline.expired? D)
        [error (io.progress (io.native-error read timeout 0 "HTTP body" "deadline expired") Progress)]
        [ok]))

(define http.read-body
  B -> (http.body-run B []))

(define http.read-body-until
  B D -> (do (deadline.check D) (http.body-run B D)))

(define http.body-run
  B D ->
    (let _ (http.body-check B)
         Saved (<-address B 4)
      (if (not (empty? Saved))
          Saved
          (do (address-> B 5 true)
              (let Result (trap-error (http.body-ready B D (http.body-budget B D 0))
                             (/. X (do (address-> B 5 false)
                                       (address-> B 4 (http.problem 400 "body read aborted"))
                                       (simple-error (error-to-string X)))))
                (do (address-> B 5 false) (address-> B 4 Result) Result))))))

(define http.body-ready
  _ _ [error Error] -> [error Error]
  B D [ok] ->
    (let V (buffer.new (<-address B 3))
      (http.body-read B D V (io.reader-exact (<-address B 1) V))))

(define http.body-read
  _ _ _ [eof N] ->
    [error (io.progress (io.native-error http-body http 400 "HTTP body" "incomplete request body") N)]
  _ _ _ [error Error N] -> [error (io.progress Error N)]
  B D V [ok N] -> (http.body-complete B V (http.body-budget B D N)))

(define http.body-complete
  _ _ [error Error] -> [error Error]
  B V [ok] -> [ok (http.complete-request (<-address B 2) V)])

(declare http.parse-request [buffer.view --> [number --> [io.result http.request]]])
(declare http.method [http.request --> string])
(declare http.target [http.request --> string])
(declare http.version [http.request --> string])
(declare http.headers [http.request --> [list [list string]]])
(declare http.content-length [http.request --> number])
(declare http.header-values [http.request --> [string --> [list string]]])
(declare http.body [http.request --> buffer.view])
(declare http.body-reader [io.reader --> [http.request --> http.body-reader]])
(declare http.read-body [http.body-reader --> [io.result http.request]])
(declare http.read-body-until [http.body-reader --> [deadline --> [io.result http.request]]])
