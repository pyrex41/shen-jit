\\ A mutable position over a fixed byte view. Load after lib/buffer.shen, under (tc -).
\\ One task owns a cursor; fork shares bytes but has an independent position.
\\ A local byte boundary returns -1, without making any claim about transport EOF.

(define cursor.cursor?
  C -> (trap-error (and (absvector? C) (= (<-address C 0) buffer.cursor))
                   (/. E false)))

(define cursor.make
  View Position -> (address-> (address-> (address-> (absvector 3)
                             0 buffer.cursor) 1 View) 2 Position))

(define cursor.check
  C -> (if (cursor.cursor? C)
           (do (buffer.check (<-address C 1)) C)
           (error "cursor: ~S is not a cursor" C)))

(define cursor.new
  View -> (cursor.make (buffer.check View) 0))

(define cursor.buffer
  C -> (<-address (cursor.check C) 1))

(define cursor.position
  C -> (<-address (cursor.check C) 2))

(define cursor.offset
  C -> (let Checked (cursor.check C)
         (+ (<-address (<-address Checked 1) 2) (<-address Checked 2))))

(define cursor.remaining
  C -> (let Checked (cursor.check C) View (<-address Checked 1)
         (- (- (<-address View 3) (<-address View 2)) (<-address Checked 2))))

(define cursor.peek
  C -> (let Checked (cursor.check C) View (<-address Checked 1)
            I (<-address Checked 2) Start (<-address View 2)
         (if (= (+ Start I) (<-address View 3))
             -1
             (shen-jit.u8 (<-address View 1) (+ Start I)))))

(define cursor.read
  C -> (let Byte (cursor.peek C)
         (if (= Byte -1) -1
             (do (address-> C 2 (+ (<-address C 2) 1)) Byte))))

(define cursor.seek
  C Position -> (let Checked (cursor.check C) View (<-address Checked 1)
                     I (buffer.range (- (<-address View 3) (<-address View 2)) Position 0)
                  (do (address-> Checked 2 I) C)))

(define cursor.skip
  C Count -> (let Checked (cursor.check C) View (<-address Checked 1)
                 I (<-address Checked 2)
                 _ (buffer.range (- (<-address View 3) (<-address View 2)) I Count)
              (do (address-> Checked 2 (+ I Count)) C)))

(define cursor.fork
  C -> (let Checked (cursor.check C)
         (cursor.make (<-address Checked 1) (<-address Checked 2))))

\\ Construct/copy first, then publish progress, so failed captures never advance.
(define cursor.view
  C Count -> (let Checked (cursor.check C) I (<-address Checked 2)
                 Out (buffer.slice (<-address Checked 1) I Count)
              (do (address-> Checked 2 (+ I Count)) Out)))

(define cursor.bytes
  C Count -> (let Checked (cursor.check C) I (<-address Checked 2)
                 Out (buffer.bytes (buffer.slice (<-address Checked 1) I Count))
              (do (address-> Checked 2 (+ I Count)) Out)))

(define cursor.string
  C Count -> (let Checked (cursor.check C) I (<-address Checked 2)
                 Out (buffer.string (buffer.slice (<-address Checked 1) I Count))
              (do (address-> Checked 2 (+ I Count)) Out)))

(declare cursor.cursor? [A --> boolean])
(declare cursor.new [buffer.view --> buffer.cursor])
(declare cursor.buffer [buffer.cursor --> buffer.view])
(declare cursor.position [buffer.cursor --> number])
(declare cursor.offset [buffer.cursor --> number])
(declare cursor.remaining [buffer.cursor --> number])
(declare cursor.peek [buffer.cursor --> number])
(declare cursor.read [buffer.cursor --> number])
(declare cursor.seek [buffer.cursor --> [number --> buffer.cursor]])
(declare cursor.skip [buffer.cursor --> [number --> buffer.cursor]])
(declare cursor.fork [buffer.cursor --> buffer.cursor])
(declare cursor.view [buffer.cursor --> [number --> buffer.view]])
(declare cursor.bytes [buffer.cursor --> [number --> buffer.storage]])
(declare cursor.string [buffer.cursor --> [number --> string]])
