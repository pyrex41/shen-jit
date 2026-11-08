\\ Grammars over byte views: Shen-YACC's notation, compiled to loops over a buffer, a position
\\ and an end. Load buffer.shen first, then this, then the grammars, under (tc -). docs/grammar.md
\\ has the notation and the API.
\\
\\ (defgrammar <digits> (+ <digit>);)
\\ (defgrammar <digit> B where (and (>= B 48) (<= B 57));)
\\ (grammar.match? <digits> (buffer.from-string "2026"))    \\ true
\\
\\ Each definition becomes (define Name Buf At End S -> ...), returning the position after its
\\ match, -1 when it does not match, or -2 when a require failed, with that position and message in
\\ S's slots 1 and 2. A rule with := leaves its value in slot 0. (* Item) becomes a function of its
\\ own, Name/1 and so on, which loops by calling itself.

(define grammar.error
  S At Message -> (do (address-> S 1 At) (address-> S 2 Message) -2))

(define grammar.state
  -> (address-> (absvector 3) 0 skip))

(define grammar.result
  P S At End Fail -> (if (= P End) (<-address S 0) (grammar.failed P S At Fail)))

(define grammar.failed
  P S At Fail -> (cases (= P -2) (Fail (<-address S 1) (<-address S 2))
                        (= P -1) (Fail At "no match")
                        true (Fail P "trailing input")))

\\ The view is checked once, then read as cursor.shen reads it: owner, start, end in slots 1 to 3.
(define grammar.parse
  Rule View Fail ->
    (let V (buffer.check View) S (grammar.state) At (<-address V 2) End (<-address V 3)
      (grammar.result ((fn Rule) (<-address V 1) At End S) S At End Fail)))

(define grammar.match?
  Rule View -> (let V (buffer.check View) End (<-address V 3)
                 (= ((fn Rule) (<-address V 1) (<-address V 2) End (grammar.state)) End)))

\\ The same over a range of storage that a library has already checked.
(define grammar.parse-range
  Rule Buffer At End Fail -> (let S (grammar.state) (grammar.result ((fn Rule) Buffer At End S) S At End Fail)))

\\ The compiler. A position is [Var Offset], known up to a constant; Fail is the code to give
\\ when an item does not match: -1, or inside a require, its error. Done makes the code that
\\ follows a match, given its position. A context is [Name Buf End S Count Values Stack], where
\\ Values maps each rule named in the semantics to the variable holding its value, and Stack lists
\\ the rules being inlined.

(define grammar.nonterminal?
  X -> (and (symbol? X) (not (variable? X))
            (let B (shen-jit.string->bytes (str X)) N (shen-jit.bytes-length B)
              (and (> N 2) (= (shen-jit.u8 B (- N 1)) 62) (grammar.opens? B 0 N)))))

\\ A < first, or after the dot of a prefix, as in http.<token>.
(define grammar.opens?
  B I N -> false where (>= I N)
  B I N -> true where (and (= (shen-jit.u8 B I) 60) (or (= I 0) (= (shen-jit.u8 B (- I 1)) 46)))
  B I N -> (grammar.opens? B (+ I 1) N))

(define grammar.wildcard?
  X -> (and (symbol? X) (= (str X) "_")))

(define grammar.pos
  [Var 0] -> Var
  [Var Off] -> [+ Var Off])

(define grammar.buf
  [_ Buf | _] -> Buf)

(define grammar.end
  [_ _ End | _] -> End)

(define grammar.s
  [_ _ _ S | _] -> S)

(define grammar.inner
  [Name Buf End S Count _ Stack] -> [Name Buf End S Count [] Stack])

(define grammar.subst
  [_ _ _ _ _ Values | _] X -> (grammar.replace Values X))

(define grammar.replace
  Values [X | Y] -> (map (/. Z (grammar.replace Values Z)) [X | Y])
  Values X -> (let Found (assoc X Values) (if (empty? Found) X (tl Found))))

(define grammar.last
  L -> (hd (reverse L)))

(define grammar.butlast
  L -> (reverse (tl (reverse L))))

