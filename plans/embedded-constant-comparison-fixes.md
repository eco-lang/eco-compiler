# Fix Embedded-Constant Handling in Comparison and Sort Kernels

## Goal

Eliminate the two remaining classes of embedded-constant mishandling in the
runtime kernel:

- **F2**: `Utils::compareUnboxableSlot` mis-orders `Const_Nil` (and would mis-order
  any future comparable constant) when one slot is the constant and the other a
  heap value. Reaches every tuple/record/cons-head compare that contains a
  `List` (or in the future, any other comparable type with an embedded
  representation for its minimum value).
- **F3**: `Elm_Kernel_List_sortBy` calls `Allocator::resolve` on the
  user-extracted key without an `isConstant` guard, asserting / aborting when
  the key is `""` or `[]`.

`Elm_Kernel_Utils_equal` / `notEqual` (F1) were fixed already by the
`equalRespectingConstants` helper at
`elm-kernel-cpp/src/core/UtilsExports.cpp:47-56`; the full E2E run confirms
all `Equality*` and `NotEqual*` tests pass on the value axis after that change.
The Bool `==` tests (`EqualityBool{Test,IfTest,CaseTest,VarTest,Pap,…}`) now
print correct values; only `EqualityBoolPapTest` still reports FAILED, and the
"Actual output" lines show the values are right — the test's CHECK pattern
just uses no-space list syntax. That's an in-tree test-data issue, addressed
in this plan alongside the kernel fixes.

## Failing tests on `main` after the F1 fix

