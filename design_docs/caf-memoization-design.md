# CAF Memoization via the `eco.global` Mechanism

Status: DESIGN (2026-07-22). No implementation yet.
Evidence base: the CAF survey + current-behavior deep dive in
`/work/caf-survey.md` (Jul 22 2026; summary restated in §1 so this doc is
self-contained if that report disappears).

---

## 1. Problem and evidence

A CAF (constant applicative form) is a top-level definition with zero
parameters. The compiler's own source has **959** of them (~16% of all
top-level defs), of which **470 are computed values** — `Bytes.Decode`
decoder graphs (~215, the artifact `.dat` format decoders), parser
combinator atoms (~40), error-doc structures (~40), keyword/kernel lookup
tables (`Dict.fromList`, `EverySet.fromList`), and arbitrary `let`/`if`
bodies. Dependency packages add more on top (the survey counted only
first-party source).

The native backend **re-executes every CAF's RHS at every dynamic
reference**:

- A non-closure `MonoDefine` compiles to a nullary thunk `func.func`
  (`Compiler/Generate/MLIR/Functions.elm:414`, `generateDefine`).
- Every reference (`MonoVarGlobal` with an arity-0 signature) emits a direct
  `eco.call` of that thunk (`Compiler/Generate/MLIR/Expr.elm:580`,
  `generateVarGlobal`).
- Nothing recovers this downstream: bare value references are explicitly
  left alone by the GlobalOpt inliner (`MonoInlineSimplify.elm:2650`; only
  call-position references are inlined, `:2446`), there is no mono-level
  CSE, and LLVM cannot CSE/hoist statepointed calls with allocation side
  effects.

So every `Set.member kw keywords` rebuilds the keyword set; every artifact
decode rebuilds its decoder graph. Only leaf string literals
(`internLiteral`, `RuntimeExports.cpp:515`), zero-capture closures
(`eco_intern_closure0`, HEAP_033), and the embedded constants
(True/False/merged-Empty) are cached; all structure above them is freshly
allocated per reference.

The JS backend, by contrast, emits `var $home$name = expr;` once at load
(`Generate/JavaScript.elm:397`) — the bootstrap compiler already has full
CAF memoization. The native backend is the outlier.

## 2. Goal

Evaluate each qualifying nullary thunk **at most once per process**, cache
the result in a GC-rooted module-level slot, and return the cached value on
every subsequent call — using the dialect's existing `eco.global` machinery
(`Ops.td:1571`: `eco.global` / `eco.load_global` / `eco.store_global`,
lowered in `EcoToLLVMGlobals.cpp`, rooted via `__eco_init_globals`).
Reference sites do not change.

**Non-goals (v1):** caller-side fast paths (elide the thunk call at
reference sites), scalar-ABI CAFs, nullary-constructor interning, eager
init at startup, permanent-space promotion of memoized values. All listed
in §12 as follow-ups.

## 3. Semantics

Elm is pure, so once-evaluation is observationally equivalent to
per-reference evaluation except for:

- **`Debug.log` in a CAF body** — prints once instead of per reference.
  This *converges* with the JS backend (which already evaluates once).
- **⊥ (crash / non-termination) timing** — moves from "every use" to
  "first use". Lazy first-use init (DS4) means a never-referenced CAF
  containing `Debug.todo` still never crashes — strictly no worse than
  today, and *safer* than the JS backend's eager load-time evaluation.

This is the same observability argument already accepted for
`raiseStagedSpecs` (`MonoInlineSimplify.elm:657`).

**RESOLVED (Jul 23 2026): the effect-type exclusion below is REMOVED** —
`plans/task-purity-and-caf-guard-removal.md` fixed both impurities at the
source (MVar/spawn/kill defer their effects to fulfilment per
KERNEL_TASK_IO_001 with no partial-eager exemptions; the scheduler's
kill-handle install copies instead of mutating, so Task nodes are
immutable). `monoTypeHasEffects` is deleted; Task/Cmd/Sub CAFs memoize like
any other value, pinned by `MVarSharedNewTaskTest`. The section below is
kept as the historical record of why the guard existed.

