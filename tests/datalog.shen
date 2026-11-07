\* Tests of lib/datalog.shen. Fixtures whose answers are written by hand, errors, and the engine
   against the plain definition over generated programs, under fixed and adaptive plans.
   Usage: shen-jit eval -l lib/datalog.shen -l tests/datalog.shen *\

(set dt.*checks* 0)
(set dt.*failures* 0)

(define dt.fail
  Name Got Want -> (do (set dt.*failures* (+ 1 (value dt.*failures*)))
                       (output "FAIL ~A: got ~R, want ~R~%" Name Got Want)))

(define dt.check
  Name Got Want -> (do (set dt.*checks* (+ 1 (value dt.*checks*)))
                       (if (= Got Want) ok (dt.fail Name Got Want))))

\* The reference and both kinds of plan give the same sorted tuples. *\
(define dt.runs
  Name Facts -> [(datalog.run-naive Name Facts) (datalog.run Name Facts) (dt.run-fixed Name Facts)])

\* With plans that do not follow sizes. *\
(define dt.run-fixed
  Name Facts -> (let _ (set datalog.*adaptive* false)
                     Db (datalog.run Name Facts)
                     _ (set datalog.*adaptive* true)
                  Db))

(define dt.same
  Label Facts Name Rel Want
  -> (dt.same-h (dt.runs Name Facts) Label Rel Want))

(define dt.same-h
  [] _ _ _ -> ok
  [Db | Dbs] Label Rel Want
  -> (do (dt.check (make-string "~A ~A" Label Rel) (datalog.sorted Db Rel) Want)
         (dt.same-h Dbs Label Rel Want)))

(define dt.raises
  Name Part F -> (let Got (trap-error (do (thaw F) "no error") (/. E (error-to-string E)))
                   (do (set dt.*checks* (+ 1 (value dt.*checks*)))
                       (if (dt.contains? Got Part) ok (dt.fail Name Got Part)))))

(define dt.contains?
  S Part -> true where (dt.prefix? Part S)
  "" _ -> false
  S Part -> (dt.contains? (tlstr S) Part))

(define dt.prefix?
  "" _ -> true
  _ "" -> false
  A B -> (and (= (pos A 0) (pos B 0)) (dt.prefix? (tlstr A) (tlstr B))))

\* ---- By hand. *\

(defdatalog dt.dep
  (relation imports [symbol symbol])
  (relation depends [symbol symbol])
  (relation cyclic [symbol])
  (rule (depends X Y) <-- (imports X Y))
  (rule (depends X Z) <-- (imports X Y) (depends Y Z))
  (rule (cyclic X) <-- (depends X X)))

\* A chain with a branch, and a separate cycle. *\
(set dt.dep-facts [[imports a b] [imports b c] [imports b d] [imports x y] [imports y x] [imports a b]])
(dt.same "dependencies" (value dt.dep-facts) dt.dep imports
  [[a b] [b c] [b d] [x y] [y x]])
(dt.same "dependencies" (value dt.dep-facts) dt.dep depends
  [[a b] [a c] [a d] [b c] [b d] [x x] [x y] [y x] [y y]])
(dt.same "dependencies" (value dt.dep-facts) dt.dep cyclic [[x] [y]])
(dt.same "empty" [] dt.dep depends [])

\* Two recursive atoms, where a new tuple can arrive in either and only in the second. *\
(defdatalog dt.nonlinear
  (relation edge [symbol symbol])
  (relation path [symbol symbol])
  (rule (path X Y) <-- (edge X Y))
  (rule (path X Z) <-- (path X Y) (path Y Z)))

(dt.same "nonlinear" [[edge a b]] dt.nonlinear path [[a b]])
(dt.same "nonlinear chain" [[edge a b] [edge b c] [edge c d] [edge d e]] dt.nonlinear path
  [[a b] [a c] [a d] [a e] [b c] [b d] [b e] [c d] [c e] [d e]])

\* Mutual recursion, with a head outside the cycle reading it. *\
(defdatalog dt.mutual
  (relation succ [integer integer])
  (relation even [integer])
  (relation odd [integer])
  (relation both [integer])
  (rule (even 0))
  (rule (odd Y) <-- (even X) (succ X Y))
  (rule (even Y) <-- (odd X) (succ X Y))
  (rule (both X) <-- (even X) (odd X)))

