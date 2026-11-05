\\ Files as memory, over the FFI and with no C of their own. It stays out of the image until asked
\\ for; load it after lib/ffi.shen, under (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l lib/mmap.shen -l program.shen
\\
\\ (let M (mmap.read "data.bin")
\\   (do (output "~A bytes, starting ~A~%" (shen-jit.bytes-length M) (shen-jit.u8 M 0))
\\       (mmap.close M)))
\\
\\   (mmap.read Path)        all of a file, as a pointer with a length, read only
\\   (mmap.read-write Path)  all of a file, where what is written reaches the file
\\   (mmap.create Path N)    a new file of N zero bytes, replacing any there, as mmap.read-write
\\   (mmap.close M)          unmaps it and kills M, so that using it again raises. A copy of M from
\\                           shen-jit.pointer-sized is not killed with it, and must not be used.
\\
\\ What reads a byte buffer reads the result, each access checked against the length, and nothing
\\ is read from the file until it is touched. An empty file cannot be mapped, and raises. Errors
\\ raise, with the system's message or, for the mapping itself on Windows, its number.
\\
\\ Two things the length cannot check end the process: a store into mmap.read's memory, and an
\\ access past the end of a file that something has since made shorter.
\\
\\ It stays mapped until mmap.close, or the end of the process. lib/handle.shen closes it once nothing
\\ reaches it: (handle.wrap (mmap.read Path) (/. M (mmap.close M))).
\\
\\ Windows opens files through its C library too, under its own names, and differs only in the
\\ mapping. Functions are found at their first call, so a system declares what it never calls
\\ without harm.

(shen-jit.library mmap.lib ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(shen-jit.library mmap.kernel32 ["kernel32.dll"])

(define mmap.windows?
  -> (= (value *os*) "Windows"))

(define-foreign mmap.c-open mmap.lib (if (mmap.windows?) "_open" "open") (string int32) --> int32)
(define-foreign mmap.c-creat mmap.lib (if (mmap.windows?) "_creat" "creat") (string int32) --> int32)
(define-foreign mmap.c-close mmap.lib (if (mmap.windows?) "_close" "close") (int32) --> int32)
(define-foreign mmap.c-lseek mmap.lib (if (mmap.windows?) "_lseeki64" "lseek") (int32 int64 int32) --> int64)
(define-foreign mmap.c-truncate mmap.lib (if (mmap.windows?) "_chsize_s" "ftruncate") (int32 int64) --> int32)
(define-foreign mmap.c-strerror mmap.lib "strerror" (int32) --> string)

(define-foreign mmap.c-mmap mmap.lib "mmap" (pointer int64 int32 int32 int32 int64) --> pointer)
(define-foreign mmap.c-munmap mmap.lib "munmap" (pointer int64) --> int32)

(define-foreign mmap.c-osfhandle mmap.lib "_get_osfhandle" (int32) --> int64)
(define-foreign mmap.c-create-mapping mmap.kernel32 "CreateFileMappingA" (int64 pointer int32 int32 int32 pointer) --> int64)
(define-foreign mmap.c-map-view mmap.kernel32 "MapViewOfFile" (int64 int32 int32 int32 int64) --> pointer)
(define-foreign mmap.c-unmap-view mmap.kernel32 "UnmapViewOfFile" (pointer) --> int32)
(define-foreign mmap.c-close-handle mmap.kernel32 "CloseHandle" (int64) --> int32)

(define mmap.fail
  Path -> (mmap.raise Path (shen-jit.c-errno)))

(define mmap.raise
  Path Code -> (error "mmap: ~A: ~A" Path (mmap.c-strerror Code)))

\\ ---------------------------------------------------------------------------
\\ The mapping. O_RDONLY is 0 and O_RDWR is 2 on every system. Windows also needs _O_BINARY, as it
\\ would otherwise take a Ctrl-Z off the end of a file opened to write.

(define mmap.open
  Path Flags -> (mmap.c-open Path (if (mmap.windows?) (+ Flags 32768) Flags)))

(define mmap.read
  Path -> (mmap.map Path (mmap.open Path 0) false))

(define mmap.read-write
  Path -> (mmap.map Path (mmap.open Path 2) true))

\\ creat gives a descriptor that cannot read, which a mapping needs, so it is opened again.
(define mmap.create
  Path N -> (error "mmap: ~A: cannot make a file of ~A bytes" Path N) where (not (and (integer? N) (> N 0)))
  Path N -> (let Fd (mmap.c-creat Path (if (mmap.windows?) 384 420))
              (if (< Fd 0)
                  (mmap.fail Path)
                  (do (mmap.c-close Fd)
                      (mmap.map-sized Path (mmap.open Path 2) N)))))

(define mmap.map-sized
  Path Fd _ -> (mmap.fail Path) where (< Fd 0)
  Path Fd N -> (if (= 0 (mmap.c-truncate Fd N))
                   (mmap.map Path Fd true)
                   (let Code (shen-jit.c-errno)
                     (do (mmap.c-close Fd) (mmap.raise Path Code)))))

\\ The descriptor is closed either way: a mapping does not need it.
(define mmap.map
  Path Fd _ -> (mmap.fail Path) where (< Fd 0)
  Path Fd Write -> (let M (trap-error (mmap.map-open Path Fd Write)
                                      (/. E (do (mmap.c-close Fd) (simple-error (error-to-string E)))))
                     (do (mmap.c-close Fd) M)))

(define mmap.map-open
  Path Fd Write -> (let Length (mmap.c-lseek Fd 0 2)
                     (cases (< Length 0) (mmap.fail Path)
                            (= Length 0) (error "mmap: ~A is empty, and cannot be mapped" Path)
                            true (shen-jit.pointer-sized (mmap.view Path Fd Length Write) Length))))

(define mmap.view
  Path Fd Length Write -> (if (mmap.windows?)
                              (mmap.windows-view Path Fd Write)
                              (mmap.posix-view Path Fd Length Write)))

\\ PROT_READ is 1, PROT_WRITE is 2, and MAP_SHARED is 1. MAP_FAILED is all ones.
(define mmap.posix-view
  Path Fd Length Write -> (let P (mmap.c-mmap [] Length (if Write 3 1) 1 Fd 0)
                            (if (= (shen-jit.pointer-address P) -1)
                                (mmap.fail Path)
                                P)))

\\ PAGE_READWRITE is 4 and PAGE_READONLY is 2; FILE_MAP_WRITE is 2 and FILE_MAP_READ is 4. A view
\\ keeps its mapping, and sizes of 0 mean all of the file.
(define mmap.windows-view
  Path Fd Write -> (let Mapping (mmap.c-create-mapping (mmap.c-osfhandle Fd) [] (if Write 4 2) 0 0 [])
                     (if (= Mapping 0)
                         (mmap.windows-fail Path (shen-jit.errno))
                         (let View (mmap.c-map-view Mapping (if Write 2 4) 0 0 0)
                              Code (shen-jit.errno)
                              _ (mmap.c-close-handle Mapping)
                           (if (empty? View)
                               (mmap.windows-fail Path Code)
                               View)))))

(define mmap.windows-fail
  Path Code -> (error "mmap: ~A: error ~A" Path Code))

\\ ---------------------------------------------------------------------------
\\ Closing.

(define mmap.close
  M -> (do (if (mmap.windows?)
               (mmap.c-unmap-view M)
               (mmap.c-munmap M (shen-jit.bytes-length M)))
           (shen-jit.pointer-kill M)
           true))
