\\ What the lowerer needs when it runs under a host, to make the stage 0 output
\\ (stage0.shen, check.shen). The host is a previous release of shen-jit or
\\ Shen/Scheme, and these work under both.
\\
\\ The tools load the lowerer as build/tools/lower.shen, which the Makefile makes
\\ with shen-jit.lower. changed to stage0.lower., as a host that is shen-jit has
\\ its own lowerer sealed under the real names. Its calls to shen-jit.sealed? and
\\ shen-jit.inline-body, primitives inside shen-jit, become the two below.

\\ Whether X is a symbol object. The kernel's portable symbol? also checks the
\\ characters of the name (it rejects :=), and ports override it differently,
\\ so the lowerer uses this exact test. In shen-jit it is a primitive, and
\\ sealed, so this definition is refused there. Shen/Scheme's symbol? is exact.
(trap-error (eval [define shen-jit.symbol? X -> [symbol? X]]) (/. E skip))

\\ Whether calls to F may be sealed, and F's inline body: stage 0 sets these
\\ tables from its input; elsewhere they are empty.
(define stage0.sealed?
  F -> (element? F (trap-error (value shen-jit.host.sealed) (/. E []))))

(define stage0.inline-body
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
  [defun F Params Body] -> (let Inline (stage0.lower.inline-form F Params Body)
                             (if (empty? Inline) [] [[F | Inline]]))
  _ -> [])

\\ Not every host has one.
(define stage0.filter
  _ [] -> []
  F [X | Xs] -> [X | (stage0.filter F Xs)] where (F X)
  F [_ | Xs] -> (stage0.filter F Xs))
