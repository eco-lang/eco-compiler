# Runtime & Kernel C++ GC Rooting Audit

## Goal

Systematically audit every C++ allocation site in Eco's runtime, Elm kernel,
and Eco kernel for GC-safety, codify the two rooting patterns as reusable
templates, and apply targeted fixes wherever a boxed `HPointer` (or an
`Unboxable` with a boxed field) can survive across a GC-capable call without
being visible to the collector.

The end state: every call to `Allocator::allocate` (and every helper that
transitively allocates) is either called with only unboxed arguments or has
its boxed arguments rooted on the stack for the duration of the call.

### Relationship to the MLIR-side audit

This plan is distinct from `plans/gc-liveness-audit-pass.md`. That one
audits compiled SSA roots and safepoints attached by `EcoGCPrepare`; this
one audits hand-written C++ rooting in the runtime and kernels. The two
touch different code, fail in different ways, and can land independently.
A short "C++ vs MLIR roots" pointer should be added to both plans so
readers of either know the other exists.

## Context (what already exists)

### Rooting primitives

- `runtime/src/allocator/RootSet.hpp` / `RootSet.cpp`: core API —
  `pushStackRoot(HPointer*)`, `stackRootPoint()` /
  `restoreStackRootPoint(size_t)`, `pushStackRootRange`, global
  `addRoot` / `removeRoot`.
- `runtime/src/allocator/HeapHelpers.hpp`:
  - `Elm::StackRootGuard` RAII helper (overloads for 1..4 `HPointer*`
    arguments, lines 58–95). Does not accept `nullptr` slots today —
    Step 1.1 adds a new `initializer_list<HPointer*>` overload that
    does, while keeping the fixed-arity overloads for hot paths.
- `runtime/src/allocator/RuntimeExports.cpp` exposes C-ABI wrappers
  `eco_gc_push_stack_range`, `eco_gc_stack_range_point`,
  `eco_gc_restore_stack_range_point` for JIT/IR use.

### Already-safe helpers in `HeapHelpers.hpp`

Confirmed already rooting internally (do not re-wrap at call sites):

| Helper | Rooting strategy |
|---|---|
| `cons` (l.419) | `pushStackRoot(&tail)` + `&head.p` if boxed |
| `tuple2` (l.498) | `pushStackRoot` per boxed slot |
| `tuple3` (l.523) | `pushStackRoot` per boxed slot |
| `custom` (l.552) | copies to `rooted_values`, pushes each boxed slot |
| `record` (l.632) | same as `custom` |
| `listFromPointers` (l.442) | copies to `rooted`, roots `result` + each element |
| `arrayFromPointers` (l.750) | copies to `rooted`, roots each element |
| `allocTask` (l.943) | `StackRootGuard(&value, &callback, &kill, &innerTask)` |
| `allocProcess` (l.964) | `StackRootGuard(&root, &stack, &mailbox)` |
| `just`, `ok`, `err`, `stackFrame` | delegate to `custom` (already safe) |

### Helpers that take no boxed arguments (inherently safe)

`allocInt`, `allocFloat`, `allocChar`, `allocString(...)` (two overloads
plus `allocStringFromUTF8`), `allocByteBuffer(data, len)`,
`allocByteBufferZero(len)`, `allocArray(capacity)` (capacity-only;
returns empty array), `arrayFromInts`, `listFromInts`, `listFromFloats`,
`allocClosure(evaluator, max_values)` (no captures yet) — none of these
receive `HPointer` arguments, so no rooting is required inside them. They
may still need rooting **at their call sites** if the caller holds boxed
locals live across the call.

### Known-unsafe or unknown sites

- **`ListOps.cpp` (753 lines, 31 `alloc::*` calls, 0 `pushStackRoot` /
  `StackRootGuard` occurrences).** Collect-then-build functions (`map`,
  `indexedMap`, `filter`, `filterMap`, `append`, `concat`, `intersperse`,
  `take`, `partition`, `unzip`, `sortBy`, `sortWith`, …) build a
  `std::vector` in phase 1 and iterate it in phase 2 calling `alloc::cons`.
  Phase 2 is unsafe: elements in the vector and the accumulator are not
  visible to GC. Same risk in `ListOps.hpp` inline helpers.
