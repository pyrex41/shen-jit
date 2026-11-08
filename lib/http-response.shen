\\ Bounded HTTP/1.1 final responses. Load http-request.shen after the buffer/I/O libraries first.
\\ Application fields are ordered pairs; framing fields are supplied by this encoder.

(define http.response
  Status Fields Body ->
    (let Code (buffer.index Status)
         _ (if (and (>= Code 200) (<= Code 599)) true
               (error "http: final response status must be 200..599"))
         _ (buffer.check Body)
      (io.record [http.response Code Fields Body false])))

(define http.response-check
  Response ->
    (if (or (io.tag? Response http.response) (io.tag? Response http.stream-description))
        Response (error "http: not a response")))

(define http.response-source
  Response -> (if (io.tag? Response http.stream-description) (<-address Response 4) []))

(define http.response-closes?
  Response ->
    (let _ (http.response-check Response)
      (<-address Response (if (io.tag? Response http.stream-description) 5 4))))

(define http.close-after
  Response ->
    (http.response-copy-fields Response (<-address (http.response-check Response) 2) true))

(define http.response-copy-fields
  Response Fields Close ->
    (if (io.tag? Response http.stream-description)
        (io.record [http.stream-description (<-address Response 1) Fields
                    (<-address Response 3) (<-address Response 4) Close])
        (io.record [http.response (<-address Response 1) Fields (<-address Response 3) Close])))

(define http.reason
  200 -> "OK"
  201 -> "Created"
  202 -> "Accepted"
  204 -> "No Content"
  205 -> "Reset Content"
  206 -> "Partial Content"
  304 -> "Not Modified"
  400 -> "Bad Request"
  403 -> "Forbidden"
  404 -> "Not Found"
  405 -> "Method Not Allowed"
  408 -> "Request Timeout"
  409 -> "Conflict"
  413 -> "Content Too Large"
  414 -> "URI Too Long"
  415 -> "Unsupported Media Type"
  417 -> "Expectation Failed"
  422 -> "Unprocessable Content"
  431 -> "Request Header Fields Too Large"
  500 -> "Internal Server Error"
  501 -> "Not Implemented"
  503 -> "Service Unavailable"
  505 -> "HTTP Version Not Supported"
  _ -> "")

(define http.response-value?
  _ At At -> true
  B At End ->
    (let Byte (shen-jit.u8 B At)
      (and (not (= Byte 127))
           (or (>= Byte 32) (= Byte 9))
           (http.response-value? B (+ At 1) End))))

(define http.response-field
  Name Value Budget ->
    (let _ (if (and (string? Name) (string? Value)) true (error "http: response fields must be strings"))
         B (shen-jit.string->bytes Name)
         V (shen-jit.string->bytes Value)
         N (shen-jit.bytes-length B)
         M (shen-jit.bytes-length V)
         _ (if (and (> N 0) (http.token-range? B 0 N)) true (error "http: invalid response field name"))
         Lower (http.lower Name)
         _ (if (element? Lower ["content-length" "transfer-encoding" "connection" "trailer"
                               "upgrade" "keep-alive" "proxy-connection" "te"])
               (error "http: response framing field is managed by the encoder") true)
         _ (if (http.response-value? V 0 M) true (error "http: invalid response field value"))
         _ (if (and (<= (+ N M 2) 8192) (<= (+ N M 4) Budget)) true
               (error "http: response head exceeds limit"))
      (shen-jit.string->bytes (cn Name (cn ": " (cn Value "c#13;c#10;"))))))

(define http.response-fields
  [] _ _ Acc Total -> (@p (reverse Acc) Total)
  [[Name Value] | Rest] Count Budget Acc Total ->
    (let _ (if (< Count 100) true (error "http: too many response fields"))
         Line (http.response-field Name Value Budget)
         N (shen-jit.bytes-length Line)
      (http.response-fields Rest (+ Count 1) (- Budget N) [Line | Acc] (+ Total N)))
  _ _ _ _ _ -> (error "http: response fields must be [Name Value] pairs"))

