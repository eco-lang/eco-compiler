# Kernel-Opt 05: Utils_append type-split -> eco.string.append + eco.list.append

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v2 deepened from OUTLINE v1;
**v3 = adversarial verification pass**: every load-bearing anchor re-opened in
the tree; corrected the registration checklist 3 → 5 points, the stale §16
borrow baseline → §18.2, the 3,465-vs-3,464 site arithmetic, the static-census
corpus path, the dynamic-census re-run mechanism, the `Eco_ListAppendOp`
placement, and the cross-plan collision with kernel-opt-07's existing
`(Utils, append)` row.) Derived from
design_docs/kernel-boundary-reduction.md Q4.1 (type-split paragraph) + Q4.5 R2;
dynamic census design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt;
static census design_docs/kernel-boundary/callsite-census-self-compile.txt.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/Eco/Config.elm` | new `AppendConfig { split, census }` — `type alias EcoConfig` LAST field (`:34-48`), `default` (`:292-339`), `decoder` LAST `D.apply` (`:346-361`) + `appendDecoder`, two `hash` tokens beside the `lchunks=1` block (`:677-686`) |
| `compiler/src/Builder/Eco/Config.elm` | two env overrides `ECO_APPEND_SPLIT`, `ECO_APPEND_CENSUS` appended to the `applyEnvOverrides` chain (last link today = `ECO_BORROW_OPT`, `:260-264`) + `applyAppendSplitOverride` / `applyAppendCensusOverride` + env-list doc lines (`:78-104`) |
| `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | 2 new `Intrinsic` ctors (`AppendString`, `AppendList`); arms in `intrinsicResultMlirType`, `intrinsicOperandTypes`, `generateIntrinsicOp`, `utilsIntrinsic`; new `kernelIntrinsicCfg` gate + `appendKindLabel` census classifier |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | `:3725` + `:4199` call `kernelIntrinsicCfg ctx.ecoConfig.append.split`; census-mode `eco.append_kind` attr stamped on the fallback `eco.call` |
| `runtime/src/codegen/Ops.td` | `Eco_StringAppendOp` after `Eco_StringFromFloatOp` (`:1114-1123`); `Eco_ListAppendOp` after `Eco_ListTailOp` (`:670-690`), before the Tuple header at `:692` |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | 2 `getOrCreate*` declarations (next to `:723-725`) |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | 2 `getOrCreate*` definitions (next to `:978-986`) + 2 entries in `materializeAllRuntimeDecls` (`:1211`, list at `:1271`) |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | 2 `OpConversionPattern`s after `:1557` (inside the anon namespace closing at `:1559`) + 2 `patterns.add<>` lines (`:2107-2108` block) |
| `elm-kernel-cpp/src/core/UtilsExports.cpp` | `eco_string_append` + `eco_list_append` exports; new `#include "allocator/ListOps.hpp"` |
| `elm-kernel-cpp/src/KernelExports.h` | 2 declarations beside the existing `eco_string_cmp3`/`eco_string_cmp_order` decls (`:189-193`) |
| `runtime/src/codegen/RuntimeSymbols.cpp` | 2 `KERNEL_SYM` entries in the Utils block (`:703-741`) |
| `compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm` (or `GlobalOpt/KernelFacts.elm` post-07) | fill the borrow axes of the `("Utils","append")` row — see Phase 3 |
| `compiler/tests/Compiler/GlobalOpt/KernelFactsTest.elm` (post-07 only) | extend `legacyBorrowGolden` + suites 3/4 from 33 → 34 keys — see Phase 3 |
| `test/codegen/string_list_append.mlir` (new) | ecoc/FileCheck/JIT lowering test for both ops |
| `test/elm/src/AppendTypeSplitTest.elm` (new) | E2E: slice + >32 KiB rope + Cons/ConsChunk/Nil + polymorphic residue |
| `elm-kernel-cpp/src/core/Utils.cpp` | (Phase 5, optional) harden the `:851-852` silent fallback |

## Flag & rollback

- **Flag:** `ecoConfig.append.split : Bool`, **default `False`**. Env
  `ECO_APPEND_SPLIT`, parsed by a byte-for-byte copy of
  `applyListChunksOverride` (Builder/Eco/Config.elm:490-511), i.e. accepted
  values are exactly **`1`/`true`/`yes`/`on` → True**, **`0`/`off` → False**,
  and **anything else is silently ignored** (`false` is NOT recognised — do not
  document it as if it were).
  **Artifact-affecting** → hash token `apsplit=1` emitted only when enabled
  (mirror the `lchunks=1` block at Compiler/Eco/Config.elm:677-686), so flag-on
  and flag-off builds never share `~/.eco` cache entries and an explicitly
  disabled config hashes byte-identically to today.
- **Census flag:** `ecoConfig.append.census : Bool`, default `False`, env
  `ECO_APPEND_CENSUS=1`. **Also artifact-affecting** (it stamps a discardable
  attr into the emitted `.mlir`) → hash token `apcensus=1`. Never from JSON.
- **Rollback:** flag off ⇒ `utilsIntrinsic` returns `Nothing` for `append`
  ⇒ byte-identical MLIR to today. The runtime ops/exports remain in the binary
  but are unreachable (no emitter, DCE'd from the module by internalize +
  globalDCE). Full revert = drop the `append` field from `EcoConfig` and the
  two arms; the runtime side is additive and can stay.
- **No runtime env kill switch is needed or possible** — the ops only exist if
  the compiler emitted them. Do NOT add one: a runtime that silently refuses to
  lower a present op is a hard error, not a fallback.
- **Sequencing trap:** land Phase 1a (runtime lowering) BEFORE Phase 1b
  (compiler emission). A stale `eco-boot-native` cannot lower a new op and
  fails Stage 6/7b with an unregistered-op parse error. `--target full`
  rebuilds both; a manual `eco-boot-native` harness does not.

## Goal

Split the polymorphic `Elm_Kernel_Utils_append` at MLIR-emission time using the
mono types the compiler already has: `(MString, MString)` becomes
`eco.string.append`, `(MList _ _, _)` becomes `eco.list.append`. Both remain
STATEPOINTED CALLs into the SAME C++ backends the runtime dispatch reaches
today (`StringOps::append` / `ListOps::append`). Genuinely polymorphic residue
(any `MVar` operand) falls through to the existing `eco.call
@Elm_Kernel_Utils_append` unchanged; the kernel symbol stays as the fallback and
is never deleted. This deletes the per-call runtime tag dispatch on a 50.4M-call
path, makes a swallowed type error unreachable at statically-typed sites, and
opens a typed boundary for later append-specific work.

## Evidence

- **Dynamic:** `Elm_Kernel_Utils_append` = **50,438,448** calls, rank #9 of 98
  symbols (kernel-census-dynamic-stage7a.txt, **file line 10** — line 1 is the
  `total=…` header). 1.37% of the 3.68B kernel-call total. Not stale — the
  Aug-10 compare series touched compare/equal only.
- **Static:** **3,465** raw occurrences — #2 static symbol, 20.4% of the
  17,005-occurrence census (callsite-census-self-compile.txt line 2). The
  corpus is the **textual** `eco-compiler.txt.mlir` (84 MB, 68,996 `func.func`s
  — design_docs/kernel-boundary-reduction.md:155-162), NOT
  `build/compiler/build-kernel/bin/eco-compiler.mlir`, which is MLIR
  **bytecode** (`ML\xefR` magic; see Phase 0).
  **Decomposition (design doc :242): 3,464 direct `eco.call` + 0 `papCreate` +
  1 `is_kernel` stub.** The zero-`papCreate` fact is what makes this item
  tractable: `utilsIntrinsic` is consulted only at APPLIED sites
  (Expr.elm:4199), so a first-class capture of `Elm_Kernel_Utils_append` could
  never be displaced. **3,464 is the displaceable population**; every count
  below is against that number, not 3,465.
