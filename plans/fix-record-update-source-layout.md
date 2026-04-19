# Fix Record Update: Use Source Record Layout + Widen Result MonoType

## 1. Problem Restatement

For an update like `\r -> { r | a = -r.a }` specialized through a polymorphic
wrapper (e.g. `applyNTimes : Int -> (a -> a) -> a -> a`), the monomorphizer
sometimes narrows the update node's result type to `MRecord { a : Int }` even
though the actual runtime record is `{ a, b, c }`.

Two distinct issues cooperate to corrupt memory:

- **Codegen** (`Compiler/Generate/MLIR/Expr.elm`, `Mono.MonoRecordUpdate` case):
  `generateRecordUpdate` derives the layout from the *result type* (`monoType`).
  When `monoType` is narrowed to `{ a }`, MLIR emits a 1-field
  `eco.construct.record`. Later `project.record` for `b`/`c` reads past the
  footprint into the following heap object.
- **Monomorphization** (`Compiler/Monomorphize/Specialize.elm`,
  `TOpt.Update` branch): the stored `MonoRecordUpdate`'s `MonoType` is taken
  from `meta.tipe` + the call-site substitution, not reconciled with the
  more concrete `recordMonoType = Mono.typeOf monoRecord`. So shape loss in
  the substitution leaks into the IR.

The failing repro is `RecordUpdateList` / `RULMinimal`; `b`/`c` are clobbered
after the update.

## 2. Design Goals

1. For `{ r | a = ... }`, the heap layout of the produced record must always
   match the *source* record's layout.
2. The `MonoRecordUpdate` node's `MonoType` is never *narrower* (fewer fields)
   than the type of the input record.
3. Align with how `MonoRecordAccess` / `MonoField` already derive layout from
   the expression's own type.
4. No runtime or GC changes.

## 3. Step-by-Step Plan

### Change A — MLIR codegen uses the source record's type

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Location:** `generateExpr`, `Mono.MonoRecordUpdate` case (around line 419).

Replace:

```elm
Mono.MonoRecordUpdate record namedUpdates monoType ->
    let
        layout =
            Types.computeRecordLayout (getRecordFields monoType)
        ...
    in
    generateRecordUpdate ctx record indexedUpdates layout monoType
```

With:

```elm
Mono.MonoRecordUpdate record namedUpdates monoType ->
    let
        recordType =
            Mono.typeOf record

        layout =
            Types.computeRecordLayout (getRecordFields recordType)

        indexedUpdates =
            List.filterMap
                (\( name, updateExpr ) ->
                    ListX.find (\fi -> fi.name == name) layout.fields
                        |> Maybe.map (\fi -> ( fi.index, updateExpr ))
                )
                namedUpdates
    in
    generateRecordUpdate ctx record indexedUpdates layout monoType
```

Rationale: matches `MonoRecordAccess`'s use of `Mono.typeOf record`, so the
emitted `construct.record` always has the same `fieldCount` /
`unboxedBitmap` as the source record. `generateRecordUpdate` itself is
unchanged — it already ignores `monoType` (`_`).

### Change B — Reconcile result type in specialization

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Location:** `specializeExpr`, `TOpt.Update` branch (around line 2308–2356).

Keep the existing computation of `monoType`, `recordMonoType`, `monoUpdates`.
Before the final tuple, introduce `resultMonoType`:

```elm
resultMonoType =
    case ( recordMonoType, monoType ) of
        ( Mono.MRecord recordFields, Mono.MRecord resultFields ) ->
            -- Dict.union is left-biased: prefer resultFields on overlap
            -- (they've gone through forceCNumberToInt via meta.tipe),
            -- fall back to recordFields for keys missing in resultFields.
            Mono.forceCNumberToInt (Mono.MRecord (Dict.union resultFields recordFields))

        ( Mono.MRecord _, _ ) ->
            -- Record expression with non-record result type is a compiler bug;
            -- TOpt.Update on a non-record is not type-correct.
            Utils.Crash.crash "Specialize.TOpt.Update: record with non-record result type"

        ( _, _ ) ->
            -- Similarly, updating a non-record should be impossible post type-check.
            Utils.Crash.crash "Specialize.TOpt.Update: input expression is not a record"
```

Return `Mono.MonoRecordUpdate monoRecord monoUpdates resultMonoType`.

Rationale:
- The result type never drops fields present on the input record.
- Left-biased union prefers `resultFields` on overlap: those came from
  `meta.tipe` + `forceCNumberToInt` and so are the normalized source of
  truth for per-field types (numeric constraints etc.). Missing keys fall
  back to the concrete `recordFields`.
- We re-apply `Mono.forceCNumberToInt` on the merged record to preserve
  the monomorphization postcondition that no `CNumber` vars leak into
  stored result types (in case `recordFields` re-introduced one).
- Non-record inputs/outputs in `TOpt.Update` are type-check-impossible,
  so we crash rather than silently fall back — consistent with other
  impossible cases in `Specialize`.

**Optional debug assertion:** for overlapping keys, assert
`resultFields[k] == recordFields[k]`. Disagreements indicate an upstream
type inconsistency worth surfacing. Can be gated behind a debug flag if
the equality check is expensive on large records.

