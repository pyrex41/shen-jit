\\ Complete-input JSON and a binary frame, exercising lib/buffer.shen and lib/cursor.shen.
\\ JSON numbers are deliberately lossless [number Token] values, not rounded Shen reals.
\\ Arrays are lists, objects [object [Key Value] ...], and duplicate keys raise.
\\ Scanners use flat storage/index/end arguments. Errors name offsets in the backing owner.
\\ These readers have no stream or kernel-I/O dependency.

(define buffer-json.fail
  I What -> (error "JSON byte ~A: ~A" I What))

(define buffer-json.byte
  Data I End -> (if (< I End) (shen-jit.u8 Data I) (buffer-json.fail I "unexpected end")))

(define buffer-json.space
  Data I End -> I where (>= I End)
  Data I End -> (let B (shen-jit.u8 Data I)
                  (if (element? B [32 9 10 13]) (buffer-json.space Data (+ I 1) End) I)))

(define buffer-json.digit?
  B -> (and (>= B 48) (<= B 57)))

(define buffer-json.digits
  Data I End -> I where (>= I End)
  Data I End -> (if (buffer-json.digit? (shen-jit.u8 Data I))
                   (buffer-json.digits Data (+ I 1) End) I))

(define buffer-json.need-digits
  Data I End -> (if (buffer-json.digit? (buffer-json.byte Data I End))
                   (buffer-json.digits Data (+ I 1) End)
                   (buffer-json.fail I "expected digits")))

(define buffer-json.number
  Data I End ->
    (let First (if (= (buffer-json.byte Data I End) 45) (+ I 1) I)
         B (buffer-json.byte Data First End)
         IntEnd (cond ((= B 48) (+ First 1))
                      ((and (>= B 49) (<= B 57)) (buffer-json.digits Data (+ First 1) End))
                      (true (buffer-json.fail First "expected integer")))
         FracEnd (if (and (< IntEnd End) (= (shen-jit.u8 Data IntEnd) 46))
                     (buffer-json.need-digits Data (+ IntEnd 1) End) IntEnd)
         Stop (if (and (< FracEnd End) (element? (shen-jit.u8 Data FracEnd) [69 101]))
                  (let E (+ FracEnd 1)
                       At (if (and (< E End) (element? (shen-jit.u8 Data E) [43 45])) (+ E 1) E)
                    (buffer-json.need-digits Data At End))
                  FracEnd)
      (@p [number (shen-jit.bytes->string Data I (- Stop I))] Stop)))

(define buffer-json.literal
  _ I _ "" Value -> (@p Value I)
  Data I End Text Value ->
    (if (= (buffer-json.byte Data I End) (string->n (pos Text 0)))
        (buffer-json.literal Data (+ I 1) End (tlstr Text) Value)
        (buffer-json.fail I "invalid literal")))

(define buffer-json.continuation?
  B -> (and (>= B 128) (<= B 191)))

(define buffer-json.utf8-width
  Data I End ->
    (let B (buffer-json.byte Data I End)
      (cond ((< B 128) 1)
            ((and (>= B 194) (<= B 223)
                  (buffer-json.continuation? (buffer-json.byte Data (+ I 1) End))) 2)
            ((and (>= B 224) (<= B 239)
                  (let C (buffer-json.byte Data (+ I 1) End)
                    (and (buffer-json.continuation? C)
                         (or (not (= B 224)) (>= C 160))
                         (or (not (= B 237)) (< C 160))))
                  (buffer-json.continuation? (buffer-json.byte Data (+ I 2) End))) 3)
            ((and (>= B 240) (<= B 244)
                  (let C (buffer-json.byte Data (+ I 1) End)
                    (and (buffer-json.continuation? C)
                         (or (not (= B 240)) (>= C 144))
                         (or (not (= B 244)) (< C 144))))
                  (buffer-json.continuation? (buffer-json.byte Data (+ I 2) End))
                  (buffer-json.continuation? (buffer-json.byte Data (+ I 3) End))) 4)
            (true (buffer-json.fail I "invalid UTF-8")))))

(define buffer-json.quote-end
  Data I End ->
    (let B (buffer-json.byte Data I End)
      (cond ((= B 34) I)
            ((= B 92) (do (buffer-json.byte Data (+ I 1) End)
                           (buffer-json.quote-end Data (+ I 2) End)))
            ((< B 32) (buffer-json.fail I "unescaped control byte"))
            (true (buffer-json.quote-end Data (+ I (buffer-json.utf8-width Data I End)) End)))))

(define buffer-json.hex
  B I -> (cond ((and (>= B 48) (<= B 57)) (- B 48))
               ((and (>= B 65) (<= B 70)) (- B 55))
               ((and (>= B 97) (<= B 102)) (- B 87))
               (true (buffer-json.fail I "invalid Unicode escape"))))

(define buffer-json.hex4
  _ I _ 0 Acc -> Acc
  Data I End N Acc -> (buffer-json.hex4 Data (+ I 1) End (- N 1)
                       (+ (* Acc 16) (buffer-json.hex (buffer-json.byte Data I End) I))))

