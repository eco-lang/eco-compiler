---
status: done
updated: 2026-11-22
---

# Call staging from lambda sets

## 0. Goal

Know at compile time how many arguments a closure value takes, at calls whose callee is a
parameter, local or call result, where step 5 of GlobalOptimize today records
`CallSegmentationUnknown` or `CallGenericApply`. Use that knowledge first where a wrong answer
costs only speed (part A), and trust it only later, if A leaves a gap worth closing (part B).

This replaces bringing back the staging solver deleted in October
(plans/staging-honesty-and-production-test-pipeline.md, P3). That solver ran its own union-find
flow analysis over parameter, capture, field and join slots. Lambda-set specialization (LSS)
already computes the same flow during monomorphization: a complete set on an arrow names every
function that can reach it. A call's first-stage arity can be read from the set on its callee's
type and the arities of the set's members, with no second analysis.

## 1. Why

- **The parser slowdown.** `Parser.Advanced.loopHelp` applies its callback to the state, then
  applies the returned parser to the input. Erasure removes the `Parser` unwrap between those two
  applies. `FusePapExtendChainPattern` (runtime/src/codegen/Passes/EcoPAPSimplify.cpp) then merges
  the two generic `eco.papExtend`s into one generic extend of two arguments on a one-argument
  closure. That over-application cannot take the guarded `sat[N]` fast edge, which requires the
  site's N to equal the closure's remaining arity
  (design_docs/theory/closures-and-calls.md). It goes through `eco_apply_closure_eval`, which
  saturates the first stage and recurses (CGEN_058). In expr-parser that is 0.85 M extra runtime
  calls.

  With **every** generic merge switched off, as an experiment, expr-parser went 163 -> 140 ms and
  lexer 147 -> 124 ms. A stops only the merges whose first extend carries a hint (§4 A), so those
  figures are an **upper bound** for A, not a prediction. P2 measures the real figure.
- **Over-application in general.** The self-compile executes 15.1 M generic applies that pass
  more arguments than every member of their callee's set takes (§2). Each takes the same runtime
  path. Split at the set's arity, each becomes two calls that can both take the fast edge.
- **What it does not buy.** A generic apply that passes exactly the closure's arity already takes
  the guarded fast edge. Making it known-arity saves only the guard. The October decision (P4 of
  the plan above: the whole generic path is ~1.8 % of self-compile cycles) still holds for those
  calls. The payoff is in merged and over-applied calls.

## 2. Census (2026-11-22)

`Compiler.MonoOpt.GenCallCensus` counts each generic call under `lss<Class>:<tag>`. The class
comes from the lambda set on the callee's type (`Mono.headAnno`) and the first-stage arities of
the set's members (`GenCallCensus.memberArities`, read from the graph before `Mono.clearLssTables`).
It runs under `ECO_STAGING_REPORT=1` and prints on the `lss gencall:` line. The classes:

- **`lssExact`, `lssOver`, `lssUnder`:** a complete set whose members all take N arguments in
  their first stage; the call passes exactly N, more, or fewer.
- **`lssDisagree`:** a complete set whose members' first-stage arities differ.
- **`lssEmpty`:** a complete set with no members. None were seen.
- **`lssUnresolved`:** a complete set with a member whose arity the census cannot read.
  `lssUnresolvedWhy+<why>` gives the reason:
  - `kernel`: a kernel function;
  - `none`: a member with no closure and no origin;
  - `define`, `node`, `noSpec`: a global whose node shows no arity. None were seen.
- **`lssVar`, `lssPartial`, `lssTop`:** no complete set (a set variable, a lower bound, or ⊤).
  `lssTopWhy+<label>` gives the ⊤ provenance.

After P1 (§8) kernel members resolve, so the `kernel` reason no longer occurs.

### Static sites

| class | benchmarks (`Bench.elm`) | E2E corpus (1,588 programs) | self-compile |
|---|---:|---:|---:|
| exact | 1,106 (74.8 %) | 29,035 (92.9 %) | 15,311 (61.1 %) |
| over | 0 | 35 | 205 |
| under | 16 | 36 | 136 |
| disagree | 0 | 9 | 6 |
| unresolved | 39 (kernel 39) | 302 (kernel 291) | 58 (kernel 19, none 39) |
| var | 30 | 211 | 1,080 |
| ⊤ | 287 | 1,638 | 8,274 |
| total | 1,478 | 31,266 | 25,070 |

⊤ is almost all `clsDestr`: 256 of 287, 1,342 of 1,638, and 7,853 of 8,274. These are locals
bound by destructuring a tuple, record or constructor. A set is not carried through a data
structure's fields (see §6). The benchmarks' other 28 ⊤ sites are `declOther` globals.

### Executions

Measured with a temporary build (now reverted). It wrote each call's class into
`_gencall_reason`, was lowered with `ECO_GENCALL_COUNTERS=1`, and ran with `ECO_DISPATCH_STATS=1`.
When two applies are merged, the merged apply carries the second apply's reason. So a merged call
counts under the class of its second half.

