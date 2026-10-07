# 04: Incremental monomorphization

> **Measured update (2026-10-06, X7: `exp-x7-owner-scoped-mono-soundness.md`).** §4's per-owner
> mono is sound only with changes:
> - ownership by key;
> - settles handled by a whole-program step, or by a ⊤ fallback that loses 98 % of ctorRows
>   writes;
> - `superTable` scoped to the owner (output differs);
> - μ-tie by content order;
> - LSS signatures published in interfaces (90 % of signature reads cross owners).
>
> The §5 question "can the settles be scoped per owner?" is answered **no, not as proposed**.

> User: "Monomorphization is currently demand driven, as is our LSS analysis. This means that we
> can demand a fresh pass for only what changes. Correct?"

**Answer: partly.**
- Discovery is demand-driven, and each specialization is translated with a fresh solver store.
- But being demand-driven means *compute only what is reachable from `main`*. It does not mean a
  spec's output is a pure function of (its definition, the requested type). Three things stand in
  the way:
  1. cross-spec state;
  2. LSS flowing in both directions;
  3. whole-run identities (03).

## 1. What already fits

- **Demand-driven discovery.** The solver engine is the default (`Compiler/Eco/Config.elm:542`).
  It seeds `main` and the flags decoder (`MonoSolver/Monomorphize.elm:103-160`) and drains a LIFO
  worklist (`Engine.elm:2197-2214`, `Monomorphize.elm:4039-4113`).
- **Per-item isolation.** `resetItem` gives every work item a fresh store, memo and var env
  (`Engine.elm:2506`). The HM/union-find state does not leak between specs.
- **An existing re-translation loop.** The engine already re-translates dirty specs and iterates
  to a fixpoint (the LSS_010 flush rounds, `Monomorphize.elm:4039-4113`, capped at 100 rounds).
  An incremental mono would be *this engine restarted from persisted state, with changed specs
  seeded dirty*.
- **LSS signatures are callee → caller, per SCC and lazy** (`LssInfer.elm:22-30, 81-110, 388`).
  To invalidate: recompute the changed SCC, then propagate up the reverse call graph until the
  signature stops changing. This is early cutoff in miniature.

## 2. What blocks reuse across runs

| Blocker | Evidence | Under requester ownership (02) |
|---|---|---|
| Ids are whole-run counters, and member ints are interned in first-mint order | 03 §1 | Owner-local numbering (03 §2.2) |
| `superTable` number taint: harvested per item, read by later items, order-dependent, only grows | `Monomorphize.elm:4249`, `Store.elm:2895-2901` | Must be owner-scoped. Needs a careful soundness argument (LSS/number-taint docs). |
| LSS shared-key join: the stored type is the join over all callers' demands. A changed join marks the spec dirty. | `Registry.elm:180-200`, `Engine.elm:2283`. Dormant on the self-compile, required for soundness. | All sharers of a key are in one owner, so the join is intra-module |
| Post-drain settles (ctor rows, var successors, var lambda) need the complete union over sibling specs; a partial union is "the false-singleton miscompile class" | `Monomorphize.elm:150-190, 330-345` | Re-run per owner over the owner's specs, *if* siblings never span owners. Must be verified, because ctor-row settles may group by ctor global, not by owner. |
| Monotone-only tables: joins, taints, `muTied`, members never shrink | Mono audit | See §3 |
| μ-tie / `demandQualified` read ids other specs minted earlier | `Engine.elm:478, 960`; `Monomorphize.elm:4450` | Owner-scoped |
| Input ids (SrcLambdaId, ArrowId, MVarId) assigned over the merged whole-program graph | `AssignMVarIds.elm:224-262` | Must become relative to their definition |
| AliasForward makes a caller's body depend on whether its callee is an alias | `GlobalOpt/PreMono/AliasForward.elm` (on by default) | Callee → caller; fine across modules, needs a dependency edge |
| Downstream: the inliner's global counters, Prune, AbiCloning's whole-graph index | 02 §3 | 02 §4 restrictions |

## 3. Removing demand

When a caller is deleted or narrowed, its demand disappears.
- **Liveness is cheap:** reachability over the persisted call edges (`Prune.reachableFromMain`,
  `Prune.elm:48`).
- **Contributions are hard to retract.** A dead or narrowed caller's contributions to joins,
  settles, taints and μ-ties have to be removed, and the current structures only grow. A warm
  build without retraction is sound but *more widened* than a cold build, so it is not
  byte-equal.

Options:
1. **Persist contributions per caller edge.** Recompute the join over *live* demands.
2. **Recompute per owner.** Under requester ownership, re-monomorphize the dirty owner module's
   whole demand set from scratch. Every caller whose demand reaches an owned instance is in the
   same owner, so retraction becomes "re-run the module". This is the simplest option, and it is
   exactly why requester ownership helps.
3. **Accept warm over-widening,** with a clean build to reset. This is history-dependent output,
   as in 03 §2.1.

## 4. Shape of per-module incremental mono under requester ownership

**Inputs for owner module M:**
- M's own TOpt bodies;
- the bodies of the generics M instantiates (from imported modules' `.ecot`, the way C++
  templates need bodies in headers);
- imported modules' published LSS signatures and back-end interfaces (02 §6);
- M's own exposed demands.

**Process:**
1. Seed the worklist with M's top-level definitions that are live, plus the instances M
   requests.
2. Drain with owner-scoped tables.
3. Settle per owner.

**Outputs:**
- M's instances, numbered owner-locally;
- M's LSS signatures and back-end interface, with early cutoff.

**Invalidation of M happens when:**
- M's source changes;
- an imported interface M consumed changes (signature, layout, LSS signature, exposed
  unfolding);
- a generic body M instantiates changes. This needs a dependency edge from M to that generic's
  source hash.

**Liveness:** program-level reachability from `main` across modules' exported symbols. Dead
exported symbols can be kept and stripped at link (`--gc-sections`), which is the library mode
that `Prune` already has.

## 5. Open soundness questions

- Can the ctor-row and var-lambda settles really be scoped to an owner? Their documented reason
  is completeness of a union over *sibling specs of one ctor global*. Siblings in other owners
  would then be computed separately. Is that sound (each owner sees a complete union over *its*
  copies), or do layouts have to agree across copies of one ctor?
  - The hazard is code that passes a value between two owners' copies of the same instance.
  - Under variant A this shouldn't happen, because values cross modules only through exported
    functions at exported types.
  - This needs a proof sketch.
- Can number taint (`superTable`) be scoped to an owner without changing the defaulting of
  numeric type variables visibly across modules?
- Do LSS widening and ⊤ provenance behave identically when computed per owner?
