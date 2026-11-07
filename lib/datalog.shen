\\ Datalog: relations, facts and recursive rules, evaluated bottom up to a fixed point. It stays
\\ out of the image until asked for; load it before the code using it:
\\
\\   shen-jit eval -l lib/datalog.shen -l program.shen
\\
\\ (defdatalog dependencies
\\   (relation imports [symbol symbol])
\\   (relation depends [symbol symbol])
\\   (relation cyclic [symbol])
\\   (rule (depends X Y) <-- (imports X Y))
\\   (rule (depends X Z) <-- (imports X Y) (depends Y Z))
\\   (rule (cyclic X) <-- (depends X X)))
\\
\\ (let Db (datalog.run dependencies [[imports a b] [imports b c] [imports c a]])
\\   (datalog.ask Db (depends a X)))     \\ the tuples of depends whose first column is a
\\
\\ defdatalog          relations and rules, checked when defined; a rule is a head, or a head,
\\                     <-- and a body of atoms and comparisons
\\ datalog.define      (datalog.define Name Items), the same with the program as data
\\ datalog.run         (datalog.run Name Facts), a database from facts such as [imports a b]
\\ datalog.run-naive   the same by the plain definition, which is slow and is what the rest is
\\                     tested against
\\ datalog.tuples      (datalog.tuples Db Relation), its tuples as lists, in no particular order
\\ datalog.sorted      the same, sorted
\\ datalog.count       how many tuples a relation has
\\ datalog.holds?      (datalog.holds? Db [depends a b])
\\ datalog.ask         (datalog.ask Db (depends a X)), the tuples that match; _ matches anything
\\ datalog.match       (datalog.match Db [depends a [var "X"]]), the same with the pattern as data
\\ datalog.plans       (datalog.plans Name), the order of each rule's joins and the indexes they use
\\ datalog.code        (datalog.code Name Layout), the KL generated for a tuple layout
\\ datalog.stats       (datalog.stats Db), rounds, and per relation tuples and derivations
\\
\\ A column is a symbol, a string or an integer. A variable in a head or a comparison must appear
\\ in a positive atom of the body. Comparisons are <, >, <= and >= on integers, and = and != on
\\ values of one type. As data, a variable is [var "X"] and _ is [any].
\\
\\ Relations are sets, so duplicates count once, and the order of rules, atoms and facts does not
\\ change a result. Evaluation is a snapshot: new facts mean a new datalog.run.
\\
\\ Each rule becomes KL, compiled once per tuple layout and kept with the program. Values are
\\ interned. Since rules make no new values, how many there are is known once the facts are read,
\\ and a tuple is one integer if its columns fit, or a vector if not.

\\ ---------------------------------------------------------------------------
\\ Checking a program.

(define datalog.comparison?
  X -> (element? X [< > <= >= = !=]))

(define datalog.ordering?
  X -> (element? X [< > <= >=]))

(define datalog.fixnum?
  X -> (and (integer? X) (trap-error (do (shen-jit.bit-or X 0) true) (/. E false))))

(define datalog.value-type
  X -> symbol where (symbol? X)
  X -> string where (string? X)
  X -> integer where (datalog.fixnum? X)
  _ -> none)

(define datalog.term->form
  [var Name] -> (intern Name)
  [any] -> (intern "_")
  X -> X)

(define datalog.atom->form
  [Rel | Terms] -> [Rel | (map (/. T (datalog.term->form T)) Terms)])

(define datalog.rule->form
  Head [] -> (datalog.atom->form Head)
  Head Body -> [(datalog.atom->form Head) <-- | (map (/. A (datalog.atom->form A)) Body)])

(define datalog.relations
  _ [] Acc -> (reverse Acc)
  Name [[relation Rel Types] | Items] Acc
  -> (cases (or (not (symbol? Rel)) (variable? Rel) (datalog.comparison? Rel))
            (error "datalog ~A: ~S cannot name a relation" Name Rel)
            (cons? (assoc Rel Acc))
            (error "datalog ~A: relation ~A is declared twice" Name Rel)
            (not (datalog.types? Types))
            (error "datalog ~A: relation ~A has columns ~S, which are not a list of symbol, string or integer" Name Rel Types)
            true (datalog.relations Name Items [[Rel | Types] | Acc]))
  Name [[rule | _] | Items] Acc -> (datalog.relations Name Items Acc)
  Name [Item | _] _ -> (error "datalog ~A: ~S is neither a relation nor a rule" Name Item))

(define datalog.types?
  [] -> true
  [T | Ts] -> (and (element? T [symbol string integer]) (datalog.types? Ts))
  _ -> false)

