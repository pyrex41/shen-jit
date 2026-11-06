#!/bin/sh
# What a prover computes: THORN's verdicts and inference counts on problems from
# the kernel, with its wall-clock limit taken away, against tests/thorn.expected.
# Shen/Scheme gives the same, so a difference is a fault in lowering, the unifier or
# a primitive, or a new kernel. Usage: tests/thorn.sh path/to/shen-jit-stlib KERNEL_DIR
SHEN=$1
expected=$(cd "$(dirname "$0")" && pwd)/thorn.expected
dir=$(mktemp -d)
trap 'cd /; rm -rf "$dir"' EXIT
cp -R "$2/lib/thorn" "$dir/thorn"
cd "$dir/thorn" || exit 1
cat > setup.shen <<'SHEN'
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
SHEN
for problem in pelletier set L schubert ec groups dreadbury; do
    echo "$problem"
    "$SHEN" eval -l setup.shen -l "Problems/$problem.shen" -e '(output "finished~%")' 2>&1 |
        tr -d '\r' | grep -a -E ' inferences,|is unproved|^finished$' | sed 's/, equality.*//'
done > "$dir/got"
if [ -n "$UPDATE_THORN" ]; then
    cp "$dir/got" "$expected"
elif ! diff "$expected" "$dir/got"; then
    echo "thorn: differs from tests/thorn.expected"
    exit 1
fi
echo "thorn: $(grep -c inferences "$dir/got") problems match"