**EXCEPTION (found during implementation, Jul 22 2026): platform effect
types are NOT pure data in the native runtime and must be excluded.** Two
independent native-runtime realities break the "Task values are pure
descriptions" assumption this section originally made:

1. The scheduler mutates Task heap nodes in place — the Task\_Binding
   kill-handle install (`Scheduler.cpp:853` "tasks are one-shot").
2. Native kernel task VALUES can be **eager**: `Eco_Kernel_MVar_new()`
   performs the effect at value-evaluation time and returns
   `Task_Succeed id` (`MVarExports.cpp:13`; the standing
   `plans/defer-eager-kernel-tasks-via-binding.md` tracks this class).
   The per-reference thunk call was **load-bearing** for these: caching
   one instance made a second `MVar.new` return the first (dropped) id —
   caught by `MVarDropReleasesSlotTest` (1632/1633 on the first flag-on
   E2E run; the only failure).

Consequence: `cafMemoQualifies` also requires `not (monoTypeHasEffects
monoType)` — a recursive walk excluding `Platform.Task` / `ProcessId` /
`Router` / `Program`, `Platform.Cmd.Cmd`, `Platform.Sub.Sub` in the result
type, through containers and custom-type instantiation args, with
`MFunction` as a barrier (task-*returning* functions are safe: the task is
constructed per application). Residual accepted risk: a monomorphic user
custom whose FIELD hard-codes an effect type is invisible in instantiation
args (needs ctor-shape expansion) — gated by the E2E corpus + self-compile.
If `defer-eager-kernel-tasks-via-binding` ever lands AND the scheduler's
in-place task mutation is removed, this exclusion can be revisited.

Elm rejects top-level value cycles (cycles must be all-functions), so lazy
initialization cannot self-deadlock. Genuine dynamic re-entry through a
lambda (`Decode.lazy`-style knots that actually force themselves) diverges
today and still diverges; a benign re-entry (inner call completes first)
just publishes twice — last-write-wins on structurally equal pure values is
sound. **No init-in-progress flag is needed.**

## 4. Design decisions

**DS1 — Slot granularity: one slot per emitted arity-0 thunk symbol (per
SpecId), never shared across specs.** Monomorphization splits one source
CAF into several specialized thunks (one per demanded type; more under LSS
keying — keyed routing duplicates the global spec per key). Different
specializations have different layouts/representations, so cross-spec
sharing is unsound even when the source text is identical. The thunk's
`funcName` already embeds the SpecId (`Module_name_$_<specId>`) and is
unique post-GlobalOpt/post-cloning, so keying the slot on the emitted
symbol gets DS1 by construction. (Proposed FORBID invariant, §9.)

**DS2 — Callee-side guard.** The load/check/store lives inside the thunk;
reference sites keep emitting a plain `eco.call`. One change point, works
uniformly for every reference shape, and keeps the slot referenced *only by
its own thunk* — which makes partition splitting trivially safe (§5.5). A
hit costs call + load + compare + return (~ns) vs the recompute it replaces
(µs–ms for decoder graphs). Caller-side fast paths are a measured follow-up.

**DS3 — Elm backend emits `eco.global` + a marker attr; the guard is
synthesized in C++ during EcoToLLVM finalization.** Elm side:
`generateNodeInner`'s `MonoDefine` arm (Functions.elm:316) emits a
module-level `eco.global @__eco_caf$<funcName>` next to the thunk and
stamps the thunk's `func.func` with a unit attr `eco.caf_memo` naming the
slot — the exact `eco.shadow_roots` precedent (consumed at
`EcoToLLVM.cpp:198`). C++ side: a finalization step in the EcoToLLVM pass
(alongside the shadow-roots step, **before** `createGlobalRootInitFunction`
at `EcoToLLVM.cpp:527`) rewrites each tagged function (§5.2). Rationale
against a pure-MLIR guard built from `eco.load_global` + branching: the
dialect has no is-null test op, and thunk bodies come in two shapes (single
`eco.return` vs `isTerminated` bodies with returns inside `eco.case`
regions, Functions.elm:431) — post-conversion all returns are uniform
`llvm.return`s, so LLVM-dialect surgery handles every shape with no new
ops and no Elm-side control-flow plumbing.