| class | self-compile | all benchmark workloads, 1 run |
|---|---:|---:|
| exact | 111.8 M (36.9 %) | 33.1 M (33.0 %) |
| over | 15.1 M (5.0 %) | 0 |
| under | 1.1 M | 0.29 M |
| disagree | 0.22 M | 0 |
| unresolved | 0.60 M | 0.38 M |
| var | 19.9 M | 1.7 M |
| ⊤ | 135.0 M (44.6 %) | 65.1 M (64.8 %) |
| later stage of a stamped call (reason 9) | 19.3 M | 0 |
| total | 303.0 M | 100.5 M |

The self-compile made 80.5 M calls through the runtime's generic entry (`[dispatch-stats] gen`);
the rest took the inline fast edge.

In the parser workloads almost all generic executions are ⊤: expr-parser has 7.06 M ⊤ against
163 exact. They apply parser closures taken out of the erased `Parser` or returned by a call.

The merged callback apply in `Parser_Advanced_loopHelp_$_3044` is counted under ⊤ too, its
second half's class. Its first half is `lssExact` with arity 1. Six of the eight `loopHelp`
specializations already call the callback directly, through an LSS fast stamp (`singleton_fast`).
The other two, `_1011` and `_3044`, have callback sets with several members that all take one
argument. Those two are what A targets in the parsers.

## 3. What LSS already provides

- **Complete sets on arrows.** `LSet` means no function outside the set can flow through the
  arrow (`Mono.LambdaSetAnno`). Step 5 has no producer information for a parameter: such a call is
  `FromType`, and its staging is untrusted. The set supplies what is missing.
- **Keyed specialization.** A function is specialized per lambda-set demand. That is why most
  `loopHelp` specializations have a single callback and are already stamped.
- **Fast stamping** (`AbiCloning`). For a singleton set it removes the indirect call. It stays the
  larger lever for singleton sites. This plan covers the calls stamping leaves generic.
- **Member identity.** Each closure carries `lssMember` and `srcLambda`. `lssMemberOrigins`
  covers globals, constructors, kernels, accessors and partial applications of globals.
  `memberArities` reads arities from these.

The old solver recomputed this flow per slot class. The October census found zero disagreeing
classes in the self-compile and the E2E corpus. The census above agrees: only 6 to 9 sites have a
set whose members disagree.

**Not yet shown:** that a member id always names an *unapplied* closure. A partial application
of a *global* has its own origin (`OriginPap`). Whether a partial application of a *lambda* can
reach an arrow under the lambda's own member id has not been checked. If it can, the set's arity
overstates that value's remaining arity. That is harmless for A (guarded) and must be settled
before B (§5, B.3).

## 4. Part A: a guarded first-stage hint

A **hint** is the first-stage arity every member of the callee's complete set agrees on. Every
use of it is guarded at run time, so a wrong hint costs speed, not correctness.

The front end uses it in two ways:

- **Splitting.** It splits an over-applied generic call at the hint.
- **Marking.** It marks each generic extend with `_stage_hint`, so `FusePapExtendChainPattern`
  does not merge a following extend past the hint.

### A.1 A member-arity module

Move `MemberArities` and `memberArities` out of `GenCallCensus` into a new module
`compiler/src/Compiler/MonoOpt/MemberArity.elm`. Production code (step 5) will depend on it, and a
census module should stay read-only tooling. Change the representation so that kernel members
resolve:

```elm
type MemberArity
    = Known (Set Int) -- parameter counts of the closures/values carrying the member
    | KernelFlat -- a kernel function: its closure arity is its flattened type's
    | Unknown String -- why: "none", "define", "node", "noSpec"

memberArities : Mono.MonoGraph -> Dict Int MemberArity

{-| The first-stage arity all members of the callee type's head set agree on. -}
setArity : Dict Int MemberArity -> Mono.MonoType -> Maybe Int

{-| The census classification, shared so the census and the hint cannot drift. -}
type SetClass
    = SetTop String -- the topKindLabel
    | SetVar
    | SetPartial
    | SetUnresolved String
    | SetEmpty
    | SetDisagree
    | SetAgree Int

classify : Dict Int MemberArity -> Mono.MonoType -> SetClass
```

1. Port the body of `GenCallCensus.memberArities` unchanged, except:
   - an `OriginKernel` gives `KernelFlat` where it gave `Err "kernel"`;
   - `Ok s` becomes `Known s`, and `Err w` becomes `Unknown w`.

   Keep the precedence rule: an origin is added only when the member has no `Known` entry from a
   closure.
2. `classify` follows `GenCallCensus.lssKeys`'s `case Mono.headAnno t of` arms:
   - `LTop code` gives `SetTop (Mono.topKindLabel code)`; `LVar` gives `SetVar`; `LPartial` gives
     `SetPartial`.
   - `LSet members` resolves each member and unions the results:
     - a missing member gives `SetUnresolved "none"`, and an `Unknown w` gives `SetUnresolved w`;
     - a `KernelFlat` member contributes
       `List.length (Tuple.first (Mono.decomposeFunctionType t))`.

     Code generation gives a kernel function value that arity
     (`Ctx.kernelFuncSignatureFromType`, used for its `papCreate` in
     `Expr.generateFlattenedPartialApplication`). The kernel's type there is the same specialized
     arrow type the set sits on.

     The union then gives `SetEmpty` (no arities), `SetAgree n` (one arity) or `SetDisagree`
     (several).
