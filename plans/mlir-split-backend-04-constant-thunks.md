# MLIR split backend 04: constant thunks in the Elm front-end (replaces the IPSCCP prologue)

**Master plan:** `plans/mlir-split-backend.md`. **Status:** feasibility-deepened outline,
2026-10-02. Nothing is built. Not implementation-ready: §8 Step 0 must confirm two Mono body
shapes first.

**Research:** `design_docs/mlir-level-partitioning-whole-program-steps.md` §5.
**Measurement:** `benchmarks/backend-opt-loop.md`, entry "IPO". Raw perf tables:
`rt-on.tsv` / `rt-off.tsv` from that session's scratch.

## 0. Findings in one screen

- **Feasible, and smaller than the outline assumed.** Every value-position reference to a
  top-level value funnels through one function, `Expr.generateVarGlobal`
  (`compiler/src/Compiler/Generate/MLIR/Expr.elm:436-437` → `684-765`). Two perf maps already
  intercept it there: `nullConsBySpec` and `constCtorBySpec` (`Context.elm:224-225`,
  `Backend.elm:1380-1460`). A third map is the same pattern.
- **Phase 1 alone gets most of the Array win, not just `hashBase`.** Once `branchFactor`'s
  reference inside `shiftStep`'s own body is the constant 32, LLVM's per-partition InstCombine
  folds `ceil(log(32.0)/log(2.0))` to `ret i64 5`, because it folds `llvm.log` of a constant. The
  `log` call disappears and only a cheap call to `shiftStep()` remains.
- **Phase 2 has a safer form than an evaluator.** Under 2A ("closed-body substitution"), the
  front end emits the thunk's own closed scalar body at each reference and lets LLVM fold it.
  - LLVM then gives exactly the semantics the IPSCCP prologue uses today.
  - Nothing has to be re-implemented in Elm, and there is no host-dependence problem.
  - 2B, the outline's Elm evaluator, is feasible but carries real exactness obstacles (§5.4).
- **IPSCCP leaves residual calls.** With the prologue on, `Array_bitMask` (0.04 %),
  `mixHash` (0.03 %), `shiftStep` and `hashBase` (0.01 % each) are still sampled. IPSCCP
  replaces a call's result with the constant but keeps the call, because thunks are not
  `readnone`: the attrs pair is off (`EcoBackend.cpp:540-552`). Folding in the front end deletes
  the call. Only the thunk residue is removable: `bitMask` + `shiftStep` + `hashBase` = 0.06 %,
  about 0.1 s. `mixHash`'s 0.03 % is its own body, and folding does not remove it. So "OFF + 04
  beats ON today" is **not expected to be measurable**; the target is parity (§8 Step 2).
- **Latent bug found on the way:** the text MLIR printer prints any `Float` whose
  `String.fromFloat` has no `.` (for example `1e-09`) as `0.0` (`Mlir/Pretty.elm:579-597`).
  `-0.0` also comes out as `0.0`, because `fromFloat` gives `"0"`. **The text path is opt-in**
  (`make --text-mlir`, `Terminal/Make.elm:342`). The default output, and the output
  `selfcompile.sh` writes, is **bytecode**: `sc-final-r1-out.mlir` starts with the `ML\xefR`
  magic, and bytecode floats are exact. So the bootstrap is not exposed. The bug is pre-existing;
  2B would be the first producer of new float values. 2A copies only existing literals.

## 1. Today, as measured

| fact | value | source |
|---|---|---|
| self-compile, prologue on / off (N = 3 medians) | 108.40 s / 110.33 s (+1.8 %, ranges disjoint) | IPO entry |
| prologue cost (serial) | IPSCCP 5.7–7.7 s + GlobalDCE 0.2–0.8 s | TL; `ipsccp/dump.log` |
| IPSCCP thunk folds | 28 call sites, 14 thunks | IPO entry |
| off-arm hot symbols | `mixHash` 0.38 %, `Array_shiftStep` 0.30 %, `bitMask` 0.08 %, `hashBase` 0.06 %, `branchFactor` 0.05 %, `log@plt` 0.04 % (+ libm body) | `rt-off.tsv` |
| on-arm residue | `bitMask` 0.04 %, `mixHash` 0.03 %, `shiftStep` 0.01 %, `hashBase` 0.01 % | `rt-on.tsv` |
| `Basics_logBase` symbol | absent from perf in both arms. In Aug it was 0.20 % (`plans/gc-free-function-propagation.md:1019`). **Review check:** it is also absent from the self-compile's MLIR symbol strings (`grep -a` over `build/compiler/build-kernel/bin/sc-final-r1-out.mlir` finds `Array_shiftStep_$_180`, `Array_bitMask_$_196`, `Array_branchFactor_$_174`, `…hashBase_$_32060` and `…mixHash_$_32053`, but no `Basics_logBase`). So `logBase` is not a spec: it is inlined at Mono level. Step 0 confirms the exact body | grep |

## 2. How a top-level value flows today

