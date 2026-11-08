\\ One HTTP/1.1 request per owned socket. Load clock/deadline/socket I/O and HTTP modules first.
\\ The application receives a complete request and returns a response value, without writing bytes.

(shen-jit.library http.time-lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign http.c-time http.time-lib
  (if (= (value *os*) "Windows") "_time64" "time") (pointer) --> int64)

(define http.quotient
  N Divisor -> (/ (- N (shen.mod N Divisor)) Divisor))

(define http.leap?
  Year -> (and (= (shen.mod Year 4) 0)
               (or (not (= (shen.mod Year 100) 0)) (= (shen.mod Year 400) 0))))

(define http.calendar-year
  Days Year ->
    (let Count (if (http.leap? Year) 366 365)
      (if (< Days Count) (@p Year Days) (http.calendar-year (- Days Count) (+ Year 1)))))

(define http.calendar-month
  Days Year Month ->
    (let Count (cond ((= Month 2) (if (http.leap? Year) 29 28))
                      ((element? Month [4 6 9 11]) 30)
                      (true 31))
      (if (< Days Count) (@p Month (+ Days 1)) (http.calendar-month (- Days Count) Year (+ Month 1)))))

(define http.list-at
  [X | _] 0 -> X
  [_ | Rest] N -> (http.list-at Rest (- N 1)))

(define http.two-digits
  N -> (if (< N 10) (cn "0" (str N)) (str N)))

(define http.date-value
  Seconds ->
    (let N (buffer.index Seconds)
         _ (if (< N 253402300800) true (error "http: date is outside years 1970..9999"))
         Days (http.quotient N 86400)
         Time (shen.mod N 86400)
         Calendar (http.calendar-year Days 1970)
         Year (fst Calendar)
         MonthDay (http.calendar-month (snd Calendar) Year 1)
         Month (http.list-at ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
                             (- (fst MonthDay) 1))
         Weekday (http.list-at ["Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"] (shen.mod (+ Days 4) 7))
      (make-string "~A, ~A ~A ~A ~A:~A:~A GMT"
        Weekday (http.two-digits (snd MonthDay)) Month Year
        (http.two-digits (http.quotient Time 3600))
        (http.two-digits (http.quotient (shen.mod Time 3600) 60))
        (http.two-digits (shen.mod Time 60)))))

(define http.has-date?
  [] -> false
  [[Name _] | Rest] -> (or (= (http.lower Name) "date") (http.has-date? Rest))
  _ -> (error "http: response fields must be pairs"))

(define http.server-response
  Response ->
    (let _ (http.response-check Response)
         Fields (<-address Response 2)
      (if (http.has-date? Fields)
          Response
          (let Date (trap-error (http.date-value (http.c-time [])) (/. X []))
            (if (empty? Date)
                Response
                (http.response (<-address Response 1) [["Date" Date] | Fields] (<-address Response 3)))))))

(define http.option-index
  head-limit -> 0
  body-limit -> 1
  response-head-limit -> 2
  response-body-limit -> 3
  head-timeout -> 4
  body-timeout -> 5
  write-timeout -> 6
  chunk-line-limit -> 7
  chunk-metadata-limit -> 8
  trailer-limit -> 9
  trailer-fields-limit -> 10
  chunk-count-limit -> 11
  _ -> (error "http: unknown server option"))

(define http.server-options
  Options ->
    (http.configure (io.record [16384 1048576 16384 1048576 5000 5000 5000
                               8192 65536 16384 100 4096]) Options []))

(define http.configure
  Config [] _ -> Config
  Config [[Name Value] | Rest] Seen ->
    (let I (http.option-index Name)
         _ (if (element? Name Seen) (error "http: duplicate server option") true)
         N (buffer.index Value)
         _ (if (element? I [0 2])
               (if (and (>= N (if (= I 2) 128 4)) (<= N 1048576))
                   true (error "http: invalid server head limit"))
               true)
         _ (if (>= I 7) (http.chunk-options [[Name N]]) true)
         _ (address-> Config I N)
      (http.configure Config Rest [Name | Seen]))
  _ _ _ -> (error "http: server options must be [Name Number] pairs"))

