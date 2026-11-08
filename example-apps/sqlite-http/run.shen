\\ Run from the repository root; the kernel loader is used only to load source code.
(let Quiet (hush?)
     _ (hush +)
     _ (map (function load)
         ["lib/ffi.shen" "lib/socket.shen" "lib/sqlite.shen" "lib/buffer.shen" "lib/io.shen" "lib/json.shen"
          "lib/deadline.shen" "lib/clock.shen" "lib/io-socket.shen" "lib/http-head.shen"
          "lib/http-request.shen" "lib/http-response.shen" "lib/http-server.shen" "lib/http-listener.shen"
          "example-apps/sqlite-http/main.shen"])
     _ (set *hush* Quiet)
  (counter-app.main (value *argv*)))
