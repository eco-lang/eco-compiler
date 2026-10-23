# Monomorphization

Monomorphization turns the linked, typed and still polymorphic program into a closed graph of specializations, one for each global at each concrete type the program uses it at. It exists because Eco's native code stores Int, Float and Char unboxed in heap fields and closures, so every value needs one concrete layout, and a function that works for any type has to become one copy per type. The pass starts from `main` and the synthesized decoder for the program's flags and works through a list of demands, each asking for one global at one type. It types a demand by loading the definition into a fresh, empty store, pinning its type to the demanded one, and running the type checker's own unifier over the body. Every global the body names becomes a further demand, until none is left. Elm's `number` stays open throughout, and the pruning step that ends the pass, which also drops the specializations nothing reaches, closes whatever is still open to Int. The same store carries lambda sets, the record of which functions can reach each place that holds a function, and they form part of a specialization's identity. The pass decides types and the lambda sets that travel with them. How curried functions are grouped into calls, how values are laid out in memory and how kernels are called are left to the passes after it.

## Specialization is type inference run again, once per demand

The type checker has proved the program well typed, but it has not said what each type variable inside a polymorphic body becomes at one particular use. Running the checker's unifier over that one definition, with the demanded type as the first fact, answers exactly that question, by the same rules type checking used.

The unifier works on a union-find store. Each type variable is one point in the store, unifying two types merges their points, and a point can be bound to a type. A per-demand table maps each variable of the definition to its point, so every occurrence of a variable is the same point, and a fact learned anywhere in the body reaches every place the variable appears, whatever order the facts arrive in. That independence from order matters because in Elm concreteness often flows backward, from a consumer to its producer. A list built in one place learns that it holds Floats only where it is later summed into a Float, and a store that merges points handles that direction with no extra machinery.

Each demand gets a fresh store. The demand list already does what instantiation does in the type checker, giving each use of a polymorphic definition its own copy of its variables, so the checker's record of which variables are instantiated where is not needed. A fresh store also makes it impossible for one specialization's facts to bind a variable in another. Under a real unifier such a leak is fatal, because a wrong binding becomes a wrong layout.

## Where the pass sits, and what it is handed

A preparation step runs first. It gives every type variable in the program a number unique across the whole program, gives every source lambda and every function arrow in a type an identity, records which variables the solver constrained to `number` or `comparable`, and synthesizes the flags decoder. The rewrites that run before the pass (alias forwarding, eta expansion to declared arity and an optional inliner) take any identity they create from the same single source. A repeated identity silently puts two function bodies under one member of a lambda set, so the shared source is the only safe way to create one.

The pass needs four things from the front end:

- every node carries its full type, and every global its canonical annotation;
- the solver's union-find roots and variable classes are saved in the cached artifacts, so that a variable's identity and whether it is a `number` come from the solver as data;
- every function arrow in a type is stamped with the solver root it came from, which gives each arrow the identity that lambda sets need;
- kernel types are honest type schemes, because a real unifier rejects shapes that a looser substitution would have absorbed.

Variable identity and class come from the solver rather than from variable names because names collide across modules and type schemes, and deriving the class from a name silently drops `number`.

After the pass come a check that every closure's parameters and captured values fit within the arity limit of one closure stage ([global-optimization.md](global-optimization.md) explains stages), the post-monomorphization inliner, a second prune, and global optimization.

## Why the pass stays narrow

The pass decides types and nothing about representation. It keeps function types curried, one argument at a time, because global optimization owns staging and must be handed the curried shape to regroup. It hands on, for each constructor, a shape that names the constructor and its field types and says nothing about layout, because the MLIR generator computes layout from the type and that shape. Kernel calling conventions belong to the back end. Each of these decisions sits in the pass that owns that representation. A pass that also chose layouts would have to agree with the generator about them, and two owners of one decision drift apart.

## Demands, keys and the registry

A demand is a pair of a global and a concrete type. The registry files each demand under a key and gives each distinct key a dense number. Every reference to a specialization is that number, so the graph is closed: each reference points at an entry that exists. A specialization that refers to itself while it is still being translated just gets its own number back, which is why ordinary recursion terminates. The order in which demands are taken does not change the result, because each store is independent of order and the registry interns by key.

