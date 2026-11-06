\\ The kernel's extension tests, run from a copy of its tests and extensions by make test-kernel and
\\ tests/bench/independent.py. One of them writes a file where it runs, which may be read-only, and
\\ then calls delete-file, which is not in the kernel: stlib defines it, as this does.
(define delete-file File -> (close (open File out)))
(load "tests/extensions/runme.shen")
