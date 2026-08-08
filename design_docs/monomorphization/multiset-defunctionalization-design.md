# Multi-set defunctionalization and the staged-currying horizon — design sketch

Status: **DESIGN SKETCH, PRE-PLANNABLE (2026-08-08).** Preserved so the
idea survives; deliberately NOT a plan — §7 defines the census that would
make it one. Companions: LSS design
(`design_docs/monomorphization/lambda-set-specialization-design.md`), the
**M5 capture-union NO-GO**
(`design_docs/monomorphization/capture-union-representation.md`, 2026-07-16
— the closest prior art, and this document must be read against its
verdict), the HOF-elimination record
(`plans/hof-elimination-closure-alloc-reduction.md`), staged currying
(`design_docs/mono-uncurry.md`, `design_docs/mono-still-curried.md`), and
`plans/gc-free-function-propagation.md` (composition target).

## 1. The observation

The closure-call lowering has exactly three dispatch modes
(`EcoToLLVMClosures.cpp` ~1222–1411, read 2026-08-08):

- `fast` — singleton lambda-set: known `_fast_evaluator` + `_capture_abi`,
  direct call. LSS's k=1 harvest; dominant by every census.
- `closure` — indirect call through the evaluator pointer stored in the
  closure object.
- `unknown` — diagnostic fallback.

Multi-member sets (k ≥ 2) lower to `closure` mode **even when ALL-KEYED
LSS statically knows the closed member set**: the HOF *body* is
specialized per set, but applications of the closure parameter inside it
discard the set knowledge and dispatch indirectly. That discarded
knowledge is this document's subject.

## 2. Reference model: MLton

MLton compiles SML with no uniform function representation at all:

1. Whole-program, defunctorized, fully monomorphized — every callee set is
   computable (0CFA) over a simply-typed program.
2. **Defunctionalization**: each lambda-set becomes a compiler-invented
   sum type (one ctor per lambda, payload = free variables); each
   application becomes a `case` with a **direct call per arm**. No
   evaluator pointers, no runtime arity, and crucially **no fallback
   path** — a fat set yields a fat `case`, not a protocol.
3. **Currying dissolves by simplification, not by a pass**: `fn a => fn b`
   converts to outer-function-returning-a-constructor of the inner set;
   full application inlines to construct → case-of-known-ctor → direct
   call, and SSA argument flattening makes functions genuinely n-ary.
   Partial application survives only as an ordinary data value carrying
   the prefix.

Legal because *nothing outside the compiled program consumes SML function
values*. Eco's structural difference is exactly the consumers MLton lacks:
kernel C++ HOFs invoking closures via the evaluator protocol, the effect
system storing callbacks (Task/Cmd/scheduler), and ports/embedding.

## 3. Eco's function model today (why staged currying exists)

Staging provides two services through one uniform protocol:

- **Partial application**: `mono-uncurry` Option A flattens directly-
  nested lambda chains into one uncurried stage; `mono-still-curried`
  keeps stage boundaries where computation intervenes (lambdas separated
  by `let`/`case`). Under-application forms runtime PAPs
  (`papCreate`/`papExtend` chains); each function commits to a canonical
  segmentation (`chooseCanonicalSegmentation`) and disagreeing call sites
  are reconciled by ABI wrappers (`buildAbiWrapperGO`; GOPT_003/010–016).
- **Unknown callees**: the uniform closure ABI (evaluator ptr + captures +
  arity/stage metadata) plus generic apply as the arity fallback.

Known saturated calls are already direct, and `$cap` inlining eats their
closure bodies — dynamically equivalent to MLton's happy path. The H-track
plus P6 removed −73.3 % then −99.2 % of dispatch events; kernel hot
combinators are set-specialized. What remains in `closure` mode is the
residual this design targets — **size unknown; nobody has counted it
since** (§7).

## 4. Design shape A — heap discriminator unions for closed multi-sets

Per closed k≥2 set: a compiler-introduced **Custom ADT** — one ctor per
member (member identity = function × captured stage, the
`lss-fork-qualified-members` naming), payload = that member's captures —
introduced **at closure construction sites** (the K5 lesson:
representation changes happen at construction or not at all) and flowing
through storage as an ordinary heap value. Apply sites lower to
`eco.case` + a direct `eco.call` per arm at the member's real signature.

### 4.1 Why this dodges both of M5's killers

M5 (stack capture unions) died on two things this shape does not have:

1. **The boxing boundary.** M5's win class excluded anything stored into
   heap data — which disqualified the dominant creator block (IO
   monadic-bind continuations, 175.5M creates, heap-captured into the
   next chain closure). Shape A's union IS a heap value; storage is its
   normal life, not a boxing bail-out.
2. **The GC contract.** M5's crux was dynamic-mask stack rooting (§2.4
   options (a)/(b), landing on the exact machinery with the worst defect
   history). Shape A is an ordinary Custom: per-ctor field layouts and
   unboxed bitmaps already express per-member capture kinds; the precise
   GC scans it with zero new machinery.

### 4.2 What it inherits from M5 unchanged

