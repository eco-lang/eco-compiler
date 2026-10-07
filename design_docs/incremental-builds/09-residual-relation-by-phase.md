# 09: What remains of the dependency relation once names are stable, phase by phase

**Status:** analysis, 2026-10-06. It builds on the catalogue in `08-dependency-relation.md` (ids
F-*, G-*, B-*) and the measurements in `exp-x*.md`.

**Questions:**
1. Assume stable naming, so every IDENTITY/order relation is gone. Which relations are left?
2. Phase by phase, which of those must actually be modelled *across units*?
3. Does requester ownership flip them favourably, or is another reframing needed?

## 1. Removing identity relations

These disappear under stable naming:
- **Front end and pre-mono:** F-2 (solver roots in `.eci`), F-12, F-13, F-17.
- **Mono:** F-23, F-29's minted ids, F-31's *ordering*, F-32, F-33, F-35, F-36, F-37.
- **GlobalOpt and codegen:** G-8, G-9, G-10, G-20, G-26, G-28's counter, G-31, G-44, G-45, G-48.
- **Back end:** B-23, B-24, B-32, and the order half of B-21 (export-late).

Two "identity" relations hide a **semantic choice**. Stable names fix *which name* is chosen,
but the choice still depends on other specs:
- **G-19 representative choice.** "First in walk order" becomes "first in stable-key order",
  which is still a global choice among instances. It is treated with AbiCloning below.
- **G-43 lambda defined by first drainer.** This becomes per-owner copies under ownership.

The remainder is about 75 semantic relations. Their classification below is the reason for this
document.

## 2. The three relation shapes that matter

Every remaining relation falls into one of three shapes:

| Shape | Meaning | Across units |
|---|---|---|
| **Down-summary** (c→C, SUMMARY) | the caller reads a small fact about the callee: type, signature, arity, CallInfo shape, budget, gc-leaf, sret availability, constant value | Free. Bottom-up and early-cut, exactly like `.eci`. |
| **Down-body** (c→C, BODY) | the caller copies or instantiates callee code: inlining, constant thunks, template bodies of generics | Allowed in import order, but early cutoff is only on a body hash. A hot generic or utility edit fans out to every consumer. |
| **Up / sideways** (C→c, symmetric, global) | the callee's result depends on its callers, or on peers | The only shape that breaks bottom-up units. Each instance needs a decision: **own it**, **contract it**, or **thin-link it** (§4). |

The "model to retain" at each phase is the cross-unit **down** edges, which are cacheable, plus
whatever residue of **up/sideways** edges survives the three treatments.

## 3. Phase by phase

### P0: Elm front end (parse, canonicalize, type-check, TOpt)

| Remains | Shape |
|---|---|
| F-1 imports-interface, F-3 type-from-interface, F-7 ctor-repr-from-union, F-8 refs | down-summary |
| F-10 port codec | down-body, generated from a type |
| F-4, F-5, F-6, F-9 | intra-module |

**Retain:** the module DAG with `.eci` summaries. This is Elm's model unchanged. Ownership is
irrelevant here.

### P1: Typed-graph load, entry prep, pre-mono

| Remains | Shape |
|---|---|
| F-15 alias-forward (target identity, transitive), F-16 eta-arity (callee arity and cost, depth 2), F-14 flags decoder | down-summary |
| F-11 merge-all-ecot | becomes "load the interfaces and template bodies this unit uses" (0.6 s whole today, X6) |

**Retain:** a per-definition summary of alias target, arity and cheapness, published with the
interface. No up edges.

### P2: Monomorphization and LSS

This is where the up edges live.

