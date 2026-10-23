# Lambda-set specialization

Eco works out which functions can reach each call by giving every function arrow in monomorphization's per-demand store a slot for a set of function values. The unifier that merges two types also joins their slots, so a set goes wherever its type goes, and a member of a set names one function value by its identity alone. A callee's effect on the sets is summarized once, as a memoized signature, and only definitions that some demand reaches are ever summarized. The published algorithm works in two passes: inference over the whole program, bottom-up in dependency order, which leaves what a definition cannot know as set parameters, and then a separate specialization pass, top-down from the entry point, which fills those parameters in. Eco runs both directions inside monomorphization's demand list instead, which reuses its solver and its worklist and never analyzes dead code. The cost is that a set is a ground fact as soon as it is computed, so whatever a definition cannot know becomes "any function" or "unknown", never a parameter that its callers fill in.

## What the sets are for

Two Elm values of type `Int -> Int` can come from different lambdas. The type checker does not tell them apart, but the code generator needs to. A call through a value known to be one particular function can jump straight to that function's code, while a call through an arbitrary closure has to read the closure's header and dispatch generically. A lambda set records, for each place that holds a function, which functions can be there, and a set with exactly one member lets a later pass prove the call direct.

Every consumer therefore asks one question: is this set a single known function? Inside monomorphization, a call through a local variable whose set is a single constructor or a single permitted kernel becomes a direct call. Global optimization stamps a call site whose set has one member for fast dispatch when it can also prove every instance of that member interchangeable, and it makes single-member calls to globals and constructors direct ([global-optimization.md](global-optimization.md)). A set with two or more members always lowers to generic dispatch, because Eco does not lower a function type to a sum over its members. The analysis is therefore judged on the singletons it finds and on never claiming one falsely. A set that is missing a member looks smaller than it is, and a false singleton becomes a direct call to the wrong code.

The sets are also part of a specialization's key, as [monomorphization.md](monomorphization.md) describes. A higher-order function gets one copy for each set of functions its callers pass, and inside each copy the calls through its function parameter can be proved direct.

## A set slot on every arrow

The sets are ordinary content in the solver store. When monomorphization loads a type into an item's store, each function arrow gets a third point beside its argument and result: a slot for its set. A slot holds either an unwritten variable or a set value. A set value is ⊤, meaning any function, or a sorted list of members, or a list of members together with directed edges that say "this slot also contains whatever those slots contain".

```elm
type FlatType
    = App1 Canonical String (List Variable)
    | Fun1 Variable Variable
    | FunL Variable Variable Variable
    ...
    | LambdaSet1 LambdaSet


type LambdaSet
    = LsTop Int
    | LsMembers (List Int)
    | LsFrom (List Int) (List Variable)
```

From `compiler/src/Compiler/AST/TypeVars.elm`. Notice that members are bare integers, so a member is an identity and nothing more. The integer on ⊤ only records where the widening came from. The sources in the third form are other store slots, and they are followed only when the slot is read back, so the order in which edges arrive does not matter. The edges exist because some flows go one way: a value passed into a slot adds to that slot's set without making the two sets equal, which a unification would do.

The unifier module is shared with the type checker and has the arms for these forms. Unifying two arrows that carry slots unifies the slots, and an arrow without a slot counts as one whose slot is unconstrained. Unifying two set values is a total join: the sorted union, with ⊤ absorbing everything. The type checker never creates an arrow with a slot, so only monomorphization's store reaches these arms and type checking is unchanged. Set unification never fails, and that is what lets every connection monomorphization makes join sets as well as types. Most of those connections are best effort and roll back on a type mismatch, so a set mismatch that could also fail would need a recovery path of its own.

Putting the sets in the store has the same reason as monomorphization's reuse of the type checker's unifier. The store already does per-arrow typing and unification for each demand, so a function value flows wherever its type is unified, and no separate dataflow analysis has to move function values around. Because each demand gets a fresh store, one specialization's sets cannot leak into another's.

Arrows have an identity before monomorphization starts. The front end stamps each function type with the type checker's solver root, and the preparation step turns that root into a program-wide arrow number. Within one item, loading a type reuses the set slot already created for the same arrow number, so two loads of one annotation share their sets and a fact written through one load is visible through the other. A fresh instantiation is loaded in isolation and shares nothing. Shared identity is how a set reaches a slot that a separate load would otherwise have missed, through plain unification and without any code that copies sets between slots.

