# Kernel Parametricity License — audit-granted "trust the type" rows for KernelSetFacts

**Status: PLAN (2026-08-20; lowered from the same-day outline to implementation-ready
detail).** Successor to `plans/lss-fidelity-3-signature-flow-completion.md` Phase F,
which shipped the per-position v1 (`PSFOpaque/PSFApplies/PSFTunnels`, LSS_021). This
plan removes the expressiveness ceiling that forced every v1 row to stay partial, by
adding a third, strongest tier: a per-kernel audited claim that the kernel's Elm TYPE
is a complete description of its set flow — after which the consumers simply skip the
LSS_004 poison and let ordinary instantiation + unification do all transport.

The plan does NOT perform any audit. It defines (a) exactly what the audit checks in
the C++, (b) the procedure and evidence format, and (c) every compiler edit that
encodes a result. All code refs verified at HEAD 2026-08-20.

---

## §0 Ground truth at HEAD

- **v1 shipped state:** `Compiler/MonoSolver/KernelSetFacts.elm` — `ParamSetFlow`,
  `KernelPlan = { params, result, evidence }`, `planFor` (arity-checked, inference
  side), `rowFor` (translation side), `facts : Dict ( Name, Name ) KernelPlan` with 6
  rows (map2-5, sortBy, sortWith). Consumers: `LssInfer.kernelCallBoundary` (the
  `walkCall` VarKernel arm) and `Translate.poisonKernelArrowsThen ( home, name )`
  (composed at `deriveKernelAbiTypeWith`'s tail; per-param descent
  `poisonKernelPerParam`; tunnels via `LssInfer.joinArrowSetsPlain`).
- **Census baselines** (Run X flag-off leg): `byKernel = 4,065`,
  `kernelFactHits = 169`, singletons 64,311, `devirtDirect = 4,000`.
  NOTE `byKernel`'s current meaning: one bump per kernel BOUNDARY (inference
  `poisonCallBoundary` / translation rowless or any-position-poisoned path) — it bumps
  even for arrow-free schemes, so it counts boundaries, not poisoned arrows.
- **Scale:** 335 `Elm_Kernel_*` entry points (Basics 47, Browser 41, Json 38,
  VirtualDom 36, String 34, Utils 31, JsArray 31, Bytes 29, File 25, List 19, …).
  The audit is wave-based or it will never finish; most kernels fall in a cheap
  "vacuous" class (§2.5).
- **Sanctioned application entry points** (the ONLY ways C++ calls an Elm closure):
  `eco_apply_closure` (RuntimeExports.cpp:1897), `eco_apply_closure_eval` (:1987),
  `eco_apply_closure_typed` (:2153), `eco_apply_segmentation_unknown` (:2175), plus
  kernel-local wrappers over them (`callUnaryClosure`/`callBinaryClosure`,
  ListExports.cpp:32-39, and per-file equivalents).
- **Known closure FABRICATION sites** (grep `Tag_Closure|allocClosure`):
  `core/Utils.cpp`, `core/TaskEffectManager.cpp`, `http/HttpExports.cpp`,
  `http/HttpEffectManager.cpp`, `time/TimeExports.cpp`, `time/TimeEffectManager.cpp`.
  Files on this list are automatic careful-audit territory; anything reachable from a
  kernel that fabricates a closure into a type-visible position is not licensable.
- **Where the compiler-visible kernel type lives:** for elm/core kernels, the
  annotation of the ALIASING def in the core package (e.g. `map2 : (a -> b -> result)
  -> …` at `~/.eco/.../elm/core/1.0.5/src/List.elm:437`); for eco/kernel, the stubs
  under `eco-kernel-cpp/src` (memory: the signature is synced in 3 places — the audit
  cites the one the compiler actually reads: the aliasing annotation).

## §1 The license: claim and soundness argument

**The claim (one per kernel, granted only by audit):** *every function value entering
or leaving this kernel flows only along the paths described by its Elm type's
variable-sharing graph, the kernel retains nothing across the call, and it introduces
no function-valued inhabitants of its own.*

**Consumer consequence:** skip the poison entirely, both sides. Ordinary
instantiation + unification then transports sets exactly as for a plain-Elm callee —
the shared `a`/`b`/`c` Points in `(a -> b -> c) -> List a -> List b -> List c` ARE
the flow edges (`loadVarC` memoizes per type variable within the instantiation). No
new transport machinery of any kind.

**Why removal-of-poison is the safe default direction:** an unconstrained FunL slot
reads back `LTop` at zonk (`Store.zonkSetSlot`'s FlexVar arm) — a licensed position
that receives no flow still reads ⊤, never a false empty set. The ONLY hazard is a
*populated-but-incomplete* set: caller knowledge flows in, the kernel secretly adds
or reroutes an inhabitant the type doesn't account for, and a downstream singleton
consumer stamps the wrong function. That hazard is precisely what the audit
checklist excludes; it is the same failure class as a wrong `PSFApplies`, widened to
every position at once — hence the discipline in §2.6.

**Why v1's opaque-result caveat dissolves under the license** (record this — it is
the argument that makes `TypeFaithful` strictly subsume every sound per-position
refinement we deferred):