| Relation | Today | Under requester ownership by key |
|---|---|---|
| F-18 demand-enqueue, F-19 instance-type-from-demand, F-34 member-qualified-by-enclosing-key | up (caller → instance) | **Flipped:** the instance lives in the caller's unit. The cross-unit edge becomes *instance ⇐ template body* of the generic, or of the caller-shaped non-generic: **down-body**. |
| F-24 LSS join across callers, F-25 completion join | up/sideways over sharers | **Intra-unit:** under per-requester copies every sharer of a key is in one owner (X7: annotation-identical) |
| F-31 μ-tie (content-ordered) | up | intra-unit |
| F-30 number taint | sideways, order-dependent | intra-unit once scoped to the owner (X7: believed sound; output differs; 3 residual vars) |
| F-20 type-from-callee-scheme, F-21 LSS signature, F-22 arity, F-39 ctor shapes, F-40 kernel facts | down-summary | unchanged. Publish signatures in the interface: 90 % of signature reads cross owners. |
| F-38 cycle siblings | intra-module | unchanged |
| F-41 prune reachability | up (liveness) | **not flipped** for exported home-owned definitions. Reframe: emit every exported definition and let the linker strip it (Prune already has a library mode) |
| **F-26/27/28 LSS settles** (ctor rows, var cells, var lambdas) | sideways, whole-program unions | **Not flipped** (X7 counterexample). See §4.3. |

**Retain across units:**
- down-summary: signatures, schemes, arities, ctor shapes;
- down-body: the **template-body** edge from each owner to every generic or caller-shaped body it
  instantiates;
- the settles residue.

**Cost of the flip:**
- duplication (X2: +13 % with the package pool, +19.5 % without);
- every edit to a widely instantiated generic re-instantiates it in all its owners (X1 e7:
  `Prelude.head` touches 10 units).

### P3: Inline, loopify, prune

| Remains | Shape | Under ownership |
|---|---|---|
| G-1 inlines-body, G-4 loopify copy, G-41 bytes-fusion final bodies | down-body | Within a unit: free. Across units: only for home-owned definitions of lower modules, since instance callees are local copies. |
| G-2, G-5, G-6 candidacy, arity, kernel rows | down-summary | unchanged |
| G-3 SCC blocks inline | intra-SCC | intra-unit (§3 of 08: 2 cross-owner SCCs, both from G-43, which ownership removes) |
| G-11 exists-iff-reachable-after-inline | up (liveness) | same reframe as F-41: link-time stripping |

**Retain:** down-body *unfolding* edges across units. Either restrict them (X3 R1: +4.9 % if
banned), or publish small unfoldings with their hash as part of the interface.

### P4: GlobalOpt

| Remains | Shape | Under ownership |
|---|---|---|
| G-13, G-14, G-15 staging classes | sideways | scoped to the owner, which is free (X3 R2: identical binary) |
| G-12, G-16, G-17, G-18, G-19, G-21, G-22 AbiCloning (instance index, fence, representative, devirt, PAP-global) | sideways/global | **Mostly flipped.** With per-requester copies, a member's instances and its call sites sit in the same owner. Residue: a member defined in a *lower* module whose representative lives there. Treat it as a down-summary "published representative" (R3h). X3's +2.9 % was measured with *shared single* package copies, so it overstates the cost under true per-requester copies. |
| G-23 CallInfo from callee staging | down-summary | unchanged |
| G-24, G-27, G-29 (off) | sideways meets | scope to the owner |

**Retain:** the down-summary callee shape (CallInfo inputs), plus published representatives for
lower-module members.

### P5: Codegen-entry derivations and codegen

| Remains | Shape | Treatment |
|---|---|---|
| G-30 signature, G-32/33 ctor folds, G-36/39 sret/psplit admission via callees, G-47 layouts | down-summary | unchanged |
| G-34 const-thunk body | down-body | publish the folded *value* in the interface: it is a literal or closed arithmetic, so this becomes down-summary |
| G-35 sret "a let-bound site exists anywhere", G-38 psplit "a constructish argument exists anywhere" | up | **For instances:** intra-unit under ownership. **For exported home-owned definitions: contract.** Decide from the callee alone (eligible shape ⇒ always emit worker + shim) and publish availability. Cost is code size only. |
| G-46 kernel gc-leaf merge | sideways hyper-edge | pin: a function of the symbol |
| G-43 lambda first drainer | sideways | per-owner copies |

