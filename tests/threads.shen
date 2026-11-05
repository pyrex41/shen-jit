\\ Threads: (thread Frozen), run by tests/cli.sh. Each thread sets a global when it
\\ is done, and the main thread spins on it, as a program without join would.

(define wait-for
  Name Value -> Name where (= (value Name) Value)
  Name Value -> (wait-for Name Value))

\\ Compiled, and run, before any thread exists: the first thread must give it
\\ the loop check it was compiled without, or it would hold the lock for ever.
(set spin 1)
(wait-for spin 1)
(set spin 0)
(output "first ~A~%" (thread (freeze (set spin 1))))
(output "spin ~A~%" (wait-for spin 1))

\\ Tight loops that call nothing, side by side, with arguments in registers: a
\\ collection by another thread must find and update them.
(define count-up
  N N Acc -> Acc
  I N Acc -> (count-up (+ I 1) N [I | (tl Acc)]))
(define allocating
  0 -> done
  N -> (let Junk (count-up 0 100 [0]) (allocating (- N 1))))
(set loops 0)
(thread (freeze (do (allocating 2000) (set loops (+ (value loops) 1)))))
(thread (freeze (do (allocating 2000) (set loops (+ (value loops) 1)))))
(output "loops ~A~%" (wait-for loops 2))

\\ Deep recursion, whose stacks grow, with lists that collections move, in every
\\ thread at once, the main one included.
(define th-build
  0 -> []
  N -> [N | (th-build (- N 1))])
(define th-sum
  [] -> 0
  [X | Xs] -> (+ X (th-sum Xs)))
(define th-rounds
  0 Total -> Total
  N Total -> (th-rounds (- N 1) (+ Total (th-sum (th-build 20000)))))
(set deep 0)
(set deep-total 0)
(define deep-worker
  -> (let Total (th-rounds 3 0)
       (do (set deep-total (+ (value deep-total) Total))
           (set deep (+ (value deep) 1)))))
(thread (freeze (deep-worker)))
(thread (freeze (deep-worker)))
(thread (freeze (deep-worker)))
(deep-worker)
(wait-for deep 4)
(output "deep ~A~%" (value deep-total))

\\ Each thread has its own handlers: errors raised and caught while others do the
\\ same, in the same function.
(define catches
  0 Acc -> Acc
  N Acc -> (catches (- N 1) (+ Acc (trap-error (hd (tl [N])) (/. E 1)))))
(set caught 0)
(set caught-total 0)
(define catcher
  -> (let Total (catches 5000 0)
       (do (set caught-total (+ (value caught-total) Total))
           (set caught (+ (value caught) 1)))))
(thread (freeze (catcher)))
(thread (freeze (catcher)))
(catcher)
(wait-for caught 3)
(output "caught ~A~%" (value caught-total))

\\ An error nothing catches ends only its thread.
(set after 0)
(thread (freeze (do (set after 1) (error "boom in a thread"))))
(wait-for after 1)
(output "after-error ok~%")

\\ Compiling, defining and interning in a thread; a thread in a thread.
(set defined 0)
(thread (freeze (do (eval [define added-in-thread X -> [+ X 1]])
                    (thread (freeze (set defined (intern "from-a-thread")))))))
(wait-for defined from-a-thread)
(output "defined ~S~%" (added-in-thread 1))

\\ A function value, and one that wants arguments.
(set by-fn 0)
((fn thread) (freeze (set by-fn 1)))
(output "by-fn ~A~%" (wait-for by-fn 1))
(output "not-a-function ~A~%" (trap-error (thread 1) (/. E (error-to-string E))))

\\ Many at once, each with its own global.
(define start-many
  0 -> done
  N -> (let Name (intern (cn "many-" (str N)))
            Set (set Name 0)
            Start (thread (freeze (set Name 1)))
         (start-many (- N 1))))
(define wait-many
  0 -> done
  N -> (let Name (intern (cn "many-" (str N)))
            Wait (wait-for Name 1)
         (wait-many (- N 1))))
(start-many 64)
(output "many ~A~%" (wait-many 64))