(define http.response-copy
  Out At [] -> At
  Out At [Chunk | Rest] ->
    (let N (shen-jit.bytes-length Chunk)
         _ (shen-jit.copy-bytes (buffer.owner Out) At Chunk 0 N)
      (http.response-copy Out (+ At N) Rest)))

(define http.encode-head
  Method Response Framing Close HeadLimit ->
    (let _ (http.response-check Response)
         MaxHead (buffer.index HeadLimit)
         _ (if (and (>= MaxHead 4) (<= MaxHead 1048576)) true
               (error "http: response head limit must be 4..1048576"))
         Status (<-address Response 1)
         _ (if (and (element? Status [204 205 304]) (not (= Framing [length 0])))
               (error "http: bodyless status requires zero length") true)
         Connection (if Close "Connection: closec#13;c#10;c#13;c#10;" "c#13;c#10;")
         TailText (if (element? Status [204 304])
                      Connection
                      (cn (http.framing-field Framing) Connection))
         Tail (shen-jit.string->bytes TailText)
         Start (shen-jit.string->bytes (make-string "HTTP/1.1 ~A ~Ac#13;c#10;" Status (http.reason Status)))
         Base (+ (shen-jit.bytes-length Start) (shen-jit.bytes-length Tail))
         _ (if (<= Base MaxHead) true (error "http: response head exceeds limit"))
         Fields (http.response-fields (<-address Response 2) 0 (- MaxHead Base) [Start] Base)
         Out (buffer.new (snd Fields))
         _ (http.response-copy Out 0 (append (fst Fields) [Tail]))
      Out))

(define http.framing-field
  [length N] -> (make-string "Content-Length: ~Ac#13;c#10;" N)
  [chunked] -> "Transfer-Encoding: chunkedc#13;c#10;")

(define http.suppressed?
  Method Status -> (or (= Method "HEAD") (element? Status [204 205 304])))

(define http.encode-mode
  Method Response HeadLimit BodyLimit Close ->
    (let _ (http.response-check Response)
         _ (if (io.tag? Response http.response) true (error "http: streaming responses require send-response"))
         Body (<-address Response 3)
         N (buffer.length Body)
         Maximum (buffer.index BodyLimit)
         _ (if (<= N Maximum) true (error "http: response body exceeds limit"))
         Head (http.encode-head Method Response [length N] Close HeadLimit)
         Send (if (http.suppressed? Method (<-address Response 1)) 0 N)
         Out (buffer.new (+ (buffer.length Head) Send))
         _ (buffer.copy! Out 0 Head 0 (buffer.length Head))
      (do (buffer.copy! Out (buffer.length Head) Body 0 Send) Out)))

(define http.encode-for
  Method Response HeadLimit BodyLimit -> (http.encode-mode Method Response HeadLimit BodyLimit true))

(define http.encode-response
  Request Response HeadLimit BodyLimit ->
    (http.encode-for (http.method Request) Response HeadLimit BodyLimit))

\\ Sources transfer to the sender, which closes them on every exit. Each callback
\\ receives a byte bound and the one absolute write deadline. No prefetch queue.
\\ Slots: tag, next, close, lifecycle, in-flight, cached close result, image guard.
(define http.source
  Next Close ->
    (let Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 http.source)
      (io.record [http.source-state Next Close fresh false [] Guard])))

(define http.source-check
  S ->
    (let _ (if (io.tag? S http.source-state) true (error "http: not a response source"))
         _ (if (= (shen-jit.pointer-address (<-address S 6)) 0)
               (error "http: saved response sources must be recreated") true)
         _ (if (<-address S 4) (error "http: response source is in flight") true)
      S))

(define http.source-claim
  S ->
    (do (http.source-check S)
        (if (= (<-address S 3) fresh) (address-> S 3 active)
            (error "http: response source has already been used"))))

