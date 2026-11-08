\\ Bounded buffered download. Build the optional adapter with make curl first.
(let Quiet (hush?)
     _ (hush +)
     _ (map (function load) ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen" "lib/curl.shen"])
  (set *hush* Quiet))

(define curl-fetch.write-result
  [ok N] -> [ok N]
  [error Error _] -> [error Error])

(define curl-fetch.opened
  _ [error Error] -> [error Error]
  Body [ok E] ->
    (io.with-endpoint E (/. Out (curl-fetch.write-result (io.write-all Out Body [])))))

(define curl-fetch.response
  _ [error Error] -> [error Error]
  Path [ok R] ->
    (if (and (>= (curl.status R) 200) (< (curl.status R) 300))
        (curl-fetch.opened (curl.body R) (io.open-file Path write))
        [error (io.native-error download http (curl.status R) (curl.url R) "download requires a 2xx response")]))

(define curl-fetch.finished
  [ok N] -> (output "Saved ~A bytes~%" N)
  [error Error] -> (error "download: ~A (~A)" (io.error-message Error) (io.error-code Error)))

(define curl-fetch.main
  [_ URL Path] ->
    (curl-fetch.finished (curl-fetch.response Path (curl.get URL [[body-limit 16777216] [timeout 30000]])))
  _ -> (error "usage: shen-jit script tools/curl-fetch.shen URL FILE"))

(curl-fetch.main (value *argv*))
