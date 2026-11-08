\\ Bounded synchronous HTTP(S) over the optional libcurl adapter. Load ffi, buffer and io first.
\\ A client is single-owner; the adapter rejects concurrent request/close on the same handle.

(shen-jit.library curl.adapter
  (trap-error (value curl.*adapter-files*)
    (/. X ["./build/shen-curl.so" "./lib/shen-curl.so" "./shen-curl.so"
           "./build/shen-curl.dll" "./lib/shen-curl.dll" "./shen-curl.dll"])))
(define-foreign curl.c-abi curl.adapter "shen_curl_abi" () --> int32)
(define-foreign-procedure curl.c-version curl.adapter "shen_curl_version" 0)
(define-foreign-procedure curl.c-open curl.adapter "shen_curl_open" 0)
(define-foreign-procedure curl.c-close curl.adapter "shen_curl_close" 2)
(define-foreign-procedure curl.c-request curl.adapter "shen_curl_request" 6)
(define-foreign-procedure curl.c-stream curl.adapter "shen_curl_stream" 3)

(define curl.abi-check
  -> (if (= (curl.c-abi) 2) true (error "curl: incompatible adapter ABI; rebuild with make curl")))

(define curl.version
  -> (do (curl.abi-check) (curl.c-version)))

(define curl.open
  -> (do (curl.abi-check) (io.record [curl.client-state (curl.c-open) []])))

(define curl.client-check
  Client -> (if (io.tag? Client curl.client-state) Client (error "curl: not a client")))

(define curl.live
  Client ->
    (let P (<-address (curl.client-check Client) 1)
      (if (= (shen-jit.pointer-address P) 0)
          (error "curl: client is closed or stale") P)))

(define curl.invalidate
  P -> (shen-jit.pointer-kill P))

(define curl.close
  Client ->
    (let _ (curl.client-check Client)
         P (<-address Client 1)
         Saved (<-address Client 2)
      (if (not (empty? Saved))
          Saved
          (let Result (trap-error (do (curl.c-close P (function curl.invalidate)) [ok])
                         (/. X [error (io.error close "curl client" (error-to-string X))]))
            (do (if (= (shen-jit.pointer-address P) 0) (address-> Client 2 Result) true)
                Result)))))

(define curl.scope-result
  [ok Value] -> [ok Value]
  [error Error] -> (if (io.error? Error) [error Error] (error "curl: invalid callback error"))
  _ -> (error "curl: callback must return [ok Value] or [error Error]"))

(define curl.with-client
  F ->
    (let Client (curl.open)
         Result (trap-error (curl.scope-result (F Client))
                  (/. X [error (io.error callback "curl client" (error-to-string X))]))
      (io.finish Result (curl.close Client))))

(define curl.option-index
  request-limit -> 0
  body-limit -> 1
  header-limit -> 2
  timeout -> 3
  connect-timeout -> 4
  redirect-limit -> 5
  ca-file -> 6
  proxy -> 7
  chunk-size -> 8
  _ -> (error "curl: unknown option"))

(define curl.options
  Options -> (curl.configure (io.record [1048576 1048576 65536 30000 5000 0 [] []]) Options [] false))

(define curl.stream-options
  Options -> (curl.configure (io.record [1048576 1048576 65536 30000 5000 0 [] [] 16384]) Options [] true))

(define curl.configure
  Config [] _ _ -> Config
  Config [[Name Value] | Rest] Seen Stream ->
    (let I (curl.option-index Name)
         _ (if (and (= I 8) (not Stream)) (error "curl: chunk-size requires a streaming request") true)
         _ (if (element? Name Seen) (error "curl: duplicate option") true)
         V (if (element? I [6 7])
               (curl.text Value (if (= I 6) 4096 8192))
               (curl.numeric-option I Value Stream))
         _ (if (and (= I 6) (= V "")) (error "curl: empty CA file") true)
         _ (address-> Config I V)
      (curl.configure Config Rest [Name | Seen] Stream))
  _ _ _ _ -> (error "curl: options must be [Name Value] pairs"))

