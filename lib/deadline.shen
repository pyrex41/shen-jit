\\ Absolute operation budgets in integer milliseconds, with an injectable frozen clock.
\\ No FFI is needed here. Load buffer.shen and io.shen first; clock.shen supplies a system clock.

(define deadline.after
  Clock Milliseconds ->
    (let Duration (buffer.index Milliseconds)
         Now (buffer.index (thaw Clock))
         End (+ Now Duration)
         Guard (shen-jit.bytes->pointer (shen-jit.u32! (shen-jit.bytes 8) 0 1) 0 deadline)
      (io.record [deadline Clock End Now Guard])))

(define deadline.check
  D ->
    (let _ (if (io.tag? D deadline) true (error "deadline: not a deadline"))
         _ (if (= (shen-jit.pointer-address (<-address D 4)) 0)
               (error "deadline: saved budgets must be recreated")
               true)
      D))

(define deadline.remaining
  D ->
    (let _ (deadline.check D)
         Clock (<-address D 1)
         Now (buffer.index (thaw Clock))
         _ (if (< Now (<-address D 3)) (error "deadline: clock moved backwards") true)
         _ (address-> D 3 Now)
         Left (- (<-address D 2) Now)
      (if (> Left 0) Left 0)))

(define deadline.expired?
  D -> (= (deadline.remaining D) 0))

(define deadline.slice
  D Maximum ->
    (let Max (buffer.index Maximum)
         _ (if (> Max 0) true (error "deadline: slice must be positive"))
         Left (deadline.remaining D)
      (if (< Left Max) Left Max)))

(declare deadline.after [[lazy number] --> [number --> deadline]])
(declare deadline.remaining [deadline --> number])
(declare deadline.expired? [deadline --> boolean])
(declare deadline.slice [deadline --> [number --> number]])
