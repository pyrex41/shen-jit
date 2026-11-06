\\ THORN with its wall-clock limit taken away, for tests/thorn.sh and tests/bench/independent.py.
\\ Run in a copy of its directory, and with the standard library, which it needs. Under that
\\ limit its counts change with load.
(tc -)
(load "datatypes.shen")
(load "THORN20.shen")
(define thorn.defaults
  -> (do (set thorn.*depth* 20)
         (set thorn.*time-allowed* 1000000)
         (set thorn.*rewrite?* false)
         (set thorn.*complexity* -1)
         set))
(thorn.defaults)