(define grammar.define
  Name Body ->
    (let Rules (map (/. R (grammar.split-rule R [])) (grammar.split Body [] []))
         _ (if (empty? Rules) (error "defgrammar ~A: no rules" Name) skip)
         _ (put Name grammar.value (grammar.every? (/. R (not (= (hd (tl R)) grammar.none))) Rules))
         _ (put Name grammar.class (grammar.class Rules))
         _ (put Name grammar.inline (grammar.inlinable Name Rules))
         _ (map (function grammar.arity) [Name | (mapcan (function grammar.called) (map (function hd) Rules))])
         Buf (gensym (protect Buf)) At (gensym (protect At)) End (gensym (protect End))
         S (gensym (protect S)) Count (address-> (absvector 1) 0 0)
      [define Name Buf At End S ->
        (grammar.alternatives
          (map (/. R (grammar.rule [Name Buf End S Count (grammar.values Name R) []] R [At 0])) Rules))]))

\\ A byte class, B where Guard and nothing else, is tested in place by the rules read after it.
(define grammar.class
  [[[V] Sem Guard]] -> [V Guard] where (and (variable? V) (= Sem grammar.none) (not (= Guard grammar.none)))
  _ -> [])

\\ A small rule that does not name itself is compiled in place by the rules read after it, up to
\\ three deep, instead of called.
(define grammar.inlinable
  Name Rules -> (let Items (map (function hd) Rules)
                  (if (and (<= (grammar.size Items) 12) (not (element? Name (grammar.called (mapcan (/. X X) Items)))))
                      Rules
                      [])))

(define grammar.size
  [] -> 0
  [X | Y] -> (+ (grammar.size X) (grammar.size Y))
  _ -> 1)

\\ A file is read whole before any of it runs, so a rule's arity is stored as it is read, for
\\ calls to it, earlier or later in the file, to be direct, as for define.
(define grammar.arity
  R -> (if (= (arity R) -1) (shen.store-arity R 4) skip))

(define grammar.called
  [] -> []
  [X | Items] -> [X | (grammar.called Items)] where (and (grammar.nonterminal? X) (not (= X <e>)))
  [[F | Args] | Items] -> (append (grammar.called (if (= F require) (grammar.butlast Args) Args))
                                  (grammar.called Items)) where (element? F [* + ? text span require])
  [_ | Items] -> (grammar.called Items))

(define grammar.every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (grammar.every? F Xs)))

(define grammar.split
  [] [] Rules -> (reverse Rules)
  [] Rule Rules -> (reverse [(reverse Rule) | Rules])
  [X | Body] Rule Rules -> (grammar.split Body [] [(reverse Rule) | Rules]) where (= X (intern ";"))
  [X | Body] Rule Rules -> (grammar.split Body [X | Rule] Rules))

(define grammar.split-rule
  [] Items -> [(reverse Items) grammar.none grammar.none]
  [X Sem] Items -> [(reverse Items) Sem grammar.none] where (= X (intern ":="))
  [X Sem where Guard] Items -> [(reverse Items) Sem Guard] where (= X (intern ":="))
  [where Guard] Items -> [(reverse Items) grammar.none Guard]
  [X | Rest] Items -> (grammar.split-rule Rest [X | Items])
    where (not (or (= X (intern ":=")) (= X where)))
  Rest _ -> (error "defgrammar: expected Items := Value where Guard;, not ~R" Rest))

(define grammar.alternatives
  [Code] -> Code
  [Code | Codes] -> (let R (gensym (protect R)) [let R Code [if [= R -1] (grammar.alternatives Codes) R]]))

\\ The rules a rule's semantics name, each with a fresh variable for its value. Only a rule matched
\\ outside a repetition has one, and only a rule with := gives one.
(define grammar.values
  Name [Items Sem Guard] ->
    (let Used (grammar.symbols [Sem Guard | (mapcan (function grammar.item-uses) Items)])
         Named (grammar.top Items)
      (mapcan (/. R (grammar.value Name R Named)) (grammar.unique (grammar.nonterminals Used) []))))

(define grammar.nonterminals
  Xs -> (mapcan (/. X (if (grammar.nonterminal? X) [X] [])) Xs))

(define grammar.unique
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (grammar.unique Xs (if (element? X Acc) Acc [X | Acc])))

(define grammar.value
  Name R Named ->
    (let Found (assoc R Named)
      (cases (empty? Found) (error "defgrammar ~A: ~A is named but not matched outside a repetition" Name R)
             (and (= (tl Found) plain) (= (trap-error (get R grammar.value) (/. E unknown)) false))
               (error "defgrammar ~A: ~A gives no value, having no :=" Name R)
             true [[R | (gensym (protect V))]])))

(define grammar.symbols
  [X | Y] -> (append (grammar.symbols X) (grammar.symbols Y))
  X -> [X] where (symbol? X)
  _ -> [])

