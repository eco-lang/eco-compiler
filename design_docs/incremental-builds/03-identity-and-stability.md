# 03: Identity and stability of names

> **Measured update (2026-10-06, X1).**
> - An edit that adds a specialization renumbers 5,000-9,000 SpecIds and dirties 83-96 % of
>   today's units.
> - Even without renumbering, the `_tail_<opId>` and `mono_inline_N` counters dirty 60 modules
>   where stable names would dirty 21.
> - LSS member and closure-kind ids never reach the emitted bytecode. Local names reach text MLIR
>   but not bytecode.

## 1. The problem today

Every identity after type checking comes from a counter over the whole run, assigned in
discovery order, and most are baked into symbol names:

| Identity | Assigned by | Appears in |
|---|---|---|
| SpecId | `registry.nextId`, LIFO worklist order (`Monomorphize/Registry.elm:128-215`) | Bodies (`MonoVarGlobal _ specId _`) and names `<Module>_<name>_$_<specId>` (`Generate/MLIR/Functions.elm:532-541`) |
| LambdaId `AnonymousLambda module Int` | `lambdaCounter` for the whole run (`MonoSolver/Translate.elm:1728`); the module is the *entry* module (`Engine.elm:1340`); the inliner and `wrapTopLevelCallables` mint more from shared counters | `_lambda_<uid>` names (`Expr.elm:1386-1390`) |
| LSS member ids | Interned from string keys in first-mint order (`Engine.elm:472-480, 1810-1820`) | Spec keys |
| SrcLambdaId / ArrowId / MVarId (input) | `AssignMVarIds` threads one supply over the merged graph (`Monomorphize/AssignMVarIds.elm:224-262, 475-510`) | Member keys, and through them spec keys |
| Inliner fresh names `mono_inline_N` | `varCounter`, never reset per node (`MonoInlineSimplify.elm:2587-2617`) | Let names. They don't reach SSA names, but do shift lambda ids. |
| `_tail_<name>_<nextOpId>` | The codegen op counter (`Expr.elm:5958`) | Symbol names |
| Type ids | First use during codegen (`Context.elm:420-560`) | `eco.dbg`, `Debug.toString` constants, the type table |
| AbiCloning kind ids, `hoist_N` | Global counters | Bodies and names |

**One edit can shift every later SpecId and lambda id.** Adding a lambda in module M shifts the
SrcLambdaIds of every global that sorts after it. That moves member keys, then member ints, then
spec keys. The result is that every symbol is renamed and every unit changes.

**Within a single run everything is deterministic** (LSS_003). The problem is equivalence across
runs.

## 2. Options

### 2.1 Persistent append-only ids (the user's proposal)

> "When we add new specializations to a build, we do so with fresh ids at the end of the range,
> and never overwrite earlier ones … earlier ids that are no longer used may continue to exist …
> there could also be a late dead code removal pass … build-history dependent, so may break
> reproducibility."

**How it works.**
- Persist the creation-key → id map (the registry `mapping`) and the counters.
- On the next run, a spec whose key is already in the map gets its old id; a new key gets
  `nextId++`.
- Dead ids are tombstones. Ids are never reused.