\\ The variables' types so far, as [["X" | symbol] ...]; each atom of the body adds to them.
(define datalog.check-atom
  Say Relations Env [Rel | Terms]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (datalog.check-terms Say Terms (tl Types) Env)))
  Say _ _ Atom -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define datalog.check-terms
  _ [] [] Env -> Env
  Say [[any] | Terms] [_ | Types] Env -> (datalog.check-terms Say Terms Types Env)
  Say [[var V] | Terms] [Type | Types] Env
  -> (let Known (assoc V Env)
       (cases (empty? Known) (datalog.check-terms Say Terms Types [[V | Type] | Env])
              (= (tl Known) Type) (datalog.check-terms Say Terms Types Env)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say [X | Terms] [Type | Types] Env
  -> (if (= (datalog.value-type X) Type)
         (datalog.check-terms Say Terms Types Env)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define datalog.term-type
  Say Env [var V] -> (let Known (assoc V Env)
                       (if (empty? Known)
                           (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
                           (tl Known)))
  Say _ [any] -> (error "datalog ~A: _ cannot be compared" Say)
  Say _ X -> (let Type (datalog.value-type X)
               (if (= Type none)
                   (error "datalog ~A: ~S is not a value" Say X)
                   Type)))

(define datalog.check-comparison
  Say Env [Op A B]
  -> (let TA (datalog.term-type Say Env A)
          TB (datalog.term-type Say Env B)
       (cases (not (= TA TB)) (error "datalog ~A: ~A and ~A are compared" Say TA TB)
              (and (datalog.ordering? Op) (not (= TA integer)))
              (error "datalog ~A: ~A orders integers" Say Op)
              true Env))
  Say _ Form -> (error "datalog ~A: ~S is not a comparison" Say Form))

(define datalog.atom?
  [Op | _] -> (not (datalog.comparison? Op))
  _ -> true)

(define datalog.atoms
  [] -> []
  [L | Ls] -> (if (datalog.atom? L) [L | (datalog.atoms Ls)] (datalog.atoms Ls)))

(define datalog.comparisons
  [] -> []
  [L | Ls] -> (if (datalog.atom? L) (datalog.comparisons Ls) [L | (datalog.comparisons Ls)]))

(define datalog.check-all
  _ _ Env [] -> Env
  F Say Env [L | Ls] -> (datalog.check-all F Say (F Say Env L) Ls))

(define datalog.check-head
  Say Env Relations [Rel | Terms]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (datalog.check-head-terms Say Env Terms (tl Types))))
  Say _ _ Atom -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define datalog.check-head-terms
  _ _ [] [] -> true
  Say _ [[any] | _] _ -> (error "datalog ~A: a head cannot hold _" Say)
  Say Env [[var V] | Terms] [Type | Types]
  -> (let Known (assoc V Env)
       (cases (empty? Known) (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
              (= (tl Known) Type) (datalog.check-head-terms Say Env Terms Types)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say Env [X | Terms] [Type | Types]
  -> (if (= (datalog.value-type X) Type)
         (datalog.check-head-terms Say Env Terms Types)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define datalog.check-rule
  Name Relations Head Body
  -> (let Say (make-string "~A, rule ~R" Name (datalog.rule->form Head Body))
          Env (datalog.check-all (/. S E A (datalog.check-atom S Relations E A)) Say [] (datalog.atoms Body))
          _ (datalog.check-all (function datalog.check-comparison) Say Env (datalog.comparisons Body))
          _ (datalog.check-head Say Env Relations Head)
       [Head Body]))

(define datalog.rules
  _ _ [] -> []
  Name Relations [[relation | _] | Items] -> (datalog.rules Name Relations Items)
  Name Relations [[rule Head Body] | Items]
  -> [(datalog.check-rule Name Relations Head Body) | (datalog.rules Name Relations Items)]
  Name _ [Item | _] -> (error "datalog ~A: ~S is neither a relation nor a rule" Name Item))

(define datalog.term-constants
  [] Acc -> Acc
  [[var _] | Ts] Acc -> (datalog.term-constants Ts Acc)
  [[any] | Ts] Acc -> (datalog.term-constants Ts Acc)
  [X | Ts] Acc -> (datalog.term-constants Ts (adjoin X Acc)))

(define datalog.constants
  [] Acc -> (reverse Acc)
  [[[_ | Terms] Body] | Rules] Acc
  -> (datalog.constants Rules
       (datalog.body-constants Body (datalog.term-constants Terms Acc))))

(define datalog.body-constants
  [] Acc -> Acc
  [[_ | Terms] | Ls] Acc -> (datalog.body-constants Ls (datalog.term-constants Terms Acc)))

(define datalog.check
  Name Items -> (let Relations (datalog.relations Name Items [])
                     Rules (datalog.rules Name Relations Items)
                  [program Name Relations Rules (datalog.constants Rules [])]))

(define datalog.define
  Name Items -> (let Program (datalog.check Name Items)
                  (do (put Name datalog.program Program)
                      (put Name datalog.plan (datalog.make-plan Program))
                      (put Name datalog.compiled [])
                      Name)))

(define datalog.program
  Name -> (trap-error (get Name datalog.program)
                      (/. E (error "datalog: no program ~A" Name))))

(define datalog.check-fact
  Relations [Rel | Values]
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog: fact ~S has no relation" [Rel | Values])
              (not (= (length Values) (length (tl Types))))
              (error "datalog: fact ~S should have ~A values" [Rel | Values] (length (tl Types)))
              true (datalog.check-values [Rel | Values] Values (tl Types))))
  _ Fact -> (error "datalog: ~S is not a fact" Fact))

(define datalog.check-values
  _ [] [] -> true
  Fact [V | Vs] [T | Ts] -> (if (= (datalog.value-type V) T)
                                (datalog.check-values Fact Vs Ts)
                                (error "datalog: fact ~S has ~S in a column of type ~A" Fact V T)))

\\ ---------------------------------------------------------------------------
\\ The reference: the plain definition, over lists. Every rule runs over every tuple until a round
\\ adds nothing. It shares only the checker with what follows, and the results must agree.

(define datalog.run-naive
  Name Facts
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Rules (datalog.nth 4 Program)
          Check (map (/. F (datalog.check-fact Relations F)) Facts)
          Tables (map (/. R [(hd R)]) Relations)
       [naive Name (datalog.naive-loop Rules (datalog.naive-add-all Facts Tables))]))

(define datalog.nth
  N [X | Xs] -> (if (= N 1) X (datalog.nth (- N 1) Xs)))

(define datalog.naive-add
  [Rel | Values] [[Rel | Tuples] | Tables]
  -> (if (element? Values Tuples)
         [[Rel | Tuples] | Tables]
         [[Rel Values | Tuples] | Tables])
  Fact [Table | Tables] -> [Table | (datalog.naive-add Fact Tables)])

(define datalog.naive-add-all
  [] Tables -> Tables
  [F | Fs] Tables -> (datalog.naive-add-all Fs (datalog.naive-add F Tables)))

(define datalog.naive-loop
  Rules Tables -> (let Next (datalog.naive-add-all (datalog.naive-round Rules Tables []) Tables)
                    (if (= Next Tables) Tables (datalog.naive-loop Rules Next))))

(define datalog.naive-round
  [] _ Acc -> Acc
  [[Head Body] | Rules] Tables Acc
  -> (datalog.naive-round Rules Tables
       (datalog.naive-body (datalog.atoms Body) (datalog.comparisons Body) Head [] Tables Acc)))

(define datalog.naive-body
  [] Comparisons [Rel | Terms] Env _ Acc
  -> (if (datalog.naive-true? Comparisons Env)
         [[Rel | (map (/. T (datalog.naive-value T Env)) Terms)] | Acc]
         Acc)
  [[Rel | Terms] | Atoms] Comparisons Head Env Tables Acc
  -> (datalog.naive-tuples (tl (assoc Rel Tables)) Terms Atoms Comparisons Head Env Tables Acc))

(define datalog.naive-tuples
  [] _ _ _ _ _ _ Acc -> Acc
  [Tuple | Tuples] Terms Atoms Comparisons Head Env Tables Acc
  -> (let Bound (datalog.naive-match Terms Tuple Env)
          More (if (= Bound no)
                   Acc
                   (datalog.naive-body Atoms Comparisons Head Bound Tables Acc))
       (datalog.naive-tuples Tuples Terms Atoms Comparisons Head Env Tables More)))

(define datalog.naive-match
  [] [] Env -> Env
  [[any] | Ts] [_ | Vs] Env -> (datalog.naive-match Ts Vs Env)
  [[var X] | Ts] [V | Vs] Env
  -> (let Known (assoc X Env)
       (cases (empty? Known) (datalog.naive-match Ts Vs [[X | V] | Env])
              (= (tl Known) V) (datalog.naive-match Ts Vs Env)
              true no))
  [C | Ts] [V | Vs] Env -> (if (= C V) (datalog.naive-match Ts Vs Env) no))

(define datalog.naive-value
  [var X] Env -> (tl (assoc X Env))
  C _ -> C)

(define datalog.naive-true?
  [] _ -> true
  [[Op A B] | Rest] Env
  -> (and (datalog.compare Op (datalog.naive-value A Env) (datalog.naive-value B Env))
          (datalog.naive-true? Rest Env)))

(define datalog.compare
  < A B -> (< A B)
  > A B -> (> A B)
  <= A B -> (<= A B)
  >= A B -> (>= A B)
  = A B -> (= A B)
  != A B -> (not (= A B)))

\\ ---------------------------------------------------------------------------
\\ Plans. Relations are evaluated by strongly connected components, in dependency order. In a
\\ recursive component a rule has one variant per atom of that component, reading the new tuples
\\ of that atom's relation and all tuples of the others: a new derivation must use a new tuple
\\ somewhere, and which atom it is cannot be told in advance.

(define datalog.depends
  Rel Rules -> (datalog.depends-h Rel Rules []))

(define datalog.depends-h
  _ [] Acc -> Acc
  Rel [[[Rel | _] Body] | Rules] Acc
  -> (datalog.depends-h Rel Rules (union (map (function hd) (datalog.atoms Body)) Acc))
  Rel [_ | Rules] Acc -> (datalog.depends-h Rel Rules Acc))

\\ What each relation reaches, as [[Rel Reached ...] ...], grown until it stops.
(define datalog.reach
  Graph -> (let Next (map (/. Node [(hd Node) | (datalog.reach-from (tl Node) Graph (tl Node))]) Graph)
             (if (= Next Graph) Graph (datalog.reach Next))))

(define datalog.reach-from
  [] _ Acc -> Acc
  [R | Rs] Graph Acc -> (datalog.reach-from Rs Graph (union (tl (assoc R Graph)) Acc)))

(define datalog.component
  Rel Reach -> (datalog.unique [Rel | (datalog.mutual Rel (tl (assoc Rel Reach)) Reach)] []))

(define datalog.unique
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (datalog.unique Xs (adjoin X Acc)))

(define datalog.mutual
  _ [] _ -> []
  Rel [Rel | Rs] Reach -> (datalog.mutual Rel Rs Reach)
  Rel [R | Rs] Reach -> (if (element? Rel (tl (assoc R Reach)))
                            [R | (datalog.mutual Rel Rs Reach)]
                            (datalog.mutual Rel Rs Reach)))

(define datalog.subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (datalog.subset? Xs Ys)))

(define datalog.same-set?
  A B -> (and (datalog.subset? A B) (datalog.subset? B A)))

(define datalog.seen?
  _ [] -> false
  C [D | Ds] -> (or (datalog.same-set? C D) (datalog.seen? C Ds)))

(define datalog.distinct-sets
  [] Acc -> (reverse Acc)
  [C | Cs] Acc -> (if (datalog.seen? C Acc)
                      (datalog.distinct-sets Cs Acc)
                      (datalog.distinct-sets Cs [C | Acc])))

\\ Components with nothing left waiting go first, in the order of the declarations.
(define datalog.order
  [] _ _ Acc -> (reverse Acc)
  Waiting Reach Done Acc -> (datalog.order-h Waiting Waiting Reach Done Acc))

(define datalog.order-h
  [C | Cs] Waiting Reach Done Acc
  -> (if (datalog.subset? (difference (datalog.reached-by C Reach) C) Done)
         (datalog.order (remove C Waiting) Reach (append C Done) [C | Acc])
         (datalog.order-h Cs Waiting Reach Done Acc)))

(define datalog.reached-by
  [] _ -> []
  [R | Rs] Reach -> (union (tl (assoc R Reach)) (datalog.reached-by Rs Reach)))

(define datalog.components
  Relations Rules
  -> (let Names (map (function hd) Relations)
          Graph (map (/. R [R | (datalog.depends R Rules)]) Names)
          Reach (datalog.reach Graph)
          Cs (datalog.distinct-sets (map (/. R (datalog.component R Reach)) Names) [])
       (datalog.order Cs Reach [] [])))

(define datalog.term-vars
  [] Acc -> Acc
  [[var V] | Ts] Acc -> (datalog.term-vars Ts (adjoin V Acc))
  [_ | Ts] Acc -> (datalog.term-vars Ts Acc))

(define datalog.known?
  [var V] Bound -> (element? V Bound)
  [any] _ -> false
  _ _ -> true)

(define datalog.known-count
  [] _ -> 0
  [T | Ts] Bound -> (if (datalog.known? T Bound)
                        (+ 1 (datalog.known-count Ts Bound))
                        (datalog.known-count Ts Bound)))

\\ The next atom: the one with the most columns already known, and the first written of those.
(define datalog.best
  [A | As] Bound -> (datalog.best-h As Bound A (datalog.known-count (tl A) Bound)))

(define datalog.best-h
  [] _ Best _ -> Best
  [A | As] Bound Best N -> (let K (datalog.known-count (tl A) Bound)
                             (if (> K N)
                                 (datalog.best-h As Bound A K)
                                 (datalog.best-h As Bound Best N))))

\\ What to do with each column of an atom: [bind V i], [check T i] or nothing.
(define datalog.columns
  [] _ _ -> []
  [[any] | Ts] I Bound -> (datalog.columns Ts (+ I 1) Bound)
  [[var V] | Ts] I Bound
  -> (if (element? V Bound)
         [[check [var V] I] | (datalog.columns Ts (+ I 1) Bound)]
         [[bind V I] | (datalog.columns Ts (+ I 1) [V | Bound])])
  [C | Ts] I Bound -> [[check C I] | (datalog.columns Ts (+ I 1) Bound)])

(define datalog.key-columns
  [] _ _ -> []
  [T | Ts] I Bound -> (if (datalog.known? T Bound)
                          [I | (datalog.key-columns Ts (+ I 1) Bound)]
                          (datalog.key-columns Ts (+ I 1) Bound)))

(define datalog.key-terms
  [] _ -> []
  [T | Ts] Bound -> (if (datalog.known? T Bound)
                        [T | (datalog.key-terms Ts Bound)]
                        (datalog.key-terms Ts Bound)))

(define datalog.unkey
  [] _ _ -> []
  [T | Ts] I Bound -> (if (datalog.known? T Bound)
                          [[any] | (datalog.unkey Ts (+ I 1) Bound)]
                          [T | (datalog.unkey Ts (+ I 1) Bound)]))

(define datalog.bound-after
  [] Bound -> Bound
  [[bind V _] | Cs] Bound -> (datalog.bound-after Cs [V | Bound])
  [_ | Cs] Bound -> (datalog.bound-after Cs Bound))

\\ The comparisons that can run now, and those left.
(define datalog.ready
  [] _ Ready Left -> (@p (reverse Ready) (reverse Left))
  [[Op A B] | Cs] Bound Ready Left
  -> (if (datalog.subset? (datalog.term-vars [A B] []) Bound)
         (datalog.ready Cs Bound [[filter Op A B] | Ready] Left)
         (datalog.ready Cs Bound Ready [[Op A B] | Left])))

\\ Steps for the atoms left, each a scan of all tuples or a lookup by its known columns.
(define datalog.plan-steps
  [] Comparisons Head Bound
  -> [[emit | Head]]
  Atoms Comparisons Head Bound
  -> (let Atom (datalog.best Atoms Bound)
       (datalog.plan-atom Atom (datalog.remove-one Atom Atoms) Comparisons Head Bound)))

(define datalog.remove-one
  X [X | Xs] -> Xs
  X [Y | Xs] -> [Y | (datalog.remove-one X Xs)])

(define datalog.plan-atom
  [Rel | Terms] Atoms Comparisons Head Bound
  -> (let Keys (datalog.key-columns Terms 1 Bound)
       (if (empty? Keys)
           (datalog.plan-scan Rel all Terms Atoms Comparisons Head Bound)
           (let KeyTerms (datalog.key-terms Terms Bound)
                Rest (datalog.columns (datalog.unkey Terms 1 Bound) 1 Bound)
             (datalog.plan-next [lookup Rel Keys KeyTerms Rest] Rest Atoms Comparisons Head Bound)))))

(define datalog.plan-scan
  Rel Source Terms Atoms Comparisons Head Bound
  -> (let Columns (datalog.columns Terms 1 Bound)
       (datalog.plan-next [scan Rel Source Columns] Columns Atoms Comparisons Head Bound)))

(define datalog.plan-next
  Step Columns Atoms Comparisons Head Bound
  -> (let After (datalog.bound-after Columns Bound)
          Split (datalog.ready Comparisons After [] [])
       [Step | (append (fst Split) (datalog.plan-steps Atoms (snd Split) Head After))]))

(define datalog.plan-rule
  [Head Body] -> (datalog.plan-first (datalog.split-body Body) Head))

(define datalog.split-body
  Body -> (@p (datalog.atoms Body) (datalog.comparisons Body)))

(define datalog.plan-first
  (@p Atoms Comparisons) Head
  -> (let Split (datalog.ready Comparisons [] [] [])
       (append (fst Split) (datalog.plan-steps Atoms (snd Split) Head []))))

\\ A variant: the atom at Position reads the new tuples, and goes first.
(define datalog.plan-variant
  [Head Body] Position
  -> (let Atoms (datalog.atoms Body)
          Atom (datalog.nth Position Atoms)
          Others (datalog.without Position Atoms)
          Split (datalog.ready (datalog.comparisons Body) [] [] [])
       (append (fst Split)
               (datalog.plan-scan (hd Atom) new (tl Atom) Others (snd Split) Head []))))

(define datalog.without
  1 [_ | Xs] -> Xs
  N [X | Xs] -> [X | (datalog.without (- N 1) Xs)])

(define datalog.positions-in
  [] _ _ -> []
  [[Rel | _] | As] I Component
  -> (if (element? Rel Component)
         [I | (datalog.positions-in As (+ I 1) Component)]
         (datalog.positions-in As (+ I 1) Component)))

(define datalog.head-in?
  [[Rel | _] _] Component -> (element? Rel Component))

(define datalog.rules-in
  [] _ -> []
  [R | Rs] C -> (if (datalog.head-in? R C)
                    [R | (datalog.rules-in Rs C)]
                    (datalog.rules-in Rs C)))

(define datalog.rule-positions
  [_ Body] C -> (datalog.positions-in (datalog.atoms Body) 1 C))

(define datalog.first-plans
  [] _ -> []
  [R | Rs] C -> (if (empty? (datalog.rule-positions R C))
                    [(datalog.plan-rule R) | (datalog.first-plans Rs C)]
                    (datalog.first-plans Rs C)))

(define datalog.variant-plans
  [] _ -> []
  [R | Rs] C -> (append (map (/. P (datalog.plan-variant R P)) (datalog.rule-positions R C))
                        (datalog.variant-plans Rs C)))

\\ A plan: for each component [Relations First Variants], with First the rules that read nothing
\\ of the component, run once, and Variants the rest, run until nothing is new.
(define datalog.make-plan
  [program _ Relations Rules _]
  -> (map (/. C (let In (datalog.rules-in Rules C)
                  [C (datalog.first-plans In C) (datalog.variant-plans In C)]))
          (datalog.components Relations Rules)))

(define datalog.plans
  Name -> (get Name datalog.plan))

\\ ---------------------------------------------------------------------------
\\ Generating KL. A layout is how a tuple is held: the bits of each column in one integer, or 0
\\ for a vector. The relations' records and the values are in a vector S, read by position.

(define datalog.position
  X [X | _] N -> N
  X [_ | Ys] N -> (datalog.position X Ys (+ N 1)))

(define datalog.relation-slot
  Rel Relations -> (datalog.position Rel (map (function hd) Relations) 1))

\\ A relation's record: 0 its name, 1 its index keys, 2 the set of its tuples, 3 all of them, 4 the
\\ new ones, 5 those for the next round, 6 how many derivations, and each index from 7.
(define datalog.index-slot
  Rel Keys Indexes -> (datalog.position Keys (tl (assoc Rel Indexes)) 7))

(define datalog.steps-indexes
  [] Acc -> Acc
  [[lookup Rel Keys _ _] | Steps] Acc
  -> (datalog.steps-indexes Steps (datalog.add-index Rel Keys Acc))
  [_ | Steps] Acc -> (datalog.steps-indexes Steps Acc))

(define datalog.add-index
  Rel Keys [] -> [[Rel Keys]]
  Rel Keys [[Rel | Ks] | Rest] -> [[Rel | (if (element? Keys Ks) Ks (append Ks [Keys]))] | Rest]
  Rel Keys [Other | Rest] -> [Other | (datalog.add-index Rel Keys Rest)])

(define datalog.all-steps
  [] -> []
  [[_ First Variants] | Cs] -> (append First (append Variants (datalog.all-steps Cs))))

(define datalog.plan-indexes
  [] Acc -> Acc
  [Steps | More] Acc -> (datalog.plan-indexes More (datalog.steps-indexes Steps Acc)))

(define datalog.value-form
  [var V] _ -> (datalog.var-symbol V)
  C Constants -> (datalog.position C Constants 0))

(define datalog.var-symbol
  V -> (intern (cn "V" V)))

(define datalog.number-form
  [var V] _ -> [<-address [<-address s 0] (datalog.var-symbol V)]
  C _ -> C)

(define datalog.shift
  Layout Arity I -> (* Layout (- Arity I)))

(define datalog.column-form
  0 _ I Tuple -> [<-address Tuple (- I 1)]
  _ 1 _ Tuple -> Tuple
  Layout Arity I Tuple
  -> (let Mask (- (shen-jit.shift-left 1 Layout) 1)
       (cases (= I 1) [shen-jit.shift-right Tuple (datalog.shift Layout Arity I)]
              (= I Arity) [shen-jit.bit-and Tuple Mask]
              true [shen-jit.bit-and [shen-jit.shift-right Tuple (datalog.shift Layout Arity I)] Mask])))

(define datalog.vector-form
  [] _ V -> V
  [F | Fs] I V -> (datalog.vector-form Fs (+ I 1) [address-> V I F]))

\\ One integer from column values, the first the highest.
(define datalog.pack-form
  _ [] -> 0
  _ [F] -> F
  Layout [F | Fs] -> [shen-jit.bit-or [shen-jit.shift-left F (* Layout (length Fs))]
                                      (datalog.pack-form Layout Fs)])

(define datalog.tuple-form
  0 Forms -> (datalog.vector-form Forms 0 [absvector (length Forms)])
  Layout Forms -> (datalog.pack-form Layout Forms))

(define datalog.list-form
  [] -> []
  [F | Fs] -> [cons F (datalog.list-form Fs)])

(define datalog.key-form
  0 [F] -> F
  0 Forms -> (datalog.list-form Forms)
  Layout Forms -> (datalog.pack-form Layout Forms))

(define datalog.filter-form
  = A B Constants -> [= (datalog.value-form A Constants) (datalog.value-form B Constants)]
  != A B Constants -> [not [= (datalog.value-form A Constants) (datalog.value-form B Constants)]]
  Op A B Constants -> [Op (datalog.number-form A Constants) (datalog.number-form B Constants)])

(define datalog.step-uses
  [filter _ A B] -> (datalog.term-vars [A B] [])
  [emit _ | Terms] -> (datalog.term-vars Terms [])
  [scan _ _ Columns] -> (datalog.columns-use Columns)
  [lookup _ _ Terms Columns] -> (datalog.term-vars Terms (datalog.columns-use Columns)))

(define datalog.columns-use
  [] -> []
  [[check T _] | Cs] -> (datalog.term-vars [T] (datalog.columns-use Cs))
  [_ | Cs] -> (datalog.columns-use Cs))

(define datalog.step-binds
  [scan _ _ Columns] -> (datalog.columns-bind Columns)
  [lookup _ _ _ Columns] -> (datalog.columns-bind Columns)
  _ -> [])

(define datalog.columns-bind
  [] -> []
  [[bind V _] | Cs] -> [V | (datalog.columns-bind Cs)]
  [_ | Cs] -> (datalog.columns-bind Cs))

\\ What the steps need from before them, for the parameters of a loop.
(define datalog.live
  [] -> []
  [Step | Steps] -> (union (datalog.step-uses Step)
                           (difference (datalog.live Steps) (datalog.step-binds Step))))

(define datalog.loop-name
  Prefix N -> (intern (cn Prefix (cn ".s" (str N)))))

\\ The expression for these steps. Each atom's loop is a function of its own, so that it is a
\\ self tail call and named in a backtrace; those go to datalog.*forms*.
(define datalog.gen
  [] _ _ _ -> true
  [[filter Op A B] | Steps] Ctx Prefix N
  -> [if (datalog.filter-form Op A B (datalog.nth 3 Ctx)) (datalog.gen Steps Ctx Prefix N) true]
  [[emit Rel | Terms] | _] Ctx _ _
  -> (let Slot (datalog.relation-slot Rel (datalog.nth 2 Ctx))
          Forms (map (/. T (datalog.value-form T (datalog.nth 3 Ctx))) Terms)
       [datalog.add [<-address s Slot] (datalog.tuple-form (hd Ctx) Forms)])
  [[scan Rel Source Columns] | Steps] Ctx Prefix N
  -> (let Slot (datalog.relation-slot Rel (datalog.nth 2 Ctx))
          Field (if (= Source new) 4 3)
       (datalog.gen-loop [<-address [<-address s Slot] Field] Rel Columns Steps Ctx Prefix N))
  [[lookup Rel Keys Terms Columns] | Steps] Ctx Prefix N
  -> (let Slot (datalog.relation-slot Rel (datalog.nth 2 Ctx))
          Field (datalog.index-slot Rel Keys (datalog.nth 4 Ctx))
          Key (datalog.key-form (hd Ctx) (map (/. T (datalog.value-form T (datalog.nth 3 Ctx))) Terms))
       [let e [shen-jit.dict-find [<-address [<-address s Slot] Field] Key]
         [if [cons? e]
             (datalog.gen-loop [tl e] Rel Columns Steps Ctx Prefix N)
             true]]))

(define datalog.gen-loop
  List Rel Columns Steps Ctx Prefix N
  -> (let Name (datalog.loop-name Prefix N)
          Live (map (function datalog.var-symbol)
                    (difference (union (datalog.columns-use Columns) (datalog.live Steps))
                                (datalog.columns-bind Columns)))
          Arity (- (length (assoc Rel (datalog.nth 2 Ctx))) 1)
          Body (datalog.gen-columns Columns (hd Ctx) Arity (datalog.gen Steps Ctx Prefix (+ N 1)) (datalog.nth 3 Ctx))
          Form [defun Name [l s | Live]
                 [if [cons? l]
                     [let t [hd l] [do Body [Name [tl l] s | Live]]]
                     true]]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       [Name List s | Live]))

\\ Binds come first, as a check can read a column bound earlier in the same atom.
(define datalog.gen-columns
  Columns Layout Arity Inner Constants
  -> (datalog.gen-binds Columns Layout Arity
       (datalog.gen-checks Columns Layout Arity Inner Constants)))

(define datalog.gen-binds
  [] _ _ Inner -> Inner
  [[bind V I] | Cs] Layout Arity Inner
  -> [let (datalog.var-symbol V) (datalog.column-form Layout Arity I t)
       (datalog.gen-binds Cs Layout Arity Inner)]
  [_ | Cs] Layout Arity Inner -> (datalog.gen-binds Cs Layout Arity Inner))

(define datalog.gen-checks
  [] _ _ Inner _ -> Inner
  [[check Term I] | Cs] Layout Arity Inner Constants
  -> [if [= (datalog.column-form Layout Arity I t) (datalog.value-form Term Constants)]
         (datalog.gen-checks Cs Layout Arity Inner Constants)
         true]
  [_ | Cs] Layout Arity Inner Constants -> (datalog.gen-checks Cs Layout Arity Inner Constants))

(define datalog.gen-plan
  Steps Ctx Prefix
  -> (let Name (intern Prefix)
          Body (datalog.gen Steps Ctx Prefix 1)
          Form [defun Name [s] Body]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       Name))

(define datalog.gen-plans
  [] _ _ _ -> []
  [Steps | Rest] Ctx Prefix N
  -> [(datalog.gen-plan Steps Ctx (cn Prefix (cn ".p" (str N)))) | (datalog.gen-plans Rest Ctx Prefix (+ N 1))])

\\ The key of an index, from a tuple.
(define datalog.gen-key
  Layout Arity Keys Name
  -> (let Forms (map (/. I (datalog.column-form Layout Arity I t)) Keys)
          Form [defun Name [t] (datalog.key-form Layout Forms)]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       Name))

(define datalog.gen-keys
  [] _ _ _ _ -> []
  [Keys | More] Layout Arity Prefix N
  -> (let Name (intern (cn Prefix (cn ".k" (str N))))
       [(datalog.gen-key Layout Arity Keys Name) | (datalog.gen-keys More Layout Arity Prefix (+ N 1))]))

(define datalog.gen-components
  [] _ _ _ -> []
  [[C First Variants] | Cs] Ctx Prefix N
  -> (let Pre (cn Prefix (cn ".c" (str N)))
          FirstNames (datalog.gen-plans First Ctx (cn Pre "f") 1)
          VariantNames (datalog.gen-plans Variants Ctx (cn Pre "v") 1)
       [[C FirstNames VariantNames] | (datalog.gen-components Cs Ctx Prefix (+ N 1))]))

(define datalog.gen-relation-keys
  [] _ _ _ -> []
  [[Rel | Types] | Rs] Indexes Layout Prefix
  -> (let Keys (assoc Rel Indexes)
          Names (if (empty? Keys)
                    []
                    (datalog.gen-keys (tl Keys) Layout (length Types) (cn Prefix (cn "." (str Rel))) 1))
       [[Rel | Names] | (datalog.gen-relation-keys Rs Indexes Layout Prefix)]))

(define datalog.compile
  Name Layout
  -> (let Known (assoc Layout (get Name datalog.compiled))
       (if (cons? Known)
           (tl Known)
           (let Code (datalog.compile-new Name Layout)
                _ (put Name datalog.compiled [[Layout | Code] | (get Name datalog.compiled)])
             Code))))

\\ [Components Keys Forms], in the program's property list, one for each layout met.
(define datalog.compile-new
  Name Layout
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Constants (datalog.nth 5 Program)
          Plan (datalog.plans Name)
          Indexes (datalog.plan-indexes (datalog.all-steps Plan) [])
          Ctx [Layout Relations Constants Indexes]
          Prefix (cn "datalog." (cn (str Name) (cn "." (str Layout))))
          _ (set datalog.*forms* [])
          Components (datalog.gen-components Plan Ctx Prefix 1)
          Keys (datalog.gen-relation-keys Relations Indexes Layout Prefix)
          Forms (reverse (value datalog.*forms*))
          _ (map (/. F (eval-kl F)) Forms)
       [(map (/. C (datalog.callable-component C)) Components)
        (map (/. K [(hd K) | (map (/. F (datalog.callable F)) (tl K))]) Keys)
        Forms]))