**Retain:** down-summaries (signature, sret/psplit availability, layouts, constant values).

### P6: MLIR passes in the back end (per unit)

| Remains | Shape | Treatment |
|---|---|---|
| B-28 PAPSimplify, B-29 cmp3, B-25 CAF fast path | down-summary | unchanged |
| B-26 wrapper existence ("some closure creation anywhere names X") | up | ownership for instances; **contract** for exported definitions: the owner mints a wrapper and descriptor for every exported closure-able function (hand-off plan §7.3 rule) |
| B-27 `$sat` signature set | global set | per-unit set (safe both ways), or thin-link |
| B-30 list-template protocol (callee rewrite needs *every* caller's shape) | sideways | instances: intra-unit. Exported definitions: **contract** ("never rewrite exported definitions"), or thin-link the licence. |
| B-17 veq, B-18 list chunks, B-31 init-globals set | global bits | pin as configuration; the init set becomes a link-time aggregate |

### P7: Whole-program back-end facts

| Remains | Shape | Treatment |
|---|---|---|
| B-1 reachability + internalize | up | link-time GC. Linkage under ownership is a callee-only rule: *exported iff the module exposes it* (cross-unit references only reach exposed home-owned definitions). |
| B-2, B-3, B-4 address-taken / eligibility | up | **contract**: "exported ⇒ not covered" (X3 R4: free in time; −42-58 % covered, +2 % stackmaps). Or thin-link (14 ms solve) to recover precision. |
| B-6 budgets, B-10 gc-leaf, B-12 ensure poison | down-summary (SCC fixpoints over callees) | unchanged: publish the budget, coverage and gc-leaf of exported definitions |
| B-7, B-11 (coverage ⇐ own eligibility ⇐ callers) | up via B-3 | disappears with the contract, or is computed in the thin link |

### P8: Per-body lowering

B-8, B-9, B-13, B-19 (`$cap` prepass), B-22 (-O2 inlining of gc-leaf callees): **intra-unit**, or
down-summary through declaration facts. B-14, B-15, B-20, B-21 and the partitioning artifacts are
gone with module units (X5).

## 4. Does requester ownership flip the phase relations favourably?

**Yes, for the dominant class.** The C→c edges whose callee is an *instance* get flipped:
- monomorphization demand, instance keys, LSS joins, μ-tie, taint;
- inliner SCCs;
- AbiCloning groups;
- sret/psplit gates and wrapper existence, *for instances*.

Each flips into two things:
- an **intra-unit** edge (caller ↔ its own copy of the instance);
- a **down-body** edge, *owner ⇐ template body*, which follows import order.

This is exactly how Elm's property comes back. The measured result: 1,232 cross-module SCCs
become 2, and the remaining 2 come from G-43, which ownership removes.

**No, for two classes.** Ownership cannot help where the callee is a *home-owned exported
definition*, or where the dependency is a union over a *type's* constructions. These need one of
two reframings.

### 4.1 Reframing A: the separate-compilation contract (open world per module)

- **The rule:** each module is compiled against its imports' interfaces and an **unknown** set of
  importers.
- **How it works:** every C→c question about an exported definition is answered from the
  definition alone, conservatively. The answer is *published* in the interface, and callers
  conform. That turns the up edge into a down-summary.

| Up edge | Contract | Measured cost |
|---|---|---|
| sret/psplit gates (G-35, G-38) | eligible shape ⇒ always worker + shim | code size only |
| cap eligibility (B-2/B-3) | exported ⇒ not covered | 0 % time; −42-58 % covered; +2 % stackmaps (X3 R4) |
| linkage (B-21), reachability (B-1, F-41, G-11) | exported = exposed; strip at link | unmeasured; low |
| wrapper existence (B-26) | mint for every exported closure-able definition | small |
| list-template (B-30) | never rewrite exported definitions | unmeasured; small |
| AbiCloning residue (G-17/19) | published representatives (R3h) | part of X3's +2.9 % |

### 4.2 Reframing B: a thin link of summaries (the ThinLTO pattern)

- **When to use it:** where the contract costs too much precision, keep the up edge but solve it
  *globally over per-unit summaries* in a cheap "thin link" step between the per-unit phases.
- **Analogy:** this is the ThinLTO design: per-module summaries, a global summary analysis, then
  per-module back ends that consume their slice.
- **What fits:** reachability (9 ms), cap budget and coverage (14 ms), gc-leaf (11 ms), `$sat`
  set, list-template licence, sret/psplit gates.
- **Effect on units:** each unit re-runs only if its consumed slice of the thin-link result
  changed. The thin link is a hub in the work graph, but it is cheap and cut off.
- **The incremental profile can choose per fact:** contract (simplest, some precision lost) or
  thin link (full precision, one global summary step).

### 4.3 The hard residue: LSS settles (F-26/27/28)

- **The dependency:** a constructor row's lambda set depends on *every construction site of that
  type* anywhere, including importers (X7). It is a union over a type's uses, not over a
  function's callers, so ownership does not flip it.
- **Options:**
  1. **Thin link.** Each unit publishes a *construction summary*: per constructor and type
     instantiation, the members it constructs. A global union produces the rows. Units whose
     consumed rows changed re-run. This is cheap and exact; it is option (a) of X7.
  2. **Contract (open-world rows).** A home-owned type's rows are ⊤ at module boundaries (X7
     option (b): loses 1,517 of 1,547 ctorRows writes). Settled rows are read *only* by
     AbiCloning's exact-target choice (E9.5), reports, and off-by-default passes. So the runtime
     cost may be small, but it is unmeasured.
  3. **Move the row into the key (speculative).** Make a data argument's constructor-row
     membership part of the spec key, as LSS already does for function arguments. Then an
     importer passing its own `Op` values to `Lib.run` demands a *caller-shaped* `run` that it
     owns, and Lib's home spec only ever sees Lib's own rows. This turns the settle into ordinary
     requester-owned demand, at the price of more specs and an LSS redesign.

