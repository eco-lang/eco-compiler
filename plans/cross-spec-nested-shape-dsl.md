# Cross-Spec Nested-Shape DSL — Phase 2 of widen-construct-make-call-aggregates.md

## 0. Goal

Lift cross-spec's "shape system" from one-level-deep flat aggregates to
arbitrarily nested aggregates, so the Phase 1.5 stopgap in
`rewriteConstructToMake` can be deleted and chained-aggregate
`construct.*` field flows no longer pay one `eco.to_heap` per nested
level.

This is a **step on the way to supporting `!eco.value` inside FCAs**.
Today RS4GC can't handle a nested FCA whose inner level contains a
`ptr addrspace(1)` ("support for FCA unimplemented"), so this plan
restricts nesting to the GC-pointer-free case via a structural
admission gate. The GC-pointer-inner case unlocks once an LLVM-level
pre-RS4GC FCA decomposer (or an upstream RS4GC fix) lands; the DSL,
parser, recursive eligibility, slot layout, and store/load paths
delivered here all carry over unchanged to that future case — only the
gate predicate needs flipping.

See [`plans/widen-construct-make-call-aggregates.md`](widen-construct-make-call-aggregates.md)
§9 for the Phase 2 framing and
[`plans/cross-spec-bridgeoperands-regressions.md`](cross-spec-bridgeoperands-regressions.md)
for the integration bugs the stopgap papers over.

## 1. Background

Phase 1 of `widen-construct-make-call-aggregates.md` widened
`construct.*` / `make.*` / `eco.call` operand types to accept aggregate
SSA values, and added an `EcoBoxAggregateOperands` pass that inserts
`eco.to_heap` at heap-slot and boxed-ABI sinks. To keep cross-spec
internally consistent, `rewriteConstructToMake` carries a Phase 1.5
stopgap that *also* boxes any aggregate-typed field operand before
building the new `make.*` op (so the make's result element list stays
flat). Without that stopgap, cross-spec produces nested aggregate
types that the rest of the toolchain — `sretSlotStructTy`,
`emitSretLoad`, `emitSretStore`, `EcoFlattenAggBoundary`, RS4GC — was
built around a flat assumption.

A heap-profile run (`./heap-profile.py … run --wall-seconds 100`)
comparing default vs `-enable-unboxed-agg` shows a small **regression
under the optimization**: +254 MB allocated bytes / +8 M objects over
100 s. The dominant contributors are exactly the `eco.to_heap`
insertions the stopgap forces. Phase 2's job is to remove those
without re-introducing the layered-type-mismatch bug that motivated
the stopgap in the first place.

## 2. DSL grammar extension (concrete)

The current `parseLogicalShape`
(`runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp:184-261`)
accepts a flat per-position element kind: each slot is a single
character (`i`/`f`/`c`/`v`). For nesting, we add bracketed sub-shapes
as an alternative production for an element.

```
shape     ::= leaf | aggregate
leaf      ::= "value" | "i64" | "f64" | "i16" | "i1"
aggregate ::= "tuple2:" elem ":" elem
            | "tuple3:" elem ":" elem ":" elem
            | "record:"  N           (":" elem){N}
            | "custom:" TAG ":" N    (":" elem){N}
            | "cons:" elem ":" elem
elem      ::= K_char | "[" shape "]"            ← new: bracketed nested shape
K_char    ::= "i" | "f" | "c" | "v"
```

Backward-compatible by construction: every flat string today parses
unchanged; brackets are the only new syntactic surface. Brackets nest
to arbitrary depth and balance is enforced by the parser.

Examples:

| String | Meaning |
|---|---|
| `record:2:i:v` | flat — existing |
| `record:2:[tuple2:i:i]:v` | record of `(tuple2:i:i, value)` |
| `tuple2:i:[tuple3:i:i:v]` | outer tuple2; second element is `tuple3:i:i:v` |
| `custom:5:2:[tuple2:i:i]:[record:3:i:i:v]` | depth-2 nesting in a custom |

Brackets are chosen over parens because `:` is already the field
separator at every level, so brackets are the natural delimiter for a
sub-expression that contains colons; parens additionally conjure
function-call associations that read wrong.

K_char shorthand stays the **only** way to write a leaf primitive in
the DSL — i.e. we do not also accept `record:2:[i64]:v`. The grammar
stays visually distinctive (brackets = aggregate; single char =
leaf) and `stringify(LogicalShape)` always picks the short form, so
the encoder is unambiguous. Trivial extension later if both forms
turn out to help readability.

## 3. Design

### 3.1 Parser

Refactor `parseLogicalShape` into recursive descent. The recursion has
two pieces:

```cpp
// Parse one shape, advancing the input cursor past it.
static bool parseShape(StringRef &cursor, MLIRContext *ctx, LogicalShape &out);

// Parse one element (single K_char or "[" shape "]").
// Returns the MLIR Type for the element slot.
static bool parseElement(StringRef &cursor, MLIRContext *ctx, Type &outTy);
```

`parseShape` reads the leading keyword (`tuple2` / `record` / `custom`
/ ...), parses the fixed-arity parameters, and then calls
`parseElement` for each element slot. `parseElement` peeks the next
character: if `[`, it scans for the matching `]` (balanced-bracket
counting), recursively calls `parseShape` on the inside, and stores
the result's `asWorkerType(ctx)` as the element Type; otherwise it
maps the single character via the existing `kindCharToType` helper.

Total parser surface: ~50 LoC including the bracket-balance helper.

### 3.2 Stringifier

Add `stringify(LogicalShape)` for round-trip and diagnostics. When an
elementTys[i] is a leaf, emit the K_char shorthand; when it is itself
an aggregate, emit `[stringify(innerShape)]`. The inner shape is
reconstructed by mapping the MLIR type back into a `LogicalShape`
(small helper `shapeFromMLIRType(Type)` that walks
`eco.tuple2/3/record/custom/cons/value/primitives`).

Used by:
- Diagnostics inside cross-spec.
- Future test fixtures that want golden DSL strings.

Roughly 30 LoC including `shapeFromMLIRType`.

### 3.3 Recursive eligibility analysis

Three predicates in cross-spec walk shapes; each needs to recurse:

| Predicate | File:line (current) | Recursion plan |
|---|---|---|
| `aggregateShapesMatch` | `EcoUnboxedAggCrossSpec.cpp:371` | compare elementTys element-by-element; if an element is itself an aggregate type, recurse via `mlirTypeMatchesShape` (or a helper that walks both types in lockstep) |
| `isAcceptedAggregateProducer` | `:454` | when a producer chain bottoms out at a `construct.*` op whose field types match the expected nested elementTys, accept; otherwise demote to Boxed. Bounded depth budget (already a parameter) keeps it safe |
| `allUsesAreProjectionsOrCallsToEligible` | `:625` | when an aggregate block-arg is consumed by a `project.*` op whose result is itself aggregate-typed, recurse into that result's uses with the inner shape's expectations |

The existing `depthBudget` parameter on `isAcceptedAggregateProducer`
generalises directly. SCC-aware termination is already in the
analysis; nested shapes inherit that machinery.

~60–90 LoC.

### 3.4 `containsGCPointer` admission gate

Add a check at every site that's about to commit a nested element
type: if the inner aggregate's type contains a `!eco.value` anywhere
(recursively, via `containsGCPointer` — already in the tree, currently
unused), refuse the nesting and demote that position to Boxed. Box
sites that survive the demotion fall back to the current Phase 1
behaviour (the `EcoBoxAggregateOperands` pass continues to insert
`eco.to_heap` at construct.* sinks, just as it does today for
non-promoted aggregate operands).

This is the single structural guard that keeps Layers 4 and 6 of the
prior analysis cheap. Two consequences:

- **RS4GC never sees a nested FCA with `ptr addrspace(1)` strictly
  inside.** The "support for FCA unimplemented" assertion can't fire.
- **`sretSlotStructTy` for a nested element is a flat primitive
  struct.** Its `llvm.alloca` lowers fine; its store and load become
  a single `llvm.store`/`llvm.load` of the inner struct value.

~15–20 LoC.

### 3.5 Recursive type conversion

Extend `elementToLLVMTy` at `EcoUnboxedAggCrossSpec.cpp:348` so a
non-leaf element calls back into the dialect's type converter (which
already recursively lowers `eco.tuple2`/`tuple3`/`record`/`custom` to
nested LLVM struct types via the rules registered in
`EcoToLLVMTypes.cpp`). With the gate at §3.4 in place, every nested
element produced here is GC-pointer-free, so the converted LLVM type
is a primitive-only struct.

`sretSlotStructTy` automatically benefits: its body now contains
nested primitive structs at the right slots.

~10 LoC.

### 3.6 Single-struct sret store/load

`emitSretStore` / `emitSretLoad` at `EcoUnboxedAggCrossSpec.cpp:777`
and `:801` currently do per-field GEP+store/load with a one-level
view. For nested elements (now guaranteed primitive-inner by §3.4),
the inner aggregate's LLVM type is a plain primitive struct — so we
can use a single `llvm.store` / `llvm.load` of the whole nested
struct. No per-leaf GEP chain needed.

The bridge between `!eco.value` element and `ptr addrspace(1)` slot
field stays as today; only the nested-element branch is new. On the
load side an `unrealized_conversion_cast` brings the loaded LLVM
struct back into the eco-dialect aggregate type so downstream
`eco.make.*` / `eco.construct.*` sees a typed operand.