3. `setArity m t` returns `Just n` for `SetAgree n` with `n >= 1`, and `Nothing` otherwise.
4. Rewrite `GenCallCensus.lssKeys` over `classify`, keeping its output keys byte-for-byte except
   `kernel`. Kernel members now resolve, so those sites move from `lssUnresolved` to
   exact/over/under. That is the intended change (P1 records it).
   - `GenCallCensus` re-exports nothing new.
   - `GenCallCensus.census` takes `Dict Int MemberArity`.

**Unit test:** `compiler/tests/Compiler/MonoOpt/MemberArityTest.elm` (test-layout rule: the same
folder as the source). Build small `MonoType`s by hand with `Mono.MFunction` and
`LSet`/`LTop`/`LVar` annotations and a hand-made `Dict Int MemberArity`. Check:
- `classify` for each `SetClass`;
- `setArity` is `Nothing` for `SetDisagree`, `SetUnresolved` and `SetTop`;
- a `KernelFlat` member on `Int -> Int -> Int` gives `SetAgree 2`;
- a `KernelFlat` member plus a `Known {1}` member on the same type gives `SetDisagree`.

### A.2 Step 5 records the hint

Files: `compiler/src/Compiler/IR/Mono.elm`, `compiler/src/Compiler/MonoOpt/GlobalOptimize.elm`.

1. **`Mono.CallInfo` gains `setArity : Maybe Int`**, documented as: "For a generic call
   (`CallSegmentationUnknown`, `CallGenericApply`): the first-stage arity every member of the
   callee's lambda set agrees on (`MemberArity.setArity`). Advisory: code generation uses it only
   behind run-time guards (CGEN_094)."
   - Set `setArity = Nothing` in `defaultCallInfo` and in every other `CallInfo` record literal.
     `grep -rn "evaluatorReturnType =" compiler/src compiler/tests` lists them: today
     `Mono.elm` has 1, `GlobalOptimize.elm` 3 and `IR/Mono/Traverse.elm` 2; skip the record
     updates among them.
   - The compiler will reject any literal you miss.
2. **`CallEnv` gains `memberArities : Dict Int MemberArity.MemberArity`.**
   - `emptyCallEnv` gives it `Dict.empty`.
   - `annotateCallStaging` gains a first parameter `arities` and starts from
     `{ emptyCallEnv | memberArities = arities }`.
3. **In `globalOptimizeWithStats`:**
   ```elm
   ( graph4Full, abiStats ) = AbiCloning.abiCloningPass census graph2
   arities = MemberArity.memberArities graph4Full    -- before clearLssTables empties origins
   graph4 = Mono.clearLssTables { keepOrigins = ... } graph4Full
   graph5 = annotateCallStaging arities graph4
   ...
   genCalls = if stagingCensus then GenCallCensus.census arities graph5 else Dict.empty
   ```
   `graph4Full` is then no longer kept alive into the census.
4. **In `computeCallInfo`'s `StageCurried` arm**, after `callKind`:
   ```elm
   setArity =
       case callKind of
           Mono.CallSegmentationUnknown -> MemberArity.setArity env.memberArities funcType
           Mono.CallGenericApply -> MemberArity.setArity env.memberArities funcType
           _ -> Nothing
   ```
   Put it in the returned record. The `FlattenedExternal` arm gets `Nothing`.
   - `annotateExprCalls`'s `MonoCall` arm copies stamp fields from `existingCallInfo`. Do **not**
     copy `setArity`: it is always derived.
   - Passes after step 5 (`CafHoist`, `Cse`, `CafDedupe`) move `CallInfo` verbatim (CGEN_069,
     CSE_001), so the field survives them.
5. **Compile-time cost.** `memberArities` was census-only and now runs on every build. It is one
   `foldExprAccFirst` over all nodes plus a `Dict` lookup per generic call. P2 checks the
   self-compile wall against the 5 % flag rule.

### A.3 Emission

File: `compiler/src/Compiler/GenerateMlir/Expr.elm`.

1. **A constant**, `stageHintMaxArgs = 8`. Its comment ties it to `emitSatBegin` in
   EcoToLLVMClosures.cpp, which gives no fast edge to a site of more than 8 new arguments. A hint
   above 8 is never emitted: the split would then make two runtime calls where the merged form
   makes one.
2. **A hint parameter on the generic emitters.** `generateGenericApply` and
   `generateUnknownSegmentationCall` gain a parameter `stageHint : Maybe Int`. When it is `Just h`,
   each adds `( "_stage_hint", IntAttr Nothing h )` to its `eco.papExtend` attributes. The
   attribute is emitted whatever `mono.stagingReport` says: unlike `_gencall_reason`, it changes
   code. Pass `Nothing` at every other caller, including `generateGenericApplyCoerced`'s
   existing callers.
