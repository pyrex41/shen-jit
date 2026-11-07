# Datalog

`lib/datalog.shen` evaluates relations, facts and recursive rules bottom up, to a fixed point. It is not in the
image. It needs `lib/native.shen`, and a macro applies only to files read after it, so load them first:

```shen
\\ deps.shen
(defdatalog dependencies
  (relation imports [symbol symbol])
  (relation depends [symbol symbol])
  (relation cyclic [symbol])
  (rule (depends X Y) <-- (imports X Y))
  (rule (depends X Z) <-- (imports X Y) (depends Y Z))
  (rule (cyclic X) <-- (depends X X)))

(let Db (datalog.run dependencies [[imports a b] [imports b c] [imports x y] [imports y x]])
  (do (output "~R~%" (datalog.sorted Db depends))
      (output "~R~%" (datalog.ask Db (depends a X)))
      (output "~R~%" (datalog.sorted Db cyclic))
      (output "~A~%" (datalog.holds? Db [depends c a]))))
```

```bash
shen-jit eval -l lib/native.shen -l lib/datalog.shen -l deps.shen
```

```text
((a b) (a c) (b c) (x x) (x y) (y x) (y y))
((a b) (a c))
((x) (y))
false
```

| Form | Meaning |
| --- | --- |
| `(defdatalog Name Item ...)` | Defines a program, checked now. An item is `(relation Name [Types])` or `(rule Head <-- Body ...)`, or `(rule Head)` for one that always holds |
| `(datalog.run Name Facts)` | A database from facts such as `[imports a b]` |
| `(datalog.tuples Db Relation)`, `(datalog.sorted Db Relation)` | Its tuples as lists, in no particular order or sorted |
| `(datalog.count Db Relation)` | How many tuples it has |
| `(datalog.holds? Db [Relation Value ...])` | Whether a tuple is there |
| `(datalog.ask Db (Relation Term ...))` | The tuples that match, in no particular order, with variables, constants and `_` |
| `(datalog.define Name Items)`, `(datalog.match Db Pattern)` | The same as `defdatalog` and `datalog.ask` with the program as data, where a variable is `[var "X"]` and `_` is `[any]` |
| `(datalog.plans Name)`, `(datalog.code Name)` | Each rule's order of joins with no sizes to go by, and the KL that gives |
| `(datalog.stats Db)` | The rounds, how many plans were made, and each relation's tuples, the derivations that made them and its indexes |
| `(datalog.run-naive Name Facts)` | The same result by the plain definition, slowly: what the rest is tested against |

- **Columns** are `symbol`, `string` or `integer`, and a value of another type raises when it is given.
- **Rules:** a body has atoms and comparisons: `<`, `>`, `<=` and `>=` on integers, and `=` and `!=` on values of one
  type. A variable in a head or a comparison must appear in an atom of the body, and each `_` is a variable of its own.
  There is no negation, no arithmetic that makes values, and no terms inside a column.
- **Results** are sets, and the order of rules, atoms and facts does not change them.
- **The order of a rule's atoms** need not be tuned. A run chooses the order of joins from the sizes of the relations, and again when one has doubled.
- **A run is a snapshot.** New facts mean a new `datalog.run`, which starts over.
- **Saving:** a program saved with `--save` runs in the saved image.
