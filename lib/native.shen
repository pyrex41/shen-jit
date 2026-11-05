\\ Native code written by hand: a Shen program builds a procedure from the
\\ instructions of docs/bytecode.md, checked before the JIT sees them. It stays out of
\\ the image until asked for; load this file under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/native.shen -l program.shen
\\
\\ (define-native sum-list (Xs Acc)
\\   (prim T cons? Xs)
\\   (jump-if-false T done)
\\   (prim H hd Xs)
\\   (prim Acc + Acc H)
\\   (prim Xs tl Xs)
\\   (tail-call sum-list Xs Acc)
\\   (label done)
\\   (return Acc))
\\
\\ Names follow Shen: a variable is a slot, a symbol is itself, and anything else
\\ is a constant, so [1 2] is a list. (const E) is the value of E, at definition.
\\ See docs/bytecode.md, "Native code written by hand".
\\
\\ Real registers hold doubles, unboxed, in code that calls nothing and catches nothing:
\\
\\ (define-native dot (A B I End Start)
\\   (real Acc Start)
\\   (loop)
\\   (prim T >= I End)
\\   (jump-if-false T more)
\\   (return-real Acc)
\\   (label more)
\\   (real Acc (+ Acc (* (f64 A I) (f64 B I))))
\\   (prim I + I 8)
\\   (tail-call dot A B I End Start))
\\
\\ Code a program generates is data, lists and not forms: (shen-jit.assemble Name
\\ Params Body) gives the code object for instructions in the same shape, and
\\ (shen-jit.install-code Form) checks and installs one. shen-jit.install, which
\\ eval-kl uses, checks only operand shapes: wrong code given to it can crash.
\\
\\ src/lowerer/check.shen loads this file for the rules, to hold the lowerer's
\\ output to them too, and defines its own versions of the next five functions.

(define shen-jit.check.fail
  Where Message X -> (simple-error (make-string "native code, ~A: ~A: ~R" Where Message X)))

\\ A constant may be any value: the collector sees the constants.
(define shen-jit.check.literal?
  _ -> true)

(define shen-jit.check.sealed?
  F _ -> (shen-jit.sealed? F))

(define shen-jit.check.open?
  F -> (and (shen-jit.symbol? F) (not (shen-jit.lower.fixed? F))))

\\ On entry with N arguments: slot 1 and the parameters are set.
(define shen-jit.check.entry-state
  N -> (let Params (shen-jit.check.range 2 (+ N 1))
         [[1 | Params] | []]))

(define shen-jit.check.assert
  true _ _ _ -> true
  false Where Message X -> (shen-jit.check.fail Where Message X))

\\ ---------------------------------------------------------------------------
\\ Structural checks. Ctx is [Where Arity Frame NConstants NCodes NCaptures].

(define shen-jit.check.code
  Where [code Name Arity Frame Constants Instructions Codes | _] NCaptures Kind
  -> (let Ctx [Where Arity Frame (length Constants) (length Codes) NCaptures]
          Labels (shen-jit.check.labels Instructions)
          Handlers (mapcan (/. I (shen-jit.check.handler-target I)) Instructions)
       (do (shen-jit.check.header Where Name Arity Frame Kind)
           (map (/. K (shen-jit.check.assert (shen-jit.check.literal? K) Where
                                               "constant is not a literal" K))
                Constants)
           (shen-jit.check.assert (shen-jit.check.distinct? Labels) Where
                                    "label defined twice" Labels)
           (map (/. I (shen-jit.check.instruction Ctx Labels I)) Instructions)
           (shen-jit.check.handlers Where none Instructions Handlers)
           (shen-jit.check.reals Where Instructions)
           (shen-jit.check.flow Where Arity Instructions (+ 1 (shen-jit.check.max Labels -1)))
           (shen-jit.check.nested Where Instructions Codes)))
  Where X _ _ -> (shen-jit.check.fail Where "malformed code object" X))

(define shen-jit.check.header
  Where Name Arity Frame Kind
  -> (shen-jit.check.assert
       (and (integer? Arity) (>= Arity 0) (integer? Frame) (>= Frame (+ Arity 2))
            (cond ((= Kind top) (and (symbol? Name) (not (element? Name [lambda freeze]))))
                  ((= Name lambda) (= Arity 1))
                  ((= Name freeze) (= Arity 0))
                  (true false)))
       Where "bad code header" [Name Arity Frame Kind]))

(define shen-jit.check.labels
  Instructions -> (mapcan (/. I (if (= (hd I) label) (tl I) [])) Instructions))

(define shen-jit.check.handler-target
  [push-handler L] -> [L]
  _ -> [])

(define shen-jit.check.distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (shen-jit.check.distinct? Xs)))

(define shen-jit.check.max
  [] M -> M
  [X | Xs] M -> (shen-jit.check.max Xs (if (> X M) X M)))

(define shen-jit.check.prim-arity
  raise-cond -> 0
  F -> (shen-jit.lower.prim-arity F))

(define shen-jit.check.instruction
  Ctx Labels I -> (shen-jit.check.assert (shen-jit.check.valid? Ctx Labels I)
                                           (hd Ctx) "bad instruction" I))