**What has to be persisted** (from the mono audit):
- **The registry's key → SpecId map.**
  - Save the *creation key*, not `reverseMapping`'s type, which settles and joins rewrite.
  - Save it before Prune clears it (Prune's `rebuild` empties `mapping`).
- **The LSS member table, string key → int, append-only.** A spec key's MonoType contains member
  ints, so those have to be stable first.
- **SrcLambdaIds relative to their definition.** Member key strings embed the raw SrcLambdaId,
  which is a whole-program counter. Every stable chain starts here.
- **Lambda and kind counters,** per owner (§2.2) or global.

**On the "content-addressed store" concern.**
- The registry already *is* a key map: `SpecKeyMap` is a `HashMap` on structural
  `SpecKey Global MonoType`. Hashes are precomputed on construction, and hits are confirmed with
  `==`, usually a pointer hit thanks to hash-consing (`AST/Monomorphized.elm:55-70, 735-780,
  454-470`). There are no big string comparisons there.
- Two side tables (member intern `byKey`, `specWidenedKeys`) *are* string-keyed today.
- So persistent ids need the existing structural map serialized. They do not add a new string
  store. What stays in names and bodies is small ints, as the user wants.

**Dead ids.**
- SpecIds index dense arrays and BitSets (`nodes`, `reverseMapping`, `scheduled`), so tombstones
  cost space until compaction, and compaction renumbers everything, i.e. a full rebuild.
- **The binary does not have to grow.** Ids are names, not code. A dead spec is not emitted, and
  its unit is dirty anyway, because the edit that killed it changed its requester.
- Growth happens only if dead code is deliberately left in cached objects to avoid re-lowering
  them. That is a separate choice, cleaned up by a periodic "compacting" clean build or a late
  DCE.

**Reproducibility.**
- Output depends on build history. Warm ≠ cold even for identical sources.
- That conflicts with the existing G6 gate (`benchmarks/incremental-cache-check.sh`: incremental
  MLIR byte-identical to cold) and with bootstrap fixed points unless those use clean builds.
- The user's position: undesirable, but not a deal breaker. Mitigations:
  - define dev/incremental builds as non-reproducible, and use clean builds for release and
    bootstrap;
  - relax G6 to equivalence up to renaming;
  - or start cold builds from a canonical, checked-in id table, which is awkward.

### 2.2 Owner-local numbering

The user's "number lambdas within enclosing specs", generalized.

**How it works.** Every id is `(owner, local index)`:
- **owner:** a module, or an enclosing definition;
- **local index:** assigned by a deterministic walk of the owner's own content and demand
  order.

**Examples:**
- lambdas: `(enclosing spec, ordinal)`;
- local tail functions: `(enclosing spec, ordinal)`;
- inliner fresh names: per caller;
- SrcLambdaId: `(Global, ordinal)`;
- instances under requester ownership: `(owning module, ordinal in that module's demand walk)`.

**Why it works with requester ownership.**
- When the owner's source or imports change, its unit is dirty anyway, so renumbering *inside*
  it costs nothing extra.
- Nothing outside the owner refers to its local ids. Under variant A (per-requester copies, 02
  §2.1), instances are never referenced across modules.
- Cross-module references then go only to **exported source-level symbols**, identified by
  `(module, name)`, which is what Elm already uses.

**Properties.**
- **Reproducible:** warm = cold, since numbering is a pure function of the owner's inputs.
- **Stable outside the edited owner.**
- **No persistent id state.**
- G6 can stay byte-identity.

**The catch: shared instances.** Variants B and C (dominator or package pool) are referenced
across modules by id. Their ids must be stable without renumbering, which is where 2.1's
append-only ids fit naturally:
- The package pool only grows in the dev loop, so append-only ids are stable there.
- A history-dependent pool numbering affects only pool symbols. Reproducibility can be recovered
  by canonicalizing the pool on clean builds.

### 2.3 Content-derived names

Name an instance by a hash of its key (global plus canonical type arguments plus lambda-set
members).
- **Pros:** stable, reproducible, needs no persistent state. It also enables COMDAT/`linkonce_odr`
  dedup of identical copies at link.
- **Cons:** the user prefers to avoid it. It means long names or hash collisions to handle, and
  the canonicalization must be exact.
- It is still worth keeping for one narrow use: link-time dedup of per-requester copies, if the
  duplication census (07) shows a large code-size cost.

## 3. Likely combination

1. **Owner-local numbering** for everything that is owner-private: lambdas, local tails, inliner
   names, SrcLambdaIds, requester-owned instances.
2. **`(module, name)` identity** for exported source-level symbols.
3. **Append-only persisted ids** for the shared package pool only, canonicalized on clean builds.

With this combination, reproducibility is lost only inside the pool, and G6 can be kept for
everything else.

## 4. Other names that must also become order-independent

- `_tail_` names (already in the hand-off plan, Phase 2.5).
- Type ids:
  - content-hashed;
  - per-unit local type tables merged at link;
  - or a persisted append-only type registry.

  Type ids are used only by `eco.dbg` and `Debug.toString`, never in heap layouts, so per-unit
  tables are cheap.
- Kernel closure-artifact ownership (hand-off plan §7.3: "lowest-index partition that creates
  it" is usage-dependent). Use a fixed owner, such as a kernel-artifacts unit.
- The `eco/hoisted` and `eco/internal` synthetic homes (02 §7).