- **The scarcity prior.** Every LSS census to date: singletons dominate;
  k≥2 sets ≈ 0 % of the top-46 % of dynamic *creates* (M5 §4). Apply
  events are a different measure (few hot k≥2 closures could still
  dominate apply traffic) — but the same census says k≥2 barely exists.
  This is the design's most probable kill.
- **`maxSetSize = 8` (LTop above it)** excludes the mega-sets — notably
  the typechecker IO-bind continuation family, whose set at the run-loop
  apply site is in the hundreds. MLton would emit the giant case; Eco's
  LSS caps it to open. So the *dominant* closure population stays out of
  reach unless the cap philosophy changes (see §6).
- **The frontier.** Kernel ABI takes `HPtr` closures; generic apply and
  PAP formation operate on heap closures. A union value crossing any of
  those reifies: the compiler emits one **dispatcher function per
  escaping set** and boxes (dispatcher, union) as an ordinary closure.
  Same coercion discipline as M5 §2.3, minus the store-to-heap clause.

### 4.3 What it buys (the honest channel)

NOT allocation: a union create is the same bump-alloc as a closure create
(Closure 22.1 % of true alloc but 0.002 % of promotion — LH1; wall follows
retention — K6). The channel is **apply-side directness compounding
through existing machinery**: direct arms feed `$cap` inlining;
case-of-known-ctor collapses locally-visible construct→apply flows;
`gc-free-function-propagation`'s v1 fixpoint sees through switches (its
LSS v2 refinement becomes unnecessary wherever this ran); arms are
analyzable by every direct-call optimization the codebase owns.

## 5. Design shape B — the horizon: retiring staged currying entirely

Shape A inside the staged world is separable and additive. The MLton
endpoint — no staging, no PAP objects, no generic apply — would require:

1. **Total LSS**: every higher-order value in a set; open sets legal only
   at the designated frontier.
2. **Defunctionalized partial application**: PAPs become ctors
   (function × applied-prefix-that-occurs) in the consuming set's union;
   `papExtend` chains become construction; every function compiles at
   full flat arity. `mono-still-curried`'s let/case-separated chains
   compile the MLton way: the inner lambda is a set member whose captures
   include the outer args and intermediate results.
3. **Frontier reification** (§4.2's dispatcher-per-set) as the ONLY
   surviving uniform representation — kernel HOFs not yet
   set-specialized, scheduler-stored callbacks, ports.
4. **Demolition**: CallInfo segmentation + wrapper builders, papCreate/
   papExtend/pap-simplify, generic apply, `_dispatch_mode`, and rewrites
   of the CGEN_CLOSURE_* / GOPT_010–016 invariant families. The plans
   directory holds ~20 PAP/staging bug-fix plans — simultaneously the
   case for removal (bug farm) and for extreme caution (load-bearing
   everywhere). Byte-identity is unavailable as a gate; this would be the
   largest structural refactor in the project's history.

Shape B is strictly downstream of shape A's verdict: if defunctionalized
dispatch shows no win inside the staged world, retiring staging is a
complexity project with no performance case, and should be argued (if
ever) purely as simplification.

## 6. What could reopen the dominant population

M5 §5's revisit condition 2 deserves restating from this angle: the
typechecker IO chain (the single largest closure family) is exactly a
defunctionalizable step loop — but through the *set-size cap*, not under
it. Raising `maxSetSize` for specific sets (a fat-case mode with a jump
table, MLton-style) or restructuring IO-bind into an explicit
defunctionalized state machine at the source/GlobalOpt level would move
the dominant block into shape A's reach. That is its own design question
(cost: case explosion, code size, icache) and should not be smuggled into
a first experiment.

## 7. The census that would make this plannable (C0)

Infra: the `benchmarks/runtime-calls.md` counter harness. One
census-build; measure on the standard cold Stage-7a workload:

1. Dynamic apply events by `_dispatch_mode` (fast / closure / unknown) —
   the `closure` share IS the addressable pool. Prior: P6 left dispatch
   events −99.2 %; if `closure`-mode events are noise, STOP and record.
2. Per-set histograms at `closure`-mode sites: member count (k=2..8),
   apply-event concentration (top-N sets), capture-free vs captured
   member split.
3. Static: closed k≥2 set count and their construction-site counts
   (M5 §5.1's "set-size-keyed census that does not exist today").
4. Bonus row for §6: events at LTop sites that would be closed at
   maxSetSize = 16/32/64 (answerable from LSS internals without building
   anything).

Plannability bar (mirrors M5's): `closure`-mode apply events ≥ ~1 % of
dispatch events AND concentrated (top ~20 sets ≥ half of it). Below that,
this document stays a design sketch and the verdict gets recorded here.

## 8. Invariant / representation impact preview (if ever built)

- New REP rows: discriminator-union Customs are ordinary ADTs (REP_HEAP
  unchanged) but the closure↔union coercion at the frontier needs a
  CGEN_CLOSURE sibling (when reification is mandatory) and a
  FORBID row (no union value may reach kernel ABI / papCreate unboxed).
- GOPT: set-identity must be stable from construction through storage to
  apply (LSS list-chain keying is the existing carrier).
- No new GC machinery (the decisive difference from M5).