(define http.source-close
  S ->
    (let _ (http.source-check S)
      (if (= (<-address S 3) closed)
          (<-address S 5)
          (let Close (<-address S 2)
               _ (address-> S 3 closed)
               _ (address-> S 1 [])
               _ (address-> S 2 [])
               _ (address-> S 4 true)
               Result (trap-error (http.source-closed (thaw Close))
                        (/. X [error (http.output-error (error-to-string X))]))
            (do (address-> S 4 false) (address-> S 5 Result) Result)))))

(define http.source-closed
  [ok] -> [ok]
  [error Error] -> (if (io.error? Error) [error Error] (error "http: invalid source close error"))
  _ -> (error "http: source close must return [ok] or [error Error]"))

(define http.output-error
  Message -> (io.native-error http-response application 500 "HTTP response" Message))

(define http.output-budget
  D -> (if (deadline.expired? D)
           [error (io.native-error http-response timeout 0 "HTTP response" "write deadline expired")]
           [ok]))

(define http.source-next
  S Maximum D ->
    (let _ (http.source-check S)
         _ (if (= (<-address S 3) active) true (error "http: response source is not active"))
      (http.source-ready S Maximum D (http.output-budget D))))

(define http.source-ready
  _ _ _ [error Error] -> [error Error]
  S Maximum D [ok] ->
    (let Next (<-address S 1)
         _ (address-> S 4 true)
         Result (trap-error (http.source-chunk (Next Maximum D) Maximum)
                  (/. X [error (http.output-error (error-to-string X))]))
         _ (address-> S 4 false)
      (http.source-budget Result (http.output-budget D))))

(define http.source-budget
  Result [ok] -> Result
  _ [error Error] -> [error Error])

(define http.source-chunk
  [eof] _ -> [eof]
  [chunk V] Maximum ->
    (let N (buffer.length V)
      (if (and (> N 0) (<= N Maximum)) [chunk V]
          (error "http: source chunk must contain 1..Maximum bytes")))
  [error Error] _ ->
    (if (io.error? Error)
        [error (io.secondary (http.output-error "response producer failed") Error)]
        (error "http: invalid response producer error"))
  _ _ -> (error "http: source must return [chunk View], [eof] or [error Error]"))

(define http.framing-check
  [length N] -> (do (buffer.index N) [length N])
  [chunked] -> [chunked]
  _ -> (error "http: response framing must be [length N] or [chunked]"))

(define http.stream-response
  Status Fields Framing Source ->
    (let Code (buffer.index Status)
         _ (if (and (>= Code 200) (<= Code 599)) true
               (error "http: final response status must be 200..599"))
         _ (http.source-check Source)
         _ (http.framing-check Framing)
      (io.record [http.stream-description Code Fields Framing Source false])))

(define http.output-options
  Options -> (http.output-config (io.record [16384 1048576 16384 4096]) Options []))

(define http.output-index
  response-head-limit -> 0
  response-body-limit -> 1
  response-chunk-size -> 2
  response-chunk-count-limit -> 3
  _ -> (error "http: unknown response option"))

(define http.output-config
  Config [] _ -> Config
  Config [[Name Value] | Rest] Seen ->
    (let I (http.output-index Name)
         N (buffer.index Value)
         _ (if (element? Name Seen) (error "http: duplicate response option") true)
         _ (if (or (and (= I 0) (>= N 4) (<= N 1048576))
                   (= I 1)
                   (and (>= I 2) (> N 0) (<= N 1048576)))
               true (error "http: invalid response limit"))
         _ (address-> Config I N)
      (http.output-config Config Rest [Name | Seen]))
  _ _ _ -> (error "http: response options must be [Name Number] pairs"))

(define http.finish-source
  Result [] -> Result
  Result S ->
    (http.finished-source Result (trap-error (http.source-close S)
                       (/. X [error (http.output-error (error-to-string X))]))))

(define http.finished-source
  [ok N] [error Error] -> [error (io.progress Error N)]
  Result Closed -> (io.finish Result Closed))