(define curl.numeric-option
  I Value Stream ->
    (let N (buffer.index Value)
         Maximum (cond ((and (= I 1) Stream) 2305843009213693951)
                       ((< I 2) 268435456) ((= I 2) 1048576) ((< I 5) 2147483647)
                       ((= I 8) 65536) (true 20))
      (if (and (<= N Maximum) (or (not (element? I [3 4 8])) (> N 0)))
          N (error "curl: invalid numeric option"))))

(define curl.no-nul
  _ At At -> true
  B At End -> (if (= (shen-jit.u8 B At) 0) (error "curl: text contains NUL")
                 (curl.no-nul B (+ At 1) End)))

(define curl.text
  Text Maximum ->
    (let _ (if (string? Text) true (error "curl: expected a string"))
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
         _ (if (<= N Maximum) true (error "curl: text exceeds limit"))
      (do (curl.no-nul B 0 N) Text)))

(define curl.lower-byte
  B -> (if (and (>= B 65) (<= B 90)) (+ B 32) B))

(define curl.lower
  Text ->
    (let B (shen-jit.string->bytes Text)
         _ (curl.lower-bytes B 0 (shen-jit.bytes-length B))
      (shen-jit.bytes->string B 0 (shen-jit.bytes-length B))))

(define curl.lower-bytes
  _ At At -> true
  B At End -> (do (shen-jit.u8! B At (curl.lower-byte (shen-jit.u8 B At)))
                  (curl.lower-bytes B (+ At 1) End)))

(define curl.url-check
  URL ->
    (let Text (curl.text URL 8192)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (cond ((and (>= N 7) (= (curl.lower (shen-jit.bytes->string B 0 7)) "http://"))
              (cn "http://" (shen-jit.bytes->string B 7 (- N 7))))
            ((and (>= N 8) (= (curl.lower (shen-jit.bytes->string B 0 8)) "https://"))
              (cn "https://" (shen-jit.bytes->string B 8 (- N 8))))
            (true (error "curl: URL must use http:// or https://")))))

(define curl.token-byte?
  B -> (or (and (>= B 48) (<= B 57)) (and (>= B 65) (<= B 90))
           (and (>= B 97) (<= B 122)) (element? B [33 35 36 37 38 39 42 43 45 46 94 95 96 124 126])))

(define curl.token-range?
  _ At At -> true
  B At End -> (and (curl.token-byte? (shen-jit.u8 B At)) (curl.token-range? B (+ At 1) End)))

(define curl.token
  Text Maximum ->
    (let _ (curl.text Text Maximum)
         B (shen-jit.string->bytes Text)
         N (shen-jit.bytes-length B)
      (if (and (> N 0) (curl.token-range? B 0 N)) Text (error "curl: invalid HTTP token"))))

(define curl.field-value?
  _ At At -> true
  B At End ->
    (let C (shen-jit.u8 B At)
      (and (or (= C 9) (>= C 32)) (not (= C 127)) (curl.field-value? B (+ At 1) End))))

(define curl.has-content-type?
  [] -> false
  [[Name _] | Rest] -> (or (= (curl.lower Name) "content-type") (curl.has-content-type? Rest))
  _ -> (error "curl: headers must be [Name Value] pairs"))

(define curl.request-fields
  [] _ _ Acc -> (reverse Acc)
  [[Name Value] | Rest] Count Total Acc ->
    (let _ (curl.token Name 8192)
         _ (curl.text Value 8192)
         _ (if (element? (curl.lower Name) ["content-length" "transfer-encoding"])
               (error "curl: request framing headers are managed by libcurl") true)
         V (shen-jit.string->bytes Value)
         _ (if (curl.field-value? V 0 (shen-jit.bytes-length V)) true (error "curl: invalid header value"))
         Line (cn Name (if (= Value "") ";" (cn ": " Value)))
         N (shen-jit.bytes-length (shen-jit.string->bytes Line))
         _ (if (and (< Count 100) (<= N 8192) (<= (+ Total N) 65536)) true
               (error "curl: request headers exceed limit"))
      (curl.request-fields Rest (+ Count 1) (+ Total N) [Line | Acc]))
  _ _ _ _ -> (error "curl: headers must be [Name Value] pairs"))

(define curl.request-input
  Method URL Fields Body Options ->
    (curl.input Method URL Fields Body (curl.options Options)))

