# Bytes-fusion escape hatch: `EOpaque` + `bf.write.encoder`

A small extension to the BF dialect that lifts the bytes-fusion entry from
"all-or-nothing" to "fuse what you can, delegate the rest". When the reifier
hits a subtree it doesn't recognise (HO mapFns, opaque locals, deep recursion),
it returns `Just [EOpaque expr]` instead of `Nothing`. The outer expression
still produces a single `bf.alloc → cursor.init → writes → ReturnBuffer`
sequence; opaque subtrees lower to a new `bf.write.encoder` that calls the
existing C++ `writeEncoder` walker against the BF cursor.

## Motivation

Coming out of [plans/bytes-fusion-broader-recognition.md](./bytes-fusion-broader-recognition.md)'s
Phase 5 + the `maxInlinesPerFunction = 10 → 1000` change, the
post-cap-1000 `eco-compiler.mlir` has:

- 21 `@Elm_Kernel_Bytes_encode` call sites (up from 14 before cap-1000;
  inlining exposed previously-hidden encoder calls).
- **3 fused encoder sites** (`bf.alloc` count). 18/21 still fall back to the
  kernel because at least one subtree fails reification — typically the HO
  pattern `Utils.Bytes.Encode.list someEncoderFn xs` where `someEncoderFn`
  is a function parameter of the enclosing AST encoder (`Compiler.AST.Optimized.exprEncoder`
  and friends).

The reifier's failure mode is binary: any `Nothing` anywhere in the tree
poisons the whole expression. The kernel then receives a fully-built `Encoder`
runtime tree (all the now-inlined primitive encoders included), allocates a
ByteBuffer, and walks the tree twice. The 56-ish primitive writes that *would*
have fused contribute 56 Encoder cells + Seq + cons cells to the heap; they
never reach `bf.write.*`.

The data-model analysis (see prior conversation summary, also reflected in
the design notes in [plans/fused-bytes-plan.md](./fused-bytes-plan.md)) shows
both paths produce the same artifact — a `ByteBuffer`-backed `Bytes` value.
The runtime `writeEncoder(encoder, buf, offset&)` walker is already
parameterised on a destination buffer + offset, so it can write into *any*
caller-provided buffer at *any* offset. That's the hook the escape hatch uses.

## What lands

| Layer | Change | Notes |
| --- | --- | --- |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm` | Add `EOpaque Mono.MonoExpr` to `EncoderNode`; flip the fall-through arms of `reifyEncoderHelp` from `Nothing` to `Just [EOpaque expr]` for non-recognised shapes (with carve-outs — see "Reifier policy" below). | Single new constructor + ~20 lines reworking the "I don't recognise this" arms. |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | Add `WriteOpaque String Mono.MonoExpr` to `Op`; add `WOpaqueWidth Mono.MonoExpr` to `WidthExpr`. | Mirrors `WriteUtf8` / `WStringUtf8Width` exactly. |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm` (`nodesToOps` / `computeWidth`) | Lower `EOpaque expr` → `WriteOpaque cursorName expr`; contribute `WOpaqueWidth expr` to the buffer-size expression. | Same arm shape as the `EUtf8` lowering. |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Emit.elm` | Lower `WriteOpaque` to a `bf.write.encoder` op; lower `WOpaqueWidth` to a `bf.encoder.width` op. | Cursor SSA-threaded same as `bf.write.utf8`. |
| `runtime/src/codegen/BF/BFOps.td` | Add `BF_EncoderWidthOp` (operand: `AnyType:$encoder`; result: `I32:$width`) and `BF_WriteEncoderOp` (operands: `BF_Cursor:$cursor, AnyType:$encoder`; result: `BF_Cursor:$result`). | One new op each, modelled on `BF_BytesWidthOp` and `BF_WriteBytesOp`. |
| `runtime/src/codegen/Passes/BFToLLVM.cpp` | Declare two runtime symbols (`elm_encoder_size`, `elm_encoder_write_into`). Add `EncoderWidthOpLowering` (single call, return i32) and `WriteEncoderOpLowering` (extract cursor ptr, call write helper getting bytesWritten, advance cursor). | Copy `BytesWidthOpLowering` and `WriteUtf8OpLowering` as templates. |
| `runtime/src/codegen/RuntimeSymbols.cpp` | Wire `elm_encoder_size` and `elm_encoder_write_into` into the JIT symbol table. | Two `symbolMap[...]` lines next to `elm_alloc_bytebuffer`. |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp` | Promote `encoderSize` from `static` to `extern "C" u32 elm_encoder_size(HPtr)`. Add `extern "C" u32 elm_encoder_write_into(HPtr encoder, u8* dst)` — 5-line wrapper that resolves the HPtr, calls the existing `writeEncoder(custom, dst, offset)`, and returns `offset` as bytes-written. | `writeEncoder` is reused unchanged. Both helpers are GC-leaf (no `eco_alloc*` calls). |
| `elm-kernel-cpp/src/bytes/Bytes.hpp` | Add declarations for the two new extern symbols. | One-liner each. |