3. **The hinted call.** In `generateCall`, the `CallGenericApply` and `CallSegmentationUnknown`
   arms keep their stamp checks first (`fastDispatchStamp`, then `fastDispatchStampStaged`: a
   stamp always wins). In the final `Nothing` branch, with `n = List.length args`:

   | `callInfo.setArity` | action |
   |---|---|
   | `Just h`, `1 <= h <= stageHintMaxArgs`, `h == n` | today's emission, with `stageHint = Just h` |
   | `Just h`, `1 <= h <= stageHintMaxArgs`, `h > n` | today's emission, with `stageHint = Just h` (lets fusion with the next extend proceed only up to `h`) |
   | `Just h`, `1 <= h <= stageHintMaxArgs`, `h < n` | `generateHintedSplitCall` (below) |
   | otherwise | today's emission, `stageHint = Nothing` |

   The `segmentation_unknown` arm's `List.isEmpty args` early return comes before all of this.
4. **`generateHintedSplitCall ctx callKindArm func h args resultType`** is modelled on
   `generateStagedFastDispatchCall`:
   ```elm
   batch1 = List.take h args
   rest   = List.drop h args
   stage1Type = peelArgs h (Mono.typeOf func)   -- the function value left after h arguments
   innerRes = <the arm's generic emitter> ctx func batch1 stage1Type (Just h)
   tailRes  = applySegUnknownToVar innerRes.ctx innerRes.resultVar innerRes.resultType rest resultType 11
   ```
   - **`peelArgs`.** Add `peelArgs : Int -> Mono.MonoType -> Mono.MonoType` to `Mono.elm`, beside
     `decomposeFunctionType`. It drops `k` parameters across `MFunction` stages. When `k` ends
     inside a stage of `p` parameters it returns that stage with its first `k'` parameters dropped
     (same annotation). It is only called with `k` below the type's flat arity, since `n > h` and the
     call type-checks.
   - **The inner extend's result.** It is a function value, so its ABI is `!eco.value` with no
     `_result_kind`. That is what the fast edge's result-kind check expects of a closure-returning
     stage.
   - **`applySegUnknownToVar` gains a reason argument.** It now writes reason 9 unconditionally.
     `generateStagedFastDispatchCall` passes 9 and the split passes 11. Document 11 in
     `gencallReasonAttr`'s comment: "the arguments beyond a hinted first stage".
   - **The split is always semantically equal** to the single generic apply. Generic apply is
     defined to saturate the first stage and apply the rest to the result (CGEN_058), and Elm
     application has no effects to reorder.
5. **As built.** One helper, `emitGenericPapExtend`, now builds every generic extend (call kind,
   reason, optional hint, result kind), and `generateGenericApply`,
   `generateUnknownSegmentationCall`, `applySegUnknownToVar` and the split share it.
6. **The census's view.** A split call's first extend keeps the callee reason (1 to 6) and its
   tail is reason 11. So the P2 counters show how many over-applied executions moved and how
   often the first stage takes the fast edge (`gen` falls).

### A.4 The fusion rule

File: `runtime/src/codegen/Passes/EcoPAPSimplify.cpp`, `FusePapExtendChainPattern::matchAndRewrite`.

1. **Refuse to fuse past the hint.** After the `hasOneUse` check:
   ```cpp
   // A generic extend carrying `_stage_hint = h` applies a closure whose lambda set says it
   // takes h arguments in its first stage (CGEN_094). Fusing a following extend past h would
   // turn a call that can take the fast edge into an over-application, which cannot.
   if (auto hint = prevExtend->getAttrOfType<IntegerAttr>("_stage_hint"))
       if (static_cast<int64_t>(prevNewargs.size() + curNewargs.size()) > hint.getInt())
           return failure();
   ```
   `prevNewargs` and `curNewargs` are read just below the check today, so move those two lines up.
2. **Keep the hint when fusion proceeds.** If the fusion goes ahead (an under-applying hinted
   extend whose fused count stays at most `h`), copy `prevExtend`'s `_stage_hint` onto `fusedOp`,
   so a third extend in the chain is held to the same bound.
3. **Update the documentation.**
   - Extend the pattern's docblock with both rules.
   - Mention `_stage_hint` in the `PapExtendOp` description in Ops.td, as a discardable,
     advisory attribute of generic mode that only EcoPAPSimplify reads. Do not add it to
     `arguments`: that would change the generated builder that the pattern calls positionally.
   - Only RCElimination and CheckEcoClosureCaptures run before EcoPAPSimplify
     (EcoPipeline.cpp), and neither rebuilds a `papExtend`, so a discardable attribute arrives
     intact.
4. **Lowering is unchanged.** `lowerGenericApply` and `lowerSegmentationUnknown` ignore the
   attribute.

### A.5 Invariants and docs