- **The defect (re-verified):** `Utils::append`
  (**elm-kernel-cpp/src/core/Utils.cpp:829-853**) re-derives at runtime what
  mono knew statically:
  - `:830-832` null/embedded-constant guards;
  - `:834-835` two `getTag` loads;
  - `:839-841` `alloc::isString(a) && alloc::isString(b)` → `StringOps::append`;
  - `:843-848` `tagA == Tag_Cons || tagA == Tag_ConsChunk || alloc::isNil(...)`
    → `ListOps::append`;
  - **`:851-852` `// Unsupported types - return first value` → silently returns
    `wrap(a)`** — a swallowed type error. (The design doc's `:844-845` anchor
    has drifted to `:851-852`; confirmed.)
- **The hook exists and sees mono types (verified):** `utilsIntrinsic`
  (**Intrinsics.elm:563-644**) already matches on `( name, argTypes )` and
  already carries a **boxed-operand precedent**: `( "compare", [ MString,
  MString ] ) -> CompareToOrder { kind = CompareStringKind }` at `:640-641`,
  whose operand types are `[ Types.ecoValue, Types.ecoValue ]` (`:250-253`) and
  which emits `eco.string.cmp_order` via `Ops.ecoBinaryOp` (`:973-978`). Adding
  append arms is pattern-match extension along an already-walked path.
- **Callees already exist — PATH ANCHORS CORRECTED:**
  - `Elm::StringOps::append` is **runtime/src/allocator/StringOps.hpp:477-537**
    (NOT `elm-kernel-cpp/src/core/StringOps.hpp`, which does not exist).
    memcpy/flatten below `string_flatten_limit`; `makeRope(aHp,bHp)` above.
  - `Elm::ListOps::append` is **runtime/src/allocator/ListOps.cpp:262-292**
    (decl `runtime/src/allocator/ListOps.hpp:181`). The `:262` line anchor from
    v1 is correct; the path was wrong.
  - `STRING_FLATTEN_LIMIT = 32 * 1024` is
    **runtime/src/allocator/AllocatorCommon.hpp:99** (design doc said `:85`).
- **Borrow upside is FALSE — v1 defect, corrected.**
  design_docs/borrow-inf-census.md:**883-897** carries an explicit
  **CORRECTION (2026-07-27)**: "`Utils.append` (3,270, 25%) is a genuine OWNER
  over String as well as List". `makeRope` stores both operands as GC roots
  (`StringOps.cpp:79-84`, `eco_alloc_with_roots(..., roots, 2, 0x3)`) and
  `ListOps::append` aliases `b` into the result tail
  (`listFromUnboxables(elements, b)`, ListOps.cpp:291). Copy-vs-rope is a
  **runtime** decision on byte length; a static `(home,name)` sig cannot
  discriminate it. **Those poisoned heap args are NOT recoverable.** (The
  quoted `3,270` is the §17 count; the current figure is **3,274**, §18.2
  `:1164-1166` — use 3,274 for every Phase-3 number.) The sound facts row is
  `POwned/POwned` + `resultAliases = [0,1]` — see Phase 3 for what the row
  *does* buy.

## Approach

### Phase 0 — emission-side census (½–1 day, no new ops)

**Mechanism.** Add `ecoConfig.append.census`. In census mode the compiler
emits today's kernel call *plus* a discardable attr classifying the mono types.
`MlirOp` is a plain record (Mlir.elm:101-111) and the printer emits **generic
form** (Pretty.elm:222-224), so an `eco.`-prefixed attr rides along untouched and
MLIR accepts it as discardable (exactly like `eco.gc_roots_count`, ecoCallNamed
Ops.elm:690-701).

Classifier in `Intrinsics.elm` (exported alongside `kernelIntrinsic`):

```elm
{-| Phase-0 census classifier: label an append site by its mono arg types.
`Nothing` for non-append sites. Pure — no config, no context.
-}
appendKindLabel : Name.Name -> Name.Name -> List Mono.MonoType -> Maybe String
appendKindLabel home name argTypes =
    case ( home, name, argTypes ) of
        ( "Utils", "append", [ Mono.MString, Mono.MString ] ) -> Just "ss"
        ( "Utils", "append", [ Mono.MList _ _, Mono.MList _ _ ] ) -> Just "ll"
        -- Mixed String/List is impossible under `appendable a => a -> a -> a`;
        -- if this bucket is ever nonzero, mono types are inconsistent and BOTH
        -- the classifier and the Phase-1b arms must bail (see 1b.1).
        ( "Utils", "append", [ Mono.MString, Mono.MList _ _ ] ) -> Just "MIXED"
        ( "Utils", "append", [ Mono.MList _ _, Mono.MString ] ) -> Just "MIXED"
        ( "Utils", "append", [ Mono.MString, _ ] ) -> Just "s_"
        ( "Utils", "append", [ _, Mono.MString ] ) -> Just "_s"
        ( "Utils", "append", [ Mono.MList _ _, _ ] ) -> Just "l_"
        ( "Utils", "append", [ _, Mono.MList _ _ ] ) -> Just "_l"
        ( "Utils", "append", [ _, _ ] ) -> Just "poly"
        _ -> Nothing
```

Stamp site: **Expr.elm:4199**'s `Nothing ->` branch, in the `KernelAbi.ElmDerived`
arm where `Ops.ecoCallNamed` produces `callOp` (`:4272-4273`). `MlirOp` is a
record, so post-process rather than widening `ecoCallNamed`. Add the binding to
that arm's `let` (after the `( ctx3, callOp )` binding at `:4272-4273`) **and
substitute it in the returned `ops` list at `:4275`** — the substitution is the
whole point and is easy to forget:

```elm
                                        callOpCensused : MlirOp
                                        callOpCensused =
                                            if ctx.ecoConfig.append.census then
                                                case Intrinsics.appendKindLabel home name argTypes of
                                                    Just kind ->
                                                        { callOp
                                                            | attrs =
                                                                Dict.insert "eco.append_kind"
                                                                    (StringAttr kind)
                                                                    callOp.attrs
                                                        }

                                                    Nothing ->
                                                        callOp

                                            else
                                                callOp
                                    in
                                    -- was: { ops = argOps ++ boxOps ++ [ callOp ], … }  (:4275)
                                    { ops = argOps ++ boxOps ++ [ callOpCensused ]
                                    , resultVar = resVar
                                    , resultType = resultMlirType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }
```

Scoping check (verified): `home`, `name`, `argTypes` and `ctx` are all in scope
there — the whole `ElmDerived` arm is nested inside
`generateSaturatedCallNoFusion ctx func args resultType callInfo`
(Expr.elm:3488-3489) and inside the `case Intrinsics.kernelIntrinsic home name
argTypes resultType of … Nothing ->` at `:4199`. `StringAttr` takes ONE
argument (Mlir.elm:56) and both `MlirAttr(..)` and `MlirOp` are already
imported (Expr.elm:71); `Dict` is imported at `:68`.

**Run it** (native compiler self-compiling itself). `--text-mlir` is
MANDATORY: the default `.mlir` output is MLIR **bytecode** — verified,
`od -c -N 8 build/compiler/build-kernel/bin/eco-compiler.mlir` →
`M L 357 R \t e c o` (`ML\xefR` magic), and every `*.mlir` in that directory is
bytecode. `--text-mlir` is a real `Terminal.onOff` flag (Terminal/Main.elm:296,
:337 → `Make.Flags.textMlir`, consumed at Make.elm:335/:410). The command below
mirrors CMake's Stage 7a exactly (compiler/CMakeLists.txt:478-491) plus
`--text-mlir` and a different `--output`:

```bash
cd /work/build/compiler/build-kernel
ECO_APPEND_CENSUS=1 ./bin/eco-compiler make --optimize --text-mlir \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/append-census.mlir \
    /work/compiler/src/Terminal/Main.elm 2>&1 | tee /tmp/append_census_build.txt
```

(`/work/eco-kernel-cpp` is the literal expansion of CMake's
`${COMPILER_DIR}/../eco-kernel-cpp`. It is a DIFFERENT directory from
`/work/elm-kernel-cpp`, where the C++ exports live — both exist; do not
conflate them.)

**Read it** — use `grep -o | wc -l`, never `grep -c`, which counts LINES:

