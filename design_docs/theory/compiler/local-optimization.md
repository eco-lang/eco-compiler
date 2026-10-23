# Local optimization

Before types are concrete, Eco optimizes each module on its own, and only with rewrites that keep every type. Local optimization lowers a type-checked canonical module into the typed optimized form: one graph of top-level definitions per module, in which every expression still carries its type and its solver variable. On the way, pattern matches become decision trees, functions that call themselves in tail position become tail-call definitions, ports get JSON encoders and decoders, the short-circuit and pipe operators become conditionals and plain calls, and nested functions whose boundaries would force extra closures are merged into one. Any rewrite that needs the whole program or a concrete type waits for monomorphization and global optimization. The erased path, which feeds JavaScript, runs Elm's original untyped copy of this phase instead.

## Change the shape, keep the types

The phase may change the shape of the program but never its meaning, and it never discards what the type checker recorded. Monomorphization, the phase that depends on these types, specializes each function from the recorded types, so a node that loses its type, or carries the wrong one, cannot be specialized correctly. The native back end needs the types to specialize functions, to lay out values in memory and to decide what can be stored unboxed, which is why Eco keeps a second, typed optimized form beside Elm's erased one ([compiler.md](compiler.md)).

Three tests follow for any rewrite. It belongs here only if it looks at one module, gives its result the type of what it replaces, and is correct for every type the code may later be specialized to. A rewrite that fails the third test, because it depends on whether a `comparable` is an Int or a String, belongs after monomorphization, where the type is known.

## What every node carries

Each expression in the typed optimized form carries two pieces of type information, which together form its metadata. The first is its type in the type checker's own terms, which may still contain variables such as `a` or `number`. The second is the solver variable for that node, which the front end recorded during constraint generation and normalized to its root after solving.

```elm
type alias Meta id =
    { tipe : Can.Type id
    , tvar : Maybe Vars.Variable
    }

type Expr id
    = Bool A.Region Bool (Meta id)
    ...
    | VarLocal Name (Meta id)
    ...
    | VarGlobal A.Region Global (Meta id)
    ...
```

From `compiler/src/Compiler/AST/TypedOptimized.elm`. Notice that the metadata is the last argument of every variant, so any rewrite that builds a node must supply both halves. The variable is optional in the type, but monomorphization depends on it for function-typed definitions and references. The design notes for the phase describe a bare type on each node; the code carries this record.

The commonest way to break the metadata is to give a function-typed definition the variable of its body instead of the variable of the whole function. A local function used in several places must carry its full function type and variable, or monomorphization crashes or specializes it wrongly. The phase recovers the right variable from the binding that introduces the name. That lookup by name is unambiguous because name resolution forbids shadowing. Tail-call definitions carry a variable for the same reason.

A reference to a top-level function is typed at the place it is used, from the solver's answer for that use. The function's general type, its scheme, comes from its annotation and is kept in the graph separately. Monomorphization caches schemes, and the cache must hold the general type, not whatever type the first use happened to have. Constructors of custom types and of record aliases get annotations for the same reason. Operators are also typed at the use site, from their operand types, because an operator's scheme can share its `number` variable with the enclosing definition and so carry that definition's constraint.

The last step of the phase records which type variables carry Elm's built-in classes, such as `number` and `comparable`. It computes them from the finished graph and the solver roots, so later phases read the classes as data. Reading them from variable names would fail, because names do not survive unification and collide across modules.

## From declarations to a graph

The phase assembles the module graph in order: declarations first, then the expressions inside them, then passes over the finished graph.

Each entry of the graph is one top-level item: a value or function, a record-alias constructor, a constructor of a custom type, a port or an effect manager. While the phase walks each item's expressions it collects the global names the item depends on and the record fields it uses, and stores them on the entry. The whole-program half links these graphs and follows the dependencies to find what is reachable from `main`.

The typed graph is cached on disk between builds. A few fields are filled with defaults when the cache is read back, such as the set of fields used and whether the module defines `main`, so no later phase may depend on them. [compiler.md](compiler.md) explains how the `main` marker reaches the build despite this.

## The expression rewrites

Four rewrites happen as the phase walks each expression. Each needs only the module and the types the front end recorded.

### Pattern matches become decision trees

A pattern match is compiled into a tree of tests, each examining one part of the value, so that no part is examined twice. A branch reached by one path is placed inline; a branch reached by several paths becomes a shared jump target, so its code is not duplicated. Each step into a value records what kind of container it is looking inside, a list, a pair, a triple or a custom type, so that later phases can choose a typed projection instead of a generic one. The pattern checks have already run in the front end, so every tree is complete by construction and needs no fallback.

### Self-recursion becomes a tail-call definition

