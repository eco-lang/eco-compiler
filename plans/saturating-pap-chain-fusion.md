# Saturating PAP-chain fusion — collapsing the applicative `apply` staircase

**Status:** **OUTLINE + P0 STEP 1 RUN (2026-09-15).** §8 has the result and it is decisive:
`EcoPAPSimplify` is not firing on the staircase and structurally cannot, so the "budget question"
outcome in §4.1 is REFUTED — but so is this plan's own framing. **There is no chain anywhere in
the emitted program**, so "chain fusion" is the wrong mechanism name; the filename is kept for
continuity and §8.5 states what the item actually is. §3's layers must be re-read through §8
before any of them is costed. §5-§7 stand.

**Read §8 first.**

**Origin:** the `var` census of 2026-09-15 (this session). Raw artefacts:

  - `build/compiler/build-kernel/bin/varcensus-2026-09-15-summary.txt`
  - `build/compiler/build-kernel/bin/varcensus-2026-09-15-pos.log.gz` (149,482 `pos|` rows)

Reproduce as documented in `plans/lss-container-payload-transport.md` §Origin (same run).

**Independence:** touches no LSS analysis. It DELETES a population rather than naming it, and
if it works the LSS question for that population disappears. Sibling:
`plans/lss-container-payload-transport.md` names what is left.

---

## 1. The shape, and how big it is

### 1.1 The idiom

```elm
lssDecoder : D.Decoder x LssConfig
lssDecoder =
    D.pure LssConfig
        |> D.apply (D.optionalField "enabled" D.bool defaultLss.enabled)
        |> D.apply (D.optionalField "keyed"   D.bool defaultLss.keyed)
        …                                   -- ~30 stages
```

`D.pure LssConfig : Decoder x (Bool -> Bool -> List String -> … -> LssConfig)` — the payload is
a curried PAP of a 30-field record constructor, threaded stage by stage. `Compiler/Eco/Config.elm`
has **114 `D.apply` sites**; `Compiler/Elm/Docs.elm` and `Builder/Elm/Outline.elm` have 14 each.

`Compiler/Json/Decode.elm`:

```elm
apply : Decoder x a -> Decoder x (a -> b) -> Decoder x b
apply (Decoder decodeArg) (Decoder decodeFunc) =
    Decoder <| \ast ->
        decodeArg ast
            |> Result.andThen (\a -> Result.map (\b -> a |> b) (decodeFunc ast))
```

Per stage that is: one intermediate PAP, one intermediate `Decoder` closure, one
`Result`/`Ok` box, and one **generic apply** at `a |> b` (`b a`, where `b` is a parameter).

### 1.2 What it costs the analysis

| | |
|---|---:|
| registry entries with positions | 40,453 |
| entries containing any `var` | 1,281 (3.2 %) |
| **entries carrying a `var` on an arrow spine ≥ 8 deep** | **309 (0.76 %)** |
| **var positions in those 309** | **10,303 of 12,956 = 79.5 %** |

Every one of the 309 is a `map` / `apply` / `andThen` / `Ok` / `Err` / `Decoder` specialization
whose payload is a curried function of arity ≥ 9. Globals inside the class: `map` 3,362,
`apply` 1,730, `Ok` 1,706, `andThen` 1,706, `Decoder` 1,136, `Err` 663.

One `Result.map` spec (registry index 30344) is 103 positions, **100 of them `var`**, from
25 unknowns appearing at four paths each:

```
pos|map||k1:g;elm/core:Result.map…       head: known
pos|map|/a0|k1:l;5947…                   the callback: known lambda
pos|map|/a0/a0|top@clsDestr              the payload it receives: ⊤
pos|map|/a0/a0/r      var@30344.24   ┐
pos|map|/a0/r         var@30344.24   ├── the same 25 unknowns,
pos|map|/r/a0/c1/r    var@30344.24   │   four paths each
pos|map|/r/r/c1/r     var@30344.24   ┘
… 27 levels of /r, ids 24 → 0
```

The chain is a staircase — one spec per `|> apply` stage, var counts stepping
`…88, 92, 96, 100, 104, 108, 112, 116`, spec indices stepping by 5.

### 1.3 THE CAVEAT THAT GOVERNS THE WHOLE ITEM