```bash
M=/work/build/compiler/build-kernel/bin/append-census.mlir
grep -o 'eco\.append_kind = "[A-Za-z_]*"' "$M" | sort | uniq -c | sort -rn | tee /tmp/append_census.txt
# Total occurrences of the kernel symbol = labelled call sites + 1 is_kernel stub.
grep -o 'Elm_Kernel_Utils_append' "$M" | wc -l
# Cross-check the pap==0 census fact — this must print 0:
grep -c 'eco.papCreate.*Elm_Kernel_Utils_append' "$M"
```

**Per-phase acceptance:** the bucket counts sum to **3,464 ± the drift between
the 2026-08-09 census snapshot and HEAD**, `grep -o … | wc -l` on the symbol
equals that sum **+ 1** (the single `is_kernel` stub — design doc :239-242
records 3,464 direct + 0 `papCreate` + 1 stub), the `MIXED` bucket is **0**,
and `ss`/`ll`/`s_`/`_s`/`l_`/`_l`/`poly` are each recorded in this file.
A nonzero `MIXED` is stop-the-line: it means mono is producing
`appendable`-violating type pairs and Phase 1b must not ship.

**Decision point.** Percentages are over the labelled total (≈3,464), not 3,465.
- `ss + ll ≥ 60%` → proceed to Phase 1 with the two-sided arms only.
- `ss + ll < 60%` **and** the half-resolved buckets (`s_`/`_s`/`l_`/`_l`) close
  the gap to ≥60% → add the one-sided arms in Phase 1 (sound: `++ : appendable a
  => a -> a -> a`, so one resolved operand pins the other's Elm type; the
  un-resolved side is `MVar _ CEcoValue`, already `!eco.value` at ABI). Emit the
  one-sided arms behind the SAME flag, no extra knob.
- `ss + ll + one-sided < 40%` → **STOP and re-scope**; the win is not in the
  static distribution and the whole item is a correctness-only change. Record
  the numbers in this file and close.

### Phase 1a — runtime: two ops, two lowerings, two exports (land FIRST)

**1a.1 `Ops.td` defs.** Model on `Eco_StringFromIntOp` (Ops.td:1102-1112) —
**deliberately trait-free**, unlike `Eco_StringCmpOrderOp` (:2759-2774) which is
`[Pure]` *because it does not allocate*. These allocate; do not mark them
`Pure`. **Placement (both verified 2026-08-10):**
- `Eco_StringAppendOp` → in `//=== 3. String Operations` (header at Ops.td:1073),
  immediately after `Eco_StringFromFloatOp` (:1114-1123) and before the
  `//=== 4. Call and Closure Operations` header at :1125.
- `Eco_ListAppendOp` → in `//=== List Operations (Cons / Nil)` (header at
  Ops.td:611), at the END of that section: after `Eco_ListTailOp` (:670-690)
  and before the `//=== Tuple Operations` header at :692. (Do NOT put it next
  to `Eco_ArrayAppendNOp` — that is `array.append_n` at :1061, an unrelated
  JsArray op.)