~5–10 LoC.

### 3.7 Wrapper Sret-rebuild recursion

The wrapper's per-result Sret-rebuild path (lines 1499–1554) and the
worker-body redirected-call rebuild (lines 1278–1340) both
reconstruct an aggregate value from `loadedFields`. With nested
elementTys, the `loadedFields[k]` for a nested element is already a
typed aggregate value (from §3.6); the existing `eco.make.*` /
`eco.construct.*` builders accept it without modification because of
the Phase 1 op-type widening. The recursion is therefore implicit —
the only change is *not* boxing at the rebuild site.

~20–30 LoC, mostly accounting for the few places that look at the
flat element list and assume per-field scalar storage.

### 3.8 Drop the Phase 1.5 stopgap

`rewriteConstructToMake` reverts to the original "compute elementTypes
from operand types verbatim" shape. The four built-in cases (Tuple2 /
Tuple3 / Record / Custom) all collapse back to the pre-stopgap form;
the `boxIfAggregate` helper and the `containsGCPointer` early-exit
become unused (the gate moved to eligibility, which decides upstream
whether nesting is admitted at all).

`containsGCPointer` itself stays in the tree — it's now used by §3.4's
admission gate.

~−30 LoC.

### 3.9 EcoFlattenAggBoundary not touched

The boundary-flatten pass stays one-level, and the §3.4 gate ensures
it never sees a nested aggregate at a function signature: positions
that would otherwise carry a nested element are demoted to Boxed
before the worker signature is built. So the LLVM-side function type
still contains only scalars and pointers (or one level of FCA at
worst, exactly as today).

Nesting happens **inside the worker body** — `make.*` ops produce
nested aggregates, the wrapper's slot allocation matches, and SROA
collapses the nested `make.*` / `project.*` pairs at LLVM level.

## 4. Implementation order

Land as a single coherent change, but in this internal ordering for
testability:

1. **DSL parser + stringifier** (§3.1, §3.2). Lands with 3-4 unit
   fixtures that just round-trip nested DSL strings through parse →
   stringify → re-parse and verify identity. No behavioural change
   yet.
2. **`containsGCPointer` admission gate** (§3.4). Becomes the gate
   for nested shapes in §3.3; today it has no caller, so this step
   alone is a no-op until §3.3 lands.
3. **Recursive eligibility** (§3.3). With the gate in place, this is
   the analysis-side change that lets cross-spec admit nested
   shapes. Behaviour: more positions get promoted, all gated to
   GC-pointer-free.
4. **Recursive type conversion** (§3.5) + **sret store/load** (§3.6).
   The downstream slot/store/load consistency.
5. **Wrapper Sret-rebuild recursion** (§3.7). The remaining
   construction sites.
6. **Drop the stopgap** (§3.8). The validation step — if everything
   above is right, the bootstrap stays green and the heap-profile
   regression goes from +254 MB → ~zero or slightly negative.
7. **Verify** (§6).

## 5. Test plan

Three new `.mlir` fixtures under `test/codegen/`, each mapping 1:1 to
a regime the gate distinguishes:

1. **`dsl_nested_shape_parse_round_trip.mlir`** — minimal function
   whose `eco.logical_result_types` uses bracket syntax. FileCheck
   verifies cross-spec accepts it and the worker signature comes out
   with the nested aggregate type. Lands with step 1 (DSL parser).
2. **`cross_spec_nested_record_primitive_inner.mlir`** — replaces /
   extends `cross_spec_nested_make_record_from_construct.mlir`. The
   chained-aggregate case with a GC-pointer-free inner. With the
   gate, recursion, and stopgap removal, this fixture goes from
   "boxed by the stopgap" to "nested via the worker's promoted
   signature; no extra `to_heap`." FileCheck asserts the absence of
   `eco.to_heap` between the producing call and the consuming
   record.
3. **`cross_spec_nested_record_gc_pointer_inner_demotes.mlir`** —
   same chained pattern but the inner aggregate contains a
   `!eco.value`. FileCheck verifies the gate kicks in: the inner
   stays boxed (via `to_heap`), and no nested FCA reaches RS4GC. The
   demotion path is exercised explicitly. Lands with step 2.

The biggest practical win of writing fixtures against the DSL: a
`.mlir` file can short-circuit the eligibility decision and just
declare "this function returns `record:2:[tuple2:i:i]:v`", and the
test exercises the nested-shape path directly. That makes steps 3–6
testable in isolation, lowering the integration risk that bit us in
the previous attempt.

## 6. Verification

1. `cmake --build build --target full` — Gate A (JIT E2E) stays
   green.