\\ Generated functions are called from here as closures, which need no arity or lambda table entry.
(define datalog.callable
  Name -> (eval-kl [lambda x [Name x]]))

(define datalog.callable-component
  [C First Variants] -> [C (map (/. F (datalog.callable F)) First) (map (/. F (datalog.callable F)) Variants)])

(define datalog.code
  Name Layout -> (let Code (datalog.compile Name Layout) (datalog.nth 3 Code)))

\\ ---------------------------------------------------------------------------
\\ Running.

(eval-kl [defun datalog.dict-find [d k] [shen-jit.dict-find d k]])
(shen.store-arity datalog.dict-find 2)

(define datalog.add
  Rel Tuple -> (let Set (<-address Rel 2)
                    Count (shen.dict-count Set)
                    Made (address-> Rel 6 (+ 1 (<-address Rel 6)))
                    _ (shen.dict-> Set Tuple true)
                 (if (= Count (shen.dict-count Set))
                     false
                     (address-> Rel 5 [Tuple | (<-address Rel 5)]))))

(define datalog.add-to-index
  Tuple Rel Slot Key
  -> (let D (<-address Rel Slot)
          K (Key Tuple)
          Entry (datalog.dict-find D K)
       (shen.dict-> D K (if (cons? Entry) [Tuple | (tl Entry)] [Tuple]))))