```tablegen
def Eco_StringAppendOp : Eco_Op<"string.append"> {
  let summary = "Concatenate two Strings (a ++ b), typed";
  let description = [{
    Typed replacement for `Elm_Kernel_Utils_append` at `(String, String)`
    mono sites. Operands are boxed strings (REP_ABI_001: String crosses every
    ABI as `!eco.value`) and accept the FULL string-shape domain — leaf,
    UTF-8 view, slice and rope — because either side may be a view.
    Allocates a VARIABLE-size result (flat leaf below
    `string_flatten_limit`, `Tag_StringRope` above), so it is NOT
    fixed-size-groupable; RS4GC inserts the statepoint at the lowered call.

    ```mlir
    %s = eco.string.append %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_ListAppendOp : Eco_Op<"list.append"> {
  let summary = "Concatenate two Lists (a ++ b), typed";
  let description = [{
    Typed replacement for `Elm_Kernel_Utils_append` at `(List _, _)` mono
    sites. Accepts every spine form (Tag_Cons, Tag_ConsChunk, Nil embedded
    constant). Allocates a VARIABLE number of cells (or one chunk chain);
    NOT fixed-size-groupable. The result SHARES the rhs spine.

    ```mlir
    %l = eco.list.append %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}
```

The `assemblyFormat` line above is copied verbatim from `Eco_StringCmpOrderOp`
(Ops.td:2772-2773), which has the identical `(Eco_Value, Eco_Value) ->
Eco_Value` shape — so result-type inference is already proven to work with
`type($lhs)` alone. Ops are auto-registered via `GET_OP_LIST`
(EcoDialect.cpp:38-39) — no manual dialect edit.

**No compiler-side op registration is needed.** The Elm MLIR bytecode writer
derives its dialect/op-name table from the ops actually emitted
(`addOpNameToDict` splits on the first `.`, Mlir/Bytecode/DialectSection.elm:222-240),
so `eco.string.append` → dialect `eco`, op `string.append` with zero edits.
Likewise the textual printer emits generic form for any op name
(Mlir/Pretty.elm:222-224).

**1a.2 Runtime function getters.** `EcoToLLVMInternal.h` next to `:723-725`:

```cpp
    // String/List append (eco.string.append / eco.list.append lowering)
    mlir::LLVM::LLVMFuncOp getOrCreateStringAppend(mlir::OpBuilder &builder) const;
    mlir::LLVM::LLVMFuncOp getOrCreateListAppend(mlir::OpBuilder &builder) const;
```

`EcoToLLVMRuntime.cpp` next to `:978-986`:

```cpp
LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringAppend(OpBuilder &builder) const {
    // eco_string_append(a: hptr, b: hptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_string_append", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateListAppend(OpBuilder &builder) const {
    // eco_list_append(a: hptr, b: hptr) -> hptr
    auto funcTy = LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, HPTR_TY});
    return getOrCreateFunc(builder, "eco_list_append", funcTy);
}
```

**MANDATORY:** add both to `materializeAllRuntimeDecls` (EcoToLLVMRuntime.cpp,
body starts `:1211`; append next to the `getOrCreateStringFromInt(b);` line at
`:1271`):

```cpp
    getOrCreateStringFromInt(b); getOrCreateStringFromDouble(b);
    getOrCreateStringAppend(b); getOrCreateListAppend(b);
```

Omitting this trips `assert(!frozen && "getOrCreateFunc miss after freeze()")`
(getOrCreateFunc, EcoToLLVMRuntime.cpp:`:122-138`) under the parallel Stage-2
conversion — a non-deterministic crash, not a clean error. The `gcLeaf`
parameter defaults **false** (declaration default lives in the HEADER:
EcoToLLVMInternal.h:`506`), which is exactly right: both callees allocate.
Contrast `getOrCreateStringCmpOrder`, which passes `/*gcLeaf=*/true`
explicitly (EcoToLLVMRuntime.cpp:946-950) because `StringOps::compare` never
allocates — **do not copy that argument here.**

**1a.3 Lowering patterns.** `EcoToLLVMHeap.cpp`, immediately after
`StringFromFloatOpLowering` (:1542-1557) and **before** the `} // namespace`
at `:1559` (both patterns must live inside the file's anonymous namespace,
like every other `*OpLowering` there). The `replaceOpWithNewOp<LLVM::CallOp>`
idiom below is copied verbatim from `StringCmpOrderOpLowering`
(EcoToLLVMArith.cpp:1117-1132) — the closest sibling with the same
`(hptr, hptr) -> hptr` shape; note the from_int/from_float neighbours in
`EcoToLLVMHeap.cpp` spell the same thing as `create` + `replaceOp`, so either
form is fine and this one is the shorter verified one:

```cpp
//===----------------------------------------------------------------------===//
// eco.string.append / eco.list.append
//===----------------------------------------------------------------------===//

struct StringAppendOpLowering : public OpConversionPattern<StringAppendOp> {
    const EcoRuntime &runtime;
    StringAppendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                           const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(StringAppendOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringAppend(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};

struct ListAppendOpLowering : public OpConversionPattern<ListAppendOp> {
    const EcoRuntime &runtime;
    ListAppendOpLowering(EcoTypeConverter &typeConverter, MLIRContext *ctx,
                         const EcoRuntime &runtime)
        : OpConversionPattern(typeConverter, ctx), runtime(runtime) {}

    LogicalResult
    matchAndRewrite(ListAppendOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateListAppend(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getLhs(), adaptor.getRhs()});
        return success();
    }
};
```

Register in `populateEcoHeapPatterns`, next to `:2107-2108`:

```cpp
    patterns.add<StringAppendOpLowering>(typeConverter, ctx, runtime);
    patterns.add<ListAppendOpLowering>(typeConverter, ctx, runtime);
```

**1a.4 GC treatment — the correct-vs-heap-corruption decision, grounded.**

Read exactly how `eco.string.from_int` is treated by `EcoGCPrepare.cpp`
(`:40-140`): it appears in **none** of `isMayAllocOp` (:40-51),
`hasFixedAllocSize` (:56-68), `isGroupBarrier` (:110-121), `isCallSafepoint`
(:125-140). **Mirror that exactly: add the two new ops to NONE of the four
lists.** The reasoning, verified end to end:

1. `!eco.value` lowers to `ptr addrspace(1)` (Ops.td:82-93). The MLIR→LLVM
   pipeline ends with `RewriteStatepointsForGC()`
   (EcoPtrIntVerify.cpp:**618**, inside `addEcoGCPipeline` :592-636). RS4GC
   statepoints **every** call to a non-`gc-leaf-function` callee and relocates
   every live `addrspace(1)` value from its OWN liveness. Our decls carry no
   `gc-leaf-function` attr (getOrCreateFunc `gcLeaf=false`), so **the lowered
   call IS a statepoint and roots are attached by RS4GC, automatically.**
2. The Eco-level `eco.gc_roots` mechanism exists only for ops whose lowering
   expands into MULTIPLE LLVM ops with internal GC points (see the comments at
   EcoGCPrepare.cpp:256-273 and :318-327). Our lowering is a **single**
   `LLVM::CallOp`, exactly like `StringFromIntOpLowering` — no internal
   allocation, so no root carrying is needed and the ops must NOT declare
   `Eco_GCRootCarrierOpInterface`.
3. **Do not add them to `isMayAllocOp`.** That list drives *fixed-size
   allocation grouping*. Both appends are variable-size; the loop at
   `:221-247` would push a non-`hasFixedAllocSize` op through the
   `flushGroup(); groups.push_back(singleton)` path at `:223-228`, which then
   calls `carrier.setGCRoots(...)` at `:283-284` on an op that is not a
   `GCRootCarrier` — a silent no-op — and stamps `eco.gc_group_size` on it.
   Harmless but meaningless; and if a future change makes the group-leader path
   assume the leader can carry roots, it becomes heap corruption. Keep them out.
4. **Do not add them to `hasFixedAllocSize` / `getFixedAllocSizeForGrouping`.**
   An append result has no static size (Q4.0 cost model). Adding them would
   under-reserve a coalesced nursery region — direct heap corruption.

**Correction to v1's stated win #2.** Two facts from the tree:
- `isGroupBarrier` (`:110-121`) is **effectively dead in this pass**: the
  grouping loop (`:221-246`) calls `flushGroup()` for **every** non-`mayAlloc`
  op *before* consulting `isGroupBarrier`, whose `if` body is an empty comment
  (`:242-244`). So an `eco.call` in the middle of two allocations already
  breaks the group merely by not being an alloc op. **Removing append sites
  from the barrier set purchases exactly nothing.**
- The root tail that `isCallSafepoint` attaches to `eco.call`
  (`:328-351` → `CallOp::setGCRoots`, EcoOps.cpp:995-1005) is **discarded at
  lowering**: `splitAdaptedRoots` (EcoToLLVMClosures.cpp:36-45) peels it off and
  hands it to `emitSafepointMarker`, which is a **NO-OP**
  (EcoToLLVMRuntime.cpp:**1134-1140**, "RS4GC handles safepoint insertion
  automatically — no marker needed"). So the root tail costs **MLIR IR size and
  EcoGCPrepare/parse time**, not LLVM spill slots or stackmap records.

Net: mechanism (2) is a **front-end/IR-size** effect, not a codegen effect.
Phase 4 measures it as `.mlir` bytes + Stage-7b backend wall, and must NOT
claim runtime wall from it.

**1a.5 The two exports.** `elm-kernel-cpp/src/core/UtilsExports.cpp` — add
`#include "allocator/ListOps.hpp"` next to the existing
`#include "allocator/StringOps.hpp"` (`:6`), and place the exports after
`Elm_Kernel_Utils_append` (`:160-170`), inside the existing `extern "C" {`
block (`:11`). Mirror `Elm_Kernel_Utils_append`'s exact
`Export::toPtr` / `Export::encode` shape:

```cpp
// Typed append exports for the eco.string.append / eco.list.append lowering
// (plans/kernel-opt-05). Same backends the polymorphic Utils::append reaches
// (Utils.cpp:839-848) — never a "leaf-only" fast path: either operand may be a
// slice/rope/view (string) or a chunk spine (list). NOT gc-leaf: both allocate.
HPtr eco_string_append(HPtr a, HPtr b) {
    void* pa = Export::toPtr(a.toBits());
    void* pb = Export::toPtr(b.toBits());
    // Both Empty embedded constants ("" ++ ""): toPtr yields nullptr for both.
    if (!pa && !pb) return a;
    // StringOps::append itself handles one-sided null and zero length
    // (StringOps.hpp:478-486) and roots across every allocation it performs
    // (:498 StackRootGuard; :533-536 wrap-then-makeRope).
    HPointer result = StringOps::append(pa, pb);
    return HPtr::fromBits(Export::encode(result));
}

HPtr eco_list_append(HPtr a, HPtr b) {
    void* pa = Export::toPtr(a.toBits());
    void* pb = Export::toPtr(b.toBits());
    // Nil is the Empty embedded constant -> toPtr == nullptr.
    if (!pa) return b;   // [] ++ b == b
    if (!pb) return a;   // a ++ [] == a
    auto& allocator = Allocator::instance();
    // No allocation between the two wraps, so neither HPointer can go stale.
    // Raw pa/pb are DEAD from here on — never hold a resolved void* across
    // ListOps::append, which allocates.
    HPointer la = allocator.wrap(pa);
    HPointer lb = allocator.wrap(pb);
    HPointer result = ListOps::append(la, lb);
    return HPtr::fromBits(Export::encode(result));
}
```

**Rooting note (do NOT add a `StackRootGuard` here).** Neither wrapper allocates
before its backend call, so there is nothing to root. `ListOps::append` roots
its own operands on the chunk path (`ListOps.cpp:274 StackRootGuard guard(&a,
&b)`) and the vector path holds only C++-heap storage before
`listFromUnboxables(elements, b)` (`:286-291`) — this is the identical calling
shape `Utils::append` uses today (`Utils.cpp:846-848`), so the rooting contract
is unchanged. Adding a redundant guard in the wrapper would root *copies* and
buy nothing.

**Registration checklist for each new symbol — FIVE points, not three.**

The right precedent is **`eco_string_cmp_order`** (landed by the Aug-10 compare
series): like ours, it is an `eco_`-prefixed typed export reached from a
*dialect-op lowering* through `getOrCreateFunc`, not from `eco.call`. Every
one of its five wiring points was opened and verified 2026-08-10:

| # | File | What | `eco_string_cmp_order` precedent |
|---|---|---|---|
| 1 | `elm-kernel-cpp/src/core/UtilsExports.cpp` | `extern "C"` definition (above), inside the `extern "C" {` at `:11` | `:60` |
| 2 | `elm-kernel-cpp/src/KernelExports.h` | declaration — `HPtr eco_string_append(HPtr a, HPtr b);` / `HPtr eco_list_append(HPtr a, HPtr b);` (put them beside the existing `eco_string_cmp3`/`eco_string_cmp_order` decls, not beside `:203`) | `:193` |
| 3 | `runtime/src/codegen/RuntimeSymbols.cpp` | `KERNEL_SYM(eco_string_append)` / `KERNEL_SYM(eco_list_append)` in the Utils block (`:703-741`), macro at `:583-587` — **JIT only**; AOT resolves at link | `:741` |
| 4 | `runtime/src/codegen/Passes/EcoToLLVMInternal.h` + `EcoToLLVMRuntime.cpp` | `getOrCreateStringAppend` / `getOrCreateListAppend` decl + defn (§1a.2) | `EcoToLLVMInternal.h:705`, `EcoToLLVMRuntime.cpp:946-950` |
| 5 | `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | call both from `materializeAllRuntimeDecls` (`:1211`, add beside `:1271`) — **the easily-missed one**; omitting it is a non-deterministic parallel-Stage-2 assert, not a clean error | `:1264` |

**Why `Elm_Kernel_Utils_append` has only three** (KernelExports.h:203,
UtilsExports.cpp:160, RuntimeSymbols.cpp:711): it is reached through
`eco.call`, whose callee decl is minted from the front-end's `is_kernel`
`func.func` stub (`Ctx.registerKernelCall`, Ops.elm:663-668), so it never goes
through `getOrCreateFunc`. Our two symbols are NOT in that class — do not use
`Utils_append` as the wiring model. No CMake edit: `UtilsExports.cpp`,
`KernelExports.h` and `RuntimeSymbols.cpp` are all already in the build.

**Phase 1a acceptance:** `cmake --build build --target ecoc` succeeds; the new
`test/codegen/string_list_append.mlir` passes all three legs (`-emit=mlir-llvm`,
`-emit=llvm`, `-emit=jit`) — the JIT leg is what proves the `KERNEL_SYM`
entries, per the `inline_alloc_tuple.mlir` precedent.

### Phase 1b — compiler: emission arms

**1b.1 `Intrinsics.elm`.** Two constructors after `CompareToOrder` (`:53`):

```elm
    | AppendString
    | AppendList
```

`intrinsicResultMlirType` (arm next to `StringFromInt`, `:119-123`):

```elm
        AppendString ->
            Types.ecoValue

        AppendList ->
            Types.ecoValue
```

`intrinsicOperandTypes` (arm next to `CompareToOrder`, `:239-253`) — the
`CompareStringKind` comment at `:250-251` is the governing precedent:

```elm
        -- REP_ABI_001: String and List cross every ABI as !eco.value. Never
        -- unbox; unboxArgsForIntrinsic no-ops for boxed-expected slots.
        AppendString ->
            [ Types.ecoValue, Types.ecoValue ]

        AppendList ->
            [ Types.ecoValue, Types.ecoValue ]
```

`generateIntrinsicOp` (arm next to `CompareToOrder`, `:960-981`):

```elm
        AppendString ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.string.append" resultVar
                        ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoBinaryOp ctx "eco.string.append" resultVar
                        ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) Types.ecoValue

        AppendList ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.list.append" resultVar
                        ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoBinaryOp ctx "eco.list.append" resultVar
                        ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) Types.ecoValue
```

`utilsIntrinsic` arms — insert immediately before the final `_ -> Nothing`
(`:643-644`). **The `MVar` residue falls through this final wildcard
unchanged** — that is the whole fallback story; there is no explicit `MVar`
arm to write:

```elm
        -- ++ on statically-known String / List (plans/kernel-opt-05). The
        -- residue — ANY MVar operand — falls through to `_ -> Nothing` below
        -- and keeps emitting eco.call @Elm_Kernel_Utils_append verbatim.
        ( "append", [ Mono.MString, Mono.MString ] ) ->
            Just AppendString

        ( "append", [ Mono.MList _ _, Mono.MList _ _ ] ) ->
            Just AppendList

        -- Defensive: a mixed String/List pair violates `appendable a => a -> a
        -- -> a` and Phase 0 must have measured this bucket at ZERO. These two
        -- arms exist ONLY so that the one-sided wildcards below can never
        -- silently mis-dispatch such a pair to the wrong typed op; they fall
        -- back to the polymorphic kernel, which still routes by runtime tag.
        -- REQUIRED if (and only if) the one-sided arms are emitted, and they
        -- MUST precede them.
        ( "append", [ Mono.MString, Mono.MList _ _ ] ) ->
            Nothing

        ( "append", [ Mono.MList _ _, Mono.MString ] ) ->
            Nothing

        -- One-sided arms: ONLY if Phase 0's s_/_s/l_/_l buckets are nonzero.
        -- Sound because `++ : appendable a => a -> a -> a` forces both
        -- operands to the same Elm type; the unresolved side is
        -- MVar _ CEcoValue, already !eco.value at ABI.
        ( "append", [ Mono.MString, _ ] ) ->
            Just AppendString

        ( "append", [ _, Mono.MString ] ) ->
            Just AppendString

        ( "append", [ Mono.MList _ _, _ ] ) ->
            Just AppendList

        ( "append", [ _, Mono.MList _ _ ] ) ->
            Just AppendList
```

**1b.2 Flag gate.** `utilsIntrinsic` has no `Ctx.Context` (signature
`Name -> List MonoType -> MonoType -> Maybe Intrinsic`, `:563`), and neither
does `kernelIntrinsic` (`:318`). Do **not** widen either; add a wrapper and
change only the call sites that can see `home == "Utils"`:

```elm
{-| Config-gated wrapper. The append arms are the only intrinsics behind a
flag; everything else is unconditional. `appendSplit == False` reproduces the
pre-flag emission byte-for-byte.
-}
kernelIntrinsicCfg : Bool -> Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsicCfg appendSplit home name argTypes resultType =
    case kernelIntrinsic home name argTypes resultType of
        Just AppendString ->
            if appendSplit then Just AppendString else Nothing

        Just AppendList ->
            if appendSplit then Just AppendList else Nothing

        other ->
            other
```

Add `kernelIntrinsicCfg` and `appendKindLabel` to the module's `exposing` list
(`:1`) and `@docs` block (`:8`).

Call-site edits — **Expr.elm:3725** and **Expr.elm:4199** become
`Intrinsics.kernelIntrinsicCfg ctx.ecoConfig.append.split <args>`.
**Expr.elm:775** is left alone: it passes `argTypes = []`, which cannot match a
two-element arm.

**1b.3 Config plumbing.** `Compiler/Eco/Config.elm`:

```elm
{-| Append type-split knobs (plans/kernel-opt-05). `split = False`
reproduces today's emission byte-for-byte (`utilsIntrinsic` declines and the
polymorphic `eco.call @Elm_Kernel_Utils_append` is emitted). Both fields are
ARTIFACT-AFFECTING: `split` changes emitted ops, `census` stamps
`eco.append_kind` attrs onto kernel calls. Hash tokens `apsplit=1` /
`apcensus=1`, emitted only when enabled, so disabled configs hash exactly like
the historical pre-flag caches. `census` is env-only, never from JSON.
-}
type alias AppendConfig =
    { split : Bool
    , census : Bool
    }
```

**ORDER IS LOAD-BEARING.** `decoder` is
`D.pure EcoConfig |> D.apply … |> D.apply …` (Config.elm:346-361) — the record
alias's *positional* constructor. The alias's current field order is
`inline, bytesFusion, logicalTypes, cafMemo, mono, borrow, list, aggPromote,
ctorInline, sretResults, psplitParams, sretFresh, sretTailFuncs`
(Config.elm:34-48) and `decoder` applies them in exactly that order. So
`append` must be added as the **LAST** field of the alias AND as the **LAST**
`D.apply` in `decoder`; any other position silently mis-assigns every field
after it.

- `type alias EcoConfig` (`:34-48`): add `, append : AppendConfig` as the final
  field.
- `default` (`:292-339`): add `, append = { split = False, census = False }` as
  the final field.
- `decoder` (`:346-361`): append
  `|> D.apply (D.optionalField "append" appendDecoder default.append)` as the
  final line, with `appendDecoder` mirroring `listDecoder` (`:367-370`) —
  decode `split` only, carry `census` from `default`:

  ```elm
  appendDecoder : D.Decoder x AppendConfig
  appendDecoder =
      D.pure (\split -> { split = split, census = default.append.census })
          |> D.apply (D.optionalField "split" D.bool default.append.split)
  ```
- `hash` (the function starts at `:540`): add two token blocks to its
  token-append chain, immediately after the `lchunks=1` block at `:677-686`,
  copying that block's shape verbatim (`++ (if cfg.append.split then [
  "apsplit=1" ] else [])`, same for `apcensus=1`).
- `Builder/Eco/Config.elm`: two links appended to the `applyEnvOverrides`
  chain, whose last link today is `ECO_BORROW_OPT` at `:260-264`. The link
  shape is `Task.andThen` outside, `Task.map` inside — copy it exactly:

  ```elm
          |> Task.andThen
              (\cfg30 ->
                  (Utils.envLookupEnv "ECO_APPEND_SPLIT" |> Task.mapError never)
                      |> Task.map (\asVal -> applyAppendSplitOverride asVal cfg30)
              )
          |> Task.andThen
              (\cfg31 ->
                  (Utils.envLookupEnv "ECO_APPEND_CENSUS" |> Task.mapError never)
                      |> Task.map (\acVal -> applyAppendCensusOverride acVal cfg31)
              )
  ```

  plus `applyAppendSplitOverride` copied from `applyListChunksOverride`
  (`:490-511`, the `1|true|yes|on` / `0|off` parse) and
  `applyAppendCensusOverride` copied from `applyListReportOverride`
  (`:517-532`, the on-only parse). Also add both env vars to the module doc
  comment's env list (`:78-104`).

**Phase 1b acceptance:** with the flag OFF, Stage-5 `eco-compiler.mlir` is
byte-identical to the pre-change build (`cmp`). With the flag ON, the new
`.mlir` contains `"eco.string.append"` / `"eco.list.append"` and the residual
`Elm_Kernel_Utils_append` count equals Phase 0's `poly` bucket + 1 (stub).
**Caveat on the "+1":** the `is_kernel` stub is emitted only because
`Ops.ecoCallNamed` calls `Ctx.registerKernelCall` on an emitted call
(Ops.elm:663-668). If the `poly` bucket turns out to be 0 the stub disappears
too and the expected residual is **0, not 1**.

### Phase 2 — verify the split landed and the residue is what Phase 0 predicted

```bash
cd /work/build/compiler/build-kernel
ECO_APPEND_SPLIT=1 ./bin/eco-compiler make --optimize --text-mlir \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/append-split.mlir /work/compiler/src/Terminal/Main.elm \
    2>&1 | tee /tmp/append_split_build.txt
M=bin/append-split.mlir
grep -o '"eco.string.append"'     "$M" | wc -l
grep -o '"eco.list.append"'       "$M" | wc -l
grep -o 'Elm_Kernel_Utils_append' "$M" | wc -l
```

**Acceptance:** `string.append + list.append + max(Utils_append − 1, 0) ==
3,464 ± the drift between the 2026-08-09 census snapshot and HEAD` (3,464 is
the *direct call-site* population; the raw census row 3,465 includes the one
`is_kernel` stub — design doc :239-242), and the `Utils_append` residue matches
Phase 0's `poly` count within a handful of sites. A mismatch means an arm is
firing on a shape the census did not classify — fix the classifier and the arm
together, never one alone. Re-run Phase 0's `MIXED` and `papCreate` checks on
this module too; both must still be 0.

### Phase 3 — facts row for `("Utils","append")` (independent of 1/2)

**This is a MONO-level row, not a per-new-callee row.** Borrow runs in GlobalOpt
over the Mono graph, where every append site is still
`MonoVarKernel _ _ "Utils" "append"`; the split happens later, at MLIR emission.
So the two new runtime symbols never appear as a `(home, name)` key and must NOT
get rows.

**This is an EDIT of a row kernel-opt-07 already ships, not a new row.**
kernel-opt-07's Phase-3 class-A2 table already carries `(Utils, append)` with
the effect axes filled in and the **borrow axes deliberately left un-audited**
(`params = []` / `resultAliases = []`, so its shim reports a MISS). This item's
whole Phase-3 contribution is to fill those two axes in. Per the canonical
schema (kernel-opt-07, `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, keyed
`(home, name)`), the merged row is:

```elm
        , ( ( "Utils", "append" )
          , { auditedPure
                | params = [ POwned, POwned ]        -- <- 05 fills this in
                , resultAliases = [ 0, 1 ]           -- <- and this
                , gcAlloc = GcUnbounded
                , cppAlloc = True
                , divergence = Just "unsupported tag pair silently returns the first argument (elm-kernel-cpp/src/core/Utils.cpp:851-852) instead of failing"
                , evidence = "elm-kernel-cpp/src/core/Utils.cpp:829-853; string path runtime/src/allocator/StringOps.hpp:477-537 (makeRope roots both operands, runtime/src/allocator/StringOps.cpp:79-84); list path runtime/src/allocator/ListOps.cpp:262-292 (result shares rhs spine, :291); OWNER per design_docs/borrow-inf-census.md:883-897"
            }
          )
```

(`auditedPure` supplies `callTimeEffect = EffNone`, `callsBackIntoElm = False`,
`cseSafe = True`, `totality = Total`. **Keep 07's `divergence` string** — 05's
v1 had `divergence = Nothing`, which contradicts the sibling plan and erases
the ledger entry for the silent type-error swallow. Note the divergence stays
true after this item ships: it becomes unreachable only at *statically typed*
sites; the `poly` residue still routes through `Utils::append`. Phase 5, if it
runs, is what retires it.)