| stage | what happens to `hashBase` / `shiftStep` | cite |
|---|---|---|
| source | `hashBase = 67108864` (`Compiler/AST/Monomorphized.elm:307-310`). elm/core 1.0.5 `Array.elm:69-102`: `branchFactor = 32`, `shiftStep = ceiling (logBase 2 (toFloat branchFactor))`, `bitMask = Bitwise.shiftRightZfBy (32 - shiftStep) 0xFFFFFFFF`. `logBase b n = fdiv (log n) (log b)` (`Basics.elm:619-623`) | ~/.eco/0.1.1/packages/elm/core/1.0.5 |
| canonical / typed opt | `Define` nodes; references are `VarGlobal`. Pre-mono `AliasForward` rewrites `ceiling`/`toFloat`/`modBy` alias calls to saturated `VarKernel` calls when the ABI is fixed. Literal bodies are not aliases and are left alone | `GlobalOpt/PreMono/AliasForward.elm` header |
| mono | One `MonoDefine (MonoLiteral (LInt 67108864) MInt) MInt` per demanded type. A `number` literal at `MFloat` becomes `LFloat` at specialization. The self-compile runs `ECO_MONO_ENGINE=solver` (`selfcompile.sh`), so the engine that matters is `MonoSolver/Translate.elm:542`; the `Specialize` twin does the same | `Monomorphized.elm:3189-3197, 3239-3266`; `Monomorphize/Specialize.elm:2585-2598`; `MonoSolver/Translate.elm:542` |
| `MonoInlineSimplify` → `pruneAfterInline` | Value references stay `MonoVarGlobal`; the inliner inlines callees, not value thunks. It may inline `logBase` and `mixHash` into callers, which multiplies the reference sites | `Builder/Generate.elm:1100-1190` |
| GlobalOpt (staging, AbiCloning, Borrow) → CSE → CafDedupe → CafHoist | Scalars are untouched. CafHoist is default-off and hoists only `!eco.value` closed subterms (CGEN_069). CafDedupe (`ECO_CAF_DEDUPE`) nulls victim specs and remaps every reference, which can turn a thunk into an alias. Either way the codegen-time map sees the final graph | `Builder/Generate.elm:1733-1757, 1812-1870` |
| codegen of the thunk | `generateDefine` wraps the body in a nullary `func.func … -> i64`. `cafMemoQualifies` refuses non-`!eco.value` results (HEAP_035: never root a raw scalar) and literal bodies, so Int, Float and Char thunks are recomputed on every call | `Functions.elm:588-604, 624-684` |
| codegen of a reference | `generateVarGlobal`, arity 0: null-cons arm → `Nothing` arm → `eco.call @thunk() : <abi>` | `Expr.elm:708-765` |
| ops in `shiftStep`'s body | core calls hit `kernelIntrinsic` through `maybeCoreInfo` (MonoVarGlobal to an elm/core spec) or a `MonoVarKernel` callee. The ops are `eco.float.log` (`logBase` itself returns `Nothing`), `eco.float.div`, an int-to-float conversion, `eco.float.ceiling`, `eco.int.shru` and `eco.int.sub` | `Expr.elm:3720-3735, 3940-3950, 4419-4422`; `Intrinsics.elm:376-620` |
| backend | `log` → `LLVM::LogOp` (a libm call at runtime; constant-folded by LLVM with the host libm). `ceiling` → `llvm.ceil` + `fptosi`. `modBy` → `srem` plus zero and sign guards. `shru` → `lshr` (poison for shift ≥ 64) | `runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131, 412-420, 504-515, 809-819` |
| cgu prologue | IPSCCP propagates the thunks' return values (the call stays), then GlobalDCE | `EcoBackend.cpp:499-556`, gate `3795-3815` |

## 3. Where the constant must be produced

| level | information present | verdict |
|---|---|---|
| typed AST (pre-mono) | The literal, but `number` literals are not yet typed, references carry solver metas (`Fresh.assertMinted`, AssignMVarIds-first), and deps and LSS metas are touched | **No.** Highest risk; it would interact with LSS member keying and alias forwarding |
| Mono graph rewrite (a GlobalOpt pass) | The final per-spec type and body. Substituting `MonoLiteral` for `MonoVarGlobal` lets Mono pattern-matchers see it (for example `BytesFusion/Reify.elm:1622-1666` `CountConst`) | Possible later (open question Q4). It orphans specs after `pruneAfterInline`, so MONO_022 needs a re-prune, and it shifts inliner costs. No measured need |
| **codegen-time map** (`Backend.elm` ctx build, both streaming paths `:174-184` and `:307-317`) | The final graph after every pass, with exact SpecIds, signatures (`Ctx.buildSignatures`) and `nodes` for following chains | **Yes.** It is the `constCtorBySpec` precedent: no graph change, one emission choke point, thunk `func.func`s stay in place |

**Rejected alternative: scalar CAF memoization.** HEAP_035 allows it only with unrooted slots
plus an init flag. That still costs a load and a branch per reference, and it never shows LLVM
the constant, so `srem` would not become a mask. It is no substitute.

**Consumption: every place that can reference a thunk.**
- **Value position in any function body, lambda, tail-rec body or ctor argument:** all go
  through `generateExpr` → `generateVarGlobal`. This covers `Lambdas.processLambdas` and
  `TailRec`, because the ctx carries the maps.
- **Callee position:** `MonoCall (MonoVarGlobal …)` at `Expr.elm:1877`, `2617`, `3709` and
  others. That form is only reachable for function-typed thunks, which are never scalar.
  Excluded by type.
- **Other thunks** (`shiftStep` → `branchFactor`, `bitMask` → `shiftStep`): handled by chain
  resolution (phase 1 aliases) or recursive substitution (2A).