- **`StringOps.cpp` / `StringOps.hpp`, `BytesOps.cpp` / `BytesOps.hpp`.**
  Neither file uses `pushStackRoot` or `StackRootGuard`. Per the design
  doc, each has direct `Allocator::allocate` calls (to be re-verified —
  grep for `Allocator::instance().allocate` returned 0 in `.cpp` files but
  the `.hpp` files have not been scanned yet). Collect-then-build patterns
  likely exist (e.g. `String.split`, `Bytes.toList`).
- **`RuntimeExports.cpp` (2696 lines, 34 direct allocates, 35
  `eco_gc_push_stack_range` calls).** Uses C-ABI root ranges for JIT
  arguments. Needs audit to confirm every new `HPtr` local added later
  sits inside the range, or gets its own guard.
- **`runtime/src/main.cpp` test helpers** `allocateInt`, `allocateConsInt`,
  `allocateRecord`, `updateRootRecord` — per design doc, mostly unrooted
  demo code. Lowest priority.
- **Elm kernel C++** (`elm-kernel-cpp/src/**`): 22 files listed in design
  doc §5.5 touch the allocator directly. Prime suspects for direct
  `Allocator::allocate` and collect-then-build: `JsonExports.cpp`,
  `BytesExports.cpp`, `core/List.cpp`, `core/ListExports.cpp`,
  `core/String.cpp`, `core/StringExports.cpp`, `core/JsArray.cpp`,
  `core/BasicsExports.cpp`, `core/Utils.cpp`.
- **Eco kernel C++** (`eco-kernel-cpp/src/eco/**`): per design doc §5.6,
  mostly thin wrappers over `alloc::*`; `File.cpp`, `MVarExports.cpp`,
  `Runtime.cpp` flagged for direct allocator use.

## Two patterns (codified)

### Pattern 1 — Root across a GC-capable call

Use around any `Allocator::allocate` (or transitive allocator) that copies
existing `HPointer` / boxed `Unboxable` arguments into the new object.

- **Template A** — manual `pushStackRoot` / `restoreStackRootPoint`. Use
  when the root set depends on runtime conditions (e.g. `is_boxed` flags).
- **Template B** — `Elm::StackRootGuard` RAII. Use when all slots are
  unconditionally pointers.

### Pattern 2 — GC-safe collect-then-build

Phase 1 (collect): traverse into a `std::vector<Unboxable>` /
`std::vector<HPointer>`. Phase 2 (build):

1. Copy the collected vector into a local `rooted` (to get stable
   addresses).