(define curl.input
  Method URL Fields Body Config ->
    (let _ (curl.token Method 32)
         Target (curl.url-check URL)
         N (buffer.length Body)
         _ (if (<= N (<-address Config 0)) true (error "curl: request body exceeds limit"))
         _ (if (and (element? Method ["GET" "HEAD"]) (> N 0)) (error "curl: GET/HEAD require an empty body") true)
         _ (if (and (> (<-address Config 5) 0) (not (element? Method ["GET" "HEAD"])))
               (error "curl: automatic redirects are limited to GET/HEAD") true)
         Headers (if (or (element? Method ["GET" "HEAD"]) (curl.has-content-type? Fields)) Fields
                     (append Fields [["Content-Type" "application/octet-stream"]]))
         Lines (curl.request-fields Headers 0 0 [])
         Bytes (buffer.bytes Body)
      (io.record [Method Target Lines Bytes Config])))

(define curl.perform
  Client Input ->
    (let P (curl.live Client)
         URL (<-address Input 1)
      (trap-error (curl.result URL (curl.c-request P (<-address Input 0) URL
                                    (<-address Input 2) (<-address Input 3) (<-address Input 4)))
        (/. X [error (io.error request URL (error-to-string X))]))))

(define curl.request
  Client Method URL Fields Body Options ->
    (do (curl.live Client)
        (curl.perform Client (curl.request-input Method URL Fields Body Options))))

(define curl.result
  URL Native ->
    (if (= (<-address Native 0) 0)
        (let Head (buffer.wrap (<-address Native 7))
             Trailers (buffer.wrap (<-address Native 8))
          [ok (io.record [curl.response-state (<-address Native 4) (<-address Native 5)
                          (buffer.wrap (<-address Native 6)) (curl.parse-fields Head true)
                          (curl.parse-fields Trailers false) Head Trailers
                          (<-address Native 9) (<-address Native 10)
                          (shen-jit.bytes-length (<-address Native 6))])])
        [error (io.progress (io.native-error request
                             (cond ((element? (<-address Native 1) [2 3]) limit)
                                   ((= (<-address Native 0) 28) timeout)
                                   (true curl))
                             (<-address Native 0) URL (<-address Native 2)) (<-address Native 3))]))

(define curl.fetch
  Method URL Fields Body Options ->
    (let Input (curl.request-input Method URL Fields Body Options)
      (curl.with-client (/. Client (curl.perform Client Input)))))

(define curl.get
  URL Options -> (curl.fetch "GET" URL [] (buffer.new 0) Options))

\\ Streaming state: current sink, bytes accepted by it, first error. Only one chunk is live here.
(define curl.stream-mark
  R Count -> (do (address-> R 3 []) (address-> R 10 Count) R))

(define curl.sink-result
  [ok Sink] -> [ok (io.endpoint-check Sink)]
  [error Error] -> (if (io.error? Error) [error Error] (error "curl: invalid sink error"))
  _ -> (error "curl: sink opener must return [ok Endpoint] or [error Error]"))

(define curl.stream-opened
  State [ok Sink] ->
    (do (address-> State 0 Sink) (io.check Sink write []) true)
  State [error Error] -> (do (address-> State 2 Error) false))

(define curl.stream-write
  State Bytes ->
    (curl.stream-write-loop State (buffer.wrap Bytes) 0 (shen-jit.bytes-length Bytes)))

(define curl.stream-write-loop
  _ _ End End -> true
  State View At End ->
    (let Sink (<-address State 0)
         Result (trap-error (io.write-some Sink (buffer.slice View At (- End At)) [])
                  (/. X [error (io.error write (<-address Sink 1) (error-to-string X))]))
      (curl.stream-written State View At End Result)))

(define curl.stream-written
  State View At End [written N] ->
    (do (address-> State 1 (+ (<-address State 1) N))
        (curl.stream-write-loop State View (+ At N) End))
  State _ _ _ [error Error] -> (do (address-> State 2 Error) false))

(define curl.stream-event
  State _ _ [] Bytes -> (curl.stream-write State Bytes)
  State Open URL Native _ ->
    (curl.stream-opened State
      (curl.sink-result (Open (curl.stream-mark (curl.stream-head (curl.result URL Native)) 0)))))

