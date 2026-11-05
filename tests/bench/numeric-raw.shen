\\ The programs of numeric.shen, with real registers in their inner loops, for make bench-numeric.
\\ What lies outside those loops stays ordinary Shen, which calls them with boxed reals.

(define now -> (get-time unix))

(define report
  Name Check T0 -> (output "~A ~A s check ~A~%" Name (- (now) T0) Check))

\\ ---------------------------------------------------------------------------

(define mat.at N I J -> (* 8 (+ (* I N) J)))

(define mat.fill-row
  _ _ _ J N -> done where (>= J N)
  M I F J N -> (do (shen-jit.f64! M (mat.at N I J) (F I J))
                   (mat.fill-row M I F (+ J 1) N)))

(define mat.fill
  _ _ I N -> done where (>= I N)
  M F I N -> (do (mat.fill-row M I F 0 N) (mat.fill M F (+ I 1) N)))

(define-native mat.dot (A AI0 B BI0 End0 Step0 Start)
  (real Acc Start)
  (word AI AI0)
  (word BI BI0)
  (word End End0)
  (word Step Step0)
  (loop)
  (jump-unless-word (< AI End) done)
  (real Acc (+ Acc (* (f64 A AI) (f64 B BI))))
  (word AI (+ AI 8))
  (word BI (+ BI Step))
  (tail-call mat.dot A AI0 B BI0 End0 Step0 Start)
  (label done)
  (return-real Acc))

(define mat.row
  _ _ _ _ _ J N -> done where (>= J N)
  A B C I Bytes J N -> (let RowStart (* I Bytes)
                         (do (shen-jit.f64! C (+ RowStart (* J 8))
                                            (mat.dot A RowStart B (* J 8) (+ RowStart Bytes) Bytes 0))
                             (mat.row A B C I Bytes (+ J 1) N))))

(define mat.rows
  _ _ _ I _ N -> done where (>= I N)
  A B C I Bytes N -> (do (mat.row A B C I Bytes 0 N) (mat.rows A B C (+ I 1) Bytes N)))

(define mat.trace
  _ I N Acc -> Acc where (>= I N)
  C I N Acc -> (mat.trace C (+ I 1) N (+ Acc (shen-jit.f64 C (mat.at N I I)))))

(define matmul
  N -> (let Bytes (* N 8)
            A (memory.alloc (* N Bytes))
            B (memory.alloc (* N Bytes))
            C (memory.alloc (* N Bytes))
            _ (mat.fill A (/. I J (/ 1.0 (+ I J 1))) 0 N)
            _ (mat.fill B (/. I J (+ 1.0 (* 0.5 (- I J)))) 0 N)
            T0 (now)
            _ (mat.rows A B C 0 Bytes N)
         (report "matmul" (mat.trace C 0 N 0.0) T0)))

\\ ---------------------------------------------------------------------------

(define-native mand.iter (CX0 CY0 N0 Limit0)
  (real X 0)
  (real Y 0)
  (real CX CX0)
  (real CY CY0)
  (word N N0)
  (word Limit Limit0)
  (loop)
  (jump-unless-word (< N Limit) stop)
  (real XX (* X X))
  (real YY (* Y Y))
  (jump-unless (> (+ XX YY) 4) go-on)
  (return-word N)
  (label go-on)
  (real Y (+ (* 2 (* X Y)) CY))
  (real X (+ (- XX YY) CX))
  (word N (+ N 1))
  (tail-call mand.iter CX0 CY0 N0 Limit0)
  (label stop)
  (return-word N))

(define mand.row
  _ _ _ I Size _ Acc -> Acc where (>= I Size)
  CY Step Limit I Size X0 Acc -> (mand.row CY Step Limit (+ I 1) Size X0
                                           (+ Acc (mand.iter (+ X0 (* I Step)) CY 0 Limit))))

(define mand.rows
  _ _ J Size _ Acc -> Acc where (>= J Size)
  Step Limit J Size Y0 Acc -> (mand.rows Step Limit (+ J 1) Size Y0
                                         (mand.row (+ Y0 (* J Step)) Step Limit 0 Size -2.0 Acc)))