(dt.same "mutual" [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] dt.mutual even [[0] [2] [4]])
(dt.same "mutual" [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] dt.mutual odd [[1] [3]])
(dt.same "mutual" [[succ 0 1] [succ 1 2] [succ 2 3] [succ 3 4]] dt.mutual both [])
(dt.same "mutual, a cycle" [[succ 0 1] [succ 1 2] [succ 2 0]] dt.mutual both [[0] [1] [2]])

\* Constants, repeated variables, _, comparisons, strings, a rule with no atoms and a relation with
   no rules that also receives derived tuples. *\
(defdatalog dt.mixed
  (relation size [symbol integer])
  (relation name [symbol string])
  (relation link [symbol symbol])
  (relation big [symbol])
  (relation self [symbol])
  (relation linked [symbol])
  (relation pair [symbol symbol])
  (relation named [string])
  (relation fixed [symbol integer])
  (relation seeded [symbol])
  (rule (big X) <-- (size X N) (> N 10))
  (rule (self X) <-- (link X X))
  (rule (linked X) <-- (link X _))
  (rule (pair X Y) <-- (size X A) (size Y B) (< A B) (!= X Y))
  (rule (named S) <-- (name a S))
  (rule (fixed z 7))
  (rule (fixed X 8) <-- (name X "bee") (= X b))
  (rule (seeded X) <-- (link X b))
  (rule (seeded c)))