| Test | Symptom | Root cause |
|---|---|---|
| `CompareTupleWithEmptyListTest` | `compare (0, []) (0, [1])` → GT (expected LT); all 5 Nil-vs-heap cases inverted | F2 |
| `CompareTupleWithEmptyListNestedTest` | same in `((0, []), 1)` and `(0, [], "x")` | F2 |
| `CompareNestedEmptyListTest` | bug fires in `Tag_Cons` heads: `compare [[]] [[1]]` → GT | F2 |
| `OrderingTupleWithEmptyListTest` | `(0, []) < (0, [1])` → False; all 12 ordering ops invert | F2 (via `Utils::lt/le/gt/ge`) |
| `SortByTupleWithEmptyListTest` | sortBy with `(parity, listOrEmpty)` key → permutation `[2, 4, 1, 3]` instead of `[4, 2, 3, 1]` | F2 (top-level key is heap Tuple2 so F3 doesn't fire; tiebreaker on field 2 is wrong) |
| `DictTupleListKeyTest` | `Dict.keys` order puts Nil-keyed entry last; `Dict.get (0, [])` still works | F2 (Dict ordering via `compare`) |
| `SetTupleListKeyTest` | same Set ordering | F2 |
| `SortByAlwaysEmptyStringKeyTest` | SIGABRT in `Allocator::resolve` | F3 |
| `SortByEmptyStringKeyMixedTest` | SIGABRT | F3 |
| `SortByIdentityEmptyStringTest` | SIGABRT | F3 |
| `SortByDerivedEmptyStringTest` | SIGABRT | F3 |
| `SortByAlwaysEmptyListKeyTest` | SIGABRT | F3 |
| `SortByEmptyListKeyMixedTest` | SIGABRT | F3 |
| `SortByIdentityEmptyListTest` | SIGABRT | F3 |
| `SortByDerivedEmptyListTest` | SIGABRT | F3 |
| `SortEmptyStringInListTest` | SIGABRT (`List.sort` = `sortBy identity`) | F3 |
| `SortEmptyListInListTest` | SIGABRT | F3 |
| `EqualityBoolPapTest` | CHECK pattern miss (values are correct) | pre-existing test-data formatting |

All 18 of these failures come from exactly two kernel sites + one stale CHECK
pattern.

## Decisions (resolved)

- **F1 fix is the style template**. Existing
  `equalRespectingConstants(uint64_t aBits, uint64_t bBits)` in the export TU
  guards `Utils::equal`'s entry point without restructuring the core
  `void*`-taking `cmp` / `eqHelp`. Apply the same pattern at every other
  affected export site rather than reworking `Utils::cmp`'s ABI.
- **F2 fix is intrinsically in `Utils.cpp`** because the bug is a fallback
  inside `compareUnboxableSlot`. There is no export-side knob to flip. Keep
  the change *local* to that function and the existing EmptyString
  special-case ladder.
- **The two comparable embedded constants (`Const_Nil`, `Const_EmptyString`)
  are the minimum value of their type, and no further comparable embedded
  constants are planned.** Elm semantics: `[] < x::xs`, `"" < c++cs`. The
  F2 fix encodes that rule directly and removes the
  `a.p.constant < b.p.constant` byte fallback. The "both constants but
  different families" branch is unreachable under well-typed Elm; mark it
  `assert(false && "..."); __builtin_unreachable();` per the codebase
  convention (`RuntimeExports.cpp:1194-1195` is the canonical example).
- **`isString` already covers every string representation**
  (`HeapHelpers.hpp:1415-1419` — `Tag_String / Tag_StringSlice /
  Tag_StringRope / Tag_LargeStringHeader`), and `header.size` is the
  logical UTF-16 length on each. The existing `EmptyString`-vs-heap-string
  canonicalisation (`Utils.cpp:181-194`) therefore equates an
  `Const_EmptyString` with a size-0 string in any of those four forms —
  no additional work needed.
- **F3 fix is local to `Elm_Kernel_List_sortBy`**. The comparator at
  `ListExports.cpp:607-615` is the only site that calls
  `allocator.resolve(keys[i])` on a user-supplied (potentially-constant) key.
  `Utils::cmp`'s top of `cmp` already handles `nullptr` correctly via the
  early returns — the guard at the call site is sufficient.
- **F2 + F3 + test-data cleanup land in one commit.** They're a single
  conceptual fix (embedded constants flow correctly through `compare`),
  and the test suite from the prior cycle was authored to gate exactly
  this change.
- **Acceptance gates**: full `elm/` E2E goes from 18 → 0 failures; stress
  baseline stays at 99/99 (pre-existing accepted flake remains
  `MVarBlockingReadAwaitsPutStress`).

## Background / grounding (file:line citations)

- **F1 already-landed fix**:
  `elm-kernel-cpp/src/core/UtilsExports.cpp:47-64`
  (`equalRespectingConstants` + the two callers).
- **F2 site**:
  `elm-kernel-cpp/src/core/Utils.cpp:155-200` — `compareUnboxableSlot`. The
  buggy fallback is at line 195: `return a.p.constant < b.p.constant ? -1 : 1;`
  Existing EmptyString special-case is at lines 181-194.
- **F2's caller graph**: `cmp` at `Utils.cpp:202-372` invokes
  `compareUnboxableSlot` in three places:
    - `Tag_Tuple2` at line 263-269 (field 0) and line 273-275 (field 1)
    - `Tag_Tuple3` at lines 285-292 (each of three fields)
    - `Tag_Cons` at line 310 (the head field; Nil-tail still goes through the
      `isNil` early-exit)
- **F2 propagation**: `Utils::lt/le/gt/ge` (declared in `Utils.hpp:58-73`,
  defined in `Utils.cpp:687-700`) all call `cmp`, so they inherit the bug.
  `Elm_Kernel_Utils_lt/le/gt/ge/compare` exports
  (`UtilsExports.cpp:66-80, 12-15`) propagate it to the user-visible
  operators. `Dict`/`Set` from `elm-core` use `compare` internally — the bug
  surfaces as wrong tree order whenever any key field is `[]`.
- **F3 site**: `elm-kernel-cpp/src/core/ListExports.cpp:607-615` — the
  `std::stable_sort` comparator inside `Elm_Kernel_List_sortBy`. Lines 610-611
  hit `allocator.resolve(keys[a])` / `keys[b]` unconditionally.
- **`Allocator::resolve` assert**:
  `runtime/src/allocator/Allocator.cpp:736` — `assert(ptr.constant == 0 && …)`.
  This is the assertion the SIGABRTs hit. `RelWithDebInfo` keeps it active via
  `-UNDEBUG` (CMakePresets.json:15-17).
- **Existing constant-aware helper for reference**:
  `Utils::resolveAndCompare` at `Utils.cpp:86-103` already does
  `if (alloc::isConstant(ap) || alloc::isConstant(bp))` and returns an early
  comparison result. F2's fix can reuse this helper directly — it's already
  called from `compareUnboxableSlot` at line 173, the bug is what the code
  does on `eq == false`.
- **Constant numbering** (sanity-check for the F2 minimum-value rule):
  `runtime/src/allocator/Heap.hpp` — `Const_Unit=0, Const_EmptyRecord=1,
  Const_True=2, Const_False=3, Const_Nil=4, Const_Nothing=5,
  Const_EmptyString=6` (HPointer.constant field stores `Const_* + 1`).
- **Tests already in place**: 39 new tests under `test/elm/src/`, listed in the
  failing-tests table above and in the prior /pqn report. Of those, 18 fail
  on `main`; the rest are regression guards that pass today and must keep
  passing.

## Plan

### Phase 1 — F2: fix `compareUnboxableSlot` to honor Elm's minimum-value semantics

1. **`elm-kernel-cpp/src/core/Utils.cpp:170-199`** (`compareUnboxableSlot`,
   `default:` branch — the boxed-HPointer slot path):

   Replace the existing post-`resolveAndCompare` ladder. The new structure:

   ```cpp
   default: {
       void* ao; void* bo; bool eq;
       if (resolveAndCompare(allocator, a.p, b.p, &ao, &bo, &eq) == 0) {
           if (eq) return 0;
           bool aConst = alloc::isConstant(a.p);
           bool bConst = alloc::isConstant(b.p);

           // Canonicalisation: Const_EmptyString must compare equal to a
           // heap-resident String of size 0 (any of the four string forms
           // covered by alloc::isString: leaf / slice / rope / large header).
           // header.size carries the logical UTF-16 length on all of them.
           constexpr unsigned EmptyStringTag = Const_EmptyString + 1;
           if (aConst && a.p.constant == EmptyStringTag && !bConst) {
               void* bo2 = allocator.resolve(b.p);
               if (bo2 && alloc::isString(bo2)) {
                   return static_cast<Header*>(bo2)->size == 0 ? 0 : -1;
               }
           }
           if (bConst && b.p.constant == EmptyStringTag && !aConst) {
               void* ao2 = allocator.resolve(a.p);
               if (ao2 && alloc::isString(ao2)) {
                   return static_cast<Header*>(ao2)->size == 0 ? 0 : 1;
               }
           }

           // The two comparable embedded constants — Const_EmptyString and
           // Const_Nil — are the minimum value of their type. A const-vs-heap
           // comparison is LT or GT depending on which side is the constant.
           if (aConst && !bConst) return -1;
           if (!aConst && bConst) return 1;

           // Both sides are constants AND resolveAndCompare reported eq=false
           // (different constant families). Unreachable in well-typed Elm —
           // any comparable-typed value pair shares one constant family,
           // and no other comparable embedded constants are planned.
           assert(false &&
                  "compareUnboxableSlot: cross-family constant comparison "
                  "is unreachable in well-typed Elm");
           __builtin_unreachable();
       }
       return cmpFn(ao, bo);
   }
   ```

   Net change vs current code:
   - Two new branches inserted (`aConst && !bConst → -1`,
     `!aConst && bConst → 1`) before the formerly-buggy fallback.
   - Old fallback `return a.p.constant < b.p.constant ? -1 : 1;` removed.
     The dead branch is replaced with the codebase-standard
     `assert(false && "..."); __builtin_unreachable();` idiom — debug-time
     assertion fires with a clear message, release builds get zero-cost UB
     telling the compiler this branch can't happen.

2. **Rewrite the comment block at `Utils.cpp:175-178`**. Replace the current
   "raw constant-bit ordering only agrees with Elm semantics when both share
   the same constant family" wording (which describes the bug, not the
   correct behaviour) with the minimum-value justification used in the new
   code. Suggested new comment, attached to the `if (aConst && !bConst)`
   pair:

   ```cpp
   // Elm's two comparable embedded constants — Const_EmptyString ("")
   // and Const_Nil ([]) — represent the minimum value of their type.
   // Per Elm semantics, "" < any non-empty String and [] < any non-empty
   // List, so a const-vs-heap comparison is LT (constant side) or GT
   // (heap side). The EmptyString canonicalisation above handles the
   // edge case where the heap value is itself an empty string.
   ```

