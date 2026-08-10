# Kernel-Opt 04: eco.string.length inline + eco.string.code_unit_at

**Status: IMPLEMENTATION-READY v2.1 — 2026-08-10.** (v2 deepened from OUTLINE v1; v2.1 =
adversarial verification pass, every load-bearing anchor re-checked against the tree.
Two substantive corrections in v2.1: the empty/constant guard is now the `ptr_ind` bit
test, not a whole-word `== 0x6` (Phase 2, "Empty/constant guard"), and the header-offset
constant moved from `EcoToLLVMInternal.h` into `EcoBackend.cpp` because that translation
unit does not include the header (Phase 2a/2d).) Derived from
`design_docs/kernel-boundary-reduction.md`
Q4.1(a) + the `eco.string.*` op-spec table (:657-734) and R5; dynamic census
`design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt:8`; static census
`design_docs/kernel-boundary/callsite-census-self-compile.txt:17`.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Compiler/Eco/Config.elm` | `stringLengthOp : Bool` appended to the `EcoConfig` record (:32-48, after `sretTailFuncs` :48), default `False` (:292-339, `aggPromote = True` at :333), `decoder` line last (:346-361, `aggPromote` at :356), `hash` token `strlen=1` when on (`hash` :540-743, after the `bopt=1` block :738-742) |
| `compiler/src/Builder/Eco/Config.elm` | `ECO_STRING_LENGTH_OP` doc bullet in `applyEnvOverrides`' doc comment (:76-110), `Task.andThen` link after the `ECO_BORROW_OPT` one (:260-264), `applyStringLengthOpOverride` (template `applyAggPromoteOverride`, doc :267-271, body :272-290) |
| `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | `StringLength` ctor in the `Intrinsic` type (:27-53, next to `StringFromInt`/`StringFromFloat` :43-44), `intrinsicResultMlirType` arm (`ArrayLength` at :131), `intrinsicOperandTypes` arm (`ArrayLength` at :217), `stringIntrinsic` arm (:660-671), `generateIntrinsicOp` arm (`StringFromInt` at :909-914), `kernelIntrinsic` (:318-341) / `stringIntrinsic` gain a `Config.EcoConfig` param, `import Compiler.Eco.Config as Config` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | 3 `kernelIntrinsic` call sites pass `ctx.ecoConfig` (:775, :3725, :4199) |
| `runtime/src/codegen/Ops.td` | `Eco_StringLengthOp`, `Eco_StringCodeUnitAtOp` inserted after `Eco_StringFromFloatOp` (:1114-1123, `}` on :1123) and before the `4. Call and Closure Operations` banner (:1125-1127) |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | `StringLengthOpLowering`, `StringCodeUnitAtOpLowering` (after `ArrayLengthOpLowering`, which ends :1250); registration next to `patterns.add<StringFromIntOpLowering>` (:2107) |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | `stringLenInlineEnabled()` (after `inlineAllocEnabled()` :769-775), 3 `getOrCreate*` decls (next to `getOrCreateStringCmpOrder` :705) |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | 3 factory defs (next to `getOrCreateStringCmpOrder` :946-950) + 3 entries in `materializeAllRuntimeDecls` (:1211-1274; string line :1264) |
| `runtime/src/codegen/EcoBackend.cpp` | `expandStringLenMarkers(Module&)` (new, template = `expandGetTagMarkers` :1419-1526); file-local `kHeaderSizeFieldOffset` + `offsetof` static_assert; `#include <cstddef>`; call it in `runEcoBackend` right after `expandListCursorMarkers(m);` (:2507), i.e. inside the marker cluster :2500-2516 that precedes `expandInlineDerefs` (:2517) |
| `runtime/src/codegen/RuntimeSymbols.cpp` | `KERNEL_SYM(eco_string_code_unit_at)` next to `KERNEL_SYM(eco_string_cmp3)` (:743), in the `eco_*` three-way-compare group (:734-744) — **not** the `Elm_Kernel_String_*` block (:651-686), which holds only `Elm_Kernel_`/`elm_` symbols |
| `elm-kernel-cpp/src/core/StringExports.cpp` | `eco_string_code_unit_at` definition (inside the `extern "C" {` block opened at :16, after `Elm_Kernel_String_length` :18-27) |
| `elm-kernel-cpp/src/KernelExports.h` | `uint16_t eco_string_code_unit_at(HPtr str, int64_t index);` next to `eco_string_cmp3`/`eco_string_cmp_order` (:189-193) — the existing home for non-`Elm_Kernel_` gc-leaf String exports; still inside the file-wide `extern "C" {` (:19-571) |
| `design_docs/invariants.csv` | FORBID_HEAP_002 amendment (:531) — verbatim draft in Phase 3 |
| `test/codegen/string_length_structural.mlir` | NEW (`-emit=mlir-eco`): op survives eco-to-eco, no kernel call |
| `test/codegen/string_length_forms.mlir` | NEW (`-emit=jit`): empty / ASCII leaf / UTF-16 leaf / slice / rope / large behaviour pins |
| `test/codegen/string_code_unit_at.mlir` | NEW (`-emit=jit`): in-range, out-of-range→0, empty→0, all forms |
| `test/elm/src/StringLengthFormsTest.elm` | NEW: end-to-end `String.length` over all six forms + `""` |

## Flag & rollback

Two independent kill switches — the compiler-side one decides whether the op is
*emitted*, the backend-side one decides how it is *lowered*.

- **Compiler:** `Config.stringLengthOp`, **default `False`**. Env
  `ECO_STRING_LENGTH_OP=1|true|yes|on` enables, `=0|off` disables
  (`applyAggPromoteOverride`, `Builder/Eco/Config.elm:272-290`, is the literal
  template). Artifact-affecting → `hash` gains `"strlen=1"` **only when enabled**,
  so default configs hash byte-identically to today and share every existing cache
  (the `cafd=1` precedent, `Compiler/Eco/Config.elm:576-584`; the `ar=1` one,
  :607-617). Off ⇒
  `stringIntrinsic` returns `Nothing` ⇒ the existing `Elm_Kernel_String_length`
  call path, unchanged.
- **Backend:** `ECO_STRING_LEN_INLINE`, **default on** (`stringLenInlineEnabled()`,
  modelled on `inlineAllocEnabled()` `EcoToLLVMInternal.h:769-775`). `=0` makes
  `StringLengthOpLowering` emit a plain `Elm_Kernel_String_length` call instead of
  the `__eco_string_len_inline` marker. This gives a backend-only A/B leg that
  needs **no compiler rebuild** and no `.mlir` regeneration.
- **Revert:** deleting the four Elm hunks restores today's emission exactly;
  deleting the Ops.td defs + the two lowerings + `expandStringLenMarkers` restores
  today's backend. The `eco_string_code_unit_at` export is additive and unreferenced
  when the op is unused (internalize + globalDCE drop the declaration, the
  `getOrCreateArrayGetI16` precedent).

## Goal

Delete the `Elm_Kernel_String_length` call entirely — the hottest string op — by
open-coding it as an INLINE-IR `eco.string.length` op (a u32 header load), and export
`StringOps::charAt` as a `GC-LEAF-CALL` `eco.string.code_unit_at` op. The second
retires nothing directly; it is the enabling primitive for kernel-opt-14's String-HOF
phase and for elm/parser-using user programs.

## Evidence

- **Dynamic:** `Elm_Kernel_String_length` = **75,588,290** calls in the Stage-7a
  census (rank **#7** of 98 — behind `Utils_compare`, the three `getOrder*`,
  `Utils_equal`, `List_cons`; **2.06 %** of the 3,676,097,627 total). The canonical
  statically-invisible-dynamically-hot symbol; cheapest large call-deletion on the
  board.
- **Static (re-measured 2026-08-10, anchor drift corrected):** the design doc's
  **102** is the older 990-file corpus number. On the newest *textual* self-compile
  dump in the tree (`build/compiler/build-kernel/bin/aggp-solver.mlir`,
  122 MB, 2026-08-03) the symbol appears **93** times: **92** as
  `callee = @Elm_Kernel_String_length` on `"eco.call"` and **1** as the
  `is_kernel = true` stub. **Zero** `papCreate` forms — every self-compile use is a
  direct saturated call, so the intrinsic covers 100 % of them. Phase 0 re-measures
  on the build under test.