No changes to `Bytes.Encode.Encoder` (the user-facing Elm type) or to the
`writeEncoder` walker itself. The escape hatch is purely additive at the BF
dialect level.

## Reifier policy

There are four arms in `reifyEncoderHelp` that currently return `Nothing`:

1. **`MonoCall` with an unrecognised global / kernel / function position.**
   Today: bail. New: emit `EOpaque expr` for the whole call expression.
2. **`MonoVarLocal name` whose `exprCache` lookup fails (or whose resolved value isn't itself reifiable).**
   Today: bail. New: emit `EOpaque (MonoVarLocal …)` so the runtime
   walker resolves it through `Elm_Kernel_Bytes_encode`'s normal HPointer
   resolution.
3. **`reifyEncoderList`'s tail-of-cons or higher-order map case where `reifyMapBody` returns `Nothing`.**
   Today: bail the *entire* `BE.sequence`. New: walk the list at compile
   time as far as possible; cons heads that reify go through as
   `EU*`/`EUtf8`/etc.; cons heads that don't reify produce `EOpaque`. The
   list-spine itself must still be a literal `MonoList`/`cons`-chain we
   can walk at compile time — see open question (Q3) below for the
   non-literal-list case.
4. **The `_ -> Nothing` catch-all.** Today: bail. New: emit `EOpaque`.

Two carve-outs where keeping `Nothing` is still correct:

- **All-opaque encoder.** If the *entire* root expression reifies to `[EOpaque
  root]` (single opaque node, no fused primitives at all), the resulting
  MLIR is just `bf.alloc + cursor.init + bf.write.encoder %root + return` —
  semantically identical to a direct `@Elm_Kernel_Bytes_encode` kernel call
  but with one extra layer of indirection (the BF wrapper around what would
  be a single kernel call). The detection is local: at the end of
  `reifyEncoderHelp`, before returning the result, check `case result of
  [EOpaque _] -> Nothing; _ -> Just result`. This keeps the kernel-call
  fallback as the cheapest path for fully-opaque expressions.
- **The decoder side stays unchanged.** Decoders don't have an obvious
  "concatenate opaque bytes" equivalent — a partial decode failing means
  we can't continue the structured walk. Decoder reification continues to
  return `Nothing` on unfamiliar shapes.

**No behavioural change for fully-fusable expressions.** Literal-list
`BE.sequence [a, b, c]` calls that fully reify today continue to do so;
the escape hatch only fills in *previously-failing* arms. A fully-fusable
literal list never lowers to `EOpaque`.

**Non-literal list spines stay out of scope.** `BE.sequence dynamicListVar`
where `dynamicListVar` is a runtime list (not a literal `MonoList` or
literal cons-chain) emits a single `EOpaque` covering the whole sequence
call — the spine isn't walked at compile time. A future "ELoop with
dynamic list spine" extension can address this without touching the
escape hatch's invariants.

## Width computation

`computeWidth` already produces a `WidthExpr` algebraic tree (constants
plus runtime `WStringUtf8Width` / `WBytesWidth` / `WListLengthMul`).
`WOpaqueWidth expr` slots into the same machinery — it's a runtime i32
computed via `bf.encoder.width %encoder`, which the BF→LLVM pass lowers
to `elm_encoder_size(encoder)`.

The runtime `encoderSize` (already implemented in
`BytesExports.cpp:122`) is the perfect match: it recurses through the
encoder tree once, returning the total byte count via cached widths in
`ENC_SEQ`/`ENC_UTF8` nodes and primitive sizes for the rest. Sub-linear
per-leaf because seq widths are pre-cached. No allocation.

The width is carried as `i32` end-to-end (matching `bf.bytes_width` and
the rest of the BF dialect). The extern wrapper `elm_encoder_size`
returns `u32`; it casts down from `encoderSize`'s `size_t` with an
implicit narrowing that's safe for any plausible encoder output (the
existing BF dialect already assumes ≤4 GiB outputs). Widening the whole
dialect to i64 is a separate concern, out of scope here.