### Members name code, not captures

A member is a small integer, interned for the run from a key that says which code object it is. The keys name the kinds of code object a function value can be:

- a source lambda, qualified by the specialization that created it;
- a top-level function, qualified by the arrow type it is demanded at;
- a constructor, a kernel (a global that only aliases a kernel folds to the kernel), or a record accessor;
- a partial application of a top-level function to a given number of arguments.

A member is written onto every arrow of the value's result spine, up to its declared arity, so a partial application of a function carries the same member as the function.

Members carry no captured values. Every consumer needs to know which code object inhabits an arrow, not what that code object holds. With identity-only members a set is a finite subset of a universe fixed for the run, so the join is a plain union and recursive set descriptions never arise. The layout of each closure's captures is recovered later, from the specializations that exist.

A lambda's member is qualified by the specialization that created it because one source lambda inside a polymorphic function is different code in each specialization. If its instances shared one member, global optimization could run one instance's code for another; in a self-compile that is a crash. A top-level function referenced as a value cannot be qualified the same way at the moment its member is created, because the specialization it belongs to is a result of translating the reference, so the qualification would be circular. Its qualifier is the demanded arrow type instead, attached when the slot is read back and the type is known.

## Demand driven, where the paper is staged

The design comes from Brandon and others, "Better Defunctionalization through Lambda Set Specialization" (PLDI 2023). Eco takes the paper's central idea, a set of functions on every arrow, solved by unification and used to specialize. It does not take the paper's order of work. The paper analyzes the whole program and then specializes it. Eco analyzes and specializes together, one demand at a time, and analyzes only what the demands reach.

### The paper's two passes

The paper's source language is simply typed. Every arrow carries a set variable, and a set is a concrete list of lambdas, a variable or a recursive set. It has no ⊤, because nothing in its language is opaque and no set is ever committed before it is known.

The first pass is inference, and it runs bottom-up over the definitions in dependency order, the way Hindley-Milner type checking does. Each definition is inferred against the already inferred signatures of its callees, and unification only equates set variables. A set variable that appears in the definition's type is promoted to a quantified set parameter, and the constraints it must satisfy, of the form "this lambda is in that set", are exported with the signature. Every other variable is settled inside the definition at its smallest solution, which is empty by default; the paper calls this internalizing the variable. A group of mutually recursive definitions is inferred as one unit, and inside it a reference to the group uses a provisional type, so inference never produces recursion that changes a set parameter from one call to the next.

The second pass is specialization, and it runs top-down from the entry point, in reverse dependency order. It makes one copy of each definition for each distinct set of concrete set arguments that its already specialized users pass, and it rewrites the references inside sets as it goes. The entry point's type has no function arrows, so every parameter that inference left open is eventually supplied by some caller. The paper needs no budget and no widening, because every set is known before any copy is made. A last step lowers each function type to a sum over its set's members.

### Eco: both directions inside each item

Eco has neither pass as a separate traversal. [Monomorphization](monomorphization.md) takes demands one at a time from its list, and each demand is a global at a fully annotated type. The two halves of the paper's work happen at the call sites inside each item:

```text
Paper:
  pass 1, bottom-up over SCCs in dependency order:
    infer against callees' schemes; set variables on the def's type become
    ∀ parameters with constraints Q; the rest are solved to their minimum
  pass 2, top-down from the entry point:
    copy each def once per concrete set arguments its callers pass

Eco, for each demanded item (G, T) popped by mono's drain:
  fresh store; load G's type; unify with T, set annotations included
  translate the body; at a call of global H (translateGlobalCallSlow):
    instantiateLss H      -- signatureFor H: bottom-up, memoized, first demand only
    unify params and result; translate args (members injected into slots)
    zonk H's type; enqueueSpecStamped (H, type with sets)   -- top-down demand
  zonk slots to LambdaSetAnno; discard the store
after the drain: dirty join rounds, then the five settle passes
```

The paper half summarizes sections 4 to 6 of the paper. The Eco half follows `compiler/src/Compiler/MonoSolver/Translate.elm` and the drain in `compiler/src/Compiler/MonoSolver/Monomorphize.elm`. In the code's terms, to zonk a slot is to read it back as an annotation, and the settle passes, described under reading a slot back, write the sets that only the finished program shows. Notice that the signature lookup is the bottom-up half and the annotated demand is the top-down half, and that nothing passes a set parameter from caller to callee.

