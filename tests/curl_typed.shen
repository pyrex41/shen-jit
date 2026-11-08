(define curl-typed.status
  {(io.result curl.response) --> number}
  [ok R] -> (let B (curl.body R)
                Fields (curl.headers R)
                Trailers (curl.trailers R)
                _ (buffer.length (curl.raw-headers R))
             (curl.status R))
  [error E] -> (io.error-code E))

(define curl-typed.request
  {curl.client --> string --> (io.result curl.response)}
  C URL -> (curl.request C "POST" URL [["Content-Type" "application/json"]]
             (buffer.from-string "{}") [[body-limit 4096] [timeout 1000] [proxy ""]]))

(define curl-typed.get
  {string --> (io.result curl.response)}
  URL -> (curl.with-client (/. C (curl.request C "GET" URL [] (buffer.new 0)
                                  [[connect-timeout 500] [header-limit 4096] [redirect-limit 1]]))))

(define curl-typed.run
  {string --> boolean}
  URL -> (= (curl-typed.status (curl.get URL [[proxy ""]])) 200))