## GC / rooting analysis

The escape hatch widens the contract of a BF write op: previously every
operand was either a scalar (i64/f64) or a known-flat heap object
(`ByteBuffer`, `String`). The opaque encoder is an arbitrary `Custom`
heap tree.

`writeEncoder` calls `allocator.resolve(hp)` repeatedly on HPointers
read from inside the tree. These resolves do not allocate. The two
non-allocation memory operations inside `writeEncoder` are:

- `Elm::StringOps::toStdU16String(strPtr)` on non-leaf strings — this
  allocates a `std::u16string` on the C++ heap (not the Eco managed
  heap). Not a GC point.
- `byteBufferView(bbPtr)` — pointer view, no allocation.

So `bf.write.encoder` is a GC-leaf at the MLIR level. The encoder operand
(`AnyType:$encoder`) must be live across the call but doesn't need
re-rooting *inside* the call. The cursor's `current_ptr` is a raw
pointer into the destination ByteBuffer; for that to stay valid, the
destination must not move while the call runs. Since `bf.write.encoder`
is a leaf, no minor or major GC fires during the call, so the destination
pointer stays valid.

The implicit guarantee from `bf.alloc → cursor.init → write* → ReturnBuffer`
that the buffer isn't relocated mid-sequence (relied on by every existing
bf.write op) continues to hold for `bf.write.encoder` without new
mechanism.

**Verification step in implementation**: confirm by inspection that
`writeEncoder` doesn't transitively call anything that allocates Eco-managed
memory. Today's call graph: writeEncoder → `allocator.resolve`, `byteBufferView`,
`endiannessHPointerToBool`, `Elm::StringOps::*`, plus C++ stdlib
(`std::memcpy`, `std::u16string` construction). All non-allocating w.r.t.
the Eco heap. If a future change adds an Eco-side allocation inside the
walker, that's the moment to add RS4GC `gc-leaf` annotations or to
explicitly root the cursor's underlying buffer.

## Implementation steps

1. **Skeleton wire-up (Elm side, lands first; behaviourally a no-op).**
   - Add `EOpaque Mono.MonoExpr` to `EncoderNode`.
   - Add `WriteOpaque String Mono.MonoExpr` to `LoopIR.Op` and
     `WOpaqueWidth Mono.MonoExpr` to `WidthExpr`.
   - Add the two new `Reify.elm` arms in `nodesToOps` and the width
     computation. Both Elm functions become total (no unhandled
     `EOpaque` case slipping into emit).
   - Do NOT flip any `Nothing → Just [EOpaque …]` yet — at this point
     `EOpaque` is unreachable.
   - Run: `cmake --build build --target guida` then E2E + stress. Should
     be a clean no-op.

2. **MLIR dialect ops.**
   - Add `BF_EncoderWidthOp` and `BF_WriteEncoderOp` to
     `runtime/src/codegen/BF/BFOps.td`. Templates: `BF_BytesWidthOp` and
     `BF_WriteBytesOp`.
   - Rebuild the BF dialect (`cmake --build build --target BFDialect`).
   - No emit-side usage yet — the ops exist but nothing produces them.

3. **Runtime helpers + lowering.**
   - Promote `encoderSize` from `static` in `BytesExports.cpp` to
     `extern "C" u32 elm_encoder_size(HPtr)`. Declare in `Bytes.hpp`.
   - Add `extern "C" u32 elm_encoder_write_into(HPtr encoder, u8* dst)`:
     ```cpp
     extern "C" u32 elm_encoder_write_into(HPtr encoderVal, u8* dst) {
         HPointer h = Export::decode(encoderVal.toBits());
         Custom* enc = static_cast<Custom*>(Allocator::instance().resolve(h));
         size_t offset = 0;
         writeEncoder(enc, dst, offset);
         return static_cast<u32>(offset);
     }
     ```
     Declare in `Bytes.hpp`.
   - Wire both into `RuntimeSymbols.cpp` (next to `elm_alloc_bytebuffer`).
   - Add `EncoderWidthOpLowering` + `WriteEncoderOpLowering` to
     `BFToLLVM.cpp`, registered alongside the existing `*OpLowering`s.
     Templates: `BytesWidthOpLowering` and `WriteUtf8OpLowering`.
   - Add C++ test confirming an isolated `bf.encoder.width` and
     `bf.write.encoder` MLIR fragment lowers + runs end-to-end against
     a tiny hand-built Encoder tree.