Where the paper's caller supplies a set argument to fill a callee's parameter, an Eco caller reads the callee's type back with the sets its arguments carry and files that type as a demand. When that demand is translated, its annotations are written into the callee's fresh store before the body is walked, so the callee's body is solved with the caller's concrete sets already present. A different set gives a different key, and so a different specialization, which is the paper's "one copy per set argument". Because demands start at `main`, specialization still runs top-down from the entry point.

### Signatures, the bottom-up half

Each item is translated in a fresh store that is discarded at the end, so when a call to a global is translated, that global's body is not in any store. The callee is instead summarized once, as a signature, and the summary is applied at every call. A signature covers only the arrows of the callee's type, because a caller sees a definition only through its type, so those arrows are its whole interface. Sets internal to the body are left out and solved again in each specialization of it, which costs nothing extra because monomorphization walks each body once per item anyway. That is how Eco gets the effect of the paper's internalized variables.

The function that computes a signature is `signatureFor`, in `LssInfer`:

```text
signatureFor g:
  memoized in lssSignatures   -> return it
  lss disabled                -> trivialSignature
  g in lssInProgress          -> EngineBug (re-entry; pre-resolution prevents it)
  g is a Link                 -> signatureFor target, prefer g's own memo entry
  else inferUnit g:
    members := resolveUnit g        -- a Cycle is all its defs, else just g
    add members to lssInProgress
    preResolveCallees: signatureFor every global the bodies name that is
        outside the unit and not memoized   -- callees first, no nested scratch
    withScratchStore:
      loadMemberSlots   -- each member's annotation-first type, one shared store,
                        -- so self and sibling references share slots
                        -- (the paper's self-type rule, explained below)
      walkMembers       -- walkExpr each body, join its result into the spine
      zonkSignatures    -- slots -> ArrowFacts, own lambda id filtered out
    memoize every member's signature; remove members from lssInProgress
```

Checked against `compiler/src/Compiler/MonoSolver/LssInfer.elm`. Notice three things. Nothing reads the item being translated, its demand or its specialization number, so a signature depends only on its unit's definitions. Callees are resolved before the scratch store opens, so scratch stores never nest, and within the part of the program that demands reach, signatures are built callees first, in the paper's dependency order. And the members of a recursive group load into one shared store, so a reference to the group hits the group's own slots. That is the paper's provisional self-type rule: it rules out recursion that changes a set from one call to the next, and it is what makes signature inference terminate.

The walk over a body adds only set facts: members where function values are created, callee signatures at calls, kernel boundaries, and joins at lets. Each sub-walk also reports whether it saw everything that can flow out of it. Where a branch joins a value the walk could not see in full, the joining slot becomes ⊤ instead of keeping a set that looks complete and is not.

Each arrow of the unit's types is then read off as one fact: its members, whether it is ⊤ and why, the lowest-numbered arrow of the same type whose slot it shares (two arrows with the same set variable, in the paper's terms), and the arrows it draws from by directed edges. A caller applies a signature by loading the callee's type again, in isolation, and pairing each fact with a slot by the arrow's position in the type. Both sides load the same type, the annotation when there is one, with the same loader, so the positions agree. If the arrow counts ever differ, every slot becomes ⊤. Calls to callees whose signature says nothing, or whose arguments contain no arrows, skip the work.

### Why the analysis is demand driven

Three forces make Eco interleave the analysis with monomorphization instead of staging it.

Elm is polymorphic and the paper's language is not. An arrow inside a polymorphic type has no concrete set until a specialization fixes the type, and Eco keys a specialization by its fully annotated type, sets included, so set specialization and type specialization are one decision. Monomorphization already reaches every specialization by demand from `main`. A staged analysis in front of it would need a whole-program annotated program built before any type is concrete. One run after it would walk the program a second time, and because sets are part of the key, it would have to choose the specializations again.

The interleaving also reuses what monomorphization has. It already has a store per item, a unifier that joins slots, a worklist and a registry of keys. The analysis adds content to the store and annotations to the key, and needs no traversal or key space of its own.

