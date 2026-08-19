# Nullary-Constructor Embedding in HPointer (`null_cons_idx`)

**Status: IMPLEMENTED AND GATED (2026-08-19).** All phases P0–P6 landed.
Invariants HEAP_044 + CGEN_079 added; CGEN_068 and HEAP_035 amended.
Measurement: `benchmarks/lss-opt.md` Run T. The promoted 0-field `Tag_Custom`
bucket is exactly **0** (was 28,645,830 / 437 MiB, of which 27,601,652 were
`RBEmpty`), and the copied-in-nursery 0-field count with it. On one cold
Stage 7a leg: promoted 475,692,159 → **450,649,497** objects (−5.3%) and
13,641 → **13,305** MiB (−2.5%) against the §0 census, with **majors 17 → 14**
— close to the −28.6M / −437 MiB the plan predicted. Read the entry before
quoting those deltas: it is one leg against a census from a different tree and
the corpus is the compiler source, which this change modifies, so only the
majors step (deterministic per Run R) is worth leaning on. No wall-clock claim.

Gates, all on the final tree: `elm make` type-check clean; E2E **1,681/1,681**
from a clean `--target full`; heap-validate E2E **1,681/1,681** with the new
0-field tripwire armed; `--target elm-tests` at exactly the 12 pre-existing
TYPE_007 failures; full bootstrap green including **both** fixed points
(Stage 4b JS, Stage 8c native).

**Five corrections to this plan, found while executing it.** Each was a real
defect the plan as written would have shipped:

1. **There are THREE tag extractors, not two.** §1 and §7 say "exactly two
   implementations" (`eco_get_tag`, `expandGetTagMarkers`). The `eco.case`
   lowering in `EcoToLLVMControlFlow.cpp` has its own open-coded
   embedded-constant arm, and it is the one every non-loopified `case` goes
   through. Missing it mis-dispatches every case on a null-cons value.
2. **`alloc::isBoolConst` (`HeapHelpers.hpp`) classified any non-Empty
   constant as a Bool** (`constant != Const_Empty`), so a null-cons word read
   as `True`. The §5.2 audit grep does not reach it. Fixed to test bit 1
   (`(constant & 2) == 0`).
