# HTTP clients with libcurl

`lib/curl.shen` provides synchronous HTTP and HTTPS requests with reusable clients, binary request
and response bodies, ordered response fields, timeouts and collection limits. It uses `buffer.view`
and the error/result types from our own [I/O library](io.md). It does not use Shen's kernel streams.

## Building and loading

The optional `lib/curl.c` adapter needs a C compiler and libcurl 7.68.0 or newer, including its
development headers. The runtime and its default image have no libcurl dependency.

```sh
# Debian/Ubuntu
sudo apt-get install libcurl4-openssl-dev pkg-config
make curl
```

macOS has the headers in its command line tools and a system libcurl. On Windows, use MSYS2's UCRT64
compiler, `mingw-w64-ucrt-x86_64-curl` and `mingw-w64-ucrt-x86_64-pkgconf`. The adapter and libcurl
must match the executable's architecture; the libcurl DLL and its dependencies must be discoverable
by Windows. Fully static Shen/JIT builds cannot load the adapter.

`make curl` writes `build/shen-curl.so` (`.dll` on Windows). A binary release carries the adapter's
source and build script, rather than a prebuilt adapter or bundled TLS libraries. From its root:

```sh
sh lib/build-curl.sh lib/shen-curl.so
# On Windows: sh lib/build-curl.sh lib/shen-curl.dll
```

The script uses `pkg-config libcurl`, then `curl-config`, then the compiler's default headers and
`-lcurl`. `CC`, `CFLAGS`, `CURL_CFLAGS` and `CURL_LIBS` override those choices. Loading Shen code never
invokes a compiler. Run from the installation or checkout root:

```sh
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/curl.shen \
  -e '(curl.version)'
```

The facade searches `./build/`, `./lib/` and the current directory for `shen-curl.so` and
`shen-curl.dll`. For another location, set `curl.*adapter-files*` to a list of absolute file names
before loading `lib/curl.shen`. Saved executables retain that declaration and need the adapter and
libcurl at runtime too. The adapter checks its own ABI and uses only the public `include/shen.h` API.

## Requests

