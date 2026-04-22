# Test Failures

Baseline (2026-04-22):
- elm-test: 12799/12799 pass, 0 fail
- E2E: 1117/1122 pass, 5 fail

Current state (2026-04-22 re-run after prior fixes):
- elm-test: 12799/12799 pass, 0 fail
- E2E: 1123/1123 pass, 0 fail (added DictRemoveMinimalTest as repro aid).

## Order (best-to-tackle first)

1. ArrayAppendCanonicalTest — FIXED
2. ArrayAppendRepeatedTest — FIXED
3. DecodeArrayShapeTest — FIXED
4. DictUnionDiffIterTest — FIXED
5. DictFromListToListRoundtripTest — FIXED

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

## 3. DictFromListToListRoundtripTest — FIXED

Root cause: ECO's structural equality (`Utils.cpp eqHelp`) compared
two Customs by tag + field-wise walk. For `Dict`, this is a tree-shape
comparison: two dicts with identical key/value sets but different
insertion orders (and therefore different LLRB tree shapes) compared
as unequal. Stock Elm JS avoids this by marking Dict/Set ctors with
negative `$` tags and branching to `Dict.toList` comparison in
`_Utils_eqHelp`.

Fix (compiler + runtime):

Compiler — new `Compiler.Data.CtorTag` module exposing reserved tag
constants and an `effective` helper that returns
`0xFFFF` for `Dict.RBNode_elm_builtin`, `0xFFFE` for
`Dict.RBEmpty_elm_builtin`, and `Index.toMachine` otherwise. Wired
through:
- `Compiler.Monomorphize.Analysis.buildCtorShapeFromUnion` (for the
  type table entries and for `MonoCtor` shape construction via
  `computeCtorShapesForGraph`).
- `Compiler.Monomorphize.Specialize.specializeNode` for the
  `TOpt.Ctor` and `TOpt.Enum` specialisation paths so the tag baked
  into `MonoCtor`/`MonoEnum` shape/tag fields matches.
- `Compiler.Generate.MLIR.Patterns.generateMonoTest` and
  `testToTagInt` so pattern matches check the same reserved tag.

Runtime — `elm-kernel-cpp/src/core/Utils.cpp` gained `CTOR_DICT_RBNODE`
/ `CTOR_DICT_RBEMPTY` constants that mirror the compiler's reserved
tags, plus a new `dictEq` that walks both trees in lockstep via
iterative in-order traversal (left spine stacks) and compares the
yielded key/value pairs with `eqUnboxableSlot`. The `Tag_Custom` path
in `eqHelp` dispatches to `dictEq` whenever either side's ctor is a
Dict marker. Colour field is ignored — it varies with insertion order
but doesn't affect set membership.

Also updated `RuntimeExports.cpp` `print_typed_value` Custom case to
locate `EcoCtorInfo` by a linear search for the matching `ctor_id`
instead of indexing `ctors[first_ctor + ctor_id]`. The old code
assumed `ctor_id < ctor_count` which no longer holds for
runtime-recognised types with reserved tags.

Attempts: 1 (successful)

## 4. DictUnionDiffIterTest — FIXED

Root cause: **Tail-recursion lowering in
`compiler/src/Compiler/Generate/MLIR/TailRec.elm` did not use
short-circuit evaluation for chains of pattern tests.** The old
`compileCaseChainStep` called `Patterns.generateMonoChainCondition`,
which emits all test ops upfront and ANDs the i1 results together.
Path navigations in later tests therefore executed regardless of
whether earlier guards held.

For `Dict.getMin` (compiled as an scf.while tail-recursive loop), the
condition of the loop body is `dict.tag == RBNode AND dict.left.tag ==
RBNode`. With the eager lowering, `project.custom(dict, field=3)`
(i.e. `dict.left`) executes even when `dict` is the `RBEmpty`
embedded constant. Reading "field 3" of an embedded constant produces
a garbage `!eco.value`; subsequent `eco.get_tag` → `resolve()` then
dereferences an invalid heap offset (raw=0x140000-style) → SIGSEGV in
`Elm::Allocator::resolve`.

Evidence chain:
1. gdb backtrace from the child process shows crash in
   `Allocator::resolve` called from `eco_get_tag`.
2. MLIR for `Dict_getMin_$_32` (text dump) contains an scf.while whose
   body computes `eco.project.custom(%dict, field_index=3)` and
   `eco.get_tag` on the result BEFORE the `eco.case` that checks
   whether `%dict` is an RBNode.
3. Minimal Elm repro `Dict.remove 1 (Dict.insert 2 20 (Dict.singleton
   1 10))` crashes — matches: removal in a 2-element tree reaches
   `getMin`, which loops with `dict=RBEmpty` after one step.
4. `Expr.generateChainGeneralWithJumps` in the non-tail path already
   uses the correct short-circuit nesting ("Multi-test chain:
   short-circuit by nesting remaining tests inside the first test's
   'then' branch"), but `TailRec.compileCaseChainStep` did not.

Fix: rewrote `compileCaseChainStep` to recurse on the test chain,
nesting each subsequent test inside the preceding test's "then"
region (`[] → go to success`, `firstTest :: restTests → eco.case on
firstTest with then = compileCaseChainStep restTests`). This mirrors
the non-tail-recursive path and restores short-circuit semantics.

Attempts: 1 (successful)

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