(define grammar.item-uses
  [where G] -> [G]
  [require | Rest] -> [(grammar.last Rest) | (mapcan (function grammar.item-uses) (grammar.butlast Rest))]
  _ -> [])

(define grammar.top
  [] -> []
  [X | Items] -> [[X | plain] | (grammar.top Items)] where (grammar.nonterminal? X)
  [[Capture R] | Items] -> [[R | Capture] | (grammar.top Items)] where (element? Capture [text span])
  [[require | Rest] | Items] -> (append (grammar.top (grammar.butlast Rest)) (grammar.top Items))
  [_ | Items] -> (grammar.top Items))

\\ What items bind: their variables, and the rules they name.
(define grammar.bound
  Items -> (append (map (function hd) (grammar.top Items)) (grammar.variables Items)))

(define grammar.variables
  [X | Y] -> (append (grammar.variables X) (grammar.variables Y))
  X -> [X] where (variable? X)
  _ -> [])

(define grammar.rule
  C [Items Sem Guard] Pos -> (grammar.seq C Items Pos -1 (/. P (grammar.done C P Sem Guard))))

(define grammar.done
  C P Sem Guard ->
    (let Value (if (= Sem grammar.none)
                   (grammar.pos P)
                   [do [address-> (grammar.s C) 0 (grammar.subst C Sem)] (grammar.pos P)])
      (if (= Guard grammar.none) Value [if (grammar.subst C Guard) Value -1])))

(define grammar.seq
  _ [] Pos _ Done -> (Done Pos)
  C [X | Items] Pos Fail Done -> (grammar.terminals C (grammar.run [X | Items] []) Pos Fail Done)
    where (or (number? X) (string? X))
  C [X | Items] Pos Fail Done -> (grammar.item C X Items Pos Fail Done))

(define grammar.run
  [X | Items] Bytes -> (grammar.run Items (append Bytes (grammar.bytes X))) where (or (number? X) (string? X))
  Items Bytes -> (@p Bytes Items))

(define grammar.bytes
  N -> [N] where (and (integer? N) (>= N 0) (<= N 255))
  S -> (let B (shen-jit.string->bytes S) (grammar.byte-list B (shen-jit.bytes-length B) [])) where (string? S)
  X -> (error "defgrammar: ~S is not a byte or a string" X))

(define grammar.byte-list
  _ 0 Acc -> Acc
  B N Acc -> (grammar.byte-list B (- N 1) [(shen-jit.u8 B (- N 1)) | Acc]))

\\ One bounds check for a run of literal bytes, then a test of each.
(define grammar.terminals
  C (@p [] Items) Pos Fail Done -> (grammar.seq C Items Pos Fail Done)
  C (@p Bytes Items) [Var Off] Fail Done ->
    (let N (length Bytes)
      [if (grammar.conj [[< (grammar.pos [Var (+ Off (- N 1))]) (grammar.end C)]
                         | (grammar.compares C Bytes Var Off)])
          (grammar.seq C Items [Var (+ Off N)] Fail Done)
          Fail]))

(define grammar.compares
  _ [] _ _ -> []
  C [Byte | Bytes] Var Off -> [[= [shen-jit.u8 (grammar.buf C) (grammar.pos [Var Off])] Byte]
                               | (grammar.compares C Bytes Var (+ Off 1))])

(define grammar.conj
  [X] -> X
  [X | Xs] -> [and X (grammar.conj Xs)])

(define grammar.byte
  C Pos Fail Rest -> [if [< (grammar.pos Pos) (grammar.end C)] Rest Fail])

(define grammar.next
  [Var Off] -> [Var (+ Off 1)])

(define grammar.item
  C X Items Pos Fail Done ->
    (cases (grammar.wildcard? X) (grammar.byte C Pos Fail (grammar.seq C Items (grammar.next Pos) Fail Done))
           (variable? X)
             (grammar.byte C Pos Fail
               [let X [shen-jit.u8 (grammar.buf C) (grammar.pos Pos)]
                 (grammar.seq C Items (grammar.next Pos) Fail Done)])
           (= X <e>) (grammar.seq C Items Pos Fail Done)
           (grammar.nonterminal? X)
             (let Class (trap-error (get X grammar.class) (/. E []))
               (if (empty? Class)
                   (grammar.call C X Pos Fail (/. P [<-address (grammar.s C) 0]) Items Done)
                   (grammar.inline C Class Items Pos Fail Done)))
           (cons? X) (grammar.form C X Items Pos Fail Done)
           true (error "defgrammar: ~R is not an item" X)))

