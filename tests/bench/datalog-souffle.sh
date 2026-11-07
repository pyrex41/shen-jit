#!/bin/sh
# lib/datalog.shen against Soufflé, on the same rules and facts: results first, then time. It needs
# souffle and a C++ compiler, and is not part of any suite. Times are milliseconds, best of three: of
# datalog.run with facts as a list, and of Soufflé's process, reading facts and printing sizes, less the
# same process with no facts, which is its startup. Homebrew's bottle has no OpenMP, so one thread.
# Usage: tests/bench/datalog-souffle.sh SHEN_JIT [CASE ...]
SHEN=$1
shift
if ! command -v souffle > /dev/null; then
    echo "no souffle: nothing compared"
    exit 0
fi
# KEEP names a directory to leave the programs and facts in.
if [ -n "$KEEP" ]; then base=$KEEP; mkdir -p "$base"; else base=$(mktemp -d); trap 'rm -rf "$base"' EXIT; fi
# Soufflé generates the C++, and it is compiled here with the flags of its own souffle-compile.py,
# whose include paths in Homebrew's bottle fail: one misses its headers, another clashes with Xcode's.
INCLUDE=$(dirname "$(dirname "$(command -v souffle)")")/include/souffle
build_cpp() { # program, name
    souffle -F "$(dirname "$1")" -g "$2.cpp" "$1" &&
    c++ -std=c++17 -O3 -w -DRAM_DOMAIN_SIZE=64 -DUSE_NCURSES -DUSE_LIBZ -DUSE_SQLITE -I"$INCLUDE" "$2.cpp" -o "$2" -lz -lsqlite3 -lncurses
}
LIMIT=${LIMIT:-60}
CASES=${*:-closure-sparse closure-dense nonlinear same-generation mutual triangles skewed-join call-graph points-to-small-a points-to-small-b points-to-small-c points-to-large-a points-to-large-b points-to-large-c}
for c in closure-sparse closure-dense nonlinear same-generation mutual triangles skewed-join call-graph points-to-small-a points-to-small-b points-to-small-c points-to-large-a points-to-large-b points-to-large-c; do
    mkdir -p "$base/$c"
done
"$SHEN" eval -l lib/native.shen -l lib/datalog.shen -l tests/bench/datalog.shen -l tests/bench/datalog-orders.shen \
    -l tests/bench/datalog-souffle.shen -e "(sf.main \"$base\")" > "$base/ours.log" 2>&1 < /dev/null
if ! grep -aq '^OURS points-to-large-c' "$base/ours.log"; then
    tail -8 "$base/ours.log" | cut -c1-160
    exit 1
fi

now() { python3 -c 'import time; print(time.time())'; }

# Milliseconds of a command, best of three, or "over" if it passes the limit.
best() {
    b=""
    for i in 1 2 3; do
        s=$(now)
        if ! timeout -s KILL "$LIMIT" "$@" > /dev/null 2>&1; then
            echo over
            return
        fi
        e=$(now)
        b=$(python3 -c "t=($e-$s)*1000; b='$b'; print('%.1f' % (min(t,float(b)) if b else t))")
    done
    echo "$b"
}

printf '%-20s %9s %9s %9s %9s %9s %s\n' case ours compiled interpreted start build-ms results
for c in $CASES; do
    d=$base/$c
    ours=$(grep -a "^OURS $c " "$base/ours.log" | awk '{print $3}')
    mkdir -p "$d/out" "$d/empty"
    for f in "$d"/*.facts; do : > "$d/empty/$(basename "$f")"; done
    s=$(now)
    build_cpp "$d/time.dl" "$d/prog" > "$d/build.log" 2>&1
    e=$(now)
    build=$(python3 -c "print('%.0f' % (($e-$s)*1000))")
    build_cpp "$d/check.dl" "$d/check" > /dev/null 2>&1
    results=unchecked
    if timeout -s KILL "$LIMIT" "$d/check" -F "$d" -D "$d/out" > /dev/null 2>&1; then
        results=same
        for f in "$d"/*.ours; do
            r=$(basename "$f" .ours)
            sort "$f" > "$d/a"
            sort "$d/out/$r.csv" > "$d/b"
            cmp -s "$d/a" "$d/b" || results="DIFFER:$r"
        done
    fi
    start=$(best "$d/prog" -F "$d/empty")
    compiled=$(best "$d/prog" -F "$d")
    i0=$(best souffle -F "$d/empty" "$d/time.dl")
    interpreted=$(best souffle -F "$d" "$d/time.dl")
    net=$(python3 -c "print('over' if '$compiled'=='over' else '%.1f' % ($compiled-$start))")
    neti=$(python3 -c "print('over' if '$interpreted'=='over' else '%.1f' % ($interpreted-$i0))")
    printf '%-20s %9s %9s %9s %9s %9s %s\n' "$c" "$ours" "$net" "$neti" "$start" "$build" "$results"
done