(define datalog.add-to-indexes
  _ _ _ [] -> true
  Tuple Rel Slot [Key | Keys]
  -> (do (datalog.add-to-index Tuple Rel Slot Key)
         (datalog.add-to-indexes Tuple Rel (+ Slot 1) Keys)))

(define datalog.merge-tuples
  [] Rel All New Keys -> (do (address-> Rel 3 All) (address-> Rel 4 New))
  [Tuple | Tuples] Rel All New Keys
  -> (do (datalog.add-to-indexes Tuple Rel 7 Keys)
         (datalog.merge-tuples Tuples Rel [Tuple | All] [Tuple | New] Keys)))

\\ The tuples for the next round become the new ones. Gives whether there were any.
(define datalog.merge
  Rel -> (let Next (<-address Rel 5)
              _ (address-> Rel 5 [])
              _ (datalog.merge-tuples Next Rel (<-address Rel 3) [] (<-address Rel 1))
           (cons? Next)))

(define datalog.merge-all
  [] Any -> Any
  [Rel | Rels] Any -> (let Some (datalog.merge Rel) (datalog.merge-all Rels (or Some Any))))

(define datalog.call-all
  [] _ -> true
  [F | Fs] S -> (do (F S) (datalog.call-all Fs S)))

(define datalog.fixpoint
  Variants Rels S Rounds
  -> (let _ (datalog.call-all Variants S)
          Any (datalog.merge-all Rels false)
       (if Any
           (datalog.fixpoint Variants Rels S (+ Rounds 1))
           (+ Rounds 1))))