- **`design_docs/invariants.csv`, new row `CGEN_094`** (MLIR_Codegen; Closures; tested):
  "`_stage_hint = h` on a generic `eco.papExtend` is advisory. The front end writes it only from
  `CallInfo.setArity` (all members of the callee's complete lambda set take h arguments in their
  first stage), only for 1 <= h <= 8. It splits an over-applied generic call into a generic extend
  of the first h arguments and a `segmentation_unknown` extend of the rest
  (`_gencall_reason` 11). EcoPAPSimplify does not fuse a following extend into a hinted one past
  h. No lowering reads it. Every fast path it enables is the guarded `sat[N]` edge, so a wrong
  hint changes speed only."
  - Code: `Compiler.MonoOpt.MemberArity`, `Compiler.GenerateMlir.Expr` (generateCall,
    generateHintedSplitCall), EcoPAPSimplify.cpp (FusePapExtendChainPattern).
  - Tests: the P2 tests.
- **Amend `GOPT_016`:** "A `CallSegmentationUnknown` or `CallGenericApply` call carries
  `setArity` (CGEN_094); it does not change the call kind."
- **design_docs/theory/closures-and-calls.md:** one paragraph after the fast-edge paragraphs
  (around line 86) on hints: where they come from, the split, the fusion rule, why they need no
  trust.
- **design_docs/theory/compiler/global-optimization.md:** one sentence in the step 5 section,
  that step 5 reads member arities before step 4 clears the origins.

## 5. Part B: known arity from the set (trusted)

Only if P3 finds a gap worth closing. B removes the guard from `lssExact` calls and gives
`lssUnder` calls a typed `eco_pap_extend_l`.

1. Step 5 adds a third source of arity, `FromSet n`, beside `FromProducer` and `FromType` in
   `SourceArity`. A `FromType` callee whose `setArity` is `Just n` and that is not
   `isDynamicCallee` or `calleeHasPolymorphicReturn` becomes `CallDirectKnownSegmentation`, with
   `initialRemaining = n`.
2. **Excess arguments.** In `computeCallInfo` a `FromSet` call with excess arguments must not fall
   into `hasUnknownExcessArgs`. Expr.elm's `applyByStages` already gives the first batch
   `remaining_arity` and later batches `segmentation_unknown`, so no new lowering is needed.
   The engineer must still check `generateClosureApplication`'s handling of an empty
   `remainingStageArities`.
3. **What must hold first.** A known-arity apply is trusted completely. A saturating one with no
   fast evaluator still has the guarded edge, but falls back to `eco_closure_call_saturated`,
   which assumes the count. A partial one goes to `eco_pap_extend_l` unchecked. So B requires:
   - **Set completeness after every pass that makes or moves closures after LSS.** The set on a
     type must stay a superset of the closures that reach it. The passes:
     - GlobalOptimize step 1's wrapper closures (adopted members) and CAF moves;
     - `InlineSimplify` copies (srcLambda carried, LSS_008);
     - the `EraseWrappers` / `Representation.run` type rewrites;
     - `KnownCtorCase`, `CafHoist`, `Cse`.
   - **Member ids name unapplied values (§3).** A census first: in `memberArities`, also record
     every member id seen on a closure *value* that is a partial application. Partial
     applications are a `MonoCall` with fewer arguments than its callee's arity, whose result
     type's head set names the member. Require zero, or give `OriginPap`-style ids to lambda
     partial applications before trusting.
   - **A validating-build check.** Under `ECO_HEAP_VALIDATE`, a known-arity extend asserts,
     before it calls or extends, that the closure's remaining arity equals `remaining_arity`.
     Write it first, with a forged wrong `remaining_arity` as the negative control (a
     test/codegen lit test with `// XFAIL`-style expected abort, per the existing validate
     tests).
   - **Unchanged MLIR for `FromProducer` calls.** Compare the self-compile MLIR before and after:
     only `FromSet` sites may differ.
   - **Invariants:** GOPT_016 gains `FromSet`; design_docs/theory/compiler/global-optimization.md's
     "trust only what a producer shows" gains the complete lambda set as a producer.

## 6. Out of scope, recorded

- **⊤ through data fields** (`clsDestr`): 44.6 % of self-compile generic executions, and nearly
  all of the parsers'. Carrying sets through constructor fields is plans/lss-payload-set-slots.md.
  It was shelved on 2026-09-17 as too slow (~55 min against an 8-10 min self-compile) and because
  its target positions were measured cold. Since then:
  - erasure has made `Parser` values plain closures;
  - the self-compile takes about 75 s;
  - the execution counts above show ⊤ is hot.

  Recheck that plan's payoff with this census before reopening it.
- **Dispatch on sets with several members.** Compare the closure's code pointer with each
  member's and call the matching member directly. That would remove the indirect call at
  `lssExact` sites whose sets have a few members. It is a stamping extension in `AbiCloning`, and
  a separate plan.
- **Later stages of stamped calls** (reason 9, 19.3 M self-compile executions). LSS_039 drops the
  intermediate stages' annotations, so no set describes the closure the first stage returns. Not
  addressed here.
- **The 39 `none` members** in the self-compile (0.6 M executions of all unresolved together):
  - to find them, print the member id and its `lssMemberKinds` entry from `graph4Full` for each
    `SetUnresolved "none"` site;
  - only worth fixing if B goes ahead, since A just gives those sites no hint.

## 7. Phases and gates