And it costs less. Code that no demand reaches is never translated, so it is never analyzed, which gives the paper's rule for unused definitions without any work. No annotated copy of the whole program is ever held in memory, which matters when the compiler compiles itself on the JavaScript heap. And a signature costs one scratch walk per demanded recursive group for the whole run. That cost grows with the number of distinct globals reached, not with the number of specializations, which is why signatures are memoized per global rather than walked at each call site.

### What the interleaving costs, and what it forbids

The interleaving has three costs, and each one is a rule that changes must keep.

A signature is a ground fact, so a definition cannot hand an unknown to its callers to fill in. Where the paper exports a set parameter, Eco writes ⊤ or leaves the slot unknown. Much of the lost precision comes back by other routes: a signature covers only the type's arrows, the body is solved again in each item with the demand's concrete sets already in the store, and arrow identity lets two loads of one annotation share a slot. The rule this imposes is that a signature belongs to its definition group and is computed before any specialization of it. It must never read the item in flight. A fact that depends on the instantiation belongs in the item, or at read-back.

Demands arrive one at a time, so a specialization translated for an early demand can be invalidated by a later demand admitted under the same key with more members. The paper never meets this, because all its sets are known before it specializes. Eco stores the join of every demand admitted under one key and translates a specialization again, in rounds once the list is empty, when its join grows; [monomorphization.md](monomorphization.md) shows the loop. The join only grows and the sets form a finite lattice, so the rounds end. This is the iterative form of the paper's guarantee that every parameter is supplied before a copy is made. The rule it imposes is that a specialization's body must be valid for the stored join, never for one caller's set.

Termination is not automatic. In the paper, specialization ends because the sets are fixed before it starts. In Eco, qualifying lambda members by the specialization that created them can loop: a specialization creates members, the members change a key, and the key creates a further specialization. Eco closes the loop by tying each lambda created during translation to a qualified member of that lambda already present in the specialization's stored demand, so a recursive specialization reuses the member it was demanded with rather than creating a fresh one each round. Signatures terminate by the shared-slot rule for recursive groups, joins terminate because the lattice is finite, and types that keep growing are stopped by monomorphization's watchdogs. The cap on set size, above which a set reads back as ⊤, and the cap on specializations per global, above which keys are widened, are fan-out policy rather than termination. Both are unlimited by default, and the analysis must terminate with them unlimited.

## Reading a slot back

At the end of an item each slot is read back as an annotation on its function type, in one of four forms:

- a set, when the slot holds members and no ⊤;
- ⊤, when the slot reached ⊤, its edges reach ⊤, or it has more members than the size cap allows;
- unknown, when nothing ever wrote the slot or its edges resolve to nothing;
- a lower bound, "at least these members", which only the join of two annotations produces.

An unwritten slot never reads back as empty. An empty set claims the arrow is dead, and a set with a missing member becomes a false singleton. ⊤ and unknown are kept apart although consumers treat them alike, because they mean different things. ⊤ is deliberate widening, at a kernel, a cap or a join the walk could not see in full. Unknown is a flow that nothing recorded. Keeping them apart lets each be measured and fixed on its own. The paper has neither form, because it never commits a set early and never meets opaque code.

When the item ends its store is discarded, and set information leaves it in only three ways. Signatures are memoized for the run. The annotations on the demands the item files become part of their keys, and the registry joins them. And after the demand list is empty, five settle passes write the sets that only the finished program shows, such as the members that reach constructor fields and the variables bound from those fields. Anything that must cross from one specialization to another has to travel by one of these three.

## Kernels are opaque unless licensed

The analysis cannot see into the C++ kernels, so every arrow that crosses a kernel boundary becomes ⊤ by default. That is always sound, and a kernel left at ⊤ only costs precision. A kernel can instead carry a license in an audited table, and two kinds exist. Most licensed kernels are type faithful: function values cross the kernel only along the type variables its Elm type shares, so the set that comes out is the set that went in. One kernel, the bytes decoder, has a flow written out per parameter.

A wrong license is worse than none. It yields a populated set that is missing members, which becomes a direct call to the wrong code. Each row of the table therefore carries its audit evidence, the audited C++ files are pinned by hash in a manifest, and the default build fails when a hash no longer matches. The hash cannot see a change to a kernel's Elm type, so a type-faithful license's scope is checked again against the type at every occurrence instead of being trusted from the table.