(define curl.stream-head
  [ok R] -> R)

(define curl.stream-deliver
  State Open URL Native Bytes ->
    (trap-error (curl.stream-event State Open URL Native Bytes)
      (/. X (do (address-> State 2 (io.error callback URL (error-to-string X))) false))))

(define curl.stream-completed
  State [ok R] -> [ok (curl.stream-mark R (<-address State 1))]
  State [error Error] -> [error (io.progress Error (<-address State 1))])

(define curl.stream-perform
  Client Input Open State ->
    (let P (curl.live Client)
         URL (<-address Input 1)
         Native (trap-error
                  (curl.result URL (curl.c-stream P Input (/. Head Bytes (curl.stream-deliver State Open URL Head Bytes))))
                  (/. X [error (io.error request URL (error-to-string X))]))
         Error (<-address State 2)
      (curl.stream-completed State (if (empty? Error) Native [error Error]))))

(define curl.request-to
  Client Method URL Fields Body Sink Options ->
    (do (curl.live Client) (io.check Sink write [])
        (curl.stream-perform Client (curl.input Method URL Fields Body (curl.stream-options Options))
          (/. Head [ok Sink]) (io.record [[] 0 []]))))

(define curl.stream-close
  [] -> [ok]
  Sink -> (trap-error (io.close Sink)
            (/. X [error (io.error close "curl sink" (error-to-string X))])))

(define curl.request-with-sink
  Client Method URL Fields Body Open Options ->
    (let _ (curl.live Client)
         Input (curl.input Method URL Fields Body (curl.stream-options Options))
         State (io.record [[] 0 []])
         Result (curl.stream-perform Client Input Open State)
      (curl.stream-completed State (io.finish Result (curl.stream-close (<-address State 0))))))

(define curl.get-to
  URL Sink Options ->
    (let _ (io.check Sink write [])
         Input (curl.input "GET" URL [] (buffer.new 0) (curl.stream-options Options))
      (curl.with-client
        (/. Client (curl.stream-perform Client Input (/. Head [ok Sink]) (io.record [[] 0 []]))))))

\\ Parse only the final status block; native callbacks retain trailers separately.
(define curl.find-byte
  _ At At _ -> At
  B At End Byte -> (if (= (shen-jit.u8 B At) Byte) At (curl.find-byte B (+ At 1) End Byte)))

(define curl.trim-left
  B At End -> (if (and (< At End) (element? (shen-jit.u8 B At) [9 32]))
                 (curl.trim-left B (+ At 1) End) At))

(define curl.trim-right
  B At End -> (if (and (> End At) (element? (shen-jit.u8 B (- End 1)) [9 32]))
                 (curl.trim-right B At (- End 1)) End))

(define curl.header-text
  B At End ->
    (let Start (curl.trim-left B At End)
         Stop (curl.trim-right B Start End)
      (shen-jit.bytes->string B Start (- Stop Start))))

(define curl.parse-fields
  View SkipStatus ->
    (let B (buffer.owner View)
         N (buffer.length View)
         At (if SkipStatus (io.min N (+ (curl.find-byte B 0 N 10) 1)) 0)
      (curl.parse-lines B At N [])))

(define curl.parse-lines
  _ At At Acc -> (reverse Acc)
  B At End Acc ->
    (let LF (curl.find-byte B At End 10)
         Stop (if (and (> LF At) (= (shen-jit.u8 B (- LF 1)) 13)) (- LF 1) LF)
         Next (io.min End (+ LF 1))
         _ (if (curl.field-value? B At Stop) true (error "curl: invalid response field value"))
         Fields (if (= Stop At) Acc (curl.parse-line B At Stop Acc))
      (curl.parse-lines B Next End Fields)))

(define curl.parse-line
  B At End Acc ->
    (if (element? (shen-jit.u8 B At) [9 32])
        (curl.continuation Acc (curl.header-text B At End))
        (let Colon (curl.find-byte B At End 58)
             _ (if (and (> Colon At) (< Colon End) (curl.token-range? B At Colon))
                   true (error "curl: malformed response field"))
             _ (if (curl.field-value? B (+ Colon 1) End) true (error "curl: invalid response field value"))
             Name (curl.lower (shen-jit.bytes->string B At (- Colon At)))
          [[Name (curl.header-text B (+ Colon 1) End)] | Acc])))

