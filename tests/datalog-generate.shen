\* Random finite Datalog programs, in a deterministic sequence, for tests/datalog.shen and
   tests/datalog-swipl.shen. A program is [Relations Rules Facts]. *\

(set dtg.*seed* 12345)

(define dtg.random
  N -> (let Next (shen-jit.bit-and (+ (* (value dtg.*seed*) 1103515) 12345) 1073741823)
            _ (set dtg.*seed* Next)
         (shen.mod (shen-jit.shift-right Next 8) N)))

(define dtg.nth
  0 [X | _] -> X
  N [_ | Xs] -> (dtg.nth (- N 1) Xs))

(define dtg.choose
  Xs -> (dtg.nth (dtg.random (length Xs)) Xs))

(define dtg.times
  0 _ -> []
  N F -> (let X (thaw F) [X | (dtg.times (- N 1) F)]))

(define dtg.numbered
  Prefix N -> (intern (cn Prefix (str N))))

(define dtg.upto
  0 -> []
  N -> (append (dtg.upto (- N 1)) [N]))

(define dtg.map
  _ [] -> []
  F [X | Xs] -> (let Y (F X) [Y | (dtg.map F Xs)]))

(define dtg.value
  symbol -> (dtg.choose [p q r s t])
  integer -> (dtg.choose [-2 -1 0 1 2 3]))

\* Variables of a type have names of their own, so that a rule is well typed by construction. *\
(define dtg.vars
  symbol -> ["A" "B" "C" "D"]
  integer -> ["M" "N"])

(define dtg.type
  -> (if (= 0 (dtg.random 3)) integer symbol))

(define dtg.relation
  I -> (let Arity (+ 1 (dtg.random 3))
         [(dtg.numbered "r" I) | (dtg.times Arity (freeze (dtg.type)))]))

\* A body term: mostly a variable, some constants and some _. *\
(define dtg.term
  Type -> (let R (dtg.random 10)
            (cases (< R 7) [var (dtg.choose (dtg.vars Type))]
                   (< R 9) (dtg.value Type)
                   true [any])))

(define dtg.atom
  [Rel | Types] -> [Rel | (dtg.map (function dtg.term) Types)])

\* Variables an atom binds with a type, as [["X" | Type] ...]. *\
(define dtg.bound
  [] _ Acc -> Acc
  [[var V] | Ts] [Type | Types] Acc -> (dtg.bound Ts Types (adjoin [V | Type] Acc))
  [_ | Ts] [_ | Types] Acc -> (dtg.bound Ts Types Acc))

(define dtg.body-bound
  [] _ Acc -> Acc
  [[Rel | Ts] | As] Relations Acc
  -> (dtg.body-bound As Relations (dtg.bound Ts (tl (assoc Rel Relations)) Acc)))

(define dtg.of-type
  [] _ -> []
  [[V | Type] | Vs] Type -> [V | (dtg.of-type Vs Type)]
  [_ | Vs] Type -> (dtg.of-type Vs Type))

\* A head from variables the body binds, or constants where it binds none of that type. *\
(define dtg.head-term
  Type Bound -> (let Vars (dtg.of-type Bound Type)
                  (if (or (empty? Vars) (= 0 (dtg.random 5)))
                      (dtg.value Type)
                      [var (dtg.choose Vars)])))

(define dtg.head
  [Rel | Types] Bound -> [Rel | (dtg.map (/. T (dtg.head-term T Bound)) Types)])

\* Sometimes one comparison of what the body binds. *\
(define dtg.comparison
  Bound -> (let Numbers (dtg.of-type Bound integer)
                Symbols (dtg.of-type Bound symbol)
                R (dtg.random 8)
             (cases (and (< R 2) (cons? Numbers))
                    [[(dtg.choose [< > <= >= = !=]) [var (dtg.choose Numbers)]
                      (if (= 0 (dtg.random 2)) [var (dtg.choose Numbers)] (dtg.value integer))]]
                    (and (< R 4) (cons? Symbols))
                    [[(dtg.choose [= !=]) [var (dtg.choose Symbols)]
                      (if (= 0 (dtg.random 2)) [var (dtg.choose Symbols)] (dtg.value symbol))]]
                    true [])))

(define dtg.rule
  Relations
  -> (let Atoms (dtg.times (+ 1 (dtg.random 3)) (freeze (dtg.atom (dtg.choose Relations))))
          Bound (dtg.body-bound Atoms Relations [])
          Head (dtg.head (dtg.choose Relations) Bound)
          Tests (dtg.comparison Bound)
       [Head (append Atoms Tests)]))

(define dtg.fact
  [Rel | Types] -> [Rel | (dtg.map (function dtg.value) Types)])

(define dtg.remove-one
  X [X | Xs] -> Xs
  X [Y | Xs] -> [Y | (dtg.remove-one X Xs)])

(define dtg.shuffle
  [] -> []
  Xs -> (let X (dtg.choose Xs)
          [X | (dtg.shuffle (dtg.remove-one X Xs))]))

(define dtg.shuffle-bodies
  [] -> []
  [[Head Body] | Rules] -> (let B (dtg.shuffle Body) [[Head B] | (dtg.shuffle-bodies Rules)]))

(define dtg.rule-items
  Rules -> (map (/. R [rule (hd R) (hd (tl R))]) Rules))

(define dtg.items
  Relations Rules -> (append (map (/. R [relation (hd R) (tl R)]) Relations)
                             (dtg.rule-items Rules)))

(define dtg.program
  -> (let Relations (dtg.map (function dtg.relation) (dtg.upto (+ 2 (dtg.random 3))))
          Rules (dtg.times (+ 1 (dtg.random 5)) (freeze (dtg.rule Relations)))
          Facts (dtg.times (dtg.random 25) (freeze (dtg.fact (dtg.choose Relations))))
       [Relations Rules Facts]))