(define grammar.inline
  C [V Guard] Items Pos Fail Done ->
    (let B (gensym (protect B))
      (grammar.byte C Pos Fail
        [let B [shen-jit.u8 (grammar.buf C) (grammar.pos Pos)]
          [if (grammar.replace [[V | B]] Guard) (grammar.seq C Items (grammar.next Pos) Fail Done) Fail]])))

\\ A loop over a byte class tests its first byte in place, and is called only if it matches.
(define grammar.class-of
  X -> (trap-error (get X grammar.class) (/. E [])) where (grammar.nonterminal? X)
  _ -> [])

(define grammar.class-test
  C [V Guard] Pos ->
    (let B (gensym (protect B))
      [and [< (grammar.pos Pos) (grammar.end C)]
           [let B [shen-jit.u8 (grammar.buf C) (grammar.pos Pos)] (grammar.replace [[V | B]] Guard)]]))

(define grammar.args
  C Pos -> [(grammar.buf C) (grammar.pos Pos) (grammar.end C) (grammar.s C)])

\\ Calls R, binds its value if the semantics name it, and goes on from where it stopped.
(define grammar.call
  C R Pos Fail Value Items Done ->
    (grammar.after (grammar.invoke C R Pos) Fail
      (/. P (let Found (assoc R (grammar.subst-values C))
                 Rest (grammar.seq C Items [P 0] Fail Done)
              (if (empty? Found) Rest [let (tl Found) (Value P) Rest])))))

(define grammar.subst-values
  [_ _ _ _ _ Values | _] -> Values)

\\ R's alternatives in place, when it is small, or a call to it.
(define grammar.invoke
  [Name Buf End S Count Values Stack] R Pos ->
    (let Rules (trap-error (get R grammar.inline) (/. E []))
      (if (or (empty? Rules) (= R Name) (element? R Stack) (>= (length Stack) 3))
          [R Buf (grammar.pos Pos) End S]
          (grammar.alternatives
            (map (/. Rule (grammar.rule [Name Buf End S Count (grammar.values R Rule) [R | Stack]] Rule Pos))
                 Rules)))))

\\ A call's result is a position, -1 or -2: -1 fails as this item fails, and -2 goes up as it is.
(define grammar.after
  Call Fail K ->
    (let P (gensym (protect P))
         Body (K P)
      (if (and (= Body P) (= Fail -1))
          Call
          [let P Call [if [< P 0] (if (= Fail -1) P [if [= P -1] Fail P]) Body]])))

(define grammar.form
  C [* X] Items Pos Fail Done ->
    (let Class (grammar.class-of X)
         Loop [(grammar.loop C X) | (grammar.args C [(grammar.pos Pos) (if (empty? Class) 0 1)])]
      (if (empty? Class)
          (grammar.after Loop -1 (/. P (grammar.seq C Items [P 0] Fail Done)))
          (let P (gensym (protect P))
            [let P [if (grammar.class-test C Class Pos) Loop (grammar.pos Pos)]
              (grammar.seq C Items [P 0] Fail Done)])))
  C [+ X] Items Pos Fail Done -> (grammar.seq C [X [* X] | Items] Pos Fail Done)
  C [? X] Items Pos Fail Done ->
    (let R (gensym (protect R))
         Inner (grammar.seq (grammar.inner C) [X] Pos -1 (function grammar.pos))
      (grammar.after [let R Inner [if [= R -1] (grammar.pos Pos) R]] -1
        (/. P (grammar.seq C Items [P 0] Fail Done))))
  C [text R] Items Pos Fail Done ->
    (grammar.call C R Pos Fail
      (/. P [shen-jit.bytes->string (grammar.buf C) (grammar.pos Pos) [- P (grammar.pos Pos)]]) Items Done)
    where (grammar.nonterminal? R)
  C [span R] Items Pos Fail Done ->
    (grammar.call C R Pos Fail (/. P [buffer.make (grammar.buf C) (grammar.pos Pos) P]) Items Done)
    where (grammar.nonterminal? R)
  C [require | Rest] Items Pos Fail Done ->
    (let Message (grammar.last Rest)
         Required (grammar.butlast Rest)
         _ (if (empty? (intersection (grammar.symbols Message) (grammar.bound Required)))
               skip
               (error "defgrammar: the message of ~R names what it requires" [require | Rest]))
      (grammar.seq C Required Pos [grammar.error (grammar.s C) (grammar.pos Pos) (grammar.subst C Message)]
        (/. P (grammar.seq C Items P Fail Done))))
    where (cons? Rest)
  C [where G] Items Pos Fail Done -> [if (grammar.subst C G) (grammar.seq C Items Pos Fail Done) Fail]
  C [u16-be V] Items Pos Fail Done -> (grammar.fixed C V 2 Items Pos Fail Done) where (variable? V)
  C [u32-be V] Items Pos Fail Done -> (grammar.fixed C V 4 Items Pos Fail Done) where (variable? V)
  _ [F | Items] _ _ _ _ -> (error "defgrammar: (~A Item) takes one item: name a sequence as a rule, in ~R"
                                   F [F | Items]) where (element? F [* + ?])
  _ X _ _ _ _ -> (error "defgrammar: ~R is not an item" X))