(define shen-jit.check.valid?
  Ctx _ [move D S] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.read? Ctx S))
  Ctx _ [const D K] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.below? K (nth 4 Ctx)))
  Ctx _ [capture D I] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.below? I (nth 6 Ctx)))
  Ctx _ [closure D C | Ss] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.below? C (nth 5 Ctx))
                                   (shen-jit.check.reads? Ctx Ss))
  Ctx _ [prim D Op | Ss] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.operands? Ctx Ss)
                                 (= (length Ss) (shen-jit.check.prim-arity Op)))
  _ _ [label L] -> (integer? L)
  _ Labels [jump L] -> (element? L Labels)
  Ctx Labels [jump-if-false S L] -> (and (shen-jit.check.operand? Ctx S) (element? L Labels))
  Ctx _ [call D A F N] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.window? Ctx A N)
                               (shen-jit.check.open? F))
  Ctx _ [call-sealed D A F N] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.window? Ctx A N)
                                      (shen-jit.check.sealed? F N))
  Ctx _ [call-value D A N] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.window? Ctx A N))
  Ctx _ [tail-call A F N] -> (and (shen-jit.check.tail-window? Ctx A N) (shen-jit.check.open? F))
  Ctx _ [tail-call-sealed A F N] -> (and (shen-jit.check.tail-window? Ctx A N) (shen-jit.check.sealed? F N))
  Ctx _ [tail-call-value A N] -> (shen-jit.check.window? Ctx A N)
  [_ Arity Frame | _] Labels [entry N L] -> (and (integer? N) (> N Arity) (< (+ N 1) Frame)
                                                 (element? L Labels))
  Ctx Labels [jump-unless-entry S N L] -> (and (shen-jit.check.read? Ctx S) (integer? N) (>= N 2)
                                               (element? L Labels))
  Ctx _ [return S] -> (shen-jit.check.operand? Ctx S)
  _ Labels [push-handler L] -> (element? L Labels)
  _ _ [pop-handler] -> true
  _ _ [inline F N] -> (and (symbol? F) (integer? N) (> N 0))
  Ctx _ [exception D] -> (shen-jit.check.write? Ctx D)
  _ _ [loop] -> true
  Ctx _ [real-number F O] -> (and (shen-jit.check.real? F) (shen-jit.check.operand? Ctx O))
  Ctx _ [real-box D F] -> (and (shen-jit.check.write? Ctx D) (shen-jit.check.real? F))
  Ctx _ [real-load F M I] -> (and (shen-jit.check.real? F) (shen-jit.check.operands? Ctx [M I]))
  Ctx _ [real-store M I F] -> (and (shen-jit.check.real? F) (shen-jit.check.operands? Ctx [M I]))
  _ _ [Op D A] -> (and (shen-jit.check.real? D) (shen-jit.check.real? A))
      where (element? Op (shen-jit.check.real-unary))
  _ _ [Op D A B] -> (and (shen-jit.check.real? D) (shen-jit.check.real? A) (shen-jit.check.real? B))
      where (element? Op (shen-jit.check.real-binary))
  _ Labels [Op A B L] -> (and (shen-jit.check.real? A) (shen-jit.check.real? B) (element? L Labels))
      where (element? Op (shen-jit.check.real-tests))
  _ _ _ -> false)

\\ As REAL_REGISTERS in ops.h.
(define shen-jit.check.real?
  F -> (shen-jit.check.below? F 12))

(define shen-jit.check.real-unary
  -> [real-move real-neg real-abs real-sqrt])

(define shen-jit.check.real-binary
  -> [real+ real- real* real/])

(define shen-jit.check.real-tests
  -> [real-unless< real-unless> real-unless<= real-unless>= real-unless=])

(define shen-jit.check.real-op?
  [Op | _] -> (or (element? Op [loop real-number real-box real-load real-store])
                  (element? Op (shen-jit.check.real-unary))
                  (element? Op (shen-jit.check.real-binary))
                  (element? Op (shen-jit.check.real-tests))))

\\ Real registers live only in code that calls nothing and catches nothing: nothing
\\ saves them across a call, and a handler would find them as a raise left them. A
\\ self tail call comes back to loop, which only straight-line code may come before.
(define shen-jit.check.reals
  Where Is -> (if (shen-jit.check.any-real? Is)
                  (do (map (/. I (shen-jit.check.assert
                                   (not (element? (hd I) [call call-sealed call-value push-handler pop-handler
                                                          exception entry jump-unless-entry]))
                                   Where "real registers with a call or a handler" I))
                           Is)
                      (shen-jit.check.before-loop Where Is))
                  skip))

(define shen-jit.check.any-real?
  [] -> false
  [I | Is] -> (or (shen-jit.check.real-op? I) (shen-jit.check.any-real? Is)))

\\ Is, up to a loop if there is one, is straight-line code; there is one loop at most.
(define shen-jit.check.before-loop
  Where [] -> skip
  Where [[loop] | Is] -> (shen-jit.check.assert (not (element? [loop] Is)) Where "two loops" [loop])
  Where [[Op | X] | Is]
  -> (do (if (element? [loop] Is)
             (shen-jit.check.assert (not (or (element? Op [label jump jump-if-false return])
                                             (element? Op (shen-jit.check.real-tests))))
                                    Where "control flow before loop" [Op | X])
             skip)
         (shen-jit.check.before-loop Where Is)))

(define shen-jit.check.below?
  I N -> (and (integer? I) (>= I 0) (< I N)))

\\ Writes never touch the return address, the procedure or the parameters.
(define shen-jit.check.write?
  [_ _ Frame | _] D -> (and (integer? D) (>= D 2) (< D Frame)))