Standing rules:
- run each test target once, output teed to a file;
- `ulimit -c 0` first;
- never edit the tree during a build or gate run;
- tests first, expected output from `elm make` plus node;
- flag wall regressions of about 5 % or more.

### P0, census: done

`GenCallCensus` `lss*` keys and the §2 numbers. The run-time patch was temporary and is reverted.

### P1, member-arity module (A.1)

1. Write `MemberArityTest.elm` (A.1) and watch it fail to compile, then make it pass.
2. Make the A.1 changes; `GenCallCensus` now calls `MemberArity`.
3. **Gate:**
   - elm-tests (`cmake --build build --target elm-tests`);
   - rebuild the compiler and rerun the self-compile and E2E censuses
     (`test/scripts/staging-census.sh`).
   - **Expected:** `lssUnresolvedWhy+kernel` goes to 0; those sites (19 self, 291 E2E, 39 bench)
     move to exact, over or under; every other key is unchanged. Record the new table in §2.

### P2, hint (A.2 to A.5)

1. **Tests first**, all failing before the change.
   - **`test/eco-mlir/src/StageHintLoopTest.elm`.** A loop in the shape of `loopHelp`, whose
     callback set has two members of arity 1, so that keyed specialization cannot make it a
     singleton:
     ```elm
     type P = P (Int -> Step)
     type Step = Loop Int | Done Int

     loop : (Int -> P) -> Int -> Int -> Int
     loop callback s input =
         case callback s of
             P f ->
                 case f input of
                     Loop s2 -> loop callback s2 (input - 1)
                     Done r -> r

     main = ... loop (if flag then cbA else cbB) 0 10 ...   -- flag read from data, not a literal
     ```
     - `cbA` and `cbB` each do some work before returning `P (\i -> ...)`, so that
       `Staging.regroup` does not flatten them to arity 2.
     - Check with `ECO_STAGING_REPORT=1` that the `callback s` site is `lssExact` with no stamp.
       If it is stamped, make the set larger or the choice more dynamic until it is not.
     - Lines:
       - `-- CHECK-MLIR: _stage_hint = 1`;
       - `CHECK:` lines for the printed result, recorded from `elm make` plus node.
   - **`test/eco-mlir/src/StageHintOverApplyTest.elm`.** A Mono-level over-application of a
     two-member set of arity 1:
     ```elm
     f = if flag then (\a -> let k = a * 2 in \b -> k + b)
                 else (\a -> let k = a - 1 in \b -> k * b)
     ... f x y ...
     ```
     - Confirm `lssOver` in the census.
     - Lines:
       - `CHECK-MLIR:` for a papExtend with `_stage_hint = 1` followed by one with
         `_call_kind = "segmentation_unknown"`;
       - `CHECK:` output lines from node.
   - **`test/codegen/pap_extend_stage_hint_fusion.mlir`** (`// RUN: %ecoc %s -emit=mlir-eco 2>&1
     | %FileCheck %s`). The in-repo harness (test/CheckPatterns.hpp) is not FileCheck: `CHECK-NOT`
     means "nowhere in the output" and there are no `[[VAR]]` captures, so the checks are
     `CHECK` / `CHECK-SAME` / `CHECK-NEXT` on consecutive lines. One function per case, each with
     its closure as a parameter so that create+extend fusion cannot apply:
     - `@hinted`: hint 1 on a one-newarg extend, then a one-newarg extend: two papExtends;
     - `@unhinted`: the same without the hint: one fused papExtend (the control, today's
       behaviour);
     - `@within_hint`: hint 3 with one newarg, then two: one fused extend that keeps
       `_stage_hint = 3`;
     - `@past_hint`: hint 2 with one newarg, then two: not fused.

     A three-extend chain is deliberately not tested: the greedy rewrite driver may fuse the
     later pair first, so the result depends on visiting order.
2. Implement A.2, A.3, A.4, A.5.
3. **Gates:**
   - **Parser benchmarks:** expr-parser, lexer, json-parser, 3 rounds each, before and after
     compilers on the same day.
     - **Expected:** a fall of at most the no-merge experiment's 163 -> 140 and 147 -> 124 ms.
     - Report the real figure, including if it is ~0. That would mean the slowdown comes from
       ⊤ merges A cannot see.
   - **All benchmark workloads**, 1 run, with merkletrees, dict-int and nsieve checked
     specifically (they moved in the no-merge experiment).
   - **Counters:** `ECO_GENCALL_COUNTERS=1` lowering plus `ECO_DISPATCH_STATS=1` on the
     self-compile and on expr-parser.
     - Report `gen` before and after, and `r11`.
     - **Expected:** `gen` falls by about the old `lssOver` executions (15.1 M self) less those
       whose first stage misses the edge.
   - **Self-compile:**
     - wall, 3 runs, flagged at ≥ 5 %;
     - `.mlir` size, since every split adds an extend and a sat bracket;
     - the fixed point (stage n and n+1 MLIR byte-identical).
   - **`cmake --build build --target full`** (E2E), **`--target elm-tests`**, and
     **`--target bootstrap`**.
4. Set this plan's `status` to `partial`, with `remaining: "P3 decision; B"`.