3. **The JSON kernel minted 0-field heap Customs outside `alloc::custom`** —
   `makeJsonNull`, `makeDecoder0` (the five primitive decoders) and
   `Elm_Kernel_Json_encodeNull` all call `eco_alloc_with_roots(Tag_Custom, …)`
   directly. §5.3's population list (Utils/Bytes/Browser/Http) is incomplete;
   its own `Tag_Custom` sweep grep is what finds them. Their consumers
   (`jsonValueCtor`, `runDecoder`'s decoder/jval ctor reads, the three
   sub-decoder kind-inference sites, `Elm_Kernel_Json_run`'s validity guard)
   had to learn to read the ctor off the word.
4. **`ListExports.cpp` resolved the Order result to read `->ctor`** in BOTH
   `sortBy` (via `Utils::compare`) and `sortWith` (the user comparator's
   return). §5.3 says "Kernel walkers: no changes needed"; in fact every
   `List.sort*` aborted on `Allocator::fromPointerRaw`'s embedded-constant
   assert until both were routed through `eco_get_tag`. Same class in
   `BytesExports.cpp`'s `endiannessHPointerToBool`.
5. **Test scaffolding hand-builds the now-illegal shape.** Four codegen
   fixtures (`allocate_ctor_minimal`, `caf_memo_enum`, `case_maybe_value`,
   `construct_scalar_bytes`), two kernel unit tests (K1/K2 endianness) and
   four allocator tests (three GC pressure tests + one rapidcheck generator)
   construct 0-field Customs directly. They are part of the change, not
   fallout to triage afterwards.

Original outline in §1–§3; the phase lowering in §5 is written so a competent
engineer can execute it without large leaps. Grep anchors were verified
against the tree on 2026-08-19.

## 0. What triggered this

The promoted-Custom ctor census (`benchmarks/lss-opt.md` Run S + the
`(nfields, ctor)` follow-on) measured, on one cold self-compile:

| population | objects | MiB |
|---|---|---|
| promoted 0-field `Tag_Custom` | 28,645,830 | 437 |
| — of which `Dict.RBEmpty_elm_builtin` (ctor 0xFFFE) | 27,601,652 | 421 |
| copied-in-nursery 0-field `Tag_Custom` | 62,025,498 | — |
| all promotion (reference) | 475,692,159 | 13,641 |

Every one of those objects is a **nullary constructor**: a 16-byte heap object
(8-byte header + the ctor/unboxed word) whose entire information content is a
ctor index that already fits in 16 bits. `HPointer` has reserved space for
exactly this since the D1 redesign:

```
//   [43-52] enum_idx : 10  — reserved bare constructor index for a future enum
//                            optimization; always 0 for now.
```

This plan uses it: a nullary constructor value becomes an **embedded HPointer
constant** carrying its ctor tag in those bits — no allocation, no promotion,
no pointer dereference at case dispatch, one fewer load than even a
CAF-memoized singleton. The field is renamed **`null_cons_idx`** because the
technique applies to every nullary constructor, not only all-nullary (`Enum`)
unions: `RBEmpty` — 96% of the payoff — lives in a `Normal` union.

## 1. Current state (verified)

- **Classification** (`Canonicalize/Environment/Local.elm:533 toOpts`):
  `Can.Unbox` for single-ctor-single-arg; `Can.Enum` iff every ctor is
  nullary; else `Can.Normal`. Enum ctors become `TOpt.Enum index` →
  `MonoEnum tag type` (bodiless spec). Nullary ctors of Normal unions become
  `MonoCtor` with `fields == []`.
- **Codegen today**: `Functions.generateEnum` (`Functions.elm:1897`) and the
  `arity == 0` arm of `generateCtor` (`Functions.elm:1809`) emit a nullary
  `func.func` whose body is `eco.construct.custom … tag N size 0` — a real
  heap allocation — except the three hard-coded names `True`/`False`/`Nothing`
  which emit `eco.constant` immediates (0x5/0x4/0x6). M4 CAF memoization
  (`Functions.elm:499-521, 696`) wraps the allocating bodies in a CAF slot so
  each spec allocates **once per process**.
- **Reference sites**: a bare `MonoVarGlobal` to an arity-0 spec emits a
  direct `eco.call @spec()` (`Expr.elm:658 generateVarGlobal`, arity-0 arm).
  So today every *reference* to e.g. `LT` is a call that returns the
  memoized heap pointer.
- **Why Dict's RBEmpty still allocates 27.6M times**: it is not an enum
  (its union has the 5-field `RBNode`), its per-*value* references come out
  of pure Elm `Dict` code where every empty subtree slot stores the (CAF-
  shared) pointer — but the census shows the promoted population is real:
  27.6M distinct promoted objects. The CAF singleton sharing does NOT
  collapse them because kernel-side `alloc::custom` construction and
  pre-CAF construction paths mint fresh ones, and every `Dict` leaf slot in
  a *copied/promoted* tree is a slot the collector must copy and trace.
  Embedding deletes the object class outright.
- **Runtime constants today** (`Heap.hpp:187-207`): `Const_False=0` (word
  0x4), `Const_True=1` (0x5), `Const_Empty=2` (0x6 — the merged
  Unit/EmptyRec/Nil/Nothing/"" empty, dispatched as `CONSTANT_TAG` 0xFFFD).
  The 2-bit `constant` field's code **3 is unused** — that is our
  discriminant.
- **Tag extraction** exists in exactly two implementations, which must stay
  in lock-step: runtime `eco_get_tag` (`RuntimeExports.cpp:4055`) and the
  open-coded diamond `expandGetTagMarkers` (`EcoBackend.cpp:1619`). Both
  currently map any non-Bool constant to `CONSTANT_TAG`.
- **GC** skips embedded constants uniformly via `ptr_ind != 0` /
  `isConstantBits` — verified at every root/slot walk touched:
  `NurserySpace.cpp:551,683,920,1166,1266,1326,1563`,
  `OldGenSpace.cpp:171,1581,1767,4044`, JIT/CAF/value roots, permanent-space
  copier. **No collector logic change is needed**; only *validators* that
  additionally assert `enum_idx == 0` break (see §5.2).
- **Kernel equality** (`elm-kernel-cpp/src/core/Utils.cpp:89
  resolveAndCompare`): *if either side is an embedded constant, equality is
  raw word equality.* `dictEq`'s `resolveCustom` (`Utils.cpp:750`) already
  treats "embedded constant → nullptr → empty subtree".
- **Kernel construction of nullary customs** funnels through
  `alloc::custom` (`runtime/src/allocator/HeapHelpers.hpp:176` namespace):
  the Order singletons `LT/EQ/GT` (`Utils.cpp:33-49`, heap-allocated,
  GC-rooted), `Bytes.cpp:71` (Endianness), `Browser.cpp:79,83,102`, and
  `HttpExports.cpp:166` (`rbEmpty()` — kernel-built response-header Dicts).

## 2. Design

### 2.1 Encoding

A nullary-constructor value is the 64-bit word

```
word = (idx << 43) | 0b111          // ptr_ind=1, constant=3 (the unused code)
```

- `constant == 3` is the **null-cons discriminant**. False/True/Empty (0x4/
  0x5/0x6) are untouched; idx 0 gives word 0x7, which collides with nothing.
- `ptr` bits [3-42] are zero, so every existing "is this a heap pointer"
  predicate (`ptr_ind != 0`) already classifies these words as non-pointers,
  and the D1 property "low 43 bits are the raw address" is preserved for
  real pointers (their `null_cons_idx`/`padding` remain 0).
- `idx` is the constructor's **zero-based declaration index** — nothing
  else. No type identity is stored (none is needed: the heap `Custom.ctor`
  field is equally union-blind today, and well-typed code never compares or
  matches across unions), and no remap table exists: tag extraction returns
  the 10 bits verbatim.

  **Prerequisite (P3.0): demote `RBEmpty` from the reserved-tag set.** Today
  `CtorTag.effective` remaps Dict's two ctors to reserved values (RBNode
  0xFFFF, RBEmpty 0xFFFE) so the *runtime* can recognise Dicts for
  content-based equality without type info. 0xFFFE does not fit in 10 bits —
  but the audit (2026-08-19) shows RBEmpty's reservation is only
  load-bearing for cases that CEASE TO EXIST once RBEmpty is embedded
  (heap-empty equality dispatch in `isDictCtor`); every walker that matters
  keys on **RBNode's** 0xFFFF, and RBNode has 5 fields so it never meets
  this mechanism. So RBEmpty reverts to its declaration index **1**, the
  reserved set shrinks to {0xFFFF, 0xFFFD}, and every nullary ctor in the
  language — RBEmpty included — stores its plain declaration index.