- **Closures and PAPs:** a scalar cannot be a PAP. A closure capturing the value captures an
  SSA value produced by `generateVarGlobal`, so it is covered.
- **main, ports, flags decoder, `__eco_register_ports`, `__eco_init_globals`:** none of these is
  scalar. Exclude `main`'s SpecId and port/flag specs anyway.
- **CAF memo guards** (CGEN_068 caller fast path): only `eco.caf_memo`-tagged thunks are
  involved, and those are never scalar. A non-literal **Bool** thunk *is* tagged. Folding its
  references leaves the slot unreferenced, which CGEN_068 permits; the dead func and slot go
  with DCE.
- **Not covered:** `generateMlirModule` (`Backend.elm:62-76`, invariant tests only) installs no
  maps. That is deliberate: it is the differential baseline.

## 4. The two hot thunks, concretely (to be confirmed in Step 0)

- **`hashBase`:** the literal, phase 1. It is referenced from `mixHash` (`Monomorphized.elm:319-321`),
  `packHashes`, `layoutHashOf`/`specHashOf` (`// hashBase` → `eco.int.div`; `modBy hashBase` →
  `eco.int.modby`) and the smart constructors. With the constant visible:
  - `IntModByOpLowering`'s `select(isZero, 1, C)` folds;
  - `srem` by 2^26 plus the sign fix becomes mask arithmetic;
  - `sdiv` becomes a shift.
  - `TypedOptimized.globalMixHash` (`:350-353`) already hand-inlines the literal: precedent for
    the manual workaround this plan makes unnecessary.
- **`branchFactor`:** the literal 32, phase 1.
- **`shiftStep`:** a closed body over `branchFactor` plus intrinsic ops.
  - Phase 1 already turns its body into `ret 5` in LLVM.
  - Phase 2 removes the calls to it (`getHelp`, `setHelp`, `insertTailInTree`, `push`).
- **`bitMask`:** `lshr(0xFFFFFFFF, 32 - 5)` = 31, phase 2. It is hot on every `Array.get`
  (`Bitwise.and bitMask index`) and is the largest on-arm residue (0.04 %).
- **`Array.empty`:** `Array_elm_builtin 0 shiftStep …` is `!eco.value` and CAF-memoized. Its
  `shiftStep` reference folds harmlessly.

## 5. Design

### 5.1 The map and the emission rule

`constThunkBySpec : Dict SpecId ConstThunk` is built in `Backend.elm` beside
`buildConstCtorBySpec`, installed with `Ctx.withConstThunkBySpec`, and consulted in
`generateVarGlobal`'s arity-0 arm **after** the null-cons and `Nothing` arms. The rule: **the
folded value must have exactly the MLIR type the replaced `eco.call` had**
(`Types.monoTypeToAbi sig.returnType`), so no consumer can observe the change.

| body kind | emitted at reference | ABI check |
|---|---|---|
| `LInt` | `arith.constant : i64` (via `generateLiteral`, `Expr.elm:589-680`) | return ABI is i64: `MInt` or `MVar CNumber` |
| `LFloat` | `arith.constant : f64` | `MFloat` |
| `LChar` | `arith.constant : i16` (`decodeCharLiteral`) | `MChar` |
| `LBool` | `eco.constant True/False` as `!eco.value`, **not** i1. CGEN_009: Bool is `!eco.value` at ABI, and the call returned `!eco.value`. `buildConstCtorBySpec` skips True/False *ctor specs* only because those flow through `Test.IsBool` paths; a Bool *thunk* reference has no such path | `MBool` |
| `MonoUnit` | `eco.constant Unit` | `!eco.value` |
| `LStr` | **not in v1** (Q2) | — |
| `MonoVarGlobal s` (an alias) | Whatever `s` resolves to (fuel 8, in-progress set). The chain end must also consult `nullConsBySpec`/`constCtorBySpec`. An alias to a nullary ctor or enum (`defaultMode = Normal`) is today a **CAF-memoized** thunk: `cafMemoQualifies` admits a `MonoVarGlobal` body (`Functions.elm:588-604`), so every reference pays the CGEN_068 slot diamond. Folding it to the embedded constant is the CGEN_079(e) pattern. **Refuse** a chain that ends at an arity > 0 spec (point-free function alias), a `MonoExtern`, or any spec whose ABI differs | same ABI |

Config: `constThunks` (env `ECO_CONST_THUNKS=0` escape). It needs a hash token per the
`ctori` convention (`Compiler/Eco/Config.elm:40, ~1336`). Add census counters (thunks folded by
kind, reference sites folded), printed on stderr under the existing report flags.

### 5.2 Phase 1: literal and alias bodies

- **Coverage:** `hashBase`, `branchFactor`, `BitSet.wordSize` (`Compiler/Data/BitSet.elm:21-60`,
  `// wordSize` and `modBy wordSize`), the CtorTag constants, about 50 compiler Int literals,
  Char/Bool literals, and `pi`/`e` (a `MonoVarKernel` arity-0 body hitting
  `ConstantFloat`, `Expr.elm:845`).
- **No semantic risk.** The emitted op is literally the op the thunk body emits; only the call
  disappears.

### 5.3 Phase 2: closed bodies

**2A, recommended: closed-body substitution at codegen.** A thunk is *substitutable* when its
body, after alias resolution, is built only from:
- literals;
- substitutable thunk references (recursion, depth ≤ 4);
- `MonoLet`/`MonoDef` of such, and `MonoVarLocal`s bound by those lets;
- `MonoIf` whose conditions are such. This is needed only for the four cold Char
  `if isWindows …` thunks, so **leave it out of v1** unless the census shows a hot one;
