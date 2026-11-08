\\ Checked byte views over managed bytes or a sized pointer. No FFI library is needed.
\\ A view borrows the exact storage object; it never copies a pointer or releases storage.
\\ Closing that original pointer makes subsequent view operations raise. Independently
\\ copied pointers and closing storage during a native call remain the caller's responsibility.
\\ Load under (tc -); public declarations below support typed clients.

(define buffer.index
  N -> (let I (shen-jit.bit-or N 0)
         (if (>= I 0) I (error "buffer: ~S is not a nonnegative index" N))))

(define buffer.range
  Length Start Count ->
    (let I (buffer.index Start) N (buffer.index Count)
      (if (and (<= I Length) (<= N (- Length I)))
          I
          (error "buffer: range ~A + ~A exceeds ~A bytes" I N Length))))

(define buffer.storage-length
  Storage -> (if (and (shen-jit.pointer? Storage)
                     (= (shen-jit.pointer-address Storage) 0))
                 (error "buffer: storage is closed")
                 (shen-jit.bytes-length Storage)))

(define buffer.view?
  V -> (trap-error (and (absvector? V) (= (<-address V 0) buffer.view))
                   (/. E false)))

\\ Private layout: tag, original owner, start, exclusive end. Metadata is not mutated.
(define buffer.make
  Storage Start End -> (address-> (address-> (address-> (address-> (absvector 4)
                                  0 buffer.view) 1 Storage) 2 Start) 3 End))

(define buffer.check
  V -> (if (buffer.view? V)
           (if (<= (<-address V 3) (buffer.storage-length (<-address V 1)))
               V
               (error "buffer: backing storage is shorter than the view"))
           (error "buffer: ~S is not a view" V)))

(define buffer.wrap
  Storage -> (buffer.make Storage 0 (buffer.storage-length Storage)))

(define buffer.new
  N -> (buffer.wrap (shen-jit.bytes (buffer.index N))))

(define buffer.from-string
  Text -> (buffer.wrap (shen-jit.string->bytes Text)))

(define buffer.owner
  V -> (<-address (buffer.check V) 1))

(define buffer.offset
  V -> (<-address (buffer.check V) 2))

(define buffer.end
  V -> (<-address (buffer.check V) 3))

(define buffer.length
  V -> (let Checked (buffer.check V) (- (<-address Checked 3) (<-address Checked 2))))

(define buffer.slice
  V Start Count ->
    (let Checked (buffer.check V)
         Begin (<-address Checked 2)
         I (buffer.range (- (<-address Checked 3) Begin) Start Count)
         At (+ Begin I)
      (buffer.make (<-address Checked 1) At (+ At Count))))

(define buffer.u8
  V I -> (let Checked (buffer.check V) Start (<-address Checked 2)
              At (buffer.range (- (<-address Checked 3) Start) I 1)
           (shen-jit.u8 (<-address Checked 1) (+ Start At))))

(define buffer.u8!
  V I Byte -> (let Checked (buffer.check V) Start (<-address Checked 2)
                   At (buffer.range (- (<-address Checked 3) Start) I 1)
                (do (shen-jit.u8! (<-address Checked 1) (+ Start At) Byte) V)))

(define buffer.bytes
  V -> (let Checked (buffer.check V) Start (<-address Checked 2)
            N (- (<-address Checked 3) Start) Out (shen-jit.bytes N)
         (shen-jit.copy-bytes Out 0 (<-address Checked 1) Start N)))

(define buffer.string
  V -> (let Checked (buffer.check V) Start (<-address Checked 2)
         (shen-jit.bytes->string (<-address Checked 1) Start (- (<-address Checked 3) Start))))

(define buffer.copy!
  To I From J Count ->
    (let T (buffer.check To) F (buffer.check From)
         TStart (<-address T 2) FStart (<-address F 2)
         TI (buffer.range (- (<-address T 3) TStart) I Count)
         FJ (buffer.range (- (<-address F 3) FStart) J Count)
      (do (shen-jit.copy-bytes (<-address T 1) (+ TStart TI)
                              (<-address F 1) (+ FStart FJ) Count)
          To)))