**DS4 — Lazy first-use initialization.** No eager evaluation from
`__eco_init_globals` (it stays a pure root-registration function). Zero
startup cost, no topological ordering machinery, dead CAFs never run, ⊥
semantics preserved (§3).

**DS5 — v1 scope: `!eco.value`-ABI thunks only; slot value `0` means
"uninitialized".** `monoTypeToAbi` returns exactly `!eco.value | i64 (Int)
| f64 (Float) | i16 (Char)` (Types.elm:158; Bool is `!eco.value` at ABI).
No valid `!eco.value` word is 0: heap pointers are nonzero addresses and
the embedded constants are 0x4/0x5/0x6 (`Heap.hpp:310`). Scalar-ABI thunks
are excluded in v1 — they are almost all trivial literals, and memoizing
them needs a separate initialized-flag global **and must not root the
slot**: `createGlobalRootInitFunction` walks *internal i64 LLVM globals*
(`EcoToLLVMGlobals.cpp:471`) and the JIT-root scan would misinterpret a raw
Int (e.g. 42 → ptr_ind 0 → "heap pointer at address 40") as a traceable
pointer. This hazard is recorded as part of HEAP_035 (§9) so a future v2
cannot trip it.

**DS6 — Rooting rides the existing `eco.global` machinery unchanged.**
Slots become internal i64 LLVM globals initialized to 0; the existing
`createGlobalRootInitFunction` walk picks them up and `__eco_init_globals`
registers each via `eco_gc_add_root` → `RootSet::addJitRoot`
(`RuntimeExports.cpp:3780`, a `std::unordered_set` — idempotent). All GC
legs are already correct for these slots (verified for this design):

- **Minor GC** evacuates JIT-root slots *in place* — `evacuateJitPtr(*root,…)`
  (`NurserySpace.cpp:638`), so a nursery-allocated memoized value is moved
  and the slot rewritten.
- **Major GC** marks through them, skipping embedded constants and null /
  non-heap words (`OldGenSpace.cpp:1576`).
- **Old-gen compaction** forwards are handled by the universal
  `Tag_Forward` inline-deref diamond (HEAP_030) on any downstream deref.
- All four launch paths call `__eco_init_globals`: AOT exe
  (`eco_entry.cpp:113`), JIT (`ecoc.cpp:343`), runner
  (`EcoRunner.cpp:245`), embed/shared-lib (`eco_embed.cpp:193`).

**DS7 — Selection policy (which thunks get slots).** All `Mono.MonoDefine`
nodes reaching the thunk arm whose ABI return is `!eco.value`, **except**
single-node trivial bodies (a lone literal / embedded-constant reference —
the guard would cost more than the body). Explicitly excluded in v1:
`MonoPortIncoming`/`MonoPortOutgoing` (also routed through
`generateDefine`, but tied to the registration preamble — PORT_003;
stamp the attr only from `generateNodeInner`'s `MonoDefine` arm so ports
are untouched), and `MonoEnum` nullary constructors (M4, §11). Port
*decoder* specs (plain `MonoDefine`s per PORT_003) qualify normally.

**DS8 — Compile-time switch, not runtime.** The guard is baked into
generated code, so the toggle is the project convention for codegen
features: an eco-config / `Config.elm` flag (`cafMemo`), default **off**
during bring-up, flipped on at M5; `TestPipeline` pins it explicitly (the
keyed=True precedent). No `ECO_*` runtime env can exist for this.