### 2.2 Capacity, and what happens when 10 bits are not enough

A nullary ctor whose declaration index is > 1023 **hard-crashes the compile**
at emission with a message naming the constructor. Accepted for now (user
decision 2026-08-19). The census-measured maximum declaration index in the
corpus is ~20, and even `Error.Syntax`'s widest unions stay in the low
hundreds, so the crash is theoretical headroom, not a live risk. If it ever
fires: bits [53-63] are 11 reserved padding bits directly above the field —
widening `null_cons_idx` to 16+ bits is a layout change confined to §5.1's
one-place encoding helpers plus the golden-word tests. Do not widen
preemptively.

### 2.3 The single-representation invariant (correctness, not hygiene)

**After this plan, a nullary constructor value exists ONLY as its embedded
word. A live heap `Tag_Custom` with 0 fields is a bug.**

This is forced, not chosen: `resolveAndCompare` (`Utils.cpp:89`) and the
`eco.value.eq` diamond (`EcoBackend.cpp:1454`) both decide *not-equal* by raw
word inequality the moment either operand is embedded. A heap-allocated `LT`
(today's kernel Order singleton) compared against an embedded `LT` would be
**unequal — a silent miscompile**. Therefore kernel-side construction converts
in the same change as compiler emission (§5.3), and heap-validate gains an
assert that no live 0-field `Tag_Custom` exists (§5.6). The same invariant is
also what keeps those two fast paths *sound* afterwards: embedded-vs-heap of
the same union means different ctors, so word inequality is the right answer.

### 2.4 What deliberately does NOT change

- `True`/`False` stay 0x5/0x4 (Bool dispatches via the i1/IsBool path), and
  the merged empty 0x6 stays for Unit/EmptyRec/Nil/Nothing/"" with its
  `CONSTANT_TAG` dispatch. Migrating `Nothing` out of the merged set is
  unsound (Nil/""/Unit share its bit pattern by design, D3) and unnecessary.
  Per-ctor single representation is what matters, and each of these ctors
  keeps exactly one representation. `CtorTag.isEmbeddedConstantCtor` (the
  three-name list) keeps guarding exactly this legacy set — the new
  mechanism's predicate is arity-based and independent of it.
- `CtorTag.effective` and every pattern-match/decision-tree path: case
  dispatch flows through `eco_get_tag`/`__eco_get_tag_inline` on both
  engines, and those learn the new arm (§5.2), so `Patterns.elm`, decision
  trees, `eco.case` lowering and the compare→branch peephole need **zero
  changes** — this is the load-bearing simplification of the whole design.
- The subst engine: `MonoCtor`/`MonoEnum` and all of §5.4's codegen are
  shared by both engines, so parity is automatic.
- `Can.Unbox` types, REP_* representation classes: an embedded null-cons is
  an ordinary `!eco.value` word in SSA/ABI/heap-slot positions. No new
  unboxing class, REP_HEAP_001 untouched.

## 3. Expected payoff (sized from the census)

- Promotion: −28.6M objects (−6.0% of all promoted objects), −437 MiB
  (−3.2% of promoted bytes). Nursery copying: −62.0M copy events (−5.6% of
  copied-in-nursery).
- Every `case` on such a value: the get_tag diamond's embedded arm (three
  ALU ops) instead of resolve + header load. Every reference: an immediate
  instead of a call returning a CAF-guarded load.
- Dict operations: empty-subtree checks stop dereferencing entirely
  (`dictEq` already short-circuits on constants); `Dict` trees shrink by
  n+1 heap leaves each, with knock-on mark/copy reductions across every
  minor and major GC (Run S: mark is 92.4% of major-GC time and scales with
  live objects).
- Given Run R (majors are a deterministic step function of occupancy), a
  ~437 MiB promoted reduction plausibly steps the major count down; report,
  don't promise.

## 4. Phase overview

| phase | what | gate |
|---|---|---|
| P0 | rename `enum_idx` → `null_cons_idx` everywhere | byte-identical build |
| P1 | bit substrate: encode/decode/classify helpers + both tag extractors + golden tests | unit + codegen fixture tests |
| P2 | fix the validators that assert `enum_idx == 0` | targeted tests |
| P3 | RBEmpty reserved-tag demotion + kernel single-representation: `alloc::custom` choke point, Order singletons, construct-op verifier | E2E subset |
| P4 | compiler emission: new constant op, `generateEnum`/`generateCtor` rewrite, CAF removal, reference-site inlining, capacity crash | full E2E + bootstrap |
| P5 | GC/validate: predicate audit, no-live-0-field-Custom assert, heap-validate suite | validate suite |
| P6 | gates + census re-run + benchmark | protocol below |

P1–P3 land together (they are one atomic representation change on the
runtime/kernel side); P4 flips the compiler onto it; P5/P6 verify. Until P4
lands, P1–P3 are inert: nothing produces a null-cons word yet, but the
decoders already accept one — the same staging discipline as HEAP_042.