The key compares types up to what code generation can see, so that two specializations that would compile to the same code share one entry. Two rules carry this.

- Every boxed type variable compares equal to every other, whatever its number. A boxed variable is one that nothing in the use fixes, such as the element type of an empty list passed to `List.length`. Each demand mints fresh variables of this kind, and if their numbers entered the key, every demand would split into identical copies.
- An open `number` is keyed exactly like Int. The prune closes every open number to Int anyway, and a Float use always arrives as a bound Float by the time the key is taken, never as an open number. Keying the two alike merges copies that would otherwise be identical.

Both rules are decided at the leaves of the key comparison:

```elm
leafKeyTag : MonoType -> Int
leafKeyTag mt =
    case mt of
        MInt ->
            1

        MFloat ->
            2

        ...

        MVar _ constraint ->
            case constraint of
                CEcoValue ->
                    7

                CNumber ->
                    1

        _ ->
            0
```

From `compiler/src/Compiler/AST/Monomorphized.elm`, used by the key equality `eqKeySpec`. Notice that the variable's number never reaches the key, and that an open number gets Int's tag. Function arrows also compare their lambda-set annotations, described below.

The output types have only two kinds of open variable. One is an undecided `number`, which must never reach code generation. The other is every other variable, including those constrained to `comparable` or `appendable`: their values are always boxed, so the class never changes a layout and needs no defaulting. The class still matters while solving. The store loads such a variable with its class, and the unifier checks it against the same Char, String and List types the type checker uses.

## Typing one demand

A demand taken from the list is a work item, or item. One item is typed in four steps, in this order.

1. The definition's annotation is loaded into the empty store and unified with the demanded type. This unification is strict: a failure means the registry handed the definition a type it cannot have, which is a compiler bug, so the pass crashes and prints both types.
2. The pass walks the body. At calls, branches, records, record updates and tail calls it asserts further equalities, so that context flows into a child before the child is translated. These connections are best effort: on failure the store rolls back and the variables stay unbound, and therefore boxed. The type checker has already proved the program compatible, so a failure here reflects only a shape the store cannot match, such as an erased kernel signature or two curried shapes that differ, and leaving the variable boxed is correct.
3. Each point is read back into a concrete type. A variable still unresolved becomes an open number if its class is `number`, and a boxed variable otherwise. Reading back never defaults anything.
4. Every global the body references becomes a demand. The facts the item learned about numbers are added to a program-wide table, leaving out the definition's own annotation variables.

The loop that runs these steps over the whole list is short, and its order is the design:

```text
drain s:
  worklist empty:
    dirtyList empty                  -> done
    joinRounds >= maxJoinRounds (100) -> EngineBug
    else worklist := dirtyList; dirtyList := []; joinRounds += 1; drain
  pop SpecializeGlobal specId; processItem specId:
    specId in inProgress             -> skip (self-reference while translating)
    already done and not dirty       -> skip (stale duplicate)
    (global, type) := Registry.lookupSpecKey specId
    Engine.resetItem                 -- fresh store and per-item memos
    specializeNodeSaturating         -- load annotation, unify strictly with type,
                                     -- translate body; every global reference
                                     -- calls Engine.enqueueSpec (global, zonked type)
    harvestSuperTableExcept; ResolveAccessorValues.rewriteNode; finishNode
  itemAux.pendingFailure set (watchdog trip) -> stop with it
  else drain

enqueueSpec (keyed path) on key K:
  miss                               -> new SpecId, check watchdogs, push on worklist
  hit, join leaves stored type alone -> return the id
  hit, join changes stored type      -> markDirty (re-run in a drain-end round)
```

Pseudocode of `drain` and `processItem` in `compiler/src/Compiler/MonoSolver/Monomorphize.elm`, with the enqueue in `MonoSolver/Engine.elm` and the interning in `Monomorphize/Registry.elm`. Notice three things. The reset replaces all per-item state, so nothing typed in one item survives into the next. A repeated demand never re-translates on the spot: a specialization whose stored type widens is marked and re-run in whole rounds once the list is empty. And a watchdog trip is acted on only between items.

## When the consumer decides the type

