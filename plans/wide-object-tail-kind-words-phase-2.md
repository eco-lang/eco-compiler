# Wide objects, Phase 2: closures end to end

**Parent:** [`wide-object-tail-kind-words.md`](wide-object-tail-kind-words.md). The overview's §S
is binding for shared names, limits and signatures (§S.1 helpers and limits, §S.2
`pushRootsByKinds`, §S.3 codegen helpers, §S.4 new runtime entries, §S.5 `slot_kinds`, §S.7
commands, §S.8 how to add tests). This file also relies on overview §2.1–§2.4 (layout and closure
design), §5 (GC concurrency procedure), §6 (test mechanics) and §7 (performance gate). File:line
references are against the tree of 2026-10-05, **before** Phases 0–1 land. Phase 1 moves some
lines, so re-anchor on the named function.

**Status:** DONE (2026-10-05): all steps implemented; gate green ("Phase 2 gate result" below).

**Precondition (Phase 1 done):**
- `ClosureKinds` / `snapshotClosureKinds` / `closureKindAt` exist (header-only, 25 slots);
- the closure walkers use them;
- `deriveAllParamKindsBitmap` is UB-free;
- make.closure uses papCreate's packer (B13);
- the papCreateGroup root mask is chunked (B15);
- `pushRootsByKinds` exists (§S.2). If Phase 1 did not add it, step 2.2 adds it.

**What this phase delivers:**
- **Packed word:** `n_values:11 | max_values:11 | result_kind:2 | unboxed:40` (inline kinds for
  slots 0..19; `CLOSURE_HDR_SLOTS = 20`).
- **Limit:** stage arity ≤ 2047 (`CLOSURE_MAX_ARITY`).
- **Ext words:** the tail kind words are the **last** `K = extWords(max_values, 20)` words of the
  object, and `header.size` = allocated value slots + K (the physical-size rule).
- **Descriptors:** `EvaluatorDesc.stage_arity` is u16 at +18; `EvalParamLayout.num_params` is u16.
- **Kind attribute:** `slot_kinds` on papCreate, papExtend and papCreateGroup (optional; absent =
  derived from operand types, §S.5). papCreateGroup's required `unboxed_bitmaps` becomes optional.
  The front-end bytecode encoder writes dense i8 arrays correctly (step 2.0).
- **Caps:** 2047 / 2046.
- **Front end:** a flattening cap and a limit error.
- **Bugs fixed:** E4 (Pap27b), E8 (decoder records ≥ 26 fields) and the compiler's own latent E10
  (`InlineConfig`), plus E5–E7; B5, B18, B19, B20, B23.

---

## 0. Commit plan (each commit builds and passes its own check)

| # | Commit | Atomic because |
|---|---|---|
| 2.0 | front-end bytecode encoder writes dense-array elements at their element width | must precede the first Elm `slot_kinds` emitter (2.8); I64 users stay byte-identical |
| 2.1 | `slot_kinds` attribute added to Ops.td (optional); papCreateGroup `unboxed_bitmaps` made optional; verifier accepts both forms | dialect only, no producer yet |
| 2.2 | root-range chunking everywhere (`pushRootsByKinds`, codegen chunked pushes) | layout-neutral |
| 2.3 | `EvalParamLayout` u16 `num_params` | runtime struct, codegen emitter, kernels and tests share one byte layout |
| 2.4 | `EvaluatorDesc.stage_arity` u16 at +18 | runtime struct + two codegen emitters |
| 2.5 | `eco_pap_extend_l` + shim; C++ callers and lowering moved to it | old entry stays as a shim |
| 2.6 | **closure layout v2**: packed word, ext words, physical size, every reader/writer, sat guard, `SAT_MAX_ARITY` + empty `sat[]` above it, interning ≤ 20, `eco_alloc_closure_group_l`, make.closure | runtime and codegen must agree on the object layout; no split possible |
| 2.7 | caps 2047/2046 in verifiers + PAPSimplify; verifier after PAPSimplify in validate/test builds | needs 2.6 |
| 2.8 | front end: `slot_kinds` emission, elm-test checker, located limit diagnostics (`TooLarge`, `HeapLimits`, decline rules, post-mono `ValidateLimits`) | needs 2.1/2.7 |
| 2.9 | delete the `eco_pap_extend` shim, `eco_alloc_closure_group_slow`, dead helpers; invariants [P2]; docs | cleanup |

**Rollback:** the phase reverts as a unit (2.9 → 2.0). Inside the phase:
- 2.0 reverts alone only while no Elm emitter writes `slot_kinds` (before 2.8).
- 2.3, 2.4 and 2.6 each revert alone only together with their codegen half, which is in the same
  commit.
- 2.8 can revert alone (the attribute is optional).

After **every** commit that touches the runtime or kernels, run `cmake --build build` (all static
libraries; overview §6.1 relink rule) and the overview §6.3 cache wipe before any E2E. Kernels
are copied once into `~/.eco/0.1.3/packages/eco/kernel`.

---

## Step 2.0: bytecode encoder writes dense arrays at their element width

**Bug:** `compiler/src/Mlir/Bytecode/AttrType.elm:1141–1175` (`EDenseArrayAttr` arm) writes **8
bytes per element whatever the element type**. A `DenseI8ArrayAttr` (`slot_kinds`, §S.5) emitted by
the front end would be mis-encoded on the default bytecode path. Today every user is I64
(`tags` at `Ops.elm:1298`, `:1328`; `Expr.elm:257`, `:4277`), so nothing is visibly broken yet.

**Change** (same file; the element type is `ty`, `MlirType` at `Mlir/Mlir.elm:146–154`):

```elm
elemBytes : MlirType -> Int
elemBytes ty =
    case ty of
        I1 -> 1
        I8 -> 1
        I16 -> 2
        I32 -> 4
        _ -> 8

-- per element: little-endian, two's complement, `elemBytes ty` bytes. Byte k is
-- (v >> 8k) & 0xFF for k < 4; bytes 4..7 are 0 (every value is non-negative and < 2^31,
-- which is today's behaviour for I64).
encodeElem : Int -> Int -> BE.Encoder
encodeElem w v =
    BE.sequence
        (List.map
            (\k -> if k < 4 then BE.unsignedInt8 (Bitwise.and (Bitwise.shiftRightZfBy (8 * k) v) 0xFF) else BE.unsignedInt8 0)
            (List.range 0 (w - 1)))
```

and in the `EDenseArrayAttr ty vals` arm, `blob = BE.encode (BE.sequence (List.map (encodeElem
(elemBytes ty)) vals))`. For I64 this produces exactly today's 8 bytes per element, so existing
output is byte-identical.

**Tests:**
- elm-test (new case in the existing bytecode encoder test module under
  `compiler/tests/TestLogic/Mlir/`, or a new `DenseArrayEncodingTest.elm`): "dense i8 array encodes
  one byte per element". Encode `ArrayAttr (Just I8) [0,1,2,3]` and check that the blob section is
  `00 01 02 03` and the declared width field is 4. Second case: an I64 array `[5]` still encodes
  as `05 00 00 00 00 00 00 00`.
- After 2.8: one P2 E2E pin (`WideClosureSat26Test`) is run through the bytecode path (the harness
  default) **and** through `--text-mlir`, with identical output; `ecoc --emit=mlir` on its bytecode
  `.mlir` shows `array<i8: …>` for `slot_kinds`.

**Commands:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`.
**Expected:** the new case passes; failures = the 2 GOPT_003 pins only.
**Invariant:** bytecode output for every existing (I64) dense array is unchanged.
**Rollback:** revert (only before 2.8).

## Step 2.1: `slot_kinds` on closure ops (dialect, optional)

**Files:**
- `runtime/src/codegen/Ops.td`:
  - papCreate args at 1386–1392 (`unboxed_bitmap` at 1387);
  - papCreateGroup args at 1445–1455 (`unboxed_bitmaps` at 1451);
  - papExtend args at 1529–1538 (`newargs_unboxed_bitmap` at 1533);
  - make.closure at 3320ff.
- `runtime/src/codegen/EcoOps.cpp`:
  - `PapCreateOp::verify` 510–618;
  - `PapExtendOp::verify` 620–730;
  - `PapCreateGroupOp::verify` 731–860;
  - `MakeClosureOp::verify` 1439–1466.

**TableGen.** Add, without removing the old attributes:

```tablegen
// papCreate (after $unboxed_bitmap)
    OptionalAttr<DenseI8ArrayAttr>:$slot_kinds,        // one kind per captured operand
// papExtend (after $newargs_unboxed_bitmap)
    OptionalAttr<DenseI8ArrayAttr>:$slot_kinds,        // one kind per real newarg
// papCreateGroup (after $unboxed_bitmaps)
    OptionalAttr<ArrayAttr>:$slot_kinds,               // per sibling: DenseI8ArrayAttr, length num_captured[i]
// papCreateGroup: the required I64ArrayAttr:$unboxed_bitmaps (Ops.td:1451) becomes
    OptionalAttr<I64ArrayAttr>:$unboxed_bitmaps,
```

Making `unboxed_bitmaps` optional changes its getter to return an optional. Update its readers in
this commit: `PapCreateGroupOp::verify` (775–834) and `PapCreateGroupOpLowering`
(`EcoToLLVMClosures.cpp:965–1223`, the reads at 1138–1139 and the `unboxedBitmapsArr` fill at
1023–1076). Treat absent as "derive from the capture operand types" (`slotKindOf`, §S.3), the same
rule as an absent `slot_kinds`.

Update the op descriptions: "`slot_kinds[i]` ∈ {0 boxed, 1 Int, 2 Float, 3 Char} is the kind of
operand i; it must equal the operand's MLIR type kind. The legacy u64 attribute is advisory and
verified only for slots it can describe."

**Verifier (shared helper in EcoOps.cpp):**

```cpp
static uint8_t operandKind(Type t) {            // same mapping as codegen slotKindOf
  if (t.isInteger(64)) return 1; if (t.isF64()) return 2; if (t.isInteger(16)) return 3; return 0;
}
// Checks `kinds` against `operands`; the legacy word only for i < min(n, 32) when the attr is present.
static LogicalResult verifyClosureKinds(Operation* op, ValueRange operands,
                                        std::optional<ArrayRef<int8_t>> kinds,
                                        StringRef legacyName, const char* what) {
  if (kinds) {
    if (kinds->size() != operands.size())
      return op->emitOpError("slot_kinds length (") << kinds->size()
             << ") != " << what << " count (" << operands.size() << ")";
    for (auto [i, v] : llvm::enumerate(operands))
      if (uint8_t((*kinds)[i]) != operandKind(v.getType()))
        return op->emitOpError(what) << " " << i << " slot_kinds " << int((*kinds)[i])
               << " does not match SSA type " << v.getType();
  }
  if (op->hasAttr(legacyName)) {                 // DefaultValued: use hasAttr, not the getter
    uint64_t w = cast<IntegerAttr>(op->getAttr(legacyName)).getValue().getZExtValue();
    for (unsigned i = 0; i < operands.size() && i < 32; ++i)
      if (((w >> (2 * i)) & 3) != operandKind(operands[i].getType()))
        return op->emitOpError(legacyName) << " slot " << i << " disagrees with SSA type";
  }
  return success();
}
```

In 2.1 the existing checks stay (50-bit, the 25 caps, the per-slot switch). The helper is
**added**, called when `slot_kinds` is present. Commit 2.7 removes the old checks.

**Test.** New fixture `test/codegen/pap_slot_kinds_verify.mlir`:
- a papCreate and a papExtend with matching `slot_kinds`, run through
  `%ecoc %s -emit=mlir | %FileCheck %s` (expect a round trip);
- a negative twin `invalid_pap_slot_kinds_mismatch.mlir`, with
  `// CHECK: slot_kinds 1 does not match SSA type`.