4. **Emit-side wiring.**
   - In `Emit.elm`, add cases that emit `bf.encoder.width` for
     `WOpaqueWidth` and `bf.write.encoder` for `WriteOpaque`.
   - Still no producer — chain is complete but dormant.

5. **Flip the reifier.**
   - In `Reify.elm`, change the four `Nothing`-returning arms listed
     above (`reifyEncoderHelp` catch-all; `reifyBytesEncodeCall` catch-all;
     `reifyEncoderList` non-literal-tail cases; `reifyMapBody` catch-all)
     to return `Just [EOpaque originalExpr]`.
   - **Add the all-opaque short-circuit inside `reifyEncoderHelp`**: at
     the return site, `case result of [EOpaque _] -> Nothing; _ -> Just
     result`. Local and exact — fires only when the entire encoder is
     opaque, avoiding the wrapper-around-kernel-call indirection.
   - This is the behavioural change.

6. **Reifier trace counter.**
   - Behind an `ECO_BF_REIFY_TRACE=1` env-var gate, emit `(fused,
     opaque)` node counts per encoder reification attempt — one line
     per top-level `reifyEncoderWith` / `reifyEncoder` call, suitable
     for grepping. Use the same `Debug.log` mechanism the Phase 5
     diagnostics used (gated so it's a no-op when the env var is
     unset).
   - This is the regression-metric hook called out under acceptance
     criterion 2 — `EOpaque` counts trending up over time signals
     the reifier is losing coverage; trending down signals
     reifier extensions (HO specialisation, etc.) are doing real work.

7. **Targeted smoke verification.**
   - Add a new test fixture `test/elm-bytes/src/FusionPartialOpaqueTest.elm`
     covering a mixed shape:
     ```elm
     E.encode (E.sequence
         [ E.unsignedInt8 7                              -- fuses
         , <some HO call that won't fuse>                -- opaque
         , E.string "hi"                                  -- fuses
         ])
     ```
     With `-- CHECK-MLIR: bf.alloc` + `-- CHECK-MLIR: bf.write.encoder`
     + `-- CHECK-MLIR-NOT: Elm_Kernel_Bytes_encode` in the test's lowered
     MLIR.
   - Run that single test through the e2e harness; confirm fusion fires
     and the program produces the right bytes.

8. **Full gates.**
   - `cmake --build build --target full` (E2E baseline: 1410/1410).
   - `cmake --build build --target stress` (baseline: 100/100).
   - Clean caches + `cmake --build build --target eco-compiler-boot`
     (baseline: 9/9 stages, fixed-point holds; Stage 5 ~2:00 / Stage 7a
     ~2:51 wall).
   - Note: cache-corruption gotcha from the cap=1000 work applies —
     after any compiler-source change, wipe
     `/work/build/compiler/build-{kernel,xhr}/elm-stuff` and
     `/work/build/compiler/build-kernel/eco-stuff` before bootstrapping.

## Acceptance criteria

1. **All 21 encoder sites in `eco-compiler.mlir` reach the fused BF path.**
   Measured as: number of `bf.alloc` ops (real, excluding string-literal
   embeddings) in the unpacked text MLIR. Today: 3. Target: ≥18 (every
   site that previously fell back to the kernel due to an opaque subtree).
   The remaining ≤3 may legitimately stay as kernel calls if the whole
   encoder is opaque (the carve-out above).
2. **Outer-Encoder-tree allocation drops materially.**
   Sub-measurement: `@Bytes_Encode_Seq_` callee references in
   `eco-compiler.mlir` should drop substantially from the cap=1000
   baseline of 1983 — primitives that were going into `Seq` cells now
   route through `bf.write.*`. Exact target is data-dependent; ≥30%
   reduction is the rule-of-thumb floor.
3. **E2E, stress, and bootstrap stay green.** Same baselines as the
   cap=1000 work: 1410/1410, 100/100, 9 stages exit 0 with fixed point.
4. **Stage 5 wall ±5% of the cap=1000 baseline (~2:00). Stage 7a wall
   ±10% of the cap=1000 baseline (~2:51).** No memory regression beyond
   the existing baselines (Stage 5 ≤ ~3.3 GiB RSS, Stage 7a ≤ ~4.4 GiB).
5. **No regression in the smoke fixture `FusionGlobalMapFnTest`** — it
   should continue to fuse to `scf.while` + `bf.write.u8` exactly as
   it does today.
6. **The new smoke fixture `FusionPartialOpaqueTest` passes** with both
   stdout `-- CHECK:` directives AND the `-- CHECK-MLIR:` directives
   (showing `bf.write.encoder` + the absence of `Elm_Kernel_Bytes_encode`
   in the function body).