(set dt.mixed-facts [[size a 1] [size b 20] [size c 11] [size d 20]
                     [name a "ay"] [name b "bee"] [name a "alpha"]
                     [link a a] [link a b] [link c d] [link d d]
                     [seeded q]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed big [[b] [c] [d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed self [[a] [d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed linked [[a] [c] [d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed pair [[a b] [a c] [a d] [c b] [c d]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed named [["alpha"] ["ay"]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed fixed [[b 8] [z 7]])
(dt.same "mixed" (value dt.mixed-facts) dt.mixed seeded [[a] [c] [q]])

\* A rule's own constant that no fact has, and a relation wide enough to need vectors. *\
(defdatalog dt.wide
  (relation r [integer integer integer integer integer integer integer])
  (relation s [integer integer])
  (rule (s A G) <-- (r A _ _ 99 _ _ G)))
(dt.same "wide" [[r 1 2 3 99 5 6 7] [r 8 9 10 11 12 13 14] [r 1 2 3 99 5 6 7]] dt.wide s [[1 7]])
(dt.same "wide" [[r 1 2 3 99 5 6 7] [r 8 9 10 11 12 13 14]] dt.wide r
  [[1 2 3 99 5 6 7] [8 9 10 11 12 13 14]])

\* A relation of no columns. *\
(defdatalog dt.nullary
  (relation a [symbol])
  (relation some [])
  (relation none [])
  (rule (some) <-- (a _))
  (rule (none) <-- (a nothing)))
(dt.same "nullary" [[a x] [a y]] dt.nullary some [[]])
(dt.same "nullary" [[a x]] dt.nullary none [])

\* Queries. *\
(let Db (datalog.run dt.dep (value dt.dep-facts))
  (do (dt.check "ask" (datalog.sort (datalog.ask Db (depends a X))) [[a b] [a c] [a d]])
      (dt.check "ask, repeated" (datalog.sort (datalog.ask Db (depends X X))) [[x x] [y y]])
      (dt.check "ask, anything" (datalog.sort (datalog.ask Db (depends _ d))) [[a d] [b d]])
      (dt.check "ask, none" (datalog.ask Db (depends q X)) [])
      (dt.check "holds" (datalog.holds? Db [depends a c]) true)
      (dt.check "does not hold" (datalog.holds? Db [depends c a]) false)
      (dt.check "not a value" (datalog.holds? Db [depends a nowhere]) false)
      (dt.check "count" (datalog.count Db depends) 9)))

\* The program as data is the same program. *\
(datalog.define dt.data
  [[relation e [symbol symbol]]
   [relation t [symbol symbol]]
   [rule [t [var "A"] [var "B"]] [[e [var "A"] [var "B"]]]]
   [rule [t [var "A"] [var "C"]] [[t [var "A"] [var "B"]] [e [var "B"] [var "C"]]]]])
(dt.same "as data" [[e a b] [e b c]] dt.data t [[a b] [a c] [b c]])

\* A long chain, where a loop that is not a tail call would run out of stack. *\
(define dt.chain
  N N Acc -> Acc
  I N Acc -> (dt.chain (+ I 1) N [[edge I (+ I 1)] | Acc]))

(defdatalog dt.reach
  (relation edge [integer integer])
  (relation start [integer])
  (relation reach [integer])
  (rule (start 0))
  (rule (reach X) <-- (start X))
  (rule (reach Y) <-- (reach X) (edge X Y)))

(let Db (datalog.run dt.reach (dt.chain 0 20000 []))
  (dt.check "long chain" (datalog.count Db reach) 20001))

\* A rule with many variables, each loop taking those it passes on as parameters. *\
(defdatalog dt.many
  (relation r [integer integer integer integer integer integer integer integer])
  (relation h [integer integer])
  (rule (h A1 C8) <-- (r A1 A2 A3 A4 A5 A6 A7 A8)
                      (r A8 B2 B3 B4 B5 B6 B7 B8)
                      (r B8 C2 C3 C4 C5 C6 C7 C8)
                      (!= A1 A2) (!= A2 A3) (!= A3 A4) (!= A4 A5) (!= A5 A6) (!= A6 A7) (!= A7 B2)
                      (!= B2 B3) (!= B3 B4) (!= B4 B5) (!= B5 B6) (!= B6 B7) (!= B7 C2)
                      (!= C2 C3) (!= C3 C4) (!= C4 C5) (!= C5 C6) (!= C6 C7)))
(dt.same "many variables"
  [[r 1 2 3 4 5 6 7 8] [r 8 9 10 11 12 13 14 15] [r 15 16 17 18 19 20 21 22] [r 15 1 1 1 1 1 1 1]]
  dt.many h [[1 22]])

\* Tables and buffers grow well past where they start, and find what they hold. *\
(define dt.many-edges
  0 Acc -> Acc
  N Acc -> (dt.many-edges (- N 1) [[edge N (+ N 1)] | Acc]))
(let Db (datalog.run dt.reach (dt.many-edges 5000 [[edge 0 1]]))
  (do (dt.check "grown, right" (datalog.count Db reach) 5002)
      (dt.check "grown, found" (datalog.holds? Db [edge 2500 2501]) true)
      (dt.check "grown, not found" (datalog.holds? Db [edge 2501 2500]) false)))

\* Plans follow sizes as they grow, and what is generated can be read. *\
(let Db (datalog.run dt.reach (dt.chain 0 2000 []))
  (dt.check "plans again as sizes grow" (> (hd (tl (hd (tl (datalog.stats Db))))) 4) true))
(dt.check "plans are there to read" (cons? (datalog.plans dt.dep)) true)
(dt.check "code is there to read" (hd (hd (datalog.code dt.dep))) defun)

\* A rule whose order matters, written either way, gives one result. *\
(defdatalog dt.order-a
  (relation big [integer integer]) (relation tiny [integer integer]) (relation out [integer integer])
  (rule (out A C) <-- (big A B) (tiny B C)))
(defdatalog dt.order-b
  (relation big [integer integer]) (relation tiny [integer integer]) (relation out [integer integer])
  (rule (out A C) <-- (tiny B C) (big A B)))
(set dt.order-facts [[big 1 2] [big 3 2] [big 4 5] [tiny 2 9]])
(dt.same "order, one way" (value dt.order-facts) dt.order-a out [[1 9] [3 9]])
(dt.same "order, the other" (value dt.order-facts) dt.order-b out [[1 9] [3 9]])

\* The kernels themselves, with enough random tuples that hashes collide: values in a run are small
   and dense, and meet few collisions. With 300000 of them about ten pairs share a fingerprint. *\
(set dt.*bits* 88172645)

(define dt.u32
  -> (let X (value dt.*bits*)
          Y (shen-jit.bit-xor X (shen-jit.bit-and (shen-jit.shift-left X 13) 4294967295))
          Z (shen-jit.bit-xor Y (shen-jit.shift-right Y 17))
          W (shen-jit.bit-xor Z (shen-jit.bit-and (shen-jit.shift-left Z 5) 4294967295))
          _ (set dt.*bits* W)
       W))

\* Keys in a small range for the first column, so that chains are long; tuples go in a dictionary
   too, by what they should be. *\
(define dt.fill-relation
  _ 0 _ Seen -> Seen
  R N Add Seen
  -> (let A (shen-jit.bit-and (dt.u32) 524287)
          B (dt.u32)
          _ (Add R [A B])
          _ (shen.dict-> Seen [A B] true)
       (dt.fill-relation R (- N 1) Add Seen)))

(define dt.all-found
  _ _ [] Acc -> Acc
  R Find [T | Ts] Acc -> (dt.all-found R Find Ts (if (> (Find R T) 0) Acc (+ Acc 1))))

(define dt.chain-length
  P _ _ N _ _ -> N where (= P 0)
  P Next Tuples N Key Off
  -> (dt.chain-length (shen-jit.u32 Next (* 4 (- P 1))) Next Tuples
       (if (= (shen-jit.u32 Tuples (+ Off (* 8 (- P 1)))) Key) (+ N 1) -1000000000) Key Off))

\* Each key's chain holds exactly its tuples. *\
(define dt.chains
  _ _ _ _ [] _ Acc -> Acc
  Index Tuples Find Want [K | Ks] Off Acc
  -> (let P (Find (<-address Index 0) Tuples (<-address Index 2) K)
          N (dt.chain-length P (<-address Index 1) Tuples 0 K Off)
       (dt.chains Index Tuples Find Want Ks Off (if (= N (tl (assoc-or K Want))) Acc (+ Acc 1)))))

(define assoc-or
  K D -> (let E (shen.<-dict D K) [K | E]))

(define dt.key-counts
  [] _ D -> D
  [T | Ts] Column D -> (let A (dt.column T Column)
                            E (trap-error (shen.<-dict D A) (/. X 0))
                            _ (shen.dict-> D A (+ E 1))
                         (dt.key-counts Ts Column D)))

(define dt.column
  [A _] 1 -> A
  [_ B] 2 -> B)

\* Tuples not in the relation, of which some share a fingerprint with one that is. *\
(define dt.absent-found
  _ _ _ 0 Acc -> Acc
  R Find Seen N Acc
  -> (let T [(+ 524288 (shen-jit.bit-and (dt.u32) 524287)) (dt.u32)]
       (dt.absent-found R Find Seen (- N 1) (if (> (Find R T) 0) (+ Acc 1) Acc))))

\* An index by one column, with a kernel called as a closure. *\
(define dt.index-test
  Label R Tuples Column
  -> (let Index (datalog.new-index 2 [Column] (datalog.count-of R))
          _ (datalog.index-range R Index 0 (datalog.count-of R))
          Counts (dt.key-counts Tuples Column (shen.dict 8))
          K (datalog.find-kernel 2 [Column])
          Find (eval-kl [lambda a [lambda b [lambda c [lambda d [K a b c d]]]]])
          _ (dt.check (cn "kernels: an index counts its keys, " Label) (<-address Index 4) (shen.dict-count Counts))
       (dt.check (cn "kernels: each chain holds its tuples, " Label)
                 (dt.chains Index (<-address R 2) Find Counts (shen.dict-keys Counts) (* 4 (- Column 1)) 0) 0)))

(define dt.kernel-test
  -> (let R (datalog.new-relation 2)
          Add (datalog.adder 2)
          Seen (dt.fill-relation R 300000 Add (shen.dict 8))
          Tuples (shen.dict-keys Seen)
          _ (dt.check "kernels: distinct tuples counted" (datalog.count-of R) (shen.dict-count Seen))
          _ (dt.check "kernels: each tuple found" (dt.all-found R (datalog.finder 2) Tuples 0) 0)
          _ (dt.check "kernels: absent tuples not found" (dt.absent-found R (datalog.finder 2) Seen 300000 0) 0)
          _ (dt.index-test "long chains" R Tuples 1)
          _ (dt.index-test "wide keys" R Tuples 2)
       ok))

\* Too much allocation for GC stress, whose run sets this first, and the rest there has buffers moving. *\
(if (trap-error (value dt.*light*) (/. E false)) ok (dt.kernel-test))

\* Errors, each when the program is defined. *\
(dt.raises "undeclared" "no relation nope"
  (freeze (datalog.define dt.bad [[rule [nope a] []]])))
(dt.raises "undeclared in a body" "no relation nope"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [var "X"]] [[nope [var "X"]]]]])))
(dt.raises "arity" "takes 1 values, not 2"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a b c] []]])))
(dt.raises "unbound head" "Y is not bound"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [relation b [symbol]] [rule [b [var "Y"]] [[a [var "X"]]]]])))
(dt.raises "unbound comparison" "Y is not bound"
  (freeze (datalog.define dt.bad [[relation a [integer]] [rule [a [var "X"]] [[a [var "X"]] [< [var "X"] [var "Y"]]]]])))