`curl.get` opens and closes a client for one GET. `curl.fetch` does the same for another method.
`curl.with-client` scopes a reusable client; repeated `curl.request` calls on that client can reuse
connections, TLS state and DNS information. Request options, headers and body are reset each time.
[libcurl's reset contract](https://curl.se/libcurl/c/curl_easy_reset.html) preserves those caches.

```shen
(define web.get
  URL ->
    (curl.with-client
      (/. Client
        (curl.request Client "GET" URL [["Accept" "application/json"]] (buffer.new 0)
          [[body-limit 65536] [header-limit 16384] [timeout 5000] [connect-timeout 1000]]))))

(define web.status
  [ok Response] -> (curl.status Response)
  [error Error] -> (error "HTTP transfer: ~A" (io.error-message Error)))
```

Load these libraries before an application. JSON is optional:

```sh
build/shen-jit eval -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen -l lib/curl.shen \
  -l lib/json.shen -l client.shen
```

Methods are case-sensitive ASCII tokens of at most 32 bytes. GET and HEAD require an empty body.
Other methods send the supplied bytes, including NUL and bytes above 127. A view's selected range is
copied, whether its storage is managed or foreign; it must be live during the call. Headers are
ordered `[Name Value]` pairs. Repeated fields remain repeated; an empty value sends an explicitly
empty field. CR, LF, other control bytes and invalid names are rejected. libcurl owns request
framing: caller-supplied Content-Length and Transfer-Encoding are rejected.

Non-GET/HEAD requests get `Content-Type: application/octet-stream` unless a Content-Type is supplied.
For JSON, load `lib/json.shen` and encode explicitly:

```shen
(define web.post-json
  URL Value ->
    (curl.fetch "POST" URL [["Content-Type" "application/json"]] (json.encode Value [])
      [[request-limit 65536] [body-limit 65536] [timeout 5000]]))

(define web.decode-json
  [ok Response] -> (json.decode (curl.body Response) [])
  [error Error] -> (error "HTTP transfer: ~A" (io.error-message Error)))
```

HTTP statuses such as 404 and 500 return `[ok Response]`. Check `curl.status` for application policy.
DNS, connection, TLS, timeout and incomplete-body failures return `[error Error]`. Invalid arguments,
closed-client misuse, a missing adapter or failure to create a client raise. JSON decoding has its
own validation and limits; it is not implied by the Content-Type.

## Options and limits

Options are `[Name Value]` pairs. Unknown names, duplicates and malformed pairs raise. Numeric
values must be nonnegative fixnums in the ranges below; timeouts must be positive.

| Option | Default | Range and meaning |
| --- | --- | --- |
| `request-limit` | 1048576 | 0–268435456 bytes copied from the request body |
| `body-limit` | 1048576 | 0–268435456 response bytes accepted by body callbacks |
| `header-limit` | 65536 | 0–1048576 bytes accepted by header callbacks, including status lines, separators and trailers |
| `timeout` | 30000 | 1–2147483647 ms for the entire transfer, including redirects |
| `connect-timeout` | 5000 | 1–2147483647 ms for connection setup, within the total timeout |
| `redirect-limit` | 0 | 0 disables automatic redirects; 1–20 follows at most that many, for GET/HEAD only |
| `ca-file` | libcurl's default | Nonempty CA file path, at most 4096 bytes |
| `proxy` | libcurl's environment/defaults | Proxy URL, at most 8192 bytes; `""` disables proxies |

URLs must use HTTP or HTTPS, contain no NUL, and fit 8192 bytes. Outgoing headers have limits of
100 fields, 8192 bytes per encoded field and 65536 bytes in total, including the default Content-Type.
The response budgets count cumulatively across callbacks for the transfer, including intermediate
header blocks. A new response block does not renew a budget. The retained response contains the
final block and its body, with trailers separate.

These are payload collection limits, rather than a cap on process memory. The implementation copies
the request into native storage before transferring, grows native response buffers geometrically,
and copies the completed result into managed bytes. During conversion both copies exist. Raw fields
and parsed field strings also occupy memory, and libcurl maintains its own connection/TLS/DNS caches.

`CURLOPT_NOSIGNAL` is enabled. With a libcurl built around a synchronous resolver, DNS resolution
may outlast the configured timeout; a threaded resolver or c-ares avoids that limitation. See
[libcurl's threading guidance](https://curl.se/libcurl/c/threadsafe.html).

## Response values and errors

Response bytes are owned managed buffers. They survive later requests, client closure, collection
and image saving. Header names are ASCII lowercase; values are trimmed and repeated fields preserve
their order. Interim responses and redirect heads are excluded from the final field list. Trailers
have their own list and raw view.

| Function | Result |
| --- | --- |
| `(curl.status Response)` | Numeric HTTP status |
| `(curl.url Response)` | Effective URL after redirects |
| `(curl.body Response)` | Owned `buffer.view` |
| `(curl.headers Response)` | Ordered list of `[Name Value]` fields |
| `(curl.header-values Response Name)` | All matching ordinary field values, case-insensitively |
| `(curl.trailers Response)` | Ordered trailer fields, separate from ordinary fields |
| `(curl.raw-headers Response)` | Final raw header block, including status line and separator |
| `(curl.raw-trailers Response)` | Raw trailer bytes delivered by libcurl |
| `(curl.elapsed Response)` | libcurl's total elapsed time, truncated to milliseconds |
| `(curl.redirects Response)` | Number of followed redirects |

libcurl removes transfer framing such as chunk boundaries. Automatic content decompression is
disabled: the facade does not add Accept-Encoding, and an explicitly requested compressed
representation remains compressed in `curl.body`. The body limit therefore does not hide an
unbounded content-decoding step.

`io.error-operation` is `request`; `io.error-resource` is the original URL. Native transfer errors
retain the numeric CURLcode and libcurl's message. `io.error-domain` is `timeout` for CURLcode 28,
`limit` for a collection budget failure, otherwise `curl`. `io.error-progress` counts body bytes
accepted by callbacks before failure, across the transfer. It is not bytes durably saved and does
not include a rejected callback chunk. Failed transfers return no partial response body.

## TLS and redirects

Certificate and hostname verification are always enabled. `ca-file` adds an explicit trust file for
that request; it does not disable verification. No insecure option is exposed. Available TLS
backends, default trust stores, proxies and HTTP versions depend on the installed libcurl;
`curl.version` reports that installation.

Redirects are off by default. An opted-in GET or HEAD may follow HTTP/HTTPS, but an HTTPS starting
URL may redirect only to HTTPS. Non-GET/HEAD methods require the caller to inspect Location and make
another explicit request, so this API does not silently replay uploads or choose POST conversion
rules. Custom headers can be forwarded to redirect targets: enable redirects only with an
appropriate header policy. See [libcurl's header forwarding rules](https://curl.se/libcurl/c/CURLOPT_HTTPHEADER.html).

## Ownership and threads

`curl.open` returns a `curl.client`. `curl.close` returns `[ok]` or `[error Error]` and remembers its
completed result, making repeated closure safe. `curl.with-client` requires a callback returning
`[ok Value]` or `[error Error]`, closes after completion or an exception, and combines cleanup failures
using the I/O library's error convention. A manually opened client must be explicitly closed;
discarding it does not install a GC finalizer. Saved clients are stale and must be reopened on startup.

Use one client per simultaneous transfer. An overlapping request or close returns an error without
freeing or invalidating the active client. A completed transfer leaves it reusable after success or
failure. The VM lock is released during the network operation and native cleanup, allowing other
Shen threads to run. libcurl callbacks touch only native storage; Shen code runs after reacquisition.

The adapter initializes libcurl once and leaves global cleanup to process exit. With libcurl older
than 7.84.0, or a build without thread-safe global initialization, call `curl.version` or `curl.open`
before creating application threads. Its [global initialization contract](https://curl.se/libcurl/c/threadsafe.html)
applies to other native threads in an embedding host too.

## Downloader and tests

```sh
build/shen-jit script tools/curl-fetch.shen https://example.com/ page.html
make test-curl
```

The downloader collects at most 16 MiB, accepts only 2xx responses, then opens the destination through
`io.open-file` and writes with `io.write-all`. A network failure or non-2xx status leaves an existing
destination untouched. File write failures retain the I/O error and progress; writing is not atomic.
It is a bounded whole-response example, rather than a streaming sink.

Tests use an independent Python HTTP/TLS server on loopback and a temporary test CA generated with
the `openssl` command. They check binary bodies, connection reuse and option reset, redirects,
interim fields, trailers, partial responses, budgets, TLS rejection/trust, concurrent ownership,
typed clients, saved images, GC during transfers and the downloader. Static builds run the pure
validation checks and explicitly skip native transfers. `make test-san` also instruments the adapter
with AddressSanitizer and UBSan on shared-capable builds.

Streaming upload/download sinks, the multi interface, transfer cancellation, authentication helpers,
cookie persistence and multipart construction remain future work.