(define shen-jit.check.read?
  [_ _ Frame | _] S -> (and (integer? S) (>= S 2) (< S Frame)))

\\ An operand is a slot to read, or (const K) for a constant of the code.
(define shen-jit.check.operand?
  Ctx [const K] -> (shen-jit.check.below? K (nth 4 Ctx))
  Ctx S -> (shen-jit.check.read? Ctx S))

(define shen-jit.check.operands?
  Ctx Ss -> (or (empty? Ss) (and (shen-jit.check.operand? Ctx (hd Ss))
                                 (shen-jit.check.operands? Ctx (tl Ss)))))

(define shen-jit.check.reads?
  Ctx Ss -> (or (empty? Ss) (and (shen-jit.check.read? Ctx (hd Ss))
                                 (shen-jit.check.reads? Ctx (tl Ss)))))

\\ Windows lie above the parameters and inside the frame: A+1+N < FrameSize.
(define shen-jit.check.window?
  [_ Arity Frame | _] A N -> (and (integer? A) (integer? N) (>= N 0) (>= A (+ Arity 2))
                                  (< (+ A (+ 1 N)) Frame)))

\\ A named tail call may also use window 0: its arguments are then already in
\\ slots 2 to N+1.
(define shen-jit.check.tail-window?
  [_ _ Frame | _] 0 N -> (and (integer? N) (>= N 0) (< (+ 1 N) Frame))
  Ctx A N -> (shen-jit.check.window? Ctx A N))

\\ exception follows only a handler label. A handler label without it is a
\\ quiet handler, which never reads the exception (docs/bytecode.md).
(define shen-jit.check.handlers
  _ _ [] _ -> true
  Where Prev [[exception D] | Is] Handlers
  -> (do (shen-jit.check.assert (shen-jit.check.handler-label? Prev Handlers) Where
                                  "exception not at a handler label" Prev)
         (shen-jit.check.handlers Where [exception D] Is Handlers))
  Where _ [I | Is] Handlers -> (shen-jit.check.handlers Where I Is Handlers))

(define shen-jit.check.handler-label?
  [label L] Handlers -> (element? L Handlers)
  _ _ -> false)

\\ Every nested code is created by exactly one closure instruction and checked
\\ with that closure's capture count.
(define shen-jit.check.nested
  Where Instructions Codes
  -> (let Closures (mapcan (/. I (if (= (hd I) closure) [I] [])) Instructions)
          Used (map (/. I (hd (tl (tl I)))) Closures)
       (do (shen-jit.check.assert (and (= (length Used) (length Codes)) (shen-jit.check.distinct? Used))
                                    Where "nested codes not used exactly once" Used)
           (map (/. I (shen-jit.check.code (cn (str Where) "/") (nth (+ 1 (hd (tl (tl I)))) Codes)
                                             (length (tl (tl (tl I)))) nested))
                Closures))))

\\ ---------------------------------------------------------------------------
\\ Dataflow. A state is [Defined | Handlers] or dead; Pending holds, per
\\ label, the merged state of the jumps (and raises) to it, or done once the
\\ label is passed, so a backward jump is caught. Defined also holds
\\ [param P] for each parameter slot, and [new P] once P is written: only a
\\ tail call with window 0 may then read P, as its argument.

(define shen-jit.check.flow
  Where Arity Instructions NLabels
  -> (let Pending (shen-jit.check.fill (absvector NLabels) 0 NLabels none)
          Final (shen-jit.check.flow-h Where (shen-jit.check.mark-loop Arity Instructions)
                                       (shen-jit.check.entry-state Arity) Pending [])
       (shen-jit.check.assert (= Final dead) Where "code falls off the end" Final)))

\\ A slot other than a parameter that code after loop writes counts as unset there: what
\\ reads it must have written it the same time round, as the JIT does not store what it
\\ finds dead going forward. A parameter's next value is the tail call's argument.
(define shen-jit.check.mark-loop
  _ [] -> []
  Arity [[loop] | Is] -> [[loop (shen-jit.check.locals-written Arity Is)] | Is]
  Arity [I | Is] -> [I | (shen-jit.check.mark-loop Arity Is)])

(define shen-jit.check.locals-written
  Arity Is -> (mapcan (/. I (if (and (element? (hd I) [move const capture closure prim real-box exception])
                                     (> (hd (tl I)) (+ Arity 1)))
                                [(hd (tl I))]
                                []))
                      Is))

(define shen-jit.check.fill
  V I N X -> V where (= I N)
  V I N X -> (shen-jit.check.fill (address-> V I X) (+ I 1) N X))

(define shen-jit.check.range
  I J -> [] where (> I J)
  I J -> [I | (shen-jit.check.range (+ I 1) J)])

\\ Order is the handlers active by the order of the code, which is how the JIT
\\ tracks them: it must agree with the handlers active on every path here.
(define shen-jit.check.flow-h
  _ [] State _ _ -> State
  Where [[label L] | Is] State Pending Order
  -> (let Merged (shen-jit.check.merge Where State (<-address Pending L))
       (do (address-> Pending L done)
           (shen-jit.check.flow-h Where Is Merged Pending Order)))
  Where [I | Is] dead Pending Order
  -> (do (shen-jit.check.fail Where "unreachable instruction" I)
         (shen-jit.check.flow-h Where Is dead Pending (shen-jit.check.in-order I Order)))
  Where [I | Is] [Defined | Handlers] Pending Order
  -> (do (shen-jit.check.assert (shen-jit.check.readable? I (shen-jit.check.used I) Defined)
                                  Where "reads an unset or clobbered slot" I)
         (shen-jit.check.assert (= Handlers Order) Where "handlers do not nest in code order" I)
         (shen-jit.check.raise Where I [Defined | Handlers] Pending)
         (shen-jit.check.flow-h Where Is (shen-jit.check.step Where I [Defined | Handlers] Pending)
                                  Pending (shen-jit.check.in-order I Order))))