(define mandelbrot
  Size Limit -> (let T0 (now)
                     Check (mand.rows (/ 3.0 Size) Limit 0 Size -1.5 0)
                  (report "mandelbrot" Check T0)))

\\ ---------------------------------------------------------------------------

\\ One row of the matrix, with its element written out, as a call would end the loop.
(define-native sn.row (V I0 J0 N0)
  (real Acc 0)
  (word I I0)
  (word J J0)
  (word N N0)
  (loop)
  (jump-unless-word (< J N) done)
  (real Acc (+ Acc (* (/ 1 (+ (* 0.5 (+ I J) (+ I J 1)) I 1)) (f64 V (* J 8)))))
  (word J (+ J 1))
  (tail-call sn.row V I0 J0 N0)
  (label done)
  (return-real Acc))

(define-native sn.column (V I0 J0 N0)
  (real Acc 0)
  (word I I0)
  (word J J0)
  (word N N0)
  (loop)
  (jump-unless-word (< J N) done)
  (real Acc (+ Acc (* (/ 1 (+ (* 0.5 (+ I J) (+ I J 1)) J 1)) (f64 V (* J 8)))))
  (word J (+ J 1))
  (tail-call sn.column V I0 J0 N0)
  (label done)
  (return-real Acc))

(define sn.times
  _ _ _ I N -> done where (>= I N)
  V Out false I N -> (do (shen-jit.f64! Out (* I 8) (sn.row V I 0 N))
                         (sn.times V Out false (+ I 1) N))
  V Out true I N -> (do (shen-jit.f64! Out (* I 8) (sn.column V I 0 N))
                        (sn.times V Out true (+ I 1) N)))

(define sn.at-a-t
  V Out Tmp N -> (do (sn.times V Tmp false 0 N)
                     (sn.times Tmp Out true 0 N)))

(define sn.power
  0 _ _ _ _ -> done
  K U V Tmp N -> (do (sn.at-a-t U V Tmp N)
                     (sn.at-a-t V U Tmp N)
                     (sn.power (- K 1) U V Tmp N)))

(define sn.ones
  _ I N -> done where (>= I N)
  U I N -> (do (shen-jit.f64! U (* I 8) 1.0) (sn.ones U (+ I 1) N)))

(define sn.dot
  _ _ I N Acc -> Acc where (>= I N)
  A B I N Acc -> (sn.dot A B (+ I 1) N (+ Acc (* (shen-jit.f64 A (* I 8)) (shen-jit.f64 B (* I 8))))))

(define spectral
  N -> (let U (memory.alloc (* N 8))
            V (memory.alloc (* N 8))
            Tmp (memory.alloc (* N 8))
            _ (sn.ones U 0 N)
            T0 (now)
            _ (sn.power 10 U V Tmp N)
         (report "spectral" (/ (sn.dot U V 0 N 0.0) (sn.dot V V 0 N 0.0)) T0)))

\\ ---------------------------------------------------------------------------

\\ One body against those after it: I and J are the bodies' offsets, and J runs to End.
(define-native nb.with (B I0 J0 End0 DtBox)
  (real Dt DtBox)
  (word I I0)
  (word J J0)
  (word End End0)
  (loop)
  (jump-unless-word (< J End) done)
  (real Dx (- (f64 B I) (f64 B J)))
  (real Dy (- (f64 B (+ I 8)) (f64 B (+ J 8))))
  (real Dz (- (f64 B (+ I 16)) (f64 B (+ J 16))))
  (real D2 (+ (+ (* Dx Dx) (* Dy Dy)) (* Dz Dz)))
  (real Mag (/ Dt (* D2 (sqrt D2))))
  (real MI (* (f64 B (+ I 48)) Mag))
  (real MJ (* (f64 B (+ J 48)) Mag))
  (f64! B (+ I 24) (- (f64 B (+ I 24)) (* Dx MJ)))
  (f64! B (+ I 32) (- (f64 B (+ I 32)) (* Dy MJ)))
  (f64! B (+ I 40) (- (f64 B (+ I 40)) (* Dz MJ)))
  (f64! B (+ J 24) (+ (f64 B (+ J 24)) (* Dx MI)))
  (f64! B (+ J 32) (+ (f64 B (+ J 32)) (* Dy MI)))
  (f64! B (+ J 40) (+ (f64 B (+ J 40)) (* Dz MI)))
  (word J (+ J 56))
  (tail-call nb.with B I0 J0 End0 DtBox)
  (label done)
  (return B))