- *PAP-of-callback (map2-5 results):* if the callback `f` has declared arity > the
  kernel's application count, the result element is a PAP of `f`. The result-element
  arrow is `c`'s Point, shared with `f`'s spine arrow at that depth — which is
  WITHIN `f`'s declared arity, so LSS_013 spine injection already wrote `f`'s member
  there. The PAP inhabitant is covered by construction ("a PAP of member m is m").
- *Exact-arity case:* the element is `f`'s returned closure `q`; `c`'s slot carries
  whatever `f`'s own body flow established for `q` (or stays flex → ⊤). Complete
  either way.
- *sortBy/sortWith permutation:* the `a`-sharing between input and output lists IS
  the `PSFTunnels` refinement, for free.
- *Partial kernel application:* no arity rule needed at all — unification against
  however many args are present, residual unified with the call type, is
  shape-correct by construction. (v1's arity-mismatch full-poison rule exists only
  because per-position lists must align positionally; the license has no positions.)

**What the license can never cover (do not audit these — reject on sight):** kernels
whose functional payloads land in TYPE-OPAQUE positions or in the runtime's own
storage. `Task`/`Process`/effect-manager internals (`Scheduler::allocTask` storing
callbacks, Scheduler.cpp:144-162; `Scheduler.succeed/fail` store their `x`/`a`
argument in the Task — a function-typed instantiation of that variable is retention
into an unrepresentable position), ports (`specializePort` poison is separate LSS_004
territory), VirtualDom event handlers, anything registering values with the JS/TSFN
boundary. These stay `Opaque` and belong on the module doc's REJECTED list — they are
the mapping doc §6 escape-by-soundness floor wearing kernel clothes.

## §2 The audit

### 2.1 Procedure (per kernel; the evidence records each step)

1. **Locate the surface.** Find the `extern "C" Elm_Kernel_<Home>_<name>` entry
   point(s) in `elm-kernel-cpp/src/**`. Build the TRANSITIVE call list: every C++
   function reachable from the entry point (kernel-local helpers, the internal twins
   in non-Exports files, runtime calls). The audit covers the closure of that list —
   an unexamined helper is an unlicensed kernel.