**On this corpus the staircase is cold, and in the measured runs it executes zero times.**
`Config.decoder` is reached only from `Builder.Eco.Config.loadBase`, once per invocation, and
only if `eco-config.json` exists — it does not exist in `build/compiler/build-kernel`, so those
309 specs never run. The other two hosts (`Outline`, `Docs`) are also once-per-invocation.

So: **79.5 % of the LSS var book is a corpus artefact of one source file's decoder.** Two
consequences that must be held together:

  - Any fix moves the coverage metric a long way and buys **no dispatch on this workload**.
    This arc has been burned by coverage-without-dispatch before (sigFlow, LSS_023,
    callArgFlow — see `lss-root-cause-arrows-have-no-identity`). Do not sell it as a
    performance item on this evidence.
  - The *transform* is nevertheless general. Whether it pays has to be measured on a workload
    where an applicative chain is hot, or on the allocation side (PAPs + `Decoder` closures +
    `Ok` boxes per stage), NOT on the self-compile's dispatch counters.

---

## 2. Prior art — checked, and it changes the framing

`eco::createEcoPAPSimplifyPass()` **is already in the pipeline** (`runtime/src/codegen/EcoPipeline.cpp:65`,
implemented in `runtime/src/codegen/Passes/EcoPAPSimplify.cpp`). It already does:

  - **P1** saturated `papCreate` + `papExtend` → direct `eco.call` (single-use closure)
  - **P4** multi-use `papCreate` elision where every use is a saturated typed `papExtend`
  - **P2** `papExtend` chain fusion
  - **P3** DCE of the resulting dead closures

**All of it is function-local MLIR peephole matching.** The `apply` staircase is not that
shape: the PAP is stored into `Ok`, wrapped in a `Decoder` closure, returned across a
definition boundary, destructured out of the constructor in a parameter pattern, and only then
applied through `a |> b` where `b` is a *parameter*. No pattern rooted at a `papCreate` in one
`func.func` can see it.

Also checked and NOT the same thing: `plans/cgen05-chain-papextend.md` (emit a chain per stage —
a correctness fix, the opposite direction), `plans/inline-papextend-saturated.md` (lower the
saturated helper inline), `plans/eco-pap-simplify-pass.md` (the plan behind the pass above),
`plans/hof-elimination-closure-alloc-reduction.md`.

**So the real question is not "what rewrite" but "at which layer can the staircase be seen at
all".** That is §3.

---

## 3. Candidate layers — NOT YET INVESTIGATED, not ranked

  - **(L1) Does inlining already expose it? — CLOSED 2026-09-15, see §8.** `EcoPAPSimplify` is
    not firing on the staircase and cannot: it removes 1 of 11,676 `segmentation_unknown` sites
    module-wide, and the staircase has no `papExtend` chain for it to match. No inline budget
    can create one (§8.4). Not a budget question.
  - **(L2) Pre-mono syntactic.** At pre-mono the chain is still `f |> apply d1 |> apply d2 …`
    with `apply` a named global of known declared arity — a syntactic pattern, the same class
    as the shipped `etaExpand` / `aliasForward` / `InlineSimplify` transforms
    (`plans/pre-mono-lss-transforms*.md`). Open: recognizing `apply` by identity is either a
    module-specific match (fragile, and this repo has refused such things before) or a general
    "combinator that applies its own payload" predicate that nobody has written down.
  - **(L3) Post-mono, on the Mono IR.** After monomorphization the staircase is a chain of
    concrete specs with known arities; a whole-graph rewrite could see across the definition
    boundaries an MLIR peephole cannot. Open: the `Decoder`/`Ok` boxing sits between the
    stages, so this is not a pure PAP chain — it is a PAP chain *through constructors*, and
    whether that is rewritable without a real escape/purity argument is unknown.
  - **(L4) Source refactor.** `Json.Decode` ships `map2…map8` precisely so the constructor
    arrives saturated and no PAP spine ever exists; a 30-field record needs a different
    factoring (nested sub-records, or decode-then-field-update). This is the cheapest way to
    move the coverage number and **that is exactly why it should not be done for the number** —
    record it as an option, not a plan.

---

