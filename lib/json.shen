\\ Complete UTF-8 JSON over byte views. Load buffer.shen first, under (tc -).
\\ Numbers decode to lossless [number Token] values; native numbers can also be encoded.

(define json.scan-fail
  I What -> (error "json: byte ~A: ~A" I What))

(define json.scan-byte
  Data I End -> (if (< I End) (shen-jit.u8 Data I) (json.scan-fail I "unexpected end")))

(define json.scan-space
  Data I End -> I where (>= I End)
  Data I End -> (let B (shen-jit.u8 Data I)
                  (if (element? B [32 9 10 13]) (json.scan-space Data (+ I 1) End) I)))

(define json.scan-digit?
  B -> (and (>= B 48) (<= B 57)))

(define json.scan-digits
  Data I End -> I where (>= I End)
  Data I End -> (if (json.scan-digit? (shen-jit.u8 Data I))
                   (json.scan-digits Data (+ I 1) End) I))

(define json.scan-need-digits
  Data I End -> (if (json.scan-digit? (json.scan-byte Data I End))
                   (json.scan-digits Data (+ I 1) End)
                   (json.scan-fail I "expected digits")))

(define json.scan-number
  Data I End ->
    (let First (if (= (json.scan-byte Data I End) 45) (+ I 1) I)
         B (json.scan-byte Data First End)
         IntEnd (cond ((= B 48) (+ First 1))
                      ((and (>= B 49) (<= B 57)) (json.scan-digits Data (+ First 1) End))
                      (true (json.scan-fail First "expected integer")))
         FracEnd (if (and (< IntEnd End) (= (shen-jit.u8 Data IntEnd) 46))
                     (json.scan-need-digits Data (+ IntEnd 1) End) IntEnd)
         Stop (if (and (< FracEnd End) (element? (shen-jit.u8 Data FracEnd) [69 101]))
                  (let E (+ FracEnd 1)
                       At (if (and (< E End) (element? (shen-jit.u8 Data E) [43 45])) (+ E 1) E)
                    (json.scan-need-digits Data At End))
                  FracEnd)
      (@p [number (shen-jit.bytes->string Data I (- Stop I))] Stop)))

(define json.scan-literal
  _ I _ [] Value -> (@p Value I)
  Data I End [Byte | Bytes] Value ->
    (if (= (json.scan-byte Data I End) Byte)
        (json.scan-literal Data (+ I 1) End Bytes Value)
        (json.scan-fail I "invalid literal")))

(define json.scan-continuation?
  B -> (and (>= B 128) (<= B 191)))

(define json.scan-utf8-width
  Data I End ->
    (let B (json.scan-byte Data I End)
      (cond ((< B 128) 1)
            ((and (>= B 194) (<= B 223)
                  (json.scan-continuation? (json.scan-byte Data (+ I 1) End))) 2)
            ((and (>= B 224) (<= B 239)
                  (let C (json.scan-byte Data (+ I 1) End)
                    (and (json.scan-continuation? C)
                         (or (not (= B 224)) (>= C 160))
                         (or (not (= B 237)) (< C 160))))
                  (json.scan-continuation? (json.scan-byte Data (+ I 2) End))) 3)
            ((and (>= B 240) (<= B 244)
                  (let C (json.scan-byte Data (+ I 1) End)
                    (and (json.scan-continuation? C)
                         (or (not (= B 240)) (>= C 144))
                         (or (not (= B 244)) (< C 144))))
                  (json.scan-continuation? (json.scan-byte Data (+ I 2) End))
                  (json.scan-continuation? (json.scan-byte Data (+ I 3) End))) 4)
            (true (json.scan-fail I "invalid UTF-8")))))

(define json.scan-quote-end
  Data I End ->
    (let B (json.scan-byte Data I End)
      (cond ((= B 34) I)
            ((= B 92) (do (json.scan-byte Data (+ I 1) End)
                           (json.scan-quote-end Data (+ I 2) End)))
            ((< B 32) (json.scan-fail I "unescaped control byte"))
            (true (json.scan-quote-end Data (+ I (json.scan-utf8-width Data I End)) End)))))

(define json.scan-hex
  B I -> (cond ((and (>= B 48) (<= B 57)) (- B 48))
               ((and (>= B 65) (<= B 70)) (- B 55))
               ((and (>= B 97) (<= B 102)) (- B 87))
               (true (json.scan-fail I "invalid Unicode escape"))))

(define json.scan-hex4
  _ I _ 0 Acc -> Acc
  Data I End N Acc -> (json.scan-hex4 Data (+ I 1) End (- N 1)
                       (+ (* Acc 16) (json.scan-hex (json.scan-byte Data I End) I))))