**DS9 — Test-harness lifecycle needs no new machinery.** Unlike
`internLiteral` (C++ thread-local statics that survive harness heap resets
and need epoch sync), CAF slots live in the compiled module: each JIT test
compiles a fresh module with zeroed slots and runs its own
`__eco_init_globals`; the harness heap reset destroys the RootSet and with
it the stale registrations — the exact lifecycle the existing
`test/codegen/global_*.mlir` tests already exercise.

## 5. Mechanism detail

### 5.1 Elm backend (compiler/src/Compiler/Generate/MLIR/)

In `generateNodeInner`'s `MonoDefine` arm (Functions.elm:316), when the
expr is not a `MonoClosure` (i.e. it will take the thunk arm) and the
selection policy (DS7) admits it:

1. Emit a module-level op `eco.global` with
   `sym_name = "__eco_caf$" ++ funcName` (new tiny builder in `Ops.elm`;
   zero operands/results/regions — serializes through the existing
   bytecode writer unchanged).
2. Add `eco.caf_memo = SymbolRefAttr slotName` to the thunk's `func.func`
   attrs (same insertion pattern as `addShadowRootsAttr`,
   Functions.elm:395).

Reference-site codegen (`generateVarGlobal`) is untouched.

### 5.2 Guard synthesis (runtime/src/codegen/Passes/EcoToLLVM.cpp)

A new finalization step, ordered with the existing ones: after the main
conversion, **before** `createGlobalRootInitFunction` (stage 5, line 527).
For every `LLVM::LLVMFuncOp` carrying `eco.caf_memo` (slot symbol `@S`):

```
entry(new):
  %addr  = llvm.mlir.addressof @S
  %bits  = llvm.load %addr : i64
  %isset = llvm.icmp "ne" %bits, 0
  llvm.cond_br %isset, ^hit, ^body
^hit:
  %v = globalLoadI64ToValue(%bits)        ; __eco_slot_to_hptr barrier
  llvm.return %v
^body:                                     ; original entry block
  ...
; every llvm.return %r in the original body becomes:
  %rbits = globalStoreValueToI64(%r)      ; __eco_hptr_to_slot barrier
  llvm.store %rbits, %addr
  llvm.return %r
```

Correctness notes:

- Uses the same `globalLoadI64ToValue` / `globalStoreValueToI64` helpers as
  the `eco.load_global`/`eco.store_global` lowerings
  (`EcoToLLVMInternal.h:162-174`) — fold-proof slot-cast barriers per
  REP_LLVM_002, stripped post-RS4GC by `StripEcoCastBarriers`. The i64↔ptr
  crossing at a global storage boundary is exactly the sanctioned
  REP_LLVM_001(c) pattern; provenance (b) holds because the global is a
  GC-scanned slot.
- No i64 with pointer provenance is live across a statepoint: the hit path
  contains no statepoint; the store is immediately before its return with
  no interleaving call (CGEN_067-style discipline).
- `llvm.unreachable` / crash tails are not instrumented (no value to
  publish).
- Both thunk body shapes (single-return and `isTerminated` multi-return)
  are handled uniformly — post-conversion returns are all `llvm.return`.
- Ordering vs other machinery: this runs during EcoToLLVM (MLIR LLVM
  dialect), i.e. before the LLVM-IR-level `$cap` inline prepass and every
  RS4GC flavour, so guarded thunks are what any later inlining copies
  (inlining a guarded thunk preserves semantics; the guard travels).

### 5.3 GC and runtime

Nothing new. Slots are standard `eco.global`-lowered cells: rooted at
startup by `__eco_init_globals`, evacuated in place at minor GC, marked at
major GC, null/constant-skipped (all verified — DS6). Memoized values are
promoted out of the nursery at the first minor GC after publication and
live for the process lifetime.