(define datalog.start-round
  [] -> true
  [Rel | Rels] -> (do (address-> Rel 4 (<-address Rel 3)) (datalog.start-round Rels)))

(define datalog.clear-new
  [] -> true
  [Rel | Rels] -> (do (address-> Rel 4 []) (datalog.clear-new Rels)))

(define datalog.run-component
  [C First Variants] Relations S Rounds
  -> (let Rels (map (/. R (<-address S (datalog.relation-slot R Relations))) C)
          _ (datalog.call-all First S)
          _ (datalog.merge-all Rels false)
          More (if (empty? Variants)
                   0
                   (do (datalog.start-round Rels)
                       (datalog.fixpoint Variants Rels S 0)))
          _ (datalog.clear-new Rels)
       (+ Rounds More)))

(define datalog.run-components
  [] _ _ Rounds -> Rounds
  [C | Cs] Relations S Rounds
  -> (datalog.run-components Cs Relations S (datalog.run-component C Relations S Rounds)))

\\ Values to integers: the program's constants first, in order, which generated code holds as
\\ numbers, then the facts'.
(define datalog.intern
  Value Interned -> (let Entry (datalog.dict-find Interned Value)
                      (if (cons? Entry)
                          (tl Entry)
                          (let Id (shen.dict-count Interned)
                               _ (shen.dict-> Interned Value Id)
                            Id))))