(define shen-jit.check.in-order
  [push-handler L] Order -> [L | Order]
  [pop-handler] [_ | Order] -> Order
  _ Order -> Order)

(define shen-jit.check.merge
  Where _ done -> (do (shen-jit.check.fail Where "label reached twice" done) dead)
  _ dead none -> dead
  _ State none -> State
  _ dead State -> State
  Where [D1 | H1] [D2 | H2]
  -> (do (shen-jit.check.assert (= H1 H2) Where "handler stacks differ at a join" [H1 H2])
         [(append (shen-jit.check.intersection D1 D2)
                  (shen-jit.check.new-on-one D1 D2) (shen-jit.check.new-on-one D2 D1))
          | H1]))

\\ A parameter written on one path and unchanged on the other.
(define shen-jit.check.new-on-one
  D1 D2 -> (mapcan (/. X (if (and (cons? X) (= (hd X) new) (element? (hd (tl X)) D2)) [X] [])) D1))

(define shen-jit.check.readable?
  [Op 0 | _] Used Defined -> (shen-jit.check.arguments? Used Defined)
      where (element? Op [tail-call tail-call-sealed])
  _ Used Defined -> (shen-jit.check.subset? Used Defined))

(define shen-jit.check.arguments?
  [] _ -> true
  [S | Ss] Defined -> (and (or (element? S Defined) (element? [new S] Defined))
                           (shen-jit.check.arguments? Ss Defined)))

\\ Writing a parameter slot makes it [new P].
(define shen-jit.check.set
  D Defined -> (adjoin [new D] (remove D Defined)) where (element? [param D] Defined)
  D Defined -> (adjoin D Defined))

(define shen-jit.check.propagate
  Where L State Pending
  -> (if (= (<-address Pending L) done)
         (shen-jit.check.fail Where "backward jump" L)
         (address-> Pending L (shen-jit.check.merge Where State (<-address Pending L)))))

\\ Slots an instruction reads; constant operands read none.
(define shen-jit.check.used
  [move _ S] -> [S]
  [closure _ _ | Ss] -> Ss
  [prim _ _ | Ss] -> (shen-jit.check.slots Ss)
  [jump-if-false S _] -> (shen-jit.check.slots [S])
  [jump-unless-entry S _ _] -> [S]
  [call _ A _ N] -> (shen-jit.check.range (+ A 2) (+ A (+ 1 N)))
  [call-sealed _ A _ N] -> (shen-jit.check.range (+ A 2) (+ A (+ 1 N)))
  [call-value _ A N] -> (shen-jit.check.range (+ A 1) (+ A (+ 1 N)))
  [tail-call A _ N] -> (shen-jit.check.range (+ A 2) (+ A (+ 1 N)))
  [tail-call-sealed A _ N] -> (shen-jit.check.range (+ A 2) (+ A (+ 1 N)))
  [tail-call-value A N] -> (shen-jit.check.range (+ A 1) (+ A (+ 1 N)))
  [return S] -> (shen-jit.check.slots [S])
  [real-number _ O] -> (shen-jit.check.slots [O])
  [real-box _ F] -> [[real F]]
  [real-load _ M I] -> (shen-jit.check.slots [M I])
  [real-store M I F] -> [[real F] | (shen-jit.check.slots [M I])]
  [Op _ A] -> [[real A]] where (element? Op (shen-jit.check.real-unary))
  [Op _ A B] -> [[real A] [real B]] where (element? Op (shen-jit.check.real-binary))
  [Op A B _] -> [[real A] [real B]] where (element? Op (shen-jit.check.real-tests))
  _ -> [])

(define shen-jit.check.slots
  Ss -> (mapcan (/. S (if (integer? S) [S] [])) Ss))

\\ A call clobbers every slot from its window up.
(define shen-jit.check.window-base
  [call _ A | _] -> A
  [call-sealed _ A | _] -> A
  [call-value _ A _] -> A
  _ -> -1)

\\ Anything but a jump or handler bookkeeping may raise: the innermost handler
\\ then starts with the slots set so far, minus those a call clobbers.
(define shen-jit.check.raise
  _ [Op | _] _ _ -> skip where (element? Op [jump push-handler pop-handler exception entry
                                              jump-unless-entry inline])
  _ _ [_ | []] _ -> skip
  Where I [Defined L | Handlers] Pending
  -> (shen-jit.check.propagate Where L [(shen-jit.check.clobber Defined (shen-jit.check.window-base I))
                                          | Handlers] Pending))

(define shen-jit.check.clobber
  Defined -1 -> Defined
  Defined A -> (mapcan (/. S (if (or (cons? S) (< S A)) [S] [])) Defined))