(dt.raises "_ in a head" "cannot hold _"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [any]] [[a [var "X"]]]]])))
(dt.raises "_ compared" "cannot be compared"
  (freeze (datalog.define dt.bad [[relation a [integer]] [rule [a [var "X"]] [[a [var "X"]] [< [any] 1]]]])))
(dt.raises "a variable of two types" "X is both"
  (freeze (datalog.define dt.bad [[relation a [integer]] [relation b [symbol]] [rule [a [var "X"]] [[a [var "X"]] [b [var "X"]]]]])))
(dt.raises "a constant of the wrong type" "is not of type symbol"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a 1] []]])))
(dt.raises "ordering symbols" "orders integers"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [var "X"]] [[a [var "X"]] [< [var "X"] b]]]])))
(dt.raises "comparing two types" "are compared"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [rule [a [var "X"]] [[a [var "X"]] [= [var "X"] 1]]]])))
(dt.raises "declared twice" "declared twice"
  (freeze (datalog.define dt.bad [[relation a [symbol]] [relation a [symbol]]])))
(dt.raises "an unknown column type" "not a list of"
  (freeze (datalog.define dt.bad [[relation a [real]]])))
(dt.raises "an operator as a name" "cannot name"
  (freeze (datalog.define dt.bad [[relation < [symbol]]])))
