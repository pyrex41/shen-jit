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

(output "~A passed, ~A failed~%" (value native-test.*passed*) (value native-test.*failed*))