(define shen-jit.check.step
  Where [jump L] State Pending -> (do (shen-jit.check.propagate Where L State Pending) dead)
  Where [jump-if-false _ L] State Pending -> (do (shen-jit.check.propagate Where L State Pending) State)
  Where [jump-unless-entry _ _ L] State Pending
  -> (do (shen-jit.check.propagate Where L State Pending) State)
  _ [loop Forget] [Defined | Handlers] _ -> [(shen-jit.check.without Forget Defined) | Handlers]
  _ [real-number F _] [Defined | Handlers] _ -> [(adjoin [real F] Defined) | Handlers]
  _ [real-load F _ _] [Defined | Handlers] _ -> [(adjoin [real F] Defined) | Handlers]
  _ [real-store | _] State _ -> State
  _ [Op F | X] [Defined | Handlers] _ -> [(adjoin [real F] Defined) | Handlers]
      where (or (element? Op (shen-jit.check.real-unary)) (element? Op (shen-jit.check.real-binary)))
  Where [Op _ _ L] State Pending -> (do (shen-jit.check.propagate Where L State Pending) State)
      where (element? Op (shen-jit.check.real-tests))
  Where [entry N L] State Pending
  -> (do (shen-jit.check.propagate Where L (shen-jit.check.entry-state N) Pending) State)
  Where [return S] [_ | Handlers] _ -> (shen-jit.check.leave Where [return S] Handlers)
  Where [Op | X] [_ | Handlers] _ -> (shen-jit.check.leave Where [Op | X] Handlers)
      where (element? Op [tail-call tail-call-sealed tail-call-value])
  _ [push-handler L] [Defined | Handlers] _ -> [Defined L | Handlers]
  _ [inline _ _] State _ -> State
  Where [pop-handler] [Defined | Handlers] _
  -> (if (empty? Handlers)
         (do (shen-jit.check.fail Where "pop-handler without handler" Defined) dead)
         [Defined | (tl Handlers)])
  _ [Op D | X] [Defined | Handlers] Pending
  -> (do (shen-jit.check.forget D Handlers Pending)
         [(shen-jit.check.set D (shen-jit.check.clobber Defined (shen-jit.check.window-base [Op D | X])))
          | Handlers])
      where (element? Op [move const capture closure prim call call-sealed call-value exception real-box])
  Where I State _ -> (do (shen-jit.check.fail Where "unknown instruction" I) State))

(define shen-jit.check.without
  Xs Ys -> (mapcan (/. Y (if (element? Y Xs) [] [Y])) Ys))

\\ A handler reads no slot written since its push: the JIT does not store a test's
\\ result that the code after the test never reads.
(define shen-jit.check.forget
  _ [] _ -> skip
  D [L | Ls] Pending -> (let S (<-address Pending L)
                          (do (if (cons? S) (address-> Pending L [(remove D (hd S)) | (tl S)]) skip)
                              (shen-jit.check.forget D Ls Pending))))

(define shen-jit.check.leave
  Where I Handlers -> (do (shen-jit.check.assert (empty? Handlers) Where "leaves with a handler" I)
                          dead))

(define shen-jit.check.subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (shen-jit.check.subset? Xs Ys)))

(define shen-jit.check.intersection
  Xs Ys -> (mapcan (/. X (if (element? X Ys) [X] [])) Xs))

\\ ---------------------------------------------------------------------------
\\ The builder. Slots are numbered from 2: the parameters, then the other variables
\\ as they first appear, and call windows above them all.

\\ A later call in the same file compiles directly if the name's arity is known when
\\ it is read, as for define.
(defmacro shen-jit.native-macro
  [define-native Name Params | Body]
  -> (do (if (and (symbol? Name) (not (variable? Name)) (= (arity Name) -1))
             (shen.store-arity Name (length Params))
             skip)
         [shen-jit.native.define Name (shen-jit.native.list Params) (shen-jit.native.list Body)]))

\\ Forms that evaluate to the instructions as data. (const E) stays an expression, and
\\ so does what the reader made of a list in brackets, as a constant.
(define shen-jit.native.data
  [const E] -> [cons const [cons E []]]
  [cons X Y] -> [cons const [cons [cons X Y] []]]
  [X | Y] -> (shen-jit.native.list [X | Y])
  X -> [protect X] where (variable? X)
  X -> X)

(define shen-jit.native.list
  [] -> []
  [X | Y] -> [cons (shen-jit.native.data X) (shen-jit.native.list Y)])

\\ As assemble and install-code, with the slots named in any error.
(define shen-jit.native.define
  Name Params Body
  -> (let Code (shen-jit.assemble Name Params Body)
       (trap-error
         (shen-jit.install-code [defun Name Code])
         (/. E (simple-error (make-string "~A~%slots: ~R" (error-to-string E)
                                          (shen-jit.lower.bind (shen-jit.native.slots Params [] (shen-jit.real.expand Body)) 2)))))))

(define shen-jit.assemble
  Name Params Body -> (shen-jit.native.code Name Params [] Body))

(define shen-jit.native.code
  Name Params Captures Written
  -> (let Body (shen-jit.real.expand Written)
          B (shen-jit.lower.builder Name (length Params) [])
          Named (shen-jit.native.slots Params Captures Body)
          Reals (shen-jit.real.registers Name Named Body)
          Window (+ 2 (length Named))
          C [B (append (shen-jit.lower.bind Named 2) (shen-jit.lower.bind Reals 0))
               (shen-jit.native.labels Body) Window]
       (do (if (shen-jit.check.distinct? (append Params Captures))
               skip
               (simple-error (make-string "native code, ~A: a name given twice: ~R" Name [Params Captures])))
           (shen-jit.lower.reserve B (- Window 1))
           (shen-jit.native.captures C Captures 0)
           (map (/. I (shen-jit.native.insn C I)) Body)
           (shen-jit.lower.code-form B))))