\\ Preparation validates metadata and primes at most one chunk before committing headers.
\\ Plans are private and single use: header/wire, source, framing, first result, limits, used.
(define http.prepare-response
  Method Response Limits Close D ->
    (let S (http.response-source Response)
         Result (trap-error [ok (http.prepare-output Method Response Limits Close D)]
                  (/. X [error (http.output-error (error-to-string X))]))
      (http.prepared-source Result S)))

(define http.prepared-source
  [ok Plan] S -> (http.prepared-first Plan S (<-address Plan 3))
  [error Error] S -> (http.finish-source [error Error] S))

(define http.prepare-output
  Method Response Limits Close D ->
    (let _ (http.response-check Response)
         S (http.response-source Response)
      (if (empty? S)
          (io.record [(http.encode-mode Method Response (<-address Limits 0) (<-address Limits 1) Close)
                      [] [] [suppressed] Limits false])
          (let _ (http.source-claim S)
               Framing (<-address Response 3)
               _ (http.length-limit Framing (<-address Limits 1))
               Head (http.encode-head Method Response Framing Close (<-address Limits 0))
               First (if (http.suppressed? Method (<-address Response 1)) [suppressed]
                         (http.pull S Framing Limits 0 0 D))
            (io.record [Head S Framing First Limits false])))))

(define http.length-limit
  [length N] Maximum -> (if (<= N Maximum) true (error "http: response body exceeds limit"))
  [chunked] _ -> true)

(define http.prepared-first
  _ S [error Error] -> (http.finish-source [error Error] S)
  Plan _ _ -> [ok Plan])

(define http.body-remaining
  [length N] _ Used -> (- N Used)
  [chunked] Limits Used -> (- (<-address Limits 1) Used))

(define http.pull
  S Framing Limits Used Count D ->
    (let Left (http.body-remaining Framing Limits Used)
         Maximum (if (or (= Left 0) (= Count (<-address Limits 3))) 1
                     (io.min Left (<-address Limits 2)))
      (http.pulled Framing Left Count Limits (http.source-next S Maximum D))))

(define http.pulled
  [length _] Left _ _ [eof] ->
    (if (= Left 0) [eof] [error (http.output-error "response source ended before Content-Length")])
  _ _ _ _ [eof] -> [eof]
  _ _ _ _ [error Error] -> [error Error]
  _ Left Count Limits [chunk V] ->
    (cond ((= Left 0) [error (http.output-error "response source exceeds body length or limit")])
          ((= Count (<-address Limits 3)) [error (http.output-error "response source exceeds chunk count limit")])
          (true [chunk V])))

(define http.send-response
  E Request Response D Options ->
    (let Prepared (trap-error
                     (http.prepare-response (http.method Request) Response (http.output-options Options) true D)
                     (/. X (http.finish-source [error (http.output-error (error-to-string X))]
                             (http.response-source Response))))
      (http.send-prepared E D Prepared)))

(define http.send-prepared
  _ _ [error Error] -> [error Error]
  E D [ok Plan] -> (http.send-plan E D Plan))

(define http.send-plan
  E D Plan ->
    (let _ (if (<-address Plan 5) (error "http: response plan already sent") true)
         _ (address-> Plan 5 true)
         State (io.record [E D Plan 0 0 0])
         Result (trap-error (http.output-start State)
                  (/. X [error (io.progress (http.output-error (error-to-string X)) (<-address State 3))]))
      (http.finish-source Result (<-address Plan 1))))

\\ Write a complete frame before requesting the next producer chunk.
(define http.output-write
  State V -> (http.output-write-loop State V 0 (buffer.length V)))

(define http.output-write-loop
  _ _ N N -> [ok]
  State V At End ->
    (http.output-write-ready State V At End (http.output-budget (<-address State 1))))

(define http.output-write-ready
  State _ _ _ [error Error] -> [error (io.progress Error (<-address State 3))]
  State V At End [ok] ->
    (http.output-written State V At End
      (io.write-some (<-address State 0) (buffer.slice V At (- End At)) [])))