- saturated calls that codegen would lower to a **pure, LLVM-foldable intrinsic**, through both
  the `MonoVarKernel` and the elm/core `maybeCoreInfo` routes. Use
  `Intrinsics.kernelIntrinsic home name argTypes resultType`, with Mono arg types, intersected
  with the fixed §5.4 op list. `gateIntrinsic` (`Expr.elm:1387`) **cannot** be called at map
  build: it takes the SSA arg types that exist only at emission. Every arithmetic intrinsic on
  the list hits its unconditional `_ -> Just` arm, so nothing is lost. If emission still
  declines the intrinsic, `generateExpr` emits the same kernel call the thunk body emits. That is
  correct, only unfolded; count such sites in the census. A `MonoVarGlobal` callee that does not
  resolve to a core intrinsic refuses the thunk.

The op whitelist (§5.4) excludes anything lowered to a runtime call (`eco.int.pow` →
`getOrCreateIntPow`) or anything that allocates. The size budget is ≤ 24 Mono nodes after
expansion.

At a reference, emit `generateExpr` on the body **in place, under a fresh lexical scope**. Model
it on `generateDefine`'s `ctxFreshScope` (`Functions.elm:635-637`), but keep the caller's
counters. Restoring only `varMappings` and the defined-SSA set is **not enough**:
- `addPlaceholderMappings` (`Expr.elm:5047-5071`) **reuses** an entry of
  `ctx.currentLetSiblings` with the same name. A substituted `let base = …` (the inlined
  `logBase` body binds `base` and `number`) inside a caller let group that also binds `base`
  would therefore write the *caller's* placeholder SSA var. The result is an SSA redefinition or
  a silent miscompile.
- Other name-keyed scope fields can leak the same way: `externBoxedVars`, `splitAggParams`,
  `decoderExprs`, `fwdRefdLetNames`, `tailRecLetBody` and `sretTailLayout`.

The rule:
- **reset** the scope fields (`varMappings`, `currentLetSiblings`, `definedSsaVars` and the
  name-keyed fields above);
- **thread** the accumulators (`nextVar`, `nextOpId`, `pendingLambdas`, `pendingFuncOps`,
  `kernelDecls`, `typeRegistry`);
- **restore** the caller's scope fields afterwards;
- register the result var the way the existing constant arms do.

Pin this with a test where the caller has a let sibling named `base`.

**Semantics are equal by construction:**
- the same Mono expression goes through the same `generateExpr`, so the same eco ops come out;
- the thunk is pure and total (whitelist). Scalar thunks are not memoized, so the old code
  evaluated the body at every reference anyway. A non-literal **Bool** thunk *is* memoized
  (`!eco.value`). Substituting it trades one memoized evaluation for one per reference: equal in
  value, and free once LLVM folds;
- LLVM then constant-folds with exactly the semantics it applies today, IPSCCP included.

If LLVM cannot fold (`-O0`), the code computes inline what the call computed; correctness is
unchanged.

**2B, the outline's evaluator: feasible, not recommended for v1.** It is a fuel-bounded Elm
interpreter over the same expression subset that produces an `LInt`/`LFloat`/`LBool` and then
uses the §5.1 emission. Its only advantage is a value visible to front-end passes (Q4). Its
costs are the obstacles in §5.4 and §5.5.

### 5.4 Operations and exact semantics (what 2B must match; what 2A's whitelist allows)

The semantics that matter are the **intrinsic lowerings** (`EcoToLLVMArith.cpp`), not the C++
kernels. The kernels differ: for example, `Basics.cpp:92-103` `modBy` *throws* on 0, while the
intrinsic returns 0 (`:83-131`). The kernel path is reached only when `kernelIntrinsic` declines.

| op | lowering | refuse when (2A and 2B) | 2B-only hazard |
|---|---|---|---|
| int add/sub/mul/negate | `arith` i64 wrap | — | JS-hosted compiler: doubles beyond 2^53 → keep \|v\| < 2^53 |
| `idiv`/`modBy`/`remainderBy` | sdiv/srem + zero guard (+ floor fix) | divisor 0 (guard semantics are compiler-specific; keep them out) | JS `idiv` is `\|0`, 32-bit |
| `Bitwise.and/or/xor/shl/shr/shru` | `arith` i64; shifts are poison for amount ∉ [0,63] (`:809-819`) | amount ∉ [0,63] | JS is 32-bit: operands must be in [0,2^31), or [0,2^32) for `shru` with amount ≥ 1 (`0xFFFFFFFF >>> 27` = 31 on both hosts) |
| `toFloat` | `sitofp` | — | exact below 2^53 |
| `fdiv`/fadd/fmul | IEEE, no fast-math flags | — | none, if the compiler build adds no contraction |
| `log`, `sqrt`, `sin`… | `llvm.*` → libm at runtime, LLVM host-libm folding at compile time | — | Elm has no `log` primitive. 2B must evaluate `fdiv(log a, log b)` as `logBase b a` (it compiles to the same ops, so it is bit-identical on the native host) and refuse a standalone `log`. A JS host uses V8's `Math.log`. musl-built (release) vs glibc-built hosts may differ in the last ulp |
| `ceiling`/`floor`/`truncate` | `llvm.ceil/floor` + `fptosi` (poison out of range) | NaN, ±inf, \|v\| ≥ 2^53 | ceiling(5.0 ± 1 ulp) flips 5↔6: the evaluator's log must be bit-equal to the runtime's |
| `round` | `llvm.round`: half away from zero | NaN/inf/range | JS `Math.round` is half-up: refuse exact −k.5 |
| `pow` (Int) | runtime call | always (no LLVM fold) | — |
| `Debug.*`, any allocation, any non-intrinsic kernel | — | always | — |