2. `pushStackRoot(&result)` for the accumulator.
3. For each boxed element, `pushStackRoot(&rooted[i].p)` (or `&rooted[i]`
   if it's an `HPointer`).
4. Walk `rooted` in reverse, calling `alloc::cons` / `alloc::tuple*`.
5. `restoreStackRootPoint(saved)`.

`alloc::listFromPointers` (l.442) is the canonical reference
implementation.

## Plan

### Step 1 — Land reusable helper infrastructure (mandatory)

Before touching call sites, extend `HeapHelpers.hpp` with a small, fixed
set of reusable primitives. **All subsequent steps MUST route through
these helpers**; hand-rolled `stackRootPoint` / `pushStackRoot` /
`restoreStackRootPoint` triples or hand-rolled loops over `alloc::cons`
are not permitted in new or edited code after this step lands.

The helpers live in `runtime/src/allocator/HeapHelpers.hpp`, next to
`cons`, `tuple2/3`, `custom`, `record`, `listFromPointers`, so they are
discoverable from one place.

1.1. **`StackRootGuard` — initializer-list constructor (additive).**

Keep the existing 1..4-argument overloads — they are already used,
trivial, and zero-cost, and the compiler will continue to pick them for
small static root sets. Add one new overload that accepts a
heterogeneous list of `HPointer*` and silently skips `nullptr` entries,
for call sites that have > 4 locals or a dynamic/conditional set:

```cpp
class StackRootGuard {
public:
    // existing 1..4 overloads kept verbatim ...

    StackRootGuard(std::initializer_list<HPointer*> roots) {
        auto& rs = Allocator::instance().getRootSet();
        savedPoint_ = rs.stackRootPoint();
        for (HPointer* r : roots) {
            if (r != nullptr) rs.pushStackRoot(r);
        }
    }
    // destructor unchanged
};
```

Call sites become:

```cpp
Elm::StackRootGuard guard{ &a, &b, z_boxed ? &z.p : nullptr };
```

This subsumes Template A (conditional rooting) and Template B (all-
pointer rooting) from the design doc in a single type, while preserving
the cheapest form for the common 1..4-fixed-slot case.

1.2. **`StackRootRangeGuard` — RAII for `pushStackRootRange`.**

For contiguous buffers (`std::vector<HPointer>`, `HPtr[N]` arrays,
shadow-stack arg frames), add an RAII wrapper around the existing
`RootSet::pushStackRootRange` / `stackRangePoint` /
`restoreStackRangePoint` API:

```cpp
class StackRootRangeGuard {
public:
    StackRootRangeGuard(HPointer* base, size_t count, uint64_t hpointer_mask) {
        auto& rs = Allocator::instance().getRootSet();
        saved_ = rs.stackRangePoint();
        rs.pushStackRootRange(base, count, hpointer_mask);
    }
    ~StackRootRangeGuard() {
        Allocator::instance().getRootSet().restoreStackRangePoint(saved_);
    }
    StackRootRangeGuard(const StackRootRangeGuard&) = delete;
    StackRootRangeGuard& operator=(const StackRootRangeGuard&) = delete;
private:
    size_t saved_;
};
```

Usage:

```cpp
std::vector<HPointer> elems = ...;
uint64_t mask = (elems.size() >= 64)
    ? ~0ULL
    : ((1ULL << elems.size()) - 1);
Elm::StackRootRangeGuard guard(elems.data(), elems.size(), mask);
// safe allocations that reference elems[i] here
```

This is the C++-side counterpart to the JIT-side
`eco_gc_push_stack_range` / `eco_gc_restore_stack_range_point` pattern
already used in `RuntimeExports.cpp`; consolidating the two under a
single RAII abstraction makes Step 4 a syntactic rewrite rather than
a semantic review.

1.3. **`alloc::listFromUnboxables` — canonical collect-then-build.**

The hot-spot type for `ListOps`, `StringOps`, `BytesOps`, and many
kernel modules is `std::vector<std::pair<Unboxable, bool>>` where
`second` is `is_boxed`. Add a single rooted build-phase helper:

```cpp
namespace Elm { namespace alloc {

inline HPointer listFromUnboxables(
        std::vector<std::pair<Unboxable, bool>>& elems) {
    HPointer result = listNil();
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();

    rs.pushStackRoot(&result);
    for (auto& [val, is_boxed] : elems) {
        if (is_boxed) rs.pushStackRoot(&val.p);
    }
    for (auto it = elems.rbegin(); it != elems.rend(); ++it) {
        result = cons(it->first, result, it->second);
    }

    rs.restoreStackRootPoint(saved);
    return result;
}

}} // namespace Elm::alloc
```

After this lands, every `ListOps` collect-then-build function (`map`,
`indexedMap`, `filter`, `filterMap`, `append`, `concat`,
`intersperse`, `take`, `partition`, `unzip`, `sortBy`, `sortWith`, …)
collapses to a straight-line "collect into vector; return
`listFromUnboxables(v)`".

1.4. **`alloc::listFromContainer` — DEFERRED until a second caller
exists.**

A generic converter template

```cpp
template<typename T, typename Converter>
HPointer listFromContainer(std::vector<T>& elems, Converter&& toUnboxable);
```

that delegates to `listFromUnboxables` is attractive in principle, but
speculative abstraction without a real second caller. Do not land it in
Step 1. Revisit during Step 6 (Elm kernel sweep): if two or more
kernel sites naturally want "container → `(Unboxable, bool)` → list"
(prime candidate: `JsonExports.cpp` with `std::vector<HPointer>`), add
`listFromContainer` at that point as a thin wrapper over
`listFromUnboxables` and migrate those call sites together.

Until then, kernels with `std::vector<HPointer>` call
`alloc::listFromPointers` (already rooted), and kernels with
`std::vector<std::pair<Unboxable, bool>>` call `listFromUnboxables`
directly.

1.5. **Retire the unrooted `ListOps.hpp::fromVector` template.**

The existing `fromVector` in `ListOps.hpp` builds a list via an
unrooted `cons` loop. As part of Step 2, either:

- migrate all its call sites to `listFromUnboxables` /
  `listFromPointers` and delete `fromVector`, or
- (only if Step 1.4's `listFromContainer` has already landed)
  re-implement `fromVector` as a one-line call to
  `listFromContainer`.

1.6. **Publish Patterns 1 and 2 as doc-comments** at the top of
`HeapHelpers.hpp`. The two rules (see §"Coding rules" below) are
copied verbatim into those comments so future contributors can't miss
them.

Deliverable: builds clean, no behavior change. No call site edits yet
— Step 1 is helper-land only.

## Coding rules (enforced from Step 2 onward)

These rules become mandatory for every edited or new C++ file in the
runtime, Elm kernel, and Eco kernel. Reviewers enforce them; the
Step-8 detection query flags violations.

**Rule 1 (Pattern 1 — root across GC-capable calls).** Any helper that
stores existing `HPointer`s or boxed `Unboxable` slots into a freshly
allocated object must either:

- (a) call a centralized `alloc::*` helper in `HeapHelpers.hpp` whose
  internal implementation already roots (`cons`, `tuple2`, `tuple3`,
  `custom`, `record`, `just`, `ok`, `err`, `stackFrame`,
  `listFromPointers`, `arrayFromPointers`, `allocTask`,
  `allocProcess`), or
- (b) wrap the boxed locals in a `StackRootGuard` (≤ ~8 slots) or
  `StackRootRangeGuard` (contiguous buffer) for the lifetime of the
  allocation.

Raw `Allocator::allocate` calls outside `HeapHelpers.hpp` are
permitted only when all stored fields are unboxed primitives or
newly-initialized memory.

**Rule 2 (Pattern 2 — collect-then-build lists from containers).**
Kernel/runtime C++ that constructs an Elm list from a pre-collected
batch of values MUST use one of:

- `alloc::listFromPointers` (input: `std::vector<HPointer>`), or
- `alloc::listFromUnboxables` (input:
  `std::vector<std::pair<Unboxable, bool>>`), or
- `alloc::listFromContainer` (input: any `std::vector<T>` plus a
  converter lambda) — **only after Step 1.4 lands in response to a
  confirmed second caller**.

Hand-rolled loops over `alloc::cons` across a `std::vector` are
forbidden. Existing such loops are rewritten in Steps 2–7.

**Rule 3 (no hand-rolled `pushStackRoot` triples).** New or edited
code must not open-code the `stackRootPoint()` /
`pushStackRoot()`/…/`restoreStackRootPoint()` sequence. Use
`StackRootGuard` or `StackRootRangeGuard`. The handful of existing
open-coded triples inside `HeapHelpers.hpp` (`cons`, `tuple2/3`,
`custom`, `record`, `listFromPointers`, `arrayFromPointers`) are
tolerated because they *are* the well-reviewed core; everything else
routes through them.

### Step 2 — Fix `ListOps.cpp` / `ListOps.hpp`

Highest-impact single file: 31 allocating calls, 0 rooting today, central
to real programs.

2.1. Walk every function in order (see §5.2.1 of the design doc for the
  function list: `map`, `indexedMap`, `filter`, `filterMap`, `append`,
  `concat`, `intersperse`, `take`, `partition`, `unzip`, `sort`,
  `sortBy`, `sortWith`, `maximum`, `minimum`, `foldl`, `foldr`, `range`,
  `repeat`, `singleton`, `sum`, `product`, …).

2.2. Classify each function:
  - **A: one-shot** — builds one new object from arguments already held by
    caller → no changes needed (helpers root internally).
  - **B: collect-then-build** — collects into a vector, then loops
    `cons`/`tuple` → apply Pattern 2.
  - **C: traversal-with-callback** — iterates a list calling a
    mapper/predicate that may GC → confirm callback args aren't stashed
    across further allocs, and that `head` / `next` are read *before* the
    callback (already done by the current `ListOps` fix).

2.3. Concrete edits per class-B function: the entire Phase-2 loop
  collapses to a single call to `alloc::listFromUnboxables` (or
  `listFromPointers` / `listFromContainer`) from Step 1. Hand-rolled
  `cons` loops are removed.

### Step 3 — Fix `StringOps` and `BytesOps`

3.1. Enumerate every direct `Allocator::allocate` in
  `StringOps.{cpp,hpp}` and `BytesOps.{cpp,hpp}`. (Note: initial grep
  returned 0 for `.cpp` files, so the bulk is likely in the headers.)

3.2. For each site, classify as Template A or B and apply the fix. Sites
  that pass only freshly-produced unboxed data (e.g. `allocString`
  variants building from `u16*`) need no change.

3.3. For split/join/concat-style functions that build lists or arrays from
  `std::vector`, apply Pattern 2 exactly as in `ListOps`.

### Step 4 — Audit `RuntimeExports.cpp`

4.1. For each `eco_alloc_*` / `eco_pap_extend` / `eco_apply_closure` /
  `eco_closure_call_saturated` / `eco_clone_array` function, list all
  `HPtr` locals.

4.2. Confirm every local lies inside an active root-range window
  (`eco_gc_push_stack_range` → `eco_gc_restore_stack_range_point`).

4.3. Where a local sits outside: either extend the root range array, or
  wrap the allocation with a local `StackRootGuard`.

4.4. Document the invariant at the top of the file: *"All `HPtr` locals
  held live across `Allocator::allocate` must be members of an active
  root range; new locals must be added to `roots[]` arrays before use."*

### Step 5 — Clean up `runtime/src/main.cpp` demo helpers

5.1. Determine usage: grep the tree for callers of `allocateInt`,
  `allocateConsInt`, `allocateRecord`, `updateRootRecord`. Two paths:

  - **If they are dev-only playground code with no callers in shipped
    binaries or tests: delete them.** This removes a class of
    "example code that looks authoritative but isn't" and shrinks the
    surface area that reviewers mistake for canonical patterns.
  - **If they are used by tests:** either move them into a clearly-named
    `test/` helper file (so their demo-only nature is obvious), or
    rewrite them to call `alloc::allocInt`, `alloc::cons`,
    `alloc::record` instead of raw `Allocator::allocate`.

5.2. Leave `reverseList` alone (already rooted per design doc). If
  Step 5.1 chooses the "delete" path, `reverseList` stays if it's
  referenced by tests; otherwise it also goes.

### Step 6 — Elm kernel C++ sweep

Start with the four highest-traffic files, then fan out:

6.1. `elm-kernel-cpp/src/json/JsonExports.cpp` — ADT construction for
  `Json.Value`. Apply Pattern 1 uniformly.

6.2. `elm-kernel-cpp/src/bytes/BytesExports.cpp` — tuple2 builders and
  byte buffers around decoded values. Pattern 1 plus Pattern 2 for any
  list-of-bytes constructions.

6.3. `elm-kernel-cpp/src/core/List.cpp`, `ListExports.cpp` — almost
  certainly collect-then-build.

6.4. `elm-kernel-cpp/src/core/String.cpp`, `StringExports.cpp` — likely
  both patterns.

6.5. Remaining files (`JsArray.cpp`, `JsArrayExports.cpp`,
  `BasicsExports.cpp`, `Utils.cpp`, `PlatformExports.cpp`,
  `ProcessExports.cpp`, `TaskEffectManager.cpp`, `file/File.cpp`,
  `bytes/Bytes.cpp`, `browser/Browser.cpp`, `http/Http.cpp`,
  `parser/Parser.cpp`, `url/Url.cpp`, `url/UrlExports.cpp`,
  `virtual-dom/VirtualDom.cpp`, `virtual-dom/VirtualDomExports.cpp`,
  `regex/Regex.cpp`) — process alphabetically, spot-checking each for
  direct `Allocator::allocate` (Template A) and
  `std::vector`-accumulate-then-build (Pattern 2).

### Step 7 — Eco kernel C++ sweep

7.1. `eco-kernel-cpp/src/eco/File.cpp` — `allocByteBuffer`,
  `allocStringFromUTF8`, `just` wrappers. Verify caller-side rooting of
  boxed arguments passed in.

7.2. `eco-kernel-cpp/src/eco/MVarExports.cpp` — `allocInt` only; no
  rooting needed at the site (unboxed input), but confirm no live
  `HPointer` across it.

7.3. Remaining `.cpp` files: grep for direct `Allocator::allocate` and
  collect-then-build patterns; fix if present.

### Step 8 — Build and snapshot the detection query

No authoritative fact table is checked into the repo today — the design
doc's §6.1 reference is aspirational. Treat the current grep-based
report as the starting point. Build a CodeQL query (or a stronger
grep/clang-tidy script) and snapshot its output durably:

- Expand allocator-callee list: `allocatePermanent`, `allocateFast`,
  `allocateSlow`, `allocateRegionSlow`, plus every `alloc::*` helper
  that transitively allocates.
- Expand rooting-detection list: `pushStackRoot`, `pushStackRootRange`,
  `stackRootPoint`, `restoreStackRootPoint`, `stackRangePoint`,
  `restoreStackRangePoint`, `eco_gc_push_stack_range`,
  `eco_gc_stack_range_point`, `eco_gc_restore_stack_range_point`,
  `StackRootGuard`, `StackRootRangeGuard`.
- Produce a fact table of `(file, line, callsite, in-scope HPointer
  locals, rooting-present?)`. Any row with boxed locals and no rooting
  is a regression.

Deliverable: commit the query source to the repo, plus a snapshot of
its latest output (SARIF from CodeQL, or a normalized CSV) under
`design_docs/gc-rooting-facts/` so future edits have a durable
regression signal to diff against. Re-run before each PR in the
sequence below.

### Step 9 — Testing

9.1. Use `cmake --build build --target full` as the baseline correctness
  signal after each sub-step (don't batch).

9.2. Add GC-stress coverage for the areas touched: shrink the nursery
  (existing knob in `NurserySpace.cpp`), then run the
  JSON-encode/decode, HTTP, VirtualDom, and Task-heavy test cases.

9.3. If `heap-object-gc-test-coverage.md` has been implemented, extend it
  with list-op stress cases.

## Audit checklist (scoreboard)

Drive this table to green in file order. Status starts at "unreviewed";
entries marked `done` are already verified above.

| File | Direct allocates | Rooting today | Collect-build sites | Status |
|---|---|---|---|---|
| `runtime/src/allocator/HeapHelpers.hpp` | many | per-helper, good | `listFromPointers`, `listFromUnboxables` | **done** |
| `runtime/src/allocator/Heap.hpp` | 0 | n/a | n/a | **done** |
| `runtime/src/allocator/ListOps.cpp` | 31 via helpers | `listFromUnboxables` | all fixed | **done** |
| `runtime/src/allocator/ListOps.hpp` | 4 via helpers | `repeat` rooted | `fromVector` retired | **done** |
| `runtime/src/allocator/StringOps.cpp` | via helpers | `StackRootGuard` | `split`/`join`/`toList` fixed | **done** |
| `runtime/src/allocator/StringOps.hpp` | many inline | copy-before-alloc | all fixed | **done** |
| `runtime/src/allocator/BytesOps.cpp` | via helpers | `StackRootGuard` | `fromList`/`concat` fixed | **done** |
| `runtime/src/allocator/BytesOps.hpp` | inline | copy-before-alloc | `append`/`slice` fixed | **done** |
| `runtime/src/allocator/RuntimeExports.cpp` | 34 | 35 range push/pop | `eco_clone_array` fixed | **done** |
| `runtime/src/main.cpp` | several | proper root mgmt | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/json/JsonExports.cpp` | many | inline wrap | no intervening allocs | **done** (verified safe) |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp` | 3 `allocate` | inline wrap | no intervening allocs | **done** (verified safe) |
| `elm-kernel-cpp/src/bytes/Bytes.cpp` | via helpers | helpers root internally | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/core/List.cpp` | via helpers | full rooting | map2-5, toArray fixed | **done** |
| `elm-kernel-cpp/src/core/ListExports.cpp` | 0 | n/a | n/a | **done** (delegates) |
| `elm-kernel-cpp/src/core/String.cpp` | via helpers | `StackRootGuard` | `lines`/`words`/`fromList` fixed | **done** |
| `elm-kernel-cpp/src/core/StringExports.cpp` | `eco_alloc_char` | copy-before-callback | `map`/`filter`/`any`/`all`/`fold` fixed | **done** |
| `elm-kernel-cpp/src/core/JsArray.cpp` | `allocArray` | full rooting | all functions fixed | **done** |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | 0 | n/a | n/a | **done** (delegates) |
| `elm-kernel-cpp/src/core/BasicsExports.cpp` | `allocate` | inline wrap | no intervening allocs | **done** (verified safe) |
| `elm-kernel-cpp/src/core/Utils.cpp` | `allocInt` | immediate resolve | no intervening allocs | **done** (verified safe) |
| `elm-kernel-cpp/src/core/PlatformExports.cpp` | via `custom` | `custom` roots internally | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/core/ProcessExports.cpp` | `allocFloat`/`allocClosure` | `StackRootGuard` | timeHP fixed | **done** |
| `elm-kernel-cpp/src/file/File.cpp` | 0 | n/a | n/a | **done** (delegates) |
| `elm-kernel-cpp/src/browser/Browser.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/http/Http.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/http/HttpExports.cpp` | `utf8ToElmString`, `allocClosure` | `StackRootGuard` | `createResponse` fixed | **done** |
| `elm-kernel-cpp/src/http/HttpEffectManager.cpp` | `allocClosure` | immediate capture | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/core/TaskEffectManager.cpp` | `allocClosure` | immediate capture | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/time/TimeEffectManager.cpp` | `allocClosure` | immediate capture | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/time/TimeExports.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `runtime/src/allocator/ElmBytesRuntime.cpp` | `allocate`, `allocString` | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/parser/Parser.cpp` | unboxed tuples | n/a | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/url/Url.cpp` | `allocString` | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/url/UrlExports.cpp` | `allocStringFromUTF8` | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/virtual-dom/VirtualDom.cpp` | `allocStringFromUTF8` | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/virtual-dom/VirtualDomExports.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `elm-kernel-cpp/src/regex/Regex.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `eco-kernel-cpp/src/eco/File.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `eco-kernel-cpp/src/eco/MVarExports.cpp` | 1 (`allocInt`) | immediate return | n/a | **done** (verified safe) |
| `eco-kernel-cpp/src/eco/Process.cpp` | via helpers | immediate return | n/a | **done** (verified safe) |
| `eco-kernel-cpp/src/eco/Runtime.cpp` | 0 | n/a | n/a | **done** |
| `eco-kernel-cpp/src/eco/ExportHelpers.hpp` | 0 | n/a | n/a | **done** |
| `eco-kernel-cpp/src/eco/KernelHelpers.hpp` | via helpers | `StackRootGuard` | `taskSucceedStringList` fixed | **done** |
| `eco-kernel-cpp/src/eco/Http.cpp` | via helpers | `StackRootGuard` | `fetch`/`getArchive` fixed | **done** |

## PR sequencing

Land the work in four PRs, grouped by layer. Each PR gets its own
`cmake --build build --target full` pass (with nursery shrunk where
relevant) before merge.

- **PR 0 — Helpers (Step 1).** Ship `StackRootGuard` initializer-list
  overload, `StackRootRangeGuard`, `alloc::listFromUnboxables`, the
  pattern doc-comments. No call-site changes. No behavior change.
  Unblocks every subsequent PR.
- **PR 1 — `runtime/src/allocator` (Steps 2–4, 5).** `HeapHelpers.hpp`
  is already mostly done; this PR fixes `ListOps.cpp` / `.hpp`,
  `StringOps.{cpp,hpp}`, `BytesOps.{cpp,hpp}`, the bridging parts of
  `RuntimeExports.cpp`, and cleans up `main.cpp`.
- **PR 2 — `elm-kernel-cpp/src/core` + `bytes` + `json` (Step 6.1–6.4).**
  The high-traffic kernel surface: `JsonExports.cpp`,
  `bytes/BytesExports.cpp`, `bytes/Bytes.cpp`, `core/List*`,
  `core/String*`, and any other `core/*` file that trips the updated
  detection query.
- **PR 3 — remaining `elm-kernel-cpp` (Step 6.5).** `browser`, `http`,
  `url`, `parser`, `virtual-dom`, `regex`, plus any other `core/*` that
  didn't make PR 2.
- **PR 4 — `eco-kernel-cpp` (Step 7).** Thin; mostly a verification
  pass over `File.cpp`, `MVarExports.cpp`, `Runtime.cpp`.

Step 8 (detection query) lands alongside PR 0 or PR 1 and is re-run
before each subsequent PR, with fresh snapshots committed under
`design_docs/gc-rooting-facts/`.

## Resolved decisions

D1. **Scope vs. MLIR audit (`gc-liveness-audit-pass.md`): separate
  workstreams.** Different codebases, different failure modes; cross-
  referenced in both plan files but landed independently.

D2. **CodeQL fact table: none exists in-repo today.** Treat the
  grep-based report as the starting point. Step 8 builds the query and
  snapshots its output under `design_docs/gc-rooting-facts/`.

D3. **`StackRootGuard` API: keep 1..4 overloads AND add
  `initializer_list<HPointer*>`.** Fixed-arity overloads stay for their
  zero-cost properties; the new overload handles > 4 locals and
  conditional / dynamic sets. Reflected in Step 1.1.

D4. **PR sequencing: by layer, four PRs** (plus PR 0 for helpers) —
  see above.

D5. **`main.cpp` demo helpers (Step 5): delete if unused, move to
  `test/` or rewrite to safe helpers if referenced by tests.** Decided
  per-helper in Step 5.1.

D6. **`alloc::listFromContainer`: deferred.** Land only when a second
  real caller appears (likely during Step 6 Elm kernel sweep); until
  then, `listFromUnboxables` plus `listFromPointers` cover the known
  cases.

## Assumptions

A1. Helpers that take only unboxed arguments (`allocInt`, `allocFloat`,
  `allocChar`, `allocString(u16*, n)`, `allocByteBuffer*`,
  `allocArray(cap)`, `listFromInts`, `listFromFloats`, `arrayFromInts`)
  are GC-safe by construction and do not need internal rooting. **Their
  callers** must still root any unrelated boxed locals live across the
  call.

A2. `alloc::allocClosure(evaluator, max_values)` is safe because it
  stores no user-supplied pointers. `closureCapture` does no allocation.
  Callers that allocate after `allocClosure` and before `closureCapture`
  must root the closure `HPointer`; this plan treats that as a call-site
  audit item (Step 4 / 6 / 7), not a helper fix.

A3. The `eco_gc_push_stack_range` C-ABI in `RuntimeExports.cpp` is
  semantically equivalent to a contiguous block of `pushStackRoot`
  calls; the GC walks both via the same `RootSet::getStackRoots`. If
  this is not true, Step 4's invariant ("locals inside the range are
  rooted") is unsafe and needs revisiting. Needs confirmation from
  whoever owns `RootSet.cpp` before PR 1 is marked ready.

A4. Per the heap representation invariants (`design_docs/invariants.csv`,
  `design_docs/theory/heap_representation_theory.md`), *only* Int,
  Float, and Char can be unboxed in `Unboxable` slots; Bool and every
  other type is boxed as `!eco.value`. So the "boxed vs unboxed"
  decision for a field is knowable from either (a) a stored `unboxed`
  bitmap, or (b) the MonoType at the call site. Patterns 1 and 2 encode
  both cases.

A5. All fixes preserve behavior in the absence of GC. Correctness-only,
  not performance. If a hotspot emerges after the sweep, follow-up work
  can coalesce per-call-site `pushStackRoot` pairs into wider root
  ranges (like `eco_gc_push_stack_range`).

## Risks

R1. **Stale-pointer bugs surface silently when nursery is large.** Many
  of the suspect sites only fail under GC pressure. Shrinking the
  nursery during `full` test runs is essential to catch regressions.
  Add a dedicated GC-stress test target if one doesn't exist.

R2. **ABI drift.** If this plan runs concurrently with
  `centralize-closure-abi-in-runtime.md` or
  `centralize-gc-roots-on-alloc-ops.md`, call sites may be rewritten
  twice. Coordinate before landing PR 1.

R3. **Hidden direct allocates.** The original design doc enumerates
  files but the fact table is incomplete (`.hpp` files' direct-allocate
  counts are listed but our sanity grep returned different totals for
  the `.cpp` files). Step 8 must produce a clean fact table before
  Steps 6–7 (PRs 2–4) can claim completion.