\\ A big-endian unsigned field of N bytes, bound to V.
(define grammar.fixed
  C V N Items [Var Off] Fail Done ->
    [if [< (grammar.pos [Var (+ Off (- N 1))]) (grammar.end C)]
        [let V (grammar.big-endian C Var Off N 0)
          (grammar.seq C Items [Var (+ Off N)] Fail Done)]
        Fail])

(define grammar.big-endian
  _ _ _ 0 Acc -> Acc
  C Var Off N Acc ->
    (grammar.big-endian C Var (+ Off 1) (- N 1)
      (let Byte [shen-jit.u8 (grammar.buf C) (grammar.pos [Var Off])]
        (if (= Acc 0) Byte [+ [shen-jit.shift-left Acc 8] Byte]))))

\\ (* X) as a function of its own: it stops where X no longer matches, or matches nothing. The
\\ macro runs as its file is read, before the file's own functions exist, and a definition
\\ compiled then would call them through fn; so it defines a stub, and the stub compiles the loop
\\ at its first call.
(define grammar.loop
  [Name Buf End S Count Values Stack] X ->
    (let N (+ (<-address Count 0) 1)
         _ (address-> Count 0 N)
         H (intern (make-string "~A/~A" Name N))
         _ (grammar.arity H)
         At (gensym (protect At))
         P (gensym (protect P))
         Body (grammar.seq [Name Buf End S Count [] Stack] [X] [At 0] -1 (function grammar.pos))
         _ (put H grammar.loop [define H Buf At End S ->
                                 [let P Body [if [> P At] [H Buf P End S] [if [= P -2] P At]]]])
         _ (eval [define H Buf At End S -> [grammar.compile H Buf At End S]])
      H))

(define grammar.compile
  H Buf At End S -> (do (eval (get H grammar.loop)) ((fn H) Buf At End S)))

(defmacro grammar.macro
  [defgrammar Name | Body] -> (grammar.define Name Body) where (grammar.nonterminal? Name)
  [defgrammar | Form] -> (error "defgrammar: expected <name> and rules, in ~R" Form)
  [grammar.parse Rule View Fail] -> (grammar.parse-form Rule View Fail) where (grammar.nonterminal? Rule)
  [grammar.match? Rule View] -> (grammar.match-form Rule View) where (grammar.nonterminal? Rule)
  [grammar.parse-range Rule Buffer At End Fail] -> (grammar.range-form Rule Buffer At End Fail)
    where (grammar.nonterminal? Rule))

\\ With the rule named, a parse calls it directly, and Fail is evaluated only when it fails.
(define grammar.parse-form
  Rule View Fail ->
    (let V (gensym (protect V)) S (gensym (protect S)) At (gensym (protect At)) End (gensym (protect End))
      [let V [buffer.check View] S [grammar.state] At [<-address V 2] End [<-address V 3]
        (grammar.finish [Rule [<-address V 1] At End S] S At End Fail)]))

(define grammar.finish
  Call S At End Fail ->
    (let P (gensym (protect P))
      [let P Call [if [= P End] [<-address S 0] [grammar.failed P S At Fail]]]))

(define grammar.match-form
  Rule View ->
    (let V (gensym (protect V)) End (gensym (protect End))
      [let V [buffer.check View] End [<-address V 3]
        [= [Rule [<-address V 1] [<-address V 2] End [grammar.state]] End]]))

(define grammar.range-form
  Rule Buffer At End Fail ->
    (let B (gensym (protect B)) A (gensym (protect A)) E (gensym (protect E)) S (gensym (protect S))
      [let B Buffer A At E End S [grammar.state]
        (grammar.finish [Rule B A E S] S A E Fail)]))