(define datalog.intern-all
  [] _ -> []
  [V | Vs] Interned -> (let Id (datalog.intern V Interned)
                         [Id | (datalog.intern-all Vs Interned)]))

(define datalog.intern-facts
  [] _ _ Acc -> Acc
  [[Rel | Values] | Facts] Relations Interned Acc
  -> (let Check (datalog.check-fact Relations [Rel | Values])
          Ids (datalog.intern-all Values Interned)
       (datalog.intern-facts Facts Relations Interned [[Rel | Ids] | Acc])))

(define datalog.max-arity
  [] N -> N
  [[_ | Types] | Rs] N -> (datalog.max-arity Rs (let A (length Types) (if (> A N) A N))))

\\ The smallest of a few sizes that holds every value and fits the widest relation, so that a
\\ program meets few layouts. Past those, tuples are vectors.
(define datalog.layout
  Relations Count -> (datalog.layout-h [12 20 30] (datalog.max-arity Relations 0) Count))

(define datalog.layout-h
  [] _ _ -> 0
  [Bits | More] Arity Count
  -> (if (datalog.fits? Bits Arity Count)
         Bits
         (datalog.layout-h More Arity Count)))

(define datalog.fits?
  Bits Arity Count -> (and (<= (* Arity Bits) 60) (<= Count (shen-jit.shift-left 1 Bits))))