**Commands:**
`cmake --build build --target test && ulimit -c 0 && build/test/test --filter "pap_slot_kinds|invalid_pap_slot" 2>&1 | tee /tmp/test_output.txt`.

**Expected:** 2 pass. **Invariant:** CGEN_003 (kinds ⇔ operand types) is still enforced.
**Rollback:** revert the commit.

## Step 2.2: chunked root ranges (layout-neutral)

`eco_gc_push_stack_range` asserts `count <= 64` (`RuntimeExports.cpp:4316`) and takes one u64
mask. After 2.7, arg buffers can hold up to 2047 slots.

**Every push site that can exceed 64 (verified by grep):**

| Site | Today | Change |
|---|---|---|
| `EcoToLLVMClosures.cpp:70–96` `emitPushArgsRootRange` (caller `emitInlineClosureCall` 2364–2376: mask loop **stops at `j < 64`**, so slots ≥ 64 are silently unrooted; **B23**) | single push | emit `ceil(n/64)` calls at `base + 64*c`, each with its own mask computed from the slot types |
| `EcoToLLVMClosures.cpp:2606–2645` (segmentation-unknown typed buffer, `1ULL << i` with i ≤ n) | single push | same |
| `EcoToLLVMClosures.cpp:2742–2783` (typed apply buffer) | single push | same |
| `EcoToLLVMClosures.cpp:2954–2967` (papExtend under-saturated args array) | single push | same |
| `EcoToLLVMClosures.cpp:1134–1172` (group flat captures; Phase 1 B15 fixed the `>= 64 → break`) | chunked in P1 | keep |
| `EcoToLLVMFunc.cpp:245–252` (shadow-frame args: `mask = N >= 64 ? ~0 : …`, count N unbounded, against the runtime's 64-slot assert; **B23**) | single push with count N | chunk; mask all-ones per chunk |
| `RuntimeExports.cpp:2290–2295` (`eco_apply_segmentation_unknown`) | `pointerMaskFromKindBitmap(bitmap, n)` | `pushRootsByKinds(typed_args, n, [&](u32 i){ return args_layout ? args_layout->kinds[i] : 0; })` |
| `RuntimeExports.cpp` `eco_apply_closure_eval` under-saturated (≈2429–2440) | same | same |
| `RuntimeExports.cpp:2899–2905` (`eco_closure_call_saturated`) and `:2978–2984` (`invokeSaturatedTyped`) | `pointerMaskFromKindBitmap(closure->unboxed, max_values)` | `pushRootsByKinds(combined_args, max_values, [&](u32 i){ return closureKindAt(ks, i); })`, with `ks` a snapshot taken right after resolving |
| `RuntimeExports.cpp` `eco_pap_extend` (2557–2571) | caller-mask + conv-mask | moves into `eco_pap_extend_l` (2.5) |

**Codegen helper (EcoToLLVMClosures.cpp, replaces the single push in `emitPushArgsRootRange`):**

```cpp
static void emitChunkedRootPush(ConversionPatternRewriter& rw, Location loc, const EcoRuntime& rt,
                                Value base, ArrayRef<bool> boxed) {
  auto i64 = rw.getI64Type(); auto push = rt.getOrCreateGcPushStackRange(rw);
  for (size_t off = 0; off < boxed.size(); off += 64) {
    size_t c = std::min<size_t>(64, boxed.size() - off); uint64_t m = 0;
    for (size_t i = 0; i < c; ++i) if (boxed[off + i]) m |= uint64_t{1} << i;
    if (!m) continue;
    Value p = off ? rw.create<LLVM::GEPOp>(loc, base.getType(), i64, base,
                       ValueRange{rw.create<LLVM::ConstantOp>(loc, i64, (int64_t)off)}) : base;
    rw.create<LLVM::CallOp>(loc, push, ValueRange{p,
        rw.create<LLVM::ConstantOp>(loc, i64, (int64_t)c),
        rw.create<LLVM::ConstantOp>(loc, i64, rw.getI64IntegerAttr((int64_t)m))});
  }
}
```

The range-point save and restore (`getOrCreateGcStackRangePoint` / `RestoreStackRangePoint`) is
unchanged: one save before the first chunk, one restore after the call.

**Tests:**
- unit `test/allocator/GenericApplyBoxingTest.cpp`, new case "generic apply of 70 args roots slots
  ≥ 64": a hand-built kernel closure via `allocClosureK(eval70, 70, 0)`, 70 boxed args, a forced
  minor GC inside the evaluator, then check the identities;
- codegen fixture `test/codegen/papextend_70_args_root_chunks.mlir`: CHECK two
  `eco_gc_push_stack_range` calls with counts 64 and 6.

The 70-arity case needs 2.6 and 2.7, so commit it in 2.7. In 2.2 use 40 args, which exercises the
helper path only.

**Fixes:** B23. **Rollback:** revert. **Invariant:** HEAP_020 (root containers) is unchanged.

## Step 2.3: `EvalParamLayout` with a u16 `num_params`

**`runtime/src/allocator/Heap.hpp:664–670` (new):**

```cpp
/// Memory layout: { num_params: u16, result_kind: u8, _pad: u8, kinds[num_params]: u8[] }
struct EvalParamLayout {
    unsigned short num_params;   // +0  (was unsigned char)
    unsigned char  result_kind;  // +2
    unsigned char  _pad;         // +3
    unsigned char  kinds[];      // +4
};
#ifdef __cplusplus
static_assert(offsetof(EvalParamLayout, num_params) == 0, "num_params at +0");
static_assert(offsetof(EvalParamLayout, result_kind) == 2, "result_kind at +2");
static_assert(offsetof(EvalParamLayout, kinds) == 4, "kinds at +4");
/// Static layouts for kernels: EvalParamLayoutN<N> is layout-compatible with EvalParamLayout.
template <unsigned N> struct EvalParamLayoutN {
    unsigned short num_params; unsigned char result_kind; unsigned char _pad; unsigned char kinds[N];
};
template <unsigned N>
constexpr EvalParamLayoutN<N> makeEvalParamLayout(unsigned char rk, const unsigned char (&k)[N]) {
    EvalParamLayoutN<N> l{}; l.num_params = N; l.result_kind = rk;
    for (unsigned i = 0; i < N; ++i) l.kinds[i] = k[i];
    return l;
}
inline const EvalParamLayout* asLayout(const void* p) { return static_cast<const EvalParamLayout*>(p); }
#endif
```

**Every hand-built layout (grep `kLayout|layoutBuf|OneArgLayoutHolder|sub_buf|LayoutStorage`):**

| File:line | Today | New |
|---|---|---|
| `elm-kernel-cpp/src/core/JsArrayExports.cpp:54` | `unsigned char kLayoutInt1[3] = {1,0,1}` | `constexpr auto kLayoutInt1 = Elm::makeEvalParamLayout<1>(0, {1});` |
| `:55` | `kLayoutIntBoxed[4] = {2,0,1,0}` | `makeEvalParamLayout<2>(0, {1,0})` |
| `:84`, `:156`, `:179`, `:503` | stack `layoutBuf[3/4] = {n, rk, …}` | `auto lb = Elm::makeEvalParamLayout<N>(rk, {…});` and pass `asLayout(&lb)` (also fix the `reinterpret_cast` at 86/158/181/505) |
| `elm-kernel-cpp/src/parser/ParserExports.cpp:175` | `kLayoutChar1[3] = {1,0,3}` | `makeEvalParamLayout<1>(0, {3})` |
| `elm-kernel-cpp/src/time/TimeExports.cpp:206` | `kLayoutInt1[3]` | same pattern |
| `elm-kernel-cpp/src/core/StringExports.cpp:198–199` | `kLayoutChar1`, `kLayoutCharBoxed` | same pattern (uses at 207/218/227) |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp:422` | `kLayoutBoxedInt[4] = {2,0,0,1}` | `makeEvalParamLayout<2>(0, {0,1})` (forward decl at 19 unchanged) |
| `elm-kernel-cpp/src/core/ListExports.cpp:545–548` | `layoutBuf[2 + kMaxArgs]` byte-filled | `EvalParamLayoutN<kMaxArgs> lb{}; lb.num_params = n_args; lb.result_kind = resultKind; …` (`kMaxArgs = 5`, `:434`) |
| `runtime/src/platform/Scheduler.cpp:671–682` | `OneArgLayoutHolder {u8,u8,u8[1]}` table | `static constexpr EvalParamLayoutN<1> one_arg_layouts[4] = { makeEvalParamLayout<1>(0,{0}), …{1}, {2}, {3} }` (use at 794 unchanged) |
| `runtime/src/allocator/RuntimeExports.cpp:2110–2141` | `kMaxClosureArity = 63`; `LayoutBytes{u8,u8,u8[63]}`; `getAllBoxedLayout` **clamps n to 63** (B19) | static table of `EvalParamLayoutN<64>` for n ≤ 64 (4 kinds × 65 entries ≈ 17 KiB), plus for n > 64 an interned cache `static std::unordered_map<uint32_t, std::unique_ptr<unsigned char[]>>` keyed `(K << 16) \| n` under a `std::mutex`, allocating `4 + n` zeroed bytes. Remove the clamp; `assert(n <= CLOSURE_MAX_ARITY)` |
| `runtime/src/allocator/RuntimeExports.cpp:2476–2478` | `unsigned char sub_buf[2 + 64]` | `std::unique_ptr<unsigned char[]>` (or `SmallVector<unsigned char, 68>`) of `4 + trailing` bytes; `sub->num_params = static_cast<unsigned short>(trailing)` |
| `test/allocator/EcoApplyClosureTypedTest.cpp:32–52` `LayoutStorage` | `buf[2 + MaxN]`, u8 `num_params` | `buf[4 + MaxN]`, `num_params` as `unsigned short` |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:2120–2187` `ensureEvalLayoutGlobal` | struct `{i8, i8, [N x i8]}` | `{i16, i8, i8, [N x i8]}`: insert `num_params` as i16 at 0, `result_kind` i8 at 1, pad i8 0 at 2, the array at 3 |
| `EcoToLLVMClosures.cpp:2191–2210` `getOrCreateEvalLayout` and the name builder in `ensureEvalLayoutGlobal` (2134–2142) | name `__eco_eval_layout_r<K>_<k0>_…_<n>` | factor `evalLayoutName(kinds, rk)` used by both: unchanged for n ≤ 64; for n > 64, `__eco_eval_layout_r<K>_h<fnv1a64(kinds)>_<n>` |
| `EcoToLLVMClosures.cpp:3116` `preMaterializeApplyLayouts` | builds names | uses `evalLayoutName` |

**Readers of `num_params`:**
- grep `->num_params` / `.num_params` in `runtime/src` and `elm-kernel-cpp/src`;
- the layout-vs-closure cross-check asserts in `eco_apply_closure_eval` (≈2480–2500).

All widen to `uint32_t` locals.

**Tests:**
- unit `EcoApplyClosureTypedTest` (existing cases) green;
- new `static_assert`s compile;
- new unit "getAllBoxedLayout(100, K) has num_params 100", for B19.

**Commands:**
`cmake --build build && cmake --build build --target test && ulimit -c 0 && build/test/test --filter "apply|layout|Generic" 2>&1 | tee /tmp/test_output.txt`.
Then the cache wipe (overview §6.3) and `full` (§S.7). The kernels changed, so their cached copy
is stale.

**Expected:** the same E2E failure list as the Phase 1 gate.

**Invariants:**
- CGEN_059 / CGEN_060: the EvalParamLayout semantics are unchanged; only the header widens.
- REP_ABI_001.

**Rollback:** revert the commit (the runtime struct, codegen emitter and kernels together).

## Step 2.4: `EvaluatorDesc.stage_arity` u16 at +18

**`runtime/src/allocator/Heap.hpp:605–613` (new):**

```cpp
struct EvaluatorDesc {
    EvalFunction   generic;      // +0   the __closure_wrapper_* address
    u64            kinds;        // +8   advisory: 2 bits/param, params 0..31 only
    unsigned char  _pad_sa;      // +16  (was stage_arity:u8; always 0 now)
    unsigned char  result_kind;  // +17  ParamKind of the wrapper's compiled return
    unsigned short stage_arity;  // +18  P (≤ 2047; was _pad0)
    unsigned int   _pad1;        // +20
    void*          sat[];        // +24  sat[0..stage_arity] if stage_arity <= SAT_MAX_ARITY, else empty (2.6.8); sat[0] unused
};
```

`static_assert`s (`Heap.hpp:630–637`):
- `stage_arity` at 18;
- `result_kind` at 17;
- `sizeof == 24`;
- `kinds` at 8 and `generic` at 0, unchanged.

`EcoToLLVMInternal.h:388`: `EvaluatorDescStageArityOffset = 18`.

**Writers:**
- `RuntimeExports.cpp:1266`: `desc->stage_arity = static_cast<unsigned short>(stage_arity);`;
- `EcoToLLVMClosures.cpp:1862–1866` (`getOrCreateEvalDesc`) and `:2032–2036`
  (`getOrCreateEvalDescForFunc`): `put(2, i8Ty, 0); put(3, i8Ty, resultKind & 3); put(4, i16Ty, stageArity /*arity*/);`.
  The struct type `{ptr, i64, i8, i8, i16, i32, [N x ptr]}` (1840, 2016) is unchanged.

**Readers:** none at runtime (grep: only these writers). The backend reads `sat` at +24
(`EvaluatorDescSatOffset`, unchanged).

**`sat[]` size:** a wide evaluator (stage arity > `SAT_MAX_ARITY`, §S.1) gets an empty `sat[]`
(step 2.6.8), so an arity-2047 descriptor is 24 bytes.

**Sat filter UB (B7):** `getOrCreateEvalDesc` (1801–1832) computes
`kindsBitmap >> 2*(stageArity - n)` for every n before `getOrCreateSatEntry` rejects
`stageArity > 16` (1683). Move the reject up:

```cpp
if (satFastEnabled() && !targetSymbol.empty() && stageArity <= 16) { … }
```

**Tests:**
- unit `HPointerLayoutTest` gains "EvaluatorDesc offsets" (`offsetof` checks);
- the existing sat-path codegen fixtures (`test/codegen/*sat*`) stay green.

**Rollback:** revert.

## Step 2.5: `eco_pap_extend_l` and the shim

**Declaration** (`runtime/src/allocator/RuntimeExports.h`, next to `eco_pap_extend`):

```cpp
extern "C" HPtr eco_pap_extend_l(HPtr closure_hptr, uint64_t* args, uint32_t num_newargs,
                                 const EvalParamLayout* caller_layout);   // null = all boxed
```

**Body outline** (replaces `eco_pap_extend` 2513–2663; the layout-v2 parts are filled in by 2.6):

```cpp
extern "C" HPtr eco_pap_extend_l(HPtr closure_hptr, uint64_t* args, uint32_t num_newargs,
                                 const EvalParamLayout* caller_layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    Closure* old = static_cast<Closure*>(hpointerToPtr(closure_bits));
    if (!old) return HPtr::fromBits(0);
    ClosureKinds ks; snapshotClosureKinds(old, ks);          // kinds survive the boxing GC
    const uint32_t old_n = old->n_values, max = old->max_values, new_n = old_n + num_newargs;
    const uint8_t rk = old->result_kind;
    if (new_n > max) { fprintf(stderr, "eco_pap_extend_l: %u > max %u\n", new_n, max); abort(); }
    auto callerKind = [&](uint32_t i) -> uint32_t { return caller_layout ? caller_layout->kinds[i] & 3 : 0; };
    llvm::SmallVector<uint64_t, 64> conv(num_newargs, 0);   // was conv[63]
    EcoRootMark saved = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    pushRootsByKinds(args, num_newargs, callerKind);
    pushRootsByKinds(conv.data(), num_newargs, [&](uint32_t i){ return closureKindAt(ks, old_n + i); });
    for (uint32_t i = 0; i < num_newargs; ++i) {
        uint32_t sk = closureKindAt(ks, old_n + i), ck = callerKind(i);
        conv[i] = convertArgToSlotKind(args[i], ck, sk);     // body = today's 2574-2601 switch (may allocate)
    }
    const uint32_t K = extWords(max, CLOSURE_HDR_SLOTS);     // 2.6; before 2.6: K = 0
    const size_t size = sizeof(Closure) + (size_t(new_n) + K) * sizeof(Unboxable);
    void* obj = Allocator::instance().allocateFast(size);
    if (obj) { Header* h = getHeader(obj); zeroNewObject(h, size); h->tag = Tag_Closure;
               h->size = new_n + K; }
    else if (!(obj = Allocator::instance().allocateSlow(size, Tag_Closure))) { ecoRootRelease(saved); return HPtr::fromBits(0); }
    old = static_cast<Closure*>(hpointerToPtr(closure_bits));           // may have moved
    Closure* nc = static_cast<Closure*>(obj);
    nc->n_values = new_n; nc->max_values = max; nc->result_kind = rk;
    nc->unboxed = ks.hdr; nc->evaluator = old->evaluator;
    for (uint32_t i = 0; i < old_n; ++i) nc->values[i] = old->values[i];
    for (uint32_t i = 0; i < num_newargs; ++i) nc->values[old_n + i].i = static_cast<i64>(conv[i]);
    u64* ext = reinterpret_cast<u64*>(&nc->values[new_n]);             // last K words (physical rule)
    for (uint32_t j = 0; j < K; ++j) ext[j] = ks.ext[j];                // zeros included
    closureStatsRecord(reinterpret_cast<const void*>(nc->evaluator), /*isExtend=*/true);
    ecoRootRelease(saved);
    return ptrToHPointer(obj);
}
```

The **shim** `eco_pap_extend(HPtr, uint64_t*, uint32_t n, uint64_t bitmap)` builds a stack
`EvalParamLayoutN<64>` from `bitmap` (`assert(n <= 32)`) and calls `eco_pap_extend_l`. It is
deleted in 2.9.

**Callers moved in this commit:**
- `eco_apply_segmentation_unknown` (`RuntimeExports.cpp:2268–2298`): delete the
  `assert(num_args <= 32)` bitmap build; call `eco_pap_extend_l(closure, typed_args, num_args, args_layout)`.
- `eco_apply_closure_eval` under-saturated branch (≈2425–2440): same.
- Lowering `PapExtendOpLowering` under-saturated path (`EcoToLLVMClosures.cpp:2925–2975`):
  - build the kinds vector from the operand types (`slotKindOf`, §S.3);
  - get the layout global via `getOrCreateEvalLayout(rewriter, loc, runtime, kinds, 0)`;
  - root with `emitChunkedRootPush`;
  - call the new `getOrCreatePapExtendL`.
- `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:559–563`: add

  ```cpp
  LLVM::LLVMFuncOp EcoRuntime::getOrCreatePapExtendL(OpBuilder& b) const {
      // eco_pap_extend_l(closure: hptr, args: ptr, num_args: i32, layout: ptr) -> hptr
      return getOrCreateFunc(b, "eco_pap_extend_l",
                             LLVM::LLVMFunctionType::get(HPTR_TY, {HPTR_TY, PTR_TY, I32_TY, PTR_TY}));
  }
  ```

  with its declaration in `EcoToLLVMInternal.h` (beside `getOrCreatePapExtend`) and its line in
  the runtime declaration list (`EcoToLLVMRuntime.cpp` ≈1315, where the declare-all list lives).
- `runtime/src/codegen/RuntimeSymbols.cpp:354–356`: add `eco_pap_extend_l` (JIT map). Native
  builds link the static runtime, so nothing more is needed.
- `EcoBackend.cpp:234–241`: `callCensusIsTrampoline` stays without it (it never dispatches); add
  the name to the comment.
- `test/allocator/GenericApplyBoxingTest.cpp:115`, `158`, `204`, `213`: switch to
  `eco_pap_extend_l` with a `makeEvalParamLayout<1>`.

**Tests:**
- `GenericApplyBoxingTest`, `EcoApplyClosureTypedTest`;
- codegen fixtures `papextend_no_realloc.mlir`, `fast_dispatch_pap_prefix.mlir` (update their
  CHECK for the callee name);
- full E2E with the same failure list as P1.

**Rollback:** revert. The shim makes the halves independent.

## Step 2.6: closure layout v2 (atomic)

### 2.6.1 Runtime structs and constants

`runtime/src/allocator/Heap.hpp:615–629`:

```cpp
typedef struct {
    Header header;           // header.size = allocated value slots + K (physical-size rule)
    u64 n_values   : 11;     // applied arity, 0..2047
    u64 max_values : 11;     // stage arity, 0..2047
    u64 result_kind: 2;      // ParamKind of `evaluator`'s C-ABI return
    u64 unboxed    : 40;     // inline 2-bit kinds for params 0..19
    const EvaluatorDesc* evaluator;
    Unboxable values[];      // [0 .. header.size - K) values, then K ext kind words
} Closure;
static_assert(sizeof(Closure) == 24, "Closure base is 24 bytes");
```

- §S.1 constants: `CLOSURE_HDR_SLOTS = 20`, `CLOSURE_MAX_ARITY = 2047`.
- `snapshotClosureKinds`: `ks.hdr = cl->unboxed; ks.max = cl->max_values;`
  `ks.k = extWords(ks.max, 20);` then copy `closureExtWords(cl)[0..k)` into `ks.ext`.
- `closureKindAt(ks, s)`: `s < 20 ? kindInWord(ks.hdr, s) : (j = (s-20)/32) < ks.k ? kindInWord(ks.ext[j], (s-20)%32) : 0`.
- Validate-only helper `closureWellFormed(cl)`: `hdr->size >= n_values + K`,
  `n_values <= max_values <= 2047`, and no ext bits past slot `max_values - 1`.

`EcoToLLVMInternal.h:375–376`: fix the comment, and add the shared packing constants:

```cpp
// packed = n_values:11 | max_values:11 | result_kind:2 | unboxed:40
constexpr unsigned ClosureMaxShift = 11, ClosureRkShift = 22, ClosureKindsShift = 24;
constexpr uint64_t ClosureCountMask = 0x7FF;            // 11 bits
constexpr unsigned ClosureHdrSlots = 20;
inline uint64_t packClosureWord(uint32_t n, uint32_t max, uint8_t rk, uint64_t hdrBits) {
    assert(n <= 2047 && max <= 2047 && (hdrBits >> 40) == 0);
    return uint64_t(n) | (uint64_t(max) << ClosureMaxShift)
         | (uint64_t(rk & 3) << ClosureRkShift) | (hdrBits << ClosureKindsShift);
}
```

`test/allocator/HPointerLayoutTest.cpp:212–223` (packed-word golden):
`w == (3 | 7<<11 | 2<<22 | 0x155ull<<24)`.

### 2.6.2 Runtime allocation entries (physical-size rule; K ext words always written)

| Entry (`RuntimeExports.cpp` unless noted) | Change |
|---|---|
| `eco_alloc_closure_k` 1275–1294 (`num_captures` = max_values) | `K = extWords(n, 20)`; size `24 + 8*(n+K)`. The size is set by `eco_alloc_with_roots` → `initHeaderForTag` (byte-derived = n+K, correct). Zero `values[n..n+K)`. Release abort `n > 2047` |
| `eco_alloc_closure` 1296, `eco_alloc_closure_fn` 1306 | via `_k` |
| `eco_intern_closure0` 1330–1352 | `assert(arity <= 20)` (the codegen never interns wider, 2.6.4); size unchanged |
| `eco_alloc_closure_fast` / `_slow` 1618–1652 | same as `_k`; `hdr->size = n + K` |
| `eco_alloc_closure_group_slow` 1734–1802 | replaced by `eco_alloc_closure_group_l` (below) |
| `eco_pap_extend_l` | 2.5 body with `K = extWords(max, 20)` |
| `HeapHelpers.hpp:2005–2021` `allocClosureK` | size `24 + 8*(max+K)`; `header.size = max + K`; zero ext; the release abort |
| `HeapHelpers.hpp:2039–2085` `closureCapture` | the abort threshold changes from `idx < 25` to `idx < 20` (typed kind at ≥ 20 aborts; release builds too); the validate check bound becomes 20 |

**New group entry** (`RuntimeExports.cpp`; declared in `RuntimeExports.h`):

```cpp
extern "C" void eco_alloc_closure_group_l(
    uint64_t numSiblings,
    const void* const* evaluators,     // EvaluatorDesc* per sibling
    const uint32_t* arities,           // max_values per sibling (<= 2047)
    const uint32_t* numCaptured,       // n_values per sibling
    const uint64_t* hdrKinds,          // per sibling: inline 40-bit kind field (params 0..19)
    const uint64_t* extKinds,          // concatenated ext words of all siblings
    const uint32_t* extOffsets,        // numSiblings+1 prefix offsets into extKinds;
                                       //   extOffsets[i+1]-extOffsets[i] == extWords(arities[i], 20)
    const uint8_t*  resultKinds,
    const uint32_t* captureOffsets,    // numSiblings+1
    const uint64_t* captures,
    const uint64_t* crossEdges,        // (producer, consumer, slot) triples
    uint64_t numCrossEdges,
    uint64_t* outClosures);
```

The body is the old one (1745–1802), with these changes:
- `perSibling = 24 + 8*(arities[i] + K_i)`;
- `hdr->size = arities[i] + K_i`;
- `closure->unboxed = hdrKinds[i]`;
- copy the K_i ext words into `values[arities[i] .. arities[i]+K_i)`;
- `assert(extOffsets[i+1]-extOffsets[i] == K_i)`.

Codegen declaration `EcoToLLVMRuntime.cpp:366–379`: `getOrCreateAllocClosureGroupL` with
`{I64, PTR×7, PTR, PTR, I64, PTR}`, matching the argument order above (13 params). JIT map
`RuntimeSymbols.cpp:195–197`: add `eco_alloc_closure_group_l`.

### 2.6.3 Runtime readers

**Carried over from Phase 1:**
- Every reader that phase-1 step 1c.4 moved to the Phase-1 `ClosureKinds` snapshot (rows 2–8) or
  to `closureSlotKind` reads through the Phase-2 bodies from now on: `CLOSURE_HDR_SLOTS = 20`
  inline kinds plus the copied ext words. They need no call-site change, only the helper bodies in
  §2.6.1.
- `pointerMaskFromKindBitmap` (which Phase 1 made treat slots ≥ 32 as boxed) and the caller-kind
  read in 1c.4 row 3 are replaced by `pushRootsByKinds` / `closureKindAt` at the sites in step 2.2.
  After this commit `pointerMaskFromKindBitmap` has no closure callers.

**ClosureKinds snapshot or accessor on a frozen object (walkers do not allocate, so a direct read
is fine):**
- `HeapChildWalk.hpp:87–95`;
- `NurseryChildWalk.hpp:54–58`;
- `NurseryParallel.cpp:516–519` (**TLA region `NP.scanEntryP`, M3**);
- `NurserySpace.cpp:906–912`, `1046–1052` (validate) and `1946–1965` (minor scan; the existing
  `validateBitmapSlotKind` is a disabled no-op and is not used, the closure check is
  `closureWellFormed`);
- `OldGenSpace.cpp:3602–3618` (scanChildren) and `7408–7416` (compaction).

Pattern:

```cpp
const Closure* cl = …; ClosureKinds ks; snapshotClosureKinds(cl, ks);
for (u32 i = 0; i < cl->n_values; i++) if (closureKindAt(ks, i) == 0) visit(cl->values[i].p);
```

**`n_values` / `max_values` widths and 63-limits:**
- `RuntimeExports.cpp:2251` `max_values > 63` → `> CLOSURE_MAX_ARITY`;
- `:2361` and `:2694` asserts → `<= CLOSURE_MAX_ARITY`;
- `:2889–2892` and `:2969–2971`: `alloca(max_values * 8)` above 16 is up to 16 KiB; use
  `std::unique_ptr<void*[]>` when `max_values > 256`.

**Kind readers → snapshot:**
- `RuntimeExports.cpp:2524/2605/2650` (inside `eco_pap_extend_l`, done);
- `:2696–2707`, `:2777–2786` (`spliceArgsForSaturatedCall` and its validate tripwire);
- `:2899`, `:2978` (done in 2.2);
- `bitmap_out` parameters (`:2175`, `:2686`, `:2922–2926`, `:2987–2993`): replace
  `uint64_t& bitmap_out` with `ClosureKinds& kinds_out`.

**Kernels:**
- `elm-kernel-cpp/src/core/ListExports.cpp:205–228`: `ClosureMeta` holds a `ClosureKinds ks`;
  `closureNewArgKind` = `closureKindAt(ks, n_values + i)`;
- `TypeInfo.hpp:39` comment.

**Tests** (`test/allocator`):
- `HeapGenerators.cpp:330`, `:554`: `buildUnboxedBitmap(…, 40)` (≤ 20 values today, so K = 0);
- `HeapSnapshot.hpp` closure loops use the accessor (B17, P1);
- `AllocatorCommonTest.cpp:476–540` sets `hdr->size = max_values + extWords(max_values, 20)`;
- `GCPressureTest.cpp`, `RuntimeExportsTest.cpp`, `HeapHelpersTest.cpp` and `OldGenSpaceTest.cpp`
  closure constructions: grep `max_values` (32 hits in AllocatorCommonTest) and audit each for
  values > 20 typed slots.

### 2.6.4 Lowering

**`PapCreateOpLowering` (`EcoToLLVMClosures.cpp:700–940`):**
- **Kinds:** `SmallVector<uint8_t> kinds = isTyped ? deriveAllParamKinds(runtime, funcSymbol, arity) : capture kinds from operand types (slotKindOf) padded with 0 to arity;`
  then `PackedKinds pk = packKinds(kinds, 20);`. This replaces 777–780 and 861–864.
- **Interning** (776): `if (numCaptured == 0 && !op->hasAttr("self_capture_indices") && arity <= 20)`;
  packed0 = `packClosureWord(0, arity, rk, pk.hdrBits)` (replaces 781–784).
- **Allocation:** inline (801–826) and call path (827–834):
  - `K = pk.ext.size()`;
  - `cloByteSize = 24 + 8*(arity + K)`;
  - `composeHeader(TagClosure, 0, arity + K)`;
  - call path: `eco_alloc_closure_k(func, arity, rk)` (the runtime computes K and zeroes).
- **Packed store:** 881–894 becomes `packClosureWord(numCaptured, arity, rk, pk.hdrBits)`.
- **Ext stores:** after the capture stores (898–930), store each `pk.ext[j]` (zeros included) as
  an i64 constant at `ClosureValuesOffset + 8*(arity + j)`, in the same no-safepoint window
  (HEAP_031).
- **Self-capture backpatch** (927): slot indices < arity, unchanged.

**`PapCreateGroupOpLowering` (945–1265):**
- per sibling, `deriveAllParamKinds` (replacing 1045) → `packKinds` → `hdrKinds[i]`, plus the
  `extKinds` and `extOffsets` allocas;
- call `eco_alloc_closure_group_l`;
- the flat-capture root mask comes from operand types (not `unboxed_bitmaps`; 1134–1150 already
  chunked in P1).

**make.closure (`EcoToLLVMValueAgg.cpp:767–890`):**
- kinds = `deriveAllParamKinds` when the target is typed, else capture kinds from the env types
  (`slotKindOf`), padded to arity;
- `packKinds(…, 20)`;
- size `24 + 8*(arity + K)`;
- `composeHeader(TagClosure, 0, arity+K)`;
- packed word `packClosureWord(numCaptured, arity, rk, hdrBits)` with
  `rk = op->getAttrOfType<IntegerAttr>("_result_kind")` (default 0) (replaces 858–865);
- ext stores;
- `kindBitmapFor` (77–87) is no longer used here.

**Third derive site:** `preMaterialize…` lambda `materialize` (3289–3295):
`kinds = isTyped ? deriveAllParamKinds(...) : {}`. The descriptor's `kinds` u64 takes the first
32 entries; params ≥ 32 are omitted (advisory, §2.2).

**`deriveAllParamKinds`** (replaces `deriveAllParamKindsBitmap` 1453–1487): the same symbol
lookup chain, returning `SmallVector<uint8_t>` of length `min(arity, params)` padded with 0 to
arity. Add `uint64_t firstKindsWord(ArrayRef<uint8_t>)` for `EvaluatorDesc.kinds` and the sat
filter (`stageArity <= 16` only, 2.4).

**Sat-entry capture loads** (1712–1730) are by static type; no change. The `(void)k` unpacking at
1719 is valid only because `stageArity <= 16 < 20`; add `assert(stageArity <= 16)`.

### 2.6.5 Sat guard in `EcoBackend.cpp:1813–1830` (IR before/after)

```cpp
// BEFORE
Value *n  = b.CreateAnd(W, b.getInt64(63), "eco.clo.n");
Value *mx = b.CreateAnd(b.CreateLShr(W, b.getInt64(6)), b.getInt64(63), "eco.clo.max");
Value *rk = b.CreateAnd(b.CreateLShr(W, b.getInt64(12)), b.getInt64(3), "eco.clo.rk");
Value *ub = b.CreateLShr(W, b.getInt64(14), "eco.clo.ub");
Value *c1b = b.CreateICmpULE(mx, b.getInt64(25));
Value *shift = b.CreateShl(n, b.getInt64(1));
// AFTER
Value *n  = b.CreateAnd(W, b.getInt64(0x7FF), "eco.clo.n");
Value *mx = b.CreateAnd(b.CreateLShr(W, b.getInt64(11)), b.getInt64(0x7FF), "eco.clo.max");
Value *rk = b.CreateAnd(b.CreateLShr(W, b.getInt64(22)), b.getInt64(3), "eco.clo.rk");
Value *ub = b.CreateLShr(W, b.getInt64(24), "eco.clo.ub");
Value *c1b = b.CreateICmpULE(mx, b.getInt64(Elm::SAT_MAX_ARITY));   // 20 (2.6.8)
// B20: a shift >= 64 gives poison, and `and(false, poison)` is poison; branching on it is
// UB. Clamp the shift operand so it is in range even when the guard fails:
Value *nSafe = b.CreateSelect(c1b, n, b.getInt64(0));
Value *shift = b.CreateShl(nSafe, b.getInt64(1));
```

The rest (`km`, `c3`, `ok`) is unchanged. This fixes **B20**, which exists today: with `mx` up to
63 the shift reaches 126 whenever `c1b` is false.

### 2.6.6 TLA canary

The commit edits `NP.scanEntryP` (`NurseryParallel.cpp:456–601`; closure arm 516–519), so the
canary fires for **M3**. The census pins for `RuntimeExports.cpp` (M1) and `AllocatorCommon.hpp`
(M3, M4) fire only if a concurrency line changed; none should.

**Procedure** (`test/tla/README.md`):
1. Read M3 `MAPPING.md` for scanEntryP.
2. Write an AUDIT.md entry in M3, plus voluntary entries in M1 and M5 for the unpinned walkers.
3. Run `test/scripts/check-tla-manifest.sh . --update`.

**AUDIT template:**

```
## 2026-MM-DD — wide-objects Phase 2: closure packed word n:11|max:11|rk:2|kinds:40 + tail kind words (GC_MODEL_001)
Changed: NP.scanEntryP Tag_Closure arm reads kinds via ClosureKinds (inline 20 + K=extWords(max_values,20)
ext words at the object's tail); n_values/max_values widened to 11 bits. Object size remains a function of
the header word alone (Closure header.size = value slots + K), so copyClaimed/copyClaimedR/CR-019 sweep are
untouched. Kinds and n_values are written only at allocation (HEAP_077, HEAP_SNAPSHOT_001).
Verdict: no model change needed (a closure's children are read from a frozen object; the packed word is one
existing location; no atomic, lock or memory order added). New hash prefix: <12 hex>.
```

Run `tla-trace` M3 once after this commit (§S.7 plus
`test/tla/run_traces.py --model M3 2>&1 | tee /tmp/test_output_trace.txt`).

### 2.6.7 Tests for 2.6

**Unit** (new file `test/allocator/WideClosureTest.cpp`, registered in `test/main.cpp` and
`test/CMakeLists.txt` like `GenericApplyBoxingTest`). For `max_values` ∈ {20, 21, 52, 53, 300,
1100, 2047}:
- `allocClosureK` + fill;
- `eco_pap_extend_l` chains in steps of 1, 7, 20 and 63 with kinds cycling Int/Float/Char/boxed;
- a forced minor and a major GC between extends;
- saturate via `eco_closure_call_saturated` into an evaluator that checks every slot;
- `closureWellFormed` in the validate tree;
- arity 1100 run with `large_ptr_nursery_divisor = 0` through `initAllocator` (forced YLOS);
- `EvalParamLayout` / `EvaluatorDesc` / `Closure` `static_assert`s;
- death test: `closureCapture` of a typed kind at idx 20.

**Codegen fixtures:**
- `test/codegen/papcreate_arity2047.mlir` (generated: a `func.func` of 2047 i64 params summing
  `p_i * (i+1)`; papCreate with 0 captures; papExtend by 1000, then by 1047 and saturate). Run
  `-emit=jit` and CHECK the printed sum.
- `papcreate_kinds_20_21.mlir`: params with Float at 19 and 20, Char at 51 and 52; JIT, CHECK the
  values.
- **B13 fixture update** (`test/codegen/make_closure_packed_word.mlir`, written in Phase 0, green
  since P1): the packed-word CHECKs change to the new word.
  - `n=2, max=3, rk=0, slot0=Int`: `2 | 3<<11 | 1<<24 = 16783362`, so
    `// CHECK: llvm.mlir.constant(16578 : i64)` becomes `// CHECK: llvm.mlir.constant(16783362 : i64)`.
  - The `rk=1` case: `16783362 | 1<<22 = 20977666` replaces `20674`.
  - Update the comment lines that derive the word (`… | 1<<14`) to `… | 1<<24`.

**Commands:**

```bash
cmake --build build && cmake --build build --target test
ulimit -c 0; build/test/test --filter "WideClosure|papcreate_|Generic|apply" 2>&1 | tee /tmp/test_output.txt
cmake --build /work/build-validate --target test && /work/build-validate/test/test --filter "WideClosure" 2>&1 | tee /tmp/test_output_validate.txt
# cache wipe (overview §6.3), then:
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

**Expected:** the unit and fixtures pass. E2E: E4 (`WideClosurePap27bTest`), E8
(`WideRecordDecoder26Test`, `WideRecordDecoder30Test`), `WideClosureArity63Test` and
`eco-kernel/WideClosureGcTest` **turn green** here: their closure arity is ≤ 63 and they don't need
the cap lift. E5–E7 and `WideClosureArity300Test` / `WideClosureArity2047Test` are still red on the
old caps until 2.7.

### 2.6.8 Empty `sat[]` for wide evaluators (part of the atomic 2.6 commit)

**Why it is safe.** The call-site sat fast path loads `desc->sat[N]` only in the `eco.sat.maybe`
block (`EcoBackend.cpp:1840–1849`). That block is reached only through `br ok, maybe, slow`
(`:1837`), and `ok` includes `c1b = (mx <= SAT_MAX_ARITY)`, where `mx` comes from the closure's own
packed word. Every compiled closure has `max_values == desc->stage_arity`:
- papCreate takes the descriptor of its target at `arity`;
- `eco_pap_extend(_l)` copies both the evaluator and `max_values`;
- kernel closures pass `max_values` as the descriptor's `stage_arity` (`HeapHelpers.hpp:2019`).

So for `stage_arity > SAT_MAX_ARITY` no code reads `sat[]`.

**Reader audit (grep `EvaluatorDescSatOffset`, `->sat[`, `.sat[`, `desc->sat`):**

| Site | What it does | Status |
|---|---|---|
| `EcoBackend.cpp:1840–1849` | the only load | guarded as above |
| `EcoToLLVMClosures.cpp:1965` | passes the constant byte offset `EvaluatorDescSatOffset + 8*n` to the `__eco_sat_begin` marker | not a read; the marker is expanded into the guarded load above |
| `Heap.hpp:638` | static_assert text | — |
| `RuntimeExports.cpp` (`ecoDescForKernelEvaluator`, `eco_intern_closure0`), kernels, debug printers | never read `sat` | interning keys on the descriptor pointer only |

**Changes:**
1. **The constant (§S.1).** In `Heap.hpp`:
   ```cpp
   // Sat fast path serves only closures whose kinds are all inline; the guard (EcoBackend.cpp)
   // and the descriptor emitters must use this one constant.
   constexpr u32 SAT_MAX_ARITY = CLOSURE_HDR_SLOTS;          // 20 after this commit
   static_assert(SAT_MAX_ARITY <= CLOSURE_HDR_SLOTS, "c3 reads kinds from the header word only");
   ```
   `EcoBackend.cpp` already includes `../allocator/Heap.hpp` (`:66`).
2. **The guard (2.6.5).** `Value *c1b = b.CreateICmpULE(mx, b.getInt64(Elm::SAT_MAX_ARITY));` replaces
   the literal. The comment at `:1840–1841` becomes: "`%c1` proved N <= stage_arity and `%c1b`
   proved stage_arity <= SAT_MAX_ARITY, so sat[] has stage_arity + 1 slots here and the load is in
   bounds".
3. **Emitter `getOrCreateEvalDesc`** (`EcoToLLVMClosures.cpp:1792–1794`):
   ```cpp
   // sat[] has stageArity + 1 slots when the sat fast path can serve this evaluator
   // (stageArity <= SAT_MAX_ARITY); otherwise it is EMPTY: the guard (EcoBackend.cpp)
   // makes it unreadable, and a 2047-arity descriptor stays 24 bytes.
   const unsigned satCount = stageArity <= Elm::SAT_MAX_ARITY
                                 ? static_cast<unsigned>(stageArity) + 1 : 0;
   ```
   - With `satCount == 0`, skip the sat-entry generation block (`if (satFastEnabled() && …)`,
     `:1797ff`).
   - `satArrTy = LLVM::LLVMArrayType::get(ptrTy, 0)` is a legal zero-length array.
   - The initializer loop (`:1868–1874`) runs zero times.
   - Separately, the `stageArity > 16` reject that 2.4 moved first stays.
4. **Emitter `getOrCreateEvalDescForFunc`** (`:2012`): the same `satCount` expression.
5. **Runtime `ecoDescForKernelEvaluator`** (`RuntimeExports.cpp:1256–1257`):
   `bytes = sizeof(EvaluatorDesc) + (stage_arity <= SAT_MAX_ARITY ? (stage_arity + 1) * sizeof(void*) : 0);`.
6. **Comments.**
   - The `Heap.hpp` `EvaluatorDesc` comment ("`sat` always has `stage_arity + 1` slots, so a load
     of `sat[N]` is in bounds for every N the `rem == N` guard can admit") becomes "`sat` has
     `stage_arity + 1` slots when `stage_arity <= SAT_MAX_ARITY`, else it is empty. The
     `max_values <= SAT_MAX_ARITY` guard makes it unreadable, so every load the guards admit is in
     bounds."
   - The `void* sat[]` member comment becomes `// +24 sat[0..stage_arity] if stage_arity <= SAT_MAX_ARITY, else empty`.
   - `EcoToLLVMInternal.h:381–390` gets the same note next to `EvaluatorDescSatOffset` (unchanged
     at 24).
7. **Validate assert.** Under `ECO_HEAP_VALIDATE`, `eco_pap_extend_l` and `allocClosureK` check
   `cl->max_values == cl->evaluator->stage_arity`. This is the premise of the safety argument. The
   field is readable now that `stage_arity` is a real u16 (2.4).

**Invariant:** HEAP_078 (step 2.9) carries the `sat[]` wording.

**Tests:**
- **Codegen fixture** `test/codegen/eval_desc_sat_sizes.mlir`, generated by a short script (as
  phase-0's fixture generators; arity-2047 bodies are generated):
  - three zero-capture `eco.papCreate`s of arities 20, 21 and 2047 targeting typed functions with
    Int params;
  - RUN `%ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s`;
  - CHECK the three descriptor globals. They are named `__eco_evaldesc_<wrapper>` (`evalDescName`,
    `EcoToLLVMClosures.cpp:1603`), so name the targets `@ar20`, `@ar21` and `@ar2047` and match
    `__eco_evaldesc_{{.*}}ar20{{[^0-9]}}` followed by
    `!llvm.struct<(ptr, i64, i8, i8, i16, i32, array<21 x ptr>)>`;
  - the same for `ar21` and `ar2047`, with `array<0 x ptr>`.
- **Run fixture** `test/codegen/eval_desc_sat_wide_jit.mlir`: an arity-21 closure applied with
  1 and then 20 newargs, and an arity-2047 closure applied through the generic path; `-emit=jit`
  prints the sums. Expected: the correct values (the sat path is not taken, and nothing reads past
  the 24-byte descriptor).
- **Unit** (`test/allocator/WideClosureTest.cpp`, the P2 closure unit file):
  `"kernel descriptor above SAT_MAX_ARITY has no sat slots"` calls
  `ecoDescForKernelEvaluator(fn, 21, 0)` and `(fn, 20, 0)`, then applies kernel closures of both
  arities via `eco_apply_closure`. Expected: correct results; under ASan builds, no read beyond the
  allocation.
- The E2E pins `WideClosureArity63Test` / `WideClosureArity2047Test` cover the end-to-end path.

**Commands:** the 2.6 commit's commands (§S.7):
```bash
cmake --build build --target test && ulimit -c 0 && build/test/test --filter "eval_desc_sat" 2>&1 | tee /tmp/test_output.txt
```
then the 2.6 gate.

**Ordering:** this must be in the **same commit** as the 2.6.5 guard change (`mx <= 20`). With the
old `mx <= 25` guard, an empty `sat[]` for arities 21–25 would be read out of bounds.

**Rollback:** with the 2.6 commit. Alone, revert steps 3–5 to `stage_arity + 1`, which is always
safe.

## Step 2.7: caps

**`EcoOps.cpp`:**
- `PapCreateOp::verify` 530–556: `numCaptured > 2046` / `arity > 2047`; delete the 50-bit and
  "25-slot" checks and the per-slot switch (570–600), now covered by `verifyClosureKinds`.
- `PapExtendOp::verify` 629–660: delete the 50-bit and 25 checks; `realNewargsCount > 2047`.
- `PapCreateGroupOp::verify` 796–811: caps 2046/2047; delete the 25 and 50-bit checks. The
  cross-edge "slot must be boxed" check (775–779) reads `slot_kinds[consumer][slot] == 0` when
  `slot_kinds` is present, else the legacy word for slot < 32.
- `MakeClosureOp::verify` 1449–1456: `numCaptures > 2046`, `arity > 2047`.

Messages:
- `"num_captured (N) exceeds closure capture limit (2046)"`;
- `"arity (N) exceeds closure arity limit (2047)"`;
- `"newargs count (N) exceeds closure arity limit (2047)"`.

**`EcoPAPSimplify.cpp`:**
- PAPSimplify pattern P2 (chain fusion, 342–356, 376–388): compute `SmallVector<int8_t> fusedKinds`, set `slot_kinds`, and
  pass `newargs_unboxed_bitmap = 0` (the builder argument at 384) with the attribute then
  **removed** (`fusedOp->removeAttr("newargs_unboxed_bitmap")`). Refuse fusion when
  `fused newargs > 2047`.
- PAPSimplify pattern P4 (create+extend fusion, 503–537): cap `fusedCaptured > 2046`; set `slot_kinds` on the clone and remove its
  `unboxed_bitmap` (536).

**Verifier after PAPSimplify in validate/test builds:** `eco-boot.cpp:382` and
`EcoNativeDriver.cpp:103` disable after-pass verification in release. Add
`if (ECO_HEAP_VALIDATE || getenv("ECO_VERIFY_AFTER_PAPSIMPLIFY")) pm.enableVerifier(true)`
scoped to the pass (or run `mlir::verify(module)` right after it). Default **on** under
`ECO_HEAP_VALIDATE` and in `ecoc` (the tool the fixtures use).

**Tests:**
- E2E `WideClosureSat26Test` (E5), `WideClosureBoxed27Test` (E6), `WideClosureCapture27Test`
  (E7), `WideClosureArity300Test`, `WideClosureArity2047Test` turn green;
- codegen fixture `papextend_70_args_root_chunks.mlir` (from 2.2);
- negative fixture `invalid_pap_arity_2048.mlir` (CHECK `exceeds closure arity limit (2047)`);
- **B16 fixture update** (`test/codegen/pap_simplify_fusion_slot_cap.mlir`, written in Phase 0;
  in P1 fusion declines above 25, so it CHECKs two extends): rewrite its CHECKs for this commit, in
  which fusion is allowed up to 2047. They become
  `// CHECK: "eco.papExtend"` followed by `slot_kinds = array<i8: …>` with **30** entries, then
  `// CHECK-NOT: "eco.papExtend"` up to the function end (one fused 30-argument extend).

**Expected:** E2E failures = the "Phase 2 gate" list below. `WideClosureSat26Test`,
`WideClosureBoxed27Test`, `WideClosureCapture27Test`, `WideClosureArity300Test` and
`WideClosureArity2047Test` turn green here.

## Step 2.8: front end

**Elm helper** (`compiler/src/Compiler/Generate/MLIR/Ops.elm`, exported):

```elm
{-| One kind per slot (0 boxed, 1 Int, 2 Float, 3 Char), as a dense i8 array. -}
slotKindsAttr : List MlirType -> MlirAttr
slotKindsAttr tys =
    ArrayAttr (Just I8) (List.map (\t -> IntAttr Nothing (Types.mlirTypeToKind t)) tys)
```

**Emitters.** Each **before** builds an `IntAttr` with `Types.bitmapSetKind`; each **after** is
`( "slot_kinds", Ops.slotKindsAttr <the same type list> )`:

| Site | Before (attr) | Type list |
|---|---|---|
| `Expr.elm:859` (zero-capture papCreate) | `unboxed_bitmap = 0` | omit the attribute (no captures) |
| `Expr.elm:1081` (kernel papCreate) | none | none (0 captures) |
| `Expr.elm:1246–1251`, attr at `:1362` (closure papCreate) | `unboxed_bitmap` | the `boxedCaptureVarsWithTypes` types |
| `Expr.elm:1849`, attr at `:1909` | `newargs_unboxed_bitmap` | `argsForClosure` types |
| `Expr.elm:1989`/`:2049`, `:2154`/`:2200`, `:2357`/`:2383`, `:2499`/`:2613`, `:2741`/`:2782` | `newargs_unboxed_bitmap` | that site's newarg types |
| `Expr.elm:6010–6016`, attr at `:6056` (tail-func closure papCreate) | `unboxed_bitmap` | `captureMlirTypes` |
| `Expr.elm:6241–6247` → `GroupSibling.unboxedBitmap` (`:6269`) | per-sibling bitmap | `capVarsBoxed` types |
| `Ops.elm:1461–1470` `GroupSibling.unboxedBitmap : Int` → `slotKinds : List MlirType`; `:1512` and `:1582` emit `( "slot_kinds", ArrayAttr Nothing (List.map (Ops.slotKindsAttr << .slotKinds) siblings) )` instead of `unboxed_bitmaps` | | |
| `Lambdas.elm:225–230`, attr at `:270` | `unboxed_bitmap` | `captureMlirTypes` |
| `BytesFusion/Emit.elm:1676–1681`, attr at `:1687` | `newargs_unboxed_bitmap` | `actualArgTypes` |

papCreateGroup's `unboxed_bitmaps` is already optional (step 2.1), so the front end stops
emitting it here. The old closure attributes stay accepted by the verifier until Phase 3D, which
deletes them (§S.5).

**elm-test checker** (`compiler/tests/TestLogic/Generate/CodeGen/UnboxedBitmap.elm`; closure part
only, the construct part changes in Phase 3C):
- papCreate (`:311`) and papExtend (`:346`) now read `slot_kinds`: kind i = element i; an absent
  attribute with zero operands is OK;
- an absent attribute with typed operands **and** no legacy bitmap is a violation;
- the legacy bitmap path is kept for fixtures;
- `checkClosureKindLimits` (added in Phase 0 for B4) switches to its post-P2 form: "`slot_kinds`
  length ≤ 2047, no u64 closure bitmap present";
- update the docstring (`:3–40`, drop "52-bit"; this is the B10 comment fix for this file).

New test cases in `UnboxedBitmapTest.elm`:
- "papExtend with 26 Int newargs carries 26 slot_kinds" (a `CloP26I`-shaped program built with the
  test IR builders as in `CallAbiConsistencyTest` `wideCtorCallTest`);
- "papCreate with 27 captures".

Expected: pass.

**Tests and commands (checker part):** covered by 2.8.6 below. Afterwards, the cache wipe
(overview §6.3), `full`, and the step 2.0 bytecode-vs-text run of `WideClosureSat26Test`.

**Limit diagnostics (D5, overview §S.9).** Do sub-steps 2.8.1–2.8.6 in order. Arity is introduced
and limited in this phase, so the shared machinery is built here; Phase 3D (step 3D.2) only adds the
two field variants.

### 2.8.1 Constants module

New leaf module `compiler/src/Compiler/Data/HeapLimits.elm`. It has no imports from `Compiler.*`,
so both Canonicalize and Generate can import it.

```elm
module Compiler.Data.HeapLimits exposing (maxStageArity)

{-| Eco heap/closure limits that users can hit. Mirrors runtime/src/allocator/Heap.hpp
(CLOSURE_MAX_ARITY); keep both in step. Phase 3D adds maxCtorFields / maxRecordFields. -}

maxStageArity : Int
maxStageArity =
    2047
```

`Generate/MLIR/Types.elm` imports `maxStageArity` instead of defining its own constant.

### 2.8.2 The error constructor and its report

In `compiler/src/Compiler/Reporting/Error/Canonicalize.elm`:
- add to `type Error` (`:157ff`, alphabetical, after `Shadowing`):
  `| TooLarge A.Region TooLargeWhat Int Int`;
- add the `TooLargeWhat` type with the three Phase-2 variants of overview §S.9 (`TooManyParams Name`,
  `TooManyLambdaParams`, `TooManyClosureSlots (Maybe Name)`);
- export both, with `@docs` lines.

The report goes in `toReport`, next to `TupleLargerThanThree` (`:1076`), in the same style:

```elm
TooLarge region what actual limit ->
    let
        ( title, subject, unit ) =
            case what of
                TooManyParams name ->
                    ( "TOO MANY PARAMETERS", "The function `" ++ name ++ "`", "parameters" )
                TooManyLambdaParams ->
                    ( "TOO MANY PARAMETERS", "This anonymous function", "parameters" )
                TooManyClosureSlots (Just name) ->
                    ( "TOO MANY CAPTURED VARIABLES", "The local function `" ++ name ++ "`", "parameters and captured variables" )
                TooManyClosureSlots Nothing ->
                    ( "TOO MANY CAPTURED VARIABLES", "This anonymous function", "parameters and captured variables" )
    in
    Report.report title region [] <|
        Code.toSnippet source region Nothing
            ( D.reflow (subject ++ " has " ++ String.fromInt actual ++ " " ++ unit
                ++ ", but Eco supports at most " ++ String.fromInt limit ++ " (HEAP_078).")
            , D.reflow "Pass the values in a record instead, or split the function into smaller ones."
            )
```

Phase 3D adds the two field cases to the same `case`.

### 2.8.3 Emission sites (canonicalization)

Each site throws with `ReportingResult.throw`, like `TupleLargerThanThree`
(`Canonicalize/Expression.elm:399`).

| Construct | Site | Check | Region |
|---|---|---|---|
| top-level function | `Compiler/Canonicalize/Module.elm` `toNodeOne` (`:303-311`; `srcArgs = valueData.args`), before `Pattern.verifyWithIds`, both the annotated and the unannotated branch | `List.length srcArgs > maxStageArity` → `TooLarge nameRegion (TooManyParams name) n maxStageArity` | the region of `valueData.name` (`A.At nameRegion name`) |
| let-defined function | `Compiler/Canonicalize/Expression.elm` `addDefNodesWithIds`, `Src.Define` (`:932`), both branches | same params check | the name's region (`aname`) |
| lambda | `Expression.elm` `canonicalizeNode`, `Src.Lambda` (`:212`) | `List.length srcArgs > maxStageArity` → `TooManyLambdaParams` | the lambda node `region` (the `canonicalizeNode` parameter) |
| lambda captures | same case, in the `ReportingResult.map` after `verifyBindingsWithIds` (`:226-234`), where `freeLocals` (`Dict Name Uses`, own args already removed) is in hand | `captured = freeLocals` keys whose `Dict.get k env.vars` is `Just (Env.Local _)`, using the **outer** `env`, not `newEnv`; if `nArgs + Dict.size captured > maxStageArity` → `TooManyClosureSlots Nothing`. Turn the `map` into an `andThen` so it can throw | lambda `region` |
| local-function captures | `addDefNodesWithIds` `Src.Define`, after the body's `freeLocals` | the same count; the function's own name counts as a capture if it is free (self-recursion), which is conservative → `TooManyClosureSlots (Just name)` | the name's region |

Top-level functions capture nothing, so they need only the params check. Record-alias and ctor
function values are covered by the field limits in Phase 3D, because their arity is the field count.

### 2.8.4 Compiler-generated arity: decline, never report

- `compiler/src/Compiler/GlobalOpt/PreMono/EtaExpand.elm`: in `expandDefinition` (422) and
  `expandOneLambda` (918), compute the post-expansion parameter count (existing arity + deficit,
  `hasDeficit` 622) and **do not expand** when it exceeds `maxStageArity`. Count it in `Metrics`
  (150) as `declinedArityCap`.
- `GlobalOpt/MonoInlineSimplify.elm:697` `raiseStagedSpecs` (default off): skip specs whose raised
  arity exceeds `maxStageArity`.
- **Every GlobalOpt site that rebuilds a closure's captures** with `Closure.computeClosureCaptures`
  must keep the original expression when `length params + length captures > maxStageArity`:
  - `MonoInlineSimplify.elm:3263` and `:4917` (decline the inline or beta step);
  - `MonoGlobalOptimize.elm:534`, `:578` and `:714` (do not create the wrapper or stage);
  - `Staging/Rewriter.elm:596` (do not split the stage).

  Count each decline in that pass's existing stats record.

### 2.8.5 Post-mono backstop (located)

New module `compiler/src/Compiler/Monomorphize/ValidateLimits.elm`, exposing
`check : Mono.MonoGraph -> List String`:
- it walks every `MonoClosure` in the graph (use `MonoTraverse`, as `ValidateLayout` does);
- for each closure with `length closureInfo.params + length closureInfo.captures > maxStageArity`,
  it produces
  `"<Home>.<function>: line <l>, column <c>: a closure has <n> parameters and captured variables after specialization; Eco supports at most 2047 (HEAP_078). Capture a record instead of many polymorphic local functions."`
  - The region comes from `Closure.extractRegion` (`Monomorphize/Closure.elm:107`) on the closure
    body.
  - The home and function come from the enclosing spec.

It is called unconditionally in `Builder/Generate.elm` (the monomorphization block, `:1020-1041`,
next to the `ValidateLayout` hook but **not** behind `ecoConfig.mono.validate`), and once more
after `runInlineSimplifyPhase`. A non-empty list → `Task.throw (Exit.GenerateMonomorphizationError
("STAGE ARITY LIMIT\n" ++ String.join "\n" violations))`.

This path is reachable only when specialization multiplies captured polymorphic local functions
beyond what the canonical count saw. After 2.8.4, the post-GlobalOpt call firing means a pass
failed to decline, which is a compiler bug; the message is the same.

The MLIR generator keeps an **internal invariant assert** where every papCreate `arity` is
computed (`Expr.elm:1237–1239`, the `:859` and `:1081` sites, `Expr.elm:6063`, `Lambdas.elm:283`,
and the papCreateGroup siblings in `Ops.ecoPapCreateGroup` 1490). It reads
`Utils.Crash.crash "internal compiler error: closure stage arity N > 2047 reached the generator (validated by ValidateLimits)"`
and is not a user-facing path.

### 2.8.6 Pins, commands and expected results

- **Canonicalization pins**, the Phase 0 pins in `compiler/tests/TestLogic/Canonicalize/LimitErrors.elm`
  and `LimitErrorsTest.elm` (Phase 0 step 0.6b item 5). They run `Canonicalize.Module.canonicalize`
  and match the error constructor, `actual` and `limit`. They turn green here:
  - "a top-level function with 2048 parameters is TooLarge TooManyParams" (2048, 2047; region = name);
  - "a let-defined function with 2048 parameters is TooLarge TooManyParams";
  - "a lambda with 2048 parameters is TooLarge TooManyLambdaParams";
  - "a lambda with 2000 parameters capturing 48 locals is TooLarge TooManyClosureSlots" (2048);
  - "a function with 2047 parameters is accepted" (boundary, no error);
  - "the TooLarge report names the function and the limit": render with `toReport`; the doc text
    contains `TOO MANY PARAMETERS`, the function name and `2047`.
- **CLI check (gate, by hand, once):** write `Arity2048.elm` in the scratchpad (a generated
  2048-parameter `big`), copy `build/test/elm/elm.json` beside it, and run:
  ```bash
  cd <scratch> && node /work/compiler/bin/index.js make Arity2048.elm --output=/dev/null 2>&1 | tee /tmp/test_output_arity.txt; echo "exit=${PIPESTATUS[0]}"
  ```
  Expected: exit status non-zero (B21 is fixed in Phase 1), and the output contains
  `TOO MANY PARAMETERS`, `big` and a line number pointing at the definition.
- **Command:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`. Expected:
  - only the 2 GOPT_003 failures;
  - `UnboxedBitmapTest` "closure kind attributes stay within the backend's slot limits" (Phase 0,
    B4) turns green;
  - the six `LimitErrorsTest` cases are green.

**Rollback:** 2.8.1–2.8.5 revert together (the error constructor, its sites and the backstop).
2.8.4's declines can stay; they are harmless.

## Step 2.9: cleanup and invariants

- **Delete:**
  - `eco_pap_extend` (the shim) and its JIT map entry;
  - `getOrCreatePapExtend`;
  - `eco_alloc_closure_group_slow` and its decl/map;
  - `deriveAllParamKindsBitmap`;
  - `kindBitmapFor` if unused (ValueAgg record/custom to_heap still uses it until Phase 3B; keep it
    if referenced);
  - `kMaxClosureArity`.
- **Invariants** (`design_docs/invariants.csv`; `;`-separated columns, keep each row's id, phase,
  category and status columns and replace or extend the description column; append "(Updated
  <date>: wide-object Phase 2)"). The Custom/Record rows change in Phase 3D (phase-3 file §3D).
  - **HEAP_019** (add a Closure clause; the Custom/Record wording stays until Phase 3D): "…; Closure
    keeps 2-bit kinds for params 0..19 in its packed word and for params 20.. in
    K = extWords(max_values, 20) extension kind words, 32 slots per word, which are the last K words
    of the object (Closure header.size counts value slots plus K; Closure header.unboxed is 0); GC,
    equality and debug code read closure kinds only through closureSlotKind / ClosureKinds."
  - **New HEAP_077 (ExtKindWords):** "Extension kind words (and, for Custom/Record, header.unboxed)
    are written only at allocation: on compiled paths before the object's first safepoint
    (HEAP_031/HEAP_034); on runtime and kernel paths before the object is published or first
    survives a GC (HEAP_SNAPSHOT_001, P1-censused). Every allocation writes all K words, zero words
    included (zeroNewObject does not clear them). closureCapture never writes an extension word:
    kernel closure slots ≥ 20 are boxed. Validate builds check K and zero padding."
  - **New HEAP_078 (ClosureHeaderWord):** "Closure packed word = n_values:11 | max_values:11 |
    result_kind:2 | kinds 0..19:40 at +8; stage arity ≤ 2047. EvaluatorDesc.stage_arity is u16 at
    +18; sat[] at +24 has stage_arity+1 slots when stage_arity ≤ SAT_MAX_ARITY (= 20) and is empty
    otherwise; the sat guard max_values ≤ SAT_MAX_ARITY makes it unreadable, and every compiled
    closure has max_values == evaluator->stage_arity. EvalParamLayout = {u16 num_params,
    u8 result_kind, u8 pad, u8 kinds[]}. Every reader of the raw packed word (the EcoBackend sat
    guard, codegen packers, the interning key) uses these widths."
  - **HEAP_033:** add "and arity ≤ 20 (wider closures need extension words and are not interned);
    the packed word per HEAP_078".
  - **HEAP_034 (b)** (Closure clause): add "for Tag_Closure, composeHeader(TagClosure, 0, S+K) with
    S value slots and K extension kind words, and the payload stores include the K words".
  - **CGEN_003 / CGEN_049:** "papCreate/papExtend/papCreateGroup/make.closure carry slot_kinds for
    their captures/newargs, checked against operand types; the closure's kinds for uncaptured
    params come from the target signature; stage arity ≤ 2047; slots 0..19 in the packed word,
    20.. in ≤ 64 extension words."
  - **REP_CLOSURE_001:** replace "at most 26 typed captures fit in the 52-bit bitmap" with "stage
    arity ≤ 2047; kinds per HEAP_019/HEAP_078".
  - **REP_CLOSURE_002:** "eco_pap_extend_l copies the closure's kind words and converts each new
    arg from its caller kind (EvalParamLayout) to its slot kind."
  - **FORBID_CLOSURE_002:** "…layout must be derived from SSA operand MLIR types (captures) and the
    target signature (uncaptured params)…"
- **Docs:** `design_docs/theory/pass_eco_to_llvm_theory.md` (closure packing),
  `heap_representation_theory.md` (closure layout).
- **Heap.hpp comment** at 617–628 (done in 2.6).

---

## Phase 2 gate

Run once each, tee'd (§S.7), after the cache wipe (overview §6.3):

| Gate | Command | Expected |
|---|---|---|
| elm-tests | `cmake --build build --target elm-tests` | only the 2 × GOPT_003 (`MonoCaseBranchResultTypeTest`) failures |
| E2E + unit + fixtures | `cmake --build build --target full` | failures exactly the list below |
| validate unit | `/work/build-validate/test/test --filter "WideClosure\|Closure\|apply"` | all pass |
| GC stress | the closure pins' `test/eco-kernel/src` variants (`Eco.GC.majorGC` + churn; CHECK the printed GC counts > 0) | pass |
| register-guards | `cmake --build build --target register-guards` | the Phase 0 baseline |
| AOT | `run-aot-e2e` (eco-stuff moved aside) | the Phase 0 baseline list |
| bootstrap | `bootstrap` + `eco-verify` | B==C |
| TLA | `tla-canary` (strict) after the 2.6 audit; `tla-trace` M3 | green / accepted |
| perf | `benchmarks/fe-opt-loop.md` §1 timed triple (overview §7) | counters differ only by the census's 21..25-arity closures (+8 B each) and >25-arity closures; record the census numbers in the P2 entry |
| E10 | one self-compile with an `eco-config.json` containing an `"inline"` object that sets every `InlineConfig` field to a non-default value (in particular `kernelCostHof`, field 25) | the dumped / debug-logged inline config equals the file's values (before Phase 2 field 25 reads pointer bits) |

**Expected E2E failures after Phase 2** (test name → reason substring; all are Custom/Record cap
messages, which Phase 3D lifts):
- `elm/WideCtorField24Test.elm` → `exceeds Custom's 24-slot limit`
- `elm/WideRecord33Test.elm`, `elm/WideRecord40Test.elm`, `elm/WideRecord600Test.elm`,
  `elm/WideRecord1100Test.elm` → `exceeds Record's 32-slot GC scan limit`
- `elm/WideCtorMixedTest.elm`, `elm/WideCtor1100Test.elm` → `exceeds Custom's 24-slot limit`
- `elm/WideRecordDecoder70Test.elm`, `elm/WideRecordDecoder300Test.elm` → `exceeds Record's 32-slot
  GC scan limit` (**not** the arity message)
- `eco-kernel/WideHeapGcTest.elm` → `field_count (40) exceeds Record's 32-slot GC scan limit`

**Green at this gate (newly):**
- E2E: `WideClosurePap27bTest`, `WideClosureSat26Test`, `WideClosureBoxed27Test`,
  `WideClosureCapture27Test`, `WideRecordDecoder26Test`, `WideRecordDecoder30Test`,
  `WideClosureArity63Test`, `WideClosureArity300Test`, `WideClosureArity2047Test`,
  `eco-kernel/WideClosureGcTest`;
- elm-test: `UnboxedBitmapTest` closure-limits case (B4), the six `LimitErrorsTest` cases (B18,
  D5), the step 2.0 encoder case;
- the 2.8.6 CLI check (`Arity2048.elm` gives `TOO MANY PARAMETERS`, located, non-zero exit);
- the unit and fixture pins of steps 2.1–2.7 (the B13 and B16 fixtures stay green with their
  updated CHECKs).

## Phase 2 gate result (recorded 2026-10-05)

**Gate (second run, after the integration fixes below; each command once, after the cache wipe):**
- elm-tests: 14,073 pass / 2 fail (the 2 GOPT_003 pins only). The step 2.0 encoder test, the B4
  closure-limits case and the six `LimitErrorsTest` cases are green.
- `full`: 2,105 run, 2,095 pass, 10 fail: exactly the expected list, each with its Custom/Record cap
  reason (`WideRecordDecoder70Test` / `…300Test` now fail on the RECORD cap, not the arity cap).
  Newly green: `WideClosurePap27bTest`, `…Sat26Test`, `…Boxed27Test`, `…Capture27Test`,
  `WideRecordDecoder26Test`, `…30Test`, `WideClosureArity63Test`, `…300Test`, `…2047Test`,
  `eco-kernel/WideClosureGcTest`, plus the 8 new codegen fixtures and the new unit tests.
- Validate tree (one run per substring): `WideClosure` 21/21, `Closure` 48/48, `apply` 9/9, `wide` 19/19.
- register-guards green; tla-canary strict green (the C++ agent's M1 audit for the new leaf mutex in
  `RuntimeExports.cpp`, prefix `7b4ec951a253`; voluntary M3/M5; M3 trace 15/15).
- AOT: 922/934; failures = the Phase 0 baseline (`FlagsRecordTest`, `PortEchoTest`) plus the 10 cap pins.
- Bootstrap: Stage 4b and 8c fixed points hold; `eco-verify` rc 0.
- Step 2.0 / 2.8.6 checks: `WideClosureSat26Test` passes through `ECO_TEXT_MLIR=1` (15 `slot_kinds
  = array<i8…>`) and the default bytecode path; the `Arity2048.elm` CLI compile exits 1 with a
  located `TOO MANY PARAMETERS` (line 6, `big`, 2047).
- **E10:** a native self-compile (`eco-optP2b`) with an `eco-config.json` `"inline"` object setting
  15 fields to non-default values (all of positions 20..26 included) persists the config hash
  `…|mpf=999|preFpi=3|postFpi=5|hthr=26|…|kcc=2/5/9/33|afwd=0|…`: `kernelCostHof` (field 25) = 33 and
  `aliasForward` (field 26) = false, exactly the file's values. `kernelCostClasses` stays `true`
  (the token is printed only then); earlier boolean switches stay default so experimental pass
  combinations cannot confound a decoding check.
- **Census** (`eco-optP2` output): one papCreate of arity 26..63 (the compiler's own `InlineConfig`,
  arity 27, now with extension words), 2 of arity 21..25, construct.record boxed primitive at >= 26: 5.

**Integration fixes found by the first gate run** (the C++ and front-end halves were built
separately):
1. `tests/Compiler/PackageCompilation.elm` matched `CanonicalizeError` exhaustively without
   `TooLarge`: branch added.
2. `PapCreateGroupOp::verify` required each sibling's `slot_kinds` to have length
   `capture_counts[i]`; step 2.1 (and the front end) say `num_captured[i]`. The verifier now
   requires length `num_captured[i]`, checks the first `capture_counts[i]` against the operand
   types and requires the sibling (cross-edge) slots to be boxed; `pap_slot_kinds_verify.mlir`
   updated. (This one bug also broke the bootstrap, the `MutualLetRec*` tests and
   `WideClosureGroupTest`.)
3. **Pre-existing ABI bug surfaced:** `Elm_Kernel_Debug_toString(HPtr, int64_t type_id)` was
   declared to MLIR with one parameter, so a `Debug.toString` closure value called it with one
   argument and `type_id` was a stale register; Phase 2 changed that register's contents and the
   printer chose a wrong type (`[]`). Split into `Elm_Kernel_Debug_toString(HPtr)` (untyped, the
   closure path) and `Elm_Kernel_Debug_toString_typed(HPtr, int64_t)` (the generator's saturated
   call, `Expr.elm`); `KernelExports.h`, `RuntimeSymbols.cpp` updated.

**Kernel licenses (LSS_022):** the 2.3/2.6 kernel edits re-hashed 94 licensed rows (7 files). The
diffs are `EvalParamLayout` encoding only (`makeEvalParamLayout` values with the same kinds; u16
`num_params`) plus `ListExports` kind snapshots; re-audited, `audited:` dates advanced with a
re-audit note, manifest `--update`d.

**Deviations recorded:**
- No `eco_pap_extend` shim phase: every caller moved to `eco_pap_extend_l` at once (2.5 + 2.9).
- Legacy u64 closure bitmaps: a zero word carries no claim (absent and zero are indistinguishable
  for property attributes), and a non-zero word is checked for slots 0..25 only (the front end
  packed at most 26).
- B16 fixture: PAPSimplify P6 folds the fused 30-newarg extend into the papCreate, so the fixture
  pins one papCreate with 31 captures plus a parameter-based function showing the fused extend.
- 2.8.4: the `MonoGlobalOptimize` wrapper sites and `Staging/Rewriter` do not decline (their
  wrappers are required for a correct calling convention); a violation there is reported as a
  located error by the post-GlobalOpt `ValidateLimits` run.
- `testHeaderWordComposition` (packed-word golden) was not registered in `test/main.cpp`; now it is.

**Perf** (`benchmarks/fe-opt-loop.md` procedure):
- First triple (`eco-optP2`): wall median 72.23 s vs Phase 1 67.62 s. Same-source cross-check
  (Phase 1 binary on the Phase 2 source: 68.4 s) put +3.8 s on the binary, +3.2 s of it in MLIR
  codegen. A DWARF profile showed it in `StringOps::collectSegs` under
  `Mlir.Bytecode.AttrType.attrIndex` → `Dict.get`: the encoder interns attributes under rope `String`
  keys joined from one piece per element, and every new `slot_kinds` array (and the attribute-dict
  key containing it) added long, shared-prefix keys that each comparison re-walks.
- **Fix:** `attrToKey` builds a dense array of single digits (every `slot_kinds`) as ONE flat
  segment (`"da#" … String.fromList`). Keys only deduplicate the encoder's attribute table:
  bytecode output byte-identical (4 sample programs; the candidate also reproduced the whole
  compiler's output, fixed point).
- Second triple (`eco-optP2b`, sha256 `8a057ab40d5d24e2…`): 69.78 / 69.65 / 69.49 s (median 69.65);
  MLIR codegen 12.3 s (= Phase 1); minor 1336, major 6, promoted 6393 MiB, objects ≈ 304,349,750,
  GC 2.82–2.84 s; deterministic + fixed point.
- **Remaining cost:** +1.2 s (+1.8 %) over the Phase 1 binary on the same source: parse/check +0.5 s
  (the canonicalization limit checks) and monomorphization +0.8 s (mostly the two `ValidateLimits`
  graph walks). Ships (correctness); follow-up: cheapen `ValidateLimits` (e.g. fold it into an
  existing walk) and the free-local count in canonicalization.

**New finding (pre-existing, NOT fixed, not part of this plan):** with
`eco-config.json` `{"inline": {"postMonoFixpointIterations": 5}}` (default 4) the self-compile
crashes in MLIR codegen with `lookupVar: unbound variable mono_inline_67908 [in
Terminal_Main_lambda_31224]`: a fifth post-mono inline round leaves a reference to an unbound
`mono_inline` variable. Identical with the Phase 0 and Phase 1 binaries.

## Checklist

- [x] 2.0 bytecode encoder element widths; elm-test; bytecode-vs-text run after 2.8
- [x] 2.1 `slot_kinds` optional on the three ops; papCreateGroup `unboxed_bitmaps` optional; `verifyClosureKinds`; 2 fixtures
- [x] 2.2 `emitChunkedRootPush`; all 9 push sites; `EcoToLLVMFunc` shadow frame chunked (B23)
- [x] 2.3 `EvalParamLayout` u16; `makeEvalParamLayout`; 11 hand-built layouts converted; `getAllBoxedLayout` clamp removed (B19); `evalLayoutName`
- [x] 2.4 `EvaluatorDesc.stage_arity` u16 @+18; two emitters + runtime writer; sat filter reject moved first
- [x] 2.5 `eco_pap_extend_l` + shim; 3 C++ callers + lowering + tests moved; JIT map
- [x] 2.6 Closure struct v2; constants; snapshot; every allocator (8) writes `S+K` and the ext words; every reader (walkers ×9 sites, splice, saturated, ListExports); `eco_alloc_closure_group_l`; papCreate/group/make.closure lowering; `deriveAllParamKinds`; interning ≤ 20; sat guard + B20; `SAT_MAX_ARITY` + empty `sat[]` for wide evaluators (2.6.8, 3 emitters, fixture ×2, unit); HPointerLayoutTest golden; `closureCapture` threshold 20; B13 fixture CHECKs → 16783362 / 20977666; TLA audit M3 (+M1/M5 voluntary)
- [x] 2.7 verifier caps 2047/2046; PAPSimplify `slot_kinds` + caps; B16 fixture rewritten (one 30-arg extend); verify-after-PAPSimplify in validate/ecoc
- [x] 2.8 `Ops.slotKindsAttr`; 13 emitter sites; `GroupSibling.slotKinds`; 2.8.1 `HeapLimits`; 2.8.2 `TooLarge` + report; 2.8.3 five canonicalization sites; 2.8.4 decline rules (EtaExpand, raiseStagedSpecs, six capture-rebuild sites); 2.8.5 `ValidateLimits` after mono and after GlobalOpt + generator internal assert; 2.8.6 `LimitErrorsTest` ×6 + CLI check; UnboxedBitmap checker (closure part, `checkClosureKindLimits` post-P2 form) + 2 tests
- [x] 2.9 shim / old group / old helpers deleted; [P2] invariants; theory docs
- [x] Phase 2 gate recorded (expected-failure list matched exactly; census numbers; perf entry; E10 run)

## Open questions (with defaults; none block)

1. **`combined_args` alloca of up to 16 KiB.** **Default:** heap-allocate when
   `max_values > 256`.
2. **`getAllBoxedLayout` beyond 64.** **Default:** mutex-guarded interned cache. One mutator per
   process (HEAP_007), but kernels may call from helper contexts, so lock anyway.
3. **`EvaluatorDesc.kinds` past 32 params.** **Default:** first 32 only, advisory (overview
   §2.2).