---

## 5. Implementation detail

### 5.1 P0+P1 — the bit substrate

**Rename** (mechanical; the field is never read, only asserted zero):
`runtime/src/allocator/Heap.hpp:199-207` (comment + field),
`eco-kernel-cpp/src/eco/ExportHelpers.hpp:41-48`,
`elm-kernel-cpp/src/ExportHelpers.hpp:20,53-54`, `THEORY.md:154,162`,
`runtime/src/codegen/Ops.td` HPointer comment, and the
`design_docs/theory/heap_representation_theory.md` layout section. Grep
`enum_idx` afterwards; expect zero hits outside this plan and the audit doc
note at `design_docs/kernel-boundary/audit-04-*.md:304` (update it too).

**Heap.hpp** (all next to the existing `isConstantBits` family at :306-336):

```cpp
enum Constant : u64 {
    Const_False = 0,
    Const_True  = 1,
    Const_Empty = 2,   // unifies Unit / EmptyRec / Nil / Nothing / ""
    Const_NullCons = 3 // nullary ctor; tag in null_cons_idx (bits [43,53))
};

#define NULL_CONS_SHIFT 43
#define NULL_CONS_MAX   1023          // 10 bits; the full range is usable

// Is this word an embedded nullary-constructor constant?
inline bool isNullConsBits(u64 b) {
    HPointer hp = hpFromBits(b);
    return hp.ptr_ind != 0 && hp.constant == Const_NullCons;
}

// The ctor's zero-based declaration index, verbatim.
// Only valid when isNullConsBits(b).
inline u32 nullConsTagBits(u64 b) {
    return static_cast<u32>(hpFromBits(b).null_cons_idx);
}

// Compose the word for a ctor's declaration index. Callers guarantee
// idx <= NULL_CONS_MAX (the compiler crashes otherwise).
inline u64 nullConsWordFor(u32 idx) {
    return (static_cast<u64>(idx) << NULL_CONS_SHIFT)
         | (1ULL << 2) | Const_NullCons;                          // …0b111
}
```

Keep `isEmptyBits` (`constant == Const_Empty`, exact — no collision) and
`boolValueBits` unchanged.

**`value_enc`** (`EcoToLLVMInternal.h:239`, the codegen mirror): add
`NullCons = 3` to `ConstantKind`, plus `constexpr unsigned NullConsShift = 43;
constexpr uint64_t NullConsMax = 1023;` and an
`encodeNullCons(uint64_t idx)` mirroring `nullConsWordFor`. Add
static_asserts in `EcoToLLVMHeap.cpp` (next to the existing `TagCustom`
cross-checks at :52) tying these to the Heap.hpp macros.

**Runtime `eco_get_tag`** (`RuntimeExports.cpp:4055`) — the embedded arm
becomes three-way; order matters because today's code falls through to
`boolValueBits` for any non-Empty constant, which would misread a null-cons
word as `True`:

```cpp
if (isConstantBits(val.bits)) {
    if (isNullConsBits(val.bits)) return nullConsTagBits(val.bits);
    if (isEmptyBits(val.bits))    return CONSTANT_TAG;
    return static_cast<uint32_t>(boolValueBits(val.bits));
}
```

**Open-coded diamond** (`expandGetTagMarkers`, `EcoBackend.cpp:1637-1690`):
the embedded branch currently computes
`select(isBool, zext(isTrue), CONSTANT_TAG)`. Extend it, keeping all direct
`ptrtoint` users in the same block (REP_LLVM_001(d), as the existing code
comments demand):

```
%constField = and %bits, 3                          ; existing
%isNullCons = icmp eq %constField, 3
%idx        = and (lshr %bits, 43), 1023            ; trunc to i32
%embTag     = select %isNullCons, %idx,
              select(%isBool, zext(%isTrue), CONSTANT_TAG)   ; existing tail
```

(`lshr` of the `ptrtoint` result is a derived i64 in the same block — the
same acceptance class as the existing `constField`.)