\\ A JSON scalar always uses UTF-8, including scalars below 256.
(define json.scan-scalar
  Out K N ->
    (cond ((< N 128) (do (shen-jit.u8! Out K N) (+ K 1)))
          ((< N 2048)
            (do (shen-jit.u8! Out K (+ 192 (shen-jit.shift-right N 6)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and N 63))) (+ K 2)))
          ((< N 65536)
            (do (shen-jit.u8! Out K (+ 224 (shen-jit.shift-right N 12)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 6) 63)))
                (shen-jit.u8! Out (+ K 2) (+ 128 (shen-jit.bit-and N 63))) (+ K 3)))
          (true
            (do (shen-jit.u8! Out K (+ 240 (shen-jit.shift-right N 18)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 12) 63)))
                (shen-jit.u8! Out (+ K 2) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 6) 63)))
                (shen-jit.u8! Out (+ K 3) (+ 128 (shen-jit.bit-and N 63))) (+ K 4)))))

(define json.scan-unicode
  Data I Stop Out K ->
    (let N (json.scan-hex4 Data (+ I 2) Stop 4 0)
      (cond ((and (>= N 55296) (<= N 56319))
              (if (and (< (+ I 7) Stop) (= (shen-jit.u8 Data (+ I 6)) 92)
                       (= (shen-jit.u8 Data (+ I 7)) 117))
                  (let Low (json.scan-hex4 Data (+ I 8) Stop 4 0)
                    (if (and (>= Low 56320) (<= Low 57343))
                        (json.scan-decode Data (+ I 12) Stop Out
                          (json.scan-scalar Out K (+ 65536 (+ (* (- N 55296) 1024) (- Low 56320)))))
                        (json.scan-fail I "invalid low surrogate")))
                  (json.scan-fail I "missing low surrogate")))
            ((and (>= N 56320) (<= N 57343)) (json.scan-fail I "unpaired low surrogate"))
            (true (json.scan-decode Data (+ I 6) Stop Out (json.scan-scalar Out K N))))))

(define json.scan-decode
  _ I I _ K -> K
  Data I Stop Out K ->
    (let B (shen-jit.u8 Data I)
      (if (= B 92)
          (let E (json.scan-byte Data (+ I 1) Stop)
            (if (= E 117)
                (json.scan-unicode Data I Stop Out K)
                (let Byte (cond ((element? E [34 47 92]) E)
                                 ((= E 98) 8) ((= E 102) 12) ((= E 110) 10)
                                 ((= E 114) 13) ((= E 116) 9)
                                 (true (json.scan-fail I "invalid escape")))
                  (do (shen-jit.u8! Out K Byte)
                      (json.scan-decode Data (+ I 2) Stop Out (+ K 1))))))
          (let Width (json.scan-utf8-width Data I Stop)
            (do (shen-jit.copy-bytes Out K Data I Width)
                (json.scan-decode Data (+ I Width) Stop Out (+ K Width)))))))

(define json.scan-string
  Data I End -> (let Start (+ I 1) Stop (json.scan-quote-end Data Start End)
                    Out (shen-jit.bytes (- Stop Start))
                    N (json.scan-decode Data Start Stop Out 0)
                 (@p (shen-jit.bytes->string Out 0 N) (+ Stop 1))))

(define json.scan-array
  Data I End Depth DepthLimit Acc ->
    (let Parsed (json.scan-value Data I End Depth DepthLimit)
         At (json.scan-space Data (snd Parsed) End)
         B (json.scan-byte Data At End) Next [(fst Parsed) | Acc]
      (cond ((= B 93) (@p (reverse Next) (+ At 1)))
            ((= B 44) (json.scan-array Data (+ At 1) End Depth DepthLimit Next))
            (true (json.scan-fail At "expected comma or closing bracket")))))

(define json.scan-object
  Data I End Depth DepthLimit Seen Acc ->
    (let At (json.scan-space Data I End)
         _ (if (= (json.scan-byte Data At End) 34) true (json.scan-fail At "expected object key"))
         Key (json.scan-string Data At End)
         _ (if (trap-error (shen.<-dict Seen (fst Key)) (/. E false))
               (json.scan-fail At "duplicate object key") true)
         _ (shen.dict-> Seen (fst Key) true)
         Colon (json.scan-space Data (snd Key) End)
         _ (if (= (json.scan-byte Data Colon End) 58) true (json.scan-fail Colon "expected colon"))
         Val (json.scan-value Data (+ Colon 1) End Depth DepthLimit)
         NextAt (json.scan-space Data (snd Val) End)
         B (json.scan-byte Data NextAt End) Next [[(fst Key) (fst Val)] | Acc]
      (cond ((= B 125) (@p [object | (reverse Next)] (+ NextAt 1)))
            ((= B 44) (json.scan-object Data (+ NextAt 1) End Depth DepthLimit Seen Next))
            (true (json.scan-fail NextAt "expected comma or closing brace")))))