(define shen-jit.native.slots
  Params Captures Body
  -> (shen-jit.native.add-names (mapcan (/. I (shen-jit.native.uses I)) Body)
                                (append Params Captures)))

(define shen-jit.native.add-names
  [] Named -> Named
  [X | Xs] Named -> (shen-jit.native.add-names Xs Named)
      where (or (not (variable? X)) (element? X Named))
  [X | Xs] Named -> (shen-jit.native.add-names Xs (append Named [X])))

(define shen-jit.native.uses
  [move D O] -> [D O]
  [prim D _ | Os] -> [D | Os]
  [jump-if-false O _] -> [O]
  [call D F | Os] -> [D F | Os]
  [tail-call F | Os] -> [F | Os]
  [return O] -> [O]
  [closure D _ Captures | _] -> [D | Captures]
  [exception D] -> [D]
  [real-number _ O] -> [O]
  [real-box D _] -> [D]
  [real-load _ M I] -> [M I]
  [real-store M I _] -> [M I]
  _ -> [])

(define shen-jit.native.labels
  Body -> (let Names (mapcan (/. I (if (= (hd I) label) (tl I) [])) Body)
            (if (shen-jit.check.distinct? Names)
                (shen-jit.lower.bind Names 0)
                (simple-error (make-string "native code: a label given twice: ~R" Names)))))

(define shen-jit.native.find
  Kind Table X -> (let Entry (assoc X Table)
                    (if (cons? Entry)
                        (tl Entry)
                        (simple-error (make-string "native code: no such ~A: ~R" Kind X)))))

(define shen-jit.native.slot
  [_ Slots | _] X -> (shen-jit.native.find "slot" Slots X))

(define shen-jit.native.label
  [_ _ Labels _] X -> (shen-jit.native.find "label" Labels X))

(define shen-jit.native.emit
  [B | _] I -> (shen-jit.lower.emit B I))

(define shen-jit.native.operand
  [B | _] [const X] -> [const (shen-jit.lower.constant B X)]
  C X -> (shen-jit.native.slot C X) where (variable? X)
  _ [X | Y] -> (simple-error (make-string "native code: bad operand: ~R" [X | Y]))
  [B | _] X -> [const (shen-jit.lower.constant B X)])

(define shen-jit.native.operands
  C Os -> (map (/. O (shen-jit.native.operand C O)) Os))

(define shen-jit.native.store
  C D [const K] -> (shen-jit.native.emit C [const D K])
  C D S -> (shen-jit.native.emit C [move D S]))

(define shen-jit.native.captures
  _ [] _ -> skip
  C [X | Xs] I -> (do (shen-jit.native.emit C [capture (shen-jit.native.slot C X) I])
                      (shen-jit.native.captures C Xs (+ I 1))))

(define shen-jit.native.insn
  C [label L] -> (shen-jit.native.emit C [label (shen-jit.native.label C L)])
  C [jump L] -> (shen-jit.native.emit C [jump (shen-jit.native.label C L)])
  C [jump-if-false O L] -> (shen-jit.native.emit C [jump-if-false (shen-jit.native.operand C O)
                                                                  (shen-jit.native.label C L)])
  C [move D O] -> (shen-jit.native.store C (shen-jit.native.slot C D) (shen-jit.native.operand C O))
  C [prim D Op | Os] -> (shen-jit.native.emit C [prim (shen-jit.native.slot C D) Op
                                                      | (shen-jit.native.operands C Os)])
  C [return O] -> (shen-jit.native.emit C [return (shen-jit.native.operand C O)])
  C [call D F | Os] -> (shen-jit.native.value-call C [call-value (shen-jit.native.slot C D)] F Os)
      where (variable? F)
  C [call D F | Os] -> (shen-jit.native.named-call C (shen-jit.native.slot C D) F (shen-jit.native.operands C Os))
  C [tail-call F | Os] -> (shen-jit.native.value-call C [tail-call-value] F Os) where (variable? F)
  C [tail-call F | Os] -> (shen-jit.native.tail-call C F (shen-jit.native.operands C Os))
  C [closure D Params Captures | Body] -> (shen-jit.native.closure C (shen-jit.native.slot C D) Params Captures Body)
  C [push-handler L] -> (shen-jit.native.emit C [push-handler (shen-jit.native.label C L)])
  C [pop-handler] -> (shen-jit.native.emit C [pop-handler])
  C [exception D] -> (shen-jit.native.emit C [exception (shen-jit.native.slot C D)])
  C [loop] -> (shen-jit.native.emit C [loop])
  C [real-number F O] -> (shen-jit.native.emit C [real-number (shen-jit.native.slot C F) (shen-jit.native.operand C O)])
  C [real-box D F] -> (shen-jit.native.emit C [real-box (shen-jit.native.slot C D) (shen-jit.native.slot C F)])
  C [real-load F M I] -> (shen-jit.native.emit C [real-load (shen-jit.native.slot C F) (shen-jit.native.operand C M)
                                                            (shen-jit.native.operand C I)])
  C [real-store M I F] -> (shen-jit.native.emit C [real-store (shen-jit.native.operand C M) (shen-jit.native.operand C I)
                                                              (shen-jit.native.slot C F)])
  C [Op D A] -> (shen-jit.native.emit C [Op (shen-jit.native.slot C D) (shen-jit.native.slot C A)])
      where (element? Op (shen-jit.check.real-unary))
  C [Op D A B] -> (shen-jit.native.emit C [Op (shen-jit.native.slot C D) (shen-jit.native.slot C A) (shen-jit.native.slot C B)])
      where (element? Op (shen-jit.check.real-binary))
  C [Op A B L] -> (shen-jit.native.emit C [Op (shen-jit.native.slot C A) (shen-jit.native.slot C B) (shen-jit.native.label C L)])
      where (element? Op (shen-jit.check.real-tests))
  _ I -> (simple-error (make-string "native code: unknown instruction: ~R" I)))

