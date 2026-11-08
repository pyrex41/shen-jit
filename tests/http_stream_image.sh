#!/bin/sh
set -eu
SHEN=$1
dir=$(mktemp -d)
trap 'stream_status=$?; if [ "$stream_status" -ne 0 ]; then cat "$dir"/*.out 2>/dev/null; fi; rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir"); fi
"$SHEN" --save "$dir/stream.img" eval -l lib/buffer.shen -l lib/io.shen -l lib/deadline.shen \
    -l lib/grammar.shen -l lib/http-head.shen -l lib/http-request.shen -l lib/http-response.shen \
    -e '(set stream-image.source (http.source (/. N D (error "saved next replayed")) (freeze (error "saved close replayed"))))' \
    > "$dir/save.out" 2>&1
SHEN_JIT_IMAGE="$dir/stream.img" "$SHEN" eval \
    -e '(output "stale: ~A~%" (trap-error (http.source-close (value stream-image.source)) (/. X (error-to-string X))))' \
    > "$dir/stale.out" 2>&1
grep -qxF 'stale: http: saved response sources must be recreated' "$dir/stale.out"
SHEN_JIT_IMAGE="$dir/stream.img" SHEN_JIT_GC_STRESS=1 "$SHEN" eval -l tests/http_stream_gc.shen > "$dir/gc.out" 2>&1
grep -qxF 'stream gc ok' "$dir/gc.out"
echo '2 passed, 0 failed'