(define curl.continuation
  [[Name Value] | Rest] Text -> [[Name (cn Value (cn " " Text))] | Rest]
  _ _ -> (error "curl: response continuation without a field"))

(define curl.response-check
  R -> (if (io.tag? R curl.response-state) R (error "curl: not a response")))

(define curl.status
  R -> (<-address (curl.response-check R) 1))
(define curl.url
  R -> (<-address (curl.response-check R) 2))
(define curl.body
  R -> (let Body (<-address (curl.response-check R) 3)
         (if (empty? Body) (error "curl: response body was streamed") Body)))
(define curl.streamed?
  R -> (empty? (<-address (curl.response-check R) 3)))
(define curl.body-length
  R -> (<-address (curl.response-check R) 10))
(define curl.headers
  R -> (<-address (curl.response-check R) 4))
(define curl.trailers
  R -> (<-address (curl.response-check R) 5))
(define curl.raw-headers
  R -> (<-address (curl.response-check R) 6))
(define curl.raw-trailers
  R -> (<-address (curl.response-check R) 7))
(define curl.elapsed
  R -> (<-address (curl.response-check R) 8))
(define curl.redirects
  R -> (<-address (curl.response-check R) 9))

(define curl.field-values
  [] _ -> []
  [[Name Value] | Rest] Name -> [Value | (curl.field-values Rest Name)]
  [_ | Rest] Name -> (curl.field-values Rest Name))

(define curl.header-values
  R Name -> (curl.field-values (curl.headers R) (curl.lower Name)))

(datatype curl-options
  N : number;
  =============================
  [request-limit N] : curl.option;
  N : number;
  =============================
  [body-limit N] : curl.option;
  N : number;
  =============================
  [header-limit N] : curl.option;
  N : number;
  =============================
  [timeout N] : curl.option;
  N : number;
  =============================
  [connect-timeout N] : curl.option;
  N : number;
  =============================
  [redirect-limit N] : curl.option;
  S : string;
  =============================
  [ca-file S] : curl.option;
  S : string;
  =============================
  [proxy S] : curl.option;
  N : number;
  =============================
  [chunk-size N] : curl.option;)

(declare curl.version [--> string])
(declare curl.open [--> curl.client])
(declare curl.close [curl.client --> io.close-result])
(declare curl.with-client [[curl.client --> [io.result A]] --> [io.result A]])
(declare curl.request
  [curl.client --> [string --> [string --> [[list [list string]] -->
    [buffer.view --> [[list curl.option] --> [io.result curl.response]]]]]]])
(declare curl.fetch
  [string --> [string --> [[list [list string]] --> [buffer.view --> [[list curl.option] --> [io.result curl.response]]]]]])
(declare curl.get [string --> [[list curl.option] --> [io.result curl.response]]])
(declare curl.request-to
  [curl.client --> [string --> [string --> [[list [list string]] --> [buffer.view -->
    [io.endpoint --> [[list curl.option] --> [io.result curl.response]]]]]]]])
(declare curl.request-with-sink
  [curl.client --> [string --> [string --> [[list [list string]] --> [buffer.view -->
    [[curl.response --> [io.result io.endpoint]] --> [[list curl.option] --> [io.result curl.response]]]]]]]])
(declare curl.get-to [string --> [io.endpoint --> [[list curl.option] --> [io.result curl.response]]]])
(declare curl.status [curl.response --> number])
(declare curl.url [curl.response --> string])
(declare curl.body [curl.response --> buffer.view])
(declare curl.streamed? [curl.response --> boolean])
(declare curl.body-length [curl.response --> number])
(declare curl.headers [curl.response --> [list [list string]]])
(declare curl.trailers [curl.response --> [list [list string]]])
(declare curl.raw-headers [curl.response --> buffer.view])
(declare curl.raw-trailers [curl.response --> buffer.view])
(declare curl.elapsed [curl.response --> number])
(declare curl.redirects [curl.response --> number])
(declare curl.header-values [curl.response --> [string --> [list string]]])
