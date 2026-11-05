\\ define-foreign in typed code, read under (tc +) by make test-ffi: a declaration with plain
\\ types can be used at once. The others are for a program to declare, under (tc -).

(shen-jit.library ffi-typed ["./ffi_test.so" "ffi_test.dll"])

(define-foreign typed-add ffi-typed "add64" (int64 int64) --> int64)
(define-foreign typed-yes ffi-typed "yes" () --> bool)
(define-foreign typed-length ffi-typed "length" (string) --> int64)

(define add-twice
  {number --> number}
  X -> (typed-add X (typed-add X 1)))

(define both
  {string --> number}
  S -> (if (typed-yes) (typed-length S) 0))

(define report
  {--> string}
  -> (trap-error (if (and (= (add-twice 2) 5) (= (both "12345") 5)) "2 passed, 0 failed" "0 passed, 2 failed")
                 (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                           "2 passed, 0 failed (a static build)"
                           (error-to-string E)))))

(output "~%~A~%" (report))
