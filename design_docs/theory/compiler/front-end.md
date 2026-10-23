# The front end

Elm source becomes a typed, canonical program through Elm's own pipeline: the parser turns text into a syntax tree, name resolution ties every name to the module that defines it, the type checker generates and solves constraints, and the pattern checks reject incomplete and redundant matches. Eco keeps this pipeline faithful to stock Elm, so it accepts real Elm packages and reports Elm's errors in Elm's words. Its one addition is that type checking keeps its answers. Name resolution gives every expression and pattern a number, constraint generation records which solver variable stands for each number, and after solving a repair step fills in the types the solver leaves open and replaces every variable by the representative the solver chose for it. The whole-program phases can then read the type of any node, and tell which type variables are the same one, from data instead of syntax. Everything the front end produces is plain data with an encoder and a decoder, because later builds reload typed modules from compact cached files instead of checking them again.

## Faithful to Elm, with one grammar

The front end is forked from Guida, which is a port of the stock Elm compiler from Haskell to Elm. Starting from that code gives Eco Elm's grammar, scoping rules, type system and error messages without writing them again, and those are what let Eco compile existing Elm packages unchanged. Guida also accepts syntax of its own, such as underscores in number literals, binary literals and tuples of more than three elements. Eco does not: it keeps one grammar, the standard one, and a smaller parser.

Errors follow Elm's model. Each phase collects every error and warning it finds instead of stopping at the first, and each error is rendered as a report that quotes the source lines it concerns. An addition to the front end that can fail reports through this same channel, so the user sees its errors in the same form as Elm's.

## Keeping the type checker's answers

Stock Elm's type checker answers one question, whether the program is well typed, and discards its working. Eco's native back end needs the type of every expression, because monomorphization specializes each function from those types. The solver, however, knows only variables: placeholders for types that unification merges and fills in. The front end joins the two with numbers. Name resolution numbers every expression and pattern, constraint generation notes which solver variable stands for each number, and after solving each node's type is read from a table by its number. The join itself is described in [compiler.md](compiler.md).

The chain rests on three plain types: an id on every canonical node, a variable recorded per id, and a type per id.

```elm
type alias ExprInfo =
    { id : Int
    , node : Expr_
    }

type alias NodeVarMap =
    Array (Maybe Vars.Variable)
...
type alias ExprTypes =
    Array (Maybe (Can.Type Name))
```

`ExprInfo` is from `compiler/src/Compiler/AST/Canonical.elm`, where each canonical expression is a located `ExprInfo`. `NodeVarMap` is from `compiler/src/Compiler/Type/Constrain/Typed/NodeIds.elm` and `ExprTypes` from `compiler/src/Compiler/AST/TypedCanonical.elm`. Notice that both tables are ordinary arrays indexed by the node's number, and nothing in the types ties an entry to its node. A number that was never recorded reads back as `Nothing`, which the typed path treats as a compiler bug. Any kind of node added to the tree must therefore take a number and have its variable recorded, or the table has a hole.

Expressions and patterns draw their numbers from one counter per module. A separate counter for each produces the same number for an expression and a pattern, and the tables then mix the two up. The counter is per module because each module is compiled on its own; numbers are unique within a module and mean nothing across modules.

## The phases

The front end has five phases that transform a module, in this order:

1. The parser turns text into the source syntax tree. It keeps Elm's parser design: small hand-written combinators, each of which records whether it consumed input, and an alternative is tried only if the previous one failed without consuming any. Syntax added to it has to respect that rule, because an alternative that consumes input and then fails hides every alternative after it.
2. Name resolution, called canonicalization in the code, resolves every name to its home module and package, reports duplicate definitions, sorts definitions into groups that refer to one another, and handles ports and effect managers. It also numbers every expression and pattern.
3. Constraint generation walks the canonical module and emits the type equations the solver must satisfy. In the typed mode it also records each node's variable, and the variables behind each annotation's type variables.
4. The solver runs rank-based Hindley-Milner inference over a union-find store, in which variables proved equal are merged into one set with a single representative, its root. A snapshot of the store is kept after solving, because the repair step reads it.
5. The repair step completes and normalizes the recorded types.

The result is the typed canonical module: each top-level body is paired with its type, and every inner expression's type is found by number in the table. The pattern checks run on the canonical patterns beside these phases, using Maranget's algorithm to find case expressions that miss a possible value and branches that can never match. A separate check for uses of Elm's `Debug` module lives in the same directory but runs later, when an optimized JavaScript build is generated, over the cached optimized modules. `Debug` is forbidden only in an optimized build, which is chosen per build, so checking at generation keeps each cached module the same in optimized and development builds.

Supporting layers for error reporting, packages and JSON serve all the phases. The one a change is most likely to touch is the small data layer, because it holds the typed integer ids and the numbers the runtime must agree with, both described below.

The erased mode, used when the build targets JavaScript or HTML, runs the same five phases with recording switched off. The parent document explains why there is one constraint generator and not two. Saved fingerprints of the generator's output are compared in the tests, so a change that alters the constraints by accident fails there instead of surfacing as a type difference in some later phase.