\\ Flat inner loop: do not reload view records for every byte.
(define buffer.equal-range?
  _ _ _ _ 0 -> true
  A I B J N -> (and (= (shen-jit.u8 A I) (shen-jit.u8 B J))
                    (buffer.equal-range? A (+ I 1) B (+ J 1) (- N 1))))

(define buffer.equal?
  A B -> (let X (buffer.check A) Y (buffer.check B)
              I (<-address X 2) J (<-address Y 2)
              N (- (<-address X 3) I)
           (and (= N (- (<-address Y 3) J))
                (buffer.equal-range? (<-address X 1) I (<-address Y 1) J N))))

\\ A single-owner builder grows geometrically under an explicit byte limit.
\\ Finish transfers its managed storage to a view and seals the builder.
(define buffer.builder
  Limit ->
    (let N (buffer.index Limit)
         B (absvector 5)
      (do (address-> B 0 buffer.builder-state) (address-> B 1 N)
          (address-> B 2 (buffer.new 0)) (address-> B 3 0) (address-> B 4 false) B)))

(define buffer.builder-check
  B ->
    (if (trap-error (and (absvector? B) (= (<-address B 0) buffer.builder-state) (not (<-address B 4)))
          (/. X false))
        B (error "buffer: not an open builder")))

(define buffer.builder-length
  B -> (<-address (buffer.builder-check B) 3))

(define buffer.builder-reserve
  B Need ->
    (let Old (<-address B 2)
         Cap (buffer.length Old)
      (if (<= Need Cap)
          Old
          (let Limit (<-address B 1)
               Grow (if (= Cap 0) (if (< Limit 256) Limit 256)
                        (+ Cap (if (< Cap (- Limit Cap)) Cap (- Limit Cap))))
               Next (buffer.new (if (> Need Grow) Need Grow))
               _ (buffer.copy! Next 0 Old 0 (<-address B 3))
            (do (address-> B 2 Next) Next)))))

(define buffer.append!
  B V ->
    (let _ (buffer.builder-check B)
         N (buffer.length V)
         At (<-address B 3)
         _ (if (<= N (- (<-address B 1) At)) true (error "buffer: builder exceeds byte limit"))
         End (+ At N)
         Out (buffer.builder-reserve B End)
         _ (buffer.copy! Out At V 0 N)
      (do (address-> B 3 End) B)))

(define buffer.append-byte!
  B Byte ->
    (let _ (buffer.builder-check B)
         Value (shen-jit.bit-or Byte 0)
         _ (if (and (>= Value 0) (<= Value 255)) true (error "buffer: invalid byte"))
         At (<-address B 3)
         _ (if (< At (<-address B 1)) true (error "buffer: builder exceeds byte limit"))
         Out (buffer.builder-reserve B (+ At 1))
         _ (buffer.u8! Out At Value)
      (do (address-> B 3 (+ At 1)) B)))

(define buffer.finish
  B ->
    (let _ (buffer.builder-check B)
         Out (buffer.slice (<-address B 2) 0 (<-address B 3))
      (do (address-> B 4 true) (address-> B 2 []) Out)))

(declare buffer.view? [A --> boolean])
(declare buffer.new [number --> buffer.view])
(declare buffer.wrap [buffer.storage --> buffer.view])
(declare buffer.from-string [string --> buffer.view])
(declare buffer.slice [buffer.view --> [number --> [number --> buffer.view]]])
(declare buffer.owner [buffer.view --> buffer.storage])
(declare buffer.offset [buffer.view --> number])
(declare buffer.end [buffer.view --> number])
(declare buffer.length [buffer.view --> number])
(declare buffer.u8 [buffer.view --> [number --> number]])
(declare buffer.u8! [buffer.view --> [number --> [number --> buffer.view]]])
(declare buffer.bytes [buffer.view --> buffer.storage])
(declare buffer.string [buffer.view --> string])
(declare buffer.copy! [buffer.view --> [number --> [buffer.view --> [number --> [number --> buffer.view]]]]])
(declare buffer.equal? [buffer.view --> [buffer.view --> boolean]])
(declare buffer.builder [number --> buffer.builder])
(declare buffer.builder-length [buffer.builder --> number])
(declare buffer.append! [buffer.builder --> [buffer.view --> buffer.builder]])
(declare buffer.append-byte! [buffer.builder --> [number --> buffer.builder]])
(declare buffer.finish [buffer.builder --> buffer.view])