3. **No header / public-API changes**. `cmpFn` signature unchanged; `cmp`'s
   call sites unchanged. `Utils::lt/le/gt/ge/compare` and the kernel
   exports inherit the fix automatically.

### Phase 2 — F3: guard `List.sortBy`'s comparator against constant keys

4. **`elm-kernel-cpp/src/core/ListExports.cpp:607-615`**: replace the
   comparator's resolve-pair with constant-aware decoding.

   ```cpp
   std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
       // Keys come from a user closure and may be embedded constants
       // (Const_EmptyString or Const_Nil — the only comparable constants).
       // Allocator::resolve asserts on constants, so check first.
       void* keyA = alloc::isConstant(keys[a]) ? nullptr
                                                : allocator.resolve(keys[a]);
       void* keyB = alloc::isConstant(keys[b]) ? nullptr
                                                : allocator.resolve(keys[b]);
       HPointer orderHP = Utils::compare(keyA, keyB);
       Custom* order = static_cast<Custom*>(allocator.resolve(orderHP));
       return order->ctor == 0;  // LT
   });
   ```

   Rationale: `Utils::cmp`'s top of function (`Utils.cpp:204-207`) already
   does `if (!a && !b) return 0; if (!a) return -1; if (!b) return 1;`. So
   passing nullptr for a constant key produces the correct top-level Elm
   semantics. `orderHP` returned by `Utils::compare` is always a heap-allocated
   Order singleton, so `allocator.resolve(orderHP)` is safe.

