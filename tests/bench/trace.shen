\\ A path tracer: a room of spheres, one of them a light, rendered to memory, hashed, and written to
\\ a file if asked. Its inner work is raw loops, with real and word registers; the loops around them
\\ are ordinary Shen. Load after lib/ffi.shen, lib/native.shen, lib/memory.shen, lib/mmap.shen and
\\ lib/handle.shen. trace.c is the same in C, to the last bit of the image.
\\
\\ (trace.render 240 180 16 "room.ppm") gives the hash as a string, and prints the time.

\\ ---------------------------------------------------------------------------
\\ The scene: each sphere is 11 reals, x y z radius, colour, light, mirror, in memory.

(define trace.spheres
  -> [[-1000.5 0 0 1000 0.75 0.25 0.25 0 0 0 0]         \\ the left wall
      [1000.5 0 0 1000 0.25 0.25 0.75 0 0 0 0]          \\ the right wall
      [0 -1000.5 0 1000 0.75 0.75 0.75 0 0 0 0]         \\ the floor
      [0 1000.5 0 1000 0.75 0.75 0.75 0 0 0 0]          \\ the ceiling
      [0 0 -1001 1000 0.75 0.75 0.75 0 0 0 0]           \\ the back wall
      [0 0 1003 1000 0 0 0 0 0 0 0]                     \\ behind the camera
      [-0.25 -0.25 -0.5 0.25 0.875 0.875 0.875 0 0 0 1] \\ a mirror
      [0.25 -0.3125 -0.25 0.1875 0.25 0.75 0.25 0 0 0 0] \\ a green ball
      [0 1 -0.5 0.625 0 0 0 6 6 6 0]])                  \\ the light

(define trace.put-reals
  _ _ [] -> done
  M I [X | Xs] -> (do (shen-jit.f64! M I X) (trace.put-reals M (+ I 8) Xs)))

(define trace.put-spheres
  _ _ [] -> done
  M I [S | Ss] -> (do (trace.put-reals M I S) (trace.put-spheres M (+ I 88) Ss)))

(define trace.scene
  -> (let Spheres (trace.spheres)
          M (handle.wrap (memory.alloc (* 88 (length Spheres))) (/. X (memory.free X)))
       (do (trace.put-spheres M 0 Spheres) M)))

\\ ---------------------------------------------------------------------------
\\ One path. A single loop does three things by turns: it tests the ray against the next sphere,
\\ and past the last one takes the bounce, which may loop drawing a random direction first. Word K is
\\ the sphere's offset, and -1 while it draws.
\\
\\ State holds the random numbers' state, and Out is where this pixel's light is added.