Ordinary unification covers most backward flow. Two let-bound cases need more, because one let-bound name can be used at several types in one body, while the store has only one point per variable. A let-bound `number` used at both Int and Float is split into one copy per type. A let-bound function, or a value containing lambdas with free variables, is cloned once per type it is used at. Both work body first: the pass translates the body of the let, records each type the name is used at, and then translates the bound expression once per type in a scratch store and renames the uses.

A value's layout must be a pure function of its recorded type. The pass emits its output while it solves, so a value read early in an item can be recorded as boxed and only later learn a concrete type. The place that builds the value and the place that reads it would then pick different slot representations, and no emitted code is correct under that disagreement. The pass prevents it three ways. It connects the types of the two views wherever they meet, for instance at an application, a loop parameter, a record update or the body of a let. It translates the item again when an erased read is bound later in the same item, up to five passes, beyond which the engine reports a bug. And the emitter crashes on a disagreement instead of repairing it, because a repair would only hide the engine bug that caused it.

## `number` stays open until the prune

`number` is decided in exactly one place, the prune that runs once the demand list is empty. As the prune copies the live specializations, it turns every open number into Int, and also every boxed variable that the final number table marks as a number. It then recomputes the constructor shapes from the closed types. A number that survives the close is a crash; a genuinely boxed variable may survive, and stays boxed.

Deciding at the end is what makes Float uses come out right. A Float use typically appears late, at a consumer, so a guess of Int made early is wrong exactly where it matters, and every early guess needs a layer of repair to undo it. Deciding when a point is read back is too early as well. A merge discovered while typing one item can show that a variable another item already read back as boxed is really a number, and only the final, program-wide table holds that fact.

When a number meets a boxed variable, the number wins. In `Debug.log "x" (10 + 3)` a number flows into a slot typed for any value. Unifying it toward the boxed variable would type an unboxed integer as a pointer, so the boxed variable is marked as a number instead, and the prune closes it with the rest.

The number facts live in two tables, kept apart on purpose. A static table, built from what the type checker solved, is read when a variable is loaded. The harvested table, gathered from what items learn, is read only when reading back, keying and pruning. An item's harvested fact must never be visible when another item loads its variables, because it would block a unification there that the type checker allows. For the same reason a definition's own annotation variables stay out of the harvest, and kernel signatures whose variables are preserved get fresh variable numbers in each item. Either kind of leak closes something to Int that is not a number: an erased `List a` becomes `List Int`, or a Debug kernel type is closed to Int and crashes when called at Float.

Closing works by position: it rewrites types in place. It cannot work out a kernel's calling convention again or undo a call that translation made direct. Any decision during translation that commits to a layout must therefore decline when its type still holds an open number. A direct kernel call on a list of open numbers, for example, would declare an integer signature for a list that may turn out to hold Floats.

The prune is also reachability. It keeps only the specializations reachable from `main` over the recorded call edges, and empties the rest without renumbering them.

## Lambda sets are solved in the same store

A lambda set records which function values can reach a place that holds a function. Only the solver engine computes them, and it does so by default. Every function arrow loaded into an item's store carries a slot for its set, and the same unifier that merges types also joins these slots. Reading back turns each slot into an annotation on the function type.

The annotation is part of the key, so two demands that differ only in which functions they pass get separate specializations. That gives a higher-order function one copy per set of callers' functions, which later passes need to prove calls direct. Demands that meet on one key share the specialization and store the join of their annotations. If the join changes the stored type, the specialization is translated again in the rounds shown in the loop above, up to a fixed cap of 100.

Keying on sets adds a source of non-termination of its own, separate from polymorphic recursion. A member that names a lambda is qualified by the specialization that created it, so a specialization can create a member that demands a further specialization, which creates another member, without end. Translation stops that chain by tying each lambda it creates to the matching member already present in the specialization's stored demand, so the same lambda in a recursive specialization stays one member instead of a new one each round. [lambda-set-specialization.md](lambda-set-specialization.md) gives the details.