2. **Pin the type.** Quote the compiler-visible Elm annotation (the aliasing def's
   annotation for elm/core; the stub for eco/kernel) and confirm the C++ argument
   order corresponds 1:1 (no hidden state args beyond the runtime's own).
3. **Enumerate function-capable positions.** Every position where a function value
   can occur at runtime: (i) parameters that ARE arrows; (ii) parameters whose TYPE
   VARIABLES may instantiate to arrows (elements of `List a`, record fields, tuple
   slots — any `a` is function-capable); (iii) the same for the result. This is the
   worklist for checklist B.
4. **Run the checklist (§2.2-2.4) over the transitive call list**, recording the
   decisive line for every nontrivial item (every write that looks like storage,
   every closure-allocating call, every application site).
5. **Classify:** all items pass → `TypeFaithful`. Some positions certifiable, others
   not → `Positional` (v1 row) covering what passed. Any B2/B3 violation on a
   position the type exposes → `Opaque` + REJECTED-list entry naming the violating
   line.
6. **Encode** (§3), add the rot-guard manifest line (§4), run the per-wave battery
   (§5).

### 2.2 Checklist A — surfaces and honesty

- **A1.** Transitive call list complete and cited. Decisive check: grep the entry
  point's file for calls out of it; follow each; stop at runtime API boundaries
  (which are covered by A2/B1's sanctioned lists, not re-audited per kernel).
- **A2.** The Elm annotation is HONEST: the C++ neither observes more structure than
  the type grants (a `a -> a` that inspects and branches on closure-ness is
  observation, tolerable; one that returns a DIFFERENT value based on it is not
  type-faithful) nor uses out-of-band type knowledge to route values.
- **A3.** No variadic/reflection tricks: argument count fixed and equal to the
  Elm-visible arity at the export boundary.

### 2.3 Checklist B — the flow discipline (per function-capable position from step 3)

- **B1 (application-only).** Every USE of a function value from an argument is one
  of: (a) a call through a sanctioned application entry point (§0 list) or a local
  wrapper over one; (b) a MOVE into a position the type exposes (e.g. stored into
  the result container at a position covered by a shared type variable — the sortBy
  permutation); (c) identity-preserving plumbing (stack rooting, `Export::encode`
  round-trips, register copies). Anything else fails.
- **B2 (no retention).** The value is not written into ANY object that outlives the
  call except the result (and then only per B1(b)). Concrete scan list — each is a
  grep target over the transitive call list:
  - writes into `static`/global storage or singletons;
  - caches/memo tables keyed across calls;
  - scheduler/task/process structures (`allocTask`, mailbox/queue enqueues) —
    the canonical rejection class;
  - registration with the embedding boundary (TSFN, JS callbacks, timers);
  - mutable cells (`MVar`-backed runtime state) reachable from other roots.
- **B3 (no fabrication or laundering).** The kernel never returns or stores a
  function value that is not one of its arguments (or a sub-value reached per the
  type). Scan list: closure allocation (`Tag_Closure`, `allocClosure` — §0 names the
  six files where these exist today); returning references to OTHER kernels'
  closures or cached globals; wrapping an argument in a fresh closure (a new
  identity the analysis has no member id for — laundering). Transient PAPs built
  INSIDE `eco_apply_closure_eval` during under/over-saturation are sanctioned (they
  are the LSS_013-covered inhabitants, §1); kernel-authored closure allocation is
  not.
- **B4 (callback re-entry).** If the kernel applies a callback (B1a), confirm the
  code between applications performs no B2/B3 action CONDITIONED on the callback's
  behavior (a callback that re-enters the kernel may observe partial state — a
  correctness concern out of scope here — but must not cause the kernel to stash or
  synthesize function values).
- **B5 (comparator/equality effects).** Closures may be compared, hashed, or
  discarded freely (no flow); check only that comparison results don't select which
  CLOSURE to store where in a way that breaks B1(b)'s "position covered by the
  type" (a sort is fine — any permutation is covered by `List a -> List a`).

### 2.4 Checklist C — result derivation

- **C1.** Every function-capable component of the RESULT is derived per the type:
  either an argument (sub)value transported along a shared type variable, or a
  callback return (covered by §1's PAP argument). Nothing else can appear.
- **C2.** If the result type has NO function-capable positions (no arrows, no type
  variables — `String -> Int` class), C1 is vacuous — record "result inert".

### 2.5 The vacuous fast class (makes 335 kernels tractable)

If the kernel's ENTIRE type has no function-capable positions (no arrows anywhere,
no type variables anywhere — `String.length : String -> Int`, `Basics.round`,
bitwise ops, most of Bytes' scalar ops), then B1/B3/B4/B5/C1 are vacuous and the
audit reduces to **A2 (honest type) + B2 (no retention of the — non-functional —
args is irrelevant to set flow; check nothing)**: effectively "confirm the type is
the real type". These license in BATCHES (one commit per module file), each row's
evidence citing the type source line only, marked `vacuous`. Types with variables
but inert results (`Utils.equal : a -> a -> Bool`) need B1+B2 on the `a` positions
(the values could be closures) but C1 is vacuous — a middle "cheap" class. The
expensive class — arrows in the type — is the §6 wave list.

### 2.6 Evidence format and discipline (mandatory, mirrors KernelFacts.elm)

```
evidence = "<class: vacuous|cheap|full> | entry: <file>:<fn>:<lines>
           | helpers: <file>:<fn>[, ...] | type: <file>:<line>
           | B1: <decisive lines> | B2: <scan result / decisive lines>
           | B3: <scan result> | audited: 2026-MM-DD"
```

One kernel per commit for the `full` class; one module file per commit for
`vacuous`/`cheap` batches (each row still individually evidenced). Any doubt on any
item ⇒ the kernel stays `Positional` or `Opaque` — the failure asymmetry (a wrong
license is a false-singleton miscompile; a missing one is only precision) is the
governing rule, unchanged from LSS_021.

## §3 Compiler changes

### 3.1 `KernelSetFacts.elm` — the three-tier row

```elm
type KernelSetFact
    = TypeFaithful { evidence : String }   -- §1 claim; consumers skip poison entirely
    | Positional KernelPlan                -- v1 unchanged (arity-aligned per-position)

factFor : Name -> Name -> Maybe KernelSetFact     -- Nothing = Opaque (LSS_004 default)
```

- `facts` becomes `Dict ( Name, Name ) KernelSetFact`; the six v1 rows wrap in
  `Positional` unchanged (their promotion to `TypeFaithful` is wave 1 WORK, §6 — the
  v1 apply-only audit did not check B2/B3 retention/fabrication and must be redone
  to the full checklist).
- `planFor`/`rowFor` become internal helpers of the `Positional` path (keep their
  arity semantics exactly; exports change to `factFor` + the types).
- Module doc gains the REJECTED list (§1's non-licensable classes with file:line
  citations) and the §2.6 evidence format.

### 3.2 Inference consumer — `LssInfer.kernelCallBoundary`

The `walkCall` VarKernel arm binds the meta it currently discards:
`TOpt.VarKernel _ _ home name funcMeta -> kernelCallBoundary home name funcMeta args meta s0`.

```elm
kernelCallBoundary home name funcMeta args meta s0 =
    case KernelSetFacts.factFor home name of
        Just (KernelSetFacts.TypeFaithful _) ->
            -- Licensed: behave like a plain callee — fresh scheme instantiation,
            -- best-effort param/result unification; shared type variables do the
            -- transport. No poison, no widenedByKernel.
            case Store.loadTypeIsolated funcMeta.tipe s0 of
                Err e -> Err e
                Ok ( funcVar, s1 ) ->
                    case unifyCallShape funcVar args meta s1 of
                        Err e -> Err e
                        Ok ( callVar, s2 ) ->
                            Ok ( WpOpaque callVar, Engine.bumpKernelFactHit s2 )

        Just (KernelSetFacts.Positional plan) ->
            -- v1 path verbatim (arity check via planFor semantics)
            ...

        Nothing ->
            poisonCallBoundary args meta s0
```

Notes: `WpOpaque` is the correct honesty class (call result — empty-or-honest, must
not mix into hubs; same contract as `applyCalleeAt`). The known A.1 arg-position
leak applies here as everywhere on the inference side (arg loads are fresh) — the
licensed inference path mainly buys rep-linkage into signatures; the full per-site
member transport happens translation-side, where `deriveKernelAbiTypeCall` already
unifies the real item-memo arg Points BEFORE the (now skipped) poison.

### 3.3 Translation consumer — `Translate.poisonKernelArrowsThen`

```elm
        case KernelSetFacts.factFor kHome kName of
            Just (KernelSetFacts.TypeFaithful _) ->
                -- Licensed: pass-through. Arg unification already happened
                -- (Engine.andThen runs the step first); the unpoisoned shared
                -- slots carry the caller's knowledge into the zonk.
                Ok ( funcVar, Engine.bumpKernelFactHit s )

            Just (KernelSetFacts.Positional plan) ->
                ... v1 poisonKernelPerParam path verbatim ...

            Nothing ->
                ... full poison + bumpWidenedByKernel (today) ...
```

`byKernel` semantics sharpen for free: licensed boundaries stop bumping entirely, so
the counter converges toward "boundaries that actually poisoned" (§7).

### 3.4 Census

Reuse `sigStats.kernelFactHits` for both tiers (it already means "a fact row
applied"). Add ONE report-gated counter `sigStats.kernelLicensed` (bump in both
consumers' TypeFaithful arms) so the report separates licensed boundaries from
positional applications: extend the `sigflow:` report line with
`" kernelLicensed=" ++ …`. No new sub-record (SigFlowStats has room).

## §4 License-rot guard

The license is a contract on the C++; a later kernel edit can silently invalidate
it. Elm tests cannot read files, so the guard is a build-tree check:

- **Manifest:** `compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt`,
  one line per licensed kernel: `<sha256>  <repo-relative C++ path>  <Home.name>`
  (multiple lines when the transitive call list spans files).
- **Checker:** `test/scripts/check-kernel-license-manifest.sh` — recompute sha256
  for each listed file; on mismatch, fail with "kernel <k> licensed against a C++
  body that has changed — re-audit per plans/kernel-parametricity-license.md §2 and
  update the manifest hash". Wire it as a CTest (`add_test`) in `test/CMakeLists.txt`
  so `--target check`/`full` runs it; it costs milliseconds.
- Updating the hash without a re-audit note in the row's `evidence` date is the
  violation the review should catch — say so in the script's failure text.

## §5 Tests and battery

**Unit — `compiler/tests/TestLogic/Monomorphize/KernelLicenseTest.elm`** (harness =
LssSigFlowTest's: `runSolverMonoWithLimits`, registry `reverseMapping` annotation
walkers):

1. *Transport pin:* a fixture calling a licensed kernel with a named-global callback
   (`testValue = ... List.map2 addFn xs ys ...` once map2 is licensed) → the stored
   demand's callback-position arrow anno carries the `g|` member (flag-independent —
   this is default-path behavior), where pre-license it reads LTop.
2. *Unlicensed pin (negative control):* the same fixture shape through a kernel with
   no row → LTop, unchanged.
3. *Vacuous-class pin:* a licensed arrow-free kernel boundary leaves surrounding
   annotations exactly as before (assert demand equality vs a run with the row
   removed — guards against the licensed path accidentally minting new structure).
4. *Positional regression:* the six v1 rows keep their existing behavior after the
   type change (the LSS_021 semantics tests, re-asserted through `factFor`).

**E2E:** extend `test/elm/src/` with one behavioral fixture per full-class wave
(map2 wave: values through licensed map2/sortBy with 2+ distinct callbacks — CHECK
lines pin outputs; the anti-miscompile shape mirrors LssSigFlowTest.elm's `b: 11`).

**Battery per wave** (identical discipline to Phase F): poison removal is
behavior-neutral by LSS_005 but ARTIFACT-AFFECTING under keying → per wave:
`--target full` once (tee, grep), elm-tests once, one cold self-compile census leg
(`ECO_MONO_LSS_REPORT=1`) recording the §7 counters, and the manifest check green.
Suites serial; purge `build/test/*/eco-stuff` between legs; rebuild
`build-kernel/bin/eco-compiler` before manual census runs (`full` deletes it).

## §6 Waves and candidates

- **Wave 0 — mechanism:** §3 type + consumers + §4 guard + §5 tests, with ZERO
  licensed rows (all six existing rows wrapped `Positional`). Battery must show a
  byte-quiet tree (no behavior anywhere — pure refactor gate).
- **Wave 1 — pilot, full class:** `List.map2` and `List.sortBy` re-audited to the
  full checklist (the v1 audit covered B1 only; B2/B3 over `kernelListMapN`
  :432-590 and the sortBy body :759-831 + helpers are new work), promoted to
  `TypeFaithful`. This wave produces the evidence-template and manifest precedents.
- **Wave 2 — remaining v1 rows:** map3-5, sortWith.
- **Wave 3 — vacuous/cheap batches:** per module file (Basics, String scalar ops,
  Bytes scalar ops, Utils comparisons), §2.5 reduced checklist. Largest byKernel
  drop for the least audit effort.
- **Wave 4 — full-class expansion by heat:** `String.map/filter/any/all/foldl/foldr`
  (StringExports.cpp:263-366, apply-only per the 2026-08-20 survey), `JsArray.map/
  initialize/initializeFromList/foldl/foldr` (JsArrayExports.cpp:463+), then the
  `kernelMissHist` top entries that aren't in the rejected classes.
- **Never:** Scheduler/Task/Process/effect managers, ports, VirtualDom handlers,
  anything in §0's fabrication-file list unless the fabrication is proven unreachable
  from the audited entry point — REJECTED-list entries, not audit backlog.

## §7 Census expectations and reading

- `byKernel` (4,065 baseline) drops per licensed boundary — vacuous batches move it
  most; after wave 3 it approximates "arrow-carrying unlicensed boundaries", a far
  sharper number for GAP-4's residue.
- `kernelLicensed` (new) counts licensed applications; `kernelFactHits` continues to
  count positional ones.
- Precision lands as: singletons (64,311 baseline) up at kernel-adjacent sites;
  `devirtDirect`/`dispatchUpgraded` up where callback sets survive to consumers;
  watch `byBudget` (36,825 baseline) for fan-out from newly-member-bearing keys —
  the watchdogs and μ-tie are the installed guards.
- Wall: per-wave census legs are lss-opt.md PLAIN runs (this is unflagged default-
  path work) — record one row per wave there, with `out.mlir` quoted (analysis
  change: it legitimately moves).

## §8 Invariants delta

- **LSS_022** (new; Monomorphization;LambdaSets): Under a KernelSetFacts
  `TypeFaithful` row a kernel boundary performs NO LSS_004 poison on either side —
  inference instantiates the kernel's annotation and unifies the call shape;
  translation passes the loaded scheme through untouched — the kernel's set flow
  being exactly its type's variable-sharing graph, per an audit discharging §2's
  checklist (application-only via the four sanctioned entry points, no retention,
  no fabrication/laundering, honest type), evidenced per row and pinned by the
  license-rot manifest (`kernel-license-manifest.txt` + CTest checker). A licensed
  position that receives no flow reads ⊤ at zonk (never falsely empty); the PAP and
  partial-application cases are covered by LSS_013's spine semantics. Grant rule:
  any checklist doubt ⇒ Positional or Opaque.
- Amend **LSS_021**: Positional becomes the middle tier consulted through `factFor`.
- Amend **LSS_004**: poison is the UNLICENSED default (reference LSS_022).

## Execution order and risks

Wave 0 (mechanism, zero rows, quiet battery) → wave 1 pilot (2 kernels, template
precedents) → LSS_022 + amendments → waves 2-4 incrementally, one battery + one
lss-opt.md row each → GAP-4 residue re-read (byKernel decomposition) at the end.

Risks: (1) a wrong license is a miscompile — mitigated by the checklist's grep-able
scan lists, the rejected-class firewall, per-row evidence, and the rot manifest;
(2) audit fatigue at 335 kernels — mitigated by the vacuous/cheap classes and the
heat-ordered full class (do NOT audit breadth-first); (3) licensed inference-side
instantiation adds scheme loads in the walk — once-per-global memoized inference
bounds it; watch the wave-1 census leg's wall, not the suite; (4) fan-out from newly
surviving members — `byBudget` watch, MONO_030/LSS_018 backstops.

---

# EXECUTION RECORD — 2026-08-20 (plan COMPLETE)

The audit was run in ONE pass over the whole kernel surface rather than the wave
sequence of §6. **Surface arithmetic**, since §0's "335 entry points" conflates
symbols with kernels: 392 raw `Elm_Kernel_*`/`Eco_Kernel_*` symbols (338 elm + 54
eco), minus 4 `*_register_gc_roots` plumbing exports, minus 56 `_Int`/`_Float`/
`_Char` ABI variants that are compiler-minted typed forms of ONE kernel (JsArray
30->15, Utils 30->9, Basics 39->31), minus 4 grep artifacts matching inside
comments = **328 distinct kernels, all 328 audited**. Verdicts: 197 TypeFaithful,
1 Positional, 130 REJECTED. The 193 encoded rows are 198 grants minus 4 dropped at
encode time by rulings R2/R5 (`Json.fail`, `MVar.new`, `MVar.drop`, `Basics.log`)
minus 1 merge (`Elm.Kernel.File.size` and `Eco.Kernel.File.size` share the
`(home, name)` key). **A REJECTED kernel deliberately gets NO row**: `KernelSetFact`
has no "refused" constructor, and `factFor` returning `Nothing` IS the conservative
default (LSS_004 full poison), so a refused kernel and an unaudited one must be —
and are — indistinguishable to both consumers. The audit trail for the 130 lives in
the module doc's REJECTED section and in `KernelLicenseTest`'s `neverLicensable`
tripwire, not in the table. This was one pass because a parallel survey made breadth affordable and the wave ordering
existed only to ration audit effort. Every §6 wave's content is covered; the
per-wave battery is replaced by a single battery over the whole change.

## Rulings settled during execution (these override the plan text above)

- **R1 — constrained variables.** A constrained variable is function-capable
  only if what it ranges over can itself CONTAIN a function. `number` (Int |
  Float) and `comparable` (scalars, and lists/tuples bottoming out in scalars)
  cannot ⇒ vacuous. `appendable`/`compappend` reach a bare element variable
  through their `List a` arm ⇒ cheap. §2.5 was silent on this; it is now the
  rule. (Raised by the Basics and Utils audits.)
- **R2 — nullary-constructor carriers are a syntactic auto-reject.**
  `type Task err ok = Task`, `Cmd msg`, `Sub msg`, `Decoder a`, `Expect msg`,
  `Resolver x a`, `Body`, `Part`, `Program`, `ProcessId` declare NO fields, so
  their parameters are phantom while the C++ fills them with payload. A free
  unconstrained variable passing through one of these is retention into a
  position the type cannot describe. This predicate — not prose — accounts for
  almost every refusal, and §1's escape-by-soundness floor is its consequence
  rather than its statement. (Raised by the Json and effects audits.)
- **R3 — `Task` in the type does NOT by itself refuse.** §1 says reject
  Task/effect internals on sight; §2.5 says an arrow-free variable-free type is
  vacuous. For a fully CONCRETE Task kernel (`String -> Task Never ()`) the two
  collide, and §2.5 wins: the loaded scheme has zero set slots, so poison and
  transport are both provable no-ops and the row is inert-by-construction. The
  license is then encoded as `LicenseScope = Inert`, which is the mechanism
  change below.
- **R4 — no Elm surface ⇒ no row.** `List.reverse/append/concat/take/drop` are
  injected at MLIR generation (`Generate/MLIR/Functions.elm listShuntKernels`),
  long after LSS; `Utils.cmp3` is emitted by `EcoCompareCaseRewrite` as a direct
  call; `*_register_gc_roots` is plumbing. None is ever a `TOpt.VarKernel`, so
  `factFor` is never consulted and a row would be dead weight implying coverage
  that is not exercised. §6's "List 19" over-counted the audit surface.
- **R5 — `INFERRED-FROM-USAGE` types license only in the vacuous class.** §2.1
  step 2 assumed an aliasing annotation always exists; several kernels are used
  only inline (`String.split`/`join`, `List.fromArray`/`toArray`,
  `Json.addEntry`, `Basics.log`, `Regex.infinity`). Arrow-free and variable-free
  ⇒ still grantable (the basis is recorded as weaker); anything with an arrow or
  a variable ⇒ no row.
- **R6 — manifest scope.** `files` lists KERNEL source only. Globally-sanctioned
  runtime machinery (`RuntimeExports.cpp` application entries, `HeapHelpers.hpp`,
  allocator/list-builder internals, `TaskBinding.hpp`) is excluded: shared by
  every kernel, no per-license signal, and it would rot every row on unrelated
  allocator churn. This also dissolves the Utils audit's objection that
  `Utils.append` would rot on `HeapHelpers.hpp` edits.

## Mechanism deltas vs §3

- `KernelSetFact` carries a `License { scope, files, evidence }`, not just
  `{ evidence }`. `files` feeds the rot manifest (§4 needed a machine-readable
  source and the plan left it implicit). `scope : LicenseScope = Inert |
  Transports` makes R3's "provable no-op" structural instead of a comment:
  the INFERENCE consumer skips an `Inert` boundary outright rather than
  instantiating it. Without that split, licensing ~170 concrete kernels would
  have ADDED an isolated scheme load per boundary — a fixed cost on a hot path
  buying exactly zero precision, and the inverse of §7's intent. Translation
  needs no split (pass-through is already nothing).
- §4's "wire it as a CTest" is not implementable as written: this project has no
  `enable_testing()`/`add_test`, and `--target check`/`full` run `test/test`
  directly, never `ctest`. The checker is instead a custom command in the
  default ALL graph, which both targets build — same effect, actually reached.
  It checks BOTH directions: hashes match, AND manifest coverage equals the
  declared rows (a new licensed row with no manifest entry fails loudly rather
  than going unguarded).

## Corrections to §0's ground truth

- **`core/Utils.cpp` is NOT a closure-fabrication file.** Its single
  `Tag_Closure` hit is a read-only `case` label in `eqHelp` (:713). The §0 list
  was built by a grep that could not tell a case label from an allocation. This
  false positive had been blocking `List.sortBy`, whose grant reaches
  `Utils::compare`.
- **The fabrication list was elm-kernel-cpp-only and missed `runtime/`.** Add
  `virtual-dom/VirtualDom.cpp`, `eco-kernel-cpp/src/eco/MVar.cpp`,
  `runtime/src/platform/TaskBinding.hpp` (`makeBinding` :152 /
  `makeAsyncBinding` :173 — reached by 41 of 47 eco kernels),
  `runtime/src/platform/PlatformRuntime.cpp` (:80, :826), `Scheduler.cpp:849`,
  `PortRuntime.cpp`.
- **`Scheduler::allocTask` does not exist.** The store is the free
  `Elm::alloc::allocTask` at `runtime/src/allocator/HeapHelpers.hpp:2047-2069`
  (write at :2065). §0's `Scheduler.cpp:144-162` is correct but incomplete: it
  covers the four callback constructors only, while `taskSucceed` (:123-126) and
  `taskFail` (:139-142) sit outside it. Correct citation:
  `Scheduler.cpp:123-162`.
- **`VirtualDom` refuses wholesale, not just its event handlers.**
  `VirtualDom.cpp:390` holds a never-freed `static std::vector<VNodePtr>
  vnodeRegistry` and every VNode-producing kernel returns a `Custom` carrying
  only an INDEX into it — so a `Node msg` value is a handle into runtime storage.
- **`Debug` belongs on the never-license list** (§6 omitted it), on lowering
  shape: `Debug` is the one family excluded from per-reference var freshening
  (`Translate` `remapWanted`), it lowers to a bespoke `eco.dbg` op, and
  `Debug.toString`'s export is arity 2 against Elm arity 1 because the compiler
  injects a `type_id` it then ROUTES on — a hidden state argument, which §2.1
  step 2 should name as disqualifying in its own right.
- **`elm/browser` is not installed**, so its 30 kernels have no type source and
  cannot be audited at all, independent of the reject class.
- Scale corrections: Json is 35 exports / 32 kernels (not 38); Bytes is 26 (not
  29); several `_Int`/`_Float`/`_Char` ABI suffixes inflated §0's counts.

## Hazards recorded, not fixed

- **Elm-annotation drift.** A row claims things about the C++ *and* the type,
  but the manifest hashes C++ only. An `Inert` row whose annotation later gains
  an arrow or a variable is a claim nobody re-checked. Recorded in the module
  doc as a re-audit trigger; a type-side pin would need the compiler to read
  package sources at build time.
- **One name, several types.** `factFor` is keyed by `(home, name)` while
  `String.fromNumber` is reached through two aliasing annotations and `Http.pair`
  through five. The CONSUMERS are safe (they read the occurrence's own
  solver-inferred type, `LocalOpt/Typed/Expression.elm:417`), but the AUDIT must
  cover every annotation a name can carry. §3.1 should say so.
- Incidental defects found and NOT fixed here (each needs its own change):
  `Json` `makeErr` builds `Failure` with `ctor = 0` (JsonExports.cpp:142) so
  every decode error is malformed; `Json.Value` has two incompatible runtime
  representations; `Regex.infinity` returns `double +inf` where its call sites
  want an `Int` limit; `Bytes.decodeFailure`/`getHostEndianness` have
  zero-parameter exports against arity-2 Elm types;
  `Elm_Kernel_Platform_sendToApp` returns `void` against `-> Task x ()`;
  `Http.emptyBody` allocates a live 0-field `Tag_Custom` (illegal under
  HEAP_044); three `VirtualDom` sanitizers are ineffective
  (`noJavaScriptOrHtmlJson` performs no check at all).

## Delivered

**Table: 193 rows** — 192 `TypeFaithful` (158 `Inert`/vacuous, 34 `Transports`:
15 cheap + 19 full) and 1 `Positional` (`Bytes.decode`). By home: String 29,
Basics 29, File 25, Bytes 24, JsArray 14, Json 10, Utils 8, Parser 7, List 7,
Bitwise 7, Regex 6, Char 6, Process 4, Http 4, Console 4, Url 2, Runtime 2,
NativeDriver 2, Env 2, Crash 1. All six v1 positional rows (map2-5, sortBy,
sortWith) were re-audited to the full checklist and PROMOTED, plus `List.cons`.
The rot manifest pins **310 (kernel x file) pairs** over 39 C++ files.

**Refusals** (no row, LSS_004 keeps its full poison): all of Browser (22),
VirtualDom (25), Debugger (8), the Scheduler/Platform/Process effect surface,
all Json `Decoder` combinators (21 of Json's 32), `MVar` read/take/put/new/drop,
`Runtime.saveState`/`loadState`, all three `Debug` kernels, and the R4/R5
no-Elm-surface and inferred-type-with-arrows cases.

**Tests.** `compiler/tests/TestLogic/Monomorphize/KernelLicenseTest.elm`, 8
tests: two transport pins through the real solver (`List.cons` licensed
transport; the same kernel PARTIALLY applied, which pins §1's "no arity rule"
claim — an arity-aligned positional row would have bailed to full poison there),
and six containment/discipline pins (the never-license list stays unlicensed;
unknown kernels have no row; every licensed row pins a file; evidence carries
the §2.6 markers; `scope` agrees with the evidence class; `licensedFiles` is
sorted, deduped and repo-relative). Plus `test/elm/src/KernelLicenseTest.elm`,
whose seven CHECKs are chosen so a false singleton yields a different NUMBER
(two callbacks through one `List.map2`; a `List (Int -> Int)` argument; a
`List.sortBy` permutation of two closures keyed against source order; two
`String.map` callbacks; `String.foldr`).

Two §5 tests could not be built as specified, and the reason is worth recording:
the mock interface env synthesizes annotations only, so kernel-alias globals
route to widened all-⊤ demands and only DIRECT argument positions can carry a
member (`Translate.injectArgLambdaMember` matches per argument EXPRESSION, so a
global inside a list literal contributes nothing). §5 test 1's `map2`-with-a-
named-callback fixture therefore reads ⊤ in the unit env both before and after
the license, and §5 test 2's negative control has no unlicensed kernel-alias
within reach. Both moved to table-level pins plus the E2E fixture.

**Gates.** `--target full` 1684/1684. elm-tests 13,141 passed / 12 failed — the
same 12 pre-existing typechecker-parity failures (node types grounded / node
vars constrained / if-chain), none in this area. The rot guard was verified to
FAIL a build on a real edit to `ListExports.cpp` (naming every affected kernel)
and to go green again on revert, and to fail on a dropped manifest pin.

## Census outcome (benchmarks/lss-opt.md Run Y)

**§7's counter prediction is confirmed exactly; its precision prediction is not.**

`widenedByKernel` 4,065 → **1,575**, with the new `kernelLicensed` reading **2,490** —
and 4,065 − 2,490 = 1,575 to the unit. Every licensed boundary previously took the
rowless full poison and now poisons nothing, so `byKernel` has become the sharp
number §7 wanted: arrow-carrying UNLICENSED boundaries only. `kernelFactHits` falls
169 → 12, which is now exactly the `Bytes.decode` positional applications.

**Precision is unmoved.** Singleton sets 64,311 → 64,311; `devirtDirect` 4,000 =
4,000; `dispatchUpgraded` 3,570 = 3,570; `byBudget` 36,825 → 36,822; grounding
5,014/11 unchanged; `multiSetSites` unchanged. §7 expected singletons up at
kernel-adjacent sites and `devirtDirect`/`dispatchUpgraded` up where callback sets
survive — none of that happened, and the reason is structural rather than a bug:

- 158 of 192 licensed rows are `Inert`. Their schemes have zero set slots, so the
  poison they no longer perform was already a no-op. They move `byKernel` and
  nothing else, BY CONSTRUCTION. That is most of the 2,490.
- Of the 34 `Transports` rows, the member-bearing position that actually carries
  traffic on this workload — the callback of `map2-5`/`sortBy`/`sortWith` — was
  ALREADY `PSFApplies` under the v1 positional rows. The license additionally opens
  their `List a` element and result positions, plus `List.cons`, `JsArray.*` and the
  `String` HOFs, and on the self-compile no member reaches any of them.

So the delivered value is the audit and the sharpened residue, not throughput: wall
+1.5% on a +0.68% larger corpus with majors 13 = 13 and promoted −0.34% is FLAT by
the file's protocol. **The honest read for GAP-4 is that kernel poison was not the
binding constraint on this workload** — 1,575 arrow-carrying unlicensed boundaries
remain, and that is now a measurable, decomposable number rather than a mixture.
Anyone hoping to convert this into precision should start by asking which of those
1,575 carry members at all, not by licensing more kernels.

## Follow-on: occurrence verification (2026-08-20, same day)

The plan trusted the audited type implicitly. That is not enough, and the reason
is one line in the constraint generator:

    Can.VarKernel _ _ _ ->
        IO.pure CTrue            -- Type/Constrain/Typed/Expression.elm

**The typechecker emits NO constraint for a kernel reference.** An annotated
kernel is bounded only indirectly, through its aliasing def; an UNANNOTATED one
is typed entirely by its context, so its "inferred" type is first-usage-wins
bookkeeping, not a property of the kernel. R5 refused those on instinct; this is
the mechanism behind the instinct.

`LicenseScope` therefore now carries a proof obligation, discharged by
`KernelSetFacts.licenseApplies` before either consumer may skip the poison:

| scope | obligation | why |
|---|---|---|
| `Inert` | re-derive "no function-capable position" from the OCCURRENCE type | the only guard against Elm-annotation drift — the rot manifest hashes C++ and cannot see a signature grow an arrow |
| `Transports` | none | an aliasing annotation already bounds every occurrence |
| `TransportsAs shape` | occurrence must be an instance of the declared shape | nothing else bounds an unannotated kernel |

Failure falls back to full poison — fail-safe, never fail-stop. The translation
side is where it earns its cost: arg unification has already run there, so a
wrongly-applied license leaves the caller's real members standing in a slot the
kernel may not honour, which is the populated-but-incomplete hazard exactly.

### Measured, then acted on

A differential probe (three one-module programs through the Stage-1 compiler
with `ECO_MONO_LSS_REPORT=1`, diffing `byKernel`/`kernelLicensed`) was used
instead of assuming, and it overturned two of the three intended rows:

- **`List.fromArray` / `List.toArray` are NOT licensable and stay rowless.**
  Their only call sites are hardcoded in elm/core's `String.elm`, and
  `Elm.Kernel.String.split` is `CTrue` too, so the non-`List` side is an
  UNSOLVED VARIABLE at the only occurrence. Bisecting the shape proved it: the
  `List a` half matched, `Array` failed, `JsArray` failed, a bare variable
  matched. There is no auditable type basis, so R5 stands. A declared type
  cannot manufacture one — that would be loosening a soundness check until it
  stops firing.
- **`Json.addEntry` IS licensed, at a deliberately weak shape.** Same cause: the
  accumulator and result are distinct unsolved variables (`emptyArray`/`wrap`
  are `CTrue` as well), so a shape naming `Value` or repeating `a` verified
  against nothing and the row silently never applied. The shipped shape asserts
  only arity plus first-parameter-is-an-arrow. With no declared sharing the
  license claims no TRANSPORT — only that the kernel adds and retains nothing,
  which is precisely what B1/B2/B3 establish; unwritten result positions read ⊤.
  Effect on a `Json.Encode.list` call: `byKernel` 10 → 8, `kernelLicensed`
  1 → 3.

**Correction to an earlier claim in this conversation:** "a user program
converting an `Array (Int -> Int)` hits `fromArray`" is FALSE. `Array.toList` is
`foldr (::) []` — ordinary Elm that never touches the kernel — and
`Elm.Kernel.*` syntax is legal only inside kernel-package source. No Elm program
can put a functional element through those two kernels, so no E2E test can
exercise that path, and the fixture says so rather than implying otherwise.

Tests: `KernelLicenseTest` gains four pins (9-12) on the verification itself —
`Inert` refused at a function-capable occurrence including a phantom variable,
declared-shape instance matching with `TsVar` consistency enforced, the shipped
`Json.addEntry` shape, and a structural check that no `TransportsAs` shape is a
non-function. E2E fixture `KernelLicenseDeclaredTest` drives two distinct
encoders through the licensed `addEntry` boundary and pins `String.split`/`join`
behaviour through the still-poisoned one. Gates: `--target full` 1685/1685,
elm-tests 13,145 / same 12 pre-existing.