\\ ---------------------------------------------------------------------------
\\ Real expressions, as flat instructions. A variable given a value by real is a register,
\\ in a namespace of its own; any other variable in an expression is a slot, whose number
\\ is read with a check. Intermediate values take registers of their own, named by depth.

(define shen-jit.real.expand
  Body -> (let Reals (shen-jit.native.add-names (mapcan (/. I (shen-jit.real.named I)) Body) [])
            (mapcan (/. I (shen-jit.real.statement Reals I)) Body)))

(define shen-jit.real.named
  [real X _] -> [X]
  _ -> [])

(define shen-jit.real.statement
  Rs [real X E] -> (shen-jit.real.into Rs 0 X E)
  Rs [f64! M I E] -> (let Value (shen-jit.real.operand Rs 0 E)
                          Index (shen-jit.real.index 0 I)
                       (append (tl Value) (tl Index) [[real-store M (hd Index) (hd Value)]]))
  Rs [real-box D E] -> (let Value (shen-jit.real.operand Rs 0 E)
                         (append (tl Value) [[real-box D (hd Value)]]))
  Rs [return-real E] -> (append (shen-jit.real.statement Rs [real-box (intern "Real.Result") E])
                                [[return (intern "Real.Result")]])
  Rs [jump-unless [Op A B] L]
  -> (let First (shen-jit.real.operand Rs 0 A)
          Second (shen-jit.real.operand Rs (shen-jit.real.after Rs 0 A) B)
       (append (tl First) (tl Second) [[(shen-jit.real.test Op) (hd First) (hd Second) L]]))
  _ I -> [I])

(define shen-jit.real.test
  < -> real-unless<
  > -> real-unless>
  <= -> real-unless<=
  >= -> real-unless>=
  = -> real-unless=
  Op -> (simple-error (make-string "native code: not a comparison of reals: ~R" Op)))

\\ The temporary after the one operand E takes, if it takes one.
(define shen-jit.real.after
  Rs N E -> (if (element? E Rs) N (+ N 1)))

(define shen-jit.real.temporary
  N -> (intern (cn "Real." (str N))))

\\ [the register that holds E | the instructions that put it there]. E's own first operand
\\ can share its temporary, as that is written last.
(define shen-jit.real.operand
  Rs N E -> [E] where (element? E Rs)
  Rs N E -> (let T (shen-jit.real.temporary N)
              [T | (shen-jit.real.into Rs N T E)]))

\\ What puts E in register D. D is written last, so E may read it.
(define shen-jit.real.into
  Rs _ D E -> [[real-move D E]] where (element? E Rs)
  _ _ D [const K] -> [[real-number D [const K]]]
  _ _ D [f64 M I] -> (let Index (shen-jit.real.index 0 I)
                       (append (tl Index) [[real-load D M (hd Index)]]))
  Rs N D [neg A] -> (shen-jit.real.unary Rs N D real-neg A)
  Rs N D [abs A] -> (shen-jit.real.unary Rs N D real-abs A)
  Rs N D [sqrt A] -> (shen-jit.real.unary Rs N D real-sqrt A)
  Rs N D [+ A B] -> (shen-jit.real.binary Rs N D real+ A B)
  Rs N D [- A B] -> (shen-jit.real.binary Rs N D real- A B)
  Rs N D [* A B] -> (shen-jit.real.binary Rs N D real* A B)
  Rs N D [/ A B] -> (shen-jit.real.binary Rs N D real/ A B)
  Rs N D [Op A B C | More] -> (shen-jit.real.into Rs N D [Op A [Op B C | More]]) where (element? Op [+ *])
  _ _ _ [Op | X] -> (simple-error (make-string "native code: not a real expression: ~R" [Op | X]))
  _ _ D O -> [[real-number D O]])

(define shen-jit.real.unary
  Rs N D Op A -> (let Value (shen-jit.real.operand Rs N A)
                   (append (tl Value) [[Op D (hd Value)]])))

(define shen-jit.real.binary
  Rs N D Op A B -> (let First (shen-jit.real.operand Rs N A)
                        Second (shen-jit.real.operand Rs (shen-jit.real.after Rs N A) B)
                     (append (tl First) (tl Second) [[Op D (hd First) (hd Second)]])))

\\ An index is an operand, or integer arithmetic through prim: [what holds it | instructions].
\\ Its slots are read at once, so that each statement can use them again.
(define shen-jit.real.index
  _ [const K] -> [[const K]]
  N [Op | Args] -> (let T (intern (cn "Real.Index." (str N)))
                        Values (shen-jit.real.indices (+ N 1) Args)
                     [T | (append (tl Values) [[prim T Op | (hd Values)]])])
  _ I -> [I])