The sets reuse this pass's store because they need exactly the per-arrow typing and unification it already does, and a second analysis would repeat that work. A lambda field in the key beside the type is not used. Unification never fills such a field, so it has to be threaded through every part of the pass and carries nothing; an annotation on the arrow sits where unification already joins it. How members are named, how callee bodies are summarized and what the kernels contribute belong to [lambda-set-specialization.md](lambda-set-specialization.md).

## Polymorphic recursion and the watchdogs

The demand list is finite unless the program uses polymorphic recursion, which legal Elm can express through annotated mutual recursion. Such recursion grows a type on every round. Types are never widened, so nothing inside the algorithm can bound the growth. Two watchdogs limit it instead: one on the number of specializations created for one global, and one on the size of a demanded type. Only the creation of a specialization is checked, never a repeated demand.

A trip is a property of the program, so it is reported to the user with advice to add a concrete annotation at the recursive call, and it is kept distinct from the engine's own bug reports. The step that files a demand has no way to return an error, so the trip is recorded on the current item and the list stops before the next item.

After the pass, the staging check confirms that closures stay within the arity limit, so a specialization that multiplies captured values fails with a located error rather than an assertion in the MLIR generator. The layout rule and the single minting of lambda identities have checkers of their own, run on request.

## Two engines and the comparison between them

The pass has two engines. They share everything except how one definition is specialized: preparation, the registry, the prune, the kernel signature rules, the checks and the output form. The solver engine, the default, is the one described above. The substitution engine carries a map from type variables to concrete types down the body and never computes lambda sets.

Reusing the type checker's unifier is preferred because the substitution engine amounts to a second, weaker theory of Elm types. It works forward only, depends on the order it meets facts, and fails silently. Most of its machinery retrofits flow from consumer to producer: several kinds of deferred work and several let-scope specialization stacks. A union-find store needs none of this. One fact resolves a whole class of variables, and its record unifier keeps record extensions. The solver engine keeps the worklist, the registry and the translation into the output form, and replaces only the unification.

The substitution engine stays for two reasons. It is the oracle for a comparison mode that runs both engines on the same prepared program and fails when their outputs differ. It is also the lighter engine on the JavaScript heap, so the self-compilation stage that runs the compiler as JavaScript uses it; that stage's output only has to be a correct compiler, and nothing shipped is built from its MLIR.

The comparison serializes both graphs to a canonical text that erases only what legitimately differs: the numbers of boxed variables and the order of record fields. Structural equality on the graphs would fail on insertion order alone. Lambda sets are off in the solver engine during the comparison, because the substitution engine cannot produce them and every annotation would mismatch. The serializer is written by hand because the compiler is built in optimized mode, where `Debug.toString` is unavailable. A mismatch fails the build; the comparison never falls back, and neither engine's output is built from the other's.

The solver engine is a complete engine beside the substitution engine, not a migration that routes items through the solver one at a time and then deletes the old engine. It is the default, so every build exercises it. It has no fallback, so it cannot quietly hand a hard case to the old engine, and the comparison mode checks it against the oracle. Parity means the same behavior at run time. Byte-identical output is not the test, because the remaining byte differences are unreachable specializations keyed differently, which the prune removes.

A project settings file selects the engine with one trap. With no settings file, or a file with no monomorphization section, the build uses the solver engine. A monomorphization section that does not name an engine selects the substitution engine, and with it lambda sets off, so a project that sets any monomorphization option, such as a lambda-set or limit option, must name the engine as well. An engine name the decoder does not recognize gives the solver engine, and an environment variable overrides the file.

## Other ways to reuse the checker

Two other designs reuse the type checker without a store per demand, and neither is used.

Querying a snapshot of the checker's solved state, through a handle on each node, fails for four reasons. The solved union-find has lost the instantiation edges that let-polymorphism needs. Every optimizer pass has to preserve the handles, and nodes the compiler synthesizes have none. A fallback to substitution returns for the cases the snapshot cannot answer. And the snapshot covers one module, while monomorphization is whole program. Its central idea, that the solver's roots are the identity of a type variable, is the one the preparation step uses.

Solving the original constraints again for each specialization is more machinery than the job needs. The constraints do not map onto the optimized program's nodes, such as decision trees, ports and synthesized nodes, and the equalities the pass needs already follow from the shape of the program.

## Keeping self-compilation affordable