\\ A JSON scalar always uses UTF-8, including scalars below 256.
(define buffer-json.scalar
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

(define buffer-json.unicode
  Data I Stop Out K ->
    (let N (buffer-json.hex4 Data (+ I 2) Stop 4 0)
      (cond ((and (>= N 55296) (<= N 56319))
              (if (and (< (+ I 7) Stop) (= (shen-jit.u8 Data (+ I 6)) 92)
                       (= (shen-jit.u8 Data (+ I 7)) 117))
                  (let Low (buffer-json.hex4 Data (+ I 8) Stop 4 0)
                    (if (and (>= Low 56320) (<= Low 57343))
                        (buffer-json.decode Data (+ I 12) Stop Out
                          (buffer-json.scalar Out K (+ 65536 (+ (* (- N 55296) 1024) (- Low 56320)))))
                        (buffer-json.fail I "invalid low surrogate")))
                  (buffer-json.fail I "missing low surrogate")))
            ((and (>= N 56320) (<= N 57343)) (buffer-json.fail I "unpaired low surrogate"))
            (true (buffer-json.decode Data (+ I 6) Stop Out (buffer-json.scalar Out K N))))))

(define buffer-json.decode
  _ I I _ K -> K
  Data I Stop Out K ->
    (let B (shen-jit.u8 Data I)
      (if (= B 92)
          (let E (buffer-json.byte Data (+ I 1) Stop)
            (if (= E 117)
                (buffer-json.unicode Data I Stop Out K)
                (let Byte (cond ((element? E [34 47 92]) E)
                                 ((= E 98) 8) ((= E 102) 12) ((= E 110) 10)
                                 ((= E 114) 13) ((= E 116) 9)
                                 (true (buffer-json.fail I "invalid escape")))
                  (do (shen-jit.u8! Out K Byte)
                      (buffer-json.decode Data (+ I 2) Stop Out (+ K 1))))))
          (let Width (buffer-json.utf8-width Data I Stop)
            (do (shen-jit.copy-bytes Out K Data I Width)
                (buffer-json.decode Data (+ I Width) Stop Out (+ K Width)))))))

(define buffer-json.string
  Data I End -> (let Start (+ I 1) Stop (buffer-json.quote-end Data Start End)
                    Out (shen-jit.bytes (- Stop Start))
                    N (buffer-json.decode Data Start Stop Out 0)
                 (@p (shen-jit.bytes->string Out 0 N) (+ Stop 1))))

(define buffer-json.array
  Data I End Depth Acc ->
    (let Parsed (buffer-json.value Data I End Depth)
         At (buffer-json.space Data (snd Parsed) End)
         B (buffer-json.byte Data At End) Next [(fst Parsed) | Acc]
      (cond ((= B 93) (@p (reverse Next) (+ At 1)))
            ((= B 44) (buffer-json.array Data (+ At 1) End Depth Next))
            (true (buffer-json.fail At "expected comma or closing bracket")))))

(define buffer-json.object
  Data I End Depth Seen Acc ->
    (let At (buffer-json.space Data I End)
         _ (if (= (buffer-json.byte Data At End) 34) true (buffer-json.fail At "expected object key"))
         Key (buffer-json.string Data At End)
         _ (if (trap-error (shen.<-dict Seen (fst Key)) (/. E false))
               (buffer-json.fail At "duplicate object key") true)
         _ (shen.dict-> Seen (fst Key) true)
         Colon (buffer-json.space Data (snd Key) End)
         _ (if (= (buffer-json.byte Data Colon End) 58) true (buffer-json.fail Colon "expected colon"))
         Val (buffer-json.value Data (+ Colon 1) End Depth)
         NextAt (buffer-json.space Data (snd Val) End)
         B (buffer-json.byte Data NextAt End) Next [[(fst Key) (fst Val)] | Acc]
      (cond ((= B 125) (@p [object | (reverse Next)] (+ NextAt 1)))
            ((= B 44) (buffer-json.object Data (+ NextAt 1) End Depth Seen Next))
            (true (buffer-json.fail NextAt "expected comma or closing brace")))))

(define buffer-json.value
  Data I End Depth ->
    (let At (buffer-json.space Data I End) B (buffer-json.byte Data At End)
         _ (if (and (element? B [91 123]) (>= Depth 128))
               (buffer-json.fail At "nesting limit") true)
      (cond ((= B 34) (buffer-json.string Data At End))
            ((= B 110) (buffer-json.literal Data At End "null" null))
            ((= B 116) (buffer-json.literal Data At End "true" true))
            ((= B 102) (buffer-json.literal Data At End "false" false))
            ((or (= B 45) (buffer-json.digit? B)) (buffer-json.number Data At End))
            ((= B 91)
              (let Next (buffer-json.space Data (+ At 1) End)
                (if (= (buffer-json.byte Data Next End) 93) (@p [] (+ Next 1))
                    (buffer-json.array Data Next End (+ Depth 1) []))))
            ((= B 123)
              (let Next (buffer-json.space Data (+ At 1) End)
                (if (= (buffer-json.byte Data Next End) 125) (@p [object] (+ Next 1))
                    (buffer-json.object Data Next End (+ Depth 1) (shen.dict 8) []))))
            (true (buffer-json.fail At "expected value")))))

(define buffer-example.json
  View -> (let Data (buffer.owner View) Start (buffer.offset View) End (buffer.end View)
               Parsed (buffer-json.value Data Start End 0)
               At (buffer-json.space Data (snd Parsed) End)
            (if (= At End) (fst Parsed) (buffer-json.fail At "trailing input"))))

(define buffer-example.uint
  _ 0 Acc -> Acc
  C N Acc -> (buffer-example.uint C (- N 1) (+ (* Acc 256) (cursor.read C))))

(define buffer-example.packet
  View Limit ->
    (let C (cursor.new View) _ (buffer.index Limit)
         _ (if (< (cursor.remaining C) 6) (error "packet: incomplete header") true)
         Tag (buffer-example.uint C 2 0) N (buffer-example.uint C 4 0)
         _ (if (> N Limit) (error "packet: payload exceeds limit") true)
         _ (if (= N (cursor.remaining C)) true (error "packet: payload length mismatch"))
      [packet Tag (cursor.bytes C N)]))