**The `log` question, resolved for 2A.** Runtime `shiftStep` computes `log` with the target's
libm; LLVM folding uses the compiling host's libm. Today's prologue-on compiler already ships
the LLVM-folded value, so 2A introduces no new semantic class. For `log(32)/log(2)`, glibc, musl
and V8 all give exactly 5.0, but that is a per-input fact, not a theorem.

### 5.5 Float constants in MLIR

- **Bytecode path:** exact. `Mlir/Bytecode/AttrType.elm:985` writes `float64` bits.
- **Text path** (opt-in `--text-mlir` only; the default and the self-compile write bytecode):
  inexact. `Pretty.elm:579-597` prints `String.fromFloat`. Natively that is `std::to_chars`
  shortest round-trip (`runtime/src/allocator/StringOps.hpp:1199-1217`), so most values are
  exact. But an output without a `.` is re-formatted with one decimal place, giving `0.0` or
  garbage. That covers `1e-09` (`1e-9` on the JS host), `1e+21`, `NaN`, `Infinity`, and `-0.0`,
  whose `fromFloat` is `"0"`, so the sign is lost.
- **Impact:** 2A emits only literals already in the source (no new exposure). 2B must refuse
  non-finite results, and results whose `fromFloat` lacks a `.`, unless Pretty is first fixed to
  emit MLIR hex floats (`0x… : f64`). That fix is recommended independently; file it as its own
  item.

## 6. Coverage estimate (approximate, from grep; Step 0 replaces it with a census)

| population | count | foldable by |
|---|---|---|
| compiler `src/`: Int literal thunks (`tk*` census tags, CtorTag, BitSet, bytecode flags, `hashBase`…) | ~50 | P1 |
| compiler: Char literal (`fpPathSeparator`), Bool literal (`isWindows` ×2), Char `if isWindows then …` ×4 | 7 | P1 / 2A (`MonoIf`) |
| compiler: Int expression (`registryTtlMs = 30 * 60 * 1000`) | 1 | 2A |
| compiler: String literal / String expression | 10 / 7 | not v1 / never |
| elm/core: `branchFactor` / `shiftStep`, `bitMask` / `pi`, `e` | 1 / 2 / 2 | P1 / 2A / P1 |
| deps: VLQ `maxInt = 2 ^ 31 - 1`, numeric-decimal `maxBound` (`pow`) | 3 | no (pow) |

Hot ones: `hashBase`, `branchFactor`, `shiftStep`, `bitMask`, plus maybe `BitSet.wordSize`. Most
of the rest are cold census tags. IPSCCP's 14 thunks are the reference set; the census must
show it as a subset of what this plan folds, **or name the reason for each exception**. For
example, IPSCCP may have folded through an op that the §5.4 whitelist refuses on purpose.
Alias-to-enum/ctor thunks (§5.1) are a further census class: CAF-memoized today, foldable by
phase 1.

## 7. Semantics, invariants, fixed point

- **Purity and totality:** only whitelisted total ops on in-domain constants are substituted.
  Crashes (`modBy 0`), poison, `Debug` and non-termination are refused, so no observable
  behaviour changes. Elm rejects cyclic value definitions; the in-progress set guards anyway.
- **Invariants:**
  - REP_*: the ABI type is preserved (§5.1).
  - CGEN_068, HEAP_035: no new slots; scalar thunks still unmemoized.
  - FORBID_OPT_003: per-SpecId and no value sharing; a substituted body is per reference site,
    never a merged slot.
  - CGEN_019: Bool and Unit use `eco.constant`.
  - Add a **new CGEN row** (next free id: CGEN_081) modelled on CGEN_079: "constant-thunk
    folding is a perf layer; the thunk `func.func` still returns the same value for any path not
    routed through the map; 2A substitution emits under a fresh lexical scope (§5.3)".
- **Bootstrap:** the compiler's own MLIR changes (it references `hashBase` and Array), so a
  default flip needs one extra turn: A≠B is propagation, the gate is B==C. The map is built by
  an `Array.foldl` in SpecId order, and substitution is pure, so the output is deterministic.
  - `selfcompile.sh` ends with `cmp … ecoGCR.mlir`. That cmp **fails by design** for every 04
    arm until the reference is regenerated at B==C.
  - Use a different artifact check: the prologue ON and OFF arms of one compiler differ only in
    lowering, so their `sc-*-out.mlir` must be **byte-identical to each other**.
- **JS-hosted stage:** 2A evaluates nothing in Elm, so it is host-independent. 2B needs the
  domain guards in §5.4.

## 8. Steps and acceptance criteria

All self-compiles use `stats-backend-opt/selfcompile.sh` with interleaved arms, N = 3,
medians, under the current default (cgu). "OFF" means `ECO_IPO_PROLOGUE=0`.