(define-native trace.path (Scene End State Out At Dx0 Dy0 Dz0 Bounces)
  (real Ox 0) (real Oy 0) (real Oz 2)
  (real Dx Dx0) (real Dy Dy0) (real Dz Dz0)
  (real Tr 1) (real Tg 1) (real Tb 1)
  (real Rr 0) (real Rg 0) (real Rb 0)
  (real Best 1e30)
  (real Nx 0) (real Ny 0) (real Nz 0)
  (word Stop End)
  (word K 0)
  (word Hit -1)
  (word Left Bounces)
  (word X (u64 State 0))
  (word Mult (+ (* 625341585 4294967296) 1332534557))
  (real Unit (/ 1 9007199254740992))
  (loop)
  (jump-unless-word (= K -1) trace)

  \\ Drawing: three reals in -1 to 1, until they lie inside the unit sphere.
  (word X (bit-xor X (shift-right X 12)))
  (word X (bit-xor X (shift-left X 25)))
  (word X (bit-xor X (shift-right X 27)))
  (real Ux (- (* 2 (* (shift-right (* X Mult) 11) Unit)) 1))
  (word X (bit-xor X (shift-right X 12)))
  (word X (bit-xor X (shift-left X 25)))
  (word X (bit-xor X (shift-right X 27)))
  (real Uy (- (* 2 (* (shift-right (* X Mult) 11) Unit)) 1))
  (word X (bit-xor X (shift-right X 12)))
  (word X (bit-xor X (shift-left X 25)))
  (word X (bit-xor X (shift-right X 27)))
  (real Uz (- (* 2 (* (shift-right (* X Mult) 11) Unit)) 1))
  (real Len (+ (* Ux Ux) (+ (* Uy Uy) (* Uz Uz))))
  (jump-unless (< Len 1) again)
  (jump-unless (> Len 0.0009765625) again)
  (real Root (sqrt Len))
  (real Dx (+ Nx (/ Ux Root)))
  (real Dy (+ Ny (/ Uy Root)))
  (real Dz (+ Nz (/ Uz Root)))
  (real Norm (sqrt (+ (* Dx Dx) (+ (* Dy Dy) (* Dz Dz)))))
  (real Dx (/ Dx Norm))
  (real Dy (/ Dy Norm))
  (real Dz (/ Dz Norm))
  (word K 0)
  (word Hit -1)
  (real Best 1e30)
  (word Left (- Left 1))
  (jump-unless-word (> Left 0) done)
  (label again)
  (tail-call trace.path Scene End State Out At Dx0 Dy0 Dz0 Bounces)

  (label trace)
  (jump-unless-word (< K Stop) bounce)

  \\ Against the sphere at K.
  (real Sr (f64 Scene (+ K 24)))
  (real Cx (- Ox (f64 Scene K)))
  (real Cy (- Oy (f64 Scene (+ K 8))))
  (real Cz (- Oz (f64 Scene (+ K 16))))
  (real B (+ (* Cx Dx) (+ (* Cy Dy) (* Cz Dz))))
  (real Disc (- (* B B) (- (+ (* Cx Cx) (+ (* Cy Cy) (* Cz Cz))) (* Sr Sr))))
  (jump-unless (> Disc 0) next-sphere)
  (real Root (sqrt Disc))
  (real T (- (- 0 B) Root))
  (jump-unless (> T 0.0009765625) far-side)
  (jump near-side)
  (label far-side)
  (real T (+ (- 0 B) Root))
  (label near-side)
  (jump-unless (> T 0.0009765625) next-sphere)
  (jump-unless (< T Best) next-sphere)
  (real Best T)
  (word Hit K)
  (label next-sphere)
  (word K (+ K 88))
  (tail-call trace.path Scene End State Out At Dx0 Dy0 Dz0 Bounces)

  \\ Past the last sphere: it left the room, or it takes what it hit.
  (label bounce)
  (jump-unless-word (>= Hit 0) done)
  (real Rr (+ Rr (* Tr (f64 Scene (+ Hit 56)))))
  (real Rg (+ Rg (* Tg (f64 Scene (+ Hit 64)))))
  (real Rb (+ Rb (* Tb (f64 Scene (+ Hit 72)))))
  (real Tr (* Tr (f64 Scene (+ Hit 32))))
  (real Tg (* Tg (f64 Scene (+ Hit 40))))
  (real Tb (* Tb (f64 Scene (+ Hit 48))))
  (real Ox (+ Ox (* Best Dx)))
  (real Oy (+ Oy (* Best Dy)))
  (real Oz (+ Oz (* Best Dz)))
  (real Radius (f64 Scene (+ Hit 24)))
  (real Nx (/ (- Ox (f64 Scene Hit)) Radius))
  (real Ny (/ (- Oy (f64 Scene (+ Hit 8))) Radius))
  (real Nz (/ (- Oz (f64 Scene (+ Hit 16))) Radius))
  (real Dn (+ (* Dx Nx) (+ (* Dy Ny) (* Dz Nz))))
  (jump-unless (> Dn 0) facing)
  (real Nx (- 0 Nx))
  (real Ny (- 0 Ny))
  (real Nz (- 0 Nz))
  (real Dn (- 0 Dn))
  (label facing)
  (jump-unless (> (f64 Scene (+ Hit 80)) 0) dull)
  (real Twice (+ Dn Dn))
  (real Dx (- Dx (* Twice Nx)))
  (real Dy (- Dy (* Twice Ny)))
  (real Dz (- Dz (* Twice Nz)))
  (word K 0)
  (word Hit -1)
  (real Best 1e30)
  (word Left (- Left 1))
  (jump-unless-word (> Left 0) done)
  (tail-call trace.path Scene End State Out At Dx0 Dy0 Dz0 Bounces)

  \\ A dull surface: the next turns draw a direction.
  (label dull)
  (word K -1)
  (tail-call trace.path Scene End State Out At Dx0 Dy0 Dz0 Bounces)

  (label done)
  (u64! State 0 X)
  (word Pixel At)
  (f64! Out Pixel (+ (f64 Out Pixel) Rr))
  (f64! Out (+ Pixel 8) (+ (f64 Out (+ Pixel 8)) Rg))
  (f64! Out (+ Pixel 16) (+ (f64 Out (+ Pixel 16)) Rb))
  (return Out))

\\ The next real from State, for the camera's jitter, as a path draws them.
(define-native trace.next-real (State)
  (word X (u64 State 0))
  (word Mult (+ (* 625341585 4294967296) 1332534557))
  (word X (bit-xor X (shift-right X 12)))
  (word X (bit-xor X (shift-left X 25)))
  (word X (bit-xor X (shift-right X 27)))
  (u64! State 0 X)
  (return-real (* (shift-right (* X Mult) 11) (/ 1 9007199254740992))))