## 5. The model to retain (after stable names and ownership by key)

**Across units, only these edges, all downward in import order:**

1. **Interface summaries per exported definition:**
   - type / scheme;
   - LSS signature;
   - alias target, arity and eta cost;
   - CallInfo shape inputs;
   - sret/psplit availability;
   - constant-thunk value;
   - ctor shapes and layouts;
   - published representatives;
   - cap budget and coverage, and gc-leaf;
   - linkage = exposed.
2. **Template bodies:** every generic (and caller-shaped non-generic) body a unit instantiates,
   cut off by body hash.
3. **Unfoldings,** if cross-module inlining is enabled: small published bodies, cut off by hash.

**Plus, per fact, either a contract (no edge) or one thin-link hub:**
- the settle rows;
- reachability and liveness;
- cap eligibility;
- the `$sat` set;
- the list-template licence;
- the sret/psplit gates for exported definitions.

**Plus pinned configuration bits:** veq, list chunks, the kernel fact table.

**This is Elm's `.eci` model with two additions:** template-body and unfolding edges (the C++
template / GHC unfolding pattern), and a small optional thin-link stage (the ThinLTO pattern).
Everything else is either intra-unit after ownership, or eliminated by stable names.

## 6. What to measure next (if this framing is adopted)

- **The cost of open-world rows** (settles → ⊤ at owner boundaries) on runtime: an X3-style
  experiment on AbiCloning E9.5 decisions.
- **X3's R3 under true per-requester copies.** The +2.9 % was measured with shared single copies
  of package instances.
- **Template-body fan-out.** For each generic, how many owners instantiate it, weighted by how
  often its source changes. That gives the expected re-instantiation cost per edit.
- **Thin-link sizes and times** on per-unit summaries, versus today's whole-module solves.