## Repair after solving

The solver leaves two kinds of gap, and the repair step fills them without touching any type the solver did work out.

Literal strings, characters, floats and the unit value get no useful constraint, because their type is fixed by their shape. The repair step assigns those types directly. Structural expressions take their types from the solver, so the repair is confined to literals and kernel references. After repair, no node outside kernel code is left with an unconstrained variable that constraint generation invented, so later phases need no marker for an incomplete type. Numbers are the exception that is left open on purpose. A literal such as `1` keeps the type `number` here, and monomorphization's prune closes it to Int once the whole program is known, because until every function is specialized it is not known which uses of `number` become Int and which become Float.

Kernel functions are the second gap. A kernel function is a built-in implemented in the host language, JavaScript for stock Elm and C++ for Eco's native build. It has no Elm declaration, so it produces no constraint of its own. The repair step gives each kernel reference a type inferred from how the code uses it. Where inference is not enough, a table of intrinsic annotations gives a kernel function a declared type, and the solver enforces it like an annotation. Each row states the contract of the C++ kernel, which can be narrower than the type the JavaScript package declares, and cites the evidence for it. Rows are added one at a time, because a wrong row turns correct package code into a type error.

## Identity comes from the solver

Monomorphization needs to know when two occurrences of a type variable are the same variable. Names cannot tell it that. The solver may prove `a` in one place equal to `b` in another, and two definitions in different modules may both use `a` for unrelated variables. The repair step therefore replaces every solver variable by its union-find root, so that variables proved equal share one identity, and it stamps every function type with the root it unified with. Membership of Elm's built-in classes such as `number` and `comparable` is read from the root's record in the store, not from the prefix of the variable's name, for the same reason: names do not survive unification.

These identities are carried as integers, each wrapped in its own type so that one cannot be passed where another is expected. Type-variable ids identify type variables by their root. Lambda ids identify the functions written in the source, and arrow ids identify individual function arrows within types. The last two are what monomorphization and the lambda-set analysis use to track which functions can flow to which call (see [monomorphization.md](monomorphization.md) and [lambda-set-specialization.md](lambda-set-specialization.md)). The canonical type is parameterized over the kind of variable it holds, so a type with named variables and a type with integer ids are the same structure. Only these kinds of id are integers; module, global and field names stay names.

## Plain data in compact files

Later builds reload typed modules from cached files instead of checking them again, so every structure the front end produces is plain data with an encoder and a decoder. Repeating whole types and names in those files makes them very large and slows a cold self-compile. Each file therefore stores every distinct string and every distinct type once, in tables, and refers to them by index, and repeated types in later phases are shared in memory. A format version number at the start of each file makes a file written by an older compiler fail when it is decoded, instead of being read wrongly.

The syntax tree modules hold only types, accessors, serialization and ordering. The parent's layer rule keeps each phase's algorithms in the phase that runs them, and in the front end it also keeps the cached formats in one place: a change to a tree's shape and a change to its encoding sit side by side.

## Shaped by running as Elm

The compiler is Elm code. It runs under JavaScript during self-compilation and natively afterward. Both have a bounded stack, and Elm forbids observable mutation in either. Two features of the front end follow.

The union-find store is an immutable array passed from step to step by value. Most of the type checker passes it through a small state-passing wrapper, which is named `IO` but does no input or output. A mutable store is faster, but it relies on a usage contract the compiler cannot check, and Elm code must never observe mutation. On the solver's busiest path, the store is passed as a plain argument rather than through the wrapper, because the wrapper's overhead dominates the solver's own work there.

Long chains of let bindings, operator applications, calls or list patterns overflow a traversal that recurses once per link. The constraint generator therefore walks each such chain, its spine, in a self-tail-recursive loop, which Elm compiles to a plain loop that runs in constant stack. It recurses directly only where the depth is bounded by what a person writes by hand, such as nested `case` expressions. The solver's main loop is written the same way. A reified constraint language interpreted step by step would also be stack safe, and the front end does without one because the direct generator with spine loops gets the same safety with less machinery.

## Numbers shared with the runtime

Some numbers must agree with the C++ runtime: how many arguments a closure can take, how many fields a record or custom type can hold, and the tag that identifies each constructor in memory, including tags reserved for the runtime's own structures. Canonicalization checks the limits and reports a breach as an error at the offending source location, because a breach that got through would crash the back end with no position to report. The numbers live in two small data modules that mirror the runtime's heap header by hand. Nothing in the build checks that the two sides agree.

## Examples of changes that fit the theory
A change fits when it records a fact while the solver can still see it, keeps one grammar and one constraint generator, and keeps the output plain data that the cache can store.

- A form of syntax that standard Elm accepts and the parser lacks goes into the parser and the source tree, is canonicalized like its neighbors, and takes a number from the shared counter. The constraint generator gains one case that records the node's variable.
- An error or warning is a constructor in its phase's error module, rendered in the same file. Error accumulation carries it with no further work.
- A kernel function that needs a firmer type gets a row in the intrinsic annotation table, with the C++ evidence for its contract.
- A limit tied to the runtime is a number in the heap-limits module, checked in canonicalization and reported at a source location.
- A field in the cached typed files goes through the encoder and the decoder, uses the string and type tables, and comes with a bump of the format version.
- A kind of id is one more wrapped integer type beside the existing ones, so the compiler keeps it apart from the others.

