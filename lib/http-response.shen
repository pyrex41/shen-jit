\\ Bounded HTTP/1.1 final responses. Load http-request.shen after the buffer/I/O libraries first.
\\ Application fields are ordered pairs; framing fields are supplied by this encoder.

(define http.response
  Status Fields Body ->
    (let Code (buffer.index Status)
         _ (if (and (>= Code 200) (<= Code 599)) true
               (error "http: final response status must be 200..599"))
         _ (buffer.check Body)
      (io.record [http.response Code Fields Body])))

(define http.response-check
  Response -> (if (io.tag? Response http.response) Response (error "http: not a response")))

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

(define http.encode-for
  Method Response HeadLimit BodyLimit ->
    (let _ (http.response-check Response)
         MaxHead (buffer.index HeadLimit)
         MaxBody (buffer.index BodyLimit)
         _ (if (and (>= MaxHead 4) (<= MaxHead 1048576)) true
               (error "http: response head limit must be 4..1048576"))
         Status (<-address Response 1)
         Body (<-address Response 3)
         N (buffer.length Body)
         _ (if (<= N MaxBody) true (error "http: response body exceeds limit"))
         Bodyless (element? Status [204 205 304])
         _ (if (and Bodyless (> N 0)) (error "http: bodyless status requires an empty body") true)
         TailText (if (element? Status [204 304])
                      "Connection: closec#13;c#10;c#13;c#10;"
                      (make-string "Content-Length: ~Ac#13;c#10;Connection: closec#13;c#10;c#13;c#10;" N))
         Tail (shen-jit.string->bytes TailText)
         Start (shen-jit.string->bytes (make-string "HTTP/1.1 ~A ~Ac#13;c#10;" Status (http.reason Status)))
         Base (+ (shen-jit.bytes-length Start) (shen-jit.bytes-length Tail))
         _ (if (<= Base MaxHead) true (error "http: response head exceeds limit"))
         Fields (http.response-fields (<-address Response 2) 0 (- MaxHead Base) [Start] Base)
         HeadBytes (snd Fields)
         Send (if (or (= Method "HEAD") Bodyless) 0 N)
         Out (buffer.new (+ HeadBytes Send))
         _ (http.response-copy Out 0 (append (fst Fields) [Tail]))
      (do (buffer.copy! Out HeadBytes Body 0 Send) Out)))

(define http.encode-response
  Request Response HeadLimit BodyLimit ->
    (http.encode-for (http.method Request) Response HeadLimit BodyLimit))

(declare http.response [number --> [[list [list string]] --> [buffer.view --> http.response]]])
(declare http.encode-response [http.request --> [http.response --> [number --> [number --> buffer.view]]]])