\\ ---------------------------------------------------------------------------
\\ The image.

(define-native trace.ray-norm (Px Py)
  (real X Px)
  (real Y Py)
  (return-real (sqrt (+ (* X X) (+ (* Y Y) (* -2 -2))))))

(define trace.sample
  Scene End State Out At X Y W H
  -> (let Px (* (- (+ X (trace.next-real State)) (* W 0.5)) (/ 2.0 H))
          Py (* (- (- (* H 0.5) Y) (trace.next-real State)) (/ 2.0 H))
          Norm (trace.ray-norm Px Py)
       (trace.path Scene End State Out At (/ Px Norm) (/ Py Norm) (/ -2 Norm) 6)))

(define trace.samples
  0 _ _ _ _ _ _ _ _ _ -> done
  N Scene End State Out At X Y W H
  -> (do (trace.sample Scene End State Out At X Y W H)
         (trace.samples (- N 1) Scene End State Out At X Y W H)))

(define trace.row
  X _ W _ _ _ _ _ _ -> done where (>= X W)
  X Y W H N Scene End State Out
  -> (do (trace.samples N Scene End State Out (* (+ (* Y W) X) 24) X Y W H)
         (trace.row (+ X 1) Y W H N Scene End State Out)))

(define trace.rows
  Y _ H _ _ _ _ _ -> done where (>= Y H)
  Y W H N Scene End State Out
  -> (do (trace.row 0 Y W H N Scene End State Out)
         (trace.rows (+ Y 1) W H N Scene End State Out)))

\\ Turns light into bytes, and hashes them with FNV-1a.
(define-native trace.develop (Light Image Count Samples Hash)
  (word I 0)
  (word N Count)
  (real Each Samples)
  (word H (u64 Hash 0))
  (word Prime 1099511628211)
  (loop)
  (jump-unless-word (< I N) done)
  (word B (truncate (* (sqrt (/ (f64 Light (* I 8)) Each)) 255.5)))
  (jump-unless-word (> B 255) in-range)
  (word B 255)
  (label in-range)
  (u8! Image I B)
  (word H (* (bit-xor H B) Prime))
  (word I (+ I 1))
  (tail-call trace.develop Light Image Count Samples Hash)
  (label done)
  (u64! Hash 0 H)
  (return Image))

\\ A word of 64 bits, read as text.
(define trace.hex
  _ 0 -> ""
  V N -> (cn (trace.hex (shen-jit.shift-right V 4) (- N 1))
             (pos "0123456789abcdef" (shen-jit.bit-and V 15))))

(define trace.word-hex
  M -> (cn (trace.hex (shen-jit.u32 M 4) 8) (trace.hex (shen-jit.u32 M 0) 8)))

(define trace.write-header
  M I [] -> I
  M I [C | Cs] -> (do (shen-jit.u8! M I C) (trace.write-header M (+ I 1) Cs)))

(define trace.save
  Path Image W H
  -> (let Header (trace.string-bytes (make-string "P6c#10;~A ~Ac#10;255c#10;" W H))
          Size (* W H 3)
          M (handle.wrap (mmap.create Path (+ (length Header) Size)) (/. X (mmap.close X)))
          At (trace.write-header M 0 Header)
          _ (shen-jit.copy-bytes M At Image 0 Size)
       (handle.close M)))

(define trace.string-bytes
  "" -> []
  S -> [(string->n (pos S 0)) | (trace.string-bytes (tlstr S))])

(define trace.render
  W H N Path
  -> (let Scene (trace.scene)
          End (shen-jit.bytes-length Scene)
          Size (* W H 3)
          State (handle.wrap (memory.alloc 8) (/. X (memory.free X)))
          Hash (handle.wrap (memory.alloc 8) (/. X (memory.free X)))
          Light (handle.wrap (memory.alloc (* 8 Size)) (/. X (memory.free X)))
          Image (handle.wrap (memory.alloc Size) (/. X (memory.free X)))
          _ (trace.seed State 1234567 89101112)
          _ (trace.seed Hash 3421674724 2216829733)
          T0 (get-time unix)
          _ (trace.rows 0 W H N Scene End State Light)
          _ (trace.develop Light Image Size N Hash)
          T1 (get-time unix)
          Check (trace.word-hex Hash)
          _ (if (= Path "") skip (trace.save Path Image W H))
       (do (output "trace ~A s check ~A~%" (- T1 T0) Check) Check)))

(define trace.seed
  M High Low -> (shen-jit.u32! (shen-jit.u32! M 0 Low) 4 High))

\\ Set trace.*image* first to have the image in a file.
(define trace.image-path
  -> (trap-error (value trace.*image*) (/. E "")))

(trace.render 240 180 16 (trace.image-path))