**Step 0: measurements and shape confirmation** (no code change beyond a census flag).
1. Have the census flag dump the **final Mono bodies** of the four hot thunks from the
   **self-compile itself**. A 10-line `ecoc --emit=mlir` program is only a cross-check: inliner
   decisions depend on context, and the self-compile runs the solver engine. Record whether
   `logBase` is inlined (the symbol grep in §1 says yes), what let-names the inlined body binds,
   and which callee forms are used (`MonoVarKernel` or a core `MonoVarGlobal`).
2. Run the census on the self-compile: arity-0 specs by ABI kind × body class (literal, alias,
   alias-to-ctor, 2A-substitutable, other) and reference sites per class, weighted by the
   `rt-off` perf rows.
3. Run the E2E suite once with `ECO_IPO_PROLOGUE=0` and no compiler change: `--target full` and
   the AOT Gate B. This de-risks Step 3 early, because the IPO entry measured the self-compile
   only.
4. Exit: a table replacing §6; `shiftStep` and `bitMask` are classified 2A-substitutable or the
   blocker is named. If `logBase` turns out to be a call, 2A needs a one-level callee-body
   substitution (§10 R3).

**Step 1: phase 1** (literal + alias + Unit/Bool/Char/Float).
- Gates: `elm-tests`, `cmake --build build --target full` (E2E), fixed point (B==C), and the
  census equals Step 0's literal class.
- Perf: N = 3 OFF + P1 against today's ON and OFF, re-measured **in the same interleaved
  session**. 110.33 s is a past session's number. **Accept** if OFF + P1 ≤ (same-session OFF)
  − 1.2 s, which is hashBase about 0.8 s plus most of the `log` cost. The IPO ranges were
  ±0.35 s, so 1.2 s is resolvable at N = 3. Perf must show `log` and `hashBase` gone from the
  hot list. Any arm needs a compiler built **by** a P1 compiler (one bootstrap turn), not just
  re-lowered.
- Loop verdict per `backend-opt-loop` rules (codegen-changing ⇒ recursive-tax gate).

**Step 2: phase 2A** (closed-body substitution).
- Gates as Step 1, plus a codegen pin test that a reference to a closed `ceiling (logBase 2 32)`
  thunk emits no `eco.call`, and an E2E Array suite run with the flag on and off.
- **Accept** if OFF + P2 ≤ ON-today (108.40 s) within noise. Perf must show
  `Array_shiftStep`, `Array_bitMask` and `Array_branchFactor` at 0 samples.
- Also run ON + P2. If ON + P2 < OFF + P2 by more than the noise (about 1.3 %), something else
  in the prologue matters: stop and attribute it before Step 3.

**Step 3: drop the cgu IPO prologue** (a loop step).
- **Lowering:** −5.7 to −7.7 s serial; wall 44 → about 37–38 s. **Measure it; do not assume
  it.** Also count the functions and instructions that reach externalize + serialize with and
  without the prologue. Its GlobalDCE also removes whatever the passes between internalize + DCE
  (TL 15.2 s) and the prologue (18.7 s) orphaned: marker expansion, capacity-hoist,
  `expandInlineAllocs`, the `$cap` prepass and gc-leaf propagation. `EcoBackend.cpp:521-526`
  calls it "not redundant on the split path". If the count grows materially, **keep a bare
  GlobalDCE** (0.2–0.8 s) and drop only IPSCCP.
- **Gates:** `--target full` E2E and the AOT Gate B with the prologue dropped, plus the fixed
  point. The IPO entry ran only the self-compile with the prologue off.
- **Self-compile:** the recursive-tax check, N = 3, against the Step-2 compiler with the
  prologue ON. Accept within 3 % (expect flat).
- Keep `runCheapModuleIPO` reachable behind an inverted diagnostic (`ECO_IPO_PROLOGUE=1`) for
  one series.

**Step 4: cleanup.**
- Delete the diagnostic and `runCheapModuleIPO` once 03 lands.
- Update the TL row in the master plan and the research §5 verdict.

**Step 5 (optional): 2B or the Mono rewrite (Q4)**, only if a later workload shows a value that
the front end needs.

## 9. Dropping the prologue: what else it does, and plan 03

`runCheapModuleIPO` (`EcoBackend.cpp:499-556`) is IPSCCP without function specialization, then
GlobalDCE. The attrs pair is off under cgu (`withFunctionAttrs=false`, A1b).

| prologue effect | after this plan |
|---|---|
| thunk return constants (the measured +1.8 %) | done by 04, with calls deleted too |
| 2,662 constant arguments, 1,615 dead blocks (mostly `Mlir_Bytecode_*`), nuw/nsw flags | lost. No runtime effect measured; IR +0.2 % for partition opt/emit, about 0.03 s wall |
| GlobalDCE (0.2–0.8 s): cleans what IPSCCP orphaned before serialize, **and** whatever the post-internalize LLVM steps (markers, capacity-hoist, `$cap`, gc-leaf; TL 15.57–18.68) orphaned | Folded thunk funcs die in the exe-path internalize + GlobalDCE (TL 15.20–15.57). The second category is **unmeasured**: Step 3 counts it, and a bare GlobalDCE is the fallback |
| non-exe outputs (`--emit=obj/.so`), `--parallel-opt=none`, JIT, dev | the prologue never ran or is replaced by whole-module `-O2` (unchanged); dev skips it since DV1 |