## One switch

The analysis runs only in monomorphization's solver engine, and it sits behind one switch that is on by default. With the switch off, the solver engine creates no set slots and keys specializations by type alone, which is the baseline for any comparison. A project settings file that sets any monomorphization option without naming the engine selects the substitution engine and so turns the analysis off ([monomorphization.md](monomorphization.md) describes this trap). Every mechanism inside the analysis runs whenever the switch is on, because the mechanisms share traversals of the same sets and a switch is a boundary that both sides of a traversal must respect ([compiler.md](compiler.md)). The other settings are caps on fan-out, each read at one site, and report switches. A value that changes generated code contributes to the settings hash.

## Designs Eco does not use

Several designs appear in Eco's design record and are not part of Eco. Each is weighed against the same forces: a polymorphic, demand-driven monomorphizer, a fresh store per item, and sets that must never look more complete than they are.

Exporting unknowns as quantified set parameters is the paper's own answer, and Eco's design record holds three forms of it. Inclusion constraints with per-caller instantiation give byte-identical output on every program measured, so Eco does not carry them. Promoting set variables to quantified parameters covers only sets on existing arrows, and arrow identity recovers the same information more cheaply. An explicit set variable does exist, as the unknown form, but it cannot remove the join at a shared key: keying a specialization commits it to one concrete set, and only lowering sets to sums would lift that commitment.

Code that copies sets between slots created by separate loads, such as carrying call arguments into a callee or flowing signatures in both directions, loses direct calls and costs compile time. Arrow identity gives the same reach through ordinary unification, so Eco relies on it instead.

Members that carry their captures, recursive set descriptions and the lowering of a set to a sum of its members are deferred. Unboxed unions of captures do not pay on measurement, and generic dispatch is always correct.

Eco specializes each member of a recursive group separately rather than the group as one unit, and lets the joins carry sets around the cycle. That fits a demand list that files one global at a time.

A default set for a signature's head arrow, and set slots on the payloads of named types, measure neutral or worse, so neither is used. Eco has no per-mechanism switches, for the reason given under the one switch.

## Examples of changes that fit the theory
A change fits when it puts a member into a slot through one of the existing channels, or gives two loads one identity so that unification carries the set, and leaves ⊤ or unknown wherever it cannot be sure.

- A flow of function values that the analysis misses gets an injection where the value is created, or a settle write after the list is empty, with ⊤ or unknown as the fallback. It is pinned by an invariant and a test. The flows of partial applications along a result spine, of local functions used at several types, and of sets bound by pattern matching each have this shape.
- A kernel that can carry functions is audited for the three properties that rule a license out, as the license table's module documentation lists them: a value kept by one call and read by a later one, a value erased into an opaque type, and a function value the kernel creates. It is then given a row whose evidence records the audit, and its files are added to the manifest. When a licensed kernel's C++ changes, the audit is repeated before the hash is regenerated.
- A set that fails to reach a slot is fixed by shared identity: give the arrow an identity so that unification carries the set.
- A further consumer reads the stored annotations in global optimization, and treats ⊤, unknown and a lower bound alike as "not a single known function".
- Compile-time work skips trivial or inert signatures and memoizes per global, never per call site.

## Examples of changes that would break the theory
A change breaks the theory when it makes a set look more complete than the evidence, or makes a signature depend on one caller.

- Reading an unwritten slot as empty, or turning a lower bound back into a set. Either one fabricates completeness, which becomes a false singleton and then a miscompile. Leave the slot unknown and find the missing flow.
- Licensing a kernel, or regenerating its hash, without the audit. A wrong license is a miscompile, while a missing one only costs speed.
- Copying sets by hand between two slots that separate loads created. It duplicates what unification does and drifts from it. Give the arrow an identity.
- Making a signature read the item in flight, its demand or its specialization number. A signature belongs to its definition group and is computed before any specialization; put instantiation-specific facts in the item or at read-back.
- Building a specialization's body for one caller's set rather than for the stored join. A later demand under the same key would then run code built for a smaller set.
- Raising or setting the set-size or per-global caps to rescue termination. Termination comes from tying members to the stored demand, the finite join and the watchdogs; a loop that needs a cap to end is a bug in one of those.
- Adding a switch around a mechanism. It splits a shared traversal. Ship the mechanism under the one switch and check that it changes only the emitted code it should.
- Giving multi-member sets a fast path in one consumer. That is sum lowering, a change of representation that needs its own design.