### P3, decision on B

- Rerun the execution census on the P2 compiler (rebuild the temporary run-time patch from the
  scratch notes: a `censusClass` on `CallInfo` and a reason override in `generateCall`).
- Report:
  - the `lssExact` executions left on the fast edge (B saves their guard);
  - the `lssUnder` executions (B makes them typed).
- Apply the October bar: B goes ahead only if the convertible premium is at least ~1 % of
  self-compile wall.
- Otherwise set `status: done` and record the numbers here.

### P4, B

1. **Validating-build check first**, with its forged-arity negative control.
2. **The member-id census** from §5, B.3. It must find zero partial applications of lambdas
   under their own member id before `FromSet` is trusted.
3. **`FromSet`**, then the MLIR comparison against P2 for `FromProducer` sites.
4. **Gates:**
   - all of P2's;
   - in the validate tree: unit tests, E2E and GC-pressure stress;
   - bootstrap.

## 8. Results (2026-11-22)

All phases ran to their decision points. P4 was not started: P3 put B below the October bar.

### P1

- `Compiler.MonoOpt.MemberArity` holds `memberArities`, `classify` and `setArity`.
  - `GenCallCensus` classifies through it.
  - `compiler/tests/Compiler/MonoOpt/MemberArityTest.elm` has 18 tests.
- Static census, against the P0 compiler:
  - benchmarks: `lssUnresolved` 39 -> 0, `lssExact` 1,106 -> 1,145;
  - E2E corpus: unresolved 302 -> 11 (all `none`), exact 29,035 -> 29,328 (291 kernel sites plus
    the two new tests' four sites);
  - self-compile: `kernel` 19 -> 0, leaving the 39 `none`. The compiler source itself grew, so its
    other classes moved by a few sites.

### P2

- **Tests.** All failed before the change: the fusion lit test fused all three chains on the old
  `ecoc`, and the old compiler wrote no `_stage_hint`. All pass now.
  - Output recorded from `elm make` plus node.
  - `StageHintLoopTest` is the `loopHelp` shape: the callback site is `lssExact`, arity 1, two
    members.
  - `StageHintOverApplyTest` is a split `lssOver` site. Its `op k b` site, a set of the kernels
    `(+)` and `(*)`, was `lssUnresolved` and now gets `_stage_hint = 2`.
- **Gates**, all green:
  - elm-tests: 22,061 passed, 0 failed;
  - `full`: 3,152 of 3,152 passed, rc 0. The first run failed only the new lit test, because of
    the harness semantics above;
  - bootstrap: rc 0, both fixed points (4b, 8c);
  - self-compile fixed point: stage n+1 and n+2 MLIR are byte-identical. The compiler's MLIR
    grows by 1.2 KB (+0.01 %).
- **Self-compile wall**, median of 3, alternating: 73.99 s -> 74.15 s (+0.2 %, noise).
- **Runtime generic entries** (`[dispatch-stats] gen`):
  - self-compile: 77.3 M -> 49.3 M (-36 %);
  - expr-parser, lexer and json-parser together: 4.34 M -> 2.77 M (-36 %).
- **Benchmarks**, medians of 3 rounds of 10 runs, base -> new:

  | workload | base ms | new ms | change |
  |---|---:|---:|---:|
  | expr-parser | 163.5 | 141 | -13.4 % |
  | lexer | 147.5 | 124 | -16 % |
  | json-parser | 204 | 203 | flat |
  | levenshtein | 277 | 234.5 | -15.3 % |
  | ctor-maybe | 48 | 43 | -10.4 % |
  | nbody | 39 | 36 | -7.7 % |
  | set-float-pairs | 309.5 | 290 | -6.3 % |
  | fasta | 456 | 429 | -5.9 % |
  | word-freq | 123 | 128 | +4.1 % |

  - The parser figures reach the all-merges-off experiment's 140 and 124 ms, so A recovers the
    whole parser slowdown.
  - word-freq's dispatch counters are identical before and after, so its +4.1 % is code layout.
    It is below the 5 % flag, and this benchmark is a known layout case.
  - Every other workload stayed within ±3 % in a single round, or within 2 % on recheck
    (merkletrees +0.6 %, dict-int 0 %, nsieve -1.6 %).

### P3: B is below the bar

The execution census was rerun on the P2 compiler, with a temporary build (since reverted) that
made two changes:
- it put the class codes at 16 to 25, clear of the callee-shape reasons 1 to 6, which calls not
  stamped by the census keep;
- it counted each runtime generic entry under the reason of the last counted extend (flawed; see
  the correction below).

Self-compile executions per class, and how many of them fail the guard of the `sat[N]` fast edge
(from the corrected census below):

| class | executions | guard fails |
|---|---:|---:|
| exact | 76.9 M | 0 |
| over (now the first stage of a split) | 13.8 M | 0 |
| hinted split tails (reason 11) | 15.1 M | 1.2 M (over) |
| under | 1.1 M | 0.71 M (under) |
| ⊤ | 102.2 M | 18.2 M (11.7 M under, 5.5 M over, 1.1 M no `sat` entry) |
| var | 8.3 M | 0.9 M (over) |
| not stamped by the census (reasons 1 to 6, 9) | 91.3 M | 0.14 M (over) |

B would only change exact and under calls. Exact calls all take the fast edge, so B would save
only their guard, a few loads and compares: about 77 M × ~1 ns ≈ 0.08 s, about 0.1 % of the 74 s
self-compile, below the ~1 % bar. B stops here, and the §5 preconditions stay recorded for whoever
reopens it.

**Correction (2026-11-22, follow-up).** The first version of this table gave exact calls 22.6 M
runtime entries and proposed finding which guard check they fail. They fail none. The temporary
census credited each runtime entry to the reason of the last counted extend on the thread, which
was never cleared, so entries made by kernels calling closures were charged to whatever generated
call ran before them, mostly exact ones. A second census replayed the guard at every counted site
(closure, N, slot kinds, result kind, and whether the site has a marker at all) and counted the
first check that fails; every exact execution passes all of them. It also attributed each runtime
entry to the site that made it:

- 32.9 M of the 49.3 M runtime generic entries come from no generated site. They are kernels
  calling closures: `Array.foldl`/`foldr` 9.4 M, `List.map2`..`map5` 8.1 M, `Array.initialize`
  6.9 M, `eco_apply_closure_typed` callers 6.2 M, `Array.map` 2.0 M, `String.map` 0.5 M. Outside
  the census these take `tryInvokeSaturatedDirect`, which the census switches off, so they are not
  the general path in a normal run.
- The rest are generated sites whose closure does not match the call: ⊤ under-applications (a
  closure built by `eco_pap_extend_l`, not a missed fast edge), over-applications of ⊤, var and
  split-tail calls, and 1.1 M calls of the `Bytes.read_u8`/`read_u16` kernel closures, whose
  descriptors have no `sat[2]` entry.

No generated call with a complete set misses the fast edge, so there is no follow-up for them. The
remaining generated-site misses are ⊤ calls, which have no set arity to act on.

**Kernel callers at default settings (2026-11-22).** A third temporary census left the direct path
on (no `ECO_DISPATCH_STATS`) and recorded, per caller of `eco_apply_closure_eval`, whether
`tryInvokeSaturatedDirect` applies or which of its checks rules it out. Of the kernel and runtime
callers' 33.1 M calls, 32.87 M take the direct path; 204 k are partial applications (two arguments
to a three-argument closure) and 47 k fail the slot-kind check (`List.sortBy` 43 k and the
scheduler 4 k, passing a boxed argument to an unboxed slot). No other check fails anywhere: 2
calls are too wide and none has an incompatible result kind. The 7.67 M over-application tails
also all take the direct path. So kernel closure calls are not a lever either; the general path
is reached only by ⊤ under- and over-applications from generated code.