**Plan 03.**
- 03 replaces internalize + GlobalDCE with MLIR `EcoReachability`.
- After 04, fully folded thunks are unreferenced already in MLIR, so 03 erases them before
  translation (slightly less translation work).
- 03's validate mode compares against LLVM DCE; both see the same unreferenced thunks, so they
  agree.
- Order: in the master plan's risk order, 03 now lands before 04. So when 04 drops the
  prologue, 03's validate mode must also account for the prologue's second GlobalDCE: count
  what it removes (Step 3) and keep a bare GlobalDCE as the fallback.

## 10. Obstacles and risks

| # | risk | likelihood | mitigation |
|---|---|---|---|
| R1 | Bool fold changes an SSA type (i1 vs `!eco.value`) and breaks a consumer | med if done naively | emit `eco.constant True/False` (`!eco.value`), the call's own type |
| R2 | 2A let-names leak into the caller's scope: `varMappings`, and **`currentLetSiblings` placeholder reuse** (`Expr.elm:5047-5071`), plus the other name-keyed fields | high if unhandled | fresh-lexical-scope emission (§5.3); pin tests with a shadowing local **and** a same-named let sibling |
| R3 | `logBase` still a separate spec, so 2A cannot see through the call | low: `Basics_logBase` is absent from the self-compile MLIR (§1) | one-level callee substitution with argument let-binding (same scope rule), or 2B for that shape only |
| R4 | transcendental fold value differs from the target libm (cross-libm, musl vs glibc) | low | identical exposure to today's LLVM folding; 2A adds none; document in the CGEN row |
| R5 | 2B host divergence (JS 32-bit Ints and bitwise, `Math.round`, V8 `log`) | real for 2B | domain guards (§5.4); prefer 2A |
| R6 | text-MLIR float printing (`1e-09` → `0.0`, `-0.0` → `0.0`) | real, pre-existing, but `--text-mlir` only (bytecode is the default and the bootstrap format) | 2B refuses such values; fix Pretty with hex floats as a separate item |
| R7 | IR growth from substitution at many sites | low (bodies ≤ 24 nodes; LLVM folds them away) | budget, plus census of substituted sites |
| R8 | a poison op (shift ≥ 64) folded into "anything" | low | refuse out-of-range amounts at the predicate |
| R9 | the fixed point needs an extra turn; a stale `.mlir` hides changes | certain / procedural | `--target full`; B==C gate |
| R10 | unit tests through `generateMlirModule` do not see the maps | by design | add a streaming-path pin test, or install the maps there behind the flag |
| R11 | removing calls changes gc-leaf / `$cap` / statepoint layout (plans 01 and 02) | expected, benign | the recursive-tax gate; this is the kind of change those gates exist for |
| R12 | the alias chain lands on a point-free function spec, an extern or a different ABI | med if unguarded | refuse (§5.1); fold only literal, kernel `ConstantFloat`, null-cons or `Nothing` chain ends |
| R13 | dropping the prologue's GlobalDCE leaves dead post-internalize code in the partitions | unknown | Step 3 count; keep a bare GlobalDCE if material |
| R14 | the prologue-off path was never E2E-tested (the IPO entry was self-compile only) | unknown | Step 0.3 E2E + AOT run with `ECO_IPO_PROLOGUE=0` before any code |

## 11. Open questions

- **Q1:** Does the census find any hot thunk outside the four named ones (`BitSet.wordSize`?)?
  Weight by the perf rows, not by site counts (lesson: site counts mispredicted weight three
  times in the LSS arc).
- **Q2:** String literal thunks. Each folded reference would mint its own `__eco_str_N` + slot
  (`EcoToLLVMGlobals.cpp:740-790`) instead of sharing the thunk's. Measure IR and globals
  growth against the saved call; default: no.
- **Q3:** Should 2A also cover non-scalar closed thunks (`Nothing`/null-cons are already
  covered)? No: those are CAF-memoized `!eco.value`, which is the CafHoist domain.
- **Q4:** Is a Mono-level rewrite (literal visible to `BytesFusion`'s `CountConst`, MonoCse and
  the inliner) worth a re-prune? Only with a measured consumer.
- **Q5:** Should the Pretty hex-float fix land first, so the text and bytecode paths are equally
  exact regardless of 04?

## Adversarial review (2026-10-02)

Read-only review against the tree: code, the IPO/TL entries, and the self-compile artifacts.
Nothing was built or run. Each issue is fixed in place above.

**Wrong or overstated claims (corrected)**
1. **"The bootstrap self-compile writes text `.mlir`" was wrong.**
   - Evidence: `build/compiler/build-kernel/bin/sc-final-r1-out.mlir` starts with the bytecode
     magic `ML\xefR`. Text is opt-in (`--text-mlir`, `Terminal/Make.elm:342`; `Backend.elm:174`
     is the text writer and `:307` the bytecode one).
   - So the Pretty float bug does not touch the bootstrap. Also added: `-0.0` prints as `0.0`.
   - Fixed in §0, §5.5 and R6.
2. **"Prologue-off can beat today's prologue-on" was overstated.**
   - Of the on-arm residue, only the thunk calls are foldable: 0.06 %, about 0.1 s. `mixHash`'s
     0.03 % is its own body.
   - Fixed in §0; the target is parity.
3. **2A's claim that "scalar thunks are not memoized, so the body was evaluated at every
   reference anyway" is false for Bool.**
   - Bool is `!eco.value`, so `cafMemoQualifies` tags a non-literal Bool thunk
     (`Functions.elm:588-604`).
   - The value is still equal; only the evaluation count changes before LLVM folds. Fixed in §5.3.