(define datalog.asked-layout
  -1 Relations Count -> (datalog.layout Relations Count)
  0 _ _ -> 0
  Bits Relations Count -> (if (datalog.fits? Bits (datalog.max-arity Relations 0) Count)
                              Bits
                              (error "datalog: layout ~A does not fit" Bits)))

(define datalog.pack
  0 Ids -> (datalog.pack-vector Ids 0 (absvector (length Ids)))
  Layout Ids -> (datalog.pack-integer Layout Ids 0))

(define datalog.pack-vector
  [] _ V -> V
  [Id | Ids] I V -> (datalog.pack-vector Ids (+ I 1) (address-> V I Id)))

(define datalog.pack-integer
  _ [] Acc -> Acc
  Layout [Id | Ids] Acc
  -> (datalog.pack-integer Layout Ids (shen-jit.bit-or (shen-jit.shift-left Acc Layout) Id)))

(define datalog.unpack
  0 Arity T -> (datalog.unpack-vector T 0 Arity)
  Layout Arity T -> (datalog.unpack-integer Layout Arity T []))

(define datalog.unpack-vector
  _ N N -> []
  T I N -> [(<-address T I) | (datalog.unpack-vector T (+ I 1) N)])

(define datalog.unpack-integer
  _ 0 _ Acc -> Acc
  Layout N T Acc
  -> (datalog.unpack-integer Layout (- N 1) (shen-jit.shift-right T Layout)
       [(shen-jit.bit-and T (- (shen-jit.shift-left 1 Layout) 1)) | Acc]))

(define datalog.new-relation
  Rel Keys
  -> (let R (absvector (+ 7 (length Keys)))
          _ (address-> R 0 Rel)
          _ (address-> R 1 Keys)
          _ (address-> R 2 (shen.dict 8))
          _ (address-> R 3 [])
          _ (address-> R 4 [])
          _ (address-> R 5 [])
          _ (address-> R 6 0)
       (datalog.new-indexes Keys R 7)))

(define datalog.new-indexes
  [] R _ -> R
  [_ | Keys] R I -> (do (address-> R I (shen.dict 8)) (datalog.new-indexes Keys R (+ I 1))))

(define datalog.fill-state
  [] [] S _ -> S
  [[Rel | _] | Rs] [[Rel | Keys] | Ks] S I
  -> (do (address-> S I (datalog.new-relation Rel Keys))
         (datalog.fill-state Rs Ks S (+ I 1))))

(define datalog.values-vector
  Interned -> (let V (absvector (shen.dict-count Interned))
                (do (shen.dict-fold (/. K Id Acc (address-> V Id K)) Interned V) V)))

(define datalog.load-facts
  [] _ _ _ -> true
  [[Rel | Ids] | Facts] Relations S Layout
  -> (let R (<-address S (datalog.relation-slot Rel Relations))
          Set (<-address R 2)
          Tuple (datalog.pack Layout Ids)
          Count (shen.dict-count Set)
          _ (shen.dict-> Set Tuple true)
          _ (if (= Count (shen.dict-count Set))
                skip
                (address-> R 5 [Tuple | (<-address R 5)]))
       (datalog.load-facts Facts Relations S Layout)))

(define datalog.merge-state
  S I End -> (if (> I End)
                 true
                 (do (datalog.merge (<-address S I)) (address-> (<-address S I) 4 [])
                     (datalog.merge-state S (+ I 1) End))))

(define datalog.zero-counts
  S I End -> (if (> I End)
                 true
                 (do (address-> (<-address S I) 6 0) (datalog.zero-counts S (+ I 1) End))))

(define datalog.run
  Name Facts -> (datalog.run-layout Name Facts -1))

