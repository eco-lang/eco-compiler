# Pre-mono LSS transforms — 04: alias forwarding

**Status:** **v1 SHIPPED DEFAULT-ON (2026-09-14, bootstrap 8c fixed point byte-identical — §7.3);
the `fast → typed` shift it exposed is ROOT-CAUSED and FIXED (`CGEN_080`)** — §5 steps 1-7 done (`ECO_INLINE_ALIAS_FORWARD=1`,
hash `afwd=`), unit 31/31, elm-tests at the 12-failure baseline, E2E 1727/1727 in both arms on the
narrowed `CGEN_080` compiler, bootstrap fixed point in both arms. Runs 11/12 showed `gen` neutral but
`fast` −21 M / `typed` +28 M; §7.1-7.2 attributed that to an EMISSION gap in `Expr.generateCall`
(stamps ignored on `CallDirectKnownSegmentation` calls of closure values), pre-existing and wider
than forwarding. Fixed; Runs 13/14: the fix alone recovers 16.9 M `fast` at the defaults, and with
it forwarding is `gen` −0.16 %, `fast` +4.9 M, `typed` +1.6 M, `out.mlir` −0.36 %, wall flat —
neutral-to-positive on every counter. Flipped default-on the same day (§7.3). Two plan claims were refuted by the flag-on E2E arm
and rebuilt as guards (R2: `abiFixed`; placeholder metas: `callsKeptKernelMeta`) — see §4 R2. **v2 (kernel-alias VALUES) designed 2026-09-14, §10; v1 amended the same day for
under-applied kernel calls (§3.2).** Item 4 of `plans/pre-mono-lss-transforms.md`.
**Origin:** `/work/pre-mono-transformation.md` §1.3 R3 and `scratchpad/q1-premono-completeness.md`
§2 R3. **Depends on:** item 0 (the pre-mono pipeline runs on `TOpt.GlobalGraph TypeIds.MVarId`
with `AssignMVarIds.GlobalMVarState` threaded; this pass is slot 2, FIRST after assignment).

## 1. Problem

`MonoInlineSimplify` inlines ≈35,100 of its 66,301 self-compile inlines (53 %, MEASURED — the LATE
`inlinedByCallee` census joined against alias-shaped globals) into callers of parameter-less
alias definitions: `Basics.add = Elm.Kernel.Basics.add` (`~/.eco/…/elm/core/1.0.5/src/Basics.elm:169`),
`eq = Elm.Kernel.Utils.equal` (`:349`), `append = Elm.Kernel.Utils.append` (`:511`),
`List.cons = Elm.Kernel.List.cons` (`List.elm:107`), `Task.succeed/andThen =
Elm.Kernel.Scheduler.*` (`Task.elm:79/208`), `Doc.fromChars = P.text` (`Reporting/Doc.elm:95`),
`Leijen.text = P.string` (`Leijen.elm:240`), `Bytes.Encode.*`. At the 2.43× per-spec multiplicity
that is ≈14k SOURCE call sites (INFERRED).

The pre-mono inliner never sees them: `InlineSimplify.bodyOf` (`InlineSimplify.elm:809`) admits
only `Define`/`TrackedDefine` whose body is a `Function`/`TrackedFunction`, and `buildCandidates`
refuses `List.isEmpty params`. So in the EARLY arm every `Basics.add x y` stays a call to a
one-line wrapper whose spec then calls the kernel — and LSS keys its `g|` member on the WRAPPER.
Forwarding is not inlining: it is reference substitution, needs no type reasoning, creates no
nodes, and is what makes the EARLY arm comparable in COVERAGE to LATE (66k = 27,130 source sites ×
2.43; a complete pre-mono pass tops out near the source-site count).

## 2. Representation — VERIFIED BY READING

- A top-level definition whose body is a bare reference is `TOpt.TrackedDefine region expr deps
  meta` (`LocalOpt/Typed/Module.elm:577`, every user def) or `TOpt.Define expr deps meta`
  (`:236`, synthesized wrappers). The body is `TOpt.VarGlobal region g meta` for a foreign or
  same-module global (`LocalOpt/Typed/Expression.elm:28,38` — `Names.registerGlobal`),
  `TOpt.VarKernel region kernelPrefix home name meta` for a kernel (`:35`,
  `Names.registerKernel`), or `TOpt.VarCycle region home name meta` for a member of a recursive
  family (`:12,:25`).
- **`TOpt.Link Global` (`TypedOptimized.elm:467`) is NOT an alias.** It is produced in exactly two
  places: effect managers (`Module.elm:294`, `TOpt.Link fx` for `command`/`subscription`) and
  cycle members (`:615`, `addLink home (TOpt.Link cycleName)`). Consumers follow it to the target
  node (`Specialize.elm:1661`, `Translate.elm:2692,2717`, `LssInfer.elm:562,2587,2722`). Aliases
  do not lower to `Link`; there is nothing here to build on for the global→global case.