## Examples of changes that would break the theory
- Finding a node's type afterward by name lookup or by walking the tree. That repeats the solver's work and can disagree with it. Record the variable during constraint generation, and repair after solving only what the solver cannot know.
- A second constraint generator for a special pathway. Two copies drift apart and report errors at different places. Add a switch to the single generator.
- Deriving type-variable identity or class membership from a variable's name. Names do not survive unification and collide across modules. Read the solver root.
- Mutable state in the solver, or a global cache that Elm code could observe. It breaks the guarantee the compiler relies on and that it cannot check. Keep the store immutable and pass it by value.
- An earlier phase importing a later one to save code. The early phase would then depend on a decision made later, and the layer rule rejects it. Move the shared definitions down to the earliest layer that uses them.
- Recursion over structure of unbounded length, such as let chains, operator chains or lists. It overflows the stack on large programs and during self-compilation. Walk the spine with a self-tail-recursive loop.
- Transformation logic in a syntax tree module. Every phase imports those modules, so the logic would hide which phase owns it. Put it in the phase that runs it.
- A field added to the cached typed files without a format version bump. Files written by the previous compiler would then be misread rather than rejected. Bump the version in the same change.
- Guida's syntax extensions, or any syntax standard Elm rejects. Programs using it would not compile with Elm, and the parser would grow a second grammar. Keep to standard Elm.

## References

Parent: [compiler.md](compiler.md). Related: [local-optimization.md](local-optimization.md), [monomorphization.md](monomorphization.md), [lambda-set-specialization.md](lambda-set-specialization.md).

Code:

- `compiler/src/Compiler/Compile.elm`: phase order on the erased and typed paths.
- `compiler/src/Compiler/Parse/Primitives.elm`, `compiler/src/Compiler/AST/Source.elm`: parser combinators and the source tree.
- `compiler/src/Compiler/Canonicalize/Module.elm`, `Expression.elm`, `Ids.elm`; `compiler/src/Compiler/AST/Canonical.elm` (`ExprInfo`): name resolution and node numbering.
- `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`, `NodeIds.elm` (`NodeVarMap`, `recordNodeVar`), `compiler/src/Compiler/Type/Constrain/Erased/Module.elm`: the single constraint generator and its recording.
- `compiler/src/Compiler/Type/Solve.elm`, `Unify.elm`, `UnionFind.elm`, `Occurs.elm`, `SolverSnapshot.elm`: the solver.
- `compiler/src/Compiler/Type/PostSolve.elm`, `SolverRoots.elm`, `KernelTypes.elm`, `KernelIntrinsics.elm`: the repair step, solver roots and kernel typing.
- `compiler/src/Compiler/AST/TypedCanonical.elm` (`ExprTypes`): the typed canonical module.
- `compiler/src/Compiler/Nitpick/PatternMatches.elm`, `compiler/src/Compiler/Nitpick/Debug.elm`: the pattern checks and the `Debug` check.
- `compiler/src/Compiler/Reporting/Result.elm`: error accumulation.
- `compiler/src/Compiler/Elm/EcoEnvironment.elm`: recognition of Eco's system package.
- `compiler/src/Compiler/Data/Id.elm`, `compiler/src/Compiler/AST/TypeIds.elm`: typed integer ids (`MVarId`, `SrcLambdaId`, `ArrowId`, `ArrowSlot`).
- `compiler/src/Compiler/Data/HeapLimits.elm`, `compiler/src/Compiler/Data/CtorTag.elm`: numbers mirrored by hand from `runtime/src/allocator/Heap.hpp`.
- `compiler/src/Compiler/AST/StringTable.elm`, `TypeTable.elm`, `Intern.elm`; `compiler/src/Compiler/AST/TypedOptimized.elm` (`typedGraphFormatVersion`): compact typed files.
- `compiler/review/src/EnforceBoundaries.elm`: the layer rule.

Documents:

- `compiler/README.md` describes a single type-check phase, constraint modules under `Type/Constrain/` and an `Optimize/` directory. The code has the typed generator under `Type/Constrain/Typed/`, a short erased entry point, and `LocalOpt/`.

Invariants (`design_docs/invariants.csv`):

- CANON_001, CANON_002: home modules recorded; node ids unique and non-negative within a module.
- TYPE_002, TYPE_004, TYPE_005: Elm typing rules; TYPE_003: every recorded id has a solved type; TYPE_007: every recorded variable is constrained.
- TYPE_SUPER_001: class membership read from the solver root; TYPE_KERNEL_001: intrinsic annotations.
- POST_001 to POST_010: the repair step, including POST_003 (no unconstrained synthetic variable outside kernel code) and POST_005, POST_006 (solver types left unchanged).
- ECOT_001 to ECOT_003: the cached typed file format.
- TYPE_001 and TYPE_006 name erased constraint modules that do not exist.