A function that calls itself as its final action is marked as a tail-call definition, so that later phases can compile it as a loop instead of a chain of calls that grows the stack.

### Operators become what they mean

The short-circuit operators become conditionals: `a && b` becomes `if a then b else False`, and `a || b` becomes `if a then True else b`. Treated as an ordinary call, `&&` reaches the strict `Basics.and`, whose intrinsic evaluates both operands and crashes programs that rely on the right-hand side not running. A conditional in the shared form gives every back end the right evaluation order with no special case. Passing `(&&)` as a function value stays strict, as it is in Elm.

The pipes `a |> f` and `f <| a` become the application they denote. They exist only to avoid brackets, and every specialization of them is a copy of the same tiny function, so if they reached monomorphization they would fill its registry of specializations with clones. When `f` is itself a partial application, the argument is added to that call rather than wrapped around it, which gives the same saturated direct call the source would have produced without the pipe. Unary minus becomes a call of `Basics.negate`. Every other operator stays a reference to its function, typed at the use site.

Only the infix form of an operator is rewritten:

```elm
        Can.Binop _ binopHome name _ left right ->
            ...
            if binopHome == ModuleName.basics && name == "and" then
                -- a && b  ==>  if a then b else False
                lowerShortCircuit
                    (\l r -> ( l, r, boolLit region False tvar ))

            else if binopHome == ModuleName.basics && name == "or" then
                -- a || b  ==>  if a then True else b
                lowerShortCircuit
                    (\l r -> ( l, boolLit region True tvar, r ))

            else if binopHome == ModuleName.basics && (name == "apR" || name == "apL") then
                -- a |> f  ==>  f a        f <| a  ==>  f a
                ...
                                |> Names.map (applyOneMore region tipe tvar optFn)

            else
                -- The operator reference is typed at this use ...
```

From the binary operator case of `optimize` in `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`. Notice two things. An operator passed as a value, as in `List.foldl (&&)`, is a different canonical form and never reaches this case. And each rewrite reuses the operator node's own type and variable for the nodes it builds. That reuse is how the rewrites preserve types, and it is the only thing that does: type preservation is a documented rule that nothing checks.

These rewrites are done here and not during name resolution because the canonical tree keeps each operator for error messages, and that tree is also serialized for documentation and interface files, which must see the source as written.

### Ports get their codecs

A port is a typed channel between an Elm program and its host. For each port the phase writes the JSON encoder or decoder as ordinary typed code, built from the port's declared type. Flags, the value the host passes in when the program starts, use the same decoder builder. The work needs only the declared type, so it is done per module.

## Merging function boundaries

The phase merges function boundaries that would otherwise force extra closures. A function that takes one argument, binds some local values and then returns another function, such as `\x -> let y = f x in \z -> g y z`, makes every call build an intermediate closure and call it again. Such a split is a staging boundary. At a case expression whose branches are functions, the boundaries also force each branch to be wrapped to a common shape. Merging them here leaves later phases fewer closures to build and fewer branches to wrap.

Two rules do the merging. The first turns a function whose body, after its local bindings, is another function into a single function of both sets of parameters, with the bindings inside. The second turns a case whose branches are all functions of the same arity and parameter types into one function around the case, renaming each branch's parameters to one shared set of fresh names. Both are applied to each function repeatedly until nothing changes.

The case rule is all or nothing: every branch is merged or none is. Merging only some branches would leave the others needing wrappers of their own to match, which adds closures instead of removing them. The rule also leaves the code as written whenever its type check is unsure. The fresh names stay fresh across the module because name resolution forbids shadowing.

Merging runs here, before monomorphization, because monomorphization only specializes types and keeps whatever function structure it is handed. The final number of parameters of each function, and how calls to it are staged, are decided by global optimization once the whole program is specialized. Local optimization removes only the boundaries that are plainly spurious and chooses nothing else about arity. Functions built by merging carry no lambda identity yet. Those ids are given by the first whole-program step, which gives every variable in the linked graph an id ([compiler.md](compiler.md)).

The typed and untyped optimized forms are not kept provably equivalent. Merging reshapes the typed form and has no counterpart in the erased one, so a check that the two agree would forbid the merging.

## Two copies of the same algorithms

The erased path keeps its own untyped copy of this phase. The typed pattern compiler, case lowering and port codec builder are typed mirrors of the erased ones and run the same algorithms. The erased copy stays as Elm wrote it, because the erased path must produce exactly what Elm produces ([compiler.md](compiler.md)), so the typed versions sit beside it rather than inside it. The cost is that a fix to one copy must be made by hand in the other. The usual hazard is an assumption about value layout that is copied across and holds only for some shapes, such as a tuple rule that works for pairs and fails for triples.