- **O(1) by invariant:** HEAP_025 (`invariants.csv:563`) defines `header.size` as the
  logical UTF-16 length for the four UTF-16 forms and its 2026-07-08 update extends
  the same statement to the two UTF-8 forms ("header.size is still the logical UTF-16
  unit count for these"), cross-referenced by HEAP_032 (`invariants.csv:566`). All six
  tags: `Tag_String` (`Heap.hpp:80`), `Tag_StringRope` (:94), `Tag_StringSlice` (:95),
  `Tag_LargeStringHeader` (:101), `Tag_StringUtf8View` (:111), `Tag_StringUtf8Leaf`
  (:112). `StringOps::rawLen` is a single u32 load (`StringOps.hpp:111` — v1 said
  :112); `StringOps::length` = null guard + `rawLen` (:239-242).
- **Exact kernel semantics to mirror** (`elm-kernel-cpp/src/core/StringExports.cpp:18-27`,
  verbatim):
  ```cpp
  int64_t Elm_Kernel_String_length(HPtr str) {
      uint64_t str_bits = str.toBits();
      HPointer h = Export::decode(str_bits);
      if (Elm::alloc::isEmptyString(h)) {
          return 0;
      }
      void* ptr = Export::toPtr(str_bits);
      assert(ptr && "Elm_Kernel_String_length: unexpected null pointer");
      return String::length(ptr);
  }
  ```
  Resolved against the tree, the guard chain is:
  - `alloc::isEmptyString(h)` (`HeapHelpers.hpp:235-237`) = `Elm::isEmptyBits(hpBits(h))`
    (`Heap.hpp:327-330`) = `h.ptr_ind != 0 && h.constant == Const_Empty`, i.e.
    **`(bits & 0x7) == 0x6`** — *not* a whole-word equality against `0x6`.
  - `Export::toPtr` (`ExportHelpers.hpp:47-68`) returns `nullptr` when
    `ptr_ind != 0 && ptr == 0 && enum_idx == 0 && padding == 0` (i.e. for **any**
    embedded constant — `False` `0x4`, `True` `0x5`, `Empty` `0x6`), otherwise
    `resolveFast(h)` for an in-heap word and the raw word-as-pointer for anything else.
  - `String::length` (`String.cpp:18-19`) is a straight forward to `StringOps::length`
    (`StringOps.hpp:239-242`), whose first line is `if (!str) return 0;`.

  So the kernel's **observable result** is exactly two cases: **(a)** any embedded
  constant → `0` (Empty via `isEmptyString`, Bool via `toPtr`→`nullptr`→`length(nullptr)`);
  **(b)** anything else (in-heap HPointer *or* raw non-heap pointer) →
  `zext(header.size)`. The inline IR must reproduce exactly that — see Phase 2, which
  pins the `ptr_ind` (bit-2) test for precisely this reason.

  **One non-value divergence, recorded deliberately:** the `assert(ptr && …)` is *live*
  in the standard build (`build` preset sets `-UNDEBUG`, `CMakePresets.json:34-35`), so a
  Bool constant reaching the kernel aborts loudly, while the inline op returns `0`
  silently. Unreachable for well-typed programs (only `Const_Empty` is a String), and it
  is a debugging-aid difference, not a result difference.
- **Layout:** `Header` is `{u32 tag:5|color:2|pin:1|age:2|unboxed:6|refcount:15|builder:1;
  u32 size;}` (`Heap.hpp:163-174`, `static_assert(sizeof(Header)==8)` at :175) → string
  length is a **u32 load at byte offset 4**. Arrays differ: their length is a separate
  field *after* the header at offset 8 (`layout::ArrayLengthOffset = HeaderSize = 8`,
  `EcoToLLVMInternal.h:352`). Note `HeaderSize` (8) and the string length offset (4) are
  different numbers for different things; Phase 2d pins the string one with `offsetof`.
- **Template lowerings:** `ArrayLengthOpLowering` (`EcoToLLVMHeap.cpp:1219-1250`) for
  the resolve+GEP+load+zext skeleton; `expandGetTagMarkers` (`EcoBackend.cpp:1419-1526`)
  for the embedded-constant/heap diamond at LLVM level; `StringCmpOrderOpLowering`
  (`EcoToLLVMArith.cpp:1117-1132`) for the trivial gc-leaf-call lowering.
- **charAt is already the right shape:** `StringOps::charAt` (`StringOps.hpp:410-463`)
  is iterative (deep ropes cannot blow the C stack), tag-dispatched over all six forms,
  and allocation-free so callers need no rooting (documented at :401-409, the
  "Resolution does not allocate" sentence at :407-408) — and has **no C-linkage export**
  today (no entry in `elm-kernel-cpp/src/KernelExports.h`; every in-tree caller is inside
  the runtime allocator layer: `StringOps.hpp:677-678, :711, :744-745, :1322, :1334`,
  `StringOps.cpp:1015`, `RuntimeExports.cpp:2797, :2819, :2834`). Downstream consumer:
  the six String HOFs (`StringExports.cpp:251, 269, 287, 305, 324, 340`) each pay a full
  `std::vector<u16>` snapshot (`snapshotChars`, :225-233, comment :220-224) plus a
  per-char dynamic closure apply.
- **Anchor correction (v1 was wrong):** the elm/parser kernels do **not** use
  `charAt`. The file is `elm-kernel-cpp/src/parser/ParserExports.cpp` (v1 named it
  without the `parser/` directory): each primitive calls `resolveString` (:81-86) =
  `parserView(parserFlatten(hp))`, where `parserFlatten` (:60-65) passes UTF-8
  (all-ASCII) and already-flat forms straight through and only calls
  `StringOps::ensureFlat` for rope/slice/UTF-16 sources, and `parserView` (:69-79)
  yields a `ParserStr` (:43-51) that the loops index with `s.at(i)` (e.g.
  `Elm_Kernel_Parser_isAsciiCode` :129-134). They gain nothing from `code_unit_at`
  unless the whole scan moves to Elm. The self-compile has **zero** Parser sites
  regardless.
- **Thresholds (v1 said "verify at implementation time" — verified):**
  `LARGE_OBJECT_THRESHOLD = 8 * 1024` bytes (`AllocatorCommon.hpp:94`) ⇒ split-header
  `Tag_LargeStringHeader` at ≥ (8192−8)/2 = **4092** UTF-16 units;
  `STRING_FLATTEN_LIMIT = 32 * 1024` units (:99) ⇒ `append` builds a
  `Tag_StringRope` above **32768** units; `STRING_TINY_SLICE_LIMIT = 128` units (:103)
  ⇒ `slice` allocates a `Tag_StringSlice` / `Tag_StringUtf8View` only above **128**.

## Approach

### Phase 0 — baseline confirmation (light, no code)

The per-symbol dynamic count is already exact (no attribution census needed, unlike the
Utils_equal/append splits), but the Stage-7a census predates the 2026-08-10 cmp3/compare
shipping.

1. **Static, on the build under test.** The compiler writes MLIR *bytecode* by default;
   `--text-mlir` (`Terminal/Main.elm:296`, chomped :337) writes text. Flags and working
   directory are Stage 7a's, verbatim (`compiler/CMakeLists.txt:478-490`) plus
   `--text-mlir` and a scratch `--output` so the real Stage-7a artifact is not clobbered:
   ```
   cd /work/build/compiler/build-kernel && \
   ./bin/eco-compiler make --optimize --text-mlir \
       --kernel-package eco/compiler \
       --local-package eco/kernel=/work/compiler/../eco-kernel-cpp \
       --output=/tmp/k04-base.mlir \
       /work/compiler/src/Terminal/Main.elm
   grep -c 'callee = @Elm_Kernel_String_length' /tmp/k04-base.mlir   # expect ~92
   grep -c 'sym_name = "Elm_Kernel_String_length"' /tmp/k04-base.mlir # expect 1
   ```
   (`/work/eco-kernel-cpp` is the Elm-side kernel *package*; `/work/elm-kernel-cpp` is
   the C++ kernel — do not swap them.)
2. **Dynamic.** The `ECO_KERNEL_CALL_CENSUS` instrumentation is **not in the tree**
   (verified: no `eco_kernel_census_bump` under `runtime/src`); re-apply it per
   `plans/kernel-call-census.md` §C1.1-C1.4, adding `eco_string_` to the counted
   prefix list so `eco_string_code_unit_at` stays visible. Record
   `Elm_Kernel_String_length` count + total.
3. **Wall + majors baseline.** Cold Stage 7a, 2×2 interleaved, per
   `plans/kernel-call-census.md` §C2.4; record major-GC counts with every wall number.

**Acceptance:** the three numbers are written into this file before Phase 1 lands.

### Phase 1 — `eco.string.length` op + Elm emission (flag-gated, default-off)

**1a. Ops.td** — insert after `Eco_StringFromFloatOp` (`Ops.td:1114-1123`; `}` is on
:1123) and before the `4. Call and Closure Operations` banner (:1125-1127). Trait
rationale copied from the `Eco_StringCmpOrderOp` block (`Ops.td:2751-2757`, the op
itself at :2759), which is the only existing precedent for `[Pure]` on an op that
*reads string contents*. `Eco_ArrayLengthOp` (:1000-1015) is the shape precedent —
same `[Pure]`, same `Eco_Value` operand, same `Eco_Int` result, same bare
`"$x attr-dict"` format (legal because `Eco_Value` is a `BuildableType`, :181-184,
and `Eco_Int`/`Eco_Char` are `I<64>`/`I<16>`, :239/:241, so no types need printing):

```tablegen
// String ops that READ heap through their operand. [Pure] is sound only because
// Eco strings are immutable after construction (every chars[]/byte write in
// StringOps.hpp targets a freshly allocated, not-yet-published `out` object) and
// SSA dominance already prevents motion above the operand's def. If a mutable
// string form (in-place builder) is ever added, revisit these traits FIRST.

def Eco_StringLengthOp : Eco_Op<"string.length", [Pure]> {
  let summary = "Logical UTF-16 length of a String (String.length)";
  let description = [{
    Reads `header.size`, which HEAP_025/HEAP_032 define as the logical UTF-16 unit
    count for ALL SIX String forms (Tag_String, Tag_StringRope, Tag_StringSlice,
    Tag_LargeStringHeader, Tag_StringUtf8View, Tag_StringUtf8Leaf) — so there is no
    per-tag dispatch. Any embedded constant (ptr_ind set) yields 0. Result is an
    unboxed Elm Int; the observable result is IDENTICAL to Elm_Kernel_String_length
    (elm-kernel-cpp/src/core/StringExports.cpp:18-27).

    ```mlir
    %len = eco.string.length %s
    ```
  }];
  let arguments = (ins Eco_Value:$str);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$str attr-dict";
}
```

**1b. Config flag.** `Compiler/Eco/Config.elm`: add to the `EcoConfig` record (next to
`aggPromote`, :42) —
```elm
    , stringLengthOp : Bool -- kernel-opt-04: emit eco.string.length instead of the
      -- Elm_Kernel_String_length call. DEFAULT-OFF; env ECO_STRING_LENGTH_OP=1
      -- enables; artifact-affecting (hash token "strlen=1" only when enabled)
```
`default` (:292-339) gains `, stringLengthOp = False`.

`decoder` (:346-361) gains
`|> D.apply (D.optionalField "stringLengthOp" D.bool default.stringLengthOp)`.
**The decoder is positional** (`D.pure EcoConfig |> D.apply …`) — the new `D.apply`
line must sit at exactly the field's position in the `EcoConfig` type alias, or every
subsequent field silently shifts. Appending the field last in the alias and the
`D.apply` last in the decoder is the safe pairing (`aggPromote`'s line is :356).

`hash` (:540-741) gains, appended to the trailing `++` chain after the `bopt=1` block
(:738-742), in the `aggp=1` posture (:687-697):
```elm
            -- eco.string.length emission rewrites the generated MLIR, so flag-on
            -- artifacts must never share flag-off caches; explicitly-disabled
            -- configs hash exactly like the historical default-off caches.
            ++ (if cfg.stringLengthOp then
                    [ "strlen=1" ]

                else
                    []
               )
```

`Builder/Eco/Config.elm`: one more `Task.andThen` link after the `ECO_BORROW_OPT` one
(the last link today, :260-264), plus `applyStringLengthOpOverride` byte-for-byte the
shape of `applyAggPromoteOverride` (doc :267-271, body :272-290), and one bullet in the
`applyEnvOverrides` doc comment (:76-110).

**1c. Intrinsics.elm.** Thread the config (three edits, all mechanical):

```elm
-- (i) new constructor, next to StringFromInt/StringFromFloat (:43-44)
    | StringLength

-- (ii) intrinsicResultMlirType (next to the ArrayLength arm, :131)
        StringLength ->
            Types.ecoInt

-- (iii) intrinsicOperandTypes (next to the ArrayLength arm, :217)
        StringLength ->
            -- REP_ABI_001: String crosses every ABI as !eco.value; never unbox.
            [ Types.ecoValue ]

-- (iv) dispatch: kernelIntrinsic/stringIntrinsic take the config
kernelIntrinsic : Config.EcoConfig -> Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsic cfg home name argTypes resultType =
    case home of
        ...
        "String" ->
            stringIntrinsic cfg name argTypes resultType
        ...

stringIntrinsic : Config.EcoConfig -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
stringIntrinsic cfg name argTypes _ =
    case ( name, argTypes ) of
        ( "fromNumber", [ Mono.MInt ] ) ->
            Just StringFromInt

        ( "fromNumber", [ Mono.MFloat ] ) ->
            Just StringFromFloat

        -- kernel-opt-04. Requires the SATURATED shape: argTypes = [ MString ].
        -- A bare `Elm.Kernel.String.length` reference reaches generateVarKernel
        -- with argTypes = [] (Expr.elm:775) and therefore still falls through to
        -- the papCreate/kernel-decl path — whitelist discipline, unlisted forms
        -- keep today's behaviour.
        ( "length", [ Mono.MString ] ) ->
            if cfg.stringLengthOp then
                Just StringLength

            else
                Nothing

        _ ->
            Nothing

-- (v) generateIntrinsicOp, next to the StringFromInt arm (:909-914)
        StringLength ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.string.length" resultVar ( operand, Types.ecoValue ) Types.ecoInt
```
No new `Ops.elm` helper is needed — `ecoUnaryOp` (`Ops.elm:982-994`) already emits the
`_operand_types` discardable attribute the generic-form writer requires (verified
against the emitted `"eco.array.length"(%5) {_operand_types = [!eco.value]} :
(!eco.value) -> i64` shape in `build/compiler/build-kernel/bin/aggp-solver.mlir`).
Add `import Compiler.Eco.Config as Config` (no cycle: `Context.elm:63` already imports
it, and `Compiler.Eco.Config` itself imports only `Compiler.Json.Decode`).
No change to `Intrinsics.elm`'s `exposing` list (:1) or `@docs` (:8) — only
`kernelIntrinsic`'s arity changes, and `stringIntrinsic` is module-private.

**1d. Expr.elm.** Three call sites pass the config: `:775`
`Intrinsics.kernelIntrinsic ctx.ecoConfig home name [] monoType`; `:3725`
`Intrinsics.kernelIntrinsic ctx1.ecoConfig moduleName name argTypes resultType`;
`:4199` likewise. No other caller exists (`grep -rn kernelIntrinsic compiler/src`).

**Acceptance:** with `ECO_STRING_LENGTH_OP=1`, `--text-mlir` output contains
`"eco.string.length"` and **zero** `callee = @Elm_Kernel_String_length`; with the flag
unset the output is byte-identical to Phase 0's `/tmp/k04-base.mlir`.

### Phase 2 — lowering: marker in MLIR, diamond at LLVM level

**Design decision (pinned).** The lowering does **not** build a CFG diamond inside the
dialect conversion. `eco.string.length` will appear inside single-block `scf` regions
(loopified tail recursion — the hot parse/format loops), and MLIR lowerings cannot
create blocks there: this is the exact reason `eco.get_tag`, the chunked-list
projections and inline nursery allocation are all *markers* expanded at LLVM level
(`EcoBackend.cpp:1130-1138`: "The marker exists because eco.get_tag sits INSIDE
single-block scf regions … where the MLIR lowering cannot create blocks; here at the
LLVM level block structure is free"). The alternative — a `bodyTarget`
`addDynamicallyLegalOp` deferral like `CaseOp`'s (`EcoToLLVM.cpp:406-412`) — is
strictly more machinery for the same result. **Use the marker.**

(For the record, the *field-read* half could have been done at MLIR level:
`ArrayLengthOpLowering` builds no blocks — it calls `emitInlineFieldPtr`
(defined `EcoToLLVMHeap.cpp:114`, called from the lowering at :1239), whose resolve is
itself the gc-leaf `__eco_resolve_fwd` marker call (`inlineResolvedBase`,
`EcoToLLVMInternal.h:783-790`). What forces the marker here is only the
**embedded-constant branch**: the constant word cannot be dereferenced, so a branch-free
`select` is unsound and a real CFG diamond is required.)

**Empty/constant guard — PINNED: test `ptr_ind` (bit 2), not word equality.**
The kernel returns `0` for **every** embedded constant, not only `Const_Empty`:
`isEmptyString` catches `Empty` (`(bits & 7) == 6`), and `Export::toPtr` maps the Bool
constants to `nullptr`, which `StringOps::length`'s `if (!str) return 0;` turns into `0`
(full chain in Evidence). So the observationally exact inline test is

```
  ((bits >> 2) & 1) != 0   ->  0      // any embedded constant
  otherwise                ->  resolve + load header.size + zext
```

which is *literally* `expandGetTagMarkers`'s `isConst` chain (`EcoBackend.cpp:1451-1454`)
and is accepted verbatim by `EcoPtrIntVerify::isTagBitTestChain` (`:154-168`: `LShr`,
`And`, `ICmp` in the same BB). LLVM folds `lshr`+`and`+`icmp ne 0` to one `test`/`and`
plus the compare, so the cost difference against a word equality is at most one
instruction on a branch that is predicted-not-taken anyway.

**Rejected alternative (v1's pin): `icmp eq %bits, 0x6`.** It is one instruction, but it
is *not* observationally identical: on a Bool constant (`0x4`/`0x5`) the kernel returns
`0` while the word test falls into the heap arm and dereferences address 4 or 5 — a
segfault, not a wrong number. It also differs from `isEmptyBits` on any non-canonical
`Empty`-tagged word (unrealizable, but the divergence is real). Both divergences are
unreachable for well-typed programs, and the plan requires *no* difference, so the
`ptr_ind` test wins. **Re-open only on evidence:** if a wall A/B ever attributes ≥0.3 %
to this one instruction (leg: hand-patch the expansion to the word test and re-run
Gate 5), switch, and record the type-safety argument that licenses it.

**2a. `EcoToLLVMInternal.h`.**
```cpp
// next to inlineAllocEnabled() (:769-775)
/// kernel-opt-04: expand eco.string.length to the inline header load.
/// Default ON; `ECO_STRING_LEN_INLINE=0` lowers the op to a plain
/// Elm_Kernel_String_length call instead (backend-only A/B leg).
inline bool stringLenInlineEnabled() {
    static const bool enabled = [] {
        const char *e = ::getenv("ECO_STRING_LEN_INLINE");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
}

// in struct EcoRuntime, next to getOrCreateStringCmpOrder (:705)
mlir::LLVM::LLVMFuncOp getOrCreateStringLenInlineMarker(mlir::OpBuilder &) const;
mlir::LLVM::LLVMFuncOp getOrCreateStringLength(mlir::OpBuilder &) const;
mlir::LLVM::LLVMFuncOp getOrCreateStringCodeUnitAt(mlir::OpBuilder &) const;
```
No `layout::` constant is added here: the only consumer of the header-size offset is
`expandStringLenMarkers`, which lives in `EcoBackend.cpp` — a translation unit that does
**not** include `Passes/EcoToLLVMInternal.h` (its includes are `EcoBackend.h`,
`LoweringStats.h`, two pass headers, LLVM/MLIR headers and `../allocator/Heap.hpp`,
:3-60). The constant is therefore defined file-locally in `EcoBackend.cpp` (Phase 2d).

**2b. `EcoToLLVMRuntime.cpp`** (next to `getOrCreateStringCmpOrder`, :946-950; the
`I64_TY`/`I16_TY`/`HPTR_TY` macros are defined at :155-164 and expand to
`IntegerType::get(ctx, …)` / `LLVM::LLVMPointerType::get(ctx, 1)` against the
`EcoRuntime::ctx` member, `EcoToLLVMInternal.h:386`):
```cpp
LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringLenInlineMarker(OpBuilder &b) const {
    // __eco_string_len_inline(ptr as1) -> i64. kernel-opt-04 marker: gc-leaf,
    // declare-only; expanded to the embedded-constant / header-load diamond by
    // expandStringLenMarkers (EcoBackend.cpp) before every RS4GC flavour and
    // before partition splitting, so it never reaches codegen.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(b, "__eco_string_len_inline", funcTy, /*gcLeaf=*/true);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringLength(OpBuilder &b) const {
    // Elm_Kernel_String_length(str: hptr) -> i64. NOT gc-leaf (today's
    // behaviour); used only on the ECO_STRING_LEN_INLINE=0 A/B leg.
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(b, "Elm_Kernel_String_length", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateStringCodeUnitAt(OpBuilder &b) const {
    // eco_string_code_unit_at(str: hptr, index: i64) -> i16. gc-leaf:
    // StringOps::charAt never allocates on any of its six tag paths
    // (StringOps.hpp:410-463 — its only calls are Allocator::resolve),
    // so callers need no rooting.
    auto funcTy = LLVM::LLVMFunctionType::get(I16_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(b, "eco_string_code_unit_at", funcTy, /*gcLeaf=*/true);
}
```
**Mandatory:** add all three to `materializeAllRuntimeDecls` (:1211-1274; put them on the
string line, :1264) — a miss after `freeze()` trips the `assert(!frozen && …)` at
`EcoToLLVMRuntime.cpp:135-137` during parallel Stage 2.

**Ordering note (why pre-materializing a *kernel* symbol is safe):**
`materializeAllRuntimeDecls` runs at `EcoToLLVM.cpp:343`, i.e. **after** serial Stage 0
(:254-324) has already lowered every `is_kernel func.func` stub through
`KernelFuncOpLowering`. So `getOrCreateStringLength` dedups onto the stub-derived decl
when one exists and creates it fresh otherwise; it can never install a conflicting
signature. `getOrCreateUtilsEqual` (:910-913, materialized :1268) is the exact
precedent. Consequence for kernel-opt-08: once this plan lands, `Elm_Kernel_String_length`
is a symbol that `getOrCreateFunc` may materialize without a stub, which is precisely the
case 08's `gcLeafKernels` consult exists to cover — no action needed here, but do not
"simplify" 08 to the stub-only path afterwards.

**2c. `EcoToLLVMHeap.cpp`** — after `ArrayLengthOpLowering` (:1219-1250), before
`ArrayGetOpLowering` (:1256). Constructor signature and `OpConversionPattern(tc, ctx)`
base call copied from `StringCmpOrderOpLowering` (`EcoToLLVMArith.cpp:1117-1132`):
```cpp
//===--------------------------------------------------------------------===//
// eco.string.length -> __eco_string_len_inline marker (expanded pre-RS4GC)
//===--------------------------------------------------------------------===//
struct StringLengthOpLowering : public OpConversionPattern<StringLengthOp> {
    const EcoRuntime &runtime;
    StringLengthOpLowering(EcoTypeConverter &tc, MLIRContext *ctx,
                           const EcoRuntime &rt)
        : OpConversionPattern(tc, ctx), runtime(rt) {}

    LogicalResult
    matchAndRewrite(StringLengthOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = stringLenInlineEnabled()
                      ? runtime.getOrCreateStringLenInlineMarker(rewriter)
                      : runtime.getOrCreateStringLength(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(op, fn,
                                                  ValueRange{adaptor.getStr()});
        return success();
    }
};

//===--------------------------------------------------------------------===//
// eco.string.code_unit_at -> gc-leaf call to eco_string_code_unit_at
//===--------------------------------------------------------------------===//
struct StringCodeUnitAtOpLowering : public OpConversionPattern<StringCodeUnitAtOp> {
    const EcoRuntime &runtime;
    StringCodeUnitAtOpLowering(EcoTypeConverter &tc, MLIRContext *ctx,
                               const EcoRuntime &rt)
        : OpConversionPattern(tc, ctx), runtime(rt) {}

    LogicalResult
    matchAndRewrite(StringCodeUnitAtOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto fn = runtime.getOrCreateStringCodeUnitAt(rewriter);
        rewriter.replaceOpWithNewOp<LLVM::CallOp>(
            op, fn, ValueRange{adaptor.getStr(), adaptor.getIndex()});
        return success();
    }
};
```
Register both next to `StringFromIntOpLowering` (:2107):
```cpp
    patterns.add<StringLengthOpLowering>(typeConverter, ctx, runtime);
    patterns.add<StringCodeUnitAtOpLowering>(typeConverter, ctx, runtime);
```
No `ConversionTarget` edit: `bodyTarget.addIllegalDialect<EcoDialect>()`
(`EcoToLLVM.cpp:405`) already makes every new eco op illegal.

**2d. `EcoBackend.cpp` — `expandStringLenMarkers`.** Place it beside
`expandGetTagMarkers` (:1419-1526) and call it from `runEcoBackend` (:2498) right after
`expandListCursorMarkers(m);` (:2507) — i.e. inside the marker cluster (:2500-2516) that
runs **before** `expandInlineDerefs(m);` (:2517), because its heap arm emits
`__eco_resolve_fwd` calls that pass consumes (ordering discipline documented at
:2500-2506 and, for `__eco_resolve_fwd` itself, at :854-873).

`EcoBackend.cpp` does **not** include `Passes/EcoToLLVMInternal.h`, so
`eco::detail::{value_enc,layout}` are not in scope here. It *does* include
`../allocator/Heap.hpp` (:55) — which is where the file already gets `TAG_BITS`,
`CONSTANT_TAG` and `Elm::Tag_Custom` — so both constants below come from there. Add
`#include <cstddef>` (for `offsetof`) next to the existing `<cstdint>` (:57).

```cpp
// kernel-opt-04. Byte offset of Header::size inside the 8-byte object header.
// HEAP_025/HEAP_032: for EVERY String form this word IS the logical UTF-16
// length. Deliberately NOT the array length offset (8, layout::ArrayLengthOffset)
// — arrays keep their length in a field AFTER the header, so a copy-paste from
// ArrayLengthOpLowering reads the first two UTF-16 chars of a Tag_String leaf.
static constexpr uint64_t kHeaderSizeFieldOffset = offsetof(Elm::Header, size);
static_assert(kHeaderSizeFieldOffset == 4,
              "Header::size moved; expandStringLenMarkers reads it directly");

// Expand each `__eco_string_len_inline` marker into the exact observable
// semantics of Elm_Kernel_String_length (StringExports.cpp:18-27):
//
//   ptr_ind set (ANY embedded constant) -> 0
//       Empty  : the kernel's alloc::isEmptyString guard returns 0 directly.
//       Others : Export::toPtr maps them to nullptr and StringOps::length's
//                `if (!str) return 0;` returns 0 (unreachable for a String).
//   otherwise -> resolve forwarding (HEAP_030) + load u32 at header offset 4
//                + zext to i64   (no per-tag dispatch, HEAP_025/HEAP_032)
//
// The ptr_ind test — not a whole-word `== 0x6` — is what makes this exact: the
// word test would dereference address 4/5 for a Bool constant where the kernel
// returns 0. Chain shape and same-BB discipline are copied verbatim from
// expandGetTagMarkers' isConst (:1451-1454). Marker (not an MLIR diamond)
// because eco.string.length sits inside single-block scf regions — same
// rationale as __eco_get_tag_inline above.
// MUST run before expandInlineDerefs. Idempotent / cheap with no markers.
static void expandStringLenMarkers(Module &m) {
    Function *marker = m.getFunction("__eco_string_len_inline");
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty  = Type::getInt8Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *v = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        // ALL direct users of the ptrtoint stay in THIS block — EcoPtrIntVerify
        // accepts the bit-test chain same-BB only (REP_LLVM_001(d),
        // EcoPtrIntVerify.cpp:154-168); downstream blocks never see `bits`.
        Value *bits = b.CreatePtrToInt(v, i64Ty, "eco.strbits");
        Value *ptrInd = b.CreateAnd(b.CreateLShr(bits, PTR_IND_BIT), 1);
        Value *isConst = b.CreateICmpNE(
            ptrInd, ConstantInt::get(i64Ty, 0), "eco.strconst");

        Instruction *constTerm = nullptr, *heapTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isConst, ci, &constTerm, &heapTerm);
        BasicBlock *contBB = ci->getParent();   // ci now lives in the join block
        BasicBlock *constBB = constTerm->getParent();

        IRBuilder<> hb(heapTerm);
        CallInst *base = hb.CreateCall(fwdMarker, {v}, "eco.strbase");
        Value *szp = hb.CreateGEP(
            i8Ty, base, ConstantInt::get(i64Ty, kHeaderSizeFieldOffset),
            "eco.strszp");
        Value *sz32 = hb.CreateAlignedLoad(i32Ty, szp, Align(4), "eco.strsz");
        Value *sz64 = hb.CreateZExt(sz32, i64Ty, "eco.strlen");
        BasicBlock *heapBB = heapTerm->getParent();

        IRBuilder<> pb(&*contBB->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(i64Ty, 2, "eco.strlen.phi");
        phi->addIncoming(ConstantInt::get(i64Ty, 0), constBB);
        phi->addIncoming(sz64, heapBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandStringLenMarkers: surviving marker use");
    marker->eraseFromParent();
}
```
`PTR_IND_BIT` is the `#define` at `Heap.hpp:221` (value 2), the constant
`value_enc::PtrIndBit` (`EcoToLLVMInternal.h:243`) mirrors. `Elm::Header` is inside
`namespace Elm` (`Heap.hpp:36-756`), so `offsetof(Elm::Header, size)` resolves.

No branch weights: empty strings are common in this workload, and mispredicting the
cold edge costs more than the layout win. (If a later census says otherwise, add
`mdb.createBranchWeights(1, 1u << 4)` favouring the heap arm — `MDBuilder.h` is already
included at :53, and `expandInlineDerefs` sets `!prof !unlikely` on its forwarding
branch, :854-866, as the in-tree precedent.)

**Acceptance:**
- `test/codegen/string_length_structural.mlir` (`-emit=mlir-eco`) shows
  `eco.string.length` surviving eco-to-eco with `CHECK-NOT: Elm_Kernel_String_length`.
- `test/codegen/string_length_forms.mlir` (`-emit=jit`) passes; the same file run with
  `ECO_STRING_LEN_INLINE=0` in the environment prints identical output.
- The expansion leaves no statepoint and no non-leaf call:
  ```
  build/runtime/src/codegen/ecoc test/codegen/string_length_structural.mlir \
      -emit=llvm -o /tmp/k04.ll
  grep -c 'gc.statepoint' /tmp/k04.ll                       # expect 0 in @len
  grep -E 'call .*@(__eco_string_len_inline|Elm_Kernel_String_length)' /tmp/k04.ll  # expect none
  grep -E 'call .*@eco_follow_forward' /tmp/k04.ll          # the ONE cold gc-leaf call
  ```

### Phase 3 — invariants bookkeeping (ships atomically with Phase 2)

Amend FORBID_HEAP_002 (`design_docs/invariants.csv:531`). **CSV mechanics, verified:**
the header (:1) is `id;phase;category;status;description;source` — 6 columns — but the
FORBID_HEAP_002 row already carries one `;` *inside* its description (`…are exempt;
ad-hoc HPointer bit arithmetic…`), so `awk -F';' 'NR==531{print NF}'` prints **7** today.
That is pre-existing and consumers tolerate it because `source` is last; the amendment
must therefore add **no further** `;` (use ` - ` for parentheticals, as the CGEN_074
clause already does). Check with `awk -F';' 'NR==531{print NF}'` before and after: 7 → 7.

**Verbatim replacement row** (one line; the only change vs today is the inserted
`, and the eco.string.length expansion (…)` clause and the two new source ids
`HEAP_025`/`HEAP_032`):

```
FORBID_HEAP_002;Runtime_Heap;ForbiddenAssumptions;enforced;No code may perform arithmetic on HPointer values except via allocator helpers or runtime APIs. The blessed --inline-deref lowering patterns (header tag test + addrspace(1) GEP/load per HEAP_030/031) the inline nursery-allocation expansion (bump-pointer GEP/compare/store per HEAP_034), capacity-check hoisting's two forms (the UNCHECKED bump - as1 GEP + store with no compare - and the ensure diamond's as1 GEP + unsigned compare outside any HEAP_034 diamond, per CGEN_074/HEAP_041), and the eco.string.length expansion (ptr_ind bit test on the HPointer word - every embedded constant yields 0, matching Elm_Kernel_String_length exactly - then the HEAP_030 forwarding diamond + as1 GEP to header byte offset 4 + u32 load + zext to i64 - header.size is the logical UTF-16 length for all six String forms per HEAP_025/HEAP_032 - emitted by expandStringLenMarkers in EcoBackend.cpp) are the codegen equivalent of those runtime APIs and are exempt; ad-hoc HPointer bit arithmetic elsewhere remains forbidden;HEAP_008|HEAP_009|HEAP_025|HEAP_030|HEAP_031|HEAP_032|HEAP_034|CGEN_074|HEAP_041
```

**Acceptance:** `git diff design_docs/invariants.csv` shows exactly this one-line change;
`wc -l design_docs/invariants.csv` still prints 639; `awk -F';' 'NR==531{print NF}'`
still prints 7.

### Phase 4 — `eco.string.code_unit_at` (export + op + lowering; no Elm emission)

**4a. Kernel export** — `elm-kernel-cpp/src/core/StringExports.cpp`, inside the existing
`extern "C" {` block (opened :16), after `Elm_Kernel_String_length` (:18-27). Modelled on
`eco_string_cmp3` (`UtilsExports.cpp:40-47`, rationale comment :31-39), which is why
these live in the kernel layer
rather than `RuntimeExports`: `Export::toPtr`'s full resolution (embedded-constant →
`nullptr`, in-heap → `resolveFast`, else raw rodata pointer) is required for parity, and
`RuntimeExports`' local `hpointerToPtr` is **not** equivalent. `StringOps.hpp` is already
included (:9) and `using namespace Elm;` / `using namespace Elm::Kernel;` are already in
effect (:13-14), so no new includes are needed.
```cpp
// kernel-opt-04. Code unit at a 0-based index; 0 when out of range, when the
// string is an embedded constant, or on a null resolve — exactly
// StringOps::charAt's contract (StringOps.hpp:401-463). gc-leaf-safe: charAt
// allocates on none of its six tag paths (its only calls are
// Allocator::resolve, which follows forwarding and never allocates), so
// callers need no rooting.
uint16_t eco_string_code_unit_at(HPtr str, int64_t index) {
    void* p = Export::toPtr(str.toBits());
    if (!p) return 0;                       // Const_Empty and friends
    return Elm::StringOps::charAt(p, index);
}
```

**4b. Registration checklist** (verified against `elm_array_push_int`'s wiring:
definition `JsArrayExports.cpp:745`, declaration `KernelExports.h:281`, JIT symbol
`RuntimeSymbols.cpp:767`, MLIR factory `EcoToLLVMRuntime.cpp:1013-1016`, pre-materialize
`:1269`):
1. **Definition** — `elm-kernel-cpp/src/core/StringExports.cpp` (above). AOT link needs
   nothing further; the kernel library globs its sources.
2. **Declaration** — `elm-kernel-cpp/src/KernelExports.h`. Put it with the other
   non-`Elm_Kernel_` gc-leaf String exports (`eco_string_cmp3` :192,
   `eco_string_cmp_order` :193, under the comment block :185-191), not in the
   `Elm_Kernel_String_*` block (:107-147): `uint16_t eco_string_code_unit_at(HPtr str,
   int64_t index);`. Both sites sit inside the file-wide `extern "C" {` (:19-571).
3. **JIT symbol map** — `runtime/src/codegen/RuntimeSymbols.cpp`, in the three-way
   compare / `eco_*` group (:734-744, next to `KERNEL_SYM(eco_string_cmp3)` :743):
   `KERNEL_SYM(eco_string_code_unit_at)`. The macro is defined at :583-588 and takes the
   symbol's address, so the declaration from step 2 must be visible. **Do not skip it**,
   and do not trust a green `-emit=jit` run as proof it was added: `EcoJIT` *also*
   installs `DynamicLibrarySearchGenerator::GetForCurrentProcess`
   (`runtime/src/jit/EcoJIT.cpp:344-348`), so a missing map entry can still resolve
   through the host process's dynamic symbol table — and then fail in a build where the
   symbol is internalized or the kernel is linked differently. Verify the entry landed
   directly: `grep -c eco_string_code_unit_at runtime/src/codegen/RuntimeSymbols.cpp`
   → 1.
4. **MLIR decl factory** — `getOrCreateStringCodeUnitAt` (Phase 2b), declared in
   `EcoToLLVMInternal.h` (:705 region) and defined in `EcoToLLVMRuntime.cpp` (:946
   region).
5. **Pre-materialization** — one entry in `materializeAllRuntimeDecls` (:1264).
6. **Lowering pattern + registration** — Phase 2c (`patterns.add<…>` at :2107).

Nothing else: there is no Elm-side op registry to update (the emitter writes op names as
strings — `Ops.elm` builds `"eco.array.length"` literally at :1083), and the dialect
registers `Eco_StringCodeUnitAtOp` from `Ops.td` automatically.

**4c. Ops.td** — beside `Eco_StringLengthOp`:
```tablegen
def Eco_StringCodeUnitAtOp : Eco_Op<"string.code_unit_at", [Pure]> {
  let summary = "UTF-16 code unit at index (GC-LEAF-CALL to StringOps::charAt)";
  let description = [{
    Tag-dispatched over all six String forms; iterative over ropes (deep trees
    cannot blow the C stack). Allocation-free, so the lowered call is gc-leaf and
    callers need no rooting.

    OUT-OF-RANGE AND EMPTY YIELD 0, not a trap — this mirrors StringOps::charAt
    and is a caveat to document, never to "fix": consumers must bounds-check
    against `eco.string.length` first. Result is `i16` (Eco_Char); widening to
    Elm Int is the consumer's job via `eco.char.toInt`.

    ```mlir
    %c = eco.string.code_unit_at %s, %i
    ```
  }];
  let arguments = (ins Eco_Value:$str, Eco_Int:$index);
  let results = (outs Eco_Char:$result);
  let assemblyFormat = "$str `,` $index attr-dict";
}
```

**4d. No Elm emission in this plan.** elm/core has no function that maps to `charAt`
(`String.uncons` allocates a tuple; `String.slice n (n+1)` allocates a view), so an
`Intrinsic` arm here would be dead code. kernel-opt-14 adds the arm when the String
HOFs move to Elm source. State the i16 convention now so it does not get re-litigated.

**Acceptance:** `test/codegen/string_code_unit_at.mlir` passes in JIT mode; the symbol is
in the AOT String archive —
`nm -g build/elm-kernel-cpp/libElmKernel_String.a | grep eco_string_code_unit_at`
(one `T`); and with the op unused the declaration is DCE'd —
`nm build/compiler/build-kernel/bin/eco-compiler | grep -c eco_string_code_unit_at`
is 0 until kernel-opt-14 emits the op.

### Phase 5 — fixtures and tests

All three are auto-discovered by `test/codegen/CodegenIsolatedTest.hpp::discoverTests`
(`directory_iterator` over `*.mlir`, :293-306); the emit mode is parsed out of the
`// RUN:` line (:86-110). No CMake or registry edit.
Note the literal syntax carries its type: `eco.string_literal "x" : !eco.value`
(`string_literal_empty.mlir:8`).

- `test/codegen/string_length_structural.mlir` — `// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s`.
  ```mlir
  module {
    func.func private @len(%s: !eco.value) -> i64 {
      %n = eco.string.length %s
      eco.return %n : i64
    }
    // CHECK-LABEL: @len
    // CHECK: eco.string.length
    // CHECK-NOT: Elm_Kernel_String_length
  }
  ```
  (`eco.return` inside a `func.func private` is the `compare_case_rewrite_structural.mlir:17-28`
  shape.) This pins that no eco-to-eco pass rewrites the op back into a call.
- `test/codegen/string_length_forms.mlir` — `-emit=jit`, `func.func @main() -> i64`
  ending `return %zero : i64` (`string_literal_empty.mlir:6, 42-43`). Kernel decls use the
  `compare_case_rewrite_structural.mlir:13` shape —
  `func.func private @Elm_Kernel_String_append(%a: !eco.value, %b: !eco.value) -> !eco.value attributes {is_kernel = true}`
  and `@Elm_Kernel_String_slice(%s: i64, %e: i64, %str: !eco.value) -> !eco.value`
  (arg order per `StringExports.cpp:56`) — and are invoked in the generic form the other
  fixtures use, `%r = "eco.call"(%a, %b) {callee = @Elm_Kernel_String_append} : (!eco.value, !eco.value) -> !eco.value`
  (`caf_memo_basic.mlir:22`). Results printed with `eco.dbg %len : i64`
  (`arithmetic_int.mlir:19-20`).

  **Building the big forms without hand-writing a 4096-char literal:** write ONE
  128-unit literal and chain `append` doublings; each `%dN = append %d(N-1) %d(N-1)`
  doubles the length. Thresholds are `AllocatorCommon.hpp:94/99/103`.
  - `eco.string_literal "" : !eco.value` → **0** (`Const_Empty`);
  - ASCII `"hello"` → **5** (`Tag_StringUtf8Leaf`);
  - non-ASCII `"λμν"` (UTF-8 bytes `"\CE\BB\CE\BC\CE\BD"`) → **3** (`Tag_String`
    UTF-16 leaf);
  - a 128-unit **non-ASCII** literal doubled 5× → **4096** ≥ 4092 = (8192−8)/2 ⇒
    `Tag_LargeStringHeader` (each intermediate ≤ 32768 flattens to a leaf, so the
    final object is an `allocString` of 4096 units);
  - that 4096 doubled 4× more → **65536** > `STRING_FLATTEN_LIMIT` 32768 ⇒
    `Tag_StringRope`;
  - `slice 10 400` of the 4096-unit string → **390** > `STRING_TINY_SLICE_LIMIT` 128 ⇒
    `Tag_StringSlice`; the same slice of the ASCII doubling chain ⇒
    `Tag_StringUtf8View`.
  If a form is not produced (the tag heuristics are runtime config, not invariants),
  the *length* assertions still hold — do not over-fit the fixture to tags it cannot
  observe from MLIR; the tag coverage is the Elm-level test's job plus
  `ECO_HEAP_VALIDATE`.
- `test/codegen/string_code_unit_at.mlir` — `-emit=jit`; index 0 / mid / last / `-1` /
  `len` / `len+100` on each of the same forms, printed with
  `%i = eco.char.toInt %c : i16 -> i64` (assembly format `Ops.td:2623-2635`) then
  `eco.dbg %i : i64`. Pins **0** for every out-of-range index and for `""`.
- `test/elm/src/StringLengthFormsTest.elm` — auto-discovered; `-- CHECK:` comments in the
  source header and `Debug.log "<tag>" <expr>` in `main`, with
  `import Html exposing (text)` (`CompareEmptyStringTest.elm:1-30` is the template).
  Covers `""`,
  `"hello"`, `"λμν"`, `String.repeat 20000 "ab"` (rope), `String.slice 10 400 big`
  (slice), and `String.left/right`. Also assert `String.length (a ++ b) ==
  String.length a + String.length b` on a rope, which pins the rope header's
  `size = leftLen + rightLen`.

**Acceptance:** all four new fixtures green in `--target full`; the three codegen
fixtures also green with `ECO_STRING_LEN_INLINE=0`.

### Phase 6 — explicitly out of scope

`starts_with` / `ends_with` / `contains` as GC-LEAF-CALL ops (48/5/7 static sites) could
batch on the same plumbing, but kernel-opt-08's declaration stamp may cover them
adequately without new ops. **Decision criterion:** if kernel-opt-08's `eco.gc_leaf`
stamp on those three declarations already un-poisons their callers in the CGEN_072
fixpoint (measure `[gcfree]` coverage before/after), do nothing here; if they remain
poisoned because the *call* itself is the barrier, open a follow-up mirroring Phase 4's
checklist. Decide there, not here. A `hasFolder` on `eco.string.length` over
`eco.string_literal` operands is likewise deferred — **no eco op has a folder today**
(`grep -c hasFolder Ops.td` = 0), so it belongs with kernel-opt-10's folder
infrastructure, not here.

## Traps & risks

- **Array-offset copy trap.** The template (`ArrayLengthOpLowering`) reads a separate
  length field at offset **8** (`layout::ArrayLengthOffset`, `EcoToLLVMInternal.h:352`);
  string length is the header `size` word at offset **4**. A verbatim copy reads the
  wrong word — for a `Tag_String` leaf, offset 8 is the first two UTF-16 chars. The
  `static_assert(kHeaderSizeFieldOffset == 4)` on `offsetof(Elm::Header, size)` in
  `EcoBackend.cpp` (Phase 2d) is the tripwire. Do **not** put that constant in
  `EcoToLLVMInternal.h`: `EcoBackend.cpp` — the only consumer — does not include it.
- **Embedded-constant guard is a `ptr_ind` test, NOT a word equality.** The kernel
  returns `0` for every embedded constant (Empty via `alloc::isEmptyString`, Bool via
  `Export::toPtr`→`nullptr`→`StringOps::length`'s null guard). `icmp eq %bits, 0x6`
  would instead dereference address 4/5 on a Bool constant — a segfault where the kernel
  returns a number. Use the `expandGetTagMarkers` chain
  (`CreateAnd(CreateLShr(bits, PTR_IND_BIT), 1)` + `CreateICmpNE(…, 0)`,
  `EcoBackend.cpp:1451-1454`). LLVM folds it to one `and`+`icmp`, so the "one instruction
  instead of three" argument for the word test does not survive contact with the
  optimizer. v1's justification for the word test — that `Export::toPtr` routes a raw
  non-heap pointer with bit 2 set down the header-read path (`ExportHelpers.hpp:49-56`
  says exactly that) — describes an **unrealizable** input: every String struct is
  `ALIGN(8)` (`Heap.hpp:393, 406, 418, 432`) and `HPointer.ptr` is documented as an
  "absolute, 8-byte-aligned heap address … its low 3 bits are 0" (`Heap.hpp:195-198`),
  so bit 2 is always 0 for a real pointer. Both tests agree on
  every realizable pointer; only the `ptr_ind` one also agrees on the constants.
- **Assert-only divergence, recorded.** The kernel's
  `assert(ptr && "…unexpected null pointer")` is live in the standard build
  (`build` preset sets `-UNDEBUG`, `CMakePresets.json:34-35`). A non-Empty constant
  reaching `Elm_Kernel_String_length` aborts; the inline op returns 0 silently.
  Unreachable for well-typed programs; do not "fix" it by adding a trap to the inline
  path — that reintroduces the branch this plan deletes.
- **Forwarding.** Mutator-visible `Tag_Forward` occurs during old-gen incremental
  compaction; the heap arm must take the HEAP_030 diamond via `__eco_resolve_fwd`
  (`eco_follow_forward` is gc-leaf). Exercise under `ECO_HEAP_VALIDATE` with compaction
  active.
- **Expansion ordering.** `expandStringLenMarkers` emits `__eco_resolve_fwd` calls, so
  it MUST run before `expandInlineDerefs` (`EcoBackend.cpp:2517`) and therefore before
  capacity hoisting (:2519+), `expandInlineAllocs` (:2550), partition splitting and every
  RS4GC flavour. Put it in the marker cluster at :2500-2516, right after
  `expandListCursorMarkers(m);` (:2507).
- **Same-block ptrtoint.** `EcoPtrIntVerify::isTagBitTestChain`
  (`EcoPtrIntVerify.cpp:154-168`) accepts a `ptrtoint ptr<1>` only when every direct user
  is `LShr/And/ICmp/Select/Trunc/ZExt` in the *same* basic block. Compute `ptrInd` and
  `isConst` before the split and never let a successor block touch `bits`.
- **Marker must not survive.** `report_fatal_error` on residual uses plus
  `marker->eraseFromParent()` (the `expandListProjMarker` discipline, :1233-1235;
  `expandGetTagMarkers`' own at :1523-1526).
  A surviving `__eco_string_len_inline` would fail to link — there is no such symbol in
  `RuntimeSymbols.cpp` and none is wanted.
- **Frozen symbol cache.** Any `getOrCreateFunc` miss after `freeze()` is parallel-Stage-2
  UB and asserts (`EcoToLLVMRuntime.cpp:135-137`). All three new factories go into
  `materializeAllRuntimeDecls`.
- **Do not add tag dispatch.** The temptation to "be safe" with per-tag branches recreates
  the cost being deleted; HEAP_025/HEAP_032 are the license for the unconditional load.
  The op is only reachable with a String-typed operand (the intrinsic requires
  `argTypes == [ Mono.MString ]`); a hand-written fixture passing a non-String is UB,
  exactly as for `eco.array.length`.
- **`[Pure]` and mutability.** Sound only while strings are immutable after construction.
  If an in-place string builder is ever added, revisit both traits FIRST (the
  `Eco_StringCmpOrderOp` note, `Ops.td:2751-2757`).
- **i16 result width.** `StringOps::charAt` returns `u16`; `eco.string.code_unit_at`
  returns `i16` (`Eco_Char`) and consumers must widen explicitly via `eco.char.toInt`.
  Fix this convention now so kernel-opt-14 builds on it. (The `Elm_Kernel_Char_*`
  widened-*parameter* trap — `CharExports.cpp:16-26`, "receiving the parameter as
  `uint64_t` forces a full-register read" — applies to parameters under statepoints; our
  index is `int64_t` and the 16-bit value is a *return*, so no widening is needed. The
  in-tree precedent for a 16-bit-returning gc-leaf export is `eco_array_get_i16`
  (`RuntimeExports.h:683`, declared `int16_t`); C signedness is immaterial at the LLVM
  `i16` boundary, but the `KernelExports.h` declaration and the `StringExports.cpp`
  definition must use the *same* spelling — pick `uint16_t` for both.)
- **Residual `String_length` calls are expected and fine.** Bare
  `Elm.Kernel.String.length` references (PAP/closure form) keep the kernel path.
  The self-compile has zero of them today; other corpora may not.
- **Config hash / cache.** `stringLengthOp` is artifact-affecting. Forgetting the `hash`
  token means flag-on builds silently reuse flag-off `.eco` artifacts — the classic
  false-negative A/B. Also: the E2E harness binary cache is mtime-blind, so flag-on legs
  need the touch discipline (memory: eco-lss-design).
- **Stale census / GC-trigger lottery.** Phase 0 re-baseline; record major-GC counts with
  every wall number.
- **Build discipline.** Always `--target full`, never `check` (stale `.mlir`).

## Dependencies

- **Blocks:** kernel-opt-14's String-HOF phase (needs `code_unit_at` + `length`).
- **Feeds a decision in:** kernel-opt-08 (whether `starts_with`/`ends_with`/`contains`
  need ops or just the gc-leaf declaration stamp) — Phase 6.
- **Interacts with kernel-opt-07/08:** once every `String_length` call site is gone, the
  `is_kernel` stub disappears from the module and with it the place kernel-opt-08 would
  stamp `eco.gc_leaf` (the single declaration attr both 08 and 09 consume — there is no
  second attr). `KernelFacts` (`compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, keyed
  `(home, name)`) should still carry a row for `("String", "length")`:
  `params`/`resultAliases` unchanged from today's `KernelSigs` axes,
  `callTimeEffect = EffNone`, `gcAlloc = GcNone`, `cppAlloc = False`,
  `callsBackIntoElm = False`, `cseSafe = True`, `totality = Total`,
  `divergence = Nothing`,
  `evidence = "elm-kernel-cpp/src/core/StringExports.cpp:18-27"`. (`gcLeafEligible`,
  `droppable` and `hoistable` are all derived, never stored.) Keep the row because the
  PAP form survives, because `getOrCreateStringLength` can still materialize the decl on
  the `ECO_STRING_LEN_INLINE=0` leg, and because the facts table is the documentation of
  record.
- **Synergy, not dependency:** `[Pure]` on `eco.string.length` makes repeated length
  loads CSE/folder-visible to kernel-opt-10/13; kernel-opt-05 shares the typed-intrinsic
  emission plumbing but neither blocks the other.
- **Unblocked now:** items 01, 02, 04, 05, 06 are mutually independent.
- **External:** `--inline-deref` / `ExpandInlineDeref` infrastructure (HEAP_030;
  `expandInlineDerefs` doc :854-873, body from :874, call site :2517 in
  `EcoBackend.cpp`) — already default-on.

## Expected impact

Honest: 75.6M calls is **2.06 %** of the 3.68B dynamic kernel calls, and the prior is
brutal — the gc-leaf pilot covered 64.1 % of dynamic calls and measured wall-FLAT, as did
three other statepoint/metadata-only removals. **Expect wall FLAT to sub-1 %, and say so
up front.** What distinguishes this from the flat-wall series and what it actually buys:
(i) it deletes the *call itself*, replacing call + statepoint + callee prologue +
`Export::decode`/`toPtr` + null guard with ~6 inline instructions (ptrtoint, and, icmp,
branch, GEP, load, zext — LLVM folds the shift into the mask — plus the
predicted-not-taken forward check) at the hottest string op —
deleted per-op work, the mechanism that has moved wall before (inline nursery −9.6 %, CAF
memoization −11.7 %, `$cap`-inlining −14.5 %, K6 hash-consing −5.07 %), just at small
dynamic volume; (ii) it un-poisons callers in the CGEN_072 gc-free fixpoint
(`bodyIsGCCallFree`, `EcoBackend.cpp:1595-1609`) — after expansion the only remaining
callee is the gc-leaf `eco_follow_forward`, so functions whose *only* kernel call was
`String_length` become stampable, with transitive statepoint relief; (iii) a `[Pure]` op
that CSE can dedupe where today every `String.length` is an opaque call; (iv)
`code_unit_at` is the prerequisite for kernel-opt-14's HOF rewrites, which delete the
`std::vector<u16>` snapshot (`StringExports.cpp:220-233`) + per-char closure applies —
the genuinely large per-op-work deletion this item enables. Effort **S**: cheap enough
that the enabling value alone justifies it even at flat wall.

## Gates

Run tests ONCE, tee to a file, grep the file. Never re-run to re-read.

1. **Structural + behavioural fixtures.**
   ```
   TEST_FILTER=codegen cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
   grep -E 'string_length|string_code_unit_at|FAIL' /tmp/test_output.txt
   ```
2. **Full E2E** (never `check` — codegen changed):
   ```
   cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
   grep -E 'FAIL|Falsifiable|passed|failed' /tmp/test_output.txt | tail -40
   ```
   Both legs: flag off (must be identical to baseline) and `ECO_STRING_LENGTH_OP=1`.
   Existing pins that must stay green: `CompareEmptyStringTest.elm`,
   `CompareStringTest.elm`, `CaseStringEmptyPatternTest.elm`,
   `EmbeddedReturnEmptyStringTest.elm`, `StringConsDynamicTest.elm`,
   `JsonEncodeBigStringTest.elm` (rope/large forms).
3. **Heap-validate tree** — specifically with forwarding/compaction exercised against the
   new inline diamond. There is **no** validate preset (`cmake --list-presets`: dev /
   build / release / mac-* / win-*), and `--preset` pins `binaryDir`, so configure the
   separate dir explicitly with the `build` preset's cache variables
   (`CMakePresets.json:22-37`) plus the option from `CMakeLists.txt:84-90`:
   ```
   cmake -S /work -B /work/build-val -G Ninja \
     -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
     -DCMAKE_EXE_LINKER_FLAGS_INIT=-fuse-ld=lld \
     -DCMAKE_SHARED_LINKER_FLAGS_INIT=-fuse-ld=lld \
     -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG" \
     -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG" \
     -DECO_HEAP_VALIDATE=ON
   ECO_STRING_LENGTH_OP=1 cmake --build /work/build-val --target full 2>&1 | tee /tmp/val_output.txt
   grep -E 'FAIL|assert' /tmp/val_output.txt | head -40
   ```
   Baseline: the last recorded validate-suite number is 1623/1623 (memory:
   heap-validate-suite-rot); kernel-opt-08 quotes 1632/1632 for the same gate. **Record
   the number this build actually reports before the change and compare against that** —
   do not assume either figure.
4. **Bootstrap fixed point** — `cmake --build build --target bootstrap 2>&1 | tee
   /tmp/bootstrap.txt` (target at `compiler/CMakeLists.txt:1026`), whose Stage 8c does a
   binary byte-compare on Linux (:546-587; the ELF-compare branch is :578-586). Output
   changes legitimately when the flag is on, so the flag-on run is a bootstrap to a
   **NEW** fixed point: the first flag-on build differs from the flag-off binary, and
   Stage 8c must still close (`eco-compiler-boot == eco-compiler-boot-2`). Because the
   flag ships default-off, the flag-on leg is
   `ECO_STRING_LENGTH_OP=1 cmake --build build --target bootstrap` — and note every stage
   from 5 onward must see the same value, so export it for the whole build, and expect a
   full re-run (the hash token `strlen=1` invalidates `~/.eco` artifacts by design).
   With the flag off, byte-identity to the pre-change binary is required — that is the
   inertness gate.
5. **Wall A/B with major-GC counts.** Cold Stage 7a, 2×2 interleaved minimum, outputs
   byte-compared, ±0.3 % noise floor stated
   (`plans/kernel-call-census.md` §C2.4). Three legs are cheap and worth running:
   flag-off, flag-on, flag-on + `ECO_STRING_LEN_INLINE=0` (isolates
   "call deleted" from "op inlined").
6. **Dynamic census rerun** (re-apply the `ECO_KERNEL_CALL_CENSUS` patch,
   `plans/kernel-call-census.md` §C1): `Elm_Kernel_String_length` → **0** in the
   self-compile (any residue must be a PAP/closure site, named); total kernel calls down
   ≈75.6M.
7. **Static census.** Re-run Phase 0's `--text-mlir` command with
   `ECO_STRING_LENGTH_OP=1` and `--output=/tmp/k04-on.mlir`, then:
   ```
   grep -c 'callee = @Elm_Kernel_String_length' /tmp/k04-on.mlir   # expect 0
   grep -c 'sym_name = "Elm_Kernel_String_length"' /tmp/k04-on.mlir # expect 0
   grep -c '"eco.string.length"' /tmp/k04-on.mlir                  # expect ~92
   ```
   (Baseline on `build/compiler/build-kernel/bin/aggp-solver.mlir`, 2026-08-03: 92 / 1 /
   0, with all 92 in the saturated `(!eco.value) -> i64` form and zero PAP forms.)
8. **Invariants diff.** `git diff design_docs/invariants.csv` contains exactly the
   FORBID_HEAP_002 amendment of Phase 3 and nothing else.
