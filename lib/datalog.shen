\\ Datalog: relations, facts and recursive rules, evaluated bottom up to a fixed point. It stays
\\ out of the image until asked for; load it after lib/native.shen, whose assembler makes its
\\ kernels, and before the code using it:
\\
\\   shen-jit eval -l lib/native.shen -l lib/datalog.shen -l program.shen
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
\\ datalog.code        (datalog.code Name), the KL those give
\\ datalog.stats       (datalog.stats Db), rounds, and per relation tuples and derivations
\\
\\ A column is a symbol, a string or an integer. A variable in a head, a comparison or a negated
\\ atom must appear in a positive atom of the body. Comparisons are <, >, <= and >= on integers,
\\ and = and != on values of one type. (not (edge X _)) holds when no tuple matches; a relation
\\ cannot depend on the negation of one that depends on it, so what is negated is complete before
\\ it is read. As data, a variable is [var "X"] and _ is [any].
\\
\\ Relations are sets, so duplicates count once, and the order of rules, atoms and facts does not
\\ change a result. Evaluation is a snapshot: new facts mean a new datalog.run.
\\
\\ Each rule becomes KL, for an order of joins, kept with the program. The order comes from the sizes
\\ of the relations as it runs, and changes when they have. Values are interned, and tuples kept
\\ flat in byte buffers: see "Storage" below.

(set datalog.*adaptive* true)
(set datalog.*plans* 0)

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
  [Rel | Terms] -> [Rel | (map (/. T (datalog.term->form T)) Terms)]
  X -> X)

(define datalog.rule->form
  Head [] -> (datalog.atom->form Head)
  Head Body -> [(datalog.atom->form Head) <-- | (map (/. A (datalog.literal->form A)) Body)])

(define datalog.literal->form
  [not Atom] -> [not (datalog.atom->form Atom)]
  Literal -> (datalog.atom->form Literal))

(define datalog.relations
  _ [] Acc -> (reverse Acc)
  Name [[relation Rel Types] | Items] Acc
  -> (cases (or (not (symbol? Rel)) (variable? Rel) (datalog.comparison? Rel) (= Rel not))
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

\\ A literal of a body is an atom, a comparison or a negated atom; the last two are conditions.
(define datalog.atom?
  [Op | _] -> (not (or (datalog.comparison? Op) (= Op not)))
  _ -> true)

\\ (not Atom): no tuple of that relation matches, with every variable in it bound elsewhere.
(define datalog.check-condition
  Say Relations Env [not [Rel | Terms]]
  -> (do (datalog.check-head Say Env Relations [Rel | Terms] true) Env)
  Say _ _ [not Atom] -> (error "datalog ~A: ~S is not an atom" Say Atom)
  Say _ Env Comparison -> (datalog.check-comparison Say Env Comparison))

(define datalog.atoms
  [] -> []
  [L | Ls] -> (if (datalog.atom? L) [L | (datalog.atoms Ls)] (datalog.atoms Ls)))

(define datalog.conditions
  [] -> []
  [L | Ls] -> (if (datalog.atom? L) (datalog.conditions Ls) [L | (datalog.conditions Ls)]))

(define datalog.check-all
  _ _ Env [] -> Env
  F Say Env [L | Ls] -> (datalog.check-all F Say (F Say Env L) Ls))

\\ An atom whose variables are all bound already: a head, or one that is negated, which alone can
\\ hold _.
(define datalog.check-head
  Say Env Relations [Rel | Terms] Negated
  -> (let Types (assoc Rel Relations)
       (cases (empty? Types) (error "datalog ~A: no relation ~A" Say Rel)
              (not (= (length Terms) (length (tl Types))))
              (error "datalog ~A: ~A takes ~A values, not ~A" Say Rel (length (tl Types)) (length Terms))
              true (datalog.check-head-terms Say Env Terms (tl Types) Negated)))
  Say _ _ Atom _ -> (error "datalog ~A: ~S is not an atom" Say Atom))

(define datalog.check-head-terms
  _ _ [] [] _ -> true
  Say Env [[any] | Terms] [_ | Types] true -> (datalog.check-head-terms Say Env Terms Types true)
  Say _ [[any] | _] _ false -> (error "datalog ~A: a head cannot hold _" Say)
  Say Env [[var V] | Terms] [Type | Types] Negated
  -> (let Known (assoc V Env)
       (cases (empty? Known) (error "datalog ~A: ~A is not bound by an atom of the body" Say V)
              (= (tl Known) Type) (datalog.check-head-terms Say Env Terms Types Negated)
              true (error "datalog ~A: ~A is both ~A and ~A" Say V (tl Known) Type)))
  Say Env [X | Terms] [Type | Types] Negated
  -> (if (= (datalog.value-type X) Type)
         (datalog.check-head-terms Say Env Terms Types Negated)
         (error "datalog ~A: ~S is not of type ~A" Say X Type)))

(define datalog.check-rule
  Name Relations Head Body
  -> (let Say (make-string "~A, rule ~R" Name (datalog.rule->form Head Body))
          Env (datalog.check-all (/. S E A (datalog.check-atom S Relations E A)) Say [] (datalog.atoms Body))
          _ (datalog.check-all (/. S E C (datalog.check-condition S Relations E C)) Say Env (datalog.conditions Body))
          _ (datalog.check-head Say Env Relations Head false)
       [Head Body]))

\\ The relations a body reads, and of those, the ones that must be complete before it runs.
(define datalog.body-relations
  [] -> []
  [[not [Rel | _]] | Ls] -> (adjoin Rel (datalog.body-relations Ls))
  [L | Ls] -> (if (datalog.atom? L) (adjoin (hd L) (datalog.body-relations Ls)) (datalog.body-relations Ls)))

(define datalog.complete-relations
  [] -> []
  [[not [Rel | _]] | Ls] -> (adjoin Rel (datalog.complete-relations Ls))
  [_ | Ls] -> (datalog.complete-relations Ls))

\\ A relation cannot depend on the negation of one that depends on it: there would be no single
\\ answer. What each relation reaches comes from the plans' datalog.reach.
(define datalog.check-strata
  Name Relations Rules
  -> (let Graph (map (/. R [(hd R) | (datalog.depends (hd R) Rules)]) Relations)
          Reach (datalog.reach Graph)
       (map (/. R (datalog.check-rule-strata Name R Reach)) Rules)))

(define datalog.check-rule-strata
  Name [[Head | Terms] Body] Reach
  -> (map (/. N (cases (= N Head)
                       (error "datalog ~A, rule ~R: ~A depends on its own negation"
                              Name (datalog.rule->form [Head | Terms] Body) Head)
                       (element? Head (tl (assoc N Reach)))
                       (error "datalog ~A, rule ~R: ~A depends on the negation of ~A, which depends on ~A"
                              Name (datalog.rule->form [Head | Terms] Body) Head N Head)
                       true ok))
          (datalog.complete-relations Body)))

\\ Each relation's stratum, as [[Rel | N] ...]: at least that of each relation its rules read, and
\\ one more than that of each they need complete. The reference evaluates by these.
(define datalog.strata
  Relations Rules -> (datalog.strata-h Rules (map (/. R [(hd R) | 0]) Relations)))

(define datalog.strata-h
  Rules S -> (let Next (datalog.strata-round Rules S)
               (if (= Next S) S (datalog.strata-h Rules Next))))

(define datalog.strata-round
  [] S -> S
  [[[Head | _] Body] | Rules] S
  -> (datalog.strata-round Rules (datalog.raise Head (datalog.body-stratum Body S) S)))

(define datalog.body-stratum
  [] _ -> 0
  [[not [Rel | _]] | Ls] S -> (datalog.max (+ 1 (tl (assoc Rel S))) (datalog.body-stratum Ls S))
  [L | Ls] S -> (if (datalog.atom? L)
                    (datalog.max (tl (assoc (hd L) S)) (datalog.body-stratum Ls S))
                    (datalog.body-stratum Ls S)))

(define datalog.raise
  Rel N [[Rel | M] | S] -> [[Rel | (datalog.max N M)] | S]
  Rel N [X | S] -> [X | (datalog.raise Rel N S)])

(define datalog.max
  A B -> (if (> A B) A B))

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
  [[not [_ | Terms]] | Ls] Acc -> (datalog.body-constants Ls (datalog.term-constants Terms Acc))
  [[_ | Terms] | Ls] Acc -> (datalog.body-constants Ls (datalog.term-constants Terms Acc)))

\\ [program Name Relations Rules Constants Strata].
(define datalog.check
  Name Items -> (let Relations (datalog.relations Name Items [])
                     Rules (datalog.rules Name Relations Items)
                     _ (datalog.check-strata Name Relations Rules)
                  [program Name Relations Rules (datalog.constants Rules []) (datalog.strata Relations Rules)]))

(define datalog.define
  Name Items -> (let Program (datalog.check Name Items)
                  (do (put Name datalog.program Program)
                      (put Name datalog.schedule (datalog.make-schedule Program))
                      (datalog.forget-code Name)
                      Name)))

(define datalog.forget-code
  Name -> (do (put Name datalog.compiled (shen.dict 8))
              (put Name datalog.indexes [])
              (put Name datalog.counter 0)))

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
          Strata (datalog.nth 6 Program)
          Check (map (/. F (datalog.check-fact Relations F)) Facts)
          Tables (map (/. R [(hd R)]) Relations)
       [naive Name (datalog.naive-strata 0 (datalog.highest Strata 0) Rules Strata
                                        (datalog.naive-add-all Facts Tables))]))

