# Bounded HTTP servers

[lib/http-listener.shen](../lib/http-listener.shen) runs the [HTTP request/response handler](http.md)
on bounded concurrent connections. It uses our own socket I/O, existing Shen threads and native waits;
it adds no runtime primitives or C adapter. Load it after the libraries needed by `http-server.shen`.
Native libraries are required, so this module is unavailable in static builds.

## Starting and stopping

```shen
(define example.handler
  Request -> (http.response 200 [["Content-Type" "text/plain"]] (buffer.from-string "hello")))

(let S (http.listen "127.0.0.1" 0 (function example.handler)
          [[max-connections 8] [shutdown-grace 1000] [body-limit 65536]])
     Port (http.port S)
     _ (http.stop S)
  [Port (http.wait S 3000)])
```

`http.listen Host Port Handler Options` binds before returning, starts a supervisor and gives an opaque
`http.server`. Port zero selects a free port; `http.port S` returns the actual port. Invalid options raise
before opening the listener. Bind or thread-start failure raises and closes any acquired socket.

The supervisor admits a connection only when a slot is free. Each admitted connection gets one worker
running `http.serve-one`, with its existing body/head/output limits, deadlines and cleanup. The connection
handles one request and closes. At capacity, new connections wait in the OS listener backlog; the server
does not allocate more worker state or send a speculative 503. Request deadlines start on admission.

`http.stop S` requests shutdown and returns true. It is idempotent and can be called from another task.
The supervisor stops accepting and closes the listener, then gives active requests their grace period.
After grace expires, it cancels the remaining socket operations and waits for worker cleanup. Already
completed workers are collected before deciding which connections remain active.

`http.wait S Milliseconds` waits within a separate nonnegative millisecond budget:

| Result | Meaning |
| --- | --- |
| `[ok]` | The listener is closed and every worker has published completion after cleanup |
| `[error Error]` | Shutdown finished after a listener/supervisor failure; Error retains cleanup failures |
| `[pending]` | The wait budget expired; the server and its workers still exist |

A zero budget polls. Waiting does not itself request shutdown. Repeated waits return the same final
result once complete. Ordinary malformed requests, handler exceptions and peer failures count as failed
connections; they do not stop admission or turn a normal server shutdown into a supervisor error.

Keep the main task alive until completion: the process exits when its main task ends. A caller receiving
`[pending]` must retain the server and decide when to wait again. Native servers saved in an image reload
stale; recreate them rather than trying to stop or resume a saved descriptor.

## Limits and observations

Options are `[Name Number]` pairs. They accept all the [one-request handler options](http.md#one-request-per-connection), plus:

| Option | Default | Range |
| --- | --- | --- |
| `max-connections` | 16 | 1..1024 workers |
| `shutdown-grace` | 1000 ms | 0..600000 ms |

Unknown, malformed and duplicate options raise. The connection cap bounds worker count; multiply the
configured body and response limits by that cap when choosing an application memory budget. Responses
and request metadata also occupy memory. This is concurrent I/O: ordinary Shen computation still shares
one runtime lock. No worker pool, general scheduler, channels or multicore execution are added.

`http.state S` reports `listening`, `draining`, `cancelling` or `stopped`. `http.stats S` returns one
consistent snapshot, in this order:

```text
[Active Accepted Completed Failed Cancelled Peak]
```

Completed includes failures. Cancelled counts connections targeted when grace expired, which can race
with their natural completion. Active can include a completed worker until the supervisor collects it.
Statistics retain counters, not an unbounded history of requests or exception messages. Peer/request
failures remain connection-local; use application logging when their individual details are needed.

## Cancellation and ownership

`io.socket-cancel Endpoint` publishes a permanent cancellation flag, including while its owner is
waiting. It is the only supported cross-task endpoint operation. It does not close a descriptor from
under another task, discard acknowledged bytes or clear a deadline. Subsequent nonempty backend I/O
returns an error with domain `cancelled`; partial transfer progress is preserved. The owning worker
alone closes its socket. Repeated cancellation, including after close, is harmless. Installing a new
deadline or removing a deadline does not undo cancellation. Do not use saved native endpoints after
loading an image.

The supervisor checks control/completion state around waits of at most 50 ms; socket waits check
cancellation around their existing poll slices of at most 100 ms. These are polling intervals, not hard
scheduling guarantees. Waiting releases the runtime lock and does not spin. A monotonic stop flag and
one completion publication per worker avoid a shared queue or read/modify/write counter race.

Cancellation is cooperative. It interrupts socket waiting, not an arbitrary Shen handler or blocking
database/foreign operation. After grace expires, a worker can remain in application work, and bounded
`http.wait` will report `[pending]`. Once that work returns, cancelled socket output fails and the worker
cleans up. Application resources must remain alive until the workers using them have completed. A peer
whose unfinished body is cancelled can observe EOF/reset; no extra HTTP rejection is fabricated.

## A complete application

[example-apps/sqlite-http](../example-apps/sqlite-http/README.md) contains a persistent counter API with
JSON responses, parameterized SQL, per-request database ownership and explicit local shutdown. Its
README gives launch commands, routes and the independent Python HTTP/SQLite test.

`make test-http` includes connection-cap, backlog, graceful response, partial cancellation, handler and
supervisor failure, typed-option, image and every-allocation GC cases, plus the counter application's
database tests. Native cases skip explicitly on static builds. Broader HTTP framing, streaming responses,
connection reuse, TLS and signal handling are separate work.