5. **Confirm no sibling site has the same shape**. Grep for `keys[`+resolve in
   the kernel; sortWith uses `Export::encode(aRoot)` to pass values to the
   user comparator without ever resolving, so it's already safe (and its
   regression-guard tests pass).

### Phase 3 — Stale CHECK-pattern cleanup

6. **`test/elm/src/EqualityBoolPapTest.elm`** — update the `-- CHECK:` lines
   to match Elm's `Debug.toString` list formatting (space after comma):

   - `isTrueList: [True,False,True,False]` → `isTrueList: [True, False, True, False]`
   - `isFalseList: [False,True,False,True]` → `isFalseList: [False, True, False, True]`
   - `filterTrue: [True,True]` → `filterTrue: [True, True]`
   - `filterFalse: [False,False]` → `filterFalse: [False, False]`

   The values these lines assert are already correct in the actual output;
   the test only "fails" because of the formatting mismatch.

7. **No other pre-existing tests** show this pattern in the current run —
   confirmed by `grep "Missing pattern:" /tmp/test_full.txt`. (The new tests
   I added in the previous pass already use the spaced format.)

### Phase 4 — Regression coverage

8. **No new tests required**. The 39 tests added in the previous /pqn cycle
   already cover the exact failure modes this plan fixes:
     - F2: 7 tests (`Compare*EmptyList*`, `Ordering*EmptyList*`,
       `Dict*ListKey*`, `Set*ListKey*`, `SortByTupleWithEmptyList*`)
     - F3: 10 tests (`SortBy*EmptyString*`, `SortBy*EmptyList*`,
       `SortEmpty*InList*`)
     - Plus regression guards on currently-correct paths that must keep
       passing (Compare/Ordering top-level constants,
       CompareTupleWithEmptyString, OrderingTupleWithEmptyString,
       SortByTupleWithEmptyString, SortWithCompareEmpty*).

   Acceptance gate: full `TEST_FILTER=elm/` E2E run goes from 18 failures →
   0 failures.

9. **Stress-test sweep**: `cmake --build build --target stress-elm-runner`
   (or whichever target runs `test/stress-elm/main.cpp`) — verify no
   regression in the property-based suite. Dict/Set operations across
   randomised tuple keys with `[]` fields are the most likely amplifier of
   F2; with the fix in place this should be quieter, not noisier.