Derived (never stored): `canTriggerGC = True`, `gcLeafEligible = False`,
`droppable = True`, `hoistable = True`.

**Cross-plan obligation — this change is NOT inert for kernel-opt-07.**
Filling `params` makes `KernelSigs.lookup ( "Utils", "append" )` start
answering `Just`, which breaks two of 07's Phase-4 suites as written:
suite 3 (`legacyBorrowGolden`, the 33-row transcription) and suite 4 (`NO key
outside the legacy 33 answers the borrow shim`). Landing 05's Phase 3
therefore REQUIRES, in the same commit, adding
`( ( "Utils", "append" ), { params = [ POwned, POwned ], resultAliases = [ 0, 1 ] } )`
to `legacyBorrowGolden` and re-labelling those suites "34". Do not land Phase 3
without that edit; do not silently weaken suite 4 to a subset check.

If kernel-opt-07 has not shipped, land the borrow axes only, in today's
`KernelSigs.elm` shape (table header at `:51-52`, rows from `:53`; `ParamMode`
at `:35-37`, `KernelSig` at `:40-43`; record-literal rows are the norm — see
`(JsArray, unsafeGet)` at `:66-70`):

```elm
        , ( ( "Utils", "append" )
            -- OWNER over BOTH String and List (borrow-inf-census.md:883-897):
            -- >32 KiB strings become a rope retaining both operands
            -- (StringOps.cpp:79-84); list append aliases `b` into the result
            -- tail (ListOps.cpp:291). Rows exist to move these ~3,274 sites off
            -- the DEFAULTED tally, not to reclaim borrows.
          , { params = [ POwned, POwned ], resultAliases = [ 0, 1 ] }
          )
```

**Baseline (CURRENT, not the §16 one).** The live baseline is
design_docs/borrow-inf-census.md **§18.2 (2026-07-31, post-U-T1.2 — the 33-row
`KernelSigs` in the tree today)**, `:1149-1160`:

```
borrowed=1382579 (32%)  kernelSigHits=7415  kernelDefaultedHeapCalls=11165
poisonedByKernel=20508  sccBailouts=0  maxSccIter=3  sigMissReads=0
```

§18.2 `:1164-1166` names `Utils.append` = **3,274** as the remaining #2 entry of
the un-audited worklist. (The §16 numbers — `13230` / `5312` / `borrowed=1367828`
— are the PRE-U-T1.2 snapshot and must not be used as the baseline; v1 of this
plan did.)