(define json.scan-value
  Data I End Depth DepthLimit ->
    (let At (json.scan-space Data I End) B (json.scan-byte Data At End)
         _ (if (and (element? B [91 123]) (>= Depth DepthLimit))
               (json.scan-fail At "nesting limit") true)
      (cond ((= B 34) (json.scan-string Data At End))
            ((= B 110) (json.scan-literal Data At End [110 117 108 108] null))
            ((= B 116) (json.scan-literal Data At End [116 114 117 101] true))
            ((= B 102) (json.scan-literal Data At End [102 97 108 115 101] false))
            ((or (= B 45) (json.scan-digit? B)) (json.scan-number Data At End))
            ((= B 91)
              (let Next (json.scan-space Data (+ At 1) End)
                (if (= (json.scan-byte Data Next End) 93) (@p [] (+ Next 1))
                    (json.scan-array Data Next End (+ Depth 1) DepthLimit []))))
            ((= B 123)
              (let Next (json.scan-space Data (+ At 1) End)
                (if (= (json.scan-byte Data Next End) 125) (@p [object] (+ Next 1))
                    (json.scan-object Data Next End (+ Depth 1) DepthLimit (shen.dict 8) []))))
            (true (json.scan-fail At "expected value")))))

(define json.decode-view
  View DepthLimit -> (let Data (buffer.owner View) Start (buffer.offset View) End (buffer.end View)
               Parsed (json.scan-value Data Start End 0 DepthLimit)
               At (json.scan-space Data (snd Parsed) End)
            (if (= At End) (fst Parsed) (json.scan-fail At "trailing input"))))


(define json.options
  Options -> (json.configure Options 1048576 128 []))

(define json.configure
  [] Bytes Depth _ -> (@p Bytes Depth)
  [[Name Value] | Rest] Bytes Depth Seen ->
    (let _ (if (element? Name Seen) (error "json: duplicate option") true)
         N (buffer.index Value)
      (cases (= Name byte-limit) (json.configure Rest N Depth [Name | Seen])
             (= Name depth-limit)
               (if (<= N 256) (json.configure Rest Bytes N [Name | Seen])
                   (error "json: depth limit must be 0..256"))
             true (error "json: unknown option")))
  _ _ _ _ -> (error "json: options must be [Name Number] pairs"))

(define json.decode
  View Options ->
    (let Limits (json.options Options)
         _ (if (<= (buffer.length View) (fst Limits)) true (error "json: input exceeds byte limit"))
      (json.decode-view View (snd Limits))))

(define json.parse
  Text Options -> (json.decode (buffer.from-string Text) Options))

(define json.number
  Token ->
    (let B (shen-jit.string->bytes Token)
         N (shen-jit.bytes-length B)
         Parsed (json.scan-number B 0 N)
      (if (= (snd Parsed) N) (fst Parsed) (error "json: invalid number token"))))

(define json.integer
  [number Token] ->
    (let _ (json.number Token)
         B (shen-jit.string->bytes Token)
         N (shen-jit.bytes-length B)
         Negative (= (shen-jit.u8 B 0) 45)
         Value (json.integer-digits B (if Negative 1 0) N 0 (if Negative 2 1))
      (if Negative Value (- 0 Value)))
  N -> (shen-jit.bit-or N 0) where (number? N)
  _ -> (error "json: expected an integer"))

(define json.integer-digits
  _ At At N _ -> N
  B At End N Last ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (and (>= Digit 0) (<= Digit 9)
               (>= N -230584300921369395)
               (or (> N -230584300921369395) (<= Digit Last)))
          (json.integer-digits B (+ At 1) End (- (* N 10) Digit) Last)
          (error "json: number is not a decimal integer in the fixnum range"))))

(define json.put-text
  Out Text -> (buffer.append! Out (buffer.from-string Text)))

(define json.hex-digit
  N -> (pos "0123456789abcdef" N))

(define json.escape
  34 -> "c#92;c#34;"
  92 -> "c#92;c#92;"
  8 -> "c#92;b"
  9 -> "c#92;t"
  10 -> "c#92;n"
  12 -> "c#92;f"
  13 -> "c#92;r"
  N -> (cn "c#92;u00" (cn (json.hex-digit (shen-jit.shift-right N 4))
                          (json.hex-digit (shen-jit.bit-and N 15)))))