- **LSS already has a KERNEL-alias notion, and this plan must be consistent with it.**
  `LssInfer.kernelAliasOf` (`LssInfer.elm:2713-2725`) recognises exactly
  `Define (VarKernel …)`, `TrackedDefine _ (VarKernel …)` and a `Link` chased to either — it is
  the E9.2 identity fold (LSS_016): a kernel-alias global passed as a value mints the KERNEL's
  `k|home.name` member, not a `g|` member, because "a split g|/k| identity would join to a 2-set
  and kill singleton consumers" (`Translate.elm:4432-4436`). It is consulted at
  `Translate.elm:4444` (argument injection), `Monomorphize.elm:3316` (census),
  `licensedKernelAliasNode` (`Monomorphize.elm:4715`, LSS_022 parametricity licence read off the
  alias DEFINITION's kernel meta), and `rootLamOf` excludes kernel-alias globals
  (`Engine.elm:471`). **It does not recognise `Define (VarGlobal g)`** — the global→global case
  (`Doc.fromChars`, `Leijen.text`) is the genuinely new part.

## 3. Design

### 3.1 The alias map

```elm
type Target = ToGlobal TOpt.Global | ToKernel Name Name Name   -- kernelPrefix home name

aliasMap : TOpt.GlobalGraph MVarId -> Dict String TOpt.Global Target   -- keyed by toComparableGlobal
```

Admitted SOURCES: a `Define`/`TrackedDefine` whose body is EXACTLY `VarGlobal _ g _` or
`VarKernel _ p h n _`. NOT admitted: `VarCycle` targets (the target is a recursive family behind
a `Link`; `kernelAliasOf` never returns `Just` for one either — `Translate.elm:4516`), `VarEnum`/
`VarBox` (constructor references — a `Ctor`/`Enum`/`Box` node is its own identity and mono
specializes it via `specializeCtorViaScheme`), `VarDebug`, ports (`PortIncoming`/`PortOutgoing`
nodes are never sources; they may be TARGETS and that is fine — the original body already
referenced them), `Manager`, `Kernel` and `Cycle` nodes, anything whose body is not a bare
reference. **v2, stated not built:** the η-wrapper `Function ps (Call (VarGlobal g) ps')` with
`ps ≡ ps'` and identical metas (this is what item 1's η-expansion may CREATE; if it does, run
this pass again after it — cheap — or teach item 1 not to wrap an alias).

Chains resolve to a fixpoint with a visited set: `f = g, g = h` ⇒ `f ↦ h`. An alias cycle
(`f = g, g = f`) cannot appear as two `Define`s — the front end emits a `Cycle` node — but the
visited set refuses it anyway and counts `afwd.cycles`. Depth is reported.

### 3.2 The rewrite, by position

| position | shape | rewrite | v1? |
|---|---|---|---|
| CALL | `Call r (VarGlobal fr f fMeta) args` | `Call r (VarGlobal fr g fMeta) args` / `Call r (VarKernel fr p h n fMeta) args` | **yes**, both target kinds — `ToKernel` only when SATURATED (amendment below) |
| ARGUMENT / value | bare `VarGlobal fr f fMeta` anywhere not in callee position | `VarGlobal fr g fMeta` / `VarKernel fr p h n fMeta` | **yes for `ToGlobal`; `ToKernel` v1 NO (§4 R6), v2 YES under §10.2** |
| the alias definition itself | `Define (VarGlobal g …)` | untouched | — |

**Call position, `ToKernel`, UNDER-APPLIED — v1 amendment (2026-09-14).** Forward a kernel-target
call only when it is EXACTLY saturated: `List.length args == arrowSpine (kernel meta tipe)` (the
same spine `declaredArityGo`'s kernel-alias arm reads, `LssInfer.elm:2629`; the built pass uses
`==`, not `>=` — an over-applied call is kept too and counted `callsKeptKernelOver`, because
`translateKernelCall` peels exactly the argument count and a written-out kernel call is never
over-applied). Reason:
the `p|` PRODUCER write `injectPapMember` runs only inside `translateGlobalCallSlow`
(`Translate.elm:3389`); `translateKernelCall` (`:3687`) derives the ABI and peels the result and
injects nothing. So a partial `Call (VarGlobal Basics.add) [x]` mints `p|Basics.add|1` on its
residual today and would mint NOTHING once forwarded. R6's "a call mints no member at all" is
true of a saturated call only. Not a miscompile — the un-written residual slot is flex, and
flex joins as `LPartial` (never-singleton) or reads `var`, both declines — but it is a
producer-side member loss that the coverage gate counts as `var`, and it is exactly the
identity §10.3 needs to exist. Kept sites are counted (`callsKeptKernelPartial`). Keeping SOME
calls of a kernel alias unforwarded does not split its identity: the head is `k|` through
`kernelAliasOf` either way, and a saturated call mints nothing either way.

**Why the CALLER-SIDE meta `fMeta` is kept, and is right.** Two consumers, two arguments:

- *Call position.* `translateCall` (`Translate.elm:1942-1962`) does not classify the callee from
  the reference meta at all: it calls `lookupAnnotation global` (`:8090`, a lookup of
  `s.env.annotations` BY GLOBAL) and uses the callee's own `Forall _ annType`; `funcMeta.tipe` is
  only the fallback when no annotation exists. After forwarding the lookup key is `g`, so `g`'s
  own scheme — with `g`'s own `MVarId`s, exactly what `translateGlobalCall`'s instantiate-and-
  unify expects — is used, and `fMeta` is never read. For a kernel target `translateKernelCall`
  (`:3654-3690`) derives the ABI from `funcMeta.tipe` AND the args (`deriveKernelAbiTypeCall`,
  `:3725`): the caller's instantiation of `add : number -> number -> number` at
  `Int -> Int -> Int` is precisely the type a direct kernel call written in `elm/core` carries.
- *Argument position.* `translate`'s `VarGlobal` arm (`:601`) calls `translateVarRef expr region
  global meta.tipe` (`:1847`) — here the meta IS used, as the reference's instantiation. `f` and
  `g` have the same type up to alias NAMES (`Doc` vs `P.Doc`), and `Store.loadType` expands
  `Can.TAlias` (`Store.elm:473-476`, `Filled`/`Holey` arms) before classification, so the caller's
  instantiation of `f`'s type classifies identically as an instantiation of `g`'s.

**Why NOT the alias body's meta.** That meta is `g`'s scheme instantiated in `f`'s OWN
environment — it mentions `f`'s binders' `MVarId`s, which are meaningless in the caller's
`SchemeEnv`. Using it would be exactly the shared-variable collapse §12 of the inliner plan spent
a day on.

**Argument position, `ToGlobal`: LSS-positive and consistent.** The `VarGlobal` injection arm
(`Translate.elm:4424-4470`) mints `standaloneArgMember ("g|" ++ toComparableGlobal g)` and then
`injectPapSuccessors g` and the M3.3 signature walk — all keyed by the global. After forwarding
those key by `g` instead of `f`; the PAP producer side `injectPapMember global …`
(`:4649`) sees `g` too, because CALL-position PAPs of `f` are forwarded by the same pass. A HOF
keyed on `g|f` would otherwise get `f`'s body — a call to `g` — as its spec (`g2global`); keyed on
`g|g` it gets `g`'s body directly. One indirection removed, identity unchanged in kind.

### 3.3 Completeness per alias — the one hard rule

**Every reference to an admitted alias is forwarded, or none is.** A partially-forwarded alias
would split its identity into `g|f` and `g|g` — the LSS_016 2-set that kills singleton consumers.
So the walk covers EVERY node kind that holds expressions: `Define`, `TrackedDefine`, `Cycle`
(both `valueDefs` and `funcDefs` bodies), `PortIncoming`, `PortOutgoing`. `InlineSimplify.
rewriteNode` (`:1119-1157`) skips `Cycle` because inlining INTO a recursive family is refused —
that reason does not apply to reference substitution, and this pass must not inherit the skip.
The `ToKernel`/argument exception (§3.2) does not split anything: those references keep the `g|f`
key, and `kernelAliasOf` folds it to `k|` exactly as today, while call positions become direct
kernel calls that mint no member at all.

### 3.4 `deps`

`Define expr deps meta`'s `deps : EverySet Global` is read by the subst engine
(`Specialize.elm:1623`) and by `InlineSimplify.recursiveGlobals` (SCC over deps). After forwarding
a call in body `b` from `f` to `g`, insert `g` (or `toKernelGlobal home` for a kernel target —
`TypedOptimized.elm:350`, which is how `Names.registerKernel` records kernel deps) into `b`'s
`deps`; do not remove `f` (harmless over-approximation, and the alias may still be referenced in
an argument position). This keeps recursion detection sound for a forwarded self-reference
through an alias (`f = g` inside `g`'s own family is a `Cycle` and excluded anyway).

### 3.5 What is left behind

The alias definitions stay in the graph. Monomorphization is demand-driven from `main`
(`MonoSolver/Monomorphize.elm:100-125`: `enqueueSpec` from the entry point; an unreferenced global
is never specialized), and `plans/prune-unreachable-specializations.md` prunes by `callEdges`
post-mono. A fully-forwarded `ToGlobal` alias therefore produces no code; a `ToKernel` alias is
still referenced from argument positions (§3.2) and specializes as today.

### 3.6 Pipeline and config

- Slot 2 of `Generate.runMonoOptPipeline` (`Generate.elm:741-772`), immediately after
  `AssignMVarIds`, before `EtaExpand`: item 1 reads the callee's declared arity, and after
  forwarding it reads `g`'s (a kernel target's arity comes from the kernel's meta type, which the
  forwarded reference carries). The inliner then sees `g`'s `Function` body in `bodyOf`, so its
  candidate set changes — expected, and measured (§7).
- `Compiler/Eco/Config.elm`: `aliasForward : Bool` on `InlineConfig` next to `preMono` (`:998`),
  default `False` (`:1091`), decoder `D.optionalField "aliasForward" D.bool …` (`:1207`), hash
  token `"afwd=" ++ …` beside `"preInl="` (`:1451`). `Builder/Eco/Config.elm`: register the env
  read beside `ECO_INLINE_PRE_MONO` (`:367`) and copy `applyInlinePreMonoOverride` (`:1797-1809`)
  verbatim as `applyInlineAliasForwardOverride` — record UPDATE via the `inline` setter, never a
  literal.
- `Compiler/GlobalOpt/PreMono/AliasForward.elm` exposes `run : Config.InlineConfig ->
  GlobalMVarState -> TOpt.GlobalGraph MVarId -> ( TOpt.GlobalGraph MVarId, GlobalMVarState,
  Metrics )` and `emptyMetrics`. State passes through untouched — this pass mints nothing (§4 R7).

## 4. Adversarial review

**R1 — "the reference meta must be the callee's own scheme."** FALSE for call position:
`translateCall` fetches the annotation by global (`:1942-1962`). TRUE-but-harmless for argument
position: `translateVarRef` uses the instantiation, which is the same for `f` and `g` after alias
expansion (`Store.elm:473-476`). *Resolution:* keep `fMeta`; pin with a unit test whose alias is
typed through a type alias (`Doc`) and an E2E test that USES the forwarded value at two
instantiations.

**R2 — kernel `_Int`/`_Float` variant selection.** `kernelInstanceSymbol` (`KernelAbi.elm:182`)
keys on `KernelInstanceKey { argTypes, resultType }`, which the MLIR call site builds from the
Mono call's argument and result types (`Generate/MLIR/Expr.elm:966-990`), and those come from
`translateKernelCall`'s `deriveKernelAbiTypeCall kernelId funcCanType args` — the caller's
instantiation plus the actual args. ~~Forwarding changes neither.~~ **REFUTED 2026-09-14 by the
flag-on E2E arm (44 failures: every `Task`/`Process`/`Http` fixture, `String.foldl`, ports).**
`KernelAbi.deriveKernelAbiMode` decides boxing from the OCCURRENCE type: in the alias body the
kernel's own variables (`succeed : a -> Task x a`) give `PreserveVars` — boxed `eco.value`
placeholders — while a forwarded call carries the caller's concrete `Int -> …` and derives
`i64 -> eco.value`. A kernel symbol is registered by NAME with one ABI, so the compiler crashed
with `Kernel signature mismatch for Elm_Kernel_Scheduler_succeed: existing (eco.value ->
eco.value) vs new (i64 -> eco.value)` where the register caught it and SIGSEGV'd where it did
not. This is precisely the lesson `InlineSimplify.polyKernel` records for the inliner; forwarding
bypassed that guard. *Resolution (BUILT):* `ToKernel` carries `abiFixed` = `deriveKernelAbiMode`'s
rule read off the alias body's kernel meta — no free type variable, OR a suffix-selecting kernel
(`KernelAbi.suffixSelectingKernels`: `Basics.add/sub/mul/pow`, `List.cons`, `Utils.equal/compare/…`,
whose ABI is the concrete instantiation on BOTH paths), never `Debug` — and a call is forwarded
only when `abiFixed`; the rest keep the alias and count `callsKeptKernelPoly`. Differential unit
pins: `pick = Elm.Kernel.Basics.identity` at `a -> a` kept; `cons = Elm.Kernel.List.cons` forwarded.
The E2E pin's `plus = (+)` at `Int` AND `Float` exercises the suffix-selecting path.
**Second refutation, same arm, same day:** with `abiFixed` in place ONE fixture still failed —
`OutgoingPortTuple3Test`, `Kernel signature mismatch for Elm_Kernel_Json_wrap: existing ( ->
eco.value) vs new (eco.value -> eco.value)`. The typed port encoder (`LocalOpt/Typed/Port.elm`,
`encode`) registers its `Json.Encode.string` reference with a PLACEHOLDER meta `Can.TVar "string"`.
§3.2's "the caller's meta is right" holds for references the front end typed, not for synthesized
ones: harmless through the by-global lookup, a zero-parameter ABI once forwarded. *Resolution
(BUILT):* a kernel call is forwarded only when `arrowSpine fMeta.tipe == spine`; the rest keep the
alias and count `callsKeptKernelMeta`. Pinned by that E2E fixture in the flag-on arm (no unit
fixture can synthesize a port encoder).

**R3 — `Link` nodes.** Not aliases (§2). A `Link` TARGET can appear only through `VarCycle` (not
admitted) or an effect manager's `command`/`subscription` globals (bodies are `Link`, not a bare
reference — not admitted as sources). *Resolution:* no handling needed; unit test that a `Cycle`
member is not treated as an alias.

**R4 — byte-identity at defaults.** Flag off ⇒ the pass is not invoked; the graph is untouched;
but the hash token must be present so a flag-on artifact is cache-disjoint. *Resolution:* the
standing byte-identity gate plus a `grep afwd=` on the config hash.

**R5 — interaction with item 1 and the inliner.** Item 1 wants `g`'s arity — that is the point of
running first. The inliner's `bodyOf` now admits `g`; its `polyKernel` guard (a kernel call whose
type is still variable) still declines kernel-bodied candidates, so forwarding to a kernel does
NOT make the inliner copy kernel calls. If item 1 wraps an alias into `Function ps (Call …)`, that
is the v2 shape of §3.1 — run this pass before item 1 (as specified) and the wrap never happens
to an alias that was already forwarded away.

**R6 — kernel aliases in ARGUMENT position lose LSS precision if forwarded.** The `VarGlobal`
alias arm (`:4424-4470`) mints the `k|` head AND `injectPapSuccessors` keyed by the alias AND the
M3.3 referent-signature walk; the bare `VarKernel` arm (`:4538-4547`) mints the `k|` head only and
is gated on `lss.injTotal`. LSS_022's licence (`licensedKernelAliasNode`, `:4715`) is read off
the alias DEFINITION's kernel meta, which a direct `VarKernel` reference does not go through.
*Resolution:* v1 does not forward `ToKernel` aliases in argument position (§3.2); the census
counts how many such references exist (`argRefsKeptKernel`) so v2 can be sized. Call positions
are forwarded for kernels: a SATURATED call mints no member and `translateKernelCall` is the same
code a direct kernel call runs (under-applied calls: §3.2 amendment). **Re-read 2026-09-14 — §10.1:
of the three losses this review cites, the head mint is IDENTICAL in both arms, the licence is
vacuous once the alias is unreferenced, and the PAP successors stamp ZERO sites today. v2 forwards
these values under §10.2.**

**R7 — the item-0 discipline.** This pass constructs no `Function` and no new arrow: the only
node it builds is `VarGlobal fr g fMeta` / `VarKernel fr p h n fMeta` with the CALLER's existing
meta, whose `TLambda` slots already carry the caller's `ArrowId`s — right by construction, because
the reference is the caller's. No `mintNewNode` call; `assertMinted` must pass unchanged.
*Resolution:* assert in the unit test that the rewritten reference's meta is `==` the original's.

**R8 — Cycle bodies.** Forwarding INSIDE a `Cycle` node's defs is required by §3.3; the inliner's
skip is not a precedent. *Resolution:* unit test — an alias referenced from inside a recursive
function is forwarded.

## 5. Lowered steps

| # | change | files | gate |
|---|---|---|---|
| 1 | **DONE 09-14.** Config: `aliasForward` field (appended LAST — the decoder is positional), default `False`, decoder row, hash `afwd=` beside `eta=`; env `ECO_INLINE_ALIAS_FORWARD` via `applyInlineAliasForwardOverride` | `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm` | `afwd=0` at defaults ⇒ one cache-key change, as `eta=` did |
| 2 | **DONE.** `AliasForward.aliasMap`: admits `Define`/`TrackedDefine` with a bare `VarGlobal`/`VarKernel` body (flags decoder excluded); chases chains with a visited set; `chainsMax` = hops (`f = inc` is 1); `ToKernel` carries the kernel's arrow spine | `Compiler/GlobalOpt/PreMono/AliasForward.elm` | unit F2: 3-link chain → `h`, `chainsMax = 2`, `cycles = 0`; `inc` not an alias |
| 3 | **DONE.** The walk over `Define`, `TrackedDefine`, `Cycle` (values + defs), both ports; alias-source nodes untouched; call position forwards `ToGlobal` always and `ToKernel` only at exact saturation (§3.2 amendment); value position forwards `ToGlobal` only; `deps` extended per §3.4 | same | unit F1/F3-F8 |
| 4 | **DONE.** Metrics + `pre-afwd:` / `pre-afwd-census:` line under `inline.report` (top-20 targets) | same, `Builder/Generate.elm` `renderPreAliasForwardReport` | — |
| 5 | **DONE.** Slot 2 of `runMonoOptPipeline` (before η), called when the flag OR `inline.report` is on; state passes through untouched | `Builder/Generate.elm` | `assertMinted` unchanged by construction (no mint); EARLY-arm compile: pending with step 7 |
| 6 | **DONE.** Unit 28/28 (the harness's `wrapWithMain` adds alias-shaped nodes, so counts are membership-based, not absolute); E2E fixture with six CHECK lines (chain through `(+)` → `Basics.add` → kernel at `Int` AND `Float`, partial kept, kernel value kept, `ToGlobal` at two instantiations) | `compiler/tests/TestLogic/GlobalOpt/AliasForwardTest.elm`, `test/elm/src/AliasForwardTest.elm` | elm-tests = 12-failure baseline exactly; E2E both arms: in progress |
| 7 | Measurement §7 | this file §7, `benchmarks/call-stats.md` Runs 11/12 | **DONE**: steps 1-4 on the self-compile; verdict not a dispatch win (`gen` neutral, `fast → typed` shift); stays default-off |

Size: ~250 lines Elm for the pass (the walk is the bulk; it is `InlineSimplify.rewriteExpr`'s
shape minus the inlining arm), ~40 lines of config plumbing, tests.

## 6. Tests

**Unit — `TestLogic/GlobalOpt/AliasForwardTest.elm`** (SourceBuilder fixtures through item 0's
`runToAssigned`; assertions on the returned graph, not on mono output):

| fixture | pins |
|---|---|
| `g x = x + 1; f = g; main = f 1` | `main`'s call targets `g`; `f`'s node unchanged; `f`'s reference meta `==` the original (R7) |
| `h`, `g = h`, `f = g`, `main = f 1` | chain resolves to `h`; `afwd.chains` depth 2 |
| `add = Elm.Kernel.Basics.add` via `makeKernelModule` (`SourceBuilder.elm:611`); `main = add 1 2` | call becomes `VarKernel`; `deps` gains `toKernelGlobal "Basics"` |
| `main = List.map f xs` with `f = g` (argument position, `ToGlobal`) | reference forwarded to `g` |
| `main = List.foldl add 0 xs` with `add` the kernel alias | reference NOT forwarded (R6); `argRefsKeptKernel = 1` |
| a recursive `loop` whose body calls `f = g` | forwarded inside the `Cycle` node (R8) |
| `type alias Doc = P.Doc; fromChars : String -> Doc; fromChars = P.text` used at a call and as a value | both forwarded; metas retained (R1) |

**E2E — `test/elm/src/AliasForwardTest.elm`** with CHECK lines, run in both arms and in the
`ECO_INLINE_THRESHOLD=0` leg: a local alias of a local function used at two types; a local alias
of `Basics.add` applied at `Int` and at `Float` (R2 — the `_Int`/`_Float` variant pin); an
alias passed to `List.map` and one passed to `List.foldl`; results reduced to Ints before
`Debug.log`. The existing suite in both arms is the standing gate (887/889).

## 7. Census and measurement

`pre-afwd:` fields: `aliases=` (map size) `globalTargets=` `kernelTargets=` `chainsMax=`
`cycles=` `callsRewritten=` `callsKeptKernelPartial=` `argRefsRewritten=` `argRefsKeptKernel=`
(v2: `argRefsRewrittenKernel=<arity1>/<arity2+>` `argRefsKeptKernelNonArrow=` `aliasesFullyRetired=`)
`depsExtended=`, plus a
top-20 targets list (`target=count`) mirroring `inlinedByCallee`'s rendering.

**Step 1 as MEASURED (2026-09-14), over the full dependency closure of the E2E fixture
(`AliasForwardTest` + `elm/core` + `elm/html`, 471 bodies — the item-1 §9.5 protocol), flag on:**

```
pre-afwd: aliases=192 globalTargets=15 kernelTargets=177 chainsMax=2 cycles=0
  callsRewritten=289 callsRewrittenKernel=285 callsKeptKernelPartial=1 callsKeptKernelOver=0
  callsKeptKernelPoly=156 callsKeptKernelMeta=0 argRefsRewritten=6 argRefsKeptKernel=28
  depsExtended=110 bodiesSeen=471
  top: k|List.cons=38 k|Basics.sub=35 k|Utils.equal=26 k|Utils.le=23 k|Basics.add=17 k|Utils.lt=17
       k|Basics.mul=14 k|String.fromNumber=14 k|Bitwise.and=12 k|Basics.toFloat=8 …
```

Reading: 92 % of admitted aliases are KERNEL aliases (177/192) and 98.6 % of forwarded calls go
to kernels — the census confirms §1's population is `Basics.*`/`Utils.*`/`List.cons`, and the
`abiFixed` rule (R2, refuted then rebuilt) keeps 156 of 446 kernel-alias calls (35 %): the
polymorphic non-suffix kernels (`Task.*`, `String.foldl`, `Json.*` …).

**Step 1 on the SELF-COMPILE (2026-09-14, JS-hosted `index.js make --optimize` from
`build-kernel`, heap cap 12,800 MB — the 16 GB cap the memory notes prescribe trips this box's
low-memory guard; 16:33 wall, 12.07 GB peak RSS, exit 0 — which is also §5 step 5's gate):**

```
pre-afwd: aliases=351 globalTargets=162 kernelTargets=189 chainsMax=3 cycles=0
  callsRewritten=15343 callsRewrittenKernel=8128 callsKeptKernelPartial=57 callsKeptKernelOver=0
  callsKeptKernelPoly=6050 callsKeptKernelMeta=0 argRefsRewritten=1539 argRefsKeptKernel=301
  depsExtended=2850 bodiesSeen=8225
  top: the-sett/elm-pretty-printer:Pretty.string=4485 k|Basics.add=1613 k|List.cons=1512
       k|Utils.equal=1506 elm/bytes:Bytes.Encode.U8=867 k|String.fromNumber=810
       elm/core:Dict.RBEmpty_elm_builtin=647 eco/compiler:Mlir.Mlir.opBuilder=566 k|Basics.sub=383
       eco/compiler:Text.PrettyPrint.ANSI.Leijen.dullyellow=324 k|Basics.not=319 …
```

Against the Q1 estimate of ≈14k source call sites: **15,343 calls + 1,539 values = 16,882
forwarded references** — the same order, so the admission rule and the join are not wrong by a
large factor (the estimate divided spec-level inlines by 2.43× and counted calls only). Two things
the estimate could not see: (a) the single largest target is NOT a kernel — `Pretty.string`
(4,485 sites, `the-sett/elm-pretty-printer`, aliased by `Doc.fromChars`/`Leijen.text`), i.e. the
global→global case §2 called "the genuinely new part" is the biggest single population; (b) the
`abiFixed` rule keeps 6,050 of 14,235 kernel-alias calls (42.5 %) — the polymorphic non-suffix
kernels are close to half the kernel population, and they are exactly what the wrapper spec +
post-mono inliner must keep serving. `callsKeptKernelMeta=0` on the self-compile: the placeholder
meta is a port-encoder artefact only.

**Step 2 — same-source, same-binary differential.** On the fixture closure (471 bodies):

| | flag off | flag on |
|---|---|---|
| pre-mono inliner `candidates` / `polyKernel` | 95 / 1 | 91 / 3 — kernel-bodied targets now visible and DECLINED (R5, as predicted) |
| POST-mono `inline-simplify: inlined` | 43 | **28** (−15: the alias wrappers it no longer needs to inline) |
| `post-inline-prune` pruned / kept | 15 / 31 | 11 / **28** (three wrapper specs retired) |
| `out.mlir` | 9,262 B | **9,112 B** (−1.6 %) |

The mechanism the parent plan wanted — pre-mono forwarding retiring post-mono alias inlines and
their wrapper specs — is visible at fixture scale. **On the SELF-COMPILE the flag-off arm is
BLOCKED on this box:** the JS-hosted flag-off compile hit V8's heap limit at the 12,800 MB cap
(14.6 GB RSS, `FATAL ERROR: Reached heap limit`, 13:29 in) while the flag-on arm completed at
12.07 GB — the on-arm is the smaller program. The on-arm's own numbers, for the record:
pre-mono `inlined=5485 candidates=818 polyKernel=17`, post-mono `inline-simplify: inlined=28974`,
`post-inline-prune: pruned=10216 kept=32911`, `out.mlir` 13,342,049 B (JS-hosted; not comparable
to the native-compiler sizes in `benchmarks/`). Steps 2-4 on the self-compile need the native
compiler (`bin/eco-compiler`, deleted by `--target full`; the bootstrap chain to rebuild it is
`eco-boot` → `eco-boot-2` → `eco-compiler-mlir` → `eco-compiler`) or a box with ≥ 20 GB.

**Steps 2-4 as MEASURED on the self-compile (2026-09-14, `benchmarks/call-stats.md` Runs 11/12, the
call-stats protocol: reference = subst-engine compiler emitted from THIS tree by the Sep-13 native
seed `bin/eco-pruneB`, benchmark = each arm's own emission, census-lowered; same source, same day):**

| | Run 11 `afwd=0` | Run 12 `afwd=1` | delta |
|---|---:|---:|---|
| pre-mono inliner `inlined` / `candidates` | 13,175 / 828 | 5,485 / 818 | −7,690 — the η-expanded `f = g` wrappers no longer need copying |
| post-mono `inline-simplify: inlined` | 47,127 | 28,974 | −18,153 (§1's "53 % are alias wrappers" was 35k of 66k on the Sep-10 tree) |
| `post-inline-prune` kept | 33,988 | 32,911 | −1,077 wrapper specs retired |
| `out.mlir` | 13,400,752 | 13,342,049 | −0.44 % |
| coverage `(k1+kN)/positions` | 91.13 % | 91.11 % | flat (`positions` −990 with the specs) |
| `dispatchUpgraded` / `stampedPapGlobal` | 16,723 / 3,251 | 16,765 / 3,356 | +42 / +105 |
| `declinedNoInstance` / `declinedBlocked` | 10,922 / 2,418 | 9,579 / 7 | the alias-CAF indirection sites cease to exist (consulted 35,800 → 32,212) |
| dispatch `gen` (benchmark arm) | 790,275,486 | 788,985,697 | **−0.16 %, NEUTRAL** |
| dispatch `fast` / `typed` | 1,024,559,506 / 53,252,191 | 1,003,485,083 / 80,851,589 | **−2.06 % / +51.8 %** — a tier shift against |
| `eco_closure_call_saturated` (group 4 helper) | 48,521,680 | 70,748,709 | +22.2 M, with +27.4 M GC stack-range pushes |
| direct calls into `List_map` specs | 49,493,259 | 13,007,767 | −36.5 M; post-mono `partialMerges` 419 → 1,050 |
| wall, benchmark / reference | 526.7 s / 615.4 s | 521.0 s / 621.0 s | −1.1 % / +0.9 %, FLAT at N=1 |
| bootstrap fixed point | identical | identical | both arms |

Step 3 (source-site coverage): 16,882 forwarded references against the 27,130 distinct source
sites of the P0 census = 62 % of the population the parent plan cares about, reached without a
single copy; what remains is the polymorphic-kernel population (6,050 kept calls + 301 kept values,
§4 R2) and the genuinely non-alias sites.

**Reading of step 4.** The plan predicted `declinedNoInstance` falls and dispatch NEUTRAL, wall
FLAT. All three happened — and the static declines that vanished (2,411 `blocked`, 1,343
`noInstance`) carried no dynamic weight, the site-count-vs-weight trap for the fifth time in this
arc. What the plan did NOT predict is the `fast → typed` shift. Attributed 2026-09-14 (§7.1).

### 7.1 The `fast → typed` shift, attributed

**Method.** The `[dispatch-stats] fp=` rows ARE symbolizable post hoc: the runtime prints
`anchor=eco_alloc_closure:0x…`, so `base = anchor − nm(eco_alloc_closure)` per census binary and
each `fp` (the CALLEE's evaluator) maps to its `nm -n` symbol. Spec ids, lambda ids and tail-loop
ids renumber between arms, so collapse `_$_N`, `lambda_N` and `_NNNN` before joining.

**What moved (callee-keyed, Run 12 − Run 11, exact `fast → typed` flips with `gen` unchanged):**

| callee (typed-ABI evaluator) | fast | typed |
|---|---:|---:|
| `Compiler.AST.Canonical.typeEncoderS` | −7,497,013 | +7,497,013 |
| the copied `List.map` lambda (`Terminal_Main_lambda…$cap`) | −4,411,010 | +4,414,134 |
| `MonoInlineSimplify.countUsages` | −4,365,768 | +4,387,311 |
| `Mlir.Bytecode.IrSection.encodeOp` | −797,323 | +799,845 |
| `Monomorphized.shallowLayoutKey`, `Utils.Bytes.Encode.jsonPair`, `computeCost`, `Basics.composeL`, `substitute`, `renameLocal`, `DecisionTree.edgesFor` ×2, `Tuple.mapSecond`, `exprEncoderS`, `monoTypeToLogical` | −0.12…−0.36 M each | matching |
| **sum of listed** | **−20,510,867** | **+27,461,375** |

Every one is a HOF CALLBACK (`List.map typeEncoderS args`, `foldl countUsages …`). Direct
`eco.call`s to these callees are IDENTICAL in both arms (59 for `typeEncoderS`); only the calls
through a closure value changed tier.

**The site, both arms (`Canonical.typeEncoderS` → `Encode.list (typeEncoderS tbl) args`):**

- Run 11: `%6 = papExtend(@typeEncoderS, tbl)` → `eco.call @List_map_$_11360(%6, args)`. Inside
  that keyed spec, the map lambda `lambda_8733$cap` does `papExtend(f, x)` with
  `_call_kind = "singleton_fast", _fast_evaluator = @typeEncoderS, _pap_prefix = 1` — the LSS_011 E2
  PAP-prefix stamp. Counted `fast`.
- Run 12: `List.map` is INLINED at the site. The same lambda is materialized in the caller as
  `papCreate(%6) @Terminal_Main_lambda_38412$clo` and passed to a `List_foldrHelper` spec shared
  by four copies (which still stamps `fn x acc` — LSS_009's verbatim-copy rule holds). But inside
  the copy, `papExtend(f, x)` is `_call_kind = "direct_known_segmentation"` — NO stamp — and lowers
  to `eco_closure_call_saturated` (+22.2 M in group 4, one `eco_gc_push_stack_range` each). Counted
  `typed`.
- Per-site census (`ECO_MONO_LSS_CENSUS=1` on the Run-12 binary, emission byte-identical): host
  `Compiler.AST.Canonical.typeEncoderS` → `stampedPapGlobal=5 stampedFlat=5 bucketOrLayoutMiss=4
  noInstance=1` — **four `bucketOrLayoutMiss` declines, one per inlined copy**: `papScan` (the E2
  suffix scan over the member's layout groups) finds no group in the copy, where the original site
  in the spec found one. `List_map` specs in the emission: **895 → 230**.

**Why `List.map` is inlined only in Run 12.** `inline top callees` (post-mono): Run 11 has
`List.cons=3632 Basics.add=3123 Basics.eq=2332 … List.foldr=1344` and `List.map` below the top-20
cut; Run 12 has **`List.map=880`**, `List.foldr=2221`. Forwarding rewrote the `x :: acc` inside
`map`'s lambda and `foldr`'s body from a call of the `List.cons` WRAPPER global — priced by
`computeCost` as `5 + 1 + args` — into a direct `Elm.Kernel.List.cons` call, which is the
`eco.construct.list` intrinsic and priced `kernelCostInline = 1` under `kernelCostClasses`. The HOF
bodies got cheaper, `hasCalledFunctionParam` (it folds into nested lambdas) gives `map` the
`hofThreshold = 25` budget, and ≈665 `List.map` call sites crossed it. The inliner's copy of the
callback site is not re-stamped, so the site drops from `fast` to `typed`.

**Experimental confirmation (`benchmarks/call-stats.md` Run 12a).** Run 12's binaries and flags
plus `inline.blacklist = ["List.map", "List.foldr"]` (post-mono inliner only): `fast`
1,003.5 M → **1,023.1 M** (Run 11: 1,024.6 M), `typed` 80.9 M → **57.9 M** (Run 11: 53.3 M),
`eco_closure_call_saturated` 70.7 M → 48.2 M, `List_map` specs 230 → 892, the `typeEncoderS` site
`singleton_fast` again. **≈93 % of the shift is the `List.map`/`foldr` HOF inlining**; the ≈4.7 M
residual is the same mechanism at other HOFs that crossed the budget (`Tuple.mapSecond`,
`Basics.composeL`, `Dict.foldr` …). Wall 517.9 s, the best of the three arms, still noise.

### 7.2 Root cause found and FIXED (2026-09-14): an emission gap, not a resolution miss

The `bucketOrLayoutMiss=4` under host `typeEncoderS` was a red herring — it is a different site,
present in BOTH arms. The per-site census showed the copy is `stampedPapGlobal` under host `enc`
in the on arm (it had been under host `List.map` in the off arm): **AbiCloning DID stamp the
copy**. The stamp was discarded at EMISSION. `Expr.generateCall` dispatches on
`callInfo.callKind` and consulted `fastDispatchStamp` only on the `CallGenericApply` and
`CallSegmentationUnknown` arms; the `CallDirectKnownSegmentation` single-stage-saturated branch
went straight to `generateSaturatedCall` → the typed saturated helper. `annotateExprCalls`
classifies a closure-valued call known-segmentation when the callee's construction is visible
in the same function (`envWithCaptures` records a captured PAP's source arity) — exactly the
copy's situation (`enc tbl` is built in `enc_$_4`, where the copied lambda now lives) and not
the original's (the PAP arrives as the `List_map` spec's parameter → `CallGenericApply`).

Reproduced in 30 lines (`test/elm/src/PapCopyStampTest.elm`: a recursive `enc` mapping a PAP of
itself over children) and fixed by consulting `fastDispatchStamp` on that branch too — a
direct-global callee never carries a stamp, so the intrinsic logic is reached exactly as before
for those. On the repro the copy is `singleton_fast → enc_$_4, _pap_prefix = 1` in both arms, and
the DEFAULT arm gains stamps as well (`List.map total es`'s callback sites were typed before):
**the gap predates forwarding and is wider than it** — every stamped site whose callee value is
built in the same function was emitting the typed helper. elm-tests at the 12-failure baseline;
E2E 1727/1727 in both arms (with `test/elm/src/PapCopyStampTest.elm`, which pins the fix in the
DEFAULT arm: a let-bound PAP of the recursive `enc` captured by an explicit `foldr` lambda).

**The first cut over-reached and was narrowed the same day.** Consulting the stamp for EVERY
callee shape on that branch also caught `MonoVarGlobal` callees: with LSS_031 a global's own spec
IS an instance, so a direct global call can carry a stamp, and `generateSaturatedCallNoFusion`
calls it DIRECTLY (`eco.call @spec`) — strictly better than any papExtend. On the self-compile's
`afwd=0` emission the broad cut moved `eco.call` 77,346 → 72,662 (−4,684) and `papCreate`
25,860 → 30,551 (+4,691): 4,691 direct calls per compile diverted into PAP objects. The narrowed
rule leaves `MonoVarGlobal`/`MonoVarKernel` callees on the saturated path and consults the stamp
only for closure VALUES (locals, call results, literals) — the shapes that have no direct form.
MEASURED on the self-compile's `afwd=0` emission (Run 11 → Run 13): `singleton_fast` 12,559 →
15,225 (**+2,666**), `direct_known_segmentation` 8,461 → 5,795 (**−2,666**), `eco.call` 77,346 →
77,350 (+4: the fix's own code in the corpus), `papCreate`/typed `papExtend` unchanged, `_pap_prefix`
sites 2,283 → 3,264 (981 of the recovered sites are `p|` PAP stamps), `out.mlir` +0.20 %
(fast-call attributes) — exactly the predicted shape, zero direct calls diverted (`CGEN_080`).
**Runs 13/14 (`benchmarks/call-stats.md`), the fixed compiler, same seed, both arms at a
bootstrap fixed point:**

| benchmark arm | `gen` | `typed` | `fast` | `eco_closure_call_saturated` | wall | `out.mlir` |
|---|---:|---:|---:|---:|---:|---:|
| Run 11 `afwd=0` (pre-fix) | 790,275,486 | 53,252,191 | 1,024,559,506 | 48,521,680 | 526.7 | 13,400,752 |
| Run 12 `afwd=1` (pre-fix) | 788,985,697 | 80,851,589 | 1,003,485,083 | 70,748,709 | 521.0 | 13,342,049 |
| **Run 13 `afwd=0` (fixed)** | 790,554,966 | **36,713,373** | **1,041,434,851** | 33,756,848 | 525.9 | 13,427,210 |
| **Run 14 `afwd=1` (fixed)** | **789,273,265** | 38,309,573 | **1,046,384,077** | 35,372,401 | 520.7 | 13,379,444 |

- **The fix alone (13 vs 11):** `typed` −16.5 M (−31 %), `fast` +16.9 M, `gen` +0.04 % (noise),
  runtime calls −38.7 M. The gap was costing ≈17 M fast dispatches per self-compile in the DEFAULT
  configuration, forwarding or not.
- **The fix under forwarding (14 vs 12):** `typed` −42.5 M, `fast` +42.9 M, runtime −89.7 M — the
  forwarding arm had more stamped-but-typed sites, which is why it surfaced the gap.
- **The flip decision (14 vs 13):** `gen` **−0.16 %**, `fast` +4.9 M, `typed` +1.6 M (the residual
  of Run 12's +27.6 M), `elm` direct calls −45.8 M (inlined `List.map`/`foldr` specs), wall −1.0 %
  (noise), `out.mlir` −0.36 %, specs −1,077, post-mono inlines −18,153. Forwarding is now
  neutral-to-positive on every dispatch counter and negative on nothing measured.

E2E on the narrowed compiler: 1727/1727 flag-off, 1727/1727 flag-on (`PapCopyStampTest` included).
All gates green; `bin/eco-compiler` rebuilt from Run 13's defaults emission.

### 7.3 Default flip (2026-09-14) — bootstrap fixed-point check

`aliasForward = True` in `Config.elm` (hash token `afwd=` unchanged; `ECO_INLINE_ALIAS_FORWARD=0` is
the escape hatch). Chain per `guides/bootstrap.md`: Gate A (`full`, JIT E2E at the new default)
**1727/1727**; Stages 2-4 under `ECO_MONO_ENGINE=subst` with the Node heap caps raised to 16 GiB
(`compiler/CMakeLists.txt`, six sites — a 12 GiB cap GC-death-spirals under solver+LSS, and on a
15 GB host the solver+LSS JS self-compile cannot fit at all; the JS→JS stages emit no MLIR and
finish in seconds on the shared front-end cache), Stage 4b `eco-boot-2.js == eco-boot-3.js` ✓;
Gate B (`run-aot-e2e`) **893/895** — the two failures, `FlagsRecordTest` and `PortEchoTest`,
reproduce with `ECO_INLINE_ALIAS_FORWARD=0` and are AOT-HARNESS gaps, not compiler regressions:
`test/aot_e2e_main.cpp` implements neither the `-- FLAGS:` directive nor the port echo that
`ElmE2ETestBase.hpp` (the JIT runner) wires (0 vs 10 references). Stage 5 under subst (6 min,
JS-hosted, no heap pressure); Stages 6-9 native at the default engine: **Stage 8c
`eco-compiler-boot.mlir == eco-compiler-boot-2.mlir` BYTE-IDENTICAL** (13,379,444 B — B == C at the
new default), Stage 9 `eco` linked (243 MB), 9b `eco → eco-2` self-compile succeeded. The
bootstrapped artifact differs from Run 14's measured emission in exactly ONE constant —
`Compiler_Eco_Config_default`'s `aliasForward` literal, `arith.constant false → true` (4 diff lines
of ~1 M) — so the fixed point IS the measured Run-14 compiler plus the flip itself. Stage 5's
subst emission differs from the pre-flip subst reference because the pre-mono passes run under
either engine and the default is now on. The optimized native compiler at the new default is
`bin/eco-compiler-boot` (Stage 6's `bin/eco-compiler` is the subst-built, less-optimized seed).
**SHIPPED DEFAULT-ON 2026-09-14.**

**Reading (superseded by §7.2 — kept for the record).** The forwarding is correct and its own
effect is neutral; the loss is an INTERACTION with the post-mono inliner's cost model — HOF
inlining that undoes an LSS stamp is a net loss at that site, and the cost model cannot see
stamps. Two fixes were proposed before §7.2 found the real cause: (a) in
`MonoInlineSimplify`, decline the HOF inline when the callee spec contains a stamped callback site
whose copy would not re-stamp (the `preserveSets` precedent — decline the ONE reshape that clears
identity; the blacklist experiment is its ceiling, minus the `map`/`foldr` inlines Run 11 did
legitimately, which a per-site guard keeps); (b) make the E2 suffix scan succeed at the copy
(find why `papScan` misses there — the copy's callee type/layout at `f`, or the member's groups —
and repair it), which keeps the inlining AND the stamp. (b) is the better outcome if the miss is
a layout-key artefact; (a) is the smaller change. Either is what gates the flip: with the stamp
kept, Run 12's other effects (−1,077 specs, `out.mlir` −0.44 %, `gen` −0.16 %) are a net win.

Order of measurement, each on the self-compile in the EARLY arm with `ECO_INLINE_REPORT=1`:

1. The forwarding census alone (`aliasForward=1`, `preMono=0`): `callsRewritten` against the
   Q1 estimate of ≈14k source sites (INFERRED) — a large miss in either direction means the alias
   admission rule or the join was wrong; find out which before going on.
2. With the inliner (`aliasForward=1 preMono=1`): `pre-inline-simplify` `candidates`/`inlined`
   against the 1,865 baseline — the inliner now sees real callees; record the delta and the new
   `polyKernel` count (kernel-bodied targets are expected to be declined, not inlined).
3. Source-site coverage: `callsRewritten + inlined` against the 27,130 distinct source sites
   from the P0 census (`plans/pre-mono-inline-simplify.md` §8.1). This is the number the parent
   plan cares about, not the raw count against 66k.
4. Run-AT-style two-arm protocol run (`benchmarks/lss-opt.md`: one cold run per arm, census off,
   no probe) with a separate dispatch uprobe run; record LSS counters (`dispatchUpgraded`,
   `declinedNoInstance`, `stampedPapGlobal`) — the expectation is that `g|`-keyed members move to
   their targets and `declinedNoInstance` FALLS as wrapper indirections disappear. Wall is
   expected FLAT.

## 8. Risks

- **Identity split (R6/§3.3)** is the only miscompile-class risk, and it is a precision loss,
  not a wrong answer: a 2-set declines a stamp. Mitigated by all-or-nothing per alias and by
  leaving kernel-alias values alone in v1.
- **Alias-typed metas** (`Doc` vs `P.Doc`) rely on `Store`'s alias expansion. If a consumer
  compares `Can.Type`s structurally before expansion (`Translate.sameCanTypeIgnoringArrows` is
  an `==` fast path on occurrence ids), a forwarded reference's meta still carries the caller's
  ids — identical to before the rewrite — so nothing new is compared. Pinned by the `Doc` unit
  fixture.
- **Over-forwarding a value that is observed by identity.** Elm has no reference equality; a
  forwarded `VarGlobal` is semantically the same value.
- **Cost:** one walk over every node plus a fixpoint over a small map. Negligible against the
  inliner's rounds.
- **Polymorphic kernel ABI (R2, refuted then rebuilt).** The one miscompile-class defect v1 hit:
  a forwarded call/value of a polymorphic non-suffix kernel changes the kernel's registered ABI.
  Guarded by `abiFixed`; any future position class this pass forwards MUST apply the same rule.
- **v2 census misreading (§10.2).** Forwarding kernel-alias values drops `p|<alias>|d` successor
  writes that stamp nothing today, so LSS analysis-coverage `%` can FALL (those positions become
  `var`) while dispatch is flat. Gate v2 on the dispatch counter, not on coverage.

## 9. What not to do

- Do not forward `ToKernel` aliases in argument position in v1; in v2 forward them ONLY under
  §10.2's four rules (arrow-typed alias, `lss.injTotal` on, all-or-nothing, caller meta). Do not
  build §10.3 (kernel PAP identity) before §10.4's census says there are sites to win.
- Do not forward an UNDER-APPLIED kernel-alias call (§3.2 amendment): that deletes the only
  `p|` producer write for its residual.
- Do not use the alias BODY's meta for the rewritten reference; do not re-instantiate it via
  `freshenCopy` — the caller's meta is already the right object.
- Do not skip `Cycle` nodes; the inliner's skip is for a different reason.
- Do not delete the alias definitions; demand-driven specialization and post-mono pruning already
  make them free, and deleting would break a `ToKernel` alias still referenced as a value.
- Do not implement the η-wrapper form (v2) without first checking whether item 1 can be told not
  to produce it for an already-forwarded alias.

## 10. v2 — kernel-alias VALUES in argument position (designed 2026-09-14)

v1 leaves every `ToKernel` alias referenced as a VALUE (`List.foldl add 0 xs`, `List.map2 cons`)
untouched, on R6's reading that the `VarGlobal` alias arm does three things the bare `VarKernel`
arm does not. That reading was re-checked against the consumers on 2026-09-14. Two of the three
are not losses and the third stamps nothing today, so v2 forwards these values — under four rules
— and states, without building, the one change that would make kernel partials a dispatch WIN.

### 10.1 R6 re-read — VERIFIED BY READING

| R6 claim | what the code does | verdict |
|---|---|---|
| the alias arm mints the `k|` head | `Translate.elm:4477` (alias arm) and `:4569` (bare `VarKernel` arm) BOTH call `standaloneArgKernelMember ("k|" ++ home ++ "." ++ name)` (`:4603`), which is `injectSpineMemberId 1` — same key, same depth. The inference-side twin (`LssInfer.elm:1420`) folds the alias to the same `kernelMemberIdFor` key. | **no loss, no split.** The head identity is `k|home.name` in both arms, which is why the §3.3 all-or-nothing rule is not even needed for the head — it is needed for the successors (row 2). One asymmetry: the bare arm is gated on `lss.injTotal` (L3), the alias arm is not ⇒ rule R2 below. |
| `injectPapSuccessors g` keyed by the alias | `LssInfer.elm:2846`: fires for arity ≥ 2 (`declaredArityGo`'s kernel-alias arm, `:2629`, reads `canTypeArrowSpine kernelMeta.tipe`, so `Basics.add` = 2 and gets `p|Basics.add|1`; arity 1 bails at `refspine|arity1`, `:2857`). The bare arm mints NO successors, and `Engine.papMemberKey` (`Engine.elm:1895`) is `TOpt.Global`-keyed — **there is no kernel form of a `p|` key**, so forwarding cannot relocate these members, only drop them. | **the one real difference — but it is inert for dispatch today.** The `p|` fast stamp (`AbiCloning.papResolve`, `:2746`) needs `specFunctionRow` (`:2871`) = `Just`, which requires a `MonoClosure`/`MonoTailFunc`/`MonoCtor` node. A kernel alias is never η-expanded (`EtaExpand.elm:447`, LSS_016), so its spec is a value CAF whose body is a `MonoVarKernel` ⇒ `Nothing` ⇒ `papNonFn`; and the Sep-7 census (`plans/lss-pap-fast-stamp.md` §11) accounts for ALL 131 `papNonFn` as constructors (94 + 26 + 11 after the ctor arm), with kernel PAPs answered as `papNoSpec` (its R11) and ABSENT from the residual table. So `p|<kernel-alias>|d` stamps ZERO of the 2,418 `p|` sites. Its only role is join-honesty, and the replacement — an un-written flex slot — is equally honest: `LSet ⊔ LVar = LPartial` (never-singleton, `plans/lss-lpartial-asymmetric-join.md`) or a lone `var`; both decline exactly as `papNonFn` declines. Same verdict, different census bucket (§8). |
| LSS_022 licence read off the alias DEFINITION (`licensedKernelAliasNode`, `Monomorphize.elm:4738`) | its non-census use is `:4340`, inside the join for the ALIAS NODE's OWN spec (restatement-⊤ recovery, `lss.rsTop`). Monomorphization is demand-driven; an alias with no remaining references is never specialized, so there is no join and no ⊤ to recover. | **vacuous, not lost.** Strictly better: the wrapper spec whose ⊤s needed recovering no longer exists. |
| (not in R6) the M3.3 referent-signature walk | `Translate.elm:4507`: gated on `not (canTypeIsArrow (typeOf arg))` — it exists for CONTAINER-typed references. A function alias's reference is arrow-typed, so it never fires. A NON-arrow kernel alias (a container-typed kernel value aliased by a global) would lose it. | **rule R1 below** excludes non-arrow-typed kernel aliases; count them. |

**Soundness of the drop in row 2, stated once.** A member write can only ever be MISSING, never
WRONG, after forwarding: the rewritten reference is the same value with the same caller meta (R7),
and the kernel arm writes a subset of what the alias arm wrote. A missing write leaves a flex
slot; a flex slot joins to `LPartial` or reads `var`; both are declines. There is no path from
"fewer writes" to a false singleton because the head — the only stampable identity on these
arrows — is written identically in both arms. The historical false-singleton miscompile
(`arrowSolverRoots`, `plans/lss-injection-completeness.md`) was a ONE-SIDED join: a branch that
wrote `{identity}` next to a branch that wrote nothing and was read as ∅. That read no longer
exists (`internalize-to-∅` is forbidden; never-written = flex), and the §3.3 all-or-nothing rule
makes every reference to one alias behave the same way regardless.

### 10.2 The v2 rule

Forward a `ToKernel` alias in ARGUMENT/value position iff ALL of (R0 first — it is the one that
bit v1):

- **R0 `abiFixed` (added 2026-09-14 from v1's refuted R2).** A bare `VarKernel` VALUE derives
  its ABI through `deriveKernelAbiTypeRef` from the REFERENCE's meta (`Translate.elm:613`), so a
  forwarded value of a polymorphic non-suffix kernel would register the caller's instantiation
  against the one boxed symbol exactly as a forwarded call does. v2 forwards a kernel-alias value
  ONLY when the alias's `abiFixed` holds (§3.2's rule); the rest stay and count
  `argRefsKeptKernelPoly`.
- **R1 arrow-typed alias.** `canTypeIsArrow` of the alias's kernel meta type (the definition's
  `VarKernel` meta, not the reference's — a container-typed reference of an arrow-typed alias
  cannot exist). Non-arrow kernel aliases are kept and counted (`argRefsKeptKernelNonArrow`).
- **R2 `lss.injTotal` on.** The bare `VarKernel` head mint is gated on it (`Translate.elm:4576`);
  forwarding under `injTotal=0` would drop the head and split nothing but lose the `k|` identity
  at those sites. `AliasForward.run` therefore takes `Config.LssConfig` alongside `InlineConfig`;
  `injTotal` is already in the config hash, so no new cache disjointness is needed for it.
- **R3 all-or-nothing per alias per position class (§3.3).** Every value reference to the alias
  is forwarded or none is; calls follow the §3.2 saturation rule independently. The two classes
  never share a `p|` write site (values get successors via `injectPapSuccessors`, calls via
  `injectPapMember`), so mixing "values forwarded, partial calls kept" splits nothing: kept partial
  calls still mint `p|<alias>|k` exactly as today, and no forwarded site mints a competing key.
- **R4 caller meta retained (R7).** The rewritten node is `VarKernel fr p h n fMeta`. Nothing new
  is minted; `assertMinted` must pass unchanged.

Flag: `aliasForwardKernelValues : Bool` on `InlineConfig` beside `aliasForward`, default `False`,
hash token `afwdK=`, env `ECO_INLINE_ALIAS_FORWARD_KERNEL` via a copy of the v1 override helper.
Inert unless `aliasForward` is also on. (`InlineConfig` is not at the 32-slot cap; `LssConfig` is —
do not put it there.)

**What v2 buys** (all INFERRED until §7 step 5 runs): (i) a fully forwarded kernel alias is never
specialized — one wrapper spec per instantiation gone from `out.mlir`, and one CAF read per value
reference replaced by the kernel's own closure reference; (ii) `argRefsKeptKernel` → 0 for arrow
aliases, so the pass's census finally states the alias population it does NOT handle (only
non-arrow aliases and partial calls remain); (iii) one reference shape for §10.3. **What v2 does
not buy:** dispatch. Expected NEUTRAL by construction — every write it removes declines today.

### 10.3 Going further — a kernel PAP identity (v3, STATED NOT BUILT)

The only way a kernel-alias partial ever becomes a direct call is a `p|` identity that names a
KERNEL, on both sides, plus a stamp that can emit it:

- `Engine.MemberSource` (`Engine.elm:452`) gains `SourcePapKernel ( prefix, home, name ) Int`;
  key form `p|k|home.name|<supplied>`; `memberClassOf` (`:1280`) keeps it in the declining class
  `"l"` exactly as `SourcePap` — the direct-rewrite fence (`injectPapMember`'s doc) applies
  verbatim: a direct rewrite drops the bound arguments.
- Producer: `translateKernelCall` (`Translate.elm:3687`) injects at the residual when
  `argCount < canTypeArrowSpine funcCanType` — the twin of `injectPapMember`, entered after
  `callResultType`. This is the write the §3.2 amendment preserves by not forwarding partial
  calls; with this in place the amendment is lifted.
- Consumer: the bare `VarKernel` arm (`:4571`) and its inference twin call a kernel
  `injectPapSuccessors` for spine depths `1 .. arity-1`.
- `buildMemberOrigins` (`Monomorphize.elm:5018`) gains `Mono.OriginPapKernel home name supplied`;
  `LssFacts`/`MapTemplate` treat it as they treat `OriginPap` (all-owned boundary / unresolved).
- **The stamp is the cost.** `AbiCloning.postSettleTarget` (`:2625`) resolves `OriginPap` to a
  `PapTarget` whose emission loads the `k` bound slots and calls a SPEC's bare symbol with the
  spec's whole row. A kernel has no spec: the target is `kernelInstanceSymbol` for
  `KernelInstanceKey { argTypes = bound ++ residual, resultType }`, so the emission needs the bound
  slots' MonoTypes — recoverable from the PAP object's stored callee type only if the kernel ABI at
  the PAP's creation site is the ABI the residual call expects (`deriveKernelAbiTypeCall` is
  per-call). That is a new `PsStampPapKernel` outcome and a new E2 emission path — a CGEN/REP
  invariant review (`design_docs/invariants.csv`) and an extension of `plans/lss-pap-fast-stamp.md`,
  NOT a change to this pass.

Build it only if §10.4 shows sites. Site counts have mispredicted weight four times in this arc,
but zero sites is zero weight in every direction.

### 10.4 Census before §10.3

Two counters, both cheap, both read off the existing Run-AT protocol:

1. `callsKeptKernelPartial` from the v1 amendment — the producer population (how many partial
   applications of kernel aliases the source has).
2. Split AbiCloning's `g1absentp|…` key by `kernelAliasOf g == Just _` (the `ctx.origins` global
   is the alias global; the check is `topSiteClassOfGlobal`'s, `Monomorphize.elm:3339`) — the
   consumer population (how many call sites through a kernel-alias PAP exist at all). The Sep-7
   table implies this is ≈ 0 on the self-compile; confirm it rather than infer it.

If (2) is ≈ 0 the identity in §10.3 has no consumer and stays unbuilt; (1) then only sizes the
honesty residue.

### 10.5 Tests

Unit (`TestLogic/GlobalOpt/AliasForwardTest.elm`, `aliasForwardKernelValues = True` arm):

| fixture | pins |
|---|---|
| `add = Elm.Kernel.Basics.add` (`makeKernelModule`); `main = List.foldl add 0 xs` | reference becomes `VarKernel`; meta `==` original (R4); `argRefsRewrittenKernel` arity-2 bucket = 1 |
| same alias referenced as a value from TWO modules | both forwarded (R3) |
| `main = List.map (add 1) xs` | the partial CALL is NOT forwarded (§3.2 amendment); `callsKeptKernelPartial = 1`; the head is still `VarGlobal add` |
| `main = add 1 2` | saturated call forwarded (v1 behaviour unchanged) |
| a container-typed kernel alias used as a value | NOT forwarded; `argRefsKeptKernelNonArrow = 1` (R1) |
| flag on with `lss.injTotal = False` | no value forwarding (R2); `argRefsKeptKernel` unchanged from v1 |

E2E (`test/elm/src/AliasForwardTest.elm`, extend): `List.foldl add 0`, `List.map2 add`,
`List.map (add 1)` (partial kept), each at `Int` AND `Float` (R2 of §4 — the `_Int`/`_Float`
kernel-variant pin now also covers the VALUE path), results reduced to Ints before `Debug.log`.
Run in both arms and in the `ECO_INLINE_THRESHOLD=0` leg.

### 10.6 Gates and measurement (adds a step 5 to §7)

- Defaults byte-identical (`afwdK=` absent); `afwdK=` present in the hash when on.
- `assertMinted` unchanged; E2E suite green in both arms.
- **Two-arm same-source protocol run** (`benchmarks/lss-opt.md`, Run-AT style): dispatch counter
  NEUTRAL; `stampedPapGlobal` UNCHANGED (its 2,135 sites are never kernel-alias sites — a change
  here means §10.1 row 2 was wrong, stop and find out); `out.mlir` smaller by the retired wrapper
  specs (`aliasesFullyRetired` × instantiations); LSS coverage `%` may FALL by the dropped
  successor writes — expected (§8), not a regression.
- A default flip needs one extra bootstrap iteration (A≠B is propagation; the gate is B==C).