**What the row buys (state it honestly):** `kernelDefaultedHeapCalls`
**11,165 → ≈7,891** (−3,274) and `kernelSigHits` **7,415 → ≈10,689**, removing
the #2 entry from the audit worklist. **`borrowed` does not move** — the default
was already the sound answer. Do not report this as a borrow win.

**Acceptance:** `ECO_BORROW=1 ECO_BORROW_REPORT=1` self-compile census line
shows `kernelDefaultedHeapCalls` ≈7,891 (down ~3,274), `kernelSigHits` ≈10,689,
`borrowed=138xxxx (32%)` unchanged within noise, and `sccBailouts=0
maxSccIter=3 sigMissReads=0` still clean.

### Phase 4 — measure

**A/B, three legs, interleaved, majors recorded with every wall:**
`OFF` (`ECO_APPEND_SPLIT=0`) / `ON` (`=1`), two runs each, alternating.
Workload = Stage 7a (`eco-compiler` compiling `Terminal/Main.elm`), the standing
benchmark. Record for each run: wall, minor GCs, **major GCs**, RSS, and the
emitted `.mlir` byte size.

Re-run the dynamic census with the shipped `ON` binary and check the
`Elm_Kernel_Utils_append` row collapses from 50,438,448 to approximately the
Phase-0 `poly` share, with `eco_string_append` + `eco_list_append` absorbing the
difference.

**The census harness is NOT in the tree** — it is the temporary patch specified
in `plans/kernel-call-census.md` §C1.1/§C1.2 (`eco_kernel_census_bump` in
`runtime/src/allocator/RuntimeExports.cpp` + an `ECO_KERNEL_CALL_CENSUS=1`
module walk in `EcoBackend.cpp`, inserted after `propagateGcFreeLeafAttrs` and
before RS4GC). Re-apply it, then make ONE edit: **its callee match is a PREFIX
list — `Elm_Kernel_` / `Eco_Kernel_` / `elm_string_from_` / `elm_array_` /
`Eco_Runtime_getOrder` (kernel-call-census.md:58-61). `eco_string_append` and
`eco_list_append` match NONE of them and would be silently invisible; add
`eco_string_` and `eco_list_` (or the two literal names) to that list.**
Run per kernel-call-census.md §C1.4; drop the patch again before shipping (its
§C1.3 flag-off byte-identity gate is the reason it is not resident).

**Honest expectation and the stop rule.** Deleted per call: 2 `getTag` loads, 2
`alloc::isString` tests, ≤2 tag compares, one `isNil`, one call frame's worth of
branch — a few nanoseconds × 50.4M ≈ **low hundreds of milliseconds at most** on
a multi-minute workload. If wall is flat, that is the expected outcome, not a
failure: **record it and keep the change for (a) and (d) below.** Reverting on
flat wall would also revert the correctness fix.

### Phase 5 — optional kernel hardening (gated on Phase 2's numbers)

Only if Phase 2 shows the residue is small AND a `poly`-site runtime probe shows
every residual dispatch resolves to string or list, replace `Utils.cpp:851-852`'s
silent `return wrap(a)` with a hard trap. **Precondition:** the fallback must
keep working for the residue — the change is `unsupported tag → abort`, never
`residue → abort`. If any residual site can legitimately reach `:851`, skip
Phase 5 entirely and leave the comment updated to say so.

## Win mechanism (explicitly NOT inlining)

Both ops remain statepointed calls — they allocate variable-size results. What
is actually purchased, ranked by confidence:

1. **Typed dispatch deletion (real, small).** No runtime tag dispatch on a
   50.4M-call path — see the deleted work list in Phase 4.
2. **Correctness (certain).** The silent type-error swallow at
   `Utils.cpp:851-852` becomes unreachable for every statically-typed site.
3. **IR-size relief (real, front-end only).** ≤3,464 `eco.call` ops lose their
   `eco.gc_roots_count` tails and root operands. Measure as `.mlir` bytes and
   Stage-7b backend wall — **not** as runtime wall, because those roots are
   discarded at lowering (`emitSafepointMarker` is a no-op,
   EcoToLLVMRuntime.cpp:1134-1140).
4. **Enabling (unmeasurable today).** A typed boundary permits append-specific
   work a polymorphic symbol forbids: small-append fast paths, chain
   flattening, `a ++ b ++ c` fusion, string-builder recognition.
5. **NOT purchased:** allocation-group-barrier relief (`isGroupBarrier` is dead
   code in the grouping loop, EcoGCPrepare.cpp:221-246) and borrow recovery
   (append is a genuine owner, borrow-inf-census.md:883-897). Both were claimed
   in v1; both are struck.

## Traps & risks

- **Slice/rope/view inputs.** The kernel routes ANY string-shaped append through
  `StringOps::append` precisely because either side may be a slice
  (`Utils.cpp:837-841`). The typed export must call the SAME entry point — do
  not "optimize" to a leaf-only path. Covered by the E2E rope/slice cases.
- **Null / embedded-constant operands.** `Empty` (`0x6`) resolves to `nullptr`
  through `Export::toPtr` (ExportHelpers.hpp:47-68). `Utils::append` guards at
  `:830-832`; `StringOps::append` guards at `:478-486`; `ListOps::append` guards
  `isNil` at `:263-264`. The wrappers must keep the `!pa && !pb` (string) and
  `!pa` / `!pb` (list) guards — `ListOps::append` takes `HPointer`, and
  `wrap(nullptr)` is NOT a valid Nil.
- **Never mark either op `hasFixedAllocSize`/groupable.** Appends build
  variable-size results; a coalesced region sized from a bogus constant is heap
  corruption. This is the single highest-severity mistake available here.
- **Do not mark either op `Pure`.** `Eco_StringCmpOrderOp` is `[Pure]` because
  it allocates nothing (Ops.td:2751-2757); `Eco_StringFromIntOp` is trait-free
  because it allocates (`:1102-1112`). Follow from_int. (There is no MLIR
  canonicalizer between emission and `EcoGCPrepare` today — the func-level one
  was removed, EcoPipeline.cpp:88-96 — so `Pure` would not immediately bite,
  which is exactly why it would bite later.)
- **`unboxArgsForIntrinsic` never BOXES.** It only inserts `eco.unbox` when
  actual is `!eco.value` and expected is primitive (Intrinsics.elm:294-304). If
  an operand ever arrives already-unboxed with `!eco.value` expected, it is
  passed through raw and the lowered call receives a non-pointer. Cannot happen
  for String/List under REP_ABI_001 (same assumption `CompareStringKind`
  already makes), but if a verifier failure appears at
  `eco.string.append`, this is the first place to look.
- **Half-resolved shapes.** Phase 0 measures `(MString, MVar)` /
  `(MVar, MList)` explicitly. The one-sided arms are correct by
  `appendable a => a -> a -> a` but must be justified by counts, not assumed.
  Their wildcards also swallow a mixed `(MString, MList)` pair, so the two
  `-> Nothing` guard arms in 1b.1 are MANDATORY whenever the one-sided arms
  ship, and must sit above them.
- **Census flag is text-mode-only in practice.** `ECO_APPEND_CENSUS=1` stamps
  `eco.append_kind` on the emitted `eco.call`. It is a discardable `eco.`-domain
  attr (same class as `eco.gc_roots_count`), so a bytecode build would also
  round-trip it through `eco-boot-native` harmlessly — but nothing consumes it
  and it perturbs the artifact hash (`apcensus=1`). Use it only with
  `--text-mlir`, and never leave it set in a build whose output feeds a
  byte-identity gate.
- **`--local-package eco/kernel=/work/eco-kernel-cpp` vs
  `/work/elm-kernel-cpp`.** Both directories exist. The kernel *package* passed
  on the command line is `eco-kernel-cpp`; the C++ exports edited in Phase 1a
  live in `elm-kernel-cpp`. Getting these backwards silently builds the wrong
  kernel.
- **`--target full`, never `check`.** This changes emitted MLIR; `check`
  consumes stale `.mlir`.
