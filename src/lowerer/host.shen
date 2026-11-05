\\ Definitions the lowerer needs when it runs under another Shen (stage 0 and
\\ src/lowerer/check.shen run it under Shen/Scheme). In shen-jit these are
\\ primitives.

\\ Whether X is a symbol object. The kernel's portable symbol? also checks the
\\ characters of the name (it rejects :=), and ports override it differently,
\\ so the lowerer uses this exact test. Shen/Scheme's symbol? is exact.
(define shen-jit.symbol?
  X -> (symbol? X))

\\ Whether calls to F may be sealed, and F's inline body: stage 0 sets these
\\ tables from its input; elsewhere they are empty.
(define shen-jit.sealed?
  F -> (element? F (trap-error (value shen-jit.host.sealed) (/. E []))))

(define shen-jit.inline-body
  F -> (let Entry (assoc F (trap-error (value shen-jit.host.inline) (/. E [])))
         (if (cons? Entry) (tl Entry) [])))

\\ Stage 0 and the checker set both tables from the definitions they lower.
(define shen-jit.host.set-tables
  Defuns -> (do (set shen-jit.host.sealed (mapcan (/. D (shen-jit.host.name D)) Defuns))
                (set shen-jit.host.inline (mapcan (/. D (shen-jit.host.inline-entry D)) Defuns))))

(define shen-jit.host.name
  [defun F | _] -> [F]
  _ -> [])

(define shen-jit.host.inline-entry
  [defun F Params Body] -> (let Inline (shen-jit.lower.inline-form F Params Body)
                             (if (empty? Inline) [] [[F | Inline]]))
  _ -> [])
