\\ Native code written by hand (lib/native.shen): code the builder and the
\\ checker accept runs as written, and code they should refuse never reaches the
\\ JIT. Run by make test-native, from the repository's root, after loading
\\ lib/native.shen: a macro applies only to files read after it is defined.

(set native-test.*passed* 0)
(set native-test.*failed* 0)

(define native-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define native-test.check
  Name Expected F -> (native-test.compare Name Expected (native-test.result F)))

(define native-test.compare
  _ X X -> (set native-test.*passed* (+ 1 (value native-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set native-test.*failed* (+ 1 (value native-test.*failed*)))))

\\ Code that must be refused, as hand-written code objects and through the builder.
\\ What matters is that the JIT never sees it: running it could crash. Code objects
\\ are data, so brackets write them; the macro takes forms.
(define native-test.refused
  Name F -> (native-test.compare Name refused
              (trap-error (do (thaw F) accepted) (/. E refused))))

(define native-test.raw
  Name Code -> (native-test.refused Name (freeze (shen-jit.install-code Code))))

\\ ---------------------------------------------------------------------------
\\ Code that runs.

\\ A loop: parameters overwritten in place, and a tail call with its arguments
\\ already in their slots, which the JIT compiles to a jump.
(define-native native-test.sum (Xs Acc)
  (prim T cons? Xs)
  (jump-if-false T done)
  (prim H hd Xs)
  (prim Acc + Acc H)
  (prim Xs tl Xs)
  (tail-call native-test.sum Xs Acc)
  (label done)
  (return Acc))
(native-test.check "a loop" 10 (freeze (native-test.sum [1 2 3 4] 0)))
(native-test.check "through fn" 3 (freeze ((fn native-test.sum) [1 2] 0)))
(native-test.check "a type error raises" error (freeze (hd (native-test.result (freeze (native-test.sum [a] 0))))))

(define native-test.numbers
  0 Acc -> Acc
  N Acc -> (native-test.numbers (- N 1) [N | Acc]))
(native-test.check "a long loop" 5000050000 (freeze (native-test.sum (native-test.numbers 100000 []) 0)))

\\ A tail call whose arguments swap, and ones that rotate or reach past the
\\ parameters, over a slot in use.
(define-native native-test.swap (A B N)
  (prim T = N 0)
  (jump-if-false T more)
  (prim R cons A B)
  (return R)
  (label more)
  (prim N1 - N 1)
  (tail-call native-test.swap B A N1))
(native-test.check "swapped arguments" [1 | 2] (freeze (native-test.swap 1 2 4)))
(native-test.check "swapped, odd" [2 | 1] (freeze (native-test.swap 1 2 3)))

(define-native native-test.three (A B C)
  (prim R cons B C)
  (prim R cons A R)
  (return R))
(define-native native-test.rotate (A B C)
  (tail-call native-test.three B C A))
(native-test.check "rotated arguments" [2 3 | 1] (freeze (native-test.rotate 1 2 3)))
(define-native native-test.widen (A)
  (prim X + A 1)
  (tail-call native-test.three X A X))
(native-test.check "more arguments than parameters" [2 1 | 2] (freeze (native-test.widen 1)))

\\ Constants: a string, a real, a Boolean, a symbol, a list, and with const the
\\ value of an expression, here one that is no literal.
(set native-test.*vector* (vector 2))
(define-native native-test.constants ()
  (prim A cons "s" [])
  (prim A cons 1.5 A)
  (prim A cons true A)
  (prim B cons foo A)
  (move C [1 2])
  (prim D cons C B)
  (prim E cons (const (value native-test.*vector*)) D)
  (return E))
(native-test.check "constants" [[1 2] foo true 1.5 "s"] (freeze (tl (native-test.constants))))
(native-test.check "a heap value as a constant" true
  (freeze (= (hd (native-test.constants)) (value native-test.*vector*))))

\\ Calls: an open one, a sealed one and one of a variable.
(define native-test.double X -> (* 2 X))
(define-native native-test.calls (X F)
  (call A native-test.double X)
  (call B reverse [1 2 3])
  (call C F A)
  (prim R cons C B)
  (return R))
(native-test.check "calls" [7 3 2 1] (freeze (native-test.calls 3 (/. X (+ X 1)))))
(define-native native-test.tail-of-variable (F X)
  (tail-call F X))
(native-test.check "a tail call of a variable" 4 (freeze (native-test.tail-of-variable (/. X (+ X 1)) 3)))

\\ Calls clobber the window, not the slots below it.
(define-native native-test.survive (X)
  (move A 10)
  (move B 20)
  (call C native-test.double X)
  (prim R + A B)
  (prim R + R C)
  (return R))
(native-test.check "slots survive a call" 36 (freeze (native-test.survive 3)))

\\ An open call sees a redefinition.
(define-native native-test.answer () (return 1))
(define-native native-test.ask () (call X native-test.answer) (return X))
(native-test.check "first definition" 1 (freeze (native-test.ask)))
(define-native native-test.answer () (return 2))
(native-test.check "redefined" 2 (freeze (native-test.ask)))

\\ Closures: a captured value and a freeze.
(define-native native-test.adder (N)
  (closure F (X) (N)
    (prim R + X N)
    (return R))
  (return F))
(native-test.check "a closure" 5 (freeze ((native-test.adder 2) 3)))
(define-native native-test.later (A B)
  (closure F () (A B)
    (prim R cons A B)
    (return R))
  (return F))
(native-test.check "a freeze" [1 | 2] (freeze (thaw (native-test.later 1 2))))

\\ Handlers: reading the exception, quietly, nested, and around a call.
(define-native native-test.safe-hd (X)
  (push-handler caught)
  (prim R hd X)
  (pop-handler)
  (return R)
  (label caught)
  (exception E)
  (prim S error-to-string E)
  (return S))
(native-test.check "no error" 1 (freeze (native-test.safe-hd [1])))
(native-test.check "an error caught" "hd: 2 is not a pair" (freeze (native-test.safe-hd 2)))
(define-native native-test.quiet (X)
  (push-handler caught)
  (prim R hd X)
  (pop-handler)
  (return R)
  (label caught)
  (return none))
(native-test.check "caught quietly" none (freeze (native-test.quiet 2)))
(define-native native-test.nested (X)
  (push-handler outer)
  (push-handler inner)
  (prim R hd X)
  (pop-handler)
  (jump after)
  (label inner)
  (prim R simple-error "again")
  (label after)
  (prim R tl X)
  (pop-handler)
  (return R)
  (label outer)
  (exception E)
  (prim S error-to-string E)
  (return S))
(native-test.check "nested handlers" "again" (freeze (native-test.nested 2)))
(native-test.check "nested, no error" [2] (freeze (native-test.nested [1 2])))
(define-native native-test.call-in-handler (X)
  (push-handler caught)
  (call R native-test.double X)
  (pop-handler)
  (return R)
  (label caught)
  (return X))
(native-test.check "a call under a handler" 4 (freeze (native-test.call-in-handler 2)))
(native-test.check "an error in the call" a (freeze (native-test.call-in-handler a)))

\\ Allocation, which moves values under GC stress.
(define-native native-test.build (N Acc)
  (prim T = N 0)
  (jump-if-false T more)
  (return Acc)
  (label more)
  (prim V absvector 2)
  (prim V address-> V 0 N)
  (prim S str N)
  (prim V address-> V 1 S)
  (prim Acc cons V Acc)
  (prim N - N 1)
  (tail-call native-test.build N Acc))
(native-test.check "allocation" "3" (freeze (<-address (hd (tl (tl (native-test.build 3 [])))) 1)))

\\ Code generated at run time: the macro inside a definition, where const reads the
\\ definition's own variable, and instructions as data for shen-jit.assemble, where
\\ brackets build the lists and protect makes a variable a symbol.
(define native-test.make-adder
  Name N -> (define-native Name (X)
              (prim R + X (const N))
              (return R)))
(native-test.make-adder native-test.add5 5)
(native-test.check "defined at run time" 8 (freeze (native-test.add5 3)))
(define native-test.generate
  N -> (shen-jit.install-code
         (shen-jit.assemble native-test.generated [(protect X)]
           [[prim (protect R) * (protect X) N]
            [return (protect R)]])))
(native-test.check "assembled at run time" 21 (freeze ((native-test.generate 7) 3)))
(native-test.check "assemble gives the code object"
  [code f 1 4 [1] [[prim 3 + 2 [const 0]] [return 3]] []]
  (freeze (shen-jit.assemble f [(protect X)] [[prim (protect R) + (protect X) 1] [return (protect R)]])))

\\ Byte buffers and bit operations, as primitives of a call-free loop, whose slots live
\\ in registers. The buffer comes first, and collections move it under GC stress.
(define-native native-test.sum-bytes (B I N Acc)
  (prim T = I N)
  (jump-if-false T more)
  (return Acc)
  (label more)
  (prim X shen-jit.u8 B I)
  (prim Acc + Acc X)
  (prim I + I 1)
  (tail-call native-test.sum-bytes B I N Acc))
(define-native native-test.fill (B I N)
  (prim T = I N)
  (jump-if-false T more)
  (return B)
  (label more)
  (prim X shen-jit.bit-and I 255)
  (prim B shen-jit.u8! B I X)
  (prim I + I 1)
  (tail-call native-test.fill B I N))
(native-test.check "filling and reading a buffer" 124716
  (freeze (native-test.sum-bytes (native-test.fill (shen-jit.bytes 3000) 0 1000) 0 1000 0)))
(native-test.check "a large buffer" 38246416
  (freeze (native-test.sum-bytes (native-test.fill (shen-jit.bytes 300000) 0 300000) 0 300000 0)))
(native-test.check "past the end of a buffer" [error "bytes: 3 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.sum-bytes (shen-jit.bytes 3) 0 4 0)))))

\\ Buffers that live across collections keep their contents.
(define native-test.buffers
  0 Acc -> Acc
  N Acc -> (native-test.buffers (- N 1) [(shen-jit.u32! (shen-jit.bytes 16) 4 N) | Acc]))
(define native-test.read-buffers
  [] Acc -> Acc
  [B | Bs] Acc -> (native-test.read-buffers Bs (+ Acc (shen-jit.u32 B 4))))
(native-test.check "buffers across collections" 500500
  (freeze (native-test.read-buffers (native-test.buffers 1000 []) 0)))

\\ FNV-1a, in plain Shen, with its published value for "a".
(define native-test.fnv
  _ I N H -> H where (= I N)
  B I N H -> (native-test.fnv B (+ I 1) N
               (shen-jit.bit-and (* (shen-jit.bit-xor H (shen-jit.u8 B I)) 16777619) 4294967295)))
(native-test.check "a hash" 3826002220 (freeze (native-test.fnv (shen-jit.string->bytes "a") 0 1 2166136261)))

\\ A code object written by hand, with what the builder does not write: an entry
\\ for two arguments at once, which also takes a jump from code that knows slot 2
\\ holds a pair. The label must not assume that when entered with two arguments.
(set native-test.*entry*
  (shen-jit.install-code
    [code native-test.entry 1 6 [1]
      [[entry 2 0]
       [prim 4 cons? 2]
       [jump-if-false 4 1]
       [const 3 0]
       [jump 0]
       [label 1]
       [return 2]
       [label 0]
       [prim 5 hd 2]
       [return 5]]
      []]))
(native-test.check "one argument" 7 (freeze ((value native-test.*entry*) 7)))
(native-test.check "one, a pair" 1 (freeze ((value native-test.*entry*) [1])))
(native-test.check "two arguments, checked" [error "hd: 7 is not a pair"]
  (freeze (native-test.result (freeze (let F (value native-test.*entry*) (F 7 8))))))
(native-test.check "two arguments, a pair" 1
  (freeze (let F (value native-test.*entry*) (F [1] 8))))

\\ ---------------------------------------------------------------------------
\\ Code to refuse. Each would misbehave or crash if it reached the JIT.

\\ What could overwrite the frame's own slots or read them as values.
(native-test.raw "writes the return address" [code f 0 4 [1] [[const 2 0] [const 0 0] [return 2]] []])
(native-test.raw "writes the procedure" [code f 0 4 [1] [[const 2 0] [move 1 2] [return 2]] []])
(native-test.raw "reads the return address" [code f 0 4 [] [[move 2 0] [return 2]] []])
(native-test.raw "reads the procedure" [code f 0 4 [] [[move 2 1] [return 2]] []])
(native-test.raw "returns the procedure" [code f 0 4 [] [[return 1]] []])
(native-test.raw "a slot past the frame" [code f 0 4 [1] [[const 9 0] [return 9]] []])
(native-test.raw "a window over the frame's start" [code f 0 6 [] [[call 3 0 native-test.double 0] [return 3]] []])
(native-test.raw "a window over a parameter" [code f 1 6 [] [[call 3 2 native-test.double 0] [return 3]] []])
(native-test.raw "a window past the frame" [code f 0 4 [] [[call 2 2 native-test.double 3] [return 2]] []])
(native-test.raw "a value tail call in window 0" [code f 0 4 [] [[tail-call-value 0 0]] []])

\\ Reading what was never written, or what a call has clobbered.
(native-test.raw "reads an unset slot" [code f 0 4 [] [[return 3]] []])
(native-test.raw "an unset argument" [code f 0 6 [] [[call 2 2 native-test.double 1] [return 2]] []])
(native-test.raw "reads above a window" [code f 0 6 [1] [[const 3 0] [call 2 2 native-test.ask 0] [return 3]] []])
(native-test.raw "set on one path only"
  [code f 1 5 [1] [[prim 3 cons? 2] [jump-if-false 3 0] [const 4 0] [label 0] [return 4]] []])

\\ Control flow the JIT cannot compile: it is one pass, and jumps only go forward.
(native-test.raw "a backward jump" [code f 0 4 [1] [[label 0] [const 2 0] [jump 0]] []])
(native-test.raw "falls off the end" [code f 0 4 [1] [[const 2 0]] []])
(native-test.raw "no code" [code f 0 4 [] [] []])
(native-test.raw "unreachable code" [code f 0 4 [1] [[const 2 0] [return 2] [const 2 0] [return 2]] []])
(native-test.raw "a label twice" [code f 0 4 [1] [[const 2 0] [jump 0] [label 0] [label 0] [return 2]] []])
(native-test.raw "an undefined label" [code f 0 4 [] [[jump 3]] []])

\\ Handlers: the JIT tracks them by the order of the code.
(native-test.raw "returns under a handler"
  [code f 0 4 [1] [[push-handler 0] [const 2 0] [return 2] [label 0] [return 2]] []])
(native-test.raw "tail calls under a handler"
  [code f 0 6 [1] [[push-handler 0] [tail-call 0 native-test.ask 0] [label 0] [const 2 0] [return 2]] []])
(native-test.raw "pops with no handler" [code f 0 4 [1] [[const 2 0] [pop-handler] [return 2]] []])
(native-test.raw "one push, a pop on each branch"
  [code f 1 5 [] [[push-handler 0] [prim 3 cons? 2] [jump-if-false 3 1] [pop-handler] [return 2]
                  [label 1] [pop-handler] [return 2] [label 0] [return 2]] []])
(native-test.raw "handlers differ at a join"
  [code f 1 5 [] [[push-handler 0] [prim 3 cons? 2] [jump-if-false 3 1] [pop-handler]
                  [label 1] [return 2] [label 0] [return 2]] []])
(native-test.raw "a handler out of the code's order"
  [code f 1 5 [] [[push-handler 0] [prim 3 cons? 2] [jump-if-false 3 2] [pop-handler] [push-handler 1]
                  [jump 3] [label 2] [pop-handler] [push-handler 1] [label 3] [prim 4 hd 2] [pop-handler] [return 4]
                  [label 0] [return 2] [label 1] [return 2]] []])
(native-test.raw "exception outside a handler" [code f 0 4 [1] [[const 2 0] [exception 3] [return 2]] []])
(native-test.raw "a handler reads a slot written under it"
  [code f 1 6 [1] [[const 3 0] [push-handler 0] [prim 3 cons? 2] [jump-if-false 3 1] [prim 4 hd 2]
                   [label 1] [pop-handler] [return 2] [label 0] [return 3]] []])

\\ Captures and nested code.
(native-test.raw "a capture at the top" [code f 0 4 [] [[capture 2 0] [return 2]] []])
(native-test.raw "a capture out of range"
  [code f 1 5 [] [[closure 3 0 2] [return 3]] [[code lambda 1 5 [] [[capture 3 1] [return 3]] []]]])
(native-test.raw "nested code not used"
  [code f 0 4 [1] [[const 2 0] [return 2]] [[code lambda 1 4 [] [[return 2]] []]]])
(native-test.raw "nested code used twice"
  [code f 0 5 [] [[closure 2 0] [closure 3 0] [return 3]] [[code lambda 1 4 [] [[return 2]] []]]])
(native-test.raw "a closure of no code" [code f 0 4 [] [[closure 2 0] [return 2]] []])
(native-test.raw "a nested lambda of two" 
  [code f 0 4 [] [[closure 2 0] [return 2]] [[code lambda 2 5 [] [[return 2]] []]]])

\\ Operands and names.
(native-test.raw "a constant out of range" [code f 0 4 [] [[const 2 5] [return 2]] []])
(native-test.raw "an operand constant out of range" [code f 0 4 [] [[return [const 0]]] []])
(native-test.raw "an unknown primitive" [code f 0 4 [] [[prim 2 frob] [return 2]] []])
(native-test.raw "a primitive's wrong arity" [code f 0 4 [1] [[prim 2 hd [const 0] [const 0]] [return 2]] []])
(native-test.raw "a call of a primitive" [code f 0 6 [1] [[const 4 0] [call 2 2 hd 1] [return 2]] []])
(native-test.raw "a sealed call of an open name" [code f 0 6 [] [[call-sealed 2 2 native-test.ask 0] [return 2]] []])
(native-test.raw "a primitive's arity, with five" [code f 0 4 [1] [[prim 2 shen-jit.copy-bytes [const 0]] [return 2]] []])
(native-test.raw "an unknown instruction" [code f 0 4 [] [[frob 1 2] [return 2]] []])
(native-test.raw "an instruction not a list" [code f 0 4 [] [5] []])
(native-test.raw "a slot not a number" [code f 0 4 [1] [[const a 0] [return a]] []])

\\ Code objects.
(native-test.raw "too short" [code f])
(native-test.raw "not code" [frob f 0 4 [] [] []])
(native-test.raw "a frame too small" [code f 1 2 [1] [[return [const 0]]] []])
(native-test.raw "an arity not a number" [code f a 4 [1] [[return [const 0]]] []])
(native-test.raw "named as nested code" [code lambda 1 4 [1] [[return [const 0]]] []])
(native-test.raw "an inline body" [code f 0 4 [1] [[return [const 0]]] [] [[x] y]])
(native-test.raw "an entry not above the arity" [code f 1 5 [] [[entry 1 0] [return 2] [label 0] [return 2]] []])
(native-test.raw "an entry not first" [code f 1 5 [] [[move 3 2] [entry 2 0] [return 3] [label 0] [return 2]] []])
(native-test.raw "an entry past the frame" [code f 1 3 [] [[entry 5 0] [return 2] [label 0] [return 2]] []])
(native-test.refused "redefines a sealed function" (freeze (shen-jit.install-code [defun reverse [code reverse 0 3 [1] [[return [const 0]]] []]])))

\\ Through the builder.
(native-test.refused "an unset name" (freeze (define-native native-test.bad (X) (return Y))))
(native-test.refused "an unset name on one path"
  (freeze (define-native native-test.bad (X)
            (prim T cons? X) (jump-if-false T l) (move Y 1) (label l) (return Y))))
(native-test.refused "no such label" (freeze (define-native native-test.bad () (jump nowhere))))
(native-test.refused "a label twice"
  (freeze (define-native native-test.bad () (jump l) (label l) (label l) (return 1))))
(native-test.refused "a name twice" (freeze (define-native native-test.bad (X X) (return X))))
(native-test.refused "a call of a variable with two arguments"
  (freeze (define-native native-test.bad (F) (call R F 1 2) (return R))))
(native-test.refused "a call of a primitive" (freeze (define-native native-test.bad (X) (call R hd X) (return R))))
(native-test.refused "an unknown instruction" (freeze (define-native native-test.bad () (add A B))))
(native-test.refused "a form as an operand" (freeze (define-native native-test.bad () (return (hd X)))))
(native-test.refused "a symbol as a destination" (freeze (define-native native-test.bad () (move r 1) (return 1))))
(native-test.refused "no return" (freeze (define-native native-test.bad () (move X 1))))
(native-test.refused "a capture unset" (freeze (define-native native-test.bad () (closure F () (A) (return A)) (return F))))
(native-test.refused "a closure of two" (freeze (define-native native-test.bad () (closure F (A B) () (return A)) (return F))))
(native-test.refused "a closure's variable not captured"
  (freeze (define-native native-test.bad (X) (closure F () () (return X)) (return F))))
(native-test.refused "a handler's code outside the handler around it"
  (freeze (define-native native-test.bad (X)
            (push-handler outer) (push-handler inner) (prim R hd X) (pop-handler) (pop-handler) (return R)
            (label inner) (pop-handler) (return X)
            (label outer) (return X))))
(native-test.refused "a backward jump" (freeze (define-native native-test.bad () (label l) (jump l))))
(native-test.refused "none of those was installed" (freeze ((fn native-test.bad))))
(native-test.refused "redefines a sealed function, built" (freeze (define-native reverse () (return 1))))

\\ ---------------------------------------------------------------------------
\\ Real registers.

\\ The loop instruction: what comes before it runs once, a register keeps its value round the
\\ loop, and a slot read for a number takes an integer as well as a real.
(define-native native-test.real-sum (B I End Start)
  (real Acc Start)
  (loop)
  (prim T >= I End)
  (jump-if-false T more)
  (return-real Acc)
  (label more)
  (real Acc (+ Acc (f64 B I)))
  (prim I + I 8)
  (tail-call native-test.real-sum B I End Start))

(set native-test.reals (shen-jit.bytes 24))
(shen-jit.f64! (value native-test.reals) 0 1.5)
(shen-jit.f64! (value native-test.reals) 8 2.5)
(shen-jit.f64! (value native-test.reals) 16 0.25)
(native-test.check "a loop on a buffer" 4.25 (freeze (native-test.real-sum (value native-test.reals) 0 24 0)))
(native-test.check "from a real" 4.75 (freeze (native-test.real-sum (value native-test.reals) 0 24 0.5)))
(native-test.check "no times round gives what it started with, boxed" 2.5 (freeze (native-test.real-sum (value native-test.reals) 0 0 2.5)))
(native-test.check "it is a real" true (freeze (number? (native-test.real-sum (value native-test.reals) 0 0 2))))
(native-test.check "not a number" [error "a is not a number"]
  (freeze (native-test.result (freeze (native-test.real-sum (value native-test.reals) 0 24 a)))))
(native-test.check "past the end" [error "bytes: 32 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.real-sum (value native-test.reals) 32 40 0)))))
(native-test.check "not memory" error
  (freeze (hd (native-test.result (freeze (native-test.real-sum "abc" 0 8 0))))))

\\ Each operation, nested, with literals and slots among them.
(define-native native-test.real-ops (A B)
  (real X A)
  (real Y B)
  (real R (- (/ (* (+ X Y) 2) Y) (sqrt (abs (neg X)))))
  (return-real R))
(native-test.check "arithmetic" 4 (freeze (native-test.real-ops 4 2)))

\\ What is on both sides, written after it is read.
(define-native native-test.real-same (A)
  (real X A)
  (real X (+ (* X X) X))
  (real X (- X (* X 0.5)))
  (return-real X))
(native-test.check "a register read in what writes it" 6 (freeze (native-test.real-same 3)))

(define-native native-test.real-many (A B)
  (real X (+ A B 1 2.5))
  (real Y (* A B 2))
  (return-real (+ X Y)))
(native-test.check "several operands, from slots" 25.5 (freeze (native-test.real-many 2 4)))

(define-native native-test.real-divide (A B)
  (real X A)
  (real Y B)
  (return-real (/ X Y)))
(native-test.check "division by zero gives infinity" true (freeze (> (native-test.real-divide 1 0) 1e300)))

\\ An index in arithmetic, and a store.
(define-native native-test.real-store (B I X)
  (real V X)
  (f64! B (* (+ I 1) 8) (+ V 1))
  (return-real (f64 B (* (+ I 1) 8))))
(native-test.check "a store, and an index worked out" 3.5 (freeze (native-test.real-store (shen-jit.bytes 16) 0 2.5)))
(native-test.check "a store past the end" [error "bytes: 16 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.real-store (shen-jit.bytes 16) 1 2.5)))))

\\ Each comparison, NaN making each one false.
(define-native native-test.real-lt (A B) (jump-unless (< A B) no) (return yes) (label no) (return no))
(define-native native-test.real-gt (A B) (jump-unless (> A B) no) (return yes) (label no) (return no))
(define-native native-test.real-le (A B) (jump-unless (<= A B) no) (return yes) (label no) (return no))
(define-native native-test.real-ge (A B) (jump-unless (>= A B) no) (return yes) (label no) (return no))
(define-native native-test.real-eq (A B) (jump-unless (= A B) no) (return yes) (label no) (return no))

(define native-test.compare-all
  A B -> [(native-test.real-lt A B) (native-test.real-gt A B) (native-test.real-le A B)
          (native-test.real-ge A B) (native-test.real-eq A B)])

(set native-test.nan (let I (* 1e300 1e300) (- I I)))
(native-test.check "below" [yes no yes no no] (freeze (native-test.compare-all 1.5 2)))
(native-test.check "above" [no yes no yes no] (freeze (native-test.compare-all 2 1.5)))
(native-test.check "equal" [no no yes yes yes] (freeze (native-test.compare-all 2 2)))
(native-test.check "NaN" [no no no no no] (freeze (native-test.compare-all (value native-test.nan) 1)))
(native-test.check "a comparison raises on what is no number" [error "a is not a number"]
  (freeze (native-test.result (freeze (native-test.real-lt a 1)))))

\\ What calls C or collects keeps them: boxes that allocate, a primitive that calls C and
\\ allocates, and an = that calls C and does not.
(define-native native-test.real-keep (N Acc)
  (real X 0)
  (real Y 100)
  (loop)
  (prim T = N 0)
  (jump-if-false T more)
  (return Acc)
  (label more)
  (real X (+ X 1))
  (real Y (- Y 1))
  (real-box A X)
  (real-box B Y)
  (prim S str N)
  (prim S2 str N)
  (prim E = S S2)
  (jump-if-false E fail)
  (prim P + A B)
  (prim Acc + Acc P)
  (prim N - N 1)
  (tail-call native-test.real-keep N Acc)
  (label fail)
  (return fail))
(native-test.check "kept across C and collections" 20000 (freeze (native-test.real-keep 200 0)))

\\ All twelve, for a square root whose registers an instruction encodes in extra bits.
(define-native native-test.real-twelve (A)
  (real R0 A)
  (real R1 (+ R0 1))
  (real R2 (+ R1 1))
  (real R3 (+ R2 1))
  (real R4 (+ R3 1))
  (real R5 (+ R4 1))
  (real R6 (+ R5 1))
  (real R7 (+ R6 1))
  (real R8 (+ R7 1))
  (real R9 (+ R8 1))
  (real R10 (sqrt (* R9 R9)))
  (real R0 (sqrt R10))
  (real R10 (sqrt R1))
  (real R0 (+ R0 R10 R2 R3 R4 R5 R6 R7 R8))
  (return-real R0))
(native-test.check "every register, and a root in each" true
  (freeze (let V (native-test.real-twelve 3)
            (and (> V 61.46) (< V 61.47)))))

(native-test.refused "an unknown instruction among them"
  (freeze (define-native native-test.bad (A) (real X A) (call-result R F) (return-real X))))

\\ What must be refused.
(native-test.refused "a call" (freeze (define-native native-test.bad (A) (real X A) (call R reverse A) (return-real X))))
(native-test.refused "a call of a value" (freeze (define-native native-test.bad (F) (real X 1) (call R F 1) (return-real X))))
(native-test.refused "a handler"
  (freeze (define-native native-test.bad (A) (push-handler h) (real X A) (pop-handler) (return-real X) (label h) (return A))))
(native-test.refused "a register unset" (freeze (define-native native-test.bad (A) (real X (+ Y 1)) (real Y 1) (return-real X))))
(native-test.refused "a register set on one path"
  (freeze (define-native native-test.bad (A) (jump-if-false A l) (real X 1) (label l) (return-real X))))
(native-test.refused "a register as a slot" (freeze (define-native native-test.bad (A) (real X A) (prim Y + X 1) (return Y))))
(native-test.refused "a register as memory" (freeze (define-native native-test.bad (A) (real X A) (real Y (f64 X 0)) (return-real Y))))
(native-test.refused "two loops" (freeze (define-native native-test.bad () (real X 1) (loop) (loop) (return-real X))))
(native-test.refused "a jump before the loop"
  (freeze (define-native native-test.bad (A) (jump-if-false A l) (label l) (loop) (return A))))
(native-test.refused "a comparison before the loop"
  (freeze (define-native native-test.bad (A) (jump-unless (< A 1) l) (label l) (loop) (return A))))
(native-test.refused "a slot from before the loop that it also writes"
  (freeze (define-native native-test.bad (A)
            (prim K + A 1)
            (loop)
            (prim T = K 0)
            (jump-if-false T more)
            (return A)
            (label more)
            (prim K + K 1)
            (tail-call native-test.bad A))))
(native-test.refused "not a real expression" (freeze (define-native native-test.bad (A) (real X (foo A)) (return-real X))))
(native-test.refused "not a comparison" (freeze (define-native native-test.bad (A) (jump-unless (foo A A) l) (label l) (return A))))
(native-test.refused "more registers than there are"
  (freeze (define-native native-test.bad (A)
            (real R0 A) (real R1 A) (real R2 A) (real R3 A) (real R4 A) (real R5 A) (real R6 A) (real R7 A)
            (real R8 A) (real R9 A) (real R10 A) (real R11 A) (real R12 A) (real R13 A) (real R14 A) (real R15 A)
            (real R16 A) (real R17 A) (real R18 A) (real R19 A) (real R20 A) (real R21 A) (real R22 A) (real R23 A)
            (real R24 A) (real R25 A) (real R26 A) (real R27 A) (real R28 A) (real R29 A) (real R30 A) (real R31 A)
            (real R32 A) (real R33 A) (real R34 A) (real R35 A) (real R36 A) (real R37 A) (real R38 A) (real R39 A)
            (real R40 A) (real R41 A) (real R42 A) (real R43 A) (real R44 A) (real R45 A) (real R46 A) (real R47 A)
            (real R48 A) (return-real R48))))
(native-test.raw "a register out of range" [code native-test.bad 0 3 [0] [[real-number 48 [const 0]] [return [const 0]]] []])
(native-test.raw "a negative register" [code native-test.bad 0 3 [0] [[real-number -1 [const 0]] [return [const 0]]] []])
(native-test.raw "a slot for a register" [code native-test.bad 0 3 [0] [[real-box 2 2] [return 2]] []])
(native-test.raw "a label that is not there" [code native-test.bad 0 3 [0] [[real-number 0 [const 0]] [real-unless< 0 0 9] [return [const 0]]] []])
(native-test.raw "a load into nothing" [code native-test.bad 1 4 [0] [[real-load 48 2 [const 0]] [return 2]] []])
(native-test.raw "a store of nothing" [code native-test.bad 1 4 [0] [[real-store 2 [const 0] 0] [return 2]] []])
(native-test.refused "none of those was installed, again" (freeze ((fn native-test.bad))))

\\ More real registers than the machine gives: those live in the native frame, and work the same.
(define-native native-test.real-many-more (A)
  (real R0 A) (real R1 (+ R0 1)) (real R2 (+ R1 1)) (real R3 (+ R2 1)) (real R4 (+ R3 1))
  (real R5 (+ R4 1)) (real R6 (+ R5 1)) (real R7 (+ R6 1)) (real R8 (+ R7 1)) (real R9 (+ R8 1))
  (real R10 (+ R9 1)) (real R11 (+ R10 1)) (real R12 (+ R11 1)) (real R13 (+ R12 1)) (real R14 (+ R13 1))
  (real R15 (sqrt (* R14 R14)))
  (real R16 (/ (neg R15) 2))
  (jump-unless (< R16 R0) wrong)
  (real-box A1 R15)
  (prim S str A1)
  (return-real (+ R0 R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15 R16))
  (label wrong)
  (return wrong))
(native-test.check "more registers than the machine's" 127.5 (freeze (native-test.real-many-more 1)))

\\ ---------------------------------------------------------------------------
\\ Word registers.

\\ Each operation, on what fits a fixnum so that it can come back.
(define-native native-test.word-ops (A B)
  (word X A)
  (word Y B)
  (word S (+ X Y))
  (word D (- X Y))
  (word M (* X Y))
  (word N (neg X))
  (return-word (+ (* S 1000000) (* D 10000) (* M 100) N)))
(native-test.check "arithmetic" 15093588 (freeze (native-test.word-ops 12 3)))

(define-native native-test.word-bits (A B)
  (word X A)
  (word Y B)
  (word Result (bit-xor (bit-or (bit-and X Y) (shift-left Y 8)) (shift-right X 2)))
  (return-word Result))
(native-test.check "and, or, xor, shifts" 3843 (freeze (native-test.word-bits 60 15)))

(define-native native-test.word-not (A)
  (word X A)
  (return-word (bit-not X)))
(native-test.check "not" -1 (freeze (native-test.word-not 0)))
(native-test.check "not of one" -2 (freeze (native-test.word-not 1)))

(define-native native-test.word-rotate (A N)
  (word X A)
  (word R (rotate-right (rotate-left X N) N))
  (return-word R))
(native-test.check "rotate there and back" 1234 (freeze (native-test.word-rotate 1234 13)))

(define-native native-test.word-signed (A N)
  (word X A)
  (return-word (shift-right-signed X N)))
(native-test.check "a signed shift" -2 (freeze (native-test.word-signed -8 2)))

\\ Wraparound: past 64 bits nothing raises. 2^63 + 2^63 is 0.
(define-native native-test.word-wrap (A)
  (word X (shift-left 1 63))
  (word Y (+ X X A))
  (return-word Y))
(native-test.check "addition wraps" 5 (freeze (native-test.word-wrap 5)))

\\ What does not fit a fixnum raises when it comes back, and only then.
(define-native native-test.word-big (N)
  (word X (shift-left 1 N))
  (return-word X))
(native-test.check "2^60 fits" 1152921504606846976 (freeze (native-test.word-big 60)))
(native-test.check "2^61 does not" error (freeze (hd (native-test.result (freeze (native-test.word-big 61))))))
(native-test.check "nor does 2^63" error (freeze (hd (native-test.result (freeze (native-test.word-big 63))))))
(native-test.check "and it says what" [error "the word 2305843009213693952 does not fit in an integer"]
  (freeze (native-test.result (freeze (native-test.word-big 61)))))
(define-native native-test.word-small (N)
  (word X (neg (shift-left 1 N)))
  (return-word X))
(native-test.check "-2^61 fits" -2305843009213693952 (freeze (native-test.word-small 61)))
(native-test.check "-2^62 does not" error (freeze (hd (native-test.result (freeze (native-test.word-small 62))))))

\\ A slot read as a word must be an integer.
(define-native native-test.word-of (A)
  (word X A)
  (return-word X))
(native-test.check "from a slot" -7 (freeze (native-test.word-of -7)))
(native-test.check "not an integer" [error "1.5 is not an integer"] (freeze (native-test.result (freeze (native-test.word-of 1.5)))))
(native-test.check "nor is a symbol" [error "a is not an integer"] (freeze (native-test.result (freeze (native-test.word-of a)))))

\\ Between words and reals.
(define-native native-test.word-real (A)
  (word X A)
  (real R (* X 0.5))
  (return-real R))
(native-test.check "a word in a real expression" 1.5 (freeze (native-test.word-real 3)))

(define-native native-test.real-word (A)
  (real R A)
  (word X (truncate (* R 2)))
  (return-word X))
(native-test.check "truncate" 3 (freeze (native-test.real-word 1.75)))
(native-test.check "truncate, toward zero" -3 (freeze (native-test.real-word -1.75)))

\\ Each comparison, and that unsigned sees -1 as the largest.
(define-native native-test.word-lt (A B) (word X A) (word Y B) (jump-unless-word (< X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-gt (A B) (word X A) (word Y B) (jump-unless-word (> X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-le (A B) (word X A) (word Y B) (jump-unless-word (<= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ge (A B) (word X A) (word Y B) (jump-unless-word (>= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-eq (A B) (word X A) (word Y B) (jump-unless-word (= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ult (A B) (word X A) (word Y B) (jump-unless-word (u< X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ugt (A B) (word X A) (word Y B) (jump-unless-word (u> X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ule (A B) (word X A) (word Y B) (jump-unless-word (u<= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-uge (A B) (word X A) (word Y B) (jump-unless-word (u>= X Y) no) (return yes) (label no) (return no))

(define native-test.word-compare
  A B -> [(native-test.word-lt A B) (native-test.word-gt A B) (native-test.word-le A B) (native-test.word-ge A B)
          (native-test.word-eq A B)])
(define native-test.word-unsigned
  A B -> [(native-test.word-ult A B) (native-test.word-ugt A B) (native-test.word-ule A B) (native-test.word-uge A B)])
(native-test.check "below" [yes no yes no no] (freeze (native-test.word-compare -1 2)))
(native-test.check "above" [no yes no yes no] (freeze (native-test.word-compare 2 -1)))
(native-test.check "equal" [no no yes yes yes] (freeze (native-test.word-compare 2 2)))
(native-test.check "unsigned, -1 is the largest" [no yes no yes] (freeze (native-test.word-unsigned -1 2)))
(native-test.check "unsigned, equal" [no no yes yes] (freeze (native-test.word-unsigned 2 2)))

\\ A constant on either side, and in a loop, whose register keeps its value round it.
(define-native native-test.word-loop (N Start)
  (word Acc Start)
  (word I 0)
  (loop)
  (jump-unless-word (< I N) done)
  (word Acc (+ Acc (* I 2)))
  (word I (+ I 1))
  (tail-call native-test.word-loop N Start)
  (label done)
  (return-word Acc))
(native-test.check "a loop" 90 (freeze (native-test.word-loop 10 0)))
(native-test.check "from a start" 95 (freeze (native-test.word-loop 10 5)))
(native-test.check "no times round" 5 (freeze (native-test.word-loop 0 5)))

\\ FNV-1a on bytes, whose value is known: 64 bits that wrap on each multiplication. Neither the
\\ offset basis nor the result is a fixnum, so the result goes to memory, read back in halves.
(define-native native-test.word-fnv (B Out End)
  (word Prime 1099511628211)
  (word Hash (+ (* 3421674724 4294967296) 2216829733))
  (word I 0)
  (loop)
  (jump-unless-word (u< I End) done)
  (word Hash (* (bit-xor Hash (u8 B I)) Prime))
  (word I (+ I 1))
  (tail-call native-test.word-fnv B Out End)
  (label done)
  (u64! Out 0 Hash)
  (return Out))

(define native-test.word-fnv-of
  S -> (let B (shen-jit.string->bytes S)
            Out (native-test.word-fnv B (shen-jit.bytes 8) (shen-jit.bytes-length B))
         [(shen-jit.u32 Out 4) (shen-jit.u32 Out 0)]))
(native-test.check "FNV-1a of nothing" [3421674724 2216829733] (freeze (native-test.word-fnv-of "")))
(native-test.check "FNV-1a of a" [2942557260 2248273036] (freeze (native-test.word-fnv-of "a")))
(native-test.check "FNV-1a of foobar" [2241085809 4147734504] (freeze (native-test.word-fnv-of "foobar")))

\\ Every width, at a word index, each checked against the length.
(define-native native-test.word-widths (M)
  (word I 8)
  (u64! M I 513)
  (word A (u8 M I))
  (word B (u16 M I))
  (word C (u32 M I))
  (word D (u64 M I))
  (u8! M 0 255)
  (u16! M 2 65535)
  (u32! M 4 -1)
  (word E (s32 M 4))
  (word F (u32 M 4))
  (word G (u16 M 2))
  (word H (u8 M 0))
  (return-word (+ A (* B 1000) (* C 10000000) (* D 100000000000) E (* F 10) (* G 100) (* H 3))))
(native-test.check "each width" 51348086740215 (freeze (native-test.word-widths (shen-jit.bytes 16))))

\\ Bounds: a word index has no tag to fail on, so each way round must be caught here.
(define-native native-test.word-at (M I)
  (word X I)
  (return-word (u64 M X)))
(define-native native-test.byte-at (M I)
  (word X I)
  (return-word (u8 M X)))
(define-native native-test.store-at (M I)
  (word X I)
  (u64! M X 1)
  (return M))
(define-native native-test.real-at (M I)
  (word X I)
  (return-real (f64 M X)))
(define-native native-test.real-store-at (M I)
  (word X I)
  (f64! M X 1.5)
  (return M))

(define native-test.bytes8
  -> (shen-jit.u32! (shen-jit.bytes 16) 8 7))
(native-test.check "the last place for 8 bytes" 7 (freeze (native-test.word-at (native-test.bytes8) 8)))
(native-test.check "past it" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.word-at (native-test.bytes8) 9)))))
(native-test.check "the last byte" 0 (freeze (native-test.byte-at (native-test.bytes8) 15)))
(native-test.check "past it, by bytes" [error "bytes: 16 is not a valid index"] (freeze (native-test.result (freeze (native-test.byte-at (native-test.bytes8) 16)))))
(native-test.check "a negative index" [error "bytes: -1 is not a valid index"] (freeze (native-test.result (freeze (native-test.word-at (native-test.bytes8) -1)))))
(native-test.check "one that adds up small" [error "bytes: -7 is not a valid index"] (freeze (native-test.result (freeze (native-test.word-at (native-test.bytes8) -7)))))
(native-test.check "a negative index, by bytes" [error "bytes: -1 is not a valid index"] (freeze (native-test.result (freeze (native-test.byte-at (native-test.bytes8) -1)))))
(native-test.check "a store past the end" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.store-at (native-test.bytes8) 9)))))
(native-test.check "a store before the start" [error "bytes: -8 is not a valid index"] (freeze (native-test.result (freeze (native-test.store-at (native-test.bytes8) -8)))))
(native-test.check "a real past the end" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.real-at (native-test.bytes8) 9)))))
(native-test.check "a real before the start" [error "bytes: -1 is not a valid index"] (freeze (native-test.result (freeze (native-test.real-at (native-test.bytes8) -1)))))
(native-test.check "a real store past the end" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.real-store-at (native-test.bytes8) 9)))))
(native-test.check "a real read" 1.5 (freeze (native-test.real-at (native-test.real-store-at (shen-jit.bytes 16) 8) 8)))
(native-test.check "not memory" error (freeze (hd (native-test.result (freeze (native-test.word-at "abc" 0))))))
(native-test.check "not a pointer with a length" error (freeze (hd (native-test.result (freeze (native-test.word-at a 0))))))

\\ What the word index works out in words, when it mentions one, and in prim otherwise.
(define-native native-test.index-kinds (M I)
  (word X I)
  (real A (f64 M (+ X 8)))
  (real B (f64 M (+ I 8)))
  (return-real (+ A B)))
(native-test.check "either way of working out an index" 3 (freeze (native-test.index-kinds (shen-jit.f64! (shen-jit.bytes 16) 8 1.5) 0)))

\\ What calls C or collects keeps word registers, in the registers and out of them.
(define-native native-test.word-keep (N Acc)
  (word A 1) (word B 2) (word C 3) (word D 4) (word E 5) (word F 6) (word G 7) (word H 8)
  (word I 9) (word J 10) (word K 11) (word L 12) (word M 13)
  (loop)
  (prim T = N 0)
  (jump-if-false T more)
  (return-word (+ A B C D E F G H I J K L M))
  (label more)
  (word A (+ A 1))
  (word M (+ M 1))
  (word-box S A)
  (real-box R A)
  (prim Text str N)
  (prim N - N 1)
  (tail-call native-test.word-keep N Acc))
(native-test.check "kept across C and collections" 491 (freeze (native-test.word-keep 200 0)))

\\ ---------------------------------------------------------------------------
\\ Memory in a loop, whose base and length are worked out on the way in: ordinary code gets this
\\ as code with registers does, and it must never read what has gone stale.

\\ A buffer moves when the loop's own allocation collects, which GC stress makes often.
(define native-test.cached-sum
  B I N Acc Junk -> [Acc | (length Junk)] where (>= I N)
  B I N Acc Junk -> (native-test.cached-sum B (+ I 1) N (+ Acc (shen-jit.u8 B I)) [I | Junk]))

(define native-test.counting-bytes
  N -> (native-test.fill-counting (shen-jit.bytes N) 0 N))

(define native-test.fill-counting
  B I N -> B where (>= I N)
  B I N -> (native-test.fill-counting (shen-jit.u8! B I (shen-jit.bit-and I 255)) (+ I 1) N))

(native-test.check "a buffer read as it moves" [31872 | 256]
  (freeze (native-test.cached-sum (native-test.counting-bytes 256) 0 256 -768 [])))

(define-native native-test.cached-registers (B N Junk)
  (word I 0)
  (word Acc 0)
  (loop)
  (jump-unless-word (< I N) done)
  (word Acc (+ Acc (u8 B I)))
  (word-box Boxed I)
  (prim Junk cons Boxed Junk)
  (word I (+ I 1))
  (tail-call native-test.cached-registers B N Junk)
  (label done)
  (return-word Acc))
(native-test.check "and in registers" 32640 (freeze (native-test.cached-registers (native-test.counting-bytes 256) 256 [])))

\\ Stores to a buffer that moves land in it.
(define native-test.cached-store
  B I N Junk -> B where (>= I N)
  B I N Junk -> (native-test.cached-store (shen-jit.u8! B I 7) (+ I 1) N [I | Junk]))
(native-test.check "a store as it moves" 7 (freeze (shen-jit.u8 (native-test.cached-store (shen-jit.bytes 64) 0 64 []) 63)))

\\ A parameter the loop changes is not the same memory each time round.
(define native-test.swapping
  A B 0 Acc -> Acc
  A B N Acc -> (native-test.swapping B A (- N 1) (+ (* Acc 10) (shen-jit.u8 A 0))))
(native-test.check "parameters that swap"
  1212
  (freeze (native-test.swapping (shen-jit.u8! (shen-jit.bytes 1) 0 1) (shen-jit.u8! (shen-jit.bytes 1) 0 2) 4 0)))

(define native-test.replacing
  M 0 Acc -> Acc
  M N Acc -> (native-test.replacing (shen-jit.u8! (shen-jit.bytes 1) 0 N) (- N 1) (+ Acc (shen-jit.u8 M 0))))
(native-test.check "a parameter replaced" 14 (freeze (native-test.replacing (shen-jit.u8! (shen-jit.bytes 1) 0 9) 3 0)))

\\ What is no memory is no error until it is used, and then says so.
(define native-test.maybe-read
  M I N Acc -> Acc where (>= I N)
  M I N Acc -> (native-test.maybe-read M (+ I 1) N (+ Acc (shen-jit.u8 M I))))
(native-test.check "not memory, and not read" 0 (freeze (native-test.maybe-read a 0 0 0)))
(native-test.check "not memory, and read" error (freeze (hd (native-test.result (freeze (native-test.maybe-read a 0 1 0))))))
(native-test.check "a string, and read" error (freeze (hd (native-test.result (freeze (native-test.maybe-read "abc" 0 1 0))))))
(native-test.check "past the end, in a loop" [error "bytes: 2 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.maybe-read (shen-jit.bytes 2) 0 3 0)))))

\\ Each width and store through the same memory.
(define native-test.widths-loop
  M I N Acc -> Acc where (>= I N)
  M I N Acc -> (do (shen-jit.u32! M 0 I)
                   (shen-jit.u16! M 4 I)
                   (shen-jit.u8! M 6 I)
                   (shen-jit.f64! M 8 1.5)
                   (native-test.widths-loop M (+ I 1) N
                     (+ Acc (shen-jit.u32 M 0) (shen-jit.u16 M 4) (shen-jit.u8 M 6) (shen-jit.s32 M 0) (shen-jit.f64 M 8)))))
(native-test.check "every width, round a loop" 16.5 (freeze (native-test.widths-loop (shen-jit.bytes 16) 0 3 0)))

\\ What must be refused.
(native-test.refused "a word unset" (freeze (define-native native-test.bad (A) (word X (+ Y 1)) (word Y 1) (return-word X))))
(native-test.refused "a word as a slot" (freeze (define-native native-test.bad (A) (word X A) (prim Y + X 1) (return Y))))
(native-test.refused "a real in a word expression" (freeze (define-native native-test.bad (A) (real R A) (word X (+ R 1)) (return-word X))))
(native-test.refused "both kinds under one name" (freeze (define-native native-test.bad (A) (real X A) (word X A) (return-word X))))
(native-test.refused "a fraction as a word" (freeze (define-native native-test.bad (A) (word X 1.5) (return-word X))))
(native-test.refused "not a word expression" (freeze (define-native native-test.bad (A) (word X (foo A)) (return-word X))))
(native-test.refused "not a comparison of words" (freeze (define-native native-test.bad (A) (word X A) (jump-unless-word (foo X X) l) (label l) (return A))))
(native-test.refused "a word with a call" (freeze (define-native native-test.bad (A) (word X A) (call R reverse A) (return-word X))))
(native-test.refused "more word registers than there are"
  (freeze (define-native native-test.bad (A)
            (word R0 A) (word R1 A) (word R2 A) (word R3 A) (word R4 A) (word R5 A) (word R6 A) (word R7 A)
            (word R8 A) (word R9 A) (word R10 A) (word R11 A) (word R12 A) (word R13 A) (word R14 A) (word R15 A)
            (word R16 A) (return-word R16))))
(native-test.raw "a word out of range" [code native-test.bad 0 3 [0] [[word-number 16 [const 0]] [return [const 0]]] []])
(native-test.raw "a word unset, by number" [code native-test.bad 0 3 [0] [[word-box 2 0] [return 2]] []])
(native-test.raw "a word store past the registers" [code native-test.bad 1 4 [0] [[word-store8 2 [const 0] 16] [return 2]] []])
(native-test.raw "a word test to nowhere" [code native-test.bad 0 3 [0] [[word-number 0 [const 0]] [word-unless< 0 0 9] [return [const 0]]] []])
(native-test.refused "none of those was installed, a third time" (freeze ((fn native-test.bad))))

(output "~A passed, ~A failed~%" (value native-test.*passed*) (value native-test.*failed*))
