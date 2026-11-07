\\ One connected client, bounded frames, one flushed reply per frame.
\\ Load ffi.shen, socket.shen, buffer.shen, io.shen, io-socket.shen and frame.shen first.

(define frame-echo.serve
  E Limit ->
    (let Max (frame.limit Limit)
      (io.with-endpoint E
        (/. Connection
          (let F (frame.reader (io.reader Connection []) Max)
               W (io.writer Connection [])
            (frame-echo.loop F W Max 0))))))

(define frame-echo.loop
  F W Limit Count -> (frame-echo.next F W Limit Count (frame.next F)))

(define frame-echo.next
  _ _ _ Count [eof] -> [ok Count]
  _ _ _ _ [error Error] -> [error Error]
  F W Limit Count [frame Tag Payload] ->
    (frame-echo.written F W Limit Count (io.write W (frame.encode Tag Payload Limit))))

(define frame-echo.written
  _ _ _ _ [error Error _] -> [error Error]
  F W Limit Count [accepted _] -> (frame-echo.flushed F W Limit Count (io.flush W)))

(define frame-echo.flushed
  _ _ _ _ [error Error _] -> [error Error]
  F W Limit Count [ok _] -> (frame-echo.loop F W Limit (+ Count 1)))
