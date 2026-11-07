\\ Owned duplex endpoints over lib/socket.shen. Load ffi.shen, socket.shen, buffer.shen, io.shen.
\\ io.socket consumes a connected socket's raw integer. Do not use or wrap that integer again.
\\ Data calls stay nonblocking; only the existing poll FFI releases the VM lock.

(define-foreign io.socket-c-error socket.lib "WSAGetLastError" () --> int32)

(define io.socket-code
  -> (if (socket.windows?) (io.socket-c-error) (shen-jit.errno)))

(define io.socket-error
  Op Name Code ->
    (io.native-error Op (if (socket.windows?) winsock posix) Code Name
      (if (socket.windows?) (make-string "socket error ~A" Code) (socket.c-strerror Code))))

(define io.socket-again?
  Code -> (or (= Code (socket.by-os 11 35 10035)) (= Code (socket.by-os 4 4 10004))))

\\ Native identities reload dead in images. The token is never dereferenced or passed to C.
(define io.socket-token
  S ->
    (let Address (+ S 1)
         B (shen-jit.bytes 8)
         _ (shen-jit.u32! B 0 (shen-jit.bit-and Address 4294967295))
         _ (shen-jit.u32! B 4 (shen-jit.shift-right Address 32))
      (shen-jit.bytes->pointer B 0 io.socket)))

(define io.socket-id
  Token ->
    (let Address (shen-jit.pointer-address Token)
      (if (> Address 0) (- Address 1) (error "io: socket endpoint is stale"))))

(define io.socket-wait
  Token Name Event ->
    (let Ready (socket.c-poll (socket.pollfd (io.socket-id Token) Event) 1 100)
         Code (if (< Ready 0) (io.socket-code) 0)
      (cond ((> Ready 0) [ok])
            ((or (= Ready 0) (io.socket-again? Code)) (io.socket-wait Token Name Event))
            (true [error (io.socket-error poll Name Code)]))))

(define io.socket-read
  Token Name Chunk ->
    (let N (socket.c-recv (io.socket-id Token) Chunk (shen-jit.bytes-length Chunk) 0)
         Code (if (< N 0) (io.socket-code) 0)
      (cond ((> N 0) [read N])
            ((= N 0) [eof])
            ((io.socket-again? Code)
              (io.socket-read-ready Token Name Chunk
                (io.socket-wait Token Name (socket.readable-event))))
            (true [error (io.socket-error read Name Code)]))))

(define io.socket-read-ready
  _ _ _ [error Error] -> [error Error]
  Token Name Chunk [ok] -> (io.socket-read Token Name Chunk))

(define io.socket-write
  Token Name Chunk ->
    (let N (socket.c-send (io.socket-id Token) Chunk (shen-jit.bytes-length Chunk) (socket.send-flags))
         Code (if (< N 0) (io.socket-code) 0)
      (cond ((>= N 0) [written N])
            ((io.socket-again? Code)
              (io.socket-write-ready Token Name Chunk
                (io.socket-wait Token Name (socket.writable-event))))
            (true [error (io.socket-error write Name Code)]))))

(define io.socket-write-ready
  _ _ _ [error Error] -> [error Error]
  Token Name Chunk [ok] -> (io.socket-write Token Name Chunk))

(define io.socket-close
  Token Name ->
    (let S (io.socket-id Token)
         _ (shen-jit.pointer-kill Token)
         Result (socket.c-close S)
         Code (if (< Result 0) (io.socket-code) 0)
      (if (= Result 0) [ok] [error (io.socket-error close Name Code)])))

(define io.socket-make
  S Name ->
    (let Token (io.socket-token S)
         E (io.endpoint Name read-write 65536
                        (/. B (io.socket-read Token Name B))
                        (/. B (io.socket-write Token Name B))
                        (freeze (io.socket-close Token Name)))
      (do (address-> E 12 Token) E)))

(define io.socket
  S Name ->
    (let N (buffer.index S)
         _ (if (and (string? Name)
                    (if (socket.windows?) (< N 2305843009213693951) (<= N 2147483647)))
               true
               (error "io: invalid socket or name"))
      (trap-error (io.socket-make N Name)
        (/. X (do (socket.c-close N) (simple-error (error-to-string X)))))))

(define io.socket-check
  E ->
    (let _ (io.endpoint-check E)
         Token (<-address E 12)
         _ (if (and (shen-jit.pointer? Token) (= (shen-jit.pointer-kind Token) io.socket))
               true
               (error "io: not a socket endpoint"))
         _ (io.check E read (<-address E 9))
      Token))

\\ Flush before sending FIN. Read EOF, write shutdown and full close remain separate states.
(define io.shutdown-write
  E ->
    (let Token (io.socket-check E)
         W (<-address E 10)
      (if (= (<-address E 2) read)
          [ok]
          (io.socket-shutdown-ready E Token (if (empty? W) [ok 0] (io.flush W))))))

(define io.socket-shutdown-ready
  _ _ [error Error _] -> [error Error]
  E Token [ok _] ->
    (let Result (socket.c-shutdown (io.socket-id Token) 1)
         Code (if (< Result 0) (io.socket-code) 0)
      (if (= Result 0)
          (do (address-> E 2 read)
              (address-> E 10 [])
              [ok])
          [error (io.socket-error shutdown (<-address E 1) Code)])))

(declare io.socket [number --> [string --> io.endpoint]])
(declare io.shutdown-write [io.endpoint --> io.close-result])