**Golden tests**: extend `test/allocator/HPointerLayoutTest.cpp`
(`testHeaderWordComposition` discipline): pin words `0x7` (ctor 0),
`(1<<43)|0x7` (RBEmpty's index), `(1023<<43)|0x7` (capacity edge); assert
`isNullConsBits`, `nullConsTagBits` round-trips verbatim, `isConstantBits`
true, `isEmptyBits` false, `boolValueBits` irrelevant-but-untriggered, and
that `eco_get_tag` on these words returns 0, 1, 1023. Also assert
`nullConsWordFor(0) == 0x7` ≠ 0x4/0x5/0x6.

### 5.2 P2 — the validators that reject the new words

The GC needs nothing (§1), but the encode/decode validators do:

- `elm-kernel-cpp/src/ExportHelpers.hpp:53-54` and
  `eco-kernel-cpp/src/eco/ExportHelpers.hpp:41-48`: the constant-path
  condition `ptr_ind != 0 && ptr == 0 && null_cons_idx == 0 && padding == 0`
  must drop the `null_cons_idx == 0` conjunct **when `constant == 3`** (or
  simply: constant path = `ptr_ind != 0 && ptr == 0 && padding == 0`, since
  legacy constants have the field zero anyway). The *pointer*-path assert
  (`ptr_ind == 0 && null_cons_idx == 0 && padding == 0`) stays exactly as
  is — real pointers still zero the field.
- Audit for other zero-asserts and range tests. Run and fix every hit of:

  ```
  grep -rn "null_cons_idx\|padding == 0\|<= 0x6\|== 0x6\b\|< 0x8\|HPOINTER_ADDRESS_LIMIT" \
      runtime/src elm-kernel-cpp/src eco-kernel-cpp/src
  ```

  Known-safe classes: `HPOINTER_ADDRESS_LIMIT` comparisons guard *address*
  arithmetic and sit behind `ptr_ind == 0` checks (a null-cons word is never
  address-classified because its `ptr_ind` is 1); `isEmptyBits` is exact on
  `constant == 2`. Anything comparing a raw word against the literal set
  {0x4, 0x5, 0x6} to mean "any constant" is a bug to fix — the only verified
  instance of that *shape* is `expandValueEqFastPath`'s bit-4 test
  (`EcoBackend.cpp:1478`), which is already generic (`and (or a,b), 4`) and
  therefore correct for null-cons unchanged.
- `ECO_HEAP_VALIDATE` walkers: grep `ECO_HEAP_VALIDATE` blocks in
  `NurserySpace.cpp`/`OldGenSpace.cpp`/`Allocator.cpp` for slot-word
  validation; the copy-preservation assert
  (`NurserySpace.cpp:900 assertHeaderPreservedAcrossCopy`) is header-side
  and unaffected. Expect the walkers to be `ptr_ind`-gated already; fix any
  that whitelist exact constant words.

### 5.3 P3 — kernel single representation

**P3.0 — demote `RBEmpty` from the reserved-tag set.** The complete consumer
list of 0xFFFE (grep-verified 2026-08-19; nothing else in the tree touches
it):

| site | change |
|---|---|
| `CtorTag.elm:93` (`effective`'s RBEmpty arm) | delete the arm — RBEmpty returns `Index.toMachine index` (= 1) like every other ctor; every compiled branch tag, `CtorShape.tag`, and `MonoEnum` tag derives from this one function, so dispatch stays consistent by construction |
| `Utils.cpp:59,65` (`isDictCtor`'s RBEmpty half) | drop it; keep the RBNode half. Post-embedding an RBEmpty never reaches `eqHelp` as a heap object (either-side-embedded short-circuits at `resolveAndCompare`), so the arm is dead; the RBNode test alone routes every remaining heap-Dict comparison to `dictEq` |
| `Utils.cpp:753` comment | update (RBEmpty is an embedded constant now) |
| `HttpExports.cpp:77,166` (`rbEmpty()` builds header Dicts kernel-side) | constant becomes `1`; via the choke point below the call then returns the embedded word — this is a CONSTRUCTION site only, it never tests the tag |
| `GCStats.cpp` ctor-census reserved rows (`kCtorDictRBEmpty`) | retire the RBEmpty row (nothing will carry 0xFFFE); keep RBNode's |
| `Heap.hpp:342` / `CtorTag.elm` docstrings | reserved set is now {0xFFFF RBNode, 0xFFFD CONSTANT_TAG} |

RBNode's 0xFFFF is untouched — it carries all the real weight (`eqHelp`
dispatch, `dictEq` spine walk) and, being 5-field, never meets this
mechanism.

**The choke point.** `alloc::custom(u16 ctor, const std::vector<Unboxable>&
values, u64 unboxed_mask)` — `runtime/src/allocator/HeapHelpers.hpp:1364`
(namespace `alloc`; shared by BOTH kernel trees and the runtime itself; the
`ok`/`err` helpers at :1405-1435 route through it): when the field list is
empty, return the embedded word instead of allocating:

```cpp
if (fields.empty()) {
    // Single-representation invariant (plans/null-cons-hpointer-embedding.md
    // §2.3): nullary ctors are embedded HPointer constants, never heap
    // objects — resolveAndCompare/eco.value.eq decide by word (in)equality
    // the moment either side is embedded, so a heap copy here would make
    // equal values compare unequal.
    assert(ctor <= NULL_CONS_MAX);
    return hpFromBits(nullConsWordFor(ctor));
}
```

This converts every kernel construction site at once — verified population:
`Utils.cpp:35-39` (Order LT/EQ/GT), `Bytes.cpp:71` (Endianness),
`Browser.cpp:79,83,102`. Then simplify `initOrderSingletons`
(`Utils.cpp:33-49`): the three statics become plain constant words; **delete
the `eco_gc_add_value_root` registrations and the init-once flag** (rooting a
constant is dead weight; the getters can become
`return Export::encode(hpFromBits(nullConsWordFor(ORDER_LT)))` one-liners).
Sweep for any other direct 0-field construction that bypasses `alloc::custom`:

```
grep -rn "Tag_Custom" elm-kernel-cpp/src eco-kernel-cpp/src | grep -iv "tag ==\|getTag\|== Tag_Custom"
```

**Backstop at the compiled-code boundary**: once P4 lands, add op verifiers
rejecting the 0-field form on `Eco_CustomConstructOp` ("eco.construct.custom",
`Ops.td:964` — the op `generateEnum`/`generateCtor` emit today) and on
`Eco_AllocateCtorOp` ("eco.allocate_ctor", `Ops.td:1618`, `size == 0 &&
scalar_bytes == 0`). The compiler no longer emits either shape; a stray
emission should fail loudly at MLIR verification, not silently mint a second
representation. Add a debug `assert` in the runtime custom-alloc export as a
final backstop.

**Kernel walkers**: no changes needed — verified: `resolveAndCompare`
(word-equality on either-embedded, §2.3 makes it *correct*), `dictEq`'s
`resolveCustom` (`Utils.cpp:750`: embedded → nullptr → spine end — precisely
the RBEmpty-as-constant behavior), list walkers (Nil has been embedded since
D3). One audit remains: `grep -n CONSTANT_TAG` consumers in the **debug
printer** (the `arg_type_ids`-driven type-table printer; find it via
`grep -rn "CONSTANT_TAG\|arg_type_ids" runtime/src elm-kernel-cpp/src`) — it
prints merged empties today by leaning on the expected type; add the
null-cons arm: `(context type_id, nullConsTagBits(word))` → ctor name from
the type table. Cosmetic (`Debug.toString`), but do it in P3 while the file
is open.

### 5.4 P4 — compiler emission

**New op** (`Ops.td`, next to `Eco_ConstantOp` :1838):

```tablegen
def Eco_ConstantNullConsOp : Eco_Op<"constant.null_cons", [Pure]> {
  let summary = "Embedded nullary-constructor constant";
  let description = [{ Materializes the HPointer word for a nullary
    constructor: (idx << 43) | 0b111, where idx is the ctor's zero-based
    declaration index. See plans/null-cons-hpointer-embedding.md §2.1. }];
  let arguments = (ins I64Attr:$tag);        // declaration index
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$tag attr-dict";
}
```

Lowering: clone `ConstantOpLowering` (`EcoToLLVMTypes.cpp:23-40`) —
`value_enc::encodeNullCons(op.getTag())` → i64 → `inttoptr` to the HPtr type;
`report_fatal_error` if the tag violates §2.2 (backstop; the Elm side crashes
first with a better message). Register in the pattern set at :137. Pure +
constant means LLVM folds/rematerializes it freely — the same class as
`eco.constant`, whose True/False words already ride through every RS4GC
flavour and statepoint as addrspace(1) constants (GC skips them in stackmap
slots via the ptr_ind predicate; no new interaction).

**Elm op builder** (`Ops.elm`, next to `ecoConstantTrue` :138):
`ecoConstantNullCons : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )`
emitting `"eco.constant.null_cons"` with the `tag` I64 attr.

**The emission predicate + capacity crash**, in `Compiler.Data.CtorTag`
(keeping the policy beside `effective`/`isEmbeddedConstantCtor`):

```elm
-- Nullary ctors embed as HPointer null-cons constants carrying their
-- zero-based DECLARATION INDEX, EXCEPT the legacy three whose bit patterns
-- predate this mechanism (True/False via Bool, Nothing via the merged empty
-- 0x6 — see D3). RBEmpty is index 1 like any other ctor once P3.0 demotes
-- its reservation.
nullConsCapacity : Int
nullConsCapacity = 1023

embedsAsNullCons : Name -> Int -> Bool          -- name, effective tag
checkNullConsCapacity : Name -> Int -> Int      -- crashes past capacity
```

`checkNullConsCapacity` crashes (hard crash accepted, §2.2) with:
`"nullary constructor '<name>' has declaration index <n>, exceeding the
10-bit HPointer null_cons_idx capacity (1023); widen the field using the
padding bits — see plans/null-cons-hpointer-embedding.md §2.2"`.

**`generateEnum`** (`Functions.elm:1897`): the non-well-known arm replaces
`Ops.ecoConstructCustom ctx1 [] resultVar tag 0 0 [] maybeCtorName` with
`Ops.ecoConstantNullCons ctx1 resultVar (checkNullConsCapacity name tag)`.
**Delete the CAF-slot wrapping for enums** — in the `Mono.MonoEnum` dispatch
arm (`Functions.elm:480-521`), `cafQualifies` becomes `False` (keep the
comment: a constant-returning body needs no once-guard, and a slot would be a
second copy of nothing). The incoming `tag` is already effective
(`Specialize.elm:1654` mints `MonoEnum` through `CtorTag.effective`; identity
for enums since Dict is Normal) — the capacity check still runs.

**`generateCtor` arity-0 arm** (`Functions.elm:1809`): same substitution in
the `_ ->` branch (the three well-known names keep their `eco.constant`
emissions), using `ctorLayout.tag` — which after
P3.0 is the plain declaration index for every nullary ctor, RBEmpty (= 1)
included (`CtorShape.tag` is minted through `CtorTag.effective`). Delete this arm's CAF
wrapping too (`Functions.elm:696` region — the nullary-custom M4 case; the
non-nullary value-thunk CAF machinery is untouched).

**Reference-site inlining** (`Expr.elm:658 generateVarGlobal`): before the
arity-0 `eco.call` emission, consult a new `Ctx.nullConsBySpec : Dict Int Int`
(SpecId → effective tag) and emit the constant directly:

```elm
case Dict.get specId ctx.nullConsBySpec of
    Just tag -> {- Ops.ecoConstantNullCons …; no call, no ops beyond it -}
    Nothing  -> {- existing arity-0 call path -}
```

Build `nullConsBySpec` where `ctorBySpec` is populated (grep
`Ctx.setCtorBySpec` / the node fold in `Backend.elm`; `Context.elm:318,346`
hold the field and setter): collect `MonoCtor shape _` with
`shape.fields == []` (excluding the three well-known names) and
`MonoEnum tag _` (same exclusion). The spec `func.func`s still exist and now
*return* the constant, so any reference path not routed through
`generateVarGlobal` (none known) would still observe the single
representation — the inlining is a perf layer, not a correctness layer.
The other `MonoVarGlobal` arms in `Expr.elm` (:1769, :2509, :2689, :2802,
:3226) are call-head/argument positions where a nullary ctor cannot appear as
a callee with args; leave them.

**`ctorInline` (`aggp` family)**: the saturated-ctor inline path documents
"nullary excluded — CAF-memoized singletons" (`Eco/Config.elm:40`). The
exclusion is now satisfied by `nullConsBySpec` interception one level up;
update the comment to cite this plan instead of CAF.

**What is NOT touched in the compiler**: `Patterns.elm`, decision trees,
`TailRec`, `eco.case` lowering, LSS/AbiCloning, the mono engines — dispatch
uniformity through get_tag (§2.4) is the whole point. `CafHoist`/`CafDedupe`
(default-off) operate on `MonoDefine` bodies, never on the bodiless
`MonoCtor`/`MonoEnum` specs (`CsePurity.elm:130`), and a hoisted expression
whose *value* is an embedded word stores the word itself — single
representation is preserved without changes there. The permanent-space
promoter (`eco_caf_promote`) deep-copies aggregates and skips
`isConstantBits` words — embedded members ride along unchanged.

### 5.5 P4½ — MLIR-level tests

Codegen fixtures (the `test/codegen/*.mlir` discipline, cf.
`fast_dispatch_pap_prefix.mlir`): one fixture pinning
`eco.constant.null_cons {tag = 5}` lowering to `inttoptr ((5<<43)|7)`; one
pinning the get_tag diamond's null-cons arm (feed the constant through
`eco.case` and FileCheck the select chain). Elm E2E
tests (`test/elm/src/`): an enum round-trip (case over a 4-ctor enum returned
from a function), a Normal-union nullary test (construct/match/equality of a
`type T = A | B Int` value in both arms), a Dict test asserting
`Dict.empty == Dict.remove k (Dict.singleton k v)` and iteration over a tree
that shrinks back to empty (exercises embedded RBEmpty in slots, dictEq, and
promotion), and an Order test (`compare 1 2 == LT` — exercises the
kernel-vs-compiled single representation END TO END; this is the test that
would have caught the resolveAndCompare landmine).

### 5.6 P5 — GC/validate closure

- Re-run the §5.2 grep audit post-P4 to catch anything the build surfaced.
- Add to the `ECO_HEAP_VALIDATE` object walk (both spaces): assert no live
  `Tag_Custom` header with `size == 0` — the single-representation tripwire.
  Site: wherever the walker already switches on `header->tag`
  (`NurserySpace`/`OldGenSpace` validate blocks); message cites §2.3.
- Run the heap-validate suite (the full-suite discipline from
  `heap-validate-suite-rot`: **all** of it, not the historical subset).

### 5.7 P6 — gates and measurement

Standard gates, in order:

1. `elm make` type-check of `compiler/src/Terminal/Main.elm` (fast loop).
2. Runtime unit tests incl. the new golden words; `libEcoRuntimeStatic.a`.
3. `--target full` (E2E 1,675 baseline; NOT byte-identical output — this is
   a representation change, `out.mlir` legitimately moves; determinism gate
   instead: two cold runs byte-identical to each other).
4. `--target elm-tests` — expect exactly the 12 pre-existing failures.
5. Bootstrap: full self-compile chain incl. Stage-4b JS fixed point, and
   `ECO_MONO_VALIDATE=1` clean.
6. Heap-validate suite with the new 0-field assert armed.
7. Purge `eco-stuff` between every leg (representation changes make stale
   caches actively misleading).

**Census re-run** (relink trick from LH1: keep the `.mlir`, `rm` the binary,
~2-min relink for runtime-only iterations — but P4 changes the compiler, so
the first census needs a full bootstrap): expect the promoted 0-field bucket
to collapse from 28,645,830 to ≈0 (the ctor table should show the
`Dict.RBEmpty_elm_builtin` row vanish), `promoted` down ~6.0% in objects and
~3.2% in MiB, copied-in-nursery down ~62M. Any residual 0-field promotion is
a missed construction path — the validate assert (§5.6) turns it into a
failure rather than a curiosity.

**Benchmark** per `benchmarks/lss-opt.md`: A/B, two binaries (pre = tree
before P4, post = after), one frozen corpus is impossible (compiler source
changes are the corpus — say so in the entry per the cross-row discipline);
judge on counters first: minors, majors, promoted. Run R's determinism means
a majors step (17 → lower) is attributable, not lottery. Record the
`(nfields, ctor)` table in the entry as the mechanism witness.

## 6. Invariants (add/amend in `design_docs/invariants.csv`)

- **HEAP_044** (new): the null-cons encoding — word `(idx<<43)|0b111`,
  `constant == 3` discriminant, idx = the ctor's zero-based declaration
  index verbatim (no type identity, no remap; the Dict reserved set shrinks
  to RBNode 0xFFFF + CONSTANT_TAG 0xFFFD), capacity 1023 enforced by
  compile-time crash; **single
  representation**: no live heap `Tag_Custom` with 0 fields exists after
  P4 (heap-validate asserts it); GC classifies null-cons words by the
  existing `ptr_ind != 0` predicate and never dereferences them. Owners:
  `Heap.hpp` helpers + `value_enc` + `alloc::custom` + validate walkers +
  `HPointerLayoutTest`.
- **CGEN_079** (new): emission rule — nullary ctors (except the legacy
  True/False/Nothing set) compile to `eco.constant.null_cons` with the
  declaration index (which `CtorTag.effective` now returns for every
  nullary ctor, P3.0); `eco.allocate_ctor`/`eco.construct.custom` with size 0 is
  a verifier error; both tag extractors (`eco_get_tag`,
  `expandGetTagMarkers`) return the effective tag for null-cons words, which
  is what keeps every case/decision-tree path representation-agnostic.
- **Amend CGEN_068/069** (CAF memoization): nullary-ctor and enum specs are
  no longer CAF-memoized (they compile to constants; a slot would be a
  second copy and a wasted guard).
- **Amend HEAP_035** (CAF slot marking): note that "embedded-constant words
  skipped" includes null-cons words (same predicate).

## 7. Traps (each pre-verified against the tree)

- **`resolveAndCompare` / `eco.value.eq` decide by word the moment either
  side is embedded** (`Utils.cpp:94-101`, `EcoBackend.cpp:1462`). Landing
  compiler emission without the kernel choke point (or vice versa) makes
  `compare a b == LT` false. P1–P3 and P4 must not be split across a tested
  boundary in a way that lets one side construct heap nullary customs the
  other side embeds.
- **`eco_get_tag`'s current fallthrough** maps any non-Empty constant to the
  Bool arm — a null-cons word would read as `True`. The three-way arm in
  §5.1 must land with (or before) anything that can produce the words.
- **Two tag extractors, one truth**: the runtime function and the open-coded
  diamond must both learn the arm; the codegen fixture in §5.5 pins the
  diamond, the golden test pins the function, and the E2E dict/order tests
  pin their agreement.
- **The ExportHelpers validators** (both kernels) currently *reject* the new
  words at every kernel boundary crossing (`assert`/fallthrough on
  `null_cons_idx == 0`). P2 is not optional polish; the first Order value
  crossing `Export::decode` fires it.
- **Tag provenance is UNIFORM — verified, do not re-derive it.** Both arms
  already carry EFFECTIVE tags: `MonoEnum` is minted as
  `Mono.MonoEnum (CtorTag.effective home name tag) t` (`Specialize.elm:1654`;
  solver twin `MonoSolver/Monomorphize.elm:771`), and `CtorShape.tag` comes
  from `CtorTag.effective` (`Monomorphize/Analysis.elm:466`). Do not apply
  `CtorTag.effective` a second time at emission — for enums it is the
  identity today, but a double application is exactly the kind of latent bug
  a later reserved-tag addition would detonate.
- **P3.0's demotion must land with P4, not before or after in isolation.**
  Compiled branch tags, `CtorShape.tag`, the kernel's Dict constants and the
  embedded words all move from 0xFFFE to 1 in one tree; a binary mixing
  conventions mis-dispatches every `case` on an empty Dict. All compiler
  sides derive from the single `CtorTag.effective` function (safe by
  construction); the kernel constants (`Utils.cpp`, `HttpExports.cpp`) are
  the two hand-synced spots — the E2E Dict test plus the eco-stuff purge
  discipline are the gates.
- **Do not touch the merged empty.** Nil/Nothing/Unit/EmptyRec/"" share one
  bit pattern by design; giving `Nothing` a null-cons word would break
  `[] == Nothing`-class punning that D3 deliberately merged (the type
  checker guarantees such comparisons don't typecheck, but the RUNTIME
  representation sharing is load-bearing for list/string ops on 0x6).
- **`hpFromBits`, never manual bit surgery** (the
  `hpointer-representation-redesign` lesson) — all new helpers above go
  through it.
- **Ninja is env-blind and does not relink `eco-compiler` on runtime-only
  changes** — `rm -f "$BK/bin/eco-compiler"` before rebuilding, keep the
  `.mlir` when the compiler is unchanged (LH1 trap; ~2-min relink).
- **`--target ecor` does not link** (pre-existing `PermanentSpace.cpp`
  omission) — build `libEcoRuntimeStatic.a`/`eco-compiler`, don't chase it.

## 8. Non-goals

- Widening `null_cons_idx` beyond 10 bits (documented escape hatch only).
- Migrating True/False/Nothing/the merged empty onto the new encoding.
- Per-type disambiguation of embedded words at runtime (a null-cons word
  deliberately carries no union identity, exactly like today's heap `ctor`
  field carries none; `Debug.toString` recovers names via the type table).
- Unboxing non-nullary ctors, changing `Can.Unbox`, or any REP_* change —
  a null-cons value is an ordinary `!eco.value` word everywhere.
- Reclaiming the CAF machinery for non-nullary value thunks (untouched).