Runtime cost of the root set: one 8-byte slot + one `jit_roots` entry per
memoized spec. Self-compile scale estimate: low thousands of slots (959
source CAFs × specialization multiplicity, minus trivial exclusions).
`evacuateJitPtr` over a few thousand mostly-null slots per minor GC is
noise next to the existing stackmap-root scan; confirmed measurable in M3
census/wall runs. If it ever shows up, the follow-up is publish-time root
registration (register the slot as a root only when first written — §12),
which also removes the init-function dependence entirely.

### 5.4 Bytecode / MLIR round-trip

`eco.global` and the `eco.caf_memo` attr must survive the compiler's MLIR
bytecode writer and the backend reader. `eco.global` is a zero-region,
zero-operand op with two attrs — the generic encoding covers it (the
existing `global_*.mlir` tests parse the textual form; the bytecode path
gets a new E2E fixture in M1).

### 5.5 Partition splitting and parallel conversion

`emitObjectFilesSplit` (EcoBackend.cpp:202) already handles this class:
`PreserveLocals=false` makes `llvm::SplitModule` **externalize** (single
definition, unique name) any local global referenced across partitions —
the correctness note names "GC-root globals (eco.global cells …)"
explicitly. With the callee-side guard, each slot is referenced only by its
own thunk anyway, so slot and thunk co-partition and externalization is
rarely even triggered. `__eco_init_globals` is generated once on the whole
module before splitting.

The function-parallel EcoToLLVM conversion (env `ECO_ECO2LLVM_PARALLEL`)
must treat the guard step like the shadow-roots step (a serial finalization
phase or per-function-safe rewrite); the byte-identical-binary gate from
that plan re-runs in M2.

### 5.6 What changes for each launch path

Nothing per-path: all four already call `__eco_init_globals` when present
(DS6). The only behavioural delta is that the function will now exist for
essentially every compiled module (today it exists only when a module uses
`eco.global`, i.e. never for Elm output).

## 6. What v1 memoizes, concretely

From the survey's categories (compiler self-compile workload):

- **A. Computed values (470)** — the target. Decoder graphs, parser atoms,
  docs, tables, task descriptions: all become compute-once.
