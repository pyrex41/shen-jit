\\ Compiles the lowerer (src/lowerer/lower.shen) to KLambda, as the kernel's
\\ make.shen does for kernel sources, so stage 0 can lower it with the kernel:
\\
\\   shen-scheme script src/lowerer/tokl.shen [OUT-FILE]
\\
\\ The default output is build/port/lower.kl.

\\ The host definitions give the Shen compiler the arities of the port
\\ primitives the lowerer calls, so calls to them compile as direct calls.
(load "src/lowerer/host.shen")

\\ The KLambda is printed with ~R, which would cut lists longer than this to
\\ "... etc": a function with more than 20 clauses would be lost.
(set *maximum-print-sequence-size* 100000)

(define shen-jit.tokl.main
  [_ Out | _] -> (shen-jit.tokl.run Out)
  _ -> (shen-jit.tokl.run "build/port/lower.kl"))

(define shen-jit.tokl.run
  Out -> (let Code (map (fn shen-jit.tokl.kl) (read-file "src/lowerer/lower.shen"))
              Text (shen-jit.tokl.text Code)
              Write (write-to-file Out Text)
           (output "~A definitions written to ~A~%" (length Code) Out)))

(define shen-jit.tokl.kl
  [define F | Rules] -> (shen.shendef->kldef F Rules)
  X -> (simple-error (make-string "tokl: unexpected top-level form ~R" X)))

(define shen-jit.tokl.text
  [] -> ""
  [X | Y] -> (@s (make-string "~R~%~%" X) (shen-jit.tokl.text Y)))

(shen-jit.tokl.main (value *argv*))