(define-native nb.moves (B I0 End0 DtBox)
  (real Dt DtBox)
  (word I I0)
  (word End End0)
  (loop)
  (jump-unless-word (< I End) done)
  (f64! B I (+ (f64 B I) (* Dt (f64 B (+ I 24)))))
  (f64! B (+ I 8) (+ (f64 B (+ I 8)) (* Dt (f64 B (+ I 32)))))
  (f64! B (+ I 16) (+ (f64 B (+ I 16)) (* Dt (f64 B (+ I 40)))))
  (word I (+ I 56))
  (tail-call nb.moves B I0 End0 DtBox)
  (label done)
  (return B))

(define nb.get B I F -> (shen-jit.f64 B (+ (* I 56) (* F 8))))
(define nb.put B I F X -> (shen-jit.f64! B (+ (* I 56) (* F 8)) X))

(define nb.forces
  _ I End _ -> done where (>= I End)
  B I End Dt -> (do (nb.with B I (+ I 56) End Dt) (nb.forces B (+ I 56) End Dt)))

(define nb.steps
  0 _ _ _ -> done
  K B End Dt -> (do (nb.forces B 0 End Dt) (nb.moves B 0 End Dt) (nb.steps (- K 1) B End Dt)))

(define nb.place
  _ I N -> done where (>= I N)
  B I N -> (do (nb.put B I 0 (* 1.25 I))
               (nb.put B I 1 (- 7.0 (* 0.5 I)))
               (nb.put B I 2 (* 0.25 (* I I)))
               (nb.put B I 3 (* 0.125 (- 3.0 I)))
               (nb.put B I 4 (* 0.0625 I))
               (nb.put B I 5 (- 0.03125 (* 0.01 I)))
               (nb.put B I 6 (+ 1.0 (* 0.5 I)))
               (nb.place B (+ I 1) N)))

(define nbody
  N Steps -> (let B (memory.alloc (* N 56))
                  _ (nb.place B 0 N)
                  T0 (now)
                  _ (nb.steps Steps B (* N 56) 0.01)
               (report "nbody" (nb.get B 0 0) T0)))

\\ ---------------------------------------------------------------------------

(define-native heat.cells (G I0 End0 Stride0)
  (word I I0)
  (word End End0)
  (word Stride Stride0)
  (loop)
  (jump-unless-word (< I End) done)
  (f64! G I (* 0.25 (+ (+ (f64 G (- I 8)) (f64 G (+ I 8))) (+ (f64 G (- I Stride)) (f64 G (+ I Stride))))))
  (word I (+ I 16))
  (tail-call heat.cells G I0 End0 Stride0)
  (label done)
  (return G))

(define heat.rows
  _ _ J H _ _ -> done where (>= J (- H 1))
  G W J H Stride Colour
  -> (let Odd (shen-jit.bit-and (+ J Colour) 1)
       (do (heat.cells G (+ (* J Stride) (* 8 (+ 1 Odd))) (+ (* J Stride) (- Stride 8)) Stride)
           (heat.rows G W (+ J 1) H Stride Colour))))

(define heat.sweeps
  0 _ _ _ _ -> done
  K G W H Stride -> (do (heat.rows G W 1 H Stride 0)
                        (heat.rows G W 1 H Stride 1)
                        (heat.sweeps (- K 1) G W H Stride)))

(define heat.edge
  _ I End -> done where (>= I End)
  G I End -> (do (shen-jit.f64! G I 100.0) (heat.edge G (+ I 8) End)))

(define heat
  W H Sweeps -> (let Stride (* W 8)
                     G (memory.alloc (* H Stride))
                     _ (heat.edge G 0 Stride)
                     T0 (now)
                     _ (heat.sweeps Sweeps G W H Stride)
                  (report "heat" (shen-jit.f64 G (+ (* (/ H 2) Stride) (* 8 (/ W 2)))) T0)))

\\ ---------------------------------------------------------------------------

(matmul 400)
(mandelbrot 400 200)
(spectral 500)
(nbody 64 200)
(heat 512 512 200)