The compiler compiles itself, so the pass's cost on its own source sets the limit. Types are hash-consed, so each distinct type is built once, because self-compilation otherwise builds many times more type nodes than there are distinct types and the collector's cost grows with what survives. Interning compares types with exact equality, never with the key's equality, because the key folds open numbers into Int and erases variable numbers.

The engine's state-passing functions are written as explicit chains of `case` expressions, without monadic combinators. The native back end returns several results in registers only from a function whose every result is a literal tuple, and a combinator chain never is one.

The engine's state records are compiled by Eco itself, and comments in the engine treat 32 fields, the size of the slot-kind bitmap in a record's header, as a hard cap on such a record, so much of the state sits in sub-records. Those comments are stale. A record wider than its header bitmap carries extra kind words after its fields, the compiler and the runtime both accept up to 2047 fields, and end-to-end tests cover records wider than 32. The sub-records do no harm, but the cap is no reason to add more.

## Pruning twice

Both engines create specializations that turn out unreachable, and the post-monomorphization inliner orphans more. Reachability is exact only after the inliner and before global optimization adds references by other routes, so a second prune runs there. It collects edges again from the rewritten bodies and does no closing of numbers. Pruned entries are emptied, never renumbered, because lambda-set members, call edges and later passes all hold specialization numbers.

## Examples of changes that fit the theory
A change fits when it adds an equality to an item's store, a demand to the list or a check that reports a property of the program, and leaves staging, layout and calling conventions to later passes.

- A construct whose type its consumer decides becomes another equality in the item's store: a connection between two types, or a frame for a loop or an application. Connecting the body of a let to the type of its node, or the record's type to the update's type, has this shape.
- A let-bound value used at several types extends the body-first split: discover the uses, translate once per use in a scratch store, and rename. Local tail-recursive definitions used at several types are split this way, one loop per type.
- A further kind of global, such as another synthesized definition or kernel family, gets a canonical type and enters as an ordinary demand. The registry, the prune and both engines then handle it like any other global, as they handle the flags decoder.
- A change to specialization semantics that both engines share goes into both, and the comparison mode confirms it. The comparison means something only while both engines implement the same rules.
- Anything about which functions can reach a call belongs to [lambda-set-specialization.md](lambda-set-specialization.md).
- Performance work cuts allocation per item: hash-consing, results the back end can return in registers, memoization keyed per global.
- A further limit on growth reports through the engine's error channel as a property of the program, as the watchdogs do, so the user gets advice instead of a compiler bug.

## Examples of changes that would break the theory
- Defaulting a `number` anywhere before the prune, or committing to a layout on a type that still holds an open number. A Float found later in another item cannot then be honored, and the prune's positional close cannot undo the decision. Keep the number open and have the decision decline.
- Comparing or interning types with the key's equality where exact equality is meant. The key folds open numbers into Int and erases variable numbers, so two different types would be treated as one. Use exact equality outside the registry.
- Changing the key to tell apart things the prune merges, such as two boxed variables, or an open number and Int. That splits specializations that compile to identical code. The key is identity up to what code generation can see.
- Harvesting a definition's own annotation variables into the program-wide number table, or letting one item's number fact reach another item's loading. Either closes non-numbers to Int. Load from the static table and read the harvested table only at read-back, keying and pruning.
- Adding boxing or unboxing shims in the MLIR patterns to repair a layout disagreement. No emitted code is correct under the disagreement, and the shim hides the engine bug. Make every view of the value agree inside the engine.
- Making a best-effort connection strict, which crashes on erased kernel signatures the checker accepted, or making the strict root unification lax, which hides registry bugs. Keep each where its reason applies.
- Falling back to the substitution engine on a hard case. The solver engine has no fallback so that an unhandled construct is a loud error; handle the construct in the solver engine.
- Loosening the comparison's canonical text to hide a mismatch, or letting one engine borrow the other's output. Either makes the comparison meaningless. Find which engine is wrong.
- Raising or disabling a watchdog limit to get past a type that keeps growing, or reporting a trip as a compiler bug. Growth from polymorphic recursion never stops; the fix is an annotation in the program. Raise a limit only for a program that really is that large.
- Staging, uncurrying, layout or calling-convention choice inside the pass. Each has an owner downstream, and a second owner drifts from the first. Put it in global optimization or the MLIR generator.
- Another kind of deferred work, or another let-scope specialization stack, for a typing problem. That rebuilds the substitution engine's machinery inside the solver engine. Use a store connection or the body-first split.
- A project settings file that sets monomorphization options without naming the engine. It silently runs the substitution engine with lambda sets off. Name the engine.