### Change C — Tests

Split by responsibility:

**Mono invariant test** — add alongside existing `MONO_017` / `MONO_018`
style checks:
- For every `MonoRecordUpdate` node, assert
  `Dict.keys rFields ⊆ Dict.keys resFields` where
  `rFields = Mono.typeOf record` (if `MRecord`) and
  `resFields = resultType` (if `MRecord`).
- This is cheap (set comparison), directly guards the class of bug, and
  plugs into the existing invariant-test framework.
- Implement in the same change set as the fix.

**Runtime end-to-end regression** — live with the existing `stress-elm`
cases so it exercises Mono + MLIR + JIT + runtime together:
- Distilled `RULMinimal` kept in-tree — `{ a, b, c }`, `applyNTimes`,
  `\r -> { r | a = -r.a }`; assert `b = 2`, `c = 3` preserved and `a`
  toggles.
- Row-polymorphic variant — a function of type
  `{ r | a : Int } -> { r | a : Int }` invoked via a polymorphic wrapper on
  both `{ a }` and `{ a, b, c }` records; both shapes must survive.
- Keep the original `RecordUpdateList` → `roundtrip: True`.

**Run the regular suites:**
- `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
- `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`

## 4. Invariants / Reasoning

- **REP_HEAP / CGEN record invariants:** unchanged — `fieldCount` and
  `unboxedBitmap` still come from a single layout computation, just sourced
  from the input record's type. This restores the invariant that the
  produced record shares the source record's layout.
- **Specialization:** Change B only widens (or leaves unchanged) the stored
  `MonoType`. It never narrows; existing passes that read the result type
  become more precise, not less. `forceCNumberToInt` is re-applied post
  merge so no `CNumber` vars escape into the result type.
- **CGEN_018 (empty record shortcut):** unaffected. `layout.fieldCount == 0`
  can only happen when the source record type is itself empty; an empty
  update set on a non-empty record still produces a non-empty layout and
  runs the normal fold. Returning the original `recordResult` when
  `fieldCount == 0` remains correct.
- **New MonoRecordUpdate shape invariant:** `keys(typeOf record) ⊆
  keys(resultType)` — enforced by construction by Change B, checked by the
  new invariant test.
- **ResolveAccessorValues / GlobalOpt / LocalOpt:** traverse
  `MonoRecordUpdate` but don't rely on the narrowed result type; widening
  is at worst neutral.
- **Backend / runtime:** only Change A changes emitted MLIR. Change B is a
  type-level consistency fix.

## 5. Files to Modify

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | `Mono.MonoRecordUpdate` case — layout from `Mono.typeOf record`. Keep `monoType` param on `generateRecordUpdate` (unused, `_`) for signature symmetry with other generators. |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | `TOpt.Update` branch — compute `resultMonoType` (merge + `forceCNumberToInt`, crash on non-record) and use it in the returned `MonoRecordUpdate`. |
| Compiler Mono invariant test module (alongside MONO_017/018 tests) | New `MonoRecordUpdate` shape-subset invariant. |
| `stress-elm` tests | `RULMinimal` + row-polymorphic variant; keep `RecordUpdateList`. |

## 6. Success Criteria

1. `RecordUpdateList` prints `roundtrip: True`.
2. `RULMinimal` and variants pass (b/c preserved, a toggles).
3. No regressions in `elm-test-rs` or `cmake --build build --target full`.
4. Emitted MLIR for record updates has `field_count` equal to the source
   record's field count, with projections for untouched fields.

## 7. Resolved Decisions (from design review)

1. **Merge bias.** Keep `Dict.union resultFields recordFields` (left-biased on
   `resultFields`). Rationale: `resultFields` came via `meta.tipe +
   forceCNumberToInt`, so they are the normalized source of truth; on a
   well-typed `Update` the two sides must agree on overlapping keys anyway.
   Optionally add a debug-build assertion that overlapping entries are
   equal, to surface real type inconsistencies early.
2. **Non-`MRecord` `recordMonoType`.** Hard crash (`Utils.Crash.crash`).
   Updating a non-record is type-check-impossible; silent fallback would
   mask upstream bugs. Matches the style used elsewhere in `Specialize` for
   impossible cases.
3. **Unused `monoType` parameter on `generateRecordUpdate`.** Keep for
   uniformity with other generators. `_` suppresses warnings; removing it
   is gratuitous churn.
4. **Mono invariant test.** Implement now, in the same change set. It is
   cheap, directly guards the bug class, and plugs into the existing
   MONO_017/018-style framework.
5. **CGEN_018 shortcut.** Unaffected. `layout.fieldCount == 0` only occurs
   for an actually-empty record type; switching to source-record layout
   doesn't change that.
6. **Re-apply `forceCNumberToInt`.** Yes. After `Dict.union`, call
   `Mono.forceCNumberToInt` on the merged `MRecord` so no `CNumber` vars
   re-enter the result type.
7. **Test placement.** Split:
   - Shape invariant → Mono invariant test module (next to MONO_017/018).
   - Runtime repro (`RULMinimal`, row-polymorphic variant, existing
     `RecordUpdateList`) → `stress-elm` end-to-end suite.