(define http.output-written
  State _ _ _ [error Error] -> [error (io.progress Error (<-address State 3))]
  State V At End [written N] ->
    (do (address-> State 3 (+ (<-address State 3) N))
        (http.output-write-loop State V (+ At N) End)))

(define http.output-start
  State ->
    (let Plan (<-address State 2)
      (http.output-headed State (http.output-write State (<-address Plan 0)))))

(define http.output-headed
  _ [error Error] -> [error Error]
  State [ok] ->
    (let Plan (<-address State 2)
      (http.output-step State (<-address Plan 3))))

(define http.output-step
  State [error Error] -> [error (io.progress Error (<-address State 3))]
  State [suppressed] -> (http.output-done State)
  State [eof] ->
    (let Plan (<-address State 2)
      (if (= (<-address Plan 2) [chunked])
          (http.output-ended State (http.output-write State (buffer.from-string "0c#13;c#10;c#13;c#10;")))
          (http.output-done State)))
  State [chunk V] ->
    (let Plan (<-address State 2)
         Frame (if (= (<-address Plan 2) [chunked]) (http.chunk-frame V) V)
      (http.output-body State V (http.output-write State Frame))))

(define http.output-body
  _ _ [error Error] -> [error Error]
  State V [ok] ->
    (let Plan (<-address State 2)
         Used (+ (<-address State 4) (buffer.length V))
         Count (+ (<-address State 5) 1)
         _ (address-> State 4 Used)
         _ (address-> State 5 Count)
      (http.output-step State (http.pull (<-address Plan 1) (<-address Plan 2)
                                        (<-address Plan 4) Used Count (<-address State 1)))))

(define http.output-ended
  _ [error Error] -> [error Error]
  State [ok] -> (http.output-done State))

(define http.output-done
  State ->
    (http.output-complete State (http.output-budget (<-address State 1))))

(define http.output-complete
  State [ok] -> [ok (<-address State 3)]
  State [error Error] -> [error (io.progress Error (<-address State 3))])

(define http.hex
  N -> (if (< N 16) (pos "0123456789abcdef" N)
           (cn (http.hex (shen-jit.shift-right N 4))
               (pos "0123456789abcdef" (shen-jit.bit-and N 15)))))

(define http.chunk-frame
  V ->
    (let Prefix (buffer.from-string (cn (http.hex (buffer.length V)) "c#13;c#10;"))
         N (buffer.length V)
         P (buffer.length Prefix)
         Out (buffer.new (+ P N 2))
         _ (buffer.copy! Out 0 Prefix 0 P)
         _ (buffer.copy! Out P V 0 N)
      (do (buffer.u8! Out (+ P N) 13) (buffer.u8! Out (+ P N 1) 10) Out)))

(datatype http-response-framing
  N : number;
  ==============================
  [length N] : http.response-framing;

  ______________________________
  [chunked] : http.response-framing;)

(datatype http-response-options
  N : number;
  ==================================
  [response-head-limit N] : http.response-option;

  N : number;
  ==================================
  [response-body-limit N] : http.response-option;

  N : number;
  ==================================
  [response-chunk-size N] : http.response-option;

  N : number;
  ==================================
  [response-chunk-count-limit N] : http.response-option;)

(declare http.response [number --> [[list [list string]] --> [buffer.view --> http.response]]])
(declare http.close-after [http.response --> http.response])
(declare http.source
  [[number --> [deadline --> io.chunk-result]] --> [[lazy io.close-result] --> http.source]])
(declare http.source-close [http.source --> io.close-result])
(declare http.stream-response
  [number --> [[list [list string]] --> [http.response-framing --> [http.source --> http.response]]]])
(declare http.encode-response [http.request --> [http.response --> [number --> [number --> buffer.view]]]])
(declare http.send-response
  [io.endpoint --> [http.request --> [http.response --> [deadline -->
    [[list http.response-option] --> [io.result number]]]]]])
