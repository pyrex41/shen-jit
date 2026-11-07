\* Datalog workloads: lib/datalog.shen over a generated graph of each shape, and an actual source
   analysis, the call graph of the kernel's KL. Each row is one run: the seconds of the first run,
   which compiles, of a later one, and what it derived.
   Usage: shen-jit eval -l lib/datalog.shen -l tests/bench/datalog.shen -e '(db.main "KLAMBDA_DIR")' *\

(set db.*seed* 2463534242)

(define db.random
  N -> (let Next (shen-jit.bit-and (+ (* (value db.*seed*) 1103515) 12345) 1073741823)
            _ (set db.*seed* Next)
         (shen.mod (shen-jit.shift-right Next 8) N)))

(define db.seconds
  F -> (let T (get-time unix) R (thaw F) (@p (- (get-time unix) T) R)))

(defdatalog db.closure
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (edge Y Z)))

(defdatalog db.nonlinear
  (relation edge [integer integer])
  (relation path [integer integer])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (path Y Z)))

(defdatalog db.samegen
  (relation parent [integer integer])
  (relation same [integer integer])
  (rule (same X X) <-- (parent X _))
  (rule (same X X) <-- (parent _ X))
  (rule (same X Y) <-- (parent A X) (same A B) (parent B Y)))

(defdatalog db.mutual
  (relation edge [integer integer])
  (relation start [integer])
  (relation even [integer])
  (relation odd [integer])
  (rule (even X) <-- (start X))
  (rule (odd Y) <-- (even X) (edge X Y))
  (rule (even Y) <-- (odd X) (edge X Y)))

(defdatalog db.triangles
  (relation edge [integer integer])
  (relation triangle [integer integer integer])
  (rule (triangle X Y Z) <-- (edge X Y) (edge Y Z) (edge Z X) (< X Y) (< Y Z)))

\* Every edge's head is one of a few nodes, so that a join on it has many tuples per key. *\
(defdatalog db.skew
  (relation edge [integer integer])
  (relation two [integer integer])
  (relation count-two [integer])
  (rule (two X Z) <-- (edge X Y) (edge Y Z))
  (rule (count-two X) <-- (two X X)))

(defdatalog db.calls
  (relation defines [symbol])
  (relation calls [symbol symbol])
  (relation root [symbol])
  (relation reaches [symbol symbol])
  (relation recursive [symbol])
  (relation live [symbol])
  (relation errors [symbol])
  (rule (reaches F G) <-- (calls F G))
  (rule (reaches F H) <-- (calls F G) (reaches G H))
  (rule (recursive F) <-- (reaches F F))
  (rule (live F) <-- (root F))
  (rule (live G) <-- (live F) (calls F G) (defines G))
  (rule (errors F) <-- (reaches F simple-error) (defines F)))

(define db.random-edges
  0 _ Acc -> Acc
  M N Acc -> (db.random-edges (- M 1) N [[edge (db.random N) (db.random N)] | Acc]))

(define db.layered
  0 _ _ Acc -> Acc
  M Width Depth Acc
  -> (let Level (db.random Depth)
       (db.layered (- M 1) Width Depth
         [[parent (+ (* Level Width) (db.random Width)) (+ (* (+ Level 1) Width) (db.random Width))] | Acc])))

(define db.skewed
  0 _ _ Acc -> Acc
  M Hubs N Acc -> (db.skewed (- M 1) Hubs N
                    [(if (= 0 (db.random 2))
                         [edge (db.random N) (db.random Hubs)]
                         [edge (db.random Hubs) (db.random N)])
                     | Acc]))

\* The facts of the call graph: each defun, and each symbol that heads a form in its body. *\
(define db.heads
  [F | Args] Acc -> (db.heads-of Args (if (symbol? F) (adjoin F Acc) (db.heads F Acc)))
  _ Acc -> Acc)

(define db.heads-of
  [] Acc -> Acc
  [X | Xs] Acc -> (db.heads-of Xs (db.heads X Acc))
  _ Acc -> Acc)

(define db.not-form
  S -> (element? S [let lambda if do cons]))

(define db.form-facts
  [defun F _ Body] Acc
  -> (db.call-facts F (db.heads Body []) [[defines F] | Acc])
  _ Acc -> Acc)

(define db.call-facts
  _ [] Acc -> Acc
  F [G | Gs] Acc -> (db.call-facts F Gs (if (db.not-form G) Acc [[calls F G] | Acc])))

(define db.file-facts
  [] Acc -> Acc
  [Form | Forms] Acc -> (db.file-facts Forms (db.form-facts Form Acc)))

(define db.kl-files
  Dir -> (map (/. F (cn Dir (cn "/" F)))
              ["core.kl" "declarations.kl" "dict.kl" "load.kl" "macros.kl" "prolog.kl" "reader.kl"
               "sequent.kl" "sys.kl" "t-star.kl" "toplevel.kl" "track.kl" "types.kl" "writer.kl" "yacc.kl"]))

(define db.call-graph
  [] Acc -> [[root shen.shen] [root eval] | Acc]
  [File | Files] Acc -> (db.call-graph Files (db.file-facts (read-file File) Acc)))

(define db.row
  Label Name Facts Layout Rel
  -> (let _ (put Name datalog.compiled [])
          First (db.seconds (freeze (datalog.run-layout Name Facts Layout)))
          Second (db.seconds (freeze (datalog.run-layout Name Facts Layout)))
          Third (db.seconds (freeze (datalog.run-layout Name Facts Layout)))
          Db (snd First)
          Stats (datalog.stats Db)
       (output "~A | layout ~A | first ~A | then ~A ~A | ~A tuples | ~A~%"
               Label (hd (tl (hd Stats))) (db.ms (fst First)) (db.ms (fst Second)) (db.ms (fst Third))
               (datalog.count Db Rel) (tl Stats))))

(define db.ms
  S -> (/ (db.floor (* S 10000) 0) 10))

(define db.floor
  X I -> (if (> (+ I 1) X) I (db.floor X (+ I 1))))

(define db.rows
  _ _ _ _ [] -> ok
  Label Name Facts Rel [L | Ls] -> (do (db.row Label Name Facts L Rel) (db.rows Label Name Facts Rel Ls)))

(define db.naive
  Label Name Facts Rel
  -> (let R (db.seconds (freeze (datalog.run-naive Name Facts)))
       (output "~A | naive | ~A ms | ~A tuples~%" Label (db.ms (fst R)) (datalog.count (snd R) Rel))))

(define db.main
  Klambda
  -> (let Sparse (db.random-edges 3000 2000 [])
          Dense (db.random-edges 1500 300 [])
          Parents (db.layered 6000 40 30 [])
          Skew (db.skewed 8000 5 3000 [])
          Calls (db.call-graph (db.kl-files Klambda) [])
       (do (output "facts: calls ~A~%" (length Calls))
           (db.rows "closure, sparse" db.closure Sparse path [-1 0])
           (db.rows "closure, dense" db.closure Dense path [-1 0])
           (db.rows "nonlinear, dense" db.nonlinear Dense path [-1 0])
           (db.rows "same generation" db.samegen Parents same [-1 0])
           (db.rows "mutual" db.mutual [[start 0] | Sparse] even [-1 0])
           (db.rows "triangles" db.triangles Dense triangle [-1 0])
           (db.rows "skewed join" db.skew Skew two [-1 0])
           (db.rows "kernel call graph" db.calls Calls reaches [-1 0])
           (db.naive "closure, 300 edges" db.closure (db.random-edges 300 200 []) path)
           ok)))
