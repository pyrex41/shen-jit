#!/bin/sh
# Differential tests of the primitives (tests/differential.shen). Each primitive runs in a process of its
# own, so that a crash names it, first as compiled and then with every primitive sent to C, and both
# must give the same results. Usage: differential.sh SHEN DIR [PRIMITIVE...]
shen=$1
dir=$2
shift 2
here=$(dirname "$0")
mkdir -p "$dir"
# A limit, so that a huge length is refused soon, in every run.
SHEN_JIT_MAX_HEAP=256M
export SHEN_JIT_MAX_HEAP

prims=${*:-"$("$shen" script "$here/differential.shen" --list | tr -d '\r')"}
failed=0
checks=0
for p in $prims properties; do
    name=$(printf '%s' "$p" | od -An -tx1 | tr -d ' \n')
    "$shen" script "$here/differential.shen" "$dir/$name.jit" "$p" > "$dir/$name.out" 2>&1
    rc=$?
    SHEN_JIT_SLOW_PRIMS=1 "$shen" script "$here/differential.shen" "$dir/$name.c" "$p" > "$dir/$name.cout" 2>&1
    rcc=$?
    summary=$(grep -a ' checks, ' "$dir/$name.out" | tail -1)
    bad=
    [ "$rc" = 0 ] && [ -n "$summary" ] || bad="exit $rc"
    [ "$rcc" = 0 ] && grep -aq ' checks, ' "$dir/$name.cout" || bad="$bad, through C exit $rcc"
    case $summary in *", 0 failed"*) ;; *) bad="$bad, $summary";; esac
    case $(grep -a ' checks, ' "$dir/$name.cout" | tail -1) in *", 0 failed"*) ;; *) bad="$bad, through C failures";; esac
    cmp -s "$dir/$name.jit" "$dir/$name.c" || bad="$bad, compiled and C differ"
    if [ -n "$bad" ]; then
        failed=$((failed + 1))
        echo "$p: $bad"
        grep -a '^FAIL' "$dir/$name.out" | head -5
        grep -a '^FAIL' "$dir/$name.cout" | head -5
        cmp -s "$dir/$name.jit" "$dir/$name.c" || diff -a "$dir/$name.jit" "$dir/$name.c" | grep -a '^[<>]' | head -6
    fi
    n=$(printf '%s\n' "$summary" | sed 's/ checks.*//')
    checks=$((checks + ${n:-0}))
done
echo "$checks checks, $failed primitives failed"
[ "$failed" = 0 ]