## Risks and pitfalls

- **GC safety of `writeEncoder`.** The walker is currently allocation-free
  w.r.t. the Eco heap (see "GC / rooting analysis" above). If a future
  change introduces an allocation inside the walker, `bf.write.encoder`
  silently becomes a GC point and the cursor's raw `current_ptr` can
  dangle if the destination is movable. Mitigations: (a) add a comment
  in `writeEncoder` warning "do not allocate from the Eco heap; this is
  called via `bf.write.encoder` which assumes GC-leaf semantics"; (b) keep
  the LOT-aware allocator's pinning behaviour for over-threshold buffers
  (already pinned in old-gen by `elm_alloc_bytebuffer`); (c) consider
  adding an RS4GC `gc-leaf` annotation when we have it available.
- **All-opaque degenerate.** Without the short-circuit, an encoder where
  no primitive reifies emits `bf.alloc + cursor.init + bf.write.encoder
  + return` — a strictly more expensive equivalent of the direct kernel
  call. Mitigation: the carve-out in step 5. Verified by a unit
  assertion in the reifier or a `--CHECK-MLIR-NOT: bf.write.encoder` on
  the all-opaque case if we add a test fixture for it.
- **Width-walk amortisation.** `bf.encoder.width` walks the opaque
  subtree once; `bf.write.encoder` walks it again. Today's kernel does
  the same two walks; no regression. But for encoders with deep `Seq`
  trees, both walks are O(N) on the cons-list spine even though widths
  are pre-cached. Worth measuring if Stage 7a wall regresses beyond
  ±10%.
- **Reifier eagerness.** The previously-conservative `Nothing` arms
  often caught shapes that *could* have been reified with more work
  (HO mapFns, deeper let-walks). Eagerly returning `EOpaque` may mask
  opportunities to extend the reifier in the future, because the test
  outcomes still look "fusion fires". Mitigation: track the count of
  `EOpaque` nodes in `eco-compiler.mlir` over time as a regression
  metric. Phase 6 of the plan tree (HO specialisation) should
  visibly *reduce* this count.
- **Cache-format invalidation.** As noted in the post-cap=1000 work,
  changes to compiler-side Elm code invalidate `eco-stuff/`/`elm-stuff/`
  in a way the build system doesn't always notice. Wipe before each
  bootstrap re-run.

## Decisions (resolved 2026-05-24)

1. **All-opaque detection** — in `reifyEncoderHelp` (local, exact-single-opaque
   check at the return site). Implemented in step 5. Threshold-based
   detection in `tryEncoderFusionWithBindings` is not pursued.
2. **`bf.encoder.width` return type** — `i32`. Matches the rest of the
   BF dialect; 4 GiB ceiling on encoder output is acceptable. No
   widening of the dialect is part of this plan.
3. **Non-literal list spine in `reifyEncoderList`** — out of scope.
   `BE.sequence dynamicListVar` lowers to a single `EOpaque` covering
   the whole sequence call. Fully-fusable literal-list shapes (the
   `MonoList` and literal-cons-chain arms) continue to fuse as today
   — the escape hatch does not regress them. A future "ELoop with
   dynamic list spine" extension can revisit.
4. **Width vs writer agreement assertion** — not added. Encoders are
   immutable in current code; the extra branch in
   `elm_encoder_write_into` isn't justified.
5. **Naming** — `bf.write.encoder` and `bf.encoder.width`. Descriptive,
   matches the dialect's `utf8` / `bytes` naming convention.
6. **Reifier trace counter** — included as step 6, gated by
   `ECO_BF_REIFY_TRACE=1`. Emits `(fused, opaque)` counts per
   reification attempt for the regression-metric hook.

## Cross-references

- [bytes-fusion-broader-recognition.md](./bytes-fusion-broader-recognition.md)
  — Phase 5 prerequisite (`tryEncoderFusionWithBindings`,
  `compileSkippedBindings` mechanism); cap=1000 measurement baseline.
- [fused-bytes-plan.md](./fused-bytes-plan.md) — original BF dialect
  design; `bf.write.*` / `bf.cursor` conventions.
- [let-bound-ho-arg-specialization.md](./let-bound-ho-arg-specialization.md)
  — the HO-specialisation work that would eventually reduce the number
  of opaque leaves the escape hatch routes around. The escape hatch
  and HO specialisation are complementary: the hatch makes partial
  fusion always-on; specialisation gradually shrinks the opaque
  population over time.