2. `cmake --build build --target stress` — stress suite stays green.
3. `cmake --build build --target run-aot-e2e` — Gate B stays green.
4. Bootstrap chain through Stage 7 stays green (Stage 8 cmp continues
   to fail on the pre-existing ASLR symbol-naming non-determinism;
   that is a separate plan).
5. The three new fixtures pass as ordinary tests (no `XFAIL`).
6. Heap-profile re-run (`./heap-profile.py --tee --enable-unboxed-agg
   run --wall-seconds 100`): allocation should drop relative to the
   Phase-1-plus-stopgap baseline. Expected direction: the chained-
   aggregate `eco.to_heap`s elided by §3.8 are the dominant
   contributor to the +254 MB regression we measured, so the
   `-enable-unboxed-agg`-on run should land at or below the default.
   Exact magnitude depends on how much of the eco-compiler's
   chained-record IR is primitive-inner; the GC-pointer-inner share
   stays boxed.

## 7. Out of scope

- **GC-pointer-inner nesting.** Requires either a pre-RS4GC LLVM-IR
  FCA decomposer (a meaningful side project that lives entirely
  outside the eco repo) or an upstream RS4GC fix. The §3.4 gate
  cleanly skips this case; everything else in this plan ports to it
  unchanged once the LLVM piece lands.
- **Front-end DSL emitter.** The Elm compiler's
  `eco.logical_*_types` attribute emitter keeps emitting flat
  strings for now. Cross-spec's eligibility analysis populates
  nested elementTys from observed IR (the producer-side chain), and
  the DSL extension delivered here is the *encoding* used internally
  for round-trip + diagnostics + test fixtures. The grammar
  extension is "ready" for the front-end to start emitting nested
  when there's a concrete win to motivate it.
- **`EcoFlattenAggBoundary` recursive flatten.** Stays one-level.
  The §3.4 gate ensures the boundary never carries a nested
  aggregate; if a future plan wants to admit nested boundaries
  (necessary if the GC-pointer-inner LLVM piece lands), the flatten
  pass would need its own recursion.

## 8. Effort

| Step | LoC | Risk |
|---|---:|---|
| 3.1 DSL parser (recursive descent + bracket balance) | ~50 | low |
| 3.2 Stringifier + `shapeFromMLIRType` | ~30 | low |
| 3.3 Recursive eligibility | ~60–90 | medium |
| 3.4 `containsGCPointer` admission gate | ~15–20 | low |
| 3.5 Recursive `elementToLLVMTy` | ~10 | low |
| 3.6 Single-struct sret store/load | ~5–10 | low |
| 3.7 Wrapper Sret-rebuild recursion | ~20–30 | low |
| 3.8 Drop stopgap | −30 | low |
| 3.9 (no-op) | 0 | — |
| Fixtures | ~120 | low |

**Total: ~130–200 LoC net additions across `EcoUnboxedAggCrossSpec.cpp`
and a small touch on `EcoToLLVMRuntime.cpp` (the type converter call
site).** Two files in the runtime, three new fixtures in `test/codegen/`.

## 9. Risks and mitigations

- **Parser ambiguity.** The bracket grammar is unambiguous in
  isolation, but a malformed string (unbalanced `[`, leading
  whitespace, mixed-case keywords) could surprise. Mitigation: the
  unit fixture from step 1 exercises a small set of malformed inputs
  and asserts the parser rejects cleanly with a deterministic
  diagnostic. Add an explicit `parseError` enum if useful.
- **Eligibility recursion infinite loop.** The existing
  `depthBudget` parameter caps recursion. Inherited by the nested
  recursion; verified by the SCC-tentative-shape test path.
- **Wrapper / worker layout disagreement.** The previous attempt's
  failure mode. Mitigation: cross-spec computes the `LogicalShape`
  once (eligibility), and *both* the wrapper-side slot allocation
  and the worker-body store/load read from the same elementTys via
  `sretSlotStructTy`. They cannot drift apart by construction.
- **Performance regression at the worker boundary.** The
  single-struct store/load (§3.6) for a nested element is one LLVM
  load + one cast vs the current per-field GEP chain. Both should
  fold the same way in SROA; mitigate with a focused micro-benchmark
  if anything looks off in the heap profile.

## 10. Onward path

Once this lands:

- Future LLVM-side work (pre-RS4GC FCA decomposer or upstream RS4GC
  patch) opens the gate at §3.4 and unlocks GC-pointer-inner
  nesting. The DSL, eligibility, slot layout, and store/load paths
  in this plan all carry over unchanged — only the predicate flips.
- The front-end can start emitting nested DSL strings directly when
  there's a clear win (e.g. monomorphisation already inferring a
  precise nested shape that cross-spec would have to rediscover).
- The heap-profile script grows a "stopgap-elision count" telemetry
  point alongside its existing GCStats so we can quantify chained-
  aggregate wins per workload.