10. **Bootstrap sanity**: `cmake --build build --target full` runs the
    bootstrap chain through Stage 6 implicitly via the
    `MLIR_EQUIV_BOOTSTRAP_DEPS`. If anything in the compiler self-compile
    depends on the buggy Nil ordering (e.g., a `Dict` keyed on something
    containing `[]`), the bootstrap will rebuild against the corrected
    comparator. Watch for any new bootstrap failures.

### Phase 5 — Documentation

11. **`design_docs/invariants.csv`**: add or update one invariant capturing
    the Elm semantics now relied on in the kernel:

    ```
    REP_COMPARE_CONST_001,
    "Comparable embedded HPointer constants (Const_EmptyString, Const_Nil) are
    the minimum value of their type. compareUnboxableSlot must return -1 when
    a is the constant and b is heap, +1 when reversed.",
    ...
    ```

    Numbering should follow whatever the latest REP_COMPARE_* slot is
    (current invariants.csv inspection required at fix time).

12. **`THEORY.md`** — under the equality/ordering discussion (if there is
    one; otherwise no change), point to the constant ladder semantics. Skip
    if there's no natural place; this is small enough to live as an
    invariant alone.

## Risk / blast radius

- **F2 change is one function**, behind a guard that only fires when at
  least one slot is an embedded constant. Cannot regress heap-vs-heap
  comparisons. The only behavioural delta is for `(…, [])` vs `(…, x::xs)`
  patterns — previously GT, now LT — which is the intended fix.
- **F3 change is one closure** inside `Elm_Kernel_List_sortBy`. Cannot
  regress sortWith, sortBy with non-constant keys, or sort of non-list
  inputs.
- **No ABI or layout change**. No header bits moved. No new kernel
  function. No invariant on the SSA / Heap / Logical reps disturbed.
- **`Dict`/`Set` data already on disk?** Dict/Set are constructed at
  runtime from `Dict.fromList`/`Set.fromList`; no persisted-on-disk format
  to migrate.

## Rollout

- Make F2 and F3 changes in one commit (they're a single conceptual fix —
  embedded constants flow correctly through `compare`-using paths).
- Run `TEST_FILTER=elm/ cmake --build build --target full` to confirm
  18 → 0 failures.
- Run the stress suite (Phase 4 step 9) — current baseline per memory is
  99/99 healthy stress E2Es; should stay at 99/99 or improve.
- Push and rebuild bootstrap chain through Stage 7 if the user wants the
  cross-check.

## Open questions

None outstanding — all seven questions resolved during /pqn review:

1. ~~Other comparable embedded constants planned?~~ — No. The minimum-value
   rule is final; the cross-family branch is provably dead under well-typed
   Elm and uses `assert(false); __builtin_unreachable();`.
2. ~~`isString` covers `Tag_StringSlice`?~~ — Confirmed by inspection at
   `HeapHelpers.hpp:1415-1419`: covers `Tag_String`, `Tag_StringSlice`,
   `Tag_StringRope`, and `Tag_LargeStringHeader`. `header.size` is the
   logical UTF-16 length on all four. Existing `EmptyString`
   canonicalisation is sound; no extra work.
3. ~~Update `EqualityBoolPapTest` CHECK strings vs teach the matcher to
   normalise?~~ — Update the test data (Phase 3).
4. ~~`assert(false)` vs `eco_crash` vs remove?~~ — Remove the dead branch
   per codebase convention: `assert(false && "..."); __builtin_unreachable();`
   (matches `RuntimeExports.cpp:1194-1195` etc.). `eco_crash` is for
   runtime-reachable error paths; this one isn't reachable.
5. ~~Rewrite the misleading comment at `Utils.cpp:175-178`?~~ — Yes, Phase 1
   step 2 specifies the replacement wording.
6. ~~Stress baseline?~~ — 99/99 confirmed; `MVarBlockingReadAwaitsPutStress`
   remains the only accepted pre-existing flake.
7. ~~One commit or two?~~ — One commit. F2 + F3 + Phase 3 test-data update
   land together.