(define shen-jit.real.indices
  _ [] -> [[]]
  N [A | As] -> (let Value (shen-jit.real.index N A)
                     Rest (shen-jit.real.indices (+ N 1) As)
                  [[(hd Value) | (hd Rest)] | (append (tl Value) (tl Rest))]))

\\ The registers that flat instructions name, which are not slots, and fit.
(define shen-jit.real.registers
  Name Slots Body
  -> (let Reals (shen-jit.native.add-names (mapcan (/. I (shen-jit.real.reads I)) Body) [])
       (do (map (/. X (if (element? X Slots)
                          (simple-error (make-string "native code, ~A: ~R is a real register, and is used as a slot" Name X))
                          skip))
                Reals)
           (if (> (length Reals) 12)
               (simple-error (make-string "native code, ~A: more than 12 real registers: ~R" Name Reals))
               Reals))))

(define shen-jit.real.reads
  [real-number F _] -> [F]
  [real-box _ F] -> [F]
  [real-load F _ _] -> [F]
  [real-store _ _ F] -> [F]
  [Op D A] -> [D A] where (element? Op (shen-jit.check.real-unary))
  [Op D A B] -> [D A B] where (element? Op (shen-jit.check.real-binary))
  [Op A B _] -> [A B] where (element? Op (shen-jit.check.real-tests))
  _ -> [])

\\ Puts operands in the call window's argument slots, from T.
(define shen-jit.native.arguments
  _ [] _ -> skip
  C [X | Xs] T -> (do (shen-jit.native.store C T X)
                      (shen-jit.native.arguments C Xs (+ T 1))))

(define shen-jit.native.named-call
  [B S L Window] D F Os
  -> (do (shen-jit.lower.reserve B (+ Window (+ 1 (length Os))))
         (shen-jit.native.arguments [B S L Window] Os (+ Window 2))
         (shen-jit.native.emit [B S L Window]
                               [(if (shen-jit.sealed? F) call-sealed call) D Window F (length Os)])))

\\ What it takes all at once depends on the value, so one argument at a time.
(define shen-jit.native.value-call
  _ _ _ [_ _ | _] -> (simple-error "native code: a call of a variable takes no or one argument")
  [B S L Window] [Op | D] F Os
  -> (do (shen-jit.lower.reserve B (+ Window (+ 1 (length Os))))
         (shen-jit.native.arguments [B S L Window] (shen-jit.native.operands [B S L Window] Os) (+ Window 2))
         (shen-jit.native.store [B S L Window] (+ Window 1) (shen-jit.native.operand [B S L Window] F))
         (shen-jit.native.emit [B S L Window] (append [Op | D] [Window (length Os)]))))

\\ A tail call's arguments go straight to slots 2.., where the callee expects them,
\\ so a call of the same name loops without moves. One whose slot a later argument
\\ still reads waits above the others until they are done.
(define shen-jit.native.tail-call
  [B S L Window] F Os
  -> (let N (length Os)
       (do (shen-jit.lower.reserve B (+ N 1))
           (map (/. T (shen-jit.native.store [B S L Window] T (+ Window T)))
                (shen-jit.native.tail-arguments [B S L Window] Os 2 []))
           (shen-jit.native.emit [B S L Window]
                                 [(if (shen-jit.sealed? F) tail-call-sealed tail-call) 0 F N]))))

\\ Returns the slots whose arguments wait.
(define shen-jit.native.tail-arguments
  _ [] _ Later -> Later
  C [T | Os] T Later -> (shen-jit.native.tail-arguments C Os (+ T 1) Later)
  [B S L Window] [O | Os] T Later
  -> (do (shen-jit.lower.reserve B (+ Window T))
         (shen-jit.native.store [B S L Window] (+ Window T) O)
         (shen-jit.native.tail-arguments [B S L Window] Os (+ T 1) [T | Later]))
      where (element? T Os)
  C [O | Os] T Later
  -> (do (shen-jit.native.store C T O)
         (shen-jit.native.tail-arguments C Os (+ T 1) Later)))

(define shen-jit.native.closure
  [B S L Window] D Params Captures Body
  -> (let Name (if (empty? Params) freeze lambda)
          Code (shen-jit.native.code Name Params Captures Body)
          I (shen-jit.lower.add-code B Code)
       (shen-jit.native.emit [B S L Window]
                             [closure D I | (map (/. X (shen-jit.native.slot [B S L Window] X)) Captures)])))

\\ ---------------------------------------------------------------------------
\\ Checking and installing.

(define shen-jit.install-code
  [defun F [code Name Arity | Rest]]
  -> (do (shen-jit.native.check F [code Name Arity | Rest])
         (shen-jit.install [defun F [code Name Arity | Rest]])
         (shen.store-arity F Arity)
         F)
  Code -> (do (shen-jit.native.check code Code) (shen-jit.install Code)))

(define shen-jit.native.check
  Where [code Name Arity Frame Constants Instructions Codes]
  -> (shen-jit.check.code Where [code Name Arity Frame Constants Instructions Codes] 0 top)
  Where [code Name Arity Frame Constants Instructions Codes []]
  -> (shen-jit.check.code Where [code Name Arity Frame Constants Instructions Codes] 0 top)
  Where X -> (shen-jit.check.fail Where "malformed code object" X))
