# Test Failures

Baseline (2026-04-22):
- elm-test: 12799/12799 pass, 0 fail
- E2E: 1117/1122 pass, 5 fail

## Order (best-to-tackle first)

1. ArrayAppendCanonicalTest — suspected tree-shape / equality bug
2. ArrayAppendRepeatedTest — likely same root cause as #1
3. DictFromListToListRoundtripTest — dict equality / tree-shape
4. DictUnionDiffIterTest — SIGSEGV, likely related to dict ops
5. DecodeArrayShapeTest — SIGABRT with bad HPointer (JSON/Array decoding issue)

---

## 1. ArrayAppendCanonicalTest — FIXED

Root cause: `Elm_Kernel_JsArray_appendN` in
`elm-kernel-cpp/src/core/JsArrayExports.cpp` used
`toCopy = min(n, srcLen)` but Elm semantics require
`toCopy = min(n - destLen, srcLen)` (cap total tail at `n`,
not source copy count). This caused appendN to copy too many
src items when dest already had some, producing over-long
tails that broke `unsafeReplaceTail`'s invariant.

Fix: compute `available = n - destLen` (clamped to 0) and use
`toCopy = min(available, srcLen)`.

Attempts: 1 (successful)

## 2. ArrayAppendRepeatedTest — FIXED

Same root cause as #1 (appendN bug). Fixed by same change.

Attempts: 1 (successful, same fix as #1)

## 3. DictFromListToListRoundtripTest — SKIPPED

Root cause: Stock Elm JS has a special case in `_Utils_eqHelp` that
detects Dict/Set (via `$ < 0` negative ctor tag marker) and compares
via `Dict.toList` instead of tree-shape structural equality. ECO's
runtime equality (Utils.cpp `eqHelp`) lacks this special case, so
two Dicts with identical content but different insertion-order-derived
tree shapes compare as unequal.

Verified: manually traced Elm's LLRB `insertHelp`/`balance` for
ascending vs descending key inserts — they produce DIFFERENT tree
shapes. Stock Elm JS hides this because `==` on Dict converts both
sides to sorted `toList` before comparing. Confirmed by running the
same test in stock Elm: all three checks return True.

A proper fix requires:
1. Compiler-side: mark Dict.RBNode_elm_builtin / RBEmpty_elm_builtin
   ctor tags with a reserved bit or ID range (analogous to Elm JS's
   negative-ctor convention).
2. Runtime-side: in Utils.cpp `eqHelp`, detect the marker and compare
   via in-order tree walk (key-value pair list).

Duck-typing at runtime (ctor==0 + 5 fields pattern) is fragile: user
types with matching shape would false-positive. Safe detection needs
compiler cooperation.

Deferring: significant architectural change out of scope for the
isolated test-fix loop. Test failure is a known semantic gap.

Attempts: 0 (skipped without attempt due to architectural complexity)

## 4. DictUnionDiffIterTest — SKIPPED

Root cause: Crash is in `Dict.remove` (called by `Dict.diff`). Stack
shows `eco_get_tag → Allocator::resolve` with a bad HPointer
(observed: raw=0x140000, which is an unusually-small offset
inconsistent with other live pointers seen during the same run).

Isolation: Reduced to the minimal repro `Dict.remove 1 (Dict.insert 2 20
(Dict.singleton 1 10))` — crashes. `Dict.remove 1 (Dict.singleton 1 10)`
works (returns RBEmpty). `Dict.remove 99 d` works. `Dict.get`/`insert`/
`size` all work. Failure only on removal of an *existing* key in a
tree with 2+ elements.

Dict's `moveRedLeft`/`moveRedRight` compiles to deeply nested
`eco.project.custom` + `eco.get_tag` + `eco.case` chains. Replicating
the same pattern shapes in a user-defined Tree type did NOT crash,
ruling out pattern-match codegen in isolation.

Likely subtle issues with:
- GC root tracking across the many safepoints in the nested cases
- ABI / boxing of `NColor` or comparable values across the deep call
  chain (Dict.remove → removeHelp → removeHelpPrepEQGT → moveRedLeft
  / moveRedRight → balance)
- Some compiler pass mis-handling a specific combination of deep
  nested patterns + `as` binding + recursive self-calls

Root cause not conclusively identified from MLIR inspection; no
single ABI-level fix is obvious. Needs further deep dive (LLVM IR
inspection, gdb with source symbols, stackmap validation).

Attempts: 0 (skipped without attempt; needs deeper runtime debugging)

## 5. DecodeArrayShapeTest — FIXED

Root cause: `DEC_ARRAY` in `elm-kernel-cpp/src/json/JsonExports.cpp`
returned a bare `ElmArray` (Tag_Array JsArray) directly from the
decoder, but Elm's `Json.Decode.array : Decoder a -> Decoder (Array a)`
must yield an `Array a` value — i.e. the `Array_elm_builtin Int Int
(Tree a) (JsArray a)` Custom, not just its underlying JsArray tail.

Downstream `Array.length`/`Array.get`/`==` project Custom fields
(field 0 = length, field 3 = tail) from what they believe is an
`Array_elm_builtin`, but actually got an `ElmArray`. Reading field 0
of an ElmArray returns `elements[0]` (an HPointer to the first decoded
element). That HPointer was then used as an Int (the length) or
passed to `resolve`, producing `raw=0x100000007`-style bad pointers.

Secondary bug: `u32 len = arr->header.size` uses the JsArray's
capacity field instead of its `length` field. For a JSON-parsed array
these happen to match (via `arrayFromPointers`), but the code should
clearly use `arr->length`.

Fix: rewrite the `DEC_ARRAY` case to
1. Determine the element kind (Int / Float / boxed) from the element
   decoder, matching the representation `Array.fromList` would produce
   for structural `==` to hold against the original.
2. Partition decoded elements into fixed-size leaves (branchFactor=32)
   + a remainder tail, following Array.elm's `builderToArray`.
3. Build `Leaf` Node Customs (`ctor = 1`, the second ctor of Node) for
   each leaf JsArray; build the tree JsArray of Nodes.
4. Wrap with `Array_elm_builtin` Custom (`ctor = 0`, 4 fields, unboxed
   bitmap `0x5` for the two unboxed Int fields `length`/`startShift`).

All root sets are pushed/popped across allocations to keep HPointers
live across GC.

Attempts: 1 (successful)