## References

Parent: [compiler.md](compiler.md). Runs inside: [monomorphization.md](monomorphization.md). Consumer: [global-optimization.md](global-optimization.md).

Code:

- `compiler/src/Compiler/MonoSolver/LssInfer.elm`: `signatureFor`, `inferUnit`, `resolveUnit`, `preResolveCallees`, `inferUnitInScratch`, `walkExpr` and its honesty classes (`WpHonest`, `WpOpaque`, `WpSelf`, `WpNone`), `applyFacts`, `kernelCallBoundary`, member injection.
- `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm`: the license table (`TypeFaithful` with scopes `Inert`, `Transports`, `TransportsAs`; `Positional`; `factFor`, `licenseApplies`). `compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt` and `test/scripts/check-kernel-license-manifest.sh`, run by the `kernel-license-check` target in `ALL` (root `CMakeLists.txt`).
- `compiler/src/Compiler/MonoSolver/Store.elm`: `loadTypeC` (set slots, the per-arrow memo `arrowMemo`), `zonkSetSlot`, `resolveSlotMembers`.
- `compiler/src/Compiler/MonoSolver/Engine.elm`: `ArrowFact`, `LssSignature`, member interning, `withScratchStore`, `enqueueSpecKeyed`. `LssSignature.residual` is computed and read nowhere; it is what remains of the inclusion-constraint path.
- `compiler/src/Compiler/MonoSolver/Translate.elm`: `translateGlobalCallSlow`, `instantiateLss`, `instantiateWithSignature`, `demandUnifyRoot`, `devirtDirectTarget`, `poisonKernelArrowsThen`, `specializeCycle`.
- `compiler/src/Compiler/MonoSolver/Monomorphize.elm`: `drain`, the dirty rounds (`maxJoinRounds`) and the settle passes (`settleVarCtorRows`, `settleCtorRows`, `settleVarSuccessors`, `settleVarLambda`).
- `compiler/src/Compiler/Type/Unify.elm` (the `FunL` and `LambdaSet1` arms) and `compiler/src/Compiler/AST/TypeVars.elm` (`FlatType`, `LambdaSet`).
- `compiler/src/Compiler/AST/Monomorphized.elm`: `LambdaSetAnno` (`LTop`, `LVar`, `LSet`, `LPartial`) and `unionAnno`.
- `compiler/src/Compiler/Eco/Config.elm`: `LssConfig` (`enabled`, `maxSetSize`, `maxSpecsPerGlobal`, `stamp.maxInstances`, and the report switches `report`, `qCensus`, `arrowCensus`, `stamp.census`); `ECO_MONO_LSS*` environment overrides.

Documents:

- `design_docs/auto-borrow-inference/lambda-set-specialization.pdf`: the paper, sections 4 to 6.
- `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`: the term-by-term account of where Eco and the paper differ. Its descriptions of the slot contents, the budget of 64 and the set-size cap of 8 are stale; both caps default to unlimited, and its claim that the budget is the only terminator predates tying members to the stored demand.
- `design_docs/auto-borrow-inference/lss-why-the-fidelity-program-failed.md`: the case against hand-written transport. Its statement that arrows have no identity is stale.
- `design_docs/monomorphization/lambda-set-specialization-design.md`, `design_docs/monomorphization/solver-reuse-evaluation.md`, `design_docs/monomorphization/capture-union-representation.md`: the design reasoning.

Invariants (`design_docs/invariants.csv`): LSS_001, LSS_002, LSS_004 to LSS_006, LSS_008 to LSS_011, LSS_013 to LSS_019, LSS_022, LSS_024, LSS_025, LSS_027, LSS_031, LSS_032, LSS_034, LSS_038 to LSS_041, MONO_030. Stale rows: LSS_001 names an annotation form the code does not have (the forms are `LTop`, `LVar`, `LSet`, `LPartial`); LSS_010 describes unkeyed specs, but keying is always on; LSS_018, LSS_019, LSS_020, LSS_024, LSS_025, LSS_027 and LSS_038 to LSS_040 name switches and dates that LSS_041 makes historical, since every mechanism they describe is unconditional.