4. **2A cannot call `gateIntrinsic` at map build.**
   - `gateIntrinsic` takes SSA arg types (`Expr.elm:1387`).
   - Fix: Mono-typed `kernelIntrinsic` intersected with the §5.4 list. All arithmetic intrinsics
     take the gate's unconditional arm. Fixed in §5.3.
5. **Mono engine.** The self-compile runs `ECO_MONO_ENGINE=solver`, so the relevant literal
   specialization is `MonoSolver/Translate.elm:542`, not only `Specialize.elm`. Fixed in §2.
6. **R3 was "unknown".**
   - `grep -a` of the self-compile MLIR finds `Array_shiftStep_$_180`, `Array_bitMask_$_196`,
     `Array_branchFactor_$_174`, `…hashBase_$_32060` and `…mixHash_$_32053`, but no
     `Basics_logBase`, so `logBase` is inlined at Mono level.
   - Downgraded to low. Step 0 now reads the self-compile's own Mono bodies instead of a 10-line
     program.

**Missed hazards (added)**

7. **Let-scope leak is worse than `varMappings`.**
   - `addPlaceholderMappings` (`Expr.elm:5047-5071`) reuses a same-named entry of
     `currentLetSiblings`. A substituted body's `let base`/`number` (the inlined `logBase`)
     inside a caller let group with a sibling of that name would redefine the caller's
     placeholder SSA var.
   - `externBoxedVars`, `splitAggParams`, `decoderExprs`, `fwdRefdLetNames`, `tailRecLetBody` and
     `sretTailLayout` are name-keyed or positional in the same way.
   - Fix: fresh-lexical-scope emission modelled on `generateDefine`'s `ctxFreshScope`
     (`Functions.elm:635-637`), keeping the accumulators. Added to §5.3, R2 and the CGEN_081
     text.
8. **Alias chains are under-specified.**
   - A chain ending at an enum or nullary ctor is today a CAF-memoized thunk (a `MonoVarGlobal`
     body qualifies), so folding it via `nullConsBySpec`/`constCtorBySpec` is a free extra win.
   - A chain ending at a point-free function spec, an extern or a different ABI must be refused.
   - Added to §5.1, §6 and R12.
9. **Dropping the prologue is not "IPSCCP only".**
   - Its GlobalDCE is the only DCE between the post-internalize LLVM steps (markers,
     capacity-hoist, `expandInlineAllocs`, `$cap`, gc-leaf; TL 15.57–18.68) and serialize.
     `EcoBackend.cpp:521-526` calls it "not redundant on the split path".
   - Step 3 now counts what reaches serialize and falls back to a bare GlobalDCE. Added R13.
10. **The prologue-off configuration was never E2E-tested.** The IPO entry is self-compile only.
    Step 0.3 and the Step 3 gates now add `--target full` + AOT Gate B. Added R14.
11. **Measurement hygiene.**
    - Step 1's threshold is now relative to same-session OFF, not 110.33 s.
    - Arms need a compiler built **by** the 04 compiler.
    - `selfcompile.sh`'s `cmp ecoGCR.mlir` fails by design until the reference is regenerated.
      The ON/OFF arms' outputs must be byte-identical to each other (§7).

**Checked and found correct**
- Every value-position arity-0 reference goes through `generateVarGlobal` (`Expr.elm:436`):
  - the other `MonoVarGlobal` matches in `Expr`, `TailRec`, `Backend` and `BytesFusion` are
    callee-position calls, analyses, or route operands back through `generateExpr`
    (`BytesFusion/Emit.elm` `compileExpr`);
  - captures are locals;
  - kernels reference no Elm thunk symbols (`eco-kernel-cpp/src/eco/Hash.cpp` has its own
    `kBase`).
- The JS backend is untouched. 2A and phase 1 do no host arithmetic, so the JS-hosted stage
  emits identical MLIR.
- Line citations:
  - `Expr.elm:684-765`, `589-680` and `845`;
  - `Context.elm:224-225`, `Backend.elm:174-184`, `307-317` and `1392-1460`;
  - `Functions.elm:588-684`, `EcoBackend.cpp:499-556` and `3795-3815`;
  - `EcoToLLVMArith.cpp` (modBy guards, `LLVM::LogOp`, ceil + `fptosi`, `ShRUIOp`);
  - `Intrinsics.elm` (`logBase` → `Nothing`, `log`/`ceiling`/`toFloat` intrinsics);
  - `Basics.cpp:92-103`, `Config.elm:40/1336`, elm/core `Array.elm` and `Basics.elm`.
- `bitMask` = 31 on both i64 and JS 32-bit `>>>`.

**Residual concerns**
- **LLVM's `llvm.log` folding uses the compiling host's libm.** The static-musl release
  compiler and glibc dev builds fold with different libms, the same exposure IPSCCP has today.
  For `log 32 / log 2` both give 5.0; that is per input, not a theorem.
- **Phase 1 leaves `shiftStep()` calls** until 2A, and its "`ret 5`" relies on the inlined
  `logBase` being in `shiftStep`'s own body (step 0.1).
- **2A grows the MLIR** before LLVM folds: about 10 eco ops per `bitMask` site. Expected
  negligible against 8.4M instructions; the census should report the `out.mlir` delta.