- **Bootstrap order.** Runtime lowering must exist before compiler emission
  (see Flag & rollback).
- **Flat-wall prior (×4).** preserve-cc, gc-leaf pilot at 64.1% dynamic
  coverage, capacity-check hoisting, the compare phases — all wall-FLAT.
  Mechanism (3) above is exactly that class. Mechanism (1) deletes real per-call
  work, but it is genuinely small per call.
- **GC-trigger lottery.** Record major-GC counts with every wall number; a
  1-major swing swamps this change's whole expected effect.

## Dependencies

- **None blocking** — item 05 is in the mutually-independent unblocked set
  {01, 02, 04, 05, 06}.
- **kernel-opt-07 (KernelFacts):** **NOT independent — see Phase 3.** 07 already
  ships a `(Utils, append)` class-A2 row with `params = []`; 05 fills the borrow
  axes in, which flips 07's shim from MISS to HIT for that key and therefore
  requires 07's Phase-4 suites 3 and 4 to be updated to 34 golden keys in the
  same commit. If 07 has not shipped, the two borrow axes land in
  `KernelSigs.elm` instead and migrate when 07 demotes `KernelSigs.elm` to the
  shim (Constrain.elm / LssFacts.elm untouched either way). Keep 07's
  `divergence` string verbatim in either home.
- **kernel-opt-08 / -09 (`eco.gc_leaf`):** **no interaction.** The new callees
  are LLVM decls minted by `getOrCreateFunc`, not `is_kernel func.func` stubs,
  so they can never carry `eco.gc_leaf`; and they must not — `gcAlloc =
  GcUnbounded`. If 09's module-level marking pass lands first, it walks
  `eco.call` only and ignores `eco.string.append` / `eco.list.append` by
  construction. Coordinate edits to `EcoGCPrepare.cpp:110-140` textually (09
  rewrites `isGroupBarrier`/`isCallSafepoint`; 05 adds nothing there — a pure
  merge win if 05 lands first).
- **kernel-opt-12 (`eco.cse_safe`):** separate channel, per-call attr on
  `eco.call`. It never applies to these ops (they are not calls). No conflict.
- **kernel-opt-01 (List cons/construct):** shares ListOps territory and the
  `utilsIntrinsic`/`kernelIntrinsic` dispatch table. No code dependency; expect
  a textual merge in `Intrinsics.elm` and `RuntimeSymbols.cpp`.

## Expected impact

Honest: the deleted per-call dispatch is a handful of loads and branches, so
**wall could well be flat** — the ×4 prior says statepoint/metadata relief alone
does not move wall, and mechanism (3) here is precisely that class. The
guaranteed purchases are: (a) a silent type-error swallow on the #2 static
symbol becomes unreachable *at statically typed sites*; (b) up to 3,464 direct
call sites (20.4% static, 1.37% dynamic) leave the opaque kernel boundary for a
typed dialect op; (c) the same ≤3,464 `eco.call` root
tails leave the IR (front-end/backend compile time and `.mlir` size, measurable);
(d) a typed boundary that later append-specific work requires. **Not** purchased:
borrow recovery (owner) and group-barrier relief (dead code). Effort M.

## Gates

Run tests ONCE, tee, then grep — never re-run to re-read.

1. **Full E2E (both flag states).**
   ```bash
   cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
   grep -E 'FAILED|Falsifiable|[0-9]+/[0-9]+' /tmp/test_output.txt | tail -20
   ECO_APPEND_SPLIT=1 cmake --build build --target full 2>&1 | tee /tmp/test_output_on.txt
   grep -E 'FAILED|Falsifiable|[0-9]+/[0-9]+' /tmp/test_output_on.txt | tail -20
   ```
   Both legs must hold the current green baseline (1632/1632 as of the Aug-10
   compare series — re-baseline on `main` before starting) plus the 2 new tests.
2. **Heap-validate leg.** There is no `ECO_HEAP_VALIDATE` preset
   (CMakePresets.json has only `dev`/`build`/`release`/`mac-*`/`win-*`), and
   `--preset` pins `binaryDir`, so configure the second tree explicitly with the
   `build` preset's cache variables plus the option (`ECO_HEAP_VALIDATE` is a
   plain `option()` at CMakeLists.txt:84-88):
   ```bash
   cmake -S /work -B /work/build-val -G Ninja \
     -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
     -DCMAKE_EXE_LINKER_FLAGS_INIT=-fuse-ld=lld \
     -DCMAKE_SHARED_LINKER_FLAGS_INIT=-fuse-ld=lld \
     -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O2 -g -UNDEBUG" \
     "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O2 -g -UNDEBUG" \
     -DECO_HEAP_VALIDATE=ON
   ECO_APPEND_SPLIT=1 cmake --build /work/build-val --target full 2>&1 | tee /tmp/val_output.txt
   grep -E 'FAILED|Falsifiable|[0-9]+/[0-9]+' /tmp/val_output.txt | tail -20
   ```
   Green in BOTH trees. This is the gate that catches a wrong rooting decision
   in the exports.
3. **Bootstrap.** `cmake --build build --target bootstrap 2>&1 | tee /tmp/boot.txt`.
   - Flag OFF: byte-identical to today's fixed point (`eco-compiler-boot` ≡
     `eco-compiler-boot-2`, and `eco-compiler-boot.mlir` ≡
     `eco-compiler-boot-2.mlir` ≡ Stage 5's `eco-compiler.mlir`). Any `.mlir`
     diff flag-off is stop-the-line.
   - Flag ON: **a NEW fixed point** — output legitimately changes. Requirement
     is self-consistency: Stage 8c `eco-compiler-boot` ≡ `eco-compiler-boot-2`
     byte-for-byte and the Stage-7a/8a `.mlir`s agree. Record the new sizes here.
4. **Codegen test.** `test/codegen/string_list_append.mlir`, three RUN lines
   (`-emit=mlir-llvm` / `-emit=llvm` / `-emit=jit`) modelled on
   `test/codegen/inline_alloc_tuple.mlir:1-3`. The JIT leg is the gate on the
   two `KERNEL_SYM` registrations. **No registration step:** every `.mlir` in
   `test/codegen/` is auto-discovered by
   `test/codegen/CodegenIsolatedTest.hpp:290-305`
   (`std::filesystem::directory_iterator`, extension `.mlir`).
5. **E2E coverage.** `test/elm/src/AppendTypeSplitTest.elm` with `-- CHECK:`
   directives (auto-discovered, `test/ElmE2ETestBase.hpp:1089`): string append
   of two literals; append where one side is a `String.slice` view; append
   producing >32,768 units (forces `makeRope`); `[] ++ xs`, `xs ++ []`, Cons and
   ConsChunk spines; and a genuinely polymorphic `++` behind a type variable
   (residue path) — all under `ECO_APPEND_SPLIT=1`.
6. **Phase-0 census artifact.** `/tmp/append_census.txt` bucket counts summing
   to the static *direct call-site* total (**3,464** at the 2026-08-09 census
   snapshot; the 3,465 census row includes the 1 `is_kernel` stub), `MIXED == 0`,
   recorded in this file.
7. **Post-ship dynamic census.** `Elm_Kernel_Utils_append` drops from 50,438,448
   to ≈ the Phase-0 `poly` share; `eco_string_append` + `eco_list_append` absorb
   the difference. **Precondition:** re-apply the `plans/kernel-call-census.md`
   §C1 patch and extend its `EcoBackend.cpp` callee-PREFIX list (`Elm_Kernel_` /
   `Eco_Kernel_` / `elm_string_from_` / `elm_array_` / `Eco_Runtime_getOrder`,
   kernel-call-census.md:58-61) with `eco_string_` / `eco_list_` — otherwise
   both new symbols are invisible and the row simply looks deleted.
8. **Borrow census.** `kernelDefaultedHeapCalls` **11,165 → ≈7,891** (−3,274)
   and `kernelSigHits` **7,415 → ≈10,689** against the §18.2 baseline;
   `borrowed` stays at 32% (a move here means the row is wrong).
9. **Wall A/B with major-GC counts** per Phase 4, interleaved, both runs each.