## 9. Review log (2026-11-22)

An adversarial review of the first draft found and fixed:

1. **Step order.** The draft had step 5 read member arities, but step 4
   (`Mono.clearLssTables`) empties `lssMemberOrigins` first unless `keepOrigins`. The arities are
   now computed from `graph4Full`, before step 4, and passed into `annotateCallStaging` (A.2).
2. **The P2 test checked the wrong IR.** `test/eco-mlir` CHECK-MLIR reads the front end's MLIR,
   before EcoPAPSimplify, where the two applies are always separate, so that test could not fail.
   The fusion rule is now tested by a `test/codegen` lit test on `-emit=mlir-eco`. eco-mlir now
   checks only that the front end writes the hint.
3. **The split lowering was put in C++.** The draft had EcoToLLVM split a hinted extend. The
   front end already splits stamped over-applications
   (`generateStagedFastDispatchCall`), so the hinted split is emitted the same way. No lowering
   changes, and the fusion rule keeps the split apart.
4. **No limit on the hint.** The fast edge covers sites of 1 to 8 arguments only (`emitSatBegin`).
   An unbounded hint would split wide calls into two runtime calls, slower than one. Hints are
   now capped at 8.
5. **Partial fusion.** The draft refused fusion only when a hint equalled its own argument count.
   An under-applying hinted extend followed by enough arguments could still fuse into an
   over-application. The rule is now "never fuse past the hint", and a fused op keeps the hint.
6. **Kernel members.** C proposed `kernelFuncSignatureFromType`, but an `OriginKernel` carries no
   type to give it. The arity is now taken from the arrow type the set sits on, which is the
   kernel value's specialized type (A.1).
7. **Expectations.** The parser gain was quoted from an experiment that disabled *all* generic
   merging. It is now stated as an upper bound for A.
8. **Census table.** The benchmarks' ⊤ count was 286; it is 287 (1,478 total). `lssEmpty` and
   the `define`/`node`/`noSpec` unresolved reasons were missing.
9. **An unexamined soundness assumption** (B): that a member id never names a partially applied
   lambda. It is now an explicit P4 precondition with its own census.
10. **Production depending on a census module.** `memberArities` moves to
    `Compiler.MonoOpt.MemberArity`. Census and hint share one classifier, so they cannot drift.