## References

Parent: [compiler.md](compiler.md). Sibling that runs inside this pass: [lambda-set-specialization.md](lambda-set-specialization.md).

Code:

- `compiler/src/Compiler/Pipeline/Steps.elm`: preparation, the pre-pass rewrites, the pass, its checks, inlining and pruning; `checkMinted`.
- `compiler/src/Compiler/Eco/Config.elm`: `MonoConfig`, `LssConfig`, `Config.default` (`EngineSolver`) and `monoDecoder`, whose `D.optionalField "engine" D.string "subst"` makes a `mono` object without `engine` select `EngineSubst`. `compiler/src/Builder/Eco/Config.elm`: the `ECO_MONO_ENGINE=subst|solver|diff` override.
- `compiler/src/Compiler/MonoSolver/Monomorphize.elm`: the driver (seeds, `drain`, `processItem`, `specializeNodeSaturating`, assembly).
- `compiler/src/Compiler/MonoSolver/Engine.elm`: engine state `S`, `resetItem`, `enqueueSpec`, the watchdog check, `harvestSuperTableExcept`, the field-cap comments.
- `compiler/src/Compiler/MonoSolver/Store.elm`: loading, `unifyStrictS`, `unifyBestEffortS`, `zonkToMono`.
- `compiler/src/Compiler/MonoSolver/Zonk.elm`: classifying a canonical type into a `MonoType` without a store.
- `compiler/src/Compiler/MonoSolver/Translate.elm`: translation, `connectTypes`, `demandUnifyRoot`, number and local splitting, kernel signatures, `kernelDevirtShapeOk`.
- `compiler/src/Compiler/MonoSolver/Diff.elm`: the comparison mode.
- `compiler/src/Compiler/Monomorphize/Registry.elm`, `compiler/src/Compiler/Monomorphize/Prune.elm`: interning, joins, `watchdogAdvice`, reachability, `pruneUnreachableSpecs` (number closing) and `pruneAfterInline`.
- `compiler/src/Compiler/Monomorphize/ValidateLimits.elm`, `compiler/src/Compiler/Monomorphize/ValidateLayout.elm`: the post-pass checks.
- `compiler/src/Compiler/AST/Monomorphized.elm`: `MonoType`, `Constraint`, `leafKeyTag`, `eqKeySpec`, `LambdaSetAnno`, `SpecKey`, `CtorShape`.
- `compiler/src/Compiler/Monomorphize/Specialize.elm`, `compiler/src/Compiler/Monomorphize/TypeSubst.elm`: the substitution engine.
- `compiler/src/Compiler/Type/Unify.elm`: the unifier shared with the type checker.
- `compiler/CMakeLists.txt`: the self-compilation stage that pins the substitution engine.

Settings: `mono.engine`, `mono.lss`, `mono.limits`, `mono.validate` (`ECO_MONO_VALIDATE=1`); watchdog limits `ECO_SPEC_BREADTH_LIMIT` (default 50,000 specializations per global) and `ECO_SPEC_TYPE_NODE_LIMIT` (default 400,000 type nodes), where 0 disables a check.

Documents: `design_docs/monomorphization/design-recovery.md` and `design_docs/monomorphization/solver-reuse-evaluation.md` hold the design reasoning. Both are stale on the engine, the key and where `number` is defaulted.

Invariants (`design_docs/invariants.csv`): MONO_001, MONO_002, MONO_003, MONO_005, MONO_011, MONO_017, MONO_019 to MONO_025, MONO_028, MONO_029, MONO_030, GOPT_001, GOPT_016, REP_HEAP_001, TYPE_SUPER_001, FORBID_SUPER_NAME_001, LSS_017, LSS_018; the other LSS rows are in [lambda-set-specialization.md](lambda-set-specialization.md).