- **B. Computed closures (98)** — partially. Function-typed point-free CAFs
  are eta-wrapped into real functions by GlobalOpt
  (`MonoGlobalOptimize.elm:551` "wraps bare MonoVarGlobal/MonoVarKernel in
  closures") and no longer reach the thunk arm; whatever still compiles to
  a `!eco.value` nullary thunk is covered, the rest is out of scope.
- **C/D/E. Ctor applications, record/list literals (171)** — covered
  (non-trivial `!eco.value` bodies).
- **F–I. Literals, nullary ctors, aliases, lambdas (220)** — mostly
  excluded by the trivial-body filter or already interned; nothing to win.

## 7. Interactions audited

| Feature | Interaction | Verdict |
|---|---|---|
| String/closure interning (HEAP_033) | Thunk bodies still call the intern helpers, now once | strictly less work |
| Inline nursery alloc (HEAP_034) | Body allocations unchanged; they just run once | none |
| GlobalOpt inliner | Call-position inlining of zero-arg *candidates* duplicates bodies into sites, bypassing the slot for those sites (function-alias cases). Value-position refs — the ones that matter — always go through the thunk | acceptable; revisit candidate policy post-M3 |
| BytesFusion reify (`buildBodyLookup`) | Reify-time beta-reduction substitutes CAF bodies into fused loops, bypassing the slot in fused code | correct, loses nothing that exists today |
| `$cap` inlining (E1.3 v3) | May inline a *guarded* thunk at a call site; guard travels | correct |
| LSS keyed / AbiCloning | More specs → more slots, one per emitted symbol (DS1) | by construction |
| PAP interning at references | Arity>0 globals still take the papCreate/intern path, untouched | none |
| Ports (PORT_003) | Port nodes not stamped (DS7); decoder specs memoize normally | safe |
| Effect managers / MonoManagerLeaf | Not stamped | none |
| Old-gen growth | Memoized values become immortal; traced every major GC | expected net win (fewer allocs ⇒ fewer majors); watch in M3, §12 permanent-promotion follow-up |

## 8. Config and rollout

- `Config.elm` / eco-config: `cafMemo : Bool`, default False in M1–M2,
  True at M5. `TestPipeline` pins it explicitly both ways during rollout.
- No runtime escape possible (guard is baked); rollback = recompile with
  flag off. The flag gates ONLY the Elm-side emission (no `eco.global`, no
  attr ⇒ the C++ step is a no-op) so one runtime binary serves both.

## 9. Proposed invariants (IDs from current tails: CGEN_067, HEAP_034)

- **CGEN_068 (CafMemoGuard):** A `func.func` tagged `eco.caf_memo = @S`
  must be an arity-0 thunk with `!eco.value` result; `@S` must be an
  `eco.global`-lowered internal i64 global referenced by no other function.
  The EcoToLLVM finalization rewrites it to: entry load of `@S` +
  icmp-ne-0 + early return of the barrier-converted value; every value
  return additionally stores the barrier-converted result to `@S`
  immediately before the return with no interleaving statepoint. Slot
  crossings use `globalLoadI64ToValue`/`globalStoreValueToI64`
  (REP_LLVM_001(c)/REP_LLVM_002). 0 is reserved as "uninitialized"; no
  valid `!eco.value` word is 0.
- **HEAP_035 (CafSlotRooting):** CAF slots are JIT roots registered by
  `__eco_init_globals` before any Elm code runs, evacuated in place at
  minor GC and marked at major GC with null/embedded-constant words
  skipped. Only slots holding tagged `!eco.value` words may be registered
  as JIT roots: a slot holding a raw scalar (i64 Int, f64 bits, i16 Char)
  must NEVER be added to the root set (the scan would misread it as a heap
  address) — any future scalar-CAF extension must use unrooted slots plus a
  separate initialized-flag and must not widen
  `createGlobalRootInitFunction`'s internal-i64 walk to them.
- **FORBID_OPT_003 (NoCrossSpecCafSharing):** A CAF slot is keyed to
  exactly one emitted thunk symbol (one SpecId). Slots must never be
  shared or merged across specializations, clones, or keyed variants of
  the same source definition — layouts and representations differ per
  spec. Deduplication of equal *values* across specs is likewise
  forbidden without a layout-equality proof.

## 10. Verification and measurement

Gates (project-standard):

- Unit: new `test/codegen/caf_memo_*.mlir` fixtures — guard shape, hit/miss
  paths, `isTerminated` multi-return thunk, crash-tail thunk, GC-during-init
  (tiny-nursery forced GC between publish and reuse, the
  `ECO_HEAP_VALIDATE` + forced-GC recipe from the List.mapN bug).
- E2E: `cmake --build build --target full` (never `check` — .mlir must
  regenerate); elm-tests leg; corpus 1628/1628.
- Self-compile fixed point: solver+subst legs byte-identical with the flag
  on (compilation output must not depend on evaluation sharing).
- Verifier legs: `ECO_LOWERING_VALIDATION` **compile-time #ifdef** build
  (an env-only run is vacuous — known trap) + heap-validate leg +
  `EcoPtrIntVerify` (barrier discipline).
- Parallel-conversion byte-identical gate re-run (ECO_ECO2LLVM_PARALLEL).

Measurement (M3):

- Census with `ECO_INLINE_ALLOC=0` (HEAP_034 counter caveat): total
  allocation events, expect visible drop from decoder/table rebuild
  elimination; runtime-call census diff (benchmarks/runtime-calls.md
  machinery).
- Wall: ×3 interleaved flag-on/off self-compile, **majors recorded with
  every wall** (the Run-K GC-trigger-lottery lesson).
- Binary size delta (slots + guards; expect noise-level).
- Optional diagnostic: thunk hit/miss counters behind `ECO_CLOSURE_STATS`-
  style build flag for one census run.

## 11. Milestones

- **M0 — Fixtures first.** Hand-written `caf_memo_*.mlir` covering §10's
  unit list against a hand-synthesized guard (validates the C++ step
  independently of the Elm emitter).
- **M1 — Mechanism.** Ops.elm `ecoGlobal` builder; `generateNodeInner`
  stamping behind `cafMemo=False` default; C++ guard step; bytecode
  round-trip fixture. Gate: full E2E green with flag off (byte-identical
  to baseline), targeted E2E subset green with flag on.
- **M2 — Full gates flag-on.** Corpus, self-compile fixed point, verifier
  + heap-validate legs, parallel-conversion gate.
- **M3 — Measure.** §10 measurement plan; decide default.
- **M4 — Nullary custom constructors. SHIPPED 2026-07-23 (Run T,
  `benchmarks/runtime-calls.md`): −4.5 % census-on wall on top of Run S,
  minors 760→727 at 9 majors flat, dispatch-neutral; +274 enum slots
  (1,215→1,489); E2E 1634/1634 (new `caf_memo_enum.mlir` fixture) +
  byte-exact bootstrap fixed points.** `MonoEnum` thunks are stamped in
  `generateNodeInner` (same `cafMemo` flag rather than a separate gate —
  `ECO_CAF_MEMO=0` escapes both); well-known constants (True/False/Nothing
  → embedded immediates) stay unstamped, and `monoTypeHasEffects` applies
  to the enum result type. Identity audit held: constructed customs are
  immutable once escaped (HEAP_031), equality/dispatch are tag-based.
- **M5 — Default on.** `cafMemo=True` in Config.elm; TestPipeline pins;
  memory + invariants.csv updated (CGEN_068 / HEAP_035 / FORBID_OPT_003
  assigned for real).

## 12. Future work

- **Inner CAFs (closed expressions inside function bodies) — surveyed
  Jul 24 2026.** Hoisting a let-bound or inline closed expression (no free
  locals, e.g. `vals = [1,2,3] |> Array.fromList` inside `f x`) to a fresh
  top-level spec would let the existing slot machinery memoize it
  unchanged. Source scan of the 275 compiler files: loose bound 251
  closed let-values (heavily false-positive — regex scoping), STRICT bound
  **17 let-values + 34 closed local functions**, true population
  ≈ O(10–40) values, inline literal builds outside lets: 0. A few are hot
  allocation sites (`Type/PostSolve.elm:414` mints a `Can.TType` per
  string-literal post-solve; `Mlir/Bytecode/AttrType.elm:988` builds a
  `BD.map2` decoder graph per float attr written); most are tiny or
  LLVM-foldable. Already covered without new work: closed local functions
  (lambda lifting + HEAP_033 closure interning), nullary ctors (M4),
  string literals (interning) — the residual class is composite structure
  builds. Verdict: not a source-level transform; the correct venue is a
  **mono-graph census + hoist** — free variables are exact on MonoExpr,
  inlining MULTIPLIES sites and specialization CLOSES more expressions,
  and the hoist is small (mint a MonoDefine spec per closed subtree,
  hash-consed to re-merge inliner duplicates; slots do the rest). Lazy
  slots preserve evaluation timing exactly (no GHC full-laziness
  eagerness hazard); space cost is the accepted immortality tradeoff.
  Estimated win: low single-digit % — run an ECO_INLINE_REPORT-style mono
  census first, decide on its numbers.
  **OUTCOME (Jul 24 2026): implemented (CafHoist.elm, CGEN_069), all
  gates green, measured NEGATIVE on the self-compile wall (+1.5 %/+0.9 %
  at mn=3/mn=8 despite minors −9 and a 1.13 MB smaller binary) — ships
  DEFAULT-OFF. The economics: hoisting introduces a statepointed call
  where HEAP_034 inline construction stood; small hot candidates lose,
  large ones are cold, and the dispatch-heavy bodies were bytes-excluded
  (dispatch-neutral to the digit). benchmarks/runtime-calls.md Run V.
  Revisit with the caller-side fast path or profile-guided selection.**
  **Mono census RUN (Jul 24 2026, `ECO_CAF_CENSUS=1` →
  `Compiler/GlobalOpt/CafCensus.elm`, reported from `runGlobalOptPhase`
  over the final graph; full report was /work/caf-mono-census.md):
  6,083 maximal closed subexpressions across 38,267 specs (~360× the
  strict source count — inlining multiplies, specialization closes),
  98.5 % value-ABI, 941 of size ≥10 nodes; kinds call=3,756 let=1,816
  tuple=317 list=174 record=20. Biggest cluster: constant
  serialization-encoder cells (Bytes.Encode.U8=998 + F64=622, warm/hot);
  parser atoms + Intrinsics.basicsIntrinsic hot; top enclosing specs skew
  COLD (Reporting.Error toReport/encoder tail). Hash-consing would
  collapse the 6,083 sites to far fewer distinct slots. Implementation
  sketch: GlobalOpt tail pass reusing CafCensus.walkExpr — hoist maximal
  closed subtrees (size ≥ 3) into hash-consed fresh MonoDefine specs,
  replace sites with MonoVarGlobal; slots do the rest. Expected
  low-single-digit % + minor-GC relief.**
- **Caller-side fast path — SHIPPED default-on (Jul 24 2026, Run W):**
  `rewriteCafCallSitesFast` turns each thunk call site into an scf.if
  diamond (hit = load+icmp+barrier, no call; miss = the original call).
  −1.2 % wall on the shipped config at dispatch/GC identity and one-sha
  outputs; +1.27 % binary. `ECO_CAF_CALLER_FAST=0` escape. Two lessons:
  scf single-block regions forbid block surgery in this phase (use scf.if
  expressions), and it did NOT rescue inner-CAF hoisting (Run X: +2.1 % —
  construction is the fast path for small structures).
- **Scalar-ABI CAFs (v2):** unrooted slot + i8 flag global per HEAP_035's
  constraint. Survey suggests near-zero value; do only if census disagrees.
- **Publish-time root registration:** `eco_caf_publish(slot, bits)` gc-leaf
  helper (store + `addJitRoot` on first write) — shrinks the root set to
  initialized slots and deletes the init-function dependence; the natural
  follow-up if minor-GC root-scan cost or the init walk ever matters.
- **Permanent-space promotion:** deep-copy large memoized structures into
  `allocatePermanent` space after evaluation (internLiteral-style) so major
  GCs stop tracing them. Needs a copy pass and a size heuristic; measure
  major-GC mark cost first.
- **Eager init option:** evaluate all slots at startup in dependency order
  (JS parity, moves cost to startup). No known motivation; lazy dominates.
- **Cross-run persistence** (serialize memoized decoder graphs into the
  binary as static data): a different, much bigger project (needs pointer
  fixups); noted only to mark the boundary.

## 13. Risks

| Risk | Mitigation |
|---|---|
| Guard surgery breaks an RS4GC/verifier assumption in some body shape | M0 fixtures first, incl. isTerminated + crash tails; EcoPtrIntVerify leg |
| Bytecode writer chokes on module-level `eco.global` from Elm | M1 round-trip fixture before anything else lands on it |
| Root-scan cost of thousands of mostly-null slots | measured in M3; publish-time registration follow-up ready (§12) |
| Debug.log-count-sensitive tests in corpus | corpus gate will surface; align with JS-backend behavior (once) |
| Immortal memoized values inflate old-gen / major-GC mark time | M3 majors-with-walls discipline; §12 permanent promotion |
| Split/parallel pipelines reorder around the new step | byte-identical parallel gate re-run in M2 |