\\ Layout -1 chooses; a test can name one.
(define datalog.run-layout
  Name Facts Asked
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Interned (shen.dict 8)
          _ (datalog.intern-all (datalog.nth 5 Program) Interned)
          Ids (datalog.intern-facts Facts Relations Interned [])
          Layout (datalog.asked-layout Asked Relations (shen.dict-count Interned))
          Code (datalog.compile Name Layout)
          N (length Relations)
          S (absvector (+ 1 N))
          _ (address-> S 0 (datalog.values-vector Interned))
          _ (datalog.fill-state Relations (datalog.nth 2 Code) S 1)
          _ (datalog.load-facts Ids Relations S Layout)
          _ (datalog.merge-state S 1 N)
          Rounds (datalog.run-components (hd Code) Relations S 0)
       [db Name Layout S Interned Rounds]))

(define datalog.relation-of
  [db Name _ S | _] Rel
  -> (let Relations (datalog.nth 3 (datalog.program Name))
       (if (cons? (assoc Rel Relations))
           (<-address S (datalog.relation-slot Rel Relations))
           (error "datalog: no relation ~A" Rel))))

(define datalog.arity-of
  Name Rel -> (length (tl (assoc Rel (datalog.nth 3 (datalog.program Name))))))

(define datalog.decode
  [] _ -> []
  [Id | Ids] Values -> [(<-address Values Id) | (datalog.decode Ids Values)])

(define datalog.decode-all
  [] _ _ _ Acc -> Acc
  [T | Ts] Layout Arity Values Acc
  -> (datalog.decode-all Ts Layout Arity Values
       [(datalog.decode (datalog.unpack Layout Arity T) Values) | Acc]))

(define datalog.tuples
  [naive _ Tables] Rel
  -> (let Table (assoc Rel Tables)
       (if (empty? Table) (error "datalog: no relation ~A" Rel) (tl Table)))
  [db Name Layout S | Rest] Rel
  -> (datalog.decode-all (<-address (datalog.relation-of [db Name Layout S | Rest] Rel) 3)
                         Layout (datalog.arity-of Name Rel) (<-address S 0) []))

(define datalog.count
  [naive | Rest] Rel -> (length (datalog.tuples [naive | Rest] Rel))
  Db Rel -> (shen.dict-count (<-address (datalog.relation-of Db Rel) 2)))

(define datalog.holds?
  [naive | Rest] [Rel | Values] -> (element? Values (datalog.tuples [naive | Rest] Rel))
  [db Name Layout S Interned | Rest] [Rel | Values]
  -> (let Ids (datalog.lookup-ids Values Interned)
       (and (not (= Ids no))
            (cons? (datalog.dict-find (<-address (datalog.relation-of [db Name Layout S Interned | Rest] Rel) 2)
                                      (datalog.pack Layout Ids))))))

(define datalog.lookup-ids
  [] _ -> []
  [V | Vs] Interned -> (let Entry (datalog.dict-find Interned V)
                         (if (cons? Entry)
                             (let More (datalog.lookup-ids Vs Interned)
                               (if (= More no) no [(tl Entry) | More]))
                             no)))

(define datalog.match
  Db [Rel | Terms] -> (datalog.match-tuples (datalog.tuples Db Rel) Terms []))

(define datalog.match-tuples
  [] _ Acc -> Acc
  [T | Ts] Terms Acc -> (datalog.match-tuples Ts Terms
                          (if (= (datalog.naive-match Terms T []) no) Acc [T | Acc])))

(define datalog.stats
  [db Name Layout S _ Rounds]
  -> (let Relations (datalog.nth 3 (datalog.program Name))
       [[layout Layout] [rounds Rounds]
        | (map (/. R (let Rec (<-address S (datalog.relation-slot (hd R) Relations))
                       [(hd R) (shen.dict-count (<-address Rec 2)) (<-address Rec 6)]))
               Relations)]))

\\ ---------------------------------------------------------------------------
\\ Sorting, for a result that does not depend on the order of evaluation.

(define datalog.value<
  A B -> (< A B) where (and (number? A) (number? B))
  A _ -> true where (number? A)
  _ B -> false where (number? B)
  A B -> (datalog.text< (str A) (str B)) where (= (string? A) (string? B))
  A _ -> (string? A))

(define datalog.text<
  "" "" -> false
  "" _ -> true
  _ "" -> false
  A B -> (let X (string->n (pos A 0))
              Y (string->n (pos B 0))
           (cases (< X Y) true
                  (> X Y) false
                  true (datalog.text< (tlstr A) (tlstr B)))))

(define datalog.tuple<
  [] [] -> false
  [A | As] [B | Bs] -> (cases (datalog.value< A B) true
                              (datalog.value< B A) false
                              true (datalog.tuple< As Bs)))

(define datalog.split
  [] A B -> (@p A B)
  [X | Xs] A B -> (datalog.split Xs [X | B] A))

(define datalog.merge-sorted
  [] Bs Acc -> (append (reverse Acc) Bs)
  As [] Acc -> (append (reverse Acc) As)
  [A | As] [B | Bs] Acc -> (if (datalog.tuple< B A)
                               (datalog.merge-sorted [A | As] Bs [B | Acc])
                               (datalog.merge-sorted As [B | Bs] [A | Acc])))

(define datalog.sort
  [] -> []
  [X] -> [X]
  Xs -> (let Halves (datalog.split Xs [] [])
          (datalog.merge-sorted (datalog.sort (fst Halves)) (datalog.sort (snd Halves)) [])))

(define datalog.sorted
  Db Rel -> (datalog.sort (datalog.tuples Db Rel)))

\\ ---------------------------------------------------------------------------
\\ The surface: forms to the data above. The reader has turned [a b] into cons forms.

(define datalog.unbracket
  [cons H T] -> [H | (datalog.unbracket T)]
  X -> X)

(define datalog.item
  [relation Name Types] -> [relation Name (datalog.unbracket Types)]
  [rule Head <-- | Body] -> [rule Head Body]
  [rule Head] -> [rule Head []]
  Form -> (error "defdatalog: ~R is neither (relation Name [Types]) nor (rule Head <-- Body)" Form))

\\ A form building the data, with variables as [var "X"] and _ as [any]: left as they are they
\\ would be read as Shen's own variables.
(define datalog.quote
  [] -> []
  [H | T] -> [cons (datalog.quote H) (datalog.quote T)]
  X -> [cons any []] where (and (symbol? X) (= (str X) "_"))
  X -> [cons var [cons (str X) []]] where (variable? X)
  X -> X)

(defmacro datalog.macro
  [defdatalog Name | Items] -> [datalog.define Name (datalog.quote (map (function datalog.item) Items))]
  [datalog.ask Db Atom] -> [datalog.match Db (datalog.quote Atom)])