## What the phase takes from earlier phases

The work above is safe because of four guarantees from the front end. The repair step after solving gives every expression a complete type and a solver variable, and supplies the types of kernel functions. Name resolution forbids shadowing, which makes the binder lookup unambiguous and the renamed parameters fresh. The pattern checks have passed, so decision trees are complete. And the cached typed format records the graph exactly, except for the fields filled with defaults on reading.

## Examples of changes that fit the theory
A change fits when it looks at one module, keeps every node's type and solver variable, and is correct before the concrete types are known.

- A rewrite of an operator or a call that builds its nodes from the original node's metadata and needs no concrete type. The short-circuit and pipe rewrites each have this shape, as a small change in the binary operator case.
- Another boundary-merging rule shaped like the existing two: structural, guarded by a type check, and leaving the code alone when unsure.
- Another kind of port payload in the typed port code, with the matching change in the erased copy if the JavaScript path needs it.
- Another kind of top-level declaration, registered in the module graph together with its annotation, as record-alias and custom-type constructors are.
- More solver information for monomorphization, carried as data on each node or in the computed class records.

## Examples of changes that would break the theory
- A rewrite that needs a concrete type, such as handling Int keys differently from String keys. The type here is still polymorphic, so the rewrite cannot tell which case it is in and slows the others: rewriting `compare` here would cost String keys a second walk. Do it after monomorphization; the rewrite of `case compare a b of` into a direct three-way comparison is done as a pattern rewrite on the generated MLIR for this reason.
- Choosing arity, staging or currying here beyond the merging rules, or teaching monomorphization to flatten functions. Two phases would then decide the same thing. Leave those decisions to global optimization.
- Building a node whose metadata disagrees with what the solver recorded, or giving a function-typed definition its body's variable. Nothing checks it here, and monomorphization later crashes or specializes wrongly. Build each node's metadata from the node it replaces or from the binder.
- Typing an operator or a global reference from its scheme instead of from its use. The scheme cache would then hold one use's type, or an operator would carry the enclosing definition's constraint. Type it from the solver's answer at the use.
- Fixing a pattern, port or case bug in one copy only, when the same code exists in the other. The bug stays on the other path. Check the sibling module and fix both.
- Moving a rewrite into name resolution because it is easier there. Error messages, documentation and interface files read the canonical tree and must see the source as written. Keep the rewrite here.
- Depending on the used-fields set or the `main` flag of a graph read from the cache. Both are defaults after reading. Recompute what is needed from the graph, or use the marker the build already carries.

## References

Parent: [compiler.md](compiler.md). Related: [front-end.md](front-end.md), [monomorphization.md](monomorphization.md), [global-optimization.md](global-optimization.md), [mlir-generation.md](mlir-generation.md).

Code:

- `compiler/src/Compiler/LocalOpt/Typed/Module.elm`: `optimizeTyped`, the per-module entry point, declaration kinds and step order, ending in `withComputedVarSupers` (`varSupers`).
- `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`: expression lowering, the `Can.Binop` rewrites and `applyOneMore`, `optimizePotentialTailCall` (`TailDef`), `findVarLocalTvar`.
- `compiler/src/Compiler/LocalOpt/Typed/NormalizeLambdaBoundaries.elm`: boundary merging and the `_hl_` renaming.
- `compiler/src/Compiler/LocalOpt/Typed/Case.elm`, `DecisionTree.elm`: pattern compilation, `Inline` and `Jump` branches, `ContainerHint`.
- `compiler/src/Compiler/LocalOpt/Typed/Names.elm`: the tracker that collects dependencies and fields.
- `compiler/src/Compiler/LocalOpt/Typed/Port.elm`: port and flags codecs.
- `compiler/src/Compiler/AST/TypedOptimized.elm`: the typed optimized form (`TOpt`), `Meta`, `LocalGraph`.
- `compiler/src/Compiler/LocalOpt/Erased/`: the untyped copy, used by `Compiler.Compile.compile`.

Documents:


Invariants (`design_docs/invariants.csv`):

- TOPT_001, TOPT_005: a type on every node, full function types on lambdas. TOPT_002: complete decision trees. TOPT_003: annotations kept in the graph. TOPT_004: type preservation, documented and not checked. TOPT_006: ground wrapper types on unboxing paths. TOPT_002 and TOPT_003 name `Compiler.Optimize.Typed.*`, which is `Compiler.LocalOpt.Typed.*` in the code.
- SNAP_TVAR_001: polymorphic metadata keeps its solver variable.
- PORT_007: port and flags codecs.
- ECOT_001 to ECOT_003: the cached typed format.
- GOPT_016: global optimization owns staging.