## 4. P0 — measure BEFORE building anything

  1. **(L1) first, always.** Dump the emitted MLIR for the config-decoder specs at defaults and
     at `ECO_INLINE_POST_MONO=0`, and count `papCreate` / `papExtend` / `generic_apply` per
     stage. If `EcoPAPSimplify` is already firing, the item shrinks to a budget question.
     → **RUN 2026-09-15, see §8. Answer: NOT firing, and it cannot. Not a budget question.**
     The `ECO_INLINE_POST_MONO=0` arm was NOT run and is now SUPERSEDED — §8.4 settles what it
     was meant to decide structurally, on the defaults arm alone.
  2. **Price the staircase honestly.** Objects allocated and generic dispatches executed per
     `apply` stage — and then multiply by an execution count that is ZERO on this workload
     (§1.3). Needs a workload where an applicative chain is hot, or the item is an
     allocation/artefact-size item only. Use `ECO_INLINE_ALLOC=0` for allocation attribution
     (memory `lss-cost-is-step-monad-allocation`).
  3. **Artefact size.** 309 specs of `map`/`apply`/`andThen`/`Ok`/`Err`/`Decoder` that exist
     only to carry the staircase — how many bytes of `out.mlir`? Compare against
     `plans/post-inline-dead-spec-prune.md`'s measurement method (unreferenced code-bearing
     definitions in the emitted text).
  4. **Generality.** How many `apply`-staircases exist outside `Eco.Config`? Count chains, not
     call sites: `Docs` 14 and `Outline` 14 `D.apply` sites, but the chain LENGTH is what
     drives the cost.
  5. **Predicted LSS delta.** If the 309 specs disappear, `var` should fall by ~10,303 and
     coverage rise from 90.58 % toward ~98 %. Pre-register that as a falsifiable prediction —
     if the transform lands and coverage does not move that far, the attribution in §1.2 was
     wrong.

---

## 5. Gates — pre-registered, sizes TBD after §4

  - **Byte-identical-behaviour rail:** the transform must not change observable behaviour
    (LSS_005 is about annotations; this changes CODE, so it needs its own argument).
    E2E both arms, elm-tests, `ECO_MONO_VALIDATE`, and the bootstrap fixed point
    (`guides/bootstrap.md`) — a code-shape transform that changes `out.mlir` needs Stage 8c
    `eco-compiler-boot.mlir == eco-compiler-boot-2.mlir`.
  - **Flag default-OFF first**, flipped only on a measured arm, per the arc's standing
    practice. One extra bootstrap iteration is required for a default flip (memory
    `premono-inliner-shipped-default-on`).
  - **Accounting identity:** chains fused == staircase specs removed, to the digit.
  - **Report BOTH** the coverage delta and the dispatch delta, and state plainly that the
    latter is expected to be ~0 on this corpus (§1.3). A silent coverage-only win here would
    misreport the item.

---

## 6. Risks and known traps

  - **Selling a cold win as a hot one.** §1.3. The single biggest risk in this item.
  - **Module-specific pattern matching.** A rewrite keyed on `Compiler.Json.Decode.apply` by
    name is not a compiler optimization; it is a hard-coded special case that rots. If no
    general predicate exists, that is a reason to close the item, not to special-case it.
  - **The `Decoder`/`Ok` boxing between stages.** This is not a bare PAP chain. Any rewrite
    that looks through a constructor needs a real purity/escape argument, not a shape match —
    compare the kernel-license discipline in LSS_021/LSS_022, where "when in doubt, poison".
  - **`EcoPAPSimplify` already exists.** Do not build a second pass that duplicates P1/P2/P4.
    If the answer is at MLIR level it is an EXTENSION of that pass.
  - **Source drift.** The workload is the compiler's own source, so touching `Config.elm` to
    test a hypothesis changes every figure in every arm. Same-source arms only.

---

## 7. What not to do

  - Do not rewrite `Config.elm`'s decoder to move the coverage number (L4 is an option of last
    resort, and the number is the wrong reason).
  - Do not start at L2/L3 before L1 has been checked (§4.1).
  - Do not quote §1.2's 79.5 % as "79.5 % of the dispatch problem" — it is 79.5 % of the
    *position* book, on code that runs zero times here.

---

## 8. P0 STEP 1 — RUN 2026-09-15. Verdict: **not firing, cannot fire, and this plan's frame is wrong**

### 8.1 Method

Same artefact, two dumps, no recompile:

```bash
BIN=build/runtime/src/codegen/ecoc
IN=build/compiler/build-kernel/bin/varcensus-out.mlir     # 13,392,466 B, the §Origin run
$BIN --emit=mlir     "$IN" 2> pre.err     # input MLIR, no lowering        82,960,717 B
$BIN --emit=mlir-eco "$IN" 2> post.err    # after buildEcoToEcoPipeline    80,894,220 B
```