(define http.serve-one
  E Handler Options ->
    (let Config (http.server-options Options)
         _ (io.socket-check E)
      (io.with-endpoint E (/. Connection (http.server-read Connection Handler Config)))))

(define http.server-read
  E Handler Config ->
    (let R (io.reader E [])
         D (clock.deadline (<-address Config 4))
         _ (io.socket-deadline E D)
         F (http.head-reader R (<-address Config 0))
      (http.server-head E R Handler Config (http.read-head-until F D))))

(define http.server-head
  _ _ _ _ [eof] -> [ok 0]
  E _ _ Config [error Error] -> (http.server-fail E Config Error)
  E R Handler Config [head V] ->
    (http.server-parsed E R Handler Config (http.parse-request V (<-address Config 1))))

(define http.server-parsed
  E _ _ Config [error Error] -> (http.server-fail E Config Error)
  E R Handler Config [ok Request] ->
    (let D (clock.deadline (<-address Config 5))
         _ (io.socket-deadline E D)
         B (http.body-reader-with R Request (http.server-body-options Config))
      (http.server-body E Handler Config (http.read-body-until B D))))

(define http.server-body-options
  Config -> [[chunk-line-limit (<-address Config 7)] [chunk-metadata-limit (<-address Config 8)]
             [trailer-limit (<-address Config 9)] [trailer-fields-limit (<-address Config 10)]
             [chunk-count-limit (<-address Config 11)]])

(define http.server-body
  E _ Config [error Error] -> (http.server-fail E Config Error)
  E Handler Config [ok Request] ->
    (let Prepared (trap-error
                     [ok (http.encode-response Request (http.server-response (Handler Request))
                                               (<-address Config 2) (<-address Config 3))]
                     (/. X [error (io.native-error http-response application 500 "HTTP response"
                                                   (error-to-string X))]))
      (http.server-prepared E Config Prepared)))

(define http.server-prepared
  E Config [error Error] -> (http.server-fail E Config Error)
  E Config [ok Wire] -> (http.server-sent (http.server-send E Config Wire)))

(define http.server-send
  E Config Wire ->
    (let D (clock.deadline (<-address Config 6))
         _ (io.socket-deadline E D)
      (io.write-all E Wire [])))

(define http.server-sent
  [ok N] -> [ok N]
  [error Error N] -> [error (io.progress Error N)])

(define http.server-status
  Error ->
    (let Domain (io.error-domain Error)
      (cond ((= Domain http) (io.error-code Error))
            ((= Domain application) 500)
            ((= Domain timeout) 408)
            ((and (= Domain library) (= (io.error-operation Error) http-head))
              (if (= (io.error-message Error) "head exceeds byte limit") 431 400))
            (true 0))))

(define http.server-fail
  E Config Error ->
    (let Status (http.server-status Error)
      (if (= Status 0)
          [error Error]
          (let Response (http.server-response (http.response Status [] (buffer.new 0)))
               Wire (http.encode-for "GET" Response (<-address Config 2) (<-address Config 3))
            (http.server-rejected Error (http.server-send E Config Wire))))))

(define http.server-rejected
  Error [ok _] -> [error Error]
  Error [error Other N] -> [error (io.secondary Error (io.progress Other N))])

(datatype http-server-options
  Option : http.chunk-option;
  ===========================
  Option : http.option;

  N : number;
  ===========================
  [head-limit N] : http.option;

  N : number;
  ===========================
  [body-limit N] : http.option;

  N : number;
  ====================================
  [response-head-limit N] : http.option;

  N : number;
  ====================================
  [response-body-limit N] : http.option;

  N : number;
  =============================
  [head-timeout N] : http.option;

  N : number;
  =============================
  [body-timeout N] : http.option;

  N : number;
  ==============================
  [write-timeout N] : http.option;)

(declare http.serve-one
  [io.endpoint --> [[http.request --> http.response] --> [[list http.option] --> [io.result number]]]])
