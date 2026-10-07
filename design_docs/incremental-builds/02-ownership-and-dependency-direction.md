# 02: Ownership and dependency direction

> **Measured update (2026-10-06).** The experiments refine this document in three places.
> - **X7** (`exp-x7-owner-scoped-mono-soundness.md`): for *monomorphization*, requester ownership
>   does **not** keep every flow in import order.
>   - Spec keys of non-generic definitions are shaped by their callers' lambda sets: 2,379
>     home-owned specs are demanded only by other modules.
>   - The post-drain LSS *settles* union constructions across modules; a two-module
>     counterexample is measured.
>   - Ownership must be decided by spec *key*, not by definition.
>   - Settles need either a narrow whole-program step or a ⊤ fallback for owner-spanning groups.
> - **X1/X2:** variant costs measured (A +19.5 %, A+C +13.3 %, B +1.7 % code). Requester
>   ownership cuts a typical edit's blast radius to ~0.25 % of the program.
> - **X3** (`exp-x3-restriction-costs.md`): runtime cost of the §4 restrictions.

## 1. Why monomorphization and inlining break module-level incrementality

Up to type checking, a module's output depends only on its own source and its imports'
interfaces. That rule is what lets `.eci` early cutoff work.

After monomorphization and inlining, a unit of output depends on five things:

| # | Channel | What changes it |
|---|---|---|
| 1 | Its own final bodies | Its own source; every body **inlined** into it; the type definitions in its type arguments (layouts); whole-program GlobalOpt decisions about it (staging, AbiCloning/LSS, sret/psplit promotion, borrow signatures, CSE/CAF transforms) |
| 2 | Which specializations exist at all | Demand from anywhere in the program, plus reachability |
| 3 | Facts about other symbols it uses | Callee headers and ABI, cap budgets and coverage, gc-leaf, linkage, closure-artifact ownership. Several flow callee → caller transitively. |
| 4 | Global tables | SpecIds, lambda ids, LSS member ids, inliner fresh names, type ids, the type table |
| 5 | The config stamp | Any artifact-affecting flag |

Channels 3 and 4 cause most of the accidental blast radius. Channel 1 is the essential part.

**Two directions of information flow:**
- **Callee → caller.** A caller's output depends on facts about its callees. Across modules this
  follows import order, because a caller can only name what it imports. This is harmless for
  incrementality: compute bottom-up, publish in an interface, and use early cutoff.
- **Caller → callee.** A callee's output depends on its callers or uses. Across modules this
  flows *against* import order: a module's output would depend on its importers. That breaks the
  bottom-up property. Combined with the callee → caller flow, it lets dependency cycles span
  modules.

**Symmetric/global** flows include equality-based merging, pooling, and counters in discovery
order. They act like both directions at once.

## 2. Requester ownership: the user's insight

> "Specialized functions effectively get pulled up into the callers' module … this means that the
> callee → caller flow gets brought within the owning module … if carried out completely, it
> leaves only the normal caller → callee flow, which cannot create SCCs that cross module
> boundaries, because circular imports among modules are not allowed."

**The rule.** A specialization belongs to the module that requests it:
- a generic instance such as `List.map @ (MyType -> Int)`;
- an LSS instance keyed by a lambda set.

When an owned instance requests further instances (`List.map@T` → `List.foldr@T`), those are
owned by the same root requester.

**Why it is sound as a dependency discipline.** The requester R transitively imports every module
the instance depends on:
- **The generic's module.** R names it directly, or the request comes from an instance R already
  owns, whose generic module R reaches transitively.
- **Every type constructor in the type arguments.** A value of type `T` can only reach R through
  the interfaces of modules R transitively imports.
- **Lambdas in an LSS key.** A lambda R passes down is R's own, or came to R through an import.
  Lambdas that cross kernel, port, effect-manager or `Debug` boundaries are widened to ⊤ (LSS_004)
  and never enter keys.

So every dependency of an owned instance points down the import DAG. Two consequences:
- **No cross-module SCCs.** Call cycles between specs cannot span modules. Source-level cycles
  live inside one module, and a transitively requested instance joins its requester.
- **Fixpoints stay local.** Every callee-first SCC fixpoint becomes a per-module computation over
  facts imported from below: inliner recursion detection, Borrow signatures, the sret greatest
  fixpoint, cap budgets, gc-leaf.

