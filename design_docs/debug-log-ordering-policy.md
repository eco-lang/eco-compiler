# Debug/⊥ observable-ordering policy for Elm-level optimizations

**Scope.** Binds every pass that deletes, duplicates, merges, or moves an Elm-level
expression: Mono DCE (kernel-opt-11), Mono CSE (kernel-opt-13), `CafHoist`, `CafDedupe`,
bytes/cons fusion, and the inliner's beta/forward rewrites.

**Fact the policy rests on.** On the **MLIR/native path `--optimize` does not remove
`Debug.*`**: `checkForDebugUses` (`Builder/Generate.elm:259-266`) runs only under the
JS `prod` entry (:188-198, reached from `Terminal/Make.elm:654`); the native path
(`Terminal/Make.elm:336/349/411/425` → `Generate.buildMonoGraph:687`) never calls it.
`Debug.log` lowers to an `eco.dbg` op (`Generate/MLIR/Expr.elm:3921`) →
`eco_dbg_print_typed` (`runtime/src/allocator/RuntimeExports.cpp:3411-3426`), which
writes `label: value\n` into the captured program output stream, interleaved with
ordinary output. The `std::cout` comment at `elm-kernel-cpp/src/core/Debug.cpp:47-48`
claims the opposite; its function has no callers and is dead.

**D-1 (no deletion).** An expression that transitively contains a `Debug.*` kernel
reference is never droppable, whatever the KernelFacts row says. `(Debug, log)` carries
`callTimeEffect = EffObservableIO` ⇒ `cseSafe = False` ⇒ `droppable = False`, and the
arg-purity recursion propagates it; the rule is nonetheless **normative** — a future
pass must re-establish it, not inherit it by luck.

**D-2 (no merge).** Two occurrences of an expression that transitively logs are never
CSE-merged: the number of emitted lines is observable output. **The merge licence is
refused, not deferred by accident** — kernel-opt-13 asked whether `--optimize` should
license merging two evaluations of a pure-but-logging expression; the answer in v1 is
NO. Granting it later is a deliberate amendment to THIS file, and the size of what it
would unlock is already measured: kernel-opt-13's `debugExcluded` census counter.

**D-3 (motion).** A logging expression may not be hoisted out of a conditional, nor into
or out of a loop body — both change the number of emitted lines, which is observable
output regardless of ordering. It may move within a straight-line region if it crosses no
other logging or ⊥-capable expression. `CafHoist` already implements the strictest form
(`hasDebug` ⇒ ineligible, `CafHoist.elm:392-393` set, `:347` consumed) and keeps it.

**D-3 does NOT claim that source order is preserved in general, because it is not.**
Measured 2026-08-12 on the native path, for

```elm
let n1 = Debug.log "n1" 1
    _  = Debug.log "w1" 2
    n2 = Debug.log "n2" 3
    _  = Debug.log "w2" n2
in  …
```

the emitted order is **`n2, n1, w1, w2`**: *named* `let` bindings run before wildcard
(`_ =`) statements, and are not in source order among themselves. A sequence of wildcard
statements alone **is** order-preserving — which is why all 558 `test/elm/src` fixtures,
which log almost exclusively through `_ = Debug.log …`, are unaffected. Elm does not
specify evaluation order within a `let` binding group, so this is unspecified-but-
observable behaviour, not a defect to fix under this policy.

The rule a pass must follow is therefore **do not make it worse**: never introduce
reordering into a region that is ordered today (the wildcard statement sequence), and
never move a logging expression across a conditional or loop boundary. Do not read the
existing looseness as a licence to reorder freely.

**D-4 (⊥ selection).** Under `--optimize`, when two occurrences would both crash or
diverge, an optimizer may keep either; the crash **message** may therefore change.
E2E assertions on crash text must not depend on which occurrence produced it. This is
the latitude kernel-opt-13 records for its C4 widening; C2/v1 does not use it, and
kernel-opt-11's `droppable` (which requires `totality == Total`) cannot use it at all.

**D-5 (no `--optimize` latitude).** No pass may assume `Debug` is absent because
`--optimize` was passed. Acquiring that latitude requires first making the native path
run `checkForDebugUses` — a separate, deliberate change with its own gates.

**Pinned by** two fixtures, both run in both `ECO_KERNEL_FACTS_DCE` flavors, and by
invariant `OPT_DEBUG_ORDER_001`:
`test/elm/src/DebugLogNoDropTest.elm` pins **D-1** — a dead named binding whose bound
expression is a droppable kernel call applied to a logging argument must keep its line;
`test/elm/src/DebugLogOrderingTest.elm` pins **D-3** over a wildcard statement sequence,
which is the part of ordering the compiler actually guarantees. They are separate files
on purpose: a single fixture mixing named and wildcard bindings would bake the
unspecified named-vs-wildcard ordering above into a gate, and would fail on a change that
violates no rule in this document.
**D-2 is not pinnable until a merging pass exists**: nothing in
the pipeline merges Elm-level expressions today, so its fixture is owed by kernel-opt-13
C2 and must land with it. D-4/D-5 are normative statements with no fixture; D-5's
falsifier is the day someone makes the native path call `checkForDebugUses`.
