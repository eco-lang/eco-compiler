# Pre-mono LSS transforms — 04: alias forwarding

**Status:** IMPLEMENTATION-READY (2026-09-10). Item 4 of `plans/pre-mono-lss-transforms.md`.
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
| CALL | `Call r (VarGlobal fr f fMeta) args` | `Call r (VarGlobal fr g fMeta) args` / `Call r (VarKernel fr p h n fMeta) args` | **yes**, both target kinds |
| ARGUMENT / value | bare `VarGlobal fr f fMeta` anywhere not in callee position | `VarGlobal fr g fMeta` | **yes for `ToGlobal`; NO for `ToKernel`** (§4 R6) |
| the alias definition itself | `Define (VarGlobal g …)` | untouched | — |

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
instantiation plus the actual args. Forwarding changes neither. *Resolution:* the E2E pin uses a
local alias of `Basics.add` at `Int` AND `Float` in one program and checks both results.

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
are forwarded for kernels: a call mints no member and `translateKernelCall` is the same code a
direct kernel call runs.

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
| 1 | Config: `aliasForward` field, default, decoder, hash `afwd=`; env `ECO_INLINE_ALIAS_FORWARD` via `applyInlineAliasForwardOverride` | `Compiler/Eco/Config.elm` (`:998,:1091,:1207,:1451`), `Builder/Eco/Config.elm` (`:367,:1797`) | byte-identical at defaults; `afwd=` in the hash when on |
| 2 | `AliasForward.aliasMap`: admit `Define`/`TrackedDefine` with a bare `VarGlobal`/`VarKernel` body; chase chains with a visited set; count depth and cycles | `Compiler/GlobalOpt/PreMono/AliasForward.elm` | unit: 3-link chain resolves to the end; cycle refused; `VarCycle`/ctor bodies not admitted |
| 3 | The walk over ALL expression-bearing node kinds (`Define`, `TrackedDefine`, `Cycle` value+func defs, `PortIncoming`, `PortOutgoing`) rewriting call-position references for both target kinds and argument-position references for `ToGlobal` only; `deps` extended per §3.4 | same | unit: alias inside a `Cycle` body forwarded; argument-position kernel alias NOT forwarded; `deps` gains the target |
| 4 | Metrics + `pre-afwd:` report line under `inline.report` | same, `Builder/Generate.elm` (render beside `renderPreInlineReport`) | census line present with the flag on, absent off |
| 5 | Wire as slot 2 of `runMonoOptPipeline`, state passed through | `Builder/Generate.elm:741-772` | `assertMinted` (item 0) passes; EARLY-arm compile of the compiler succeeds |
| 6 | Tests §6 | `compiler/tests/TestLogic/GlobalOpt/AliasForwardTest.elm`, `test/elm/src/AliasForwardTest.elm` | all green in both arms |
| 7 | Measurement §7 | `benchmarks/lss-opt.md` | recorded |

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
`cycles=` `callsRewritten=` `argRefsRewritten=` `argRefsKeptKernel=` `depsExtended=`, plus a
top-20 targets list (`target=count`) mirroring `inlinedByCallee`'s rendering.

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

## 9. What not to do

- Do not forward `ToKernel` aliases in argument position until the R6 precision question is
  measured on the census — that is a v2 decision, not an oversight.
- Do not use the alias BODY's meta for the rewritten reference; do not re-instantiate it via
  `freshenCopy` — the caller's meta is already the right object.
- Do not skip `Cycle` nodes; the inliner's skip is for a different reason.
- Do not delete the alias definitions; demand-driven specialization and post-mono pruning already
  make them free, and deleting would break a `ToKernel` alias still referenced as a value.
- Do not implement the η-wrapper form (v2) without first checking whether item 1 can be told not
  to produce it for an already-forwarded alias.