**This reframes the problem.** The back-end facts behave like type-check facts. A module's
"back-end interface" (§5) can be cached and early-cut exactly like `.eci`.

**The audit (§3) confirms the core composes bottom-up today:**
- monomorphization with keyed LSS;
- the inliner's decisions;
- CallInfo, MonoReturnArity, Borrow signatures, CSE purity;
- ConstThunks and the null-cons maps;
- gc-leaf and cap budgets.

### 2.1 Placement variants

| Variant | Rule | Pros | Cons |
|---|---|---|---|
| **A. Per-requester copies** (the C++ template model) | Every requesting module owns its own copy | Perfect isolation; no cross-module numeric ids (03); instance bodies depend only on R's import closure | Duplication: `List.map@Int` exists once per requesting module. Code size and compile time scale with fan-in. A generic CAF whose body has a `Debug.log` logs once per copy (observable only through Debug). |
| **B. Dominator ownership** | If one module in {generic's module, type-arg homes, LSS member homes} transitively imports all the others, it owns the instance and requesters share it. Otherwise, fall back to A. | Shares common cases (e.g. `Dict.get@A.Key` when A imports Dict); still preserves import order | Shared instances are referenced across modules by id (03). The owner's unit changes whenever a *new* requester appears anywhere, which is churn. |
| **C. Package pool** | Instances whose keys mention only package types and package lambdas (`List.map@Int`) go to a shared, append-only pool. User-typed instances use A or B. | Packages don't change in the dev loop, so the pool only ever grows (§03 append-only ids fit here). Removes most duplication. | The pool gains entries whenever any module needs a new package-typed instance. New entries need their own small units so the existing objects stay valid (06). |

An earlier suggestion was "home = the module defining the type arguments". It is a variant of B,
but it violates import order whenever the type module doesn't import the generic's module (for
example `Dict.get@A.T` where A doesn't import Dict). Only the dominator form is safe.

**Likely shape: A for user-typed instances, C for package-typed ones.** It needs a census of
fan-in and duplication (07).

## 3. Flow audit of every pass after type checking

The audit was read-only, against defaults (`Compiler/Eco/Config.elm:517-556`). Paths are under
`compiler/src/Compiler/`.

| Pass | Flow | Evidence and notes |
|---|---|---|
| Mono discovery (solver engine) | demand: caller → callee | Worklist from `main` and the flags decoder (`MonoSolver/Monomorphize.elm:103-160, 4039-4113`). Each item gets a fresh solver store (`Engine.elm:2506`). |
| LSS signatures (`LssInfer`) | callee → caller | Demand-lazy, SCC-granular summaries (`LssInfer.elm:22-30, 81-110`) |
| LSS demands into callee keys | caller → callee, but **keyed** | Argument lambda sets ride in the demanded type and become part of the callee's spec key (`Engine.elm:2316-2360`; unlimited budget by default, `Config.elm:335-344`). Under requester ownership the keyed instance is the requester's, so this is fine. |
| LSS shared-key join (LSS_010) | **caller → callee** | When demands collide on one key, the stored type is the join over all callers. If it changed, the spec is re-translated (`Registry.elm:180-200`, `Engine.elm:2283`). Dormant on the self-compile (`rounds=0`, `benchmarks/lss-opt.md:1356`), but required for soundness. Reactivated by any non-zero `maxSpecsPerGlobal`. |
| Post-drain ctor-row settles | **global** | Need the complete union over sibling specs (`Monomorphize.elm:150-190, 330-345`) |
| Number-taint `superTable` | **global, order-dependent** | Harvested per item and read during zonk of later items (`Monomorphize.elm:4249`, `Store.elm:2895-2901`). It only grows. |
| MonoInlineSimplify decisions | callee → caller | Candidacy and cost come from the callee's body (`MonoInlineSimplify.elm:2456`); recursion from SCCs (`:1104-1245`); budget per caller (`:4818`) |
| Inliner arity-raise gate (off by default) | caller → callee | A program-wide census of call sites (`:618, 846-847`) |
| Inliner naming | **global counter** | `varCounter`/`lambdaCounter` are never reset per node (`:2587-2588`) |
| `Prune.pruneAfterInline` | demand | Reachable from `main` (`Prune.elm:48-91`). A library mode keeps everything (`:52-67`). |
| `wrapTopLevelCallables` | local, **global counter** | Lambda ids come from the shared counter, homed at the generic's module (`MonoGlobalOptimize.elm:59-63, 204-216`) |
| **Staging solver** | **global/symmetric** | Union-find slot keys are structural and program-wide: a record slot is keyed by field names, a tuple slot by arity (`Staging/GraphBuilder.elm:301, 611, 625`). Each class is decided by majority vote (`Staging/Solver.elm:170-214`); minority producers are eta-wrapped (`Staging/Rewriter.elm:180-225`). Call arguments are *not* unified with callee parameters (`GraphBuilder.elm:279-287`), so a function's own staging is its own. Only lambdas stored in data or joined at if/case results get pooled. |
| **AbiCloning** (LSS stamps, fastEvaluator, post-settle devirt) | **global/symmetric**; can name a symbol against import order | One member → instances index over all nodes (`AbiCloning.elm:300-318`). A member is blocked if *any* instance anywhere is a staging wrapper (`:209-216`). The representative is first in node-walk order (`:235`), and the stamp names that instance's symbol (`:1432`). Devirtualization needs uniqueness over all specs of the target (`:3077-3116`). Kind ids come from a global counter (`:2636-2649`). |
| annotateCallStaging (CallInfo) | callee → caller | Reads the callee's arity and stage arities (`MonoGlobalOptimize.elm:1479-1560, 2013`) |
| MonoReturnArity | type-local | — |
| Borrow (off by default) | callee → caller; member signatures **global** | Reverse-topological SCC fixpoint over bodies (`Borrow.elm:288`). A lambda member's signature is the meet over all instances program-wide (`:223-246`). |
| MonoCse (off by default) | local + callee → caller purity | `CsePurity.elm:22-33` |
| CafDedupe (off by default) | **global/symmetric** | Program-wide structural equality; the canonical copy is the smallest SpecId (`CafDedupe.elm:32`) |
| CafHoist (off by default) | **global** sharing, counter, budget | `CafHoist.elm:52, 62, 64, 285` |
| MapTemplate (off by default) | callee → caller; member meets **global** | `MapTemplate.elm:765-794, 1280-1327` |
| sret promotion | **caller → callee** gate, then callee → caller fixpoint | Rule (c): "a let-bound direct call site exists somewhere in the graph" (`Generate/MLIR/Backend.elm:478-486, 540-556`) |
| psplit promotion | **caller → callee** gate | "≥ 1 direct call site somewhere passes a constructish argument" (`Backend.elm:953-963, 1093-1113`) |
| ConstThunks | callee → caller | Like an exposed unfolding (`ConstThunks.elm:65-140`) |
| null-cons / const-ctor maps | local | — |
| Kernel declaration gc-leaf | **global** | OR-merged across call sites (`Context.elm:784-822`). Fixed by making it a function of the symbol (hand-off plan, Phase 2.6). |
| Back-end reachability | demand | — |
| Cap-hoist eligibility | **caller → callee** | Not address-taken, and local (`EcoCapHoistPlan.cpp:225-231`) |
| Cap budgets, gc-leaf | callee → caller | Inherit caller → callee through coverage (5,073 of 8,558 stamps) |
| Linkage | **caller → callee** | Export iff referenced from another unit |
| Symbol names | **global counters** | `<Module>_<name>_$_<specId>`, `<home>_lambda_<uid>` (`Generate/MLIR/Expr.elm:306-316, 1386-1389`) |

## 4. Flows against import order, and how an incremental profile bounds them

The user accepts reduced optimization in incremental builds. Each restriction below is an
ordinary separate-compilation rule. Release builds would stay whole-program.

1. **Staging pooling.** Scope slot classes to the owning module. Or drop the vote for slots whose
   values cross a module boundary and keep each producer's natural staging. Consumers of values
   taken from data structures already lower as generic or unknown-segmentation calls.
   *Cost: low. It also produces fewer staging wrappers, which means fewer AbiCloning blocks.*
2. **AbiCloning's global index.**
   - Restrict the index to the owner's instances plus instances published in the member's home
     module's interface.
   - Choose representatives only from those, never "first in walk order" across the program.
   - Blocked status and devirtualization uniqueness are checked against what the requester can
     see.
   - Kind ids become per-module.

   *Cost: moderate and measurable. Fast dispatch is lost at sites whose only verbatim instance
   lives in an unrelated module.*
3. **sret/psplit site gates.** Decide promotion of *exported* specs from the callee alone: if the
   shape is eligible, always emit the worker plus shim, and publish worker availability in the
   interface. Module-local specs keep the "a site exists in this module" gate.
   *Cost: code size only; unused shims are dead-stripped.*
4. **Cap-hoist coverage and linkage.**
   - An exported symbol has unknown external callers, so it is not eligible for coverage. That is
     the existing `cw=0` rule: eligibility requires internal linkage.
   - Linkage is Export for exposed symbols and symbols reachable from an exposed unfolding,
     Internal otherwise.
   - *Recovery:* give an exported function a covered internal body plus an uncovered export
     thunk, a separate entry for address-taking. Cross-module callers use the covered entry when
     the interface publishes its budget.

   *Cost: binary and stackmap size, and some gc-leaf stamps. Not wall time: hoisting is flat on
   wall time.*
5. **LSS shared-key joins, settles and taints.** Under requester ownership, every sibling spec
   sharing a key lives in one owner, so the join and the settles become intra-module. The
   `superTable` must be owner-scoped. Keep `maxSpecsPerGlobal = 0`, or scope joins to the owner.
6. **CafDedupe, CafHoist, Borrow and MapTemplate member meets.**
   - Scope them to the module: per-module budgets, owner-qualified `hoist_N`, and meets over the
     instances the owner can see.
   - Cross-module CAF sharing, if it is wanted at all, moves to the linker through content-named
     `linkonce_odr` symbols.

   *Most are off by default, so there is no cost against today's defaults.*
7. **Arity-raise census.** Owner sites only; exported specs are never raised.
8. **Kernel gc-leaf.** A function of the symbol (hand-off plan Phase 2.6). The cross-module
   CGEN_038 ABI check becomes a link-time check.
9. **Global numbering.** See 03. This is the real blocker: until names stop changing, nothing can
   be cached.

## 5. Inlining across modules

Inlining is the one callee → caller flow that carries a *body*, not a summary. If D inlines C's
exported `f`, D's output depends on C's optimized body. It also references C's private helpers,
which must then be exported. This is GHC's "exposed unfolding" rule.

| Option | Effect |
|---|---|
| **Exposed unfoldings in the interface** | C's back-end interface publishes the bodies of inlinable exported functions. D's cache key includes their hashes. A change to an inlinable body cascades to importers. |
| **Package-only cross-module inlining** (the incremental profile) | Inline freely within a module. Across modules, inline only from packages, which don't change in the dev loop. Cross-module coupling then reduces to signatures, the same shape `.eci` already handles. The user accepts the loss. |
| **Provenance recording** | Each spec records the source definitions inlined into it, with hashes. This gives exact invalidation and is useful for diagnostics and the blast-radius study (07). |

## 6. The back-end interface

Requester ownership plus §4 makes every cross-module dependency a summary of something lower in
the DAG. Those summaries form a per-module *back-end interface*, the analogue of `.eci` for code
generation. For each exported symbol it records:
- name (module + source name; see 03) and function type;
- staging/ABI, sret/psplit worker availability, borrow signature;
- LSS signature;
- gc-leaf and cap fact (budget of the covered entry, if published);
- closure-artifact ownership;
- the exposed unfolding's hash, if cross-module inlining is enabled.

**Early cutoff works the same way as for `.eci`.** When a module rebuilds and its back-end
interface is unchanged, importers' units stay clean even if the module's bodies changed. Most
edits change bodies, not these summaries, so most edits stay inside the edited module's own
units, plus the requester-owned instances whose inputs changed.

## 7. Where the idea fails or needs care

- **Synthetic homes.** These need rehoming to the owner:
  - accessors belong to no module (`AST/Monomorphized.elm:2931-2933`);
  - staging wrappers live in `eco/internal`;
  - hoisted CAFs in `eco/hoisted`;
  - lambda ids are minted under the entry module or the generic's home.
- **Ports and flags** are a program-level aggregate collected at link (`__eco_register_ports`),
  owned by `main`'s module.
- **Kernel code** is outside the module graph but reaches the compiler only through static
  tables (`KernelFacts`, `KernelSigs`). It is a fixed leaf.
- **Cross-module inlining** (§5).
- **The duplication cost** of variant A is unmeasured (07).
- **Release builds keep whole-program optimization.** Release and incremental builds then produce
  different code. That is acceptable, but it means two configurations to test.