(dt.raises "not an item" "neither"
  (freeze (datalog.define dt.bad [[other]])))
(dt.raises "a fact's relation" "has no relation"
  (freeze (datalog.run dt.dep [[nope a]])))
(dt.raises "a fact's arity" "should have 2 values"
  (freeze (datalog.run dt.dep [[imports a]])))
(dt.raises "a fact's type" "in a column of type symbol"
  (freeze (datalog.run dt.dep [[imports a 1]])))
(dt.raises "a fact's real" "in a column of type integer"
  (freeze (datalog.run dt.reach [[edge 1 (+ 0.5 0.5)]])))
(dt.raises "no such program" "no program"
  (freeze (datalog.run dt.nope [])))

\* ---- Generated programs (tests/datalog-generate.shen) against the plain definition. *\

(define dt.compare-relation
  _ _ _ [] -> ok
  Seed Db Reference [[Rel | _] | Rs]
  -> (do (dt.check (make-string "generated ~A ~A" Seed Rel) (datalog.sorted Db Rel) (datalog.sorted Reference Rel))
         (dt.compare-relation Seed Db Reference Rs)))

(define dt.compare-all
  _ [] _ _ -> ok
  Seed [Db | Dbs] Reference Relations
  -> (do (dt.compare-relation Seed Db Reference Relations)
         (dt.compare-all Seed Dbs Reference Relations)))

(define dt.generated
  0 -> ok
  N -> (let Program (dtg.program)
            Relations (hd Program)
            Rules (hd (tl Program))
            Facts (hd (tl (tl Program)))
            Name (dtg.numbered "dt.g" N)
            _ (datalog.define Name (dtg.items Relations Rules))
            Reference (datalog.run-naive Name Facts)
            Db (datalog.run Name Facts)
            Fixed (dt.run-fixed Name Facts)
            Name2 (dtg.numbered "dt.h" N)
            _ (datalog.define Name2 (append (dtg.items (dtg.shuffle Relations) [])
                                            (dtg.rule-items (dtg.shuffle (dtg.shuffle-bodies Rules)))))
            Shuffled (datalog.run Name2 (dtg.shuffle Facts))
            _ (dt.compare-all N [Fixed Db] Reference Relations)
            _ (dt.compare-relation N Shuffled Reference Relations)
         (dt.generated (- N 1))))

(dt.generated 300)

(output "~A checks, ~A failed~%" (value dt.*checks*) (value dt.*failures*))
(if (= 0 (value dt.*failures*)) true (shen-jit.exit 1))