(define json.emit-string
  Out Text ->
    (let B (shen-jit.string->bytes Text)
         _ (buffer.append-byte! Out 34)
      (json.emit-string-run Out B 0 0 (shen-jit.bytes-length B))))

(define json.emit-string-run
  Out B Start End End ->
    (do (buffer.append! Out (buffer.make B Start End)) (buffer.append-byte! Out 34))
  Out B Start At End ->
    (let Byte (shen-jit.u8 B At)
      (if (or (< Byte 32) (= Byte 34) (= Byte 92))
          (do (buffer.append! Out (buffer.make B Start At))
              (json.put-text Out (json.escape Byte))
              (json.emit-string-run Out B (+ At 1) (+ At 1) End))
          (json.emit-string-run Out B Start (+ At (json.scan-utf8-width B At End)) End))))

(define json.container-depth
  Depth Limit -> (if (< Depth Limit) (+ Depth 1) (error "json: nesting limit")))

(define json.emit
  Out null _ _ -> (json.put-text Out "null")
  Out true _ _ -> (json.put-text Out "true")
  Out false _ _ -> (json.put-text Out "false")
  Out Text _ _ -> (json.emit-string Out Text) where (string? Text)
  Out N _ _ -> (json.emit-number Out (str N)) where (number? N)
  Out [number Token] _ _ -> (json.emit-number Out Token)
  Out [object | Members] Depth Limit ->
    (let Next (json.container-depth Depth Limit)
         _ (buffer.append-byte! Out 123)
      (json.emit-members Out Members Next Limit (shen.dict 8) false))
  Out Values Depth Limit ->
    (let Next (json.container-depth Depth Limit)
         _ (buffer.append-byte! Out 91)
      (json.emit-elements Out Values Next Limit false)) where (or (empty? Values) (cons? Values))
  _ _ _ _ -> (error "json: not a JSON value"))

(define json.emit-number
  Out Token -> (do (json.number Token) (json.put-text Out Token)))

(define json.emit-elements
  Out [] _ _ _ -> (buffer.append-byte! Out 93)
  Out [Value | Rest] Depth Limit Comma ->
    (do (if Comma (buffer.append-byte! Out 44) Out)
        (json.emit Out Value Depth Limit)
        (json.emit-elements Out Rest Depth Limit true))
  _ _ _ _ _ -> (error "json: array must be a proper list"))

(define json.emit-members
  Out [] _ _ _ _ -> (buffer.append-byte! Out 125)
  Out [[Key Value] | Rest] Depth Limit Seen Comma ->
    (let _ (if (string? Key) true (error "json: object keys must be strings"))
         _ (if (trap-error (shen.<-dict Seen Key) (/. X false))
               (error "json: duplicate object key") true)
         _ (shen.dict-> Seen Key true)
      (do (if Comma (buffer.append-byte! Out 44) Out)
          (json.emit-string Out Key)
          (buffer.append-byte! Out 58)
          (json.emit Out Value Depth Limit)
          (json.emit-members Out Rest Depth Limit Seen true)))
  _ _ _ _ _ _ -> (error "json: object members must be [Key Value] pairs"))

(define json.encode
  Value Options ->
    (let Limits (json.options Options)
         Out (buffer.builder (fst Limits))
         _ (json.emit Out Value 0 (snd Limits))
      (buffer.finish Out)))

(define json.stringify
  Value Options -> (buffer.string (json.encode Value Options)))

(datatype json-values
  S : string;
  ===========================
  S : json.value;

  N : number;
  ===========================
  N : json.value;

  ___________________________
  null : json.value;

  ___________________________
  true : json.value;

  ___________________________
  false : json.value;

  Token : string;
  ===========================
  [number Token] : json.value;

  Values : (list json.value);
  ===========================
  Values : json.value;

  Key : string; Value : json.value;
  ===========================
  [Key Value] : json.member;

  Members : (list json.member);
  ===========================
  [object | Members] : json.value;)

(datatype json-options
  N : number;
  ===========================
  [byte-limit N] : json.option;

  N : number;
  ===========================
  [depth-limit N] : json.option;)

(declare json.decode [buffer.view --> [[list json.option] --> json.value]])
(declare json.parse [string --> [[list json.option] --> json.value]])
(declare json.number [string --> json.value])
(declare json.integer [json.value --> number])
(declare json.encode [json.value --> [[list json.option] --> buffer.view]])
(declare json.stringify [json.value --> [[list json.option] --> string]])
