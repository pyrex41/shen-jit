\\ The kernel's benchmark suite and Shen/Scheme's realistic benchmarks, loaded
\\ from their sources with the ordinary load, as any Shen would. Run from the
\\ Shen/Scheme source directory with bench-offset (run counts are divided by
\\ 10 to that power) and bench-samples set. Prints one line per sample.
(set *hush* true)
\\ As the kernel's benchmarks/benchmarks.shen does.
(factorise +)
(load "benchmarks/port-harness.shen")
(load "benchmarks/port-adapter.shen")
(set *port-benchmarks* [])
(load "benchmarks/realistic/core.shen")
(load "benchmarks/realistic/analysis.shen")
(load "benchmarks/realistic/optimize.shen")
(load "benchmarks/realistic/compile.shen")
(load "benchmarks/realistic/vm.shen")
(load "benchmarks/realistic/main.shen")
\\ This resets the list, so it comes before the kernel's benchmarks.
(load "benchmarks/realistic-registrations.shen")
(load "benchmarks/port/data.shen")
(load "benchmarks/port/control-flow.shen")
(load "benchmarks/port/shen-compilation.shen")
(load "benchmarks/port/pattern-matching.shen")
(load "benchmarks/port/equality-check.shen")
(set *hush* false)
(port-bench.emit-header)
(port-bench.run-benchmarks (language) (value bench-offset) (value bench-samples))
