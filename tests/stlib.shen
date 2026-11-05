\\ What make stlib's executable has to have: functions from each part of the
\\ standard library, and what stlib.initialise installs. Run by make test-stlib,
\\ from another directory, as a user would. It writes one file there.

(set stlib-test.*passed* 0)
(set stlib-test.*failed* 0)

(define stlib-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define stlib-test.check
  Name Expected F -> (stlib-test.compare Name Expected (stlib-test.result F)))

(define stlib-test.compare
  _ X X -> (set stlib-test.*passed* (+ 1 (value stlib-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set stlib-test.*failed* (+ 1 (value stlib-test.*failed*)))))

\\ The state stlib.initialise leaves.
(stlib-test.check "type checking is off" false (freeze (tc?)))
(stlib-test.check "the home directory is empty" "" (freeze (value *home-directory*)))
(stlib-test.check "arities" 2 (freeze (arity take)))
(stlib-test.check "the package's names" true (freeze (element? take (external stlib))))
(stlib-test.check "source metadata" true (freeze (cons? (ps take))))

\\ Each part.
(stlib-test.check "symbols" ab (freeze (concat* a b)))
(stlib-test.check "new variables" true (freeze (variable? (newv))))
(stlib-test.check "maths" 9 (freeze (sq 3)))
(stlib-test.check "primes" true (freeze (and (prime? 7) (not (prime? 8)))))
(stlib-test.check "rationals" true (freeze (r= (n->r 2) (n->r 2))))
(stlib-test.check "complex numbers" [4 6]
  (freeze (let C (c+ (c# 1 2) (c# 3 4)) [(real C) (imaginary C)])))
(stlib-test.check "numerals and their printer" "FF#16" (freeze (make-string "~A" (hex 255))))
(stlib-test.check "lists" [1 2] (freeze (take 2 [1 2 3])))
(stlib-test.check "strings" "cba" (freeze (string.reverse "abc")))
(stlib-test.check "string lists" "ab" (freeze (list->string (string->list "ab"))))
(stlib-test.check "vector macros" 7 (freeze (let V (vector 2) (do (V [1] := 7) (:= V [1])))))
(stlib-test.check "tuples" [(@p 1 a) (@p 2 b)] (freeze (pairoff [1 2] [a b])))
(stlib-test.check "files" "hello"
  (freeze (do (write-to-file "stlib-test.txt" "hello")
              (read-file-as-string "stlib-test.txt"))))

\\ Its types and datatypes, in code type checked as a user loads it: load decides
\\ when it starts, so a file has to be loaded with type checking already on.
(write-to-file "stlib-test.txt" "(define stlib-test.typed {complex --> number --> number} C N -> (+ (real (c+ C C)) (sq N)))")
(stlib-test.check "typed code" 11
  (freeze (do (tc +) (load "stlib-test.txt") (tc -) (stlib-test.typed (c# 1 2) 3))))
(write-to-file "stlib-test.txt" "(define stlib-test.ill {number --> complex} N -> (c+ N N))")
(stlib-test.check "ill-typed code is refused" refused
  (freeze (trap-error (do (tc +) (load "stlib-test.txt") accepted) (/. E (do (tc -) refused)))))

\\ Its names are system functions, which define refuses: stlib.initialise-final.
(stlib-test.check "its names are protected" true (freeze (shen.sysfunc? take)))

(output "~A passed, ~A failed (stlib)~%" (value stlib-test.*passed*) (value stlib-test.*failed*))
