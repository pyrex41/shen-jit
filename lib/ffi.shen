\\ Calling C from Shen. It stays out of the image until asked for; load this file under
\\ (tc -), before the code using it:
\\
\\   shen-jit eval -l lib/ffi.shen -l program.shen
\\
\\ A library is named once, with the file names to try in order. [] means the executable
\\ and what it links, which on Windows reaches nothing, as the executable is static.
\\
\\ (shen-jit.library libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
\\ (define-foreign c-cos libm "cos" (double) --> double)
\\ (define-foreign c-fcntl sockets "fcntl" (int32 int32 int32) --> int32 (varargs 2))
\\ (define-foreign c-recv sockets "recv" (int32 bytes int64 int32) --> int64 blocking)
\\
\\ Each type, as an argument and as a result:
\\
\\   int64           a fixnum; a result must fit one
\\   int32, uint32   a fixnum in range; C's int is int32
\\   double          a number; a new real
\\   string          copied for the call, and a NUL in it raises; copied, and NULL is []
\\   pointer         a pointer of any kind, or [] for NULL; a pointer of kind pointer, or []
\\   bytes           the address of a byte buffer; no result
\\   bool            true or false; the result's low byte
\\   void            no argument; []
\\
\\ At most 6 arguments that are not doubles, and 8 that are. blocking lets other threads run
\\ during the call, which then works on copies of its byte buffers, as they may move.
\\ (varargs N) marks a variadic function with N fixed arguments, 1 to 3, and integers only.
\\
\\ A function is found at its first call, so an image saved with some finds them again, and a
\\ system can declare what it never calls without harm. A pointer saved in an image loads dead,
\\ and raises when given to C, as one does after shen-jit.pointer-kill. A pointer with a length
\\ can be read and written in place: shen-jit.pointer-sized, lib/memory.shen and lib/mmap.shen.
\\ See docs/ffi.md.
\\
\\ The C name, the result and each argument type are expressions, evaluated when the definition
\\ is, which lets one definition suit each system: lib/socket.shen shows how.
\\
\\ C written for Shen is declared with its arity alone, up to 8, and takes and returns values as
\\ they are, with include/shen.h:
\\
\\ (define-foreign-procedure sum-list mine "sum_list" 1)

(define shen-jit.library
  Name Files -> (do (put Name shen-jit.ffi.files Files) Name))

(define shen-jit.ffi.files
  Library -> (trap-error (get Library shen-jit.ffi.files)
                         (/. E (error "foreign: ~A is not a library: see shen-jit.library" Library))))

\\ A later call in the same file compiles directly if the name's arity is known when it is
\\ read, as for define.
(defmacro shen-jit.ffi-macro
  [define-foreign Name Library CName Types --> Result | Flags]
  -> (do (if (and (symbol? Name) (not (variable? Name)) (= (arity Name) -1))
             (shen.store-arity Name (length Types))
             skip)
         (shen-jit.ffi.check-flags Flags)
         [shen-jit.ffi.define Name Library CName (shen-jit.ffi.list Types) Result
                              (element? blocking Flags) (shen-jit.ffi.varargs Flags)])
  [define-foreign | Form]
  -> (error "define-foreign: expected Name Library CName (Types) --> Result Flags, in ~R" Form)
  [define-foreign-procedure Name Library CName Arity]
  -> (do (if (and (symbol? Name) (not (variable? Name)) (= (arity Name) -1))
             (shen.store-arity Name Arity)
             skip)
         [shen-jit.ffi.define-procedure Name Library CName Arity])
  [define-foreign-procedure | Form]
  -> (error "define-foreign-procedure: expected Name Library CName Arity, in ~R" Form))

(define shen-jit.ffi.list
  [] -> []
  [X | Xs] -> [cons X (shen-jit.ffi.list Xs)])

(define shen-jit.ffi.check-flags
  [] -> true
  [blocking | Flags] -> (shen-jit.ffi.check-flags Flags)
  [[varargs N] | Flags] -> (shen-jit.ffi.check-flags Flags) where (integer? N)
  [Flag | _] -> (error "define-foreign: ~R is not a flag" Flag))

(define shen-jit.ffi.varargs
  [] -> 0
  [[varargs N] | _] -> N
  [_ | Flags] -> (shen-jit.ffi.varargs Flags))

\\ As ffi.c numbers them.
(define shen-jit.ffi.code
  void -> 0
  int64 -> 1
  int32 -> 2
  uint32 -> 3
  double -> 4
  string -> 5
  pointer -> 6
  bytes -> 7
  bool -> 8
  Type -> (error "foreign: ~R is not a type" Type))

(define shen-jit.ffi.argument
  void -> (error "foreign: void is not an argument type")
  Type -> (shen-jit.ffi.code Type))

(define shen-jit.ffi.result
  bytes -> (error "foreign: bytes is not a result type")
  Type -> (shen-jit.ffi.code Type))

(define shen-jit.ffi.fill
  V _ [] -> V
  V I [X | Xs] -> (shen-jit.ffi.fill (address-> V I X) (+ I 1) Xs))

\\ The description that ffi.c reads, in its order: the name, the library's name and files, the
\\ name in C, the result, the flags, the kind of a pointer returned, and the arguments.
(define shen-jit.ffi.define
  Name _ _ _ _ _ _ -> (error "foreign: ~A is a system function" Name) where (shen.sysfunc? Name)
  Name Library CName Types Result Blocking Varargs
  -> (let N (length Types)
          Flags (+ (if Blocking 1 0) (* 2 Varargs))
          Fields [Name Library (shen-jit.ffi.files Library) CName (shen-jit.ffi.result Result) Flags pointer
                  | (map (/. T (shen-jit.ffi.argument T)) Types)]
          Desc (shen-jit.ffi.fill (absvector (length Fields)) 0 Fields)
       (do (shen-jit.foreign Name Desc)
           (shen.store-arity Name N)
           (shen-jit.ffi.declare Name Types Result)
           Name)))

\\ A procedure has one type of its own, in place of every other.
(define shen-jit.ffi.define-procedure
  Name _ _ _ -> (error "foreign: ~A is a system function" Name) where (shen.sysfunc? Name)
  Name Library CName Arity
  -> (let Fields [Name Library (shen-jit.ffi.files Library) CName 9 0 pointer | (shen-jit.ffi.repeat Arity 9)]
          Desc (shen-jit.ffi.fill (absvector (length Fields)) 0 Fields)
       (do (shen-jit.foreign Name Desc)
           (shen.store-arity Name Arity)
           Name)))

(define shen-jit.ffi.repeat
  0 _ -> []
  N X -> [X | (shen-jit.ffi.repeat (- N 1) X)])

\\ Typed code can use a function at once if each of its types is a plain Shen type. A result
\\ that may be [] is not, nor is a pointer: those are for the program to declare.
(define shen-jit.ffi.declare
  Name Types Result -> (let Plain (map (/. T (shen-jit.ffi.plain T)) [string | Types])
                            Out (shen-jit.ffi.plain Result)
                         (if (and (not (element? unknown [Out | Plain])) (not (= Out string)))
                             (declare Name (shen-jit.ffi.type (tl Plain) Out))
                             skip)))

(define shen-jit.ffi.plain
  int64 -> number
  int32 -> number
  uint32 -> number
  double -> number
  bool -> boolean
  string -> string
  _ -> unknown)

(define shen-jit.ffi.type
  [] Out -> [--> Out]
  [T] Out -> [T --> Out]
  [T | Ts] Out -> [T --> (shen-jit.ffi.type Ts Out)])

(declare shen-jit.library [symbol --> [[list string] --> symbol]])
(declare shen-jit.ffi.define
         [symbol --> [symbol --> [string --> [[list symbol] --> [symbol --> [boolean --> [number --> symbol]]]]]]])
(declare shen-jit.ffi.define-procedure [symbol --> [symbol --> [string --> [number --> symbol]]]])
(declare shen-jit.errno [--> number])
(declare shen-jit.c-errno [--> number])