\\ Each stratum's rules to a fixed point, lowest first, so that what one negates is complete.
(define datalog.naive-strata
  K Top Rules Strata Tables
  -> (if (> K Top)
         Tables
         (datalog.naive-strata (+ K 1) Top Rules Strata
           (datalog.naive-loop (datalog.in-stratum K Rules Strata) Tables))))

(define datalog.in-stratum
  _ [] _ -> []
  K [[[Head | Terms] Body] | Rules] Strata
  -> (if (= K (tl (assoc Head Strata)))
         [[[Head | Terms] Body] | (datalog.in-stratum K Rules Strata)]
         (datalog.in-stratum K Rules Strata)))

(define datalog.highest
  [] N -> N
  [[_ | M] | S] N -> (datalog.highest S (datalog.max M N)))

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
       (datalog.naive-body (datalog.atoms Body) (datalog.conditions Body) Head [] Tables Acc)))

(define datalog.naive-body
  [] Conditions [Rel | Terms] Env Tables Acc
  -> (if (datalog.naive-true? Conditions Env Tables)
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
  [] _ _ -> true
  [[not [Rel | Terms]] | Rest] Env Tables
  -> (and (not (datalog.naive-any? (tl (assoc Rel Tables)) Terms Env))
          (datalog.naive-true? Rest Env Tables))
  [[Op A B] | Rest] Env Tables
  -> (and (datalog.compare Op (datalog.naive-value A Env) (datalog.naive-value B Env))
          (datalog.naive-true? Rest Env Tables)))

(define datalog.naive-any?
  [] _ _ -> false
  [Tuple | Tuples] Terms Env -> (or (not (= (datalog.naive-match Terms Tuple Env) no))
                                    (datalog.naive-any? Tuples Terms Env)))

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
  -> (datalog.depends-h Rel Rules (union (datalog.body-relations Body) Acc))
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

\\ The next atom. With no sizes to go by, Est is [] and it is the one with the most columns already
\\ known, and the first written of those. With sizes, the one expected to give the fewest tuples.
(define datalog.best
  [A | As] Bound [] -> (datalog.best-h As Bound A (datalog.known-count (tl A) Bound))
  [A | As] Bound Est -> (datalog.cheapest As Bound Est A (Est A Bound)))

(define datalog.best-h
  [] _ Best _ -> Best
  [A | As] Bound Best N -> (let K (datalog.known-count (tl A) Bound)
                             (if (> K N)
                                 (datalog.best-h As Bound A K)
                                 (datalog.best-h As Bound Best N))))

(define datalog.cheapest
  [] _ _ Best _ -> Best
  [A | As] Bound Est Best N -> (let K (Est A Bound)
                                 (if (< K N)
                                     (datalog.cheapest As Bound Est A K)
                                     (datalog.cheapest As Bound Est Best N))))

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

\\ The conditions that can run now, as steps, and those left. A negated atom is [absent Rel Keys
\\ Terms]: no tuple has these terms in these columns.
(define datalog.ready
  [] _ Ready Left -> (@p (reverse Ready) (reverse Left))
  [C | Cs] Bound Ready Left
  -> (if (datalog.subset? (datalog.condition-vars C) Bound)
         (datalog.ready Cs Bound [(datalog.condition-step C Bound) | Ready] Left)
         (datalog.ready Cs Bound Ready [C | Left])))

(define datalog.condition-vars
  [not [_ | Terms]] -> (datalog.term-vars Terms [])
  [_ A B] -> (datalog.term-vars [A B] []))

(define datalog.condition-step
  [not [Rel | Terms]] Bound -> [absent Rel (datalog.key-columns Terms 1 Bound) (datalog.key-terms Terms Bound)]
  [Op A B] _ -> [filter Op A B])

\\ Steps for the atoms left, each a scan of all tuples or a lookup by its known columns.
(define datalog.plan-steps
  [] Comparisons Head Bound _
  -> [[emit | Head]]
  Atoms Comparisons Head Bound Est
  -> (let Atom (datalog.best Atoms Bound Est)
       (datalog.plan-atom Atom (datalog.remove-one Atom Atoms) Comparisons Head Bound Est)))

(define datalog.remove-one
  X [X | Xs] -> Xs
  X [Y | Xs] -> [Y | (datalog.remove-one X Xs)])

(define datalog.plan-atom
  [Rel | Terms] Atoms Comparisons Head Bound Est
  -> (let Keys (datalog.key-columns Terms 1 Bound)
       (if (empty? Keys)
           (datalog.plan-scan Rel all Terms Atoms Comparisons Head Bound Est)
           (let KeyTerms (datalog.key-terms Terms Bound)
                Rest (datalog.columns (datalog.unkey Terms 1 Bound) 1 Bound)
             (datalog.plan-next [lookup Rel Keys KeyTerms Rest] Rest Atoms Comparisons Head Bound Est)))))

(define datalog.plan-scan
  Rel Source Terms Atoms Comparisons Head Bound Est
  -> (let Columns (datalog.columns Terms 1 Bound)
       (datalog.plan-next [scan Rel Source Columns] Columns Atoms Comparisons Head Bound Est)))

(define datalog.plan-next
  Step Columns Atoms Comparisons Head Bound Est
  -> (let After (datalog.bound-after Columns Bound)
          Split (datalog.ready Comparisons After [] [])
       [Step | (append (fst Split) (datalog.plan-steps Atoms (snd Split) Head After Est))]))

(define datalog.plan-rule
  [Head Body] Est
  -> (let Split (datalog.ready (datalog.conditions Body) [] [] [])
       (append (fst Split) (datalog.plan-steps (datalog.atoms Body) (snd Split) Head [] Est))))

\\ A variant: the atom at Position reads the new tuples, and goes first.
(define datalog.plan-variant
  [Head Body] Position Est
  -> (let Atoms (datalog.atoms Body)
          Atom (datalog.nth Position Atoms)
          Others (datalog.without Position Atoms)
          Split (datalog.ready (datalog.conditions Body) [] [] [])
       (append (fst Split)
               (datalog.plan-scan (hd Atom) new (tl Atom) Others (snd Split) Head [] Est))))

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

(define datalog.first-rules
  [] _ -> []
  [R | Rs] C -> (if (empty? (datalog.rule-positions R C))
                    [R | (datalog.first-rules Rs C)]
                    (datalog.first-rules Rs C)))

(define datalog.variants
  [] _ -> []
  [R | Rs] C -> (append (map (/. P [R P]) (datalog.rule-positions R C))
                        (datalog.variants Rs C)))

\\ For each component [Relations First Variants]: First the rules that read nothing of the
\\ component, run once, and Variants the rest as [Rule Position], run until nothing is new. What
\\ order each joins in is chosen when it runs.
(define datalog.make-schedule
  [program _ Relations Rules | _]
  -> (map (/. C (let In (datalog.rules-in Rules C)
                  [C (datalog.first-rules In C) (datalog.variants In C)]))
          (datalog.components Relations Rules)))

\\ The plan with no sizes to go by.
(define datalog.plans
  Name -> (map (/. C [(hd C)
                      (map (/. R (datalog.plan-rule R [])) (hd (tl C)))
                      (map (/. V (datalog.plan-variant (hd V) (hd (tl V)) [])) (hd (tl (tl C))))])
               (get Name datalog.schedule)))

\\ ---------------------------------------------------------------------------
\\ Storage. A relation's tuples are u32 columns, one after another in a byte buffer, which the
\\ collector does not scan, and its new tuples and those for the next round are ranges of that. A
\\ table of 64-bit entries, open addressed, finds a tuple or an index's key: the top half of each is
\\ the top half of its hash, which also says where it goes when the table grows, and the bottom half
\\ is the tuple's position plus one, 0 being empty. An index's chain of tuples with one key is
\\ a u32 for each tuple, the position plus one of the next.

(define datalog.stride
  0 -> 4
  N -> (* 4 N))

(set datalog.*kernels* (shen.dict 8))

(eval-kl [defun datalog.dict-find [d k] [shen-jit.dict-find d k]])
(shen.store-arity datalog.dict-find 2)

\\ A generated kernel, once, under its name. Kernels depend only on the shape of a tuple.
(define datalog.kernel
  Name Make -> (if (cons? (datalog.dict-find (value datalog.*kernels*) Name))
                   Name
                   (do (shen-jit.install-code [defun Name (thaw Make)])
                       (shen.dict-> (value datalog.*kernels*) Name true)
                       Name)))

(define datalog.kernel-name
  Prefix N Keys -> (intern (datalog.name-with Keys (cn Prefix (str N)))))

(define datalog.name-with
  [] Name -> Name
  [K | Ks] Name -> (datalog.name-with Ks (cn Name (cn "." (str K)))))

\\ The word registers and parameters of a kernel are named, as protect writes a variable.
(define datalog.column-parameter
  I -> (intern (cn "C" (str I))))

(define datalog.upto
  I N -> (if (> I N) [] [I | (datalog.upto (+ I 1) N)]))

\\ A multiplicative hash of word expressions, whose top half is what goes in the table.
(define datalog.hash-form
  [] -> (protect K)
  [C | Cs] -> (datalog.hash-more Cs [* C (protect K)]))

(define datalog.hash-more
  [] H -> H
  [C | Cs] H -> (datalog.hash-more Cs [* [bit-xor H C] (protect K)]))

(define datalog.hash-setup
  -> [[word (protect K) [bit-or [shift-left 2654435769 32] 2135587861]]])

(define datalog.offset-form
  Base 0 -> Base
  Base Off -> [+ Base Off])

\\ Add a tuple if it is not there: 1 if it was added, 0 if not, 2 if there is no room, for which
\\ datalog.grow makes room. Meta holds the count, the table's mask, how many tuples fit and how many
\\ derivations there have been, at 0, 8, 16 and 24.
(define datalog.insert-kernel
  N -> (datalog.kernel (datalog.kernel-name "datalog.k.insert." N [])
         (freeze (datalog.insert-code N))))

(define datalog.insert-code
  N -> (let Cols (map (function datalog.column-parameter) (datalog.upto 1 N))
            Name (datalog.kernel-name "datalog.k.insert." N [])
         (shen-jit.assemble Name [(protect Table) (protect Tuples) (protect Meta) | Cols]
           (append (datalog.hash-setup)
             [[word (protect Count) [u64 (protect Meta) 0]]
              [u64! (protect Meta) 24 [+ [u64 (protect Meta) 24] 1]]
              [word (protect Fp) [shift-right (datalog.hash-form Cols) 32]]
              [word (protect Mask) [u64 (protect Meta) 8]]
              [word (protect I) [bit-and (protect Fp) (protect Mask)]]
              [while true
                [word (protect Off) [shift-left (protect I) 3]]
                [word (protect E) [u64 (protect Table) (protect Off)]]
                [when [= (protect E) 0]
                  [unless [< (protect Count) [u64 (protect Meta) 16]] [return-word 2]]
                  [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
                  [word (protect P) [* (protect Count) (datalog.stride N)]]
                  [do | (datalog.store-columns Cols 0)]
                  [u64! (protect Meta) 0 [+ (protect Count) 1]]
                  [return-word 1]]
                [when [= [shift-right (protect E) 32] (protect Fp)]
                  [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (datalog.stride N)]]
                  [when [and | (datalog.same-columns Cols 0)] [return-word 0]]]
                [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

(define datalog.store-columns
  [] _ -> []
  [C | Cs] Off -> [[u32! (protect Tuples) (datalog.offset-form (protect P) Off) C]
                   | (datalog.store-columns Cs (+ Off 4))])

\\ Tests that the tuple at P holds these values.
(define datalog.same-columns
  [] _ -> []
  [C | Cs] Off -> [[= [u32 (protect Tuples) (datalog.offset-form (protect P) Off)] C]
                   | (datalog.same-columns Cs (+ Off 4))])

\\ Where these key values are in a table: the position plus one of the tuple there, or 0.
(define datalog.find-kernel
  N Keys -> (datalog.kernel (datalog.kernel-name "datalog.k.find." N Keys)
              (freeze (datalog.find-code N Keys))))

(define datalog.key-offsets
  Keys -> (map (/. K (* 4 (- K 1))) Keys))

(define datalog.same-keys
  [] [] -> []
  [Off | Offs] [C | Cs]
  -> [[= [u32 (protect Tuples) (datalog.offset-form (protect P) Off)] C] | (datalog.same-keys Offs Cs)])

(define datalog.find-code
  N Keys
  -> (let Cols (map (function datalog.column-parameter) (datalog.upto 1 (length Keys)))
          Name (datalog.kernel-name "datalog.k.find." N Keys)
       (shen-jit.assemble Name [(protect Table) (protect Tuples) (protect Mask) | Cols]
         (append (datalog.hash-setup)
           [[word (protect Fp) [shift-right (datalog.hash-form Cols) 32]]
            [word (protect I) [bit-and (protect Fp) (protect Mask)]]
            [while true
              [word (protect E) [u64 (protect Table) [shift-left (protect I) 3]]]
              [when [= (protect E) 0] [return-word 0]]
              [when [= [shift-right (protect E) 32] (protect Fp)]
                [word (protect P) [* [- [bit-and (protect E) 4294967295] 1] (datalog.stride N)]]
                [when [and | (datalog.same-keys (datalog.key-offsets Keys) Cols)]
                  [return-word [bit-and (protect E) 4294967295]]]]
              [word (protect I) [bit-and [+ (protect I) 1] (protect Mask)]]]]))))

\\ Adds the tuples from From up to To to an index, whose table has room, and gives how many keys
\\ were new. A tuple goes at the head of its key's chain.
(define datalog.index-kernel
  N Keys -> (datalog.kernel (datalog.kernel-name "datalog.k.index." N Keys)
              (freeze (datalog.index-code N Keys))))

(define datalog.tuple-columns
  [] _ -> []
  [Off | Offs] Base -> [[u32 (protect Tuples) (datalog.offset-form Base Off)] | (datalog.tuple-columns Offs Base)])

\\ Tests that the tuples at Q and Base have the same keys.
(define datalog.same-tuples
  [] -> []
  [Off | Offs]
  -> [[= [u32 (protect Tuples) (datalog.offset-form (protect Q) Off)]
         [u32 (protect Tuples) (datalog.offset-form (protect Base) Off)]]
      | (datalog.same-tuples Offs)])

(define datalog.index-code
  N Keys
  -> (let Offs (datalog.key-offsets Keys)
          Name (datalog.kernel-name "datalog.k.index." N Keys)
       (shen-jit.assemble Name [(protect Table) (protect Next) (protect Tuples) (protect Mask) (protect From) (protect To)]
         (append (datalog.hash-setup)
           [[word (protect D) 0]
            [word (protect Mk) (protect Mask)]
            [for (protect Pos) (protect From) (protect To)
              [word (protect Base) [* (protect Pos) (datalog.stride N)]]
              [word (protect Fp) [shift-right (datalog.hash-form (datalog.tuple-columns Offs (protect Base))) 32]]
              [word (protect I) [bit-and (protect Fp) (protect Mk)]]
              [while probe true
                [word (protect Off) [shift-left (protect I) 3]]
                [word (protect E) [u64 (protect Table) (protect Off)]]
                [when [= (protect E) 0]
                  [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Pos) 1]]]
                  [u32! (protect Next) [shift-left (protect Pos) 2] 0]
                  [word (protect D) [+ (protect D) 1]]
                  [exit probe]]
                [when [= [shift-right (protect E) 32] (protect Fp)]
                  [word (protect Q) [* [- [bit-and (protect E) 4294967295] 1] (datalog.stride N)]]
                  [when [and | (datalog.same-tuples Offs)]
                    [u32! (protect Next) [shift-left (protect Pos) 2] [bit-and (protect E) 4294967295]]
                    [u64! (protect Table) (protect Off) [bit-or [shift-left (protect Fp) 32] [+ (protect Pos) 1]]]
                    [exit probe]]]
                [word (protect I) [bit-and [+ (protect I) 1] (protect Mk)]]]]
            [return-word (protect D)]]))))

\\ Moves a table's entries to a larger one.
(define datalog.rehash-code
  -> (shen-jit.assemble datalog.k.rehash [(protect New) (protect Old) (protect Mask) (protect Size)]
       [[word (protect Mk) (protect Mask)]
        [for (protect J) 0 (protect Size)
          [word (protect E) [u64 (protect Old) [shift-left (protect J) 3]]]
          [unless [= (protect E) 0]
            [word (protect I) [bit-and [shift-right (protect E) 32] (protect Mk)]]
            [while place true
              [word (protect Off) [shift-left (protect I) 3]]
              [when [= [u64 (protect New) (protect Off)] 0]
                [u64! (protect New) (protect Off) (protect E)]
                [exit place]]
              [word (protect I) [bit-and [+ (protect I) 1] (protect Mk)]]]]]
        [return-word 0]]))

(datalog.kernel datalog.k.rehash (freeze (datalog.rehash-code)))

\\ A relation's record: 0 where its indexes end, 1 those in use, 2 its tuples, 3 its table, 4 its
\\ meta, 5 and 6 the tuples that are new, by position, those before 6 being all that a round reads,
\\ 7 the bytes of a tuple, and each index from 8, by a number kept with the program across runs. A
\\ run starts only those it looks up. An index is a vector of its table, chain, mask and keys.
(define datalog.new-relation
  Arity
  -> (let Room (+ 8 (shen-jit.shift-left 1 (if (> Arity 6) 6 Arity)))
          R (absvector Room)
          Stride (datalog.stride Arity)
          Meta (shen-jit.bytes 32)
          _ (shen-jit.s64! Meta 8 15)
          _ (shen-jit.s64! Meta 16 8)
          _ (address-> R 0 Room)
          _ (address-> R 1 [])
          _ (address-> R 2 (shen-jit.bytes (* 8 Stride)))
          _ (address-> R 3 (shen-jit.bytes (* 16 8)))
          _ (address-> R 4 Meta)
          _ (address-> R 5 0)
          _ (address-> R 6 0)
          _ (address-> R 7 Stride)
       R))

(define datalog.count-of
  Rec -> (shen-jit.s64 (<-address Rec 4) 0))

\\ A larger table, its entries moved.
(define datalog.larger-table
  Old OldSize NewSize
  -> (let New (shen-jit.bytes (* 8 NewSize))
          _ (datalog.k.rehash New Old (- NewSize 1) OldSize)
       New))

\\ Room for at least one more tuple, in the buffer and at half full in the table.
(define datalog.grow
  Rec
  -> (let Meta (<-address Rec 4)
          Count (shen-jit.s64 Meta 0)
          Stride (<-address Rec 7)
          Tuples (<-address Rec 2)
          Fits (/ (shen-jit.bytes-length Tuples) Stride)
          Size (+ 1 (shen-jit.s64 Meta 8))
          NewFits (if (>= Count Fits) (* 2 Fits) Fits)
          NewSize (if (>= (* 2 Count) Size) (* 2 Size) Size)
          _ (if (= NewFits Fits)
                skip
                (address-> Rec 2 (shen-jit.copy-bytes (shen-jit.bytes (* NewFits Stride)) 0 Tuples 0 (* Count Stride))))
          _ (if (= NewSize Size)
                skip
                (do (address-> Rec 3 (datalog.larger-table (<-address Rec 3) Size NewSize))
                    (shen-jit.s64! Meta 8 (- NewSize 1))))
          _ (shen-jit.s64! Meta 16 (let Half (shen-jit.shift-right NewSize 1) (if (< Half NewFits) Half NewFits)))
       true))

\\ ---------------------------------------------------------------------------
\\ Generating KL. The relations' records and the values are in a vector S, read by position.

(define datalog.position
  X [X | _] N -> N
  X [_ | Ys] N -> (datalog.position X Ys (+ N 1)))

(define datalog.relation-slot
  Rel Relations -> (datalog.position Rel (map (function hd) Relations) 1))

(define datalog.index-slot
  Rel Keys Indexes -> (datalog.position Keys (tl (assoc Rel Indexes)) 8))

(define datalog.steps-indexes
  [] _ Acc -> Acc
  [Step | Steps] Relations Acc
  -> (datalog.steps-indexes Steps Relations
       (if (datalog.indexed? Step Relations)
           (datalog.add-index (hd (tl Step)) (hd (tl (tl Step))) Acc)
           Acc)))

\\ Keys that are every column need no index: the relation's own table finds them. A negated atom
\\ with no keys needs only to know whether the relation is empty.
(define datalog.whole-tuple?
  Rel Keys Relations -> (= (length Keys) (datalog.arity-in Rel Relations)))

(define datalog.indexed?
  [lookup Rel Keys | _] Relations -> (not (datalog.whole-tuple? Rel Keys Relations))
  [absent Rel Keys | _] Relations -> (not (or (empty? Keys) (datalog.whole-tuple? Rel Keys Relations)))
  _ _ -> false)

(define datalog.arity-in
  Rel Relations -> (- (length (assoc Rel Relations)) 1))

(define datalog.add-index
  Rel Keys [] -> [[Rel Keys]]
  Rel Keys [[Rel | Ks] | Rest] -> [[Rel | (if (element? Keys Ks) Ks (append Ks [Keys]))] | Rest]
  Rel Keys [Other | Rest] -> [Other | (datalog.add-index Rel Keys Rest)])

(define datalog.value-form
  [var V] _ -> (datalog.var-symbol V)
  C Constants -> (datalog.position C Constants 0))

(define datalog.var-symbol
  V -> (intern (cn "V" V)))

(define datalog.number-form
  [var V] _ -> [<-address [<-address s 0] (datalog.var-symbol V)]
  C _ -> C)

(define datalog.filter-form
  = A B Constants -> [= (datalog.value-form A Constants) (datalog.value-form B Constants)]
  != A B Constants -> [not [= (datalog.value-form A Constants) (datalog.value-form B Constants)]]
  Op A B Constants -> [Op (datalog.number-form A Constants) (datalog.number-form B Constants)])

(define datalog.step-uses
  [filter _ A B] -> (datalog.term-vars [A B] [])
  [absent _ _ Terms] -> (datalog.term-vars Terms [])
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

(define datalog.loop-live
  Columns Steps
  -> (map (function datalog.var-symbol)
          (difference (union (datalog.columns-use Columns) (datalog.live Steps))
                      (datalog.columns-bind Columns))))

\\ Add a tuple to the relation in r, growing it if it must. Its first attempt found no room and
\\ changed nothing, so that a second is the whole of it.
(define datalog.insert-form
  N Forms
  -> (let Kernel (datalog.insert-kernel N)
          Call [Kernel [<-address r 3] [<-address r 2] [<-address r 4] | Forms]
       [let x Call [if [= x 2] [do [datalog.grow r] Call] x]]))

\\ The expression for these steps. Each atom's loop is a function of its own, so that it is a
\\ self tail call and named in a backtrace; those go to datalog.*forms*. Ctx is Relations,
\\ Constants and Indexes. A loop keeps the buffer it started with: a round can only add to a
\\ relation it reads, what it reads is already in that buffer, and growing leaves it as it is.
(define datalog.gen
  [] _ _ _ -> true
  [[filter Op A B] | Steps] Ctx Prefix N
  -> [if (datalog.filter-form Op A B (datalog.nth 2 Ctx)) (datalog.gen Steps Ctx Prefix N) true]
  [[absent Rel Keys Terms] | Steps] [Relations Constants Indexes] Prefix N
  -> [let r [<-address s (datalog.relation-slot Rel Relations)]
       [if (datalog.found-form Rel Keys Terms [Relations Constants Indexes])
           true
           (datalog.gen Steps [Relations Constants Indexes] Prefix N)]]
  [[emit Rel | Terms] | _] [Relations Constants Indexes] _ _
  -> [let r [<-address s (datalog.relation-slot Rel Relations)]
       (datalog.insert-form (datalog.arity-in Rel Relations)
         (map (/. T (datalog.value-form T Constants)) Terms))]
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Stride (datalog.stride (datalog.arity-in Rel Relations))
          Start (if (= Source new) [* [<-address r 5] Stride] 0)
       [let r [<-address s (datalog.relation-slot Rel Relations)]
         (datalog.gen-scan Start [* [<-address r 6] Stride] Stride Columns Steps
                           [Relations Constants Indexes] Prefix N)])
  [[lookup Rel Keys Terms Columns] | Steps] [Relations Constants Indexes] Prefix N
  -> (let Forms (map (/. T (datalog.value-form T Constants)) Terms)
          Find (datalog.find-kernel (datalog.arity-in Rel Relations) Keys)
          Ctx [Relations Constants Indexes]
       [let r [<-address s (datalog.relation-slot Rel Relations)]
         (if (datalog.whole-tuple? Rel Keys Relations)
             [if [> [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Forms] 0]
                 (datalog.gen Steps Ctx Prefix N)
                 true]
             (let Field (datalog.index-slot Rel Keys Indexes)
                  Stride (datalog.stride (datalog.arity-in Rel Relations))
               [let i [<-address r Field]
                 [let p [Find [<-address i 0] [<-address r 2] [<-address i 2] | Forms]
                   [if [> p 0]
                       (datalog.gen-chain Stride Columns Steps Ctx Prefix N)
                       true]]]))]))

\\ Whether the relation in r has a tuple with these terms in these columns.
(define datalog.found-form
  _ [] _ _ -> [> [<-address r 6] 0]
  Rel Keys Terms [Relations Constants Indexes]
  -> (let Forms (map (/. T (datalog.value-form T Constants)) Terms)
          Find (datalog.find-kernel (datalog.arity-in Rel Relations) Keys)
       (if (datalog.whole-tuple? Rel Keys Relations)
           [> [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | Forms] 0]
           (let I [<-address r (datalog.index-slot Rel Keys Indexes)]
             [> [Find [<-address I 0] [<-address r 2] [<-address I 2] | Forms] 0]))))

\\ A loop over the tuples from byte Start to byte End of the relation in r.
(define datalog.gen-scan
  Start End Stride Columns Steps Ctx Prefix N
  -> (let Name (datalog.loop-name Prefix N)
          Live (datalog.loop-live Columns Steps)
          Body (datalog.gen-columns Columns l (datalog.nth 2 Ctx) (datalog.gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [l e b s | Live]
                 [if [< l e]
                     [do Body [Name [+ l Stride] e b s | Live]]
                     true]]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       [Name Start End [<-address r 2] s | Live]))

\\ A loop along a chain, from p and the index in i of the relation in r.
(define datalog.gen-chain
  Stride Columns Steps Ctx Prefix N
  -> (let Name (datalog.loop-name Prefix N)
          Live (datalog.loop-live Columns Steps)
          Body (datalog.gen-columns Columns l (datalog.nth 2 Ctx) (datalog.gen Steps Ctx Prefix (+ N 1)))
          Form [defun Name [p n b s | Live]
                 [if [> p 0]
                     [let q [- p 1]
                       [let l [* q Stride]
                         [do Body [Name [shen-jit.u32 n [* q 4]] n b s | Live]]]]
                     true]]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       [Name p [<-address i 1] [<-address r 2] s | Live]))

(define datalog.column-form
  Base I -> [shen-jit.u32 b (if (= I 1) Base [+ Base (* 4 (- I 1))])])

\\ Binds come first, as a check can read a column bound earlier in the same atom.
(define datalog.gen-columns
  Columns Base Constants Inner
  -> (datalog.gen-binds Columns Base (datalog.gen-checks Columns Base Constants Inner)))

(define datalog.gen-binds
  [] _ Inner -> Inner
  [[bind V I] | Cs] Base Inner
  -> [let (datalog.var-symbol V) (datalog.column-form Base I) (datalog.gen-binds Cs Base Inner)]
  [_ | Cs] Base Inner -> (datalog.gen-binds Cs Base Inner))

(define datalog.gen-checks
  [] _ _ Inner -> Inner
  [[check Term I] | Cs] Base Constants Inner
  -> [if [= (datalog.column-form Base I) (datalog.value-form Term Constants)]
         (datalog.gen-checks Cs Base Constants Inner)
         true]
  [_ | Cs] Base Constants Inner -> (datalog.gen-checks Cs Base Constants Inner))

(define datalog.gen-plan
  Steps Ctx Prefix
  -> (let Name (intern Prefix)
          Body (datalog.gen Steps Ctx Prefix 1)
          Form [defun Name [s] Body]
          _ (set datalog.*forms* [Form | (value datalog.*forms*)])
       Name))

(define datalog.next-name
  Name
  -> (let N (get Name datalog.counter)
          _ (put Name datalog.counter (+ N 1))
       (cn "datalog." (cn (str Name) (cn ".p" (str N))))))

\\ Generated functions are called from here as closures, which need no arity or lambda table entry.
(define datalog.callable
  Name -> (eval-kl [lambda x [Name x]]))

\\ A kernel's form shows what it was written as; it is installed already.
(define datalog.install
  Forms -> (map (/. F (if (= (hd F) define-native) skip (eval-kl F))) Forms))

\\ The code for these steps, kept with the program, as [Closure | Forms]. There are only so many
\\ orders a rule can join in.
(define datalog.compiled
  Name Steps Relations Constants
  -> (let Cache (get Name datalog.compiled)
          Entry (datalog.dict-find Cache Steps)
       (if (cons? Entry)
           (tl Entry)
           (let Ctx [Relations Constants (get Name datalog.indexes)]
                Prefix (datalog.next-name Name)
                Fn (datalog.gen-either Steps Ctx Prefix)
                Forms (reverse (value datalog.*forms*))
                _ (datalog.install Forms)
                Code [(datalog.callable Fn) | Forms]
                _ (shen.dict-> Cache Steps Code)
             Code))))

\\ ---------------------------------------------------------------------------
\\ Native joins. A plan becomes one kernel of word registers, written with lib/native.shen's
\\ structured control, which looks up, compares and inserts inline and calls nothing. A variable
\\ costs no register: it is read from its tuple's column where it is used. When a relation it adds
\\ to has no room, the kernel gives where its outer loop stood, plus one, and a KL function grows
\\ the relation and calls it again from there, as deriving a tuple twice does no harm. A plan the
\\ registers cannot hold, or anything else the assembler refuses, stays KL.

(set datalog.*native* true)
(set datalog.*fallbacks* 0)
(set datalog.*labels* 0)

(define datalog.gen-either
  Steps Ctx Prefix
  -> (if (value datalog.*native*)
         (trap-error (do (set datalog.*forms* []) (datalog.native-plan Steps Ctx Prefix))
                     (/. E (do (set datalog.*fallbacks* (+ 1 (value datalog.*fallbacks*)))
                               (set datalog.*forms* [])
                               (datalog.gen-plan Steps Ctx Prefix))))
         (do (set datalog.*forms* []) (datalog.gen-plan Steps Ctx Prefix))))

(define datalog.word-name
  Prefix N -> (intern (cn Prefix (str N))))

\\ A kernel's parameter, as [Name | KL form computing it from s and start], each once.
(define datalog.param
  Name Form -> (do (if (cons? (assoc Name (value datalog.*params*)))
                       skip
                       (set datalog.*params* (append (value datalog.*params*) [[Name | Form]])))
                   Name))

(define datalog.record-form
  Slot -> [<-address s Slot])

(define datalog.tuples-param
  Slot -> (datalog.param (datalog.word-name "Tup" Slot) [<-address (datalog.record-form Slot) 2]))

(define datalog.mask
  -> 4294967295)

\\ The word a term stands for: an interned value.
(define datalog.native-value
  [var V] Env _ -> (tl (assoc V Env))
  C _ Constants -> (datalog.position C Constants 0))

\\ The integer a term stands for, from the run's integers by value.
(define datalog.native-integer
  [var V] Env [_ _ _ N] -> [u64 (datalog.param (intern "Ints") [<-address s (+ 1 N)]) [shift-left (tl (assoc V Env)) 3]]
  C _ _ -> C)

(define datalog.native-test
  = A B Env [R Constants | X] -> [= (datalog.native-value A Env Constants) (datalog.native-value B Env Constants)]
  != A B Env [R Constants | X] -> [!= (datalog.native-value A Env Constants) (datalog.native-value B Env Constants)]
  Op A B Env Ctx -> [Op (datalog.native-integer A Env Ctx) (datalog.native-integer B Env Ctx)])

\\ Columns of the tuple whose first byte is Base in Tuples.
(define datalog.column-word
  Tuples Base I -> [u32 Tuples (datalog.offset-form Base (* 4 (- I 1)))])

(define datalog.native-binds
  [] _ _ Env -> Env
  [[bind V I] | Cs] Tuples Base Env -> (datalog.native-binds Cs Tuples Base [[V | (datalog.column-word Tuples Base I)] | Env])
  [_ | Cs] Tuples Base Env -> (datalog.native-binds Cs Tuples Base Env))

\\ Checks come after binds, as a check can read a column bound earlier in the same atom.
(define datalog.native-checks
  [] _ _ _ _ -> []
  [[check T I] | Cs] Tuples Base Env Constants
  -> [[= (datalog.column-word Tuples Base I) (datalog.native-value T Env Constants)]
      | (datalog.native-checks Cs Tuples Base Env Constants)]
  [_ | Cs] Tuples Base Env Constants -> (datalog.native-checks Cs Tuples Base Env Constants))

\\ Statements for these steps. Outer is the outermost scan's position, from which a kernel without
\\ room starts again; none before the first step, and restart when that step is not a scan.
(define datalog.native-steps
  [] _ _ _ _ -> []
  [[filter Op A B] | Steps] Ctx Env Level Outer
  -> [[when (datalog.native-test Op A B Env Ctx) | (datalog.native-steps Steps Ctx Env Level Outer)]]
  [[absent Rel Keys Terms] | Steps] Ctx Env Level Outer
  -> (datalog.native-absent Rel Keys Terms Steps Ctx Env Level Outer)
  [[emit Rel | Terms] | _] Ctx Env _ Outer -> (datalog.native-insert Rel Terms Ctx Env Outer)
  [[scan Rel Source Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          From (if (and (= Outer none) (= Level 1))
                   (datalog.param (intern "Start") start)
                   (datalog.param (datalog.word-name "From" Level) (if (= Source new) [<-address (datalog.record-form Slot) 5] 0)))
          To (datalog.param (datalog.word-name "To" Level) [<-address (datalog.record-form Slot) 6])
          P (datalog.word-name "P" Level)
          B (datalog.word-name "B" Level)
          Inner (datalog.native-binds Columns Tuples B Env)
       [[for P From To
          [word B [* P Stride]]
          | (datalog.guarded (datalog.native-checks Columns Tuples B Inner Constants)
              (datalog.native-steps Steps Ctx Inner (+ Level 1) (if (and (= Outer none) (= Level 1)) P (datalog.outer Outer))))]])
  [[lookup Rel Keys Terms Columns] | Steps] [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Values (map (/. T (datalog.native-value T Env Constants)) Terms)
       (if (datalog.whole-tuple? Rel Keys Relations)
           (datalog.native-member Rel Slot Values Steps Ctx Env Level (datalog.outer Outer))
           (datalog.native-chain Rel Slot Keys Values Columns Steps Ctx Env Level (datalog.outer Outer)))))

\\ Only a scan at the outermost level can start again partway: below any other step, a kernel with
\\ no room starts again from the beginning.
(define datalog.outer
  none -> restart
  Outer -> Outer)

\\ The tuple these values make, if the relation has it, by its own table.
(define datalog.native-member
  Rel Slot Values Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          Table (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
          Mask (datalog.param (datalog.word-name "Mask" Slot) [shen-jit.u32 [<-address (datalog.record-form Slot) 4] 8])
          Q (datalog.word-name "Q" Level)
          Probe (datalog.word-name "probe" Level)
       (datalog.probe-loop Probe Values Table Mask Q Stride (datalog.equal-columns Tuples Q Values 1)
         [[do | (datalog.native-steps Steps [Relations Constants Indexes N] Env (+ Level 1) Outer)]
          [exit Probe]])))

\\ A table's probe for these values: Q is the byte of each tuple with their fingerprint, Matches
\\ whether it has them, and Found what follows if it does, which leaves the loop itself.
(define datalog.probe-loop
  Probe Values Table Mask Q Stride Matches Found
  -> [[word (protect Fp) [shift-right (datalog.hash-form Values) 32]]
      [word (protect I) [bit-and (protect Fp) Mask]]
      [while Probe true
        [word (protect E) [u64 Table [shift-left (protect I) 3]]]
        [when [= (protect E) 0] [exit Probe]]
        [when [= [shift-right (protect E) 32] (protect Fp)]
          [word Q [* [- [bit-and (protect E) (datalog.mask)] 1] Stride]]
          [when [and | Matches] | Found]]
        [word (protect I) [bit-and [+ (protect I) 1] Mask]]]])

\\ The steps after a negated atom, in a block that a tuple it matches leaves: by the relation's own
\\ table for a whole tuple, an index's table for some columns, and its size for none.
(define datalog.native-absent
  Rel Keys Terms Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Slot (datalog.relation-slot Rel Relations)
          Rest (datalog.native-steps Steps Ctx Env Level Outer)
          Values (map (/. T (datalog.native-value T Env Constants)) Terms)
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Tuples (datalog.tuples-param Slot)
          Block (datalog.native-label "absent")
          Q (datalog.word-name "Q" Level)
       (cases (empty? Keys)
              [[when [= (datalog.param (datalog.word-name "Size" Slot) [<-address (datalog.record-form Slot) 6]) 0] | Rest]]
              (datalog.whole-tuple? Rel Keys Relations)
              [[block Block
                 | (append (datalog.probe-loop (datalog.native-label "probe") Values
                             (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
                             (datalog.param (datalog.word-name "Mask" Slot) [shen-jit.u32 [<-address (datalog.record-form Slot) 4] 8])
                             Q Stride (datalog.equal-columns Tuples Q Values 1) [[exit Block]])
                           Rest)]]
              true
              (let Field (datalog.index-slot Rel Keys Indexes)
                   Index [<-address (datalog.record-form Slot) Field]
                [[block Block
                   | (append (datalog.probe-loop (datalog.native-label "probe") Values
                               (datalog.param (datalog.index-name "Itab" Slot Field) [<-address Index 0])
                               (datalog.param (datalog.index-name "Imask" Slot Field) [<-address Index 2])
                               Q Stride (datalog.equal-keys Tuples Q Keys Values) [[exit Block]])
                             Rest)]]))))

(define datalog.index-name
  Prefix Slot Field -> (intern (cn Prefix (cn (str Slot) (cn "x" (str Field))))))

\\ A name for a block or loop, of its own within a kernel.
(define datalog.native-label
  Kind -> (do (set datalog.*labels* (+ 1 (value datalog.*labels*)))
              (intern (cn Kind (cn "." (str (value datalog.*labels*)))))))

(define datalog.equal-columns
  _ _ [] _ -> []
  Tuples Base [V | Vs] I -> [[= (datalog.column-word Tuples Base I) V] | (datalog.equal-columns Tuples Base Vs (+ I 1))])

(define datalog.equal-keys
  _ _ [] [] -> []
  Tuples Base [K | Ks] [V | Vs] -> [[= (datalog.column-word Tuples Base K) V] | (datalog.equal-keys Tuples Base Ks Vs)])

\\ The tuples with these values for Keys, through an index: its table finds the first, and its chain
\\ the rest.
(define datalog.native-chain
  Rel Slot Keys Values Columns Steps [Relations Constants Indexes N] Env Level Outer
  -> (let Ctx [Relations Constants Indexes N]
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Field (datalog.index-slot Rel Keys Indexes)
          Index [<-address (datalog.record-form Slot) Field]
          Tuples (datalog.tuples-param Slot)
          Table (datalog.param (datalog.index-name "Itab" Slot Field) [<-address Index 0])
          Next (datalog.param (datalog.index-name "Inext" Slot Field) [<-address Index 1])
          Mask (datalog.param (datalog.index-name "Imask" Slot Field) [<-address Index 2])
          P (datalog.word-name "P" Level)
          Q (datalog.word-name "Q" Level)
          Probe (datalog.word-name "probe" Level)
          Chain (datalog.word-name "chain" Level)
          Inner (datalog.native-binds Columns Tuples Q Env)
       [[word P 0]
        | (append
            (datalog.probe-loop Probe Values Table Mask Q Stride (datalog.equal-keys Tuples Q Keys Values)
              [[word P [bit-and (protect E) (datalog.mask)]] [exit Probe]])
        [[while Chain [> P 0]
          [word Q [* [- P 1] Stride]]
          [do | (datalog.guarded (datalog.native-checks Columns Tuples Q Inner Constants)
                  (datalog.native-steps Steps Ctx Inner (+ Level 1) Outer))]
          [word P [u32 Next [shift-left [- P 1] 2]]]]])]))

\\ Statements that run only when these checks hold.
(define datalog.guarded
  [] Statements -> Statements
  Checks Statements -> [[when [and | Checks] | Statements]])

\\ Adds the tuple these values make, as datalog.insert-kernel does, or gives where to start again.
(define datalog.native-insert
  Rel Terms [Relations Constants Indexes N] Env Outer
  -> (let Slot (datalog.relation-slot Rel Relations)
          Stride (datalog.stride (datalog.arity-in Rel Relations))
          Values (map (/. T (datalog.native-value T Env Constants)) Terms)
          Tuples (datalog.tuples-param Slot)
          Table (datalog.param (datalog.word-name "Tab" Slot) [<-address (datalog.record-form Slot) 3])
          Meta (datalog.param (datalog.word-name "Meta" Slot) [<-address (datalog.record-form Slot) 4])
          Again (if (element? Outer [none restart]) 1 [+ Outer 1])
       [[word (protect Count) [u64 Meta 0]]
        [u64! Meta 24 [+ [u64 Meta 24] 1]]
        [word (protect Fp) [shift-right (datalog.hash-form Values) 32]]
        [word (protect I) [bit-and (protect Fp) [u64 Meta 8]]]
        [while insert true
          [word (protect E) [u64 Table [shift-left (protect I) 3]]]
          [when [= (protect E) 0]
            [unless [< (protect Count) [u64 Meta 16]] [return-word Again]]
            [u64! Table [shift-left (protect I) 3] [bit-or [shift-left (protect Fp) 32] [+ (protect Count) 1]]]
            [word (protect Pe) [* (protect Count) Stride]]
            [do | (datalog.store-values Tuples Values 0)]
            [u64! Meta 0 [+ (protect Count) 1]]
            [exit insert]]
          [when [= [shift-right (protect E) 32] (protect Fp)]
            [word (protect Pe) [* [- [bit-and (protect E) (datalog.mask)] 1] Stride]]
            [when [and | (datalog.equal-columns Tuples (protect Pe) Values 1)] [exit insert]]]
          [word (protect I) [bit-and [+ (protect I) 1] [u64 Meta 8]]]]]))

(define datalog.store-values
  _ [] _ -> []
  Tuples [V | Vs] Off -> [[u32! Tuples (datalog.offset-form (protect Pe) Off) V] | (datalog.store-values Tuples Vs (+ Off 4))])

(define datalog.head-slot
  [] _ -> (simple-error "datalog: a plan with no head")
  [[emit Rel | _] | _] Relations -> (datalog.relation-slot Rel Relations)
  [_ | Steps] Relations -> (datalog.head-slot Steps Relations))

\\ The kernel, and the KL that calls it: W starts it where its first loop starts, and W.go grows the
\\ relation it adds to and calls it again for as long as it runs out of room.
(define datalog.native-plan
  Steps [Relations Constants Indexes] Prefix
  -> (let N (length Relations)
          Ctx [Relations Constants Indexes N]
          _ (set datalog.*params* [])
          _ (set datalog.*labels* 0)
          Body (datalog.native-steps Steps Ctx [] 1 none)
          Params (value datalog.*params*)
          Kernel (intern (cn Prefix ".k"))
          Written (append (datalog.hash-setup) Body [[return-word 0]])
          Code (shen-jit.assemble Kernel (map (function hd) Params) Written)
          _ (shen-jit.install-code [defun Kernel Code])
          Name (intern Prefix)
          Go (intern (cn Prefix ".go"))
          Head (datalog.head-slot Steps Relations)
          First (datalog.first-start Steps Relations)
          Call [Kernel | (map (function tl) Params)]
          GoForm [defun Go [s start]
                   [let x Call
                     [if [= x 0] true [do [datalog.grow [<-address s Head]] [Go s [- x 1]]]]]]
          Entry [defun Name [s] [Go s First]]
          _ (set datalog.*forms* [Entry GoForm [define-native Kernel (map (function hd) Params) | Written]
                                  | (value datalog.*forms*)])
       Name))

\\ Where the first loop starts: the new tuples or all of them; 0 if the plan begins with no loop.
(define datalog.first-start
  [[scan Rel new _] | _] Relations -> [<-address [<-address s (datalog.relation-slot Rel Relations)] 5]
  [[scan _ _ _] | _] _ -> 0
  [[filter | _] | Steps] Relations -> (datalog.first-start Steps Relations)
  [[absent | _] | Steps] Relations -> (datalog.first-start Steps Relations)
  _ _ -> 0)

\\ The integers of a run's values, by number, for native comparisons; 0 for what is not one.
(define datalog.ints-bytes
  Values N -> (let
                 B (shen-jit.bytes (* 8 (if (> N 0) N 1)))
              (datalog.fill-ints Values B 0 N)))

(define datalog.fill-ints
  _ B N N -> B
  Values B I N -> (let V (<-address Values I)
                       _ (if (datalog.fixnum? V) (shen-jit.s64! B (* 8 I) V) skip)
                    (datalog.fill-ints Values B (+ I 1) N)))

\\ The KL of the plan with no sizes to go by.
(define datalog.code
  Name
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Constants (datalog.nth 5 Program)
          Steps (datalog.all-steps (datalog.plans Name))
       (datalog.code-h Steps Name Relations Constants)))

(define datalog.all-steps
  [] -> []
  [[_ First Variants] | Cs] -> (append First (append Variants (datalog.all-steps Cs))))

(define datalog.code-h
  [] _ _ _ -> []
  [Steps | More] Name Relations Constants
  -> (let _ (put Name datalog.indexes (datalog.steps-indexes Steps Relations (get Name datalog.indexes)))
          Code (datalog.compiled Name Steps Relations Constants)
       (append (tl Code) (datalog.code-h More Name Relations Constants))))

\\ ---------------------------------------------------------------------------
\\ Running.

\\ Room for Added more tuples of which every key may be new, and their chains.
(define datalog.index-room
  Index Added Count
  -> (let Size (+ 1 (<-address Index 2))
          Wanted (* 2 (+ (<-address Index 4) Added))
          NewSize (datalog.power-at-least Size Wanted)
          _ (if (= NewSize Size)
                skip
                (do (address-> Index 0 (datalog.larger-table (<-address Index 0) Size NewSize))
                    (address-> Index 2 (- NewSize 1))))
          Next (<-address Index 1)
          Bytes (shen-jit.bytes-length Next)
       (if (>= Bytes (* 4 Count))
           true
           (address-> Index 1 (shen-jit.copy-bytes (shen-jit.bytes (* 8 Count)) 0 Next 0 Bytes)))))

(define datalog.power-at-least
  P N -> (if (>= P N) P (datalog.power-at-least (* 2 P) N)))

\\ Tuples From up to To into an index, whose kernel is called through a closure kept in it.
(define datalog.index-range
  Rec Index From To
  -> (let _ (datalog.index-room Index (- To From) To)
          F (<-address Index 3)
          New (F (<-address Index 0) (<-address Index 1) (<-address Rec 2) (<-address Index 2) From To)
       (address-> Index 4 (+ New (<-address Index 4)))))

(define datalog.index-all
  [] _ _ _ -> true
  [Slot | Slots] Rec From To -> (do (datalog.index-range Rec (<-address Rec Slot) From To)
                                    (datalog.index-all Slots Rec From To)))

\\ What was added becomes the new tuples. Gives whether there were any.
(define datalog.merge
  Rec -> (let From (<-address Rec 6)
              To (datalog.count-of Rec)
              _ (datalog.index-all (<-address Rec 1) Rec From To)
              _ (address-> Rec 5 From)
              _ (address-> Rec 6 To)
           (> To From)))

(define datalog.merge-all
  [] Any -> Any
  [Rel | Rels] Any -> (let Some (datalog.merge Rel) (datalog.merge-all Rels (or Some Any))))

(define datalog.call-all
  [] _ -> true
  [F | Fs] S -> (do (F S) (datalog.call-all Fs S)))

\\ Everything so far counts as new, for the first round of a component.
(define datalog.start-round
  [] -> true
  [Rel | Rels] -> (do (address-> Rel 5 0) (datalog.start-round Rels)))

\\ What a run needs: [Name Relations Constants S].
(define datalog.run-relation
  Rel [_ Relations _ S] -> (<-address S (datalog.relation-slot Rel Relations)))

(define datalog.log2
  X N -> (if (<= X 1) N (datalog.log2 (shen-jit.shift-right X 1) (+ N 1))))

(define datalog.quotient
  A B Q -> (if (< A B) Q (datalog.quotient (- A B) B (+ Q 1))))

\\ How many tuples an atom is expected to give for one set of known columns: the average per key if
\\ there is an index to say, and otherwise as if the columns were alike and independent.
(define datalog.estimate
  [Rel | Terms] Bound Run
  -> (let Rec (datalog.run-relation Rel Run)
          Size (datalog.count-of Rec)
          Keys (datalog.key-columns Terms 1 Bound)
          Known (length Keys)
          Arity (length Terms)
       (cases (= Known 0) Size
              (= Size 0) 0
              (= Known Arity) 1
              true (datalog.per-key Rec Size Rel Keys Known Arity Run))))

(define datalog.per-key
  Rec Size Rel Keys Known Arity [Name | Run]
  -> (let Table (assoc Rel (get Name datalog.indexes))
          Slot (if (and (cons? Table) (element? Keys (tl Table)))
                   (datalog.index-slot Rel Keys (get Name datalog.indexes))
                   none)
       (if (and (not (= Slot none)) (element? Slot (<-address Rec 1)) (> (<-address (<-address Rec Slot) 4) 0))
           (/ Size (<-address (<-address Rec Slot) 4))
           (shen-jit.shift-left 1 (datalog.quotient (* (datalog.log2 Size 0) (- Arity Known)) Arity 0)))))

(define datalog.estimator
  Run -> (if (value datalog.*adaptive*)
             (/. Atom Bound (datalog.estimate Atom Bound Run))
             []))

\\ Each index these steps look up, started if this run has not used it.
(define datalog.prepare
  [] _ -> true
  [Step | Steps] [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
       (do (if (datalog.indexed? Step Relations)
               (datalog.use-index (hd (tl Step)) (hd (tl (tl Step))) Run)
               skip)
           (datalog.prepare Steps Run))))

\\ A closure of an index's kernel, for calling it from here.
(define datalog.index-function
  N Keys -> (let K (datalog.index-kernel N Keys)
              (eval-kl [lambda a [lambda b [lambda c [lambda d [lambda e [lambda f [K a b c d e f]]]]]]])))

(define datalog.new-index
  N Keys Count
  -> (let I (absvector 5)
          _ (address-> I 0 (shen-jit.bytes (* 16 8)))
          _ (address-> I 1 (shen-jit.bytes (* 4 (if (> Count 8) Count 8))))
          _ (address-> I 2 15)
          _ (address-> I 3 (datalog.index-function N Keys))
          _ (address-> I 4 0)
       I))

(define datalog.use-index
  Rel Keys [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          _ (put Name datalog.indexes (datalog.add-index Rel Keys (get Name datalog.indexes)))
          Slot (datalog.index-slot Rel Keys (get Name datalog.indexes))
          Rec (datalog.run-relation Rel Run)
       (cases (element? Slot (<-address Rec 1)) true
              (>= Slot (<-address Rec 0)) (error "datalog: too many indexes on ~A" Rel)
              true (let I (datalog.new-index (datalog.arity-in Rel Relations) Keys (<-address Rec 6))
                        _ (address-> Rec Slot I)
                        _ (address-> Rec 1 [Slot | (<-address Rec 1)])
                     (datalog.index-range Rec I 0 (<-address Rec 6))))))

(define datalog.steps-function
  Steps [Name Relations Constants S]
  -> (let Run [Name Relations Constants S]
          _ (datalog.prepare Steps Run)
          _ (set datalog.*plans* (+ 1 (value datalog.*plans*)))
       (hd (datalog.compiled Name Steps Relations Constants))))

(define datalog.first-functions
  [] _ _ -> []
  [R | Rs] Est Run -> (let F (datalog.steps-function (datalog.plan-rule R Est) Run)
                        [F | (datalog.first-functions Rs Est Run)]))

(define datalog.variant-functions
  [] _ _ -> []
  [[R P] | Vs] Est Run -> (let F (datalog.steps-function (datalog.plan-variant R P Est) Run)
                            [F | (datalog.variant-functions Vs Est Run)]))

\\ Sizes to within a power of two: a new plan when one has moved that far.
(define datalog.signature
  [] _ -> []
  [[Rel | _] | Rs] Run
  -> [(datalog.log2 (datalog.count-of (datalog.run-relation Rel Run)) 0) | (datalog.signature Rs Run)])

(define datalog.fixpoint
  Variants Rels Run Functions Signature Rounds
  -> (let Now (datalog.signature (hd (tl Run)) Run)
          Replan (and (value datalog.*adaptive*) (not (= Now Signature)))
          Fs (if Replan (datalog.variant-functions Variants (datalog.estimator Run) Run) Functions)
          _ (datalog.call-all Fs (datalog.nth 4 Run))
          Any (datalog.merge-all Rels false)
       (if Any
           (datalog.fixpoint Variants Rels Run Fs Now (+ Rounds 1))
           (+ Rounds 1))))

(define datalog.run-component
  [C First Variants] Run Rounds
  -> (let Rels (map (/. R (datalog.run-relation R Run)) C)
          Est (datalog.estimator Run)
          _ (datalog.call-all (datalog.first-functions First Est Run) (datalog.nth 4 Run))
          _ (datalog.merge-all Rels false)
          More (if (empty? Variants)
                   0
                   (do (datalog.start-round Rels)
                       (datalog.fixpoint Variants Rels Run
                         (datalog.variant-functions Variants (datalog.estimator Run) Run)
                         (datalog.signature (hd (tl Run)) Run)
                         0)))
       (+ Rounds More)))

(define datalog.run-components
  [] _ Rounds -> Rounds
  [C | Cs] Run Rounds -> (datalog.run-components Cs Run (datalog.run-component C Run Rounds)))

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

(define datalog.list-forms
  0 _ -> []
  N L -> [[hd L] | (datalog.list-forms (- N 1) [tl L])])

\\ Closures for adding and finding a tuple given as a list, one for each arity.
(define datalog.adder
  N -> (let Name (intern (cn "datalog.adder." (str N)))
            Known (datalog.dict-find (value datalog.*kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let F (eval-kl [lambda r [lambda l (datalog.insert-form N (datalog.list-forms N l))]])
                  _ (shen.dict-> (value datalog.*kernels*) Name F)
               F))))

(define datalog.finder
  N -> (let Name (intern (cn "datalog.finder." (str N)))
            Known (datalog.dict-find (value datalog.*kernels*) Name)
         (if (cons? Known)
             (tl Known)
             (let Find (datalog.find-kernel N (datalog.upto 1 N))
                  F (eval-kl [lambda r [lambda l
                               [Find [<-address r 3] [<-address r 2] [shen-jit.u32 [<-address r 4] 8] | (datalog.list-forms N l)]]])
                  _ (shen.dict-> (value datalog.*kernels*) Name F)
               F))))

(define datalog.load-facts
  [] _ _ _ -> true
  [[Rel | Values] | Facts] Relations S Interned
  -> (let Check (datalog.check-fact Relations [Rel | Values])
          Ids (datalog.intern-all Values Interned)
          R (<-address S (datalog.relation-slot Rel Relations))
          Add (datalog.adder (length Ids))
          _ (Add R Ids)
       (datalog.load-facts Facts Relations S Interned)))

(define datalog.fill-state
  [] S _ -> S
  [[_ | Types] | Rs] S I
  -> (do (address-> S I (datalog.new-relation (length Types)))
         (datalog.fill-state Rs S (+ I 1))))

(define datalog.values-vector
  Interned -> (let V (absvector (shen.dict-count Interned))
                (do (shen.dict-fold (/. K Id Acc (address-> V Id K)) Interned V) V)))

(define datalog.merge-state
  S I End -> (if (> I End)
                 true
                 (do (datalog.merge (<-address S I))
                     (datalog.zero-derivations (<-address S I))
                     (datalog.merge-state S (+ I 1) End))))

(define datalog.zero-derivations
  Rec -> (shen-jit.s64! (<-address Rec 4) 24 0))

(define datalog.run
  Name Facts
  -> (let Program (datalog.program Name)
          Relations (datalog.nth 3 Program)
          Constants (datalog.nth 5 Program)
          Interned (shen.dict 8)
          _ (datalog.intern-all Constants Interned)
          N (length Relations)
          S (absvector (+ 2 N))
          _ (datalog.fill-state Relations S 1)
          _ (datalog.load-facts Facts Relations S Interned)
          _ (address-> S 0 (datalog.values-vector Interned))
          _ (address-> S (+ 1 N) (datalog.ints-bytes (<-address S 0) (shen.dict-count Interned)))
          _ (datalog.merge-state S 1 N)
          Run [Name Relations Constants S]
          _ (set datalog.*plans* 0)
          Rounds (datalog.run-components (get Name datalog.schedule) Run 0)
       [db Name S Interned Rounds (value datalog.*plans*)]))

(define datalog.relation-of
  [db Name S | _] Rel
  -> (let Relations (datalog.nth 3 (datalog.program Name))
       (if (cons? (assoc Rel Relations))
           (<-address S (datalog.relation-slot Rel Relations))
           (error "datalog: no relation ~A" Rel))))

(define datalog.arity-of
  Name Rel -> (length (tl (assoc Rel (datalog.nth 3 (datalog.program Name))))))

(define datalog.tuple-at
  _ _ I N _ -> [] where (= I N)
  Tuples Base I N Values
  -> (let Id (shen-jit.u32 Tuples (+ Base (* 4 I)))
          More (datalog.tuple-at Tuples Base (+ I 1) N Values)
       [(<-address Values Id) | More]))

(define datalog.read-tuples
  P To _ _ _ _ Acc -> Acc where (= P To)
  P To Tuples Stride Arity Values Acc
  -> (datalog.read-tuples (+ P 1) To Tuples Stride Arity Values
       [(datalog.tuple-at Tuples (* P Stride) 0 Arity Values) | Acc]))

(define datalog.tuples
  [naive _ Tables] Rel
  -> (let Table (assoc Rel Tables)
       (if (empty? Table) (error "datalog: no relation ~A" Rel) (tl Table)))
  [db Name S | Rest] Rel
  -> (let Rec (datalog.relation-of [db Name S | Rest] Rel)
       (datalog.read-tuples 0 (<-address Rec 6) (<-address Rec 2) (<-address Rec 7)
                            (datalog.arity-of Name Rel) (<-address S 0) [])))

(define datalog.count
  [naive | Rest] Rel -> (length (datalog.tuples [naive | Rest] Rel))
  Db Rel -> (datalog.count-of (datalog.relation-of Db Rel)))

(define datalog.holds?
  [naive | Rest] [Rel | Values] -> (element? Values (datalog.tuples [naive | Rest] Rel))
  [db Name S Interned | Rest] [Rel | Values]
  -> (let Ids (datalog.lookup-ids Values Interned)
          Find (datalog.finder (length Values))
       (and (not (= Ids no))
            (> (Find (datalog.relation-of [db Name S Interned | Rest] Rel) Ids) 0))))

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

\\ Rounds, plans made, and for each relation its tuples, its derivations and its indexes.
(define datalog.stats
  [db Name S _ Rounds Plans]
  -> (let Relations (datalog.nth 3 (datalog.program Name))
       [[rounds Rounds] [plans Plans]
        | (map (/. R (let Rec (<-address S (datalog.relation-slot (hd R) Relations))
                       [(hd R) (datalog.count-of Rec) (shen-jit.s64 (<-address Rec 4) 24) (length (<-address Rec 1))]))
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