`--emit=mlir-eco` runs exactly `buildEcoToEcoPipeline` (`EcoPipeline.cpp:52-75`):
RCElimination → **EcoPAPSimplify** → EcoCompareCaseRewrite → UndefinedFunction. So the pre/post
pair is a clean before/after for the pass on the real workload. (Text goes to **stderr**.)
`eco.call` / `eco.papExtend` / `eco.papCreate` are always printed in generic form, so counting
by `"eco.<op>"` is exact — verified against the pretty-printed op list.

### 8.2 The pass IS doing substantial work — on other code

| | pre | post | Δ |
|---|---:|---:|---:|
| `eco.papExtend` | 34,641 | 26,523 | **−8,118 (−23.4 %)** |
| `eco.papCreate` | 26,074 | 21,934 | −4,140 (−15.9 %) |
| `eco.call` | 74,044 | 77,148 | +3,104 |
| functions changed | | | **4,870 of 57,867 (8.42 %)** |

**But split by `_call_kind`, the pass consumes only already-resolved sites:**

| `_call_kind` on `papExtend` | pre | post | Δ |
|---|---:|---:|---:|
| `direct_known_segmentation` | 5,899 | 270 | **−5,629** |
| (untagged) | 1,353 | 11 | −1,342 |
| `singleton_fast` | 15,387 | 14,241 | −1,146 |
| `generic_apply` | 326 | 326 | 0 |
| **`segmentation_unknown`** | **11,676** | **11,675** | **−1** |

**It removes exactly ONE generic dispatch site out of 8,118 rewrites.** That is not a tuning
accident — it is the pass's contract: P1/P4 rewrite a `papExtend` to `eco.call @f` and need a
known `f`, which is precisely what a `segmentation_unknown` site does not have.

### 8.3 On the staircase it changes NOTHING

Per-function op-count diff over the whole module:

```
staircase specs (Compiler_Json_Decode_apply_$_* + Compiler_Eco_Config_*Decoder_$_*): 160, CHANGED = 0
```

`Compiler_Eco_Config_lssDecoder_$_30151` and `Compiler_Json_Decode_apply_$_30220` are
**byte-identical** pre and post. (45 functions in the wider `Json.Decode` / `Result` family do
change — `fromByteString`, `mapError`, `mapErrorHelp` — none of them staircase specs.)

### 8.4 WHY — and it settles the `ECO_INLINE_POST_MONO=0` arm without running it

**There is no chain. At no point in the emitted program are two `papExtend`s on the same PAP
adjacent, or even in the same function.** `lssDecoder` is a CAF (`eco.caf_memo`) and contains:

```mlir
%149 = "eco.papCreate"() <{arity = 32, function = @Compiler_Eco_Config_LssConfig_$_30187,
                           num_captured = 0}>                       // the record ctor PAP
…
%181 = "eco.call"(%1, %180) <{callee = @Compiler_Json_Decode_apply_$_30219}>
%182 = "eco.call"(%0, %181) <{callee = @Compiler_Json_Decode_apply_$_30220}>
```

**124 `eco.call`, 1 `eco.papCreate`, 0 `eco.papExtend`** — 32 direct calls to 32 *distinct*
`apply` specializations. Every one of the 15 `Eco.Config` decoders has the identical shape, with
`papCreate` arity exactly equal to its stage count and **zero `papExtend`**:

| decoder | stages | ctor PAP arity | papExtend |
|---|---:|---:|---:|
| `lssDecoder` | 32 | 32 | 0 |
| `inlineDecoder` | 27 | 27 | 0 |
| `decoder` (top level) | 20 | 20 | 0 |
| `borrowDecoder`, `lssInstanceQualDecoder` | 5 | 5 | 0 |
| `cafMemoDecoder` | 4 | 4 | 0 |
| `cafHoistDecoder`, `cseDecoder`, `listDecoder`, `monoDecoder`, `lssSettleDecoder` | 3 | 3 | 0 |
| `lssStageAnchorDecoder`, `specLimitsDecoder` | 2 | 2 | 0 |
| `bytesFusionDecoder`, `logicalTypesDecoder` | 1 | 1 | 0 |
| **total** | **114** | | **0** |

Each `apply` spec is four ops and also has no `papExtend`:

```mlir
func.func private @Compiler_Json_Decode_apply_$_30220(%arg0, %arg1) -> !eco.value {
  %0 = eco.project.custom %arg0[0]        // unwrap Decoder decodeArg
  %1 = eco.project.custom %arg1[0]        // unwrap Decoder decodeFunc
  %2 = "eco.papCreate"(%0, %1) <{arity = 3, function = @Terminal_Main_lambda_25382$clo,
                                 num_captured = 2}>
  %3 = eco.construct.custom(%2) {constructor = "Decoder", tag = 0}
  eco.return %3
}
```

**The staircase is a deferred closure TREE built at CAF time, not a PAP chain.** The extensions
happen one per closure invocation, at decode time, in the stage bodies:

```mlir
@Terminal_Main_lambda_25382$cap(decodeArg, decodeFunc, ast):
  %0 = papExtend(decodeArg, ast)   {_call_kind = "segmentation_unknown"}   // GENERIC
  case Ok:
    %5 = papCreate @Terminal_Main_lambda_25384 arity=2 captures=1          // the \b -> a |> b
    %6 = papExtend(decodeFunc, ast) {_call_kind = "segmentation_unknown"}  // GENERIC
    %7 = call @Result_map_$_30221                                          // direct
@Terminal_Main_lambda_25384$cap(a, b):
  %0 = papExtend(b, a)             {_call_kind = "segmentation_unknown"}   // GENERIC — `a |> b`
```

**Consequence for the arm that was not run:** inlining `apply` into `lssDecoder` would replace 32
`eco.call`s with 32 `papCreate`+`construct` pairs. It would **not** bring a single `papExtend`
into `lssDecoder`, because the `papExtend`s live in closure bodies invoked later. No inline
budget at any setting can make these adjacent, so `ECO_INLINE_POST_MONO=0` cannot change the
verdict and was not run. **§4.1's "it shrinks to a budget question" outcome is REFUTED.**

### 8.5 What the item actually is

Following the closures the 145 `apply` specs create, one level deep:

```
stage-closure family: 580 functions
   papExtend = 435   papCreate = 145
   call kinds: {segmentation_unknown: 435}      ← 435 of 435, 100 % generic
```

435 of the module's 11,676 `segmentation_unknown` sites (3.7 %) are the staircase, and **not one
is devirtualized**. The census and the codegen line up exactly: `Result_map_$_30221`'s own
`papExtend` IS `singleton_fast` with `_fast_evaluator = @Terminal_Main_lambda_25384$cap` — LSS
resolved the `\b -> a |> b` callback, which is the `pos|map|/a0|k1:l;5947` row. The *unresolved*
extension is the one inside it, on the `LssConfig` PAP — which is exactly the
`pos|map|/a0/a0/r…` var spine. Same fact, two instruments.

So the item is **not** "fuse a PAP chain". It is: *collapse an applicative structure whose
intermediate stages are heap-resident closures and constructor boxes into one saturated
application.* That is a `mapN` synthesis / defunctionalization, not a peephole, and it must
reason about the `Decoder` and `Ok` boxes between stages. §3's L2/L3 survive under that reading;
**L1 is closed**, and L3's parenthetical ("this is not a pure PAP chain — it is a PAP chain
through constructors") turns out to be the whole problem rather than a caveat.

### 8.6 Host inventory, and a correction to §1.3

Callers of `Decode.apply` specs, by stage count: `Eco.Config` **114**, `Builder.Elm.Outline` 14
(`appDecoder` 6, `pkgDecoder` 8), `Compiler.Elm.Docs` 16. So 114 of ~144 stages (79 %) are the
config decoder.

**Correction to §1.3:** "the staircase executes zero times" is right for the `Eco.Config` chains
(no `eco-config.json` in `build/compiler/build-kernel`) and those are the ones holding the var
mass — but `Outline.appDecoder`/`pkgDecoder` DO run on every compile that reads an `elm.json`.
That is 14 stages over a handful of parses: cold, but not zero. Quote it that way.

### 8.7 Artefacts

`pre.err` / `post.err` are ~83 MB each and were not kept. Regenerate with §8.1 in one minute
from `varcensus-out.mlir`, which IS kept. The extraction helpers used (`fx.py` function
extractor, `perfn.py` per-function op diff) are ten-line scripts; re-derive rather than hunt.
