---
status: partial
updated: 2026-11-25
remaining: "H10 gates (USER): cmake --build build --target full and --target bootstrap after the commit (bootstrap already passed once on the implemented tree); ECO_HEAP_VALIDATE deferred by the user"
---

# Hashed values and hash-consing: explicit `Hashed` for structures, automatic hashes for Strings

This plan combines the two halves of plans/hash-reuse-explicit-vs-cached.md:

- **Strings keep Part B** as built on branch `hash-cache`: the HEAP_088 slot holding definition v4
  (CRC32C), composition at build, and the `==` slot fast-reject. No API. Nothing here changes them.
- **Every other structure uses an explicit `Hashed a`** (Part A's idea), made compositional so that
  a program can hash-cons recursive data. `Hash.hashed : a -> Hashed a` makes a small heap object
  of its own kind, `Tag_Hashed`, holding the value's hash and a pointer to the value. Hashing any
  value that contains a `Hashed` reads the stored hash in O(1) instead of walking that part again.
- **The value hash loses its bounds (definition v5)**, so that a stored hash is exactly what a walk
  of the value computes, and two structures that differ anywhere hash differently (up to ordinary
  collisions). v5 also fixes NaN (canonical) and Bytes (hashed by content; v4 is unsound for Bytes).
- **New `HashedDict` and `HashedSet`** in eco/system, keyed by `Hashed k`, with
  `HashedDict.lookup`, `HashedSet.find` and `HashedSet.intern` returning the stored (canonical) key.

The compiler's own code does not adopt any of this (D5); its hash-consing
(`Compiler.IR.Mono.Intern`) is unchanged.

## 0. Decisions (user, 2026-11-25)

- **D1.** Strings: automatic (Part B). Other structures: explicit `Hashed`. No hash slot or cache
  in Custom, Record or Tuple objects, and no value that secretly carries a hash.
- **D2 (revised by the user after implementation, 2026-11-25).** Keep v4's bounds (16 levels, 256
  items): v5 is v4 plus the Bytes-by-content fix and the `Hashed` row. The unbounded walk (with an
  explicit stack and canonical NaN) was implemented first and rolled back (§11). The bounds do not
  interfere with `Hashed`, which is mixed as its own number, never as a stand-in for a walk of its
  value.
- **D3.** `Debug.toString` of a `Hashed` prints its value only, on both backends; the JavaScript
  side through `compiler/kernel-overrides`.
- **D4.** A kernel license (plans/kernel-parametricity-license.md) for every new kernel and every
  kernel whose own behaviour changes (`FNV.hashed`, `value`, `hashOf`, `FNV.hash`), and a re-audit of
  every licensed kernel pinned to a file this plan edits. The unlicensed Debug kernels stay
  unlicensed: only the printer behind them changes, not what they do with functions (user,
  2026-11-25; follow-up F5).
- **D5.** No compiler adoption in this plan.
- **D6.** API names `HashedSet.find`, `HashedDict.lookup` and `HashedSet.intern` (lookup or insert,
  returning the canonical element).
- **D7. `Hashed` is a heap object kind of its own, `Tag_Hashed`** (the user chose it over a Custom
  with a reserved constructor tag, as the clearer design). §2.2 gives the struct.
- **D8. v5 keeps v4's pre-order running state** (v4 with the bounds removed) plus one row for
  `Hashed`: `mix(kHashed); mix(h)`. It is not fully bottom-up (a value's hash is not built from its
  children's finished hashes, except at `Hashed` children); that is accepted: the requirement is
  that equal values always hash equal. A fully bottom-up definition can be tried later.

## 1. What this achieves

1. **Hash-consing in eco programs without hand-written hash fields.** A recursive type that keeps
   its children as `Hashed` gets each node's hash in O(fields). A `HashedSet` hands back the one
   canonical copy of each structure, so `==` on canonical children is a pointer comparison, and two
   different structures with different hashes are told apart by one integer comparison.
2. **Structured keys hashed once.** A `HashedDict` keyed by a record or a list hashes each key when
   its `Hashed` is made, not on every operation. On a hit, `==` still compares the key's value
   unless the probe is the stored object itself (then it is a pointer comparison); a `Hashed` saves
   the hash, and canonical keys save the comparison too.
3. **An exact hash.** No depth or item bounds: structures that differ only beyond 16 levels or 256
   items no longer collide by construction. The typed chains lose their bounds bookkeeping (the item
   budget, the `arith.select` gates, the static depth cut).
4. **Two v4 bugs fixed:** equal Bytes in different forms (a buffer and a slice) hash differently
   today, and NaNs with different payloads hash differently (harmless today, wrong once `==` is made
   reflexive).
5. **Strings unchanged:** every Part B gain stands.

## 2. Design

### 2.1 Definition v5

v5 is v4 (design_docs/theory/runtime/value-hash.md, `Hasher` in `runtime/src/allocator/ValueHash.cpp`:
one FNV-1a state from the offset basis, walked in pre-order, finished with `nonZero(fmix32(h))`, bounded
by 16 levels of nesting and 256 elements, entries and fields in all) with these changes and nothing
else:

1. **Bytes** (`Tag_ByteBuffer`, `Tag_ByteBufferSlice`, `Tag_LargeByteHeader`: the three forms
   `alloc::isByteBuffer` accepts and `eqHelp` compares by content): `mix(kBytes); mix(n);
   mix(crc32c::update8(crc32c::kEmpty, data, n))` over `alloc::byteBufferView(obj)`, whatever the
   bounds. (v4 mixes `kOther ·tag`, so a slice and a buffer with equal bytes hash differently.)
2. **`Hashed`** (a `Tag_Hashed` object, §2.2) with stored hash `h`: nested anywhere, it contributes
   `mix(kHashed); mix(h)`, whatever the bounds, and its value is not walked. As the whole hashed value
   (`eco_hash_value` called on it) the result is `h` itself, so `Hash.hash (hashed x) == Hash.hash x`.
3. **New markers** appended to `enum Marker` (never renumber the existing ones): `kBytes = 17`,
   `kHashed = 18`.

Sound: row 1 hashes the bytes `eqHelp` compares; row 2 holds because `h = Hash.hash v` and equal values
have equal hashes. Every value with no Bytes or `Hashed` in it keeps its v4 number, so **no pin in
HashIdentityTest moves**. Because a `Hashed` is mixed as its own number, the bounds do not interfere with
composition: a structure built from `Hashed` parts is told apart by them however deep it is, and the
bounds still cap the cost of hashing a large plain value.

(History: the first implementation removed the bounds, walked with an explicit stack and canonicalised
NaN; it was measured and rolled back by the user's revised D2. §11 has both sets of numbers.)

### 2.2 `Hashed a`: the `Tag_Hashed` heap object

**The struct** (`runtime/src/allocator/Heap.hpp`, beside `ElmByteBufferSlice`):

```c
/**
 * A value paired with its value hash: eco/system's `Hash.Hashed` (Hash.hashed). Only the runtime
 * creates one (Eco_Kernel_FNV_hashed), fully initialised before it is published, and it never
 * changes afterwards. `value` is the only field a collector traces; `header.unboxed` and
 * `header.size` are 0. `hash` is `Hash.hash value` (design_docs/theory/runtime/value-hash.md v5),
 * never 0 (HEAP_089).
 */
struct ALIGN(8) elm_hashed {
    Header header;     // tag = Tag_Hashed, unboxed = 0, refcount = 0, size = 0
    u32 hash;          // Hash.hash of value, in [1, 2^32)
    u32 reserved;      // 0; keeps `value` 8-byte aligned
    HPointer value;    // the value, always boxed (FNV.hashed has no _Int/_Float/_Char variant)
};
typedef struct elm_hashed ElmHashed;
static_assert(sizeof(ElmHashed) == 24, "ElmHashed must be 24 bytes");
```

The header word, bit by bit (`Header`, `Heap.hpp`; `TAG_BITS` = 5):

| bits | field | value in an `ElmHashed` |
|---|---|---|
| 0-4 | `tag` | `Tag_Hashed` = 25 |
| 5-6 | `color` | mark colour (the concurrent marker writes it, as for every object) |
| 7 | `pin` | as for any object |
| 8-9 | `age` | minor collections survived |
| 10-15 | `unboxed` | 0 (`value` is always a boxed pointer; see the note below the table) |
| 16-30 | `refcount` | 0 |
| 31 | `builder` | 0 when published (the kernel writes the whole object in one allocation) |
| 32-63 | `size` | 0 (fixed size: `sizeof(ElmHashed)`) |

**Why `value` is always boxed:** a kernel can take a primitive unboxed, through a `_Int`, `_Float`
or `_Char` variant chosen by `Compiler.GenerateMlir.KernelAbi` for a fixed list of kernels. This plan
does not add `FNV.hashed` to that list, so its argument arrives boxed and is stored as an `HPointer`.
An unboxed variant (an `Unboxable` value with its kind in `header.unboxed` bits 1:0, as `Task` does)
would only help `Hashed Int`, `Hashed Float` and `Hashed Char`. Those gain nothing from `Hashed`:
their hash is already O(1). It would cost a slot-kind test at every GC site and three more kernel
variants to license. Not done (user, 2026-11-25).

**The tag:** `Tag_Hashed` goes into `enum Tag` just before `Tag_Free`, which must stay last but one:
`Tag_ListBacking` = 24, **`Tag_Hashed` = 25**, `Tag_Free` 25 → 26, `Tag_Forward` 26 → 27. Compiled
code writes only live tags, which do not move; it does compare with `Tag_Forward`, through
`value_enc::TagForward` in `runtime/src/codegen/Passes/EcoToLLVMInternal.h` (26 → 27; a
`static_assert` in `EcoToLLVMHeap.cpp` checks it) and `Elm::Tag_Forward` in `EcoBackend.cpp`.
`TAG_BITS` 5 leaves room (28 of 32 values used).

**Elm side** (`system-kernel-cpp/src/Hash.elm`), declared as a kernel-produced type the way
`JsArray2` is (`type JsArray2 a = JsArray2 a`, never constructed in Elm):

```elm
module Hash exposing (hash, Hashed, hashed, value, hashOf)

import Eco.Kernel.FNV

{-| ... (never constructed in Elm: `Eco.Kernel.FNV.hashed` builds a Tag_Hashed object) -}
type Hashed a
    = Hashed a

hashed : a -> Hashed a
hashed =
    Eco.Kernel.FNV.hashed

value : Hashed a -> a
value =
    Eco.Kernel.FNV.value

hashOf : Hashed a -> Int
hashOf =
    Eco.Kernel.FNV.hashOf
```

- The placeholder constructor's one field of type `a` gives the type table the value's type, which
  the typed `Debug.toString` printer uses (§2.3).
- **Kernel-owned:** `( "eco/system:Hash", "Hashed" )` joins `kernelOwned` in
  `compiler/src/Compiler/IR/Kernel/Visibility.elm` (beside `eco/system:JsArray2`), so no
  representation pass touches the type: `EraseWrappers` would otherwise erase a one-field
  one-constructor type. **Cost:** `NullableMaybe.admissiblePayload` rejects kernel-owned payloads, so
  `Maybe (Hashed a)` (the result of `find` and `lookup`) allocates a `Just`; and `TaggedUnions` gives
  a one-field constructor whose field is kernel-owned the `Boxed` shape, so `TList (Hashed Ty)` is a
  heap Custom, not a bare tagged word. H8 measures this; follow-up F1 (§6) can narrow both.
- **The kernels are new, in eco/system's `FNV` kernel module** (`Eco.Kernel.FNV`, which `Hash.elm`
  already imports). `Eco.Kernel.Hash` is taken: it is the compiler's eco/kernel module
  (`eco-kernel-cpp/src/eco-kernel/HashExports.cpp`), and kernel symbols are global.
  - `Eco_Kernel_FNV_hashed(HPtr v) -> HPtr`: compute `h = eco_hash_value(v)` (allocates nothing),
    then allocate an `ElmHashed` with `v` rooted (`eco_alloc_with_roots(Tag_Hashed,
    sizeof(ElmHashed), roots, 1, 0x1)`, as `StringOps::makeSlice` does), write `hash`, `reserved`,
    `value` (from `roots[0]`: the collection may have moved it), return it.
  - `Eco_Kernel_FNV_value(HPtr hd) -> HPtr`: the `value` field.
  - `Eco_Kernel_FNV_hashOf(HPtr hd) -> int64_t`: the `hash` field.
  - JavaScript twins in `system-kernel-cpp/src/Eco/Kernel/FNV.js` (§2.5).
  Native calls of `value` at a known type are inline loads (F4, done 2026-11-25). `hashOf` was removed
  from the API on 2026-11-25 (§11): `Hash.hash` of a `Hashed` gives the same number, also inline.
- **`==`:** `eqHelp` (`elm-kernel-cpp/src/core/Utils.cpp`) gets a `Tag_Hashed` arm: two `Hashed` are
  equal when their hashes are equal and their values are `==` (the same-pointer shortcut at the top
  of `eqHelp` covers identical objects). Its default arm returns `false` for an unknown tag, so the
  arm is required.
- **`compare`:** `Hashed` is not `comparable`; nothing to do.
- **The GC and every per-tag walk** learn the tag: one traced child, `value` (the same shape as
  `Tag_StringSlice`'s `base`). The sites are listed in H2.
- **Immutable after creation**, so it is friendly to the frozen heap (P1, HEAP_SNAPSHOT_001) and
  needs no new concurrency reasoning. Editing the GC's per-tag switches can still change pinned
  TLA+ regions; H2 follows the canary procedure.

### 2.3 `Debug.toString` (D3)

A `Hashed` prints as its value: `Debug.toString (hashed (Just 1))` is `"Just 1"`, and
`Debug.toString (Just (hashed (Box 1)))` is `"Just (Box 1)"`.

- **Native:** `runtime/src/allocator/RuntimeExports.cpp`. The typed printer reaches a `Hashed`
  through its type, a `Custom` type (`Hash.Hashed`, constructor `Hashed`, one field of type `a`):
  in `print_custom_heap`, before the `header->tag != Tag_Custom → "<internals>"` test, a
  `Tag_Hashed` object prints its `value` with the constructor's field 0 type id (the type's first
  constructor's first field). The untyped printer (`print_value`) gets a `case Tag_Hashed:` printing
  `value`. Parentheses need no work: `print_ctor_arg` decides them from the printed text, as elm/core
  does.
- **JavaScript:** the JS `hashed` builds `{ $: 'Hashed_elm_builtin', a: hash, b: value }` (§2.5). A
  new override `compiler/kernel-overrides/HashedDebug.js` rebinds `_Debug_toAnsiString` so that such
  an object prints as its `b`. Only development builds print values (`_Debug_toString__PROD`
  returns `'<internals>'`). Nested values reach the override because elm/core's printer recurses by
  name.

### 2.4 `HashedDict`, `HashedSet` and `SeqDict.lookup`

New exposed modules in eco/system, thin typed layers over `SeqDict`: once the walker reads a
`Hashed` key's hash in O(1), `SeqDict (Hashed k) v` behaves as wanted, so no trie code is written.

- `type HashedDict k v = HashedDict (SeqDict (Hashed k) v)`: one constructor, one field, which
  `EraseWrappers` usually erases natively (MONO_031's conditions). API: SeqDict's with `Hashed k` for
  `k`, plus `lookup : Hashed k -> HashedDict k v -> Maybe ( Hashed k, v )` (the stored key and value).
- `type HashedSet a = HashedSet (SeqDict (Hashed a) ())`. API: SeqSet's with `Hashed a` for `a`,
  plus `find : Hashed a -> HashedSet a -> Maybe (Hashed a)` (the stored element) and
  `intern : Hashed a -> HashedSet a -> ( Hashed a, HashedSet a )` (the stored element if present,
  else the argument, inserted).
- `SeqDict` gains `lookup : k -> SeqDict k v -> Maybe ( k, v )`, which both need (they cannot reach
  SeqDict's `getEntry`); it is useful on its own.
- Equality and `Debug.toString` follow SeqDict's (insertion order; internals printed).
- A key of type `Hashed k` hashes, in compiled code, through `eco.hash` of kind `value`
  (`hashPlanFor` gives `HashWalk` for it) = one call of `eco_hash_value`, which returns the stored
  hash at once. The key is already a heap pointer, so no `eco.box` is needed.

Hash-consing with it:

```elm
type Ty
    = TInt
    | TList (Hashed Ty)
    | TFun (Hashed Ty) (Hashed Ty)

cons : Ty -> HashedSet Ty -> ( Hashed Ty, HashedSet Ty )
cons ty set =
    HashedSet.intern (Hash.hashed ty) set

-- hashed (TFun a b) with canonical a, b mixes two stored hashes (O(1)); intern compares the probe
-- with the stored candidate: same hash, then TFun's fields a and b, each by pointer.
```

### 2.5 JavaScript

- `Eco/Kernel/FNV.js` gains `_FNV_hashed(v) = { $: 'Hashed_elm_builtin', a: _FNV_hash(v), b: v }`,
  `_FNV_value(h) = h.b`, `_FNV_hashOf(h) = h.a`. The `$` is a string in both build modes (the object
  is kernel-made, not compiled from a constructor). In production builds elm/core's `_Utils_eqHelp`
  tests `x.$ < 0` (Dicts), which is false for a string, so stock `==` compares `$`, then `a` (the
  hash), then `b`: correct with no override.
- `_FNV_hashHelp` recognises it: `if (value.$ === 'Hashed_elm_builtin') return _FNV_mix(_FNV_mix(h,
  18), value.a);` and `_FNV_hash` returns `value.a` for a top-level `Hashed`. So JS also gets the O(1)
  shortcut and `Hash.hash (hashed x) == Hash.hash x`.
- The JS hash otherwise stays as it is: a separate function with its own numbers and its own depth
  bound (`depth > 16`), which is sound (equal values stay equal under a bound). **Values differing
  only below depth 16 still collide on JS**; tests of that are native-only.

## 3. Ground truth (verified 2026-11-25 on the `hash-cache` working tree, and by the review)

- **Walker:** `struct Hasher` in `runtime/src/allocator/ValueHash.cpp`: one running state, pre-order,
  bounded by `kMaxDepth = 16` and `kMaxItems = 256`, recursing on the C stack (`boxed` → `slot` →
  `boxed`, `dict` recursive on the left subtree). `enum Marker { kInt = 1, kFloat, kChar, kString,
  kEmpty, kConst, kTuple, kList, kListEnd, kCustom, kRecord, kArray, kDict, kSeqDict, kOther, kTag }`
  (kTag = 16). A word's bits 43-52 (`wordTag`) are mixed first as `kTag ·tag`. `floatValue`
  normalises -0.0 only. A zero-length String mixes `kEmpty`. Bytes and closures fall to `kOther ·tag`.
  Exports `eco_hash_value`, `eco_hash_string`, `eco_hash_i64`, `eco_hash_f64`, `eco_hash_char`,
  `eco_hash_mix_string`, `eco_hash_walk(h, items, value, depth)` (result `items << 32 | h`), declared
  in `ValueHash.hpp`.
- **Typed chains:** `generateHashOp`, `hashPlanFor`, `hashPlanSize`, `hashMaxDepth`, `hashMaxItems`,
  `generateTypedHash`, `hashNodeOps`, `hashAggregateOps`, `hashGateOps`, `hashMixOp` in
  `compiler/src/Compiler/GenerateMlir/Expr.elm` (`HashPlan = HashPrim String MlirType | HashTuple ..
  | HashRecord .. | HashWalk`). Ops `Eco_HashOp`, `Eco_HashMixOp`, `Eco_HashWalkOp`,
  `Eco_HashFinishOp` (`runtime/src/codegen/Ops.td`); `HashMixOp::verify` (`EcoOps.cpp`);
  `HashMixOpLowering`, `HashWalkOpLowering` and `eco.hash`'s lowering, with the inline primitive
  mixing in `valuehash::mixPrimitive` (`Passes/EcoToLLVMArith.cpp`; its `float` arm normalises only
  -0.0); `getOrCreateHashWalk`, `getOrCreateHashMixString` (`Passes/EcoToLLVMRuntime.cpp`,
  `EcoToLLVMInternal.h`, all declared together in `materializeAllRuntimeDecls`); JIT symbols in
  `runtime/src/codegen/RuntimeSymbols.cpp`. Invariants CGEN_095 and HEAP_088 name `eco_hash_walk` /
  `eco_hash_mix_string`. `test/codegen/hash_inline_matches_runtime.mlir` covers `eco.hash` of kinds
  int, float, char, bool and value only.
- **Tags:** `enum Tag` in `Heap.hpp` ends `..., Tag_ConsChunk, Tag_ListBacking (24), Tag_Free (25),
  Tag_Forward (26)`; "Tag_Forward must be last and Tag_Free just before it". `value_enc::TagForward
  = 26` (`EcoToLLVMInternal.h:374`, `static_assert` in `EcoToLLVMHeap.cpp:50`); `EcoBackend.cpp` uses
  `Elm::Tag_Forward`; `MinorWork.hpp` has a `static_assert` on `Tag_Forward`.
- **Per-tag sites for a one-pointer object** (those that list `Tag_ByteBufferSlice` /
  `Tag_StringUtf8View`): `AllocatorCommon.hpp` (object size), `ThreadLocalHeap.cpp`
  (`initHeaderForTag`), `NurserySpace.cpp` (evacuate children; the young and old validators,
  `checkChild` / `checkOGChild`), `NurseryParallel.cpp` (`tagHasChildren`; `evacuateP`, inside the
  pinned region `TLA-REGION(NP.scanEntryP)`), `OldGenSpace.cpp` (mark `greyH`; fix-up `fixHPointer`),
  `HeapChildWalk.hpp`, `NurseryChildWalk.hpp` (two sites), `GCStats.cpp` (kind name),
  `RuntimeExports.cpp` (printer), `ValueHash.cpp` (walker), `elm-kernel-cpp/src/core/Utils.cpp`
  (`eqHelp`).
- **Allocation:** `eco_alloc_with_roots(tag, size, roots, n, mask)` (`StringOps::makeSlice`).
- **Kernel-produced Elm types:** `type JsArray2 a = JsArray2 a` (`system-kernel-cpp/src/JsArray2.elm`),
  `kernelOwned` entry `( "eco/system:JsArray2", "JsArray2" )` and the kernel rows
  `( ( "JsArray2", n ), Inspects [ ( "eco/system:JsArray2", "JsArray2" ) ] )` in `Visibility.elm`;
  `scripts/check-kernel-opaque.py` lists single-constructor types in kernel-importing modules.
  `Visibility.elm` lists FNV's kernels as `( "FNV", [ "hash" ] )`.
- **`FNV.hash`:** `Eco_Kernel_FNV_hash` = `eco_hash_value`
  (`system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp`). KernelFacts row `( "Eco", "FNV", "hash" )`
  in `compiler/src/Compiler/IR/Kernel/Facts.elm` ("a bounded read-only walk ... allocates nothing").
  No license.
- **Licensing:** a `TypeFaithful` row in `compiler/src/Compiler/Monomorphize/Solver/KernelSetFacts.elm`
  (e.g. `( ( "Elm", "Utils", "equal" ), TypeFaithful { scope = Transports } )`) plus rows in
  `kernel-license-audit.csv` (`kernel,date,plan,note`) and `kernel-license-files.csv`
  (`kernel,file,sha256,audited`); `test/scripts/check-kernel-license-manifest.sh <root> [--update]`
  requires the CSV kernels to be exactly the `TypeFaithful` rows plus the KernelIntrinsics rows. A
  license makes the compiler skip the LSS_004 poison at every call to the kernel: it changes
  compilation. `Elm.Utils.equal`, `compare`, `append`, `Elm.List.sortBy` and others are pinned to
  `Utils.cpp`. No `Elm.Debug.*` kernel is licensed. No license pins `ValueHash.cpp`,
  `RuntimeExports.cpp` or `Heap.hpp`.
- **`eqHelp`:** `if (a == b) return true;` first; Bytes by content when both are `isByteBuffer`;
  per-tag arms; the default arm returns `false`.
- **Printers:** `print_custom_heap` (typed; returns `<internals>` for a non-`Tag_Custom` object),
  `print_value` (untyped), `print_ctor_arg` (parentheses from the printed text) in `RuntimeExports.cpp`.
- **TLA+ canary** (`test/tla/README.md`, "The canary"): `NurseryParallel.cpp` and `OldGenSpace.cpp`
  hold pinned `TLA-REGION`s (`NP.scanEntryP` contains `evacuateP`'s tag switch); `RuntimeExports.cpp`
  has a census pin (model M1) whose regex matches no printer code; `ValueHash.cpp` has none.
- **JS:** `compiler/kernel-overrides/*.js`, regenerated into
  `compiler/src/Compiler/GenerateJs/KernelOverride/Files.elm` by
  `node compiler/scripts/gen-kernel-overrides.mjs > compiler/src/Compiler/GenerateJs/KernelOverride/Files.elm`;
  `SeqDictEquality.js` is the pattern. elm/core 1.0.5 `Debug.js`: `_Debug_toString__PROD` returns
  `'<internals>'`; `_Debug_toAnsiString(ansi, value)` is a function declaration recursing by name.
- **eco/system:** `SeqDict.elm` (`getEntry : Int -> k -> Node k v -> Maybe (Entry k v)`,
  `Entry Int Int k v`); `SeqSet = SeqSet_elm_builtin (SeqDict a Bool)`; `elm.json` `exposed-modules`;
  `scripts/make-docs-package.js` for `docs.json`. `/work/ecosyskernel` is absent.
- **Inline whitelist:** `InlineSimplify.defaultWhitelist` lists `eco/system:SeqDict.get` etc.
- **Tests:** `test/eco-system/src/HashTest.elm`, `HashTypedTest.elm` (both backends; a `bounds`
  group), `HashIdentityTest.elm` + `HashIdentityGenericTest.elm` (native only, `SKIP-JS`; pins; no
  NaN or Bytes in the corpus), `SeqDictHashOnceTest.elm`; unit tests
  `test/allocator/StringHash*Test.cpp`. `alloc::ListCursor` has only an explicit constructor.

## 4. Steps

Each step ends with its targeted tests, run once with output to a file in the scratchpad. Wipe stale
E2E caches before any E2E run that follows a compiler, runtime or eco/system change:
`build/test/*/eco-stuff` and the eco/system artifacts under `~/.eco/0.2.0/packages` (memory "E2E
STALE CACHES"). Unit test binaries are built by name (memory "TEST BINARIES NOT IN ALL"). The full
gates run once, at the end (H10), and only on the USER's go-ahead.

### H0. Preconditions (USER)

1. Part B (`hash-cache`) committed; its owed full gate run (`full` and `bootstrap`). The
   ECO_HEAP_VALIDATE gate is not a precondition: the user deferred it to a much later date (2026-11-25).
2. A branch for this plan, from `hash-cache`.
3. H8's baseline is the Part B final binary `local-dev/hashreuse/bench-final` (and
   `post-v4-final-bench.json`); comparisons with it are interleaved, never across sessions.

### H1. Expose the Bytes bug as a test first (memory "EXPOSE BUGS AS TESTS FIRST")

1. `test/eco-system/src/HashBytesTest.elm` (`-- SKIP-JS: JavaScript hashes all Bytes alike`): build
   Bytes `b` with `Bytes.Encode.encode` (64 bytes), and a slice of a larger buffer with the same 64
   bytes (decode with `Bytes.Decode.bytes 64` after skipping a prefix: that yields a
   `Tag_ByteBufferSlice`, as `test/kernel/KernelExportsTest.cpp`'s slice cases show). Print `b == s`
   (`True`) and `Hash.hash b == Hash.hash s` (expected `True`). Mark the second CHECK with the E2E
   harness's XFAIL form (grep an existing `XFAIL` test under `test/` for the exact syntax). Run it:
   it must fail as expected now.

### H2. The `Tag_Hashed` heap object (runtime only)

1. `Heap.hpp`: insert `Tag_Hashed` before `Tag_Free` with a comment (`An ElmHashed.`); add §2.2's
   struct and `static_assert` beside `ElmByteBufferSlice`; add a line to the `Tag` comment that the
   tag numbers of `Tag_Free` and `Tag_Forward` moved (runtime-only tags) on 2026-11-25.
2. `EcoToLLVMInternal.h`: `value_enc::TagForward = 27`. Build: the `static_assert`s in
   `EcoToLLVMHeap.cpp` and `MinorWork.hpp` must pass. Grep `runtime/src` and `test/` for other
   literal uses of 25 or 26 as a tag (`grep -rn "Tag_Free\|Tag_Forward"` and any table indexed by tag,
   e.g. `GCStats.cpp`'s name table, census arrays sized by tag count) and fix them.
3. Every per-tag site in §3's list, each beside its `Tag_StringSlice` / `Tag_ByteBufferSlice` case and
   in its idiom:
   - `AllocatorCommon.hpp`: size `sizeof(ElmHashed)`.
   - `ThreadLocalHeap.cpp` `initHeaderForTag`: `size = 0`, nothing else (no hash slot).
   - `NurserySpace.cpp`: evacuate `value` (`evacuate(h->value, oldgen, promoted_objects)`); young
     validator `checkChild(h->value, "hashed-value", 0)`; old validator `checkOGChild(h->value, scan,
     "hashed-value", 0)`; the validators also check `h->hash != 0 && h->reserved == 0`.
   - `NurseryParallel.cpp`: `tagHasChildren` returns true; `evacuateP(w, h->value, parent_old)`.
   - `OldGenSpace.cpp`: mark `greyH(h->value)`; fix-up `fixHPointer(h->value)`.
   - `HeapChildWalk.hpp` (`visit(h->value)`), `NurseryChildWalk.hpp` (both sites).
   - `GCStats.cpp`: `"Hashed"`.
   - Any other switch that `grep -rn "case Tag_StringSlice\|case Tag_ByteBufferSlice"` over `runtime/src`,
     `elm-kernel-cpp/src`, `eco-kernel-cpp/src` and `system-kernel-cpp/src` finds and that is not
     String- or Bytes-specific.
4. `elm-kernel-cpp/src/core/Utils.cpp` `eqHelp`: a `Tag_Hashed` arm (both tags `Tag_Hashed`, else
   `false`): `return ha->hash == hb->hash && <compare ha->value with hb->value one level deeper,
   through the same path the Tuple/Custom arms use for a boxed field, including the depth-100
   deferral>`. Add the matching `Tag_Hashed` case wherever `Utils.cpp` dispatches equality on tags
   (for example a typed or `equalRespectingConstants` path; grep `case Tag_Tuple2` in the file).
5. `RuntimeExports.cpp`: the printers of §2.3 (`print_custom_heap`: test `header->tag == Tag_Hashed`
   first and print `value` with the type's first constructor's field 0 type id via the same helper the
   Custom arm uses for a boxed field; `print_value`: `case Tag_Hashed:` printing `value`).
6. `design_docs/invariants.csv`: new row `HEAP_089` (6 `;`-separated fields, no `;` in the text):
   "HASHED OBJECT (plans/hashed-values-and-hash-consing.md): a Tag_Hashed object is an ElmHashed
   (header, u32 hash, u32 reserved = 0, HPointer value), created only by Eco_Kernel_FNV_hashed fully
   written before publication and never written again; hash = Hash.hash of value (value-hash.md v5),
   never 0; value is its only traced field; header.unboxed and header.size are 0. Tag_Hashed sits
   before Tag_Free (Tag_Free 26, Tag_Forward 27).", refs
   `runtime/src/allocator/Heap.hpp|system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp|runtime/src/allocator/ValueHash.cpp|elm-kernel-cpp/src/core/Utils.cpp`.
7. **TLA+ canary.** Read `test/tla/README.md` "The canary" before this step (CLAUDE.md). After the
   edits, run the canary (`test/scripts/check-tla-manifest.sh .`); it will name the pins whose code
   changed (at least `NP.scanEntryP`). For each: confirm the change only adds a case that traces one
   more pointer field (no new atomic step, lock, shared location or memory order), add an AUDIT.md
   entry to every named model ("2026-11-..: Tag_Hashed case added to the per-tag switch; traces one
   field like Tag_StringSlice; no model change needed; new hash <12 hex>"), then
   `check-tla-manifest.sh . --update`. Never just update the hash.
8. Unit test `test/allocator/HashedObjectTest.cpp` (+ `.hpp`, registered in `test/CMakeLists.txt` and
   the unit `main.cpp`, suite `HashedObject`; model on an existing GC test that allocates a slice and
   forces collections): allocate an `ElmHashed` over a fresh list, keep only the `Hashed` rooted,
   force a minor and then a major collection, check `value` still reads the same list and `hash` is
   unchanged; promote one and check the old-gen mark keeps its value alive; `eqHelp` of two
   `Hashed` over equal and unequal values.
9. Run: build `test` by name; `--filter HashedObject`, `--filter HEAP_088`; the canary.

### H3. The kernels and the Elm type

1. `system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp`: `Eco_Kernel_FNV_hashed`,
   `Eco_Kernel_FNV_value`, `Eco_Kernel_FNV_hashOf` (§2.2). Update the file's header comment.
2. `system-kernel-cpp/src/Eco/Kernel/FNV.js`: `_FNV_hashed`, `_FNV_value`, `_FNV_hashOf` (as `F`-wrapped
   kernel values only if the file's other exports are; they take one argument), and the two
   `_FNV_hashHelp` / `_FNV_hash` changes of §2.5.
3. `system-kernel-cpp/src/Hash.elm`: §2.2's declaration and three functions, with doc comments (the
   stored hash is `Hash.hash` of the value; hashing a value that contains a `Hashed` costs O(1) for
   that part; `==` and `Debug.toString` see the value). Add them to `exposing` and `@docs`.
4. `Visibility.elm`: `kernelOwned` gets `( "eco/system:Hash", "Hashed" )` with a comment
   (FNVExports.cpp builds it; ValueHash.cpp, Utils.cpp and RuntimeExports.cpp read it); the FNV kernel
   list becomes `( "FNV", [ "hash" ] )` plus `hashed`, `value`, `hashOf` with
   `Inspects [ ( "eco/system:Hash", "Hashed" ) ]` (follow the JsArray2 rows). If
   `scripts/check-kernel-opaque.py` keeps its own list, add `Hash.Hashed`; add the three kernels to
   `design_docs/elm_kernel_functions.csv` if FNV.hash is listed there.
5. `compiler/src/Compiler/IR/Kernel/Facts.elm`: rows for the three kernels (copy the FNV `hash` row's
   shape): `hashed` (`params = [ PBorrowed ]`, allocates: the `gcAlloc` value other allocating
   kernels use, evidence FNVExports.cpp lines), `value` and `hashOf` (`GcNone`, `PBorrowed`).
6. `compiler/kernel-overrides/HashedDebug.js`:

   ```js
   /*
   kind kernel
   requires Elm.Kernel.Debug
   requires Eco.Kernel.FNV
   package elm/core 1.0.5
   */
   // eco/system's Hash.Hashed pairs a value with its hash; eco's native Debug.toString prints a Hashed
   // as its value alone (RuntimeExports.cpp, Tag_Hashed). This makes elm/core's development-build
   // printer do the same. The JS kernel (_FNV_hashed) gives the object the string `$`
   // 'Hashed_elm_builtin' in both build modes; production builds print '<internals>' for every value.
   // elm/core's printer calls `_Debug_toAnsiString` by name, so a Hashed nested in other values comes
   // through here too.
   var _KernelOverride_stockToAnsiString = _Debug_toAnsiString;
   _Debug_toAnsiString = function(ansi, value)
   {
   	if (typeof value === 'object' && value !== null && value.$ === 'Hashed_elm_builtin')
   	{
   		return _Debug_toAnsiString(ansi, value.b);
   	}
   	return _KernelOverride_stockToAnsiString(ansi, value);
   };
   ```

   Regenerate `KernelOverride/Files.elm` (§3) and add the file to plans/js-kernel-overrides.md's
   override table.
7. `test/eco-system/src/HashedTest.elm` (both backends):
   - `hashOf (hashed x) == Hash.hash x` and `Hash.hash (hashed x) == Hash.hash x` for an Int, a
     String, a tuple, a list, a custom value and a tagged-union value;
   - `value (hashed x) == x`;
   - `hashed a == hashed b` exactly when `a == b`, with `a`, `b` built separately (two different
     lists with equal contents; two different ones);
   - NaN: `hashed n1 == hashed n2` is `False` where `n1 = 0/0` and `n2 = sqrt -1` (built through
     different routes, so that no pass shares one object: `eqHelp` and JS `===` short-cut identical
     objects);
   - `Debug.toString` of `hashed 1`, `hashed "s"`, `Just (hashed (Box 1))`, `[ hashed ( 1, 'c' ) ]`
     and `{ k = hashed [ 1 ] }`: the plain values' text (`1`, `"s"`, `Just (Box 1)`, `[(1,'c')]`,
     `{ k = [1] }`), the same on both backends.
8. Run: `cmake --build build --target elm-tests` (compiler files changed), E2E `HashedTest` and
   `Hash*` (caches wiped). (The walker does not yet treat `Hashed` specially: before H5 its hash is
   v4's `kOther ·tag` for every `Hashed`, which is sound but collides; H5 fixes it. If that ordering
   is unwelcome, do H5 before H3: H5 only needs the tag from H2.)

### H4. Licenses for the new and changed kernels (D4)

Per plans/kernel-parametricity-license.md §2 (procedure §2.1, checklists A-C) and
`test/scripts/check-kernel-license-manifest.sh`.

1. **New kernels** (`TypeFaithful` rows in `KernelSetFacts.elm`, audit rows in
   `kernel-license-audit.csv`, file pins in `kernel-license-files.csv` with empty sha and stamp,
   then `check-kernel-license-manifest.sh /work --update`):
   - `Eco.FNV.hashed : a -> Hashed a`: stores its argument in the result, never applies it; scope
     `Transports` (as `Elm.Utils.equal`'s row shows the form). B2: no global write; B3: no closure.
   - `Eco.FNV.value : Hashed a -> a`: returns the stored value; scope `Transports`.
   - `Eco.FNV.hashOf : Hashed a -> Int`: reads an Int; scope `Transports` (the `a` inside `Hashed a` is a
     function-capable position, so `Inert`, which needs none, does not apply).
2. **Changed kernel `Eco.FNV.hash : a -> Int`** (behaviour changes in H5), unlicensed today: audit
   (B1 the argument is read, never applied, retained or returned; B2 no global write Elm can reach:
   the `ECO_HASH_CENSUS=1` tables hold addresses for diagnostics only, and the `thread_local` frame
   vector holds raw pointers only during one call; B3 no closure); scope `Transports` (as
   `Elm.Utils.equal : a -> a -> Bool`: `a` is function-capable, so not `Inert`). Pins:
   `FNVExports.cpp`, `ValueHash.cpp`, `Heap.hpp`.
3. **Re-audits:** `Utils.cpp` changed (H2.4), so every kernel pinned to it (`Elm.Utils.equal`,
   `compare`, `append`, `Elm.List.sortBy`, ...: the manifest check names them) gets a re-audit note
   row ("Tag_Hashed arm added to eqHelp: compares two Hashed by hash then value; no application,
   retention, fabrication or type change; B1-B3 unchanged"), then `--update`.
4. **This changes compilation:** licensed calls skip the LSS_004 poison. Run `elm-tests` and the E2E
   `Hash*`, `SeqDict*` and `Hashed*` tests after it.
5. **Debug kernels: not licensed** (D4). `Debug.log`, `toString` and `todo` are unlicensed, and this
   plan changes only the printer behind them (`RuntimeExports.cpp`), not what they do with functions.
   Licensing them would change compiled output for programs passing functions through `Debug.log`
   and would pin `RuntimeExports.cpp` (5,113 lines) to the license manifest, so every later edit to
   it would need a re-audit. Follow-up F5.

### H5. Definition v5: runtime walker and typed chains (one step: they must agree)

> **Rolled back in part (D2 revised, 2026-11-25; §11).** What stands from H5: the Bytes row, the
> `Hashed` row and the top-level `Hashed` shortcut in the walker, and the H5c tests that check those
> (HashBytesTest, HashDeepTest's `big` and `nested` groups, the unit tests `Hash v5 ...` for `Hashed`,
> deep values and Bytes). Reverted to v4: the bounds (H5a.4), the explicit-stack walker (H5a.2), the
> canonical NaN (H5a.3, H5b.4), the new `eco_hash_walk` / `eco.hash.walk` signature (H5a.6, H5b.2-3) and
> the chain changes (H5b.1), with the tests that relied on them (HashTypedTest is back to its `bounds`
> group; the NaN and no-bounds tests are gone).

**H5a. Runtime (`runtime/src/allocator/ValueHash.cpp`, `ValueHash.hpp`).**

1. `enum Marker`: append `kBytes = 17, kHashed = 18` (comment: appended, never renumber).
2. Replace `Hasher`'s recursion with an explicit-stack pre-order walk that mixes into one running
   state `h` exactly in v4's order. Shape:

   ```cpp
   struct Frame {
       enum Kind : u8 { Fields, List, Dict, SeqDict, Array } kind;
       void* obj;     // the aggregate (Tuple2/3, Custom, Record, Array, Dict node, SeqDict Custom)
       u32 next;      // Fields/Array/SeqDict: next index; Dict: 0 = left pending, 1 = left done
       u32 count;     // fields/elements/entries to visit
   };
   ```

   - **Primitives, Strings, constants, Bytes, `Hashed`, closures/other:** mixed on the spot (no
     frame). A String keeps v4's `string()` exactly, including `n == 0 → mix(kEmpty)` and the slot
     read/fill code. Bytes: §2.1 row 3. `Tag_Hashed`: `mix(kHashed); mix(h->hash)`.
   - **Tagged words:** `mix(kTag); mix(tag)`, then continue with the untagged word (a tail step, no
     frame).
   - **Tuple2/Tuple3/Custom/Record/Array:** mix the marker (and the ctor for a Custom), push a
     `Fields`/`Array` frame; the loop takes the frame's next slot (kind by `tupleFieldKind`,
     `customSlotKind`, `recordSlotKind`, or the Array's element kind) until `next == count`, then
     pops.
   - **Lists:** a `List` frame keeps its cursor in a parallel `std::optional<alloc::ListCursor>` slot
     (`ListCursor` has only an explicit constructor, so it cannot sit in a plain array of frames);
     each step visits `current()` with `currentKind()` and calls `next()`; `mix(kListEnd)` when the
     frame pops.
   - **Dict (ctor 0xFFFF):** in-order traversal without a vector: a frame for node `n` first pushes
     its left subtree (if not a constant), then on return mixes key and value (slots 1, 2), then
     replaces itself by the right subtree.
   - **SeqDict (`CTOR_SEQDICT`):** iterate the order array by index (`SeqDictLayout.hpp`:
     `forEachSeqDictEntry` walks `orderArray`; replicate its hole skipping with an index in the frame
     instead of the callback).
   - **Storage:** the first 32 frames (and 32 cursor slots) in local arrays; deeper ones spill to a
     `thread_local std::vector<Frame>` (and one for cursors) reused across calls, so an ordinary hash
     makes no `malloc`. The walk allocates nothing on the Elm heap, so no collection can run and raw
     pointers stay valid for the whole walk (as in v4).
3. `floatValue`: after the `memcpy`, `if (f != f) bits = 0x7FF8000000000000ull;`.
4. Delete `kMaxDepth`, `kMaxItems`, `items` and the `depth` parameters.
5. Top-level `Hashed`: `eco_hash_value` returns `h->hash` directly when the (untagged, non-constant)
   value is a `Tag_Hashed` object; otherwise `finish(walk)`.
6. `eco_hash_walk(int64_t h, HPtr value) -> int64_t`: the walk of `value` continued from state `h`,
   returning the new state (no items, no depth, no packing). Update `ValueHash.hpp`'s declaration and
   comment. `eco_hash_mix_string` is unchanged.
7. Rewrite the file's header comment: definition v5, no bounds, the explicit stack and its spill, the
   DAG cost, `Hashed`, Bytes by content.

**H5b. Typed chains (`Expr.elm`) and ops.**

1. Remove the bounds: delete `hashMaxDepth`, `hashMaxItems`, `hashGateOps`; `generateTypedHash` starts
   from the offset basis only (no items constant); `hashNodeOps ctx path plan` returns
   `( ops, stateVar, ctx )` threading one state; `hashAggregateOps` mixes the marker and folds the
   fields with no depth test and no gates. Keep every helper top-level (memory "COMPILER BUG ...
   MUTUALLY RECURSIVE let-bound local functions").
2. `HashWalk` (lists, customs, `Hashed`, anything else) keeps its name; its op becomes
   `eco.hash.walk %state, %v : !eco.value -> i64` (one result, no `items`, no `depth`).
3. `Eco_HashWalkOp`: arguments `(Eco_Int:$state, Eco_Value:$value)`, one result; update the
   description, `HashWalkOpLowering` (one call, no unpacking), `getOrCreateHashWalk`'s type
   (`(i64, ptr) -> i64`) and its comment in `EcoToLLVMInternal.h`. `RuntimeSymbols.cpp` keeps the
   symbol.
4. `valuehash::mixPrimitive`, `float` arm: after the -0.0 select, `CmpFOp UNO v, v` → select the bits
   of the canonical NaN. This covers `eco.hash` kind `float` and `eco.hash.mix` kind `float`.
5. `test/codegen/hash_inline_matches_runtime.mlir`: add a NaN case (a non-canonical payload built with
   `arith.bitcast` of an `i64` constant) whose inline hash must equal the runtime's, and an
   `eco.hash.walk` case with the new signature.

**H5c. Tests (same step).**

1. `HashTypedTest.elm`: replace the `bounds` group with a `deep` group comparing chain and walker
   (each value hashed once through a typed call and once through `FNV.hash` passed as a function
   value, as the file already does) for a tuple nested 20 levels and a record holding a 300-element
   list. Equality of the two computations holds on both backends (on JS both are the JS kernel).
2. `test/eco-system/src/HashDeepTest.elm` (`-- SKIP-JS: the JavaScript hash keeps a depth bound`):
   two values differing only at depth 20 hash differently; two lists differing only at element 300
   hash differently; a 100,000-element list and a 100,000-deep user list type (`type L = Nil | Cons
   Int L`) hash without crashing, and twice to the same number; `Hash.hash ( hashed x, 1 )` equals
   `Hash.hash ( hashed x2, 1 )` for a separately built `x2 == x`.
3. NaN (in `HashTest.elm` if it is native-only, else a new SKIP-JS file): `0/0`, `sqrt -1` and
   `-(0/0)`, built through different routes, each hashed inline (`Hash.hash x` at type Float) and
   through the walker (inside a list): all equal.
4. H1's test: remove the XFAIL marker; it must pass.
5. `HashIdentityTest.elm` / `HashIdentityGenericTest.elm`: **no pin may move.** If one does, v5 is
   mis-implemented; do not re-pin.
6. `test/allocator/ValueHashTest.cpp` (+ `.hpp`; registered in `test/CMakeLists.txt` and the unit
   `main.cpp`, suite `ValueHash`), modelled on `StringHashComposeTest.cpp`: a 1,000,000-deep Custom
   chain hashes (no crash) and equals the same chain rebuilt; an `ElmHashed` (built with the H3
   kernel) hashes at top level to its `hash`, and inside a Tuple2 as `mix(kHashed) mix(hash)`: a
   Tuple2 holding it differs from a Tuple2 holding its value, and equals a Tuple2 holding a
   hand-built `ElmHashed` with the same `hash` over a different value (the value is not walked);
   a Bytes buffer and a slice with equal content hash alike; two Dicts with the same entries
   inserted in different orders hash alike.
7. Run once each: unit `--filter ValueHash`, `--filter HashedObject`, `--filter HEAP_088`; the codegen
   test; E2E `Hash*`, `Hashed*`, `SeqDict*` (caches wiped).

### H6. `SeqDict.lookup`, `HashedDict`, `HashedSet`

1. `SeqDict.elm`, after `get`, exposed and in `# Query`'s `@docs`:

   ```elm
   {-| The key stored in the dictionary that equals `key`, with its value. The stored key may be a
   different object from `key`: useful when keys are shared or canonical (`HashedSet.find`).
   -}
   lookup : k -> SeqDict k v -> Maybe ( k, v )
   lookup key (SeqDict_elm_builtin root _) =
       case getEntry (FNV.hash key) key root of
           Just (Entry _ _ k v) ->
               Just ( k, v )

           Nothing ->
               Nothing
   ```

   Add `"eco/system:SeqDict.lookup"` to `InlineSimplify.defaultWhitelist` (with `get`, `member`).
2. `system-kernel-cpp/src/HashedDict.elm`: `type HashedDict k v = HashedDict (SeqDict (Hashed k) v)`;
   every SeqDict function (`empty, singleton, insert, update, updateIfExists, remove, get, lookup,
   isEmpty, member, size, unorderedEquals, union, intersect, diff, merge, toList, fromList, keys,
   values, foldl, foldr, map, filter, filterMap, partition`), each unwrapping, calling the SeqDict
   function and rewrapping, with `Hashed k` for `k`. Module doc: what a `Hashed` key buys (§1.2,
   including the hit-compare caveat), insertion order, `Debug.toString` shows internals.
3. `system-kernel-cpp/src/HashedSet.elm`: `type HashedSet a = HashedSet (SeqDict (Hashed a) ())`;
   SeqSet's API (`empty, singleton, insert, remove, isEmpty, member, size, unorderedEquals, union,
   intersect, diff, toList, fromList, map, foldl, foldr, filter, partition`) over the SeqDict, plus:

   ```elm
   find : Hashed a -> HashedSet a -> Maybe (Hashed a)
   find key (HashedSet dict) =
       Maybe.map Tuple.first (SeqDict.lookup key dict)

   intern : Hashed a -> HashedSet a -> ( Hashed a, HashedSet a )
   intern key ((HashedSet dict) as set) =
       case SeqDict.lookup key dict of
           Just ( stored, _ ) ->
               ( stored, set )

           Nothing ->
               ( key, HashedSet (SeqDict.insert key () dict) )
   ```

   `map : (Hashed a -> Hashed b) -> HashedSet a -> HashedSet b` by folding into a new set (as
   SeqSet's `map` does). `unorderedEquals` as SeqSet's.
4. `elm.json`: add `HashedDict` and `HashedSet` to `exposed-modules`. Regenerate `docs.json`: `node
   system-kernel-cpp/scripts/make-docs-package.js`, then stock `elm make --docs=docs.json` inside the
   generated `.docs-package`, and copy the result over `system-kernel-cpp/docs.json` (the script's
   header describes the flow). `/work/ecosyskernel` is absent; if it returns, it needs the same API
   as `Debug.todo` stubs (memory "ECO/SYSTEM API REFACTOR").
5. Tests (both backends):
   - `test/eco-system/src/SeqDictLookupTest.elm`: a hit returns the stored key and its value, a miss
     `Nothing`.
   - `test/eco-system/src/HashedDictTest.elm`: every operation against `SeqDict` on the unwrapped
     keys, results compared after `Hash.value`.
   - `test/eco-system/src/HashedSetTest.elm`: `intern` of two separately built equal values returns
     the first (`find` gives it back; the size stays 1); `intern` of a 10,000-node tree twice returns
     canonical copies that compare equal.
6. Run: E2E `SeqDict*`, `Hashed*` (caches wiped).

### H7. Hash-consing example test

`test/eco-system/src/HashConsTest.elm` (both backends): §2.4's `Ty` (`TInt | TList (Hashed Ty) |
TFun (Hashed Ty) (Hashed Ty)`); build the same 1,000 types twice, bottom-up through `intern`; check
the set's size equals the number of distinct types, and every second-build result `==` the first
build's. No timing assertions.

### H8. Benchmarks (interleaved against the Part B final binary)

1. `examples/benchmarks/src/HashCons.elm` (new), registered in `Bench.elm`; each workload takes an Int
   size and returns a self-checking Bool (memory "BENCH HARNESS"):
   - `hashcons-plain`: `type PTy = PInt | PBool | PList PTy | PFun PTy PTy`; build N terms bottom-up
     from a pool of earlier terms (deterministic PRNG; depth ≤ 10 so the unfolded size stays
     bounded), interning each node through `SeqDict PTy PTy` + `SeqDict.lookup`; check: the number of
     distinct nodes.
   - `hashcons-hashed`: the same terms as `HTy` with `Hashed` children and `HashedSet.intern`; same
     check (equal to the plain count).
   - `seqdict-structkeys` / `hasheddict-structkeys`: 20,000 keys `( List Int, String )` with 50-element
     lists; each looked up 20 times. The hashed variant makes the keys `Hashed` once and probes with
     the same `Hashed` objects (the "hash once, reuse the key" pattern, where the hit compare is a
     pointer comparison); say so in the workload description.
2. Runs: the whole suite (`--skip-js --no-build`, the `bench-full.sh` route) on the new binary, then
   an interleaved A/B (the `local-dev/hashreuse/ab4.sh` route) of the hash-heavy workloads (every
   `seqdict-*`, `seqset-*`, `dict-*`, `pair*`, `string-eq-prefix`) against
   `local-dev/hashreuse/bench-final`. The four new workloads exist only in the new binary: compare
   plain with hashed there.
3. Evaluate and record in §11: (a) v5's cost on existing workloads (flag any ≥ 5 %: memory "WALL
   TOLERANCE"; the Bytes and NaN rows and the explicit stack are the expected costs); (b)
   `hashcons-hashed` vs `hashcons-plain`; (c) `hasheddict-structkeys` vs `seqdict-structkeys`; (d) in
   a profile of `hashcons-hashed` (`sudo -n perf`, memory "PERF NEEDS SUDO"): the kernel calls of
   `value`/`hashOf`/`hashed` (F4) and the kernel-owned costs (F1); propose either if it dominates.
4. Compiler self-build (benchmarks/fe-opt-loop.md §2, one run, by the `hashcrc` row's method). The
   compiler uses `Eco.Hash`, not `FNV.hash`, so a flat result is expected; the GC switch changes are
   the only code it runs.

### H9. Docs, invariants, kernel facts

1. `design_docs/theory/runtime/value-hash.md`: "Definition v5" (§2.1: the five changes, the soundness
   argument, the DAG cost, the explicit stack), v4 marked "until v5", the typed-chain section
   rewritten (no bounds, the new `eco.hash.walk`), a `Hashed` section (the object, `h = hash value`,
   the O(1) rule).
2. Doc comments: `Hash.elm`'s `hash` (drop the bounds sentence; Bytes by content; the DAG cost; point to
   `Hashed`); `SeqDict.elm` and `SeqSet.elm` module docs (one line pointing structured keys to
   `HashedDict` / `HashedSet`); `ValueHash.hpp` declarations.
3. `design_docs/invariants.csv` (exactly 6 `;`-separated fields per row, no `;` in the text): CGEN_095
   rewritten for v5 chains (no bounds, `eco.hash.walk %state, %v -> state`, NaN canonical in the inline
   float hash); HEAP_088's mention of `eco_hash_walk` checked against the new signature; HEAP_089 from
   H2.6 checked against the final code.
4. `Facts.elm`, FNV `hash` row: comment ("an unbounded read-only walk on an explicit stack; frames past
   32 spill to a thread_local std::vector reused across calls; allocates nothing on the Elm heap"),
   `cppAlloc = True`, evidence with the new line numbers.
5. `design_docs/theory/` heap layout doc that lists the tags (grep `Tag_ByteBufferSlice` under
   `design_docs/`): add `Tag_Hashed` and the moved `Tag_Free`/`Tag_Forward` numbers.
6. plans/hash-reuse-explicit-vs-cached.md: header `remaining` and a §7 log line ("A-vs-B decided
   2026-11-25: B for Strings; A superseded by plans/hashed-values-and-hash-consing.md").

### H10. Gates (end of plan; remind the USER, do not auto-run)

- `cmake --build build --target full` and `--target bootstrap`.
- `cmake --build build --target elm-tests`.
- The ECO_HEAP_VALIDATE gate (build-validate unit tests, E2E, stress, `ulimit -c 0`) is deferred by
  the user to a much later date (2026-11-25), not part of this plan's gates. H2's validator cases are
  exercised when it runs; until then the HashedObject unit test (H2.8) is the GC net.
- `test/scripts/check-kernel-license-manifest.sh`, the TLA+ canary.

## 5. Risks and traps

- **Tag renumbering:** `Tag_Free` and `Tag_Forward` move. Compiled code only compares with
  `Tag_Forward` through `value_enc::TagForward` (static-asserted); any other literal 25/26 used as a
  tag is a bug to find in H2.2. Stale build trees (`build-validate`, other build dirs) must be
  rebuilt whole before use (memory "RELOWER NEEDS ALL RUNTIME LIBS").
- **A missed per-tag site** shows as a GC crash or a validator failure: the unit test (H2.8) and the
  validate gate (H10) are the nets.
- **TLA+ canary:** H2 changes pinned regions; follow the README procedure (audit entries first).
- **DAG blow-up:** moot with the bounds kept (D2 revised); it applied to the unbounded walk.
- **A pin moves:** v5 is mis-implemented (§2.1 says none moves). Never re-pin to make it pass.
- **Two implementations of the hash:** the walker and the typed chains (plus the inline primitive
  hashes). HashTypedTest, the identity pair (ECO_HASH_INLINE=0) and `hash_inline_matches_runtime.mlir`
  compare them.
- **JS differs on purpose:** bounded; tests that need unbounded behaviour are SKIP-JS.
- **Kernel symbol clash:** `Eco.Kernel.Hash` belongs to the compiler's eco/kernel package; the new
  kernels go in `Eco.Kernel.FNV`.
- **Elm let-bound mutual recursion** miscompiles natively: keep the chain helpers top-level.
- **Identical-object short-cuts** (`eqHelp`'s `a == b`, JS `===`): inequality tests build their
  operands through different routes.
- **Stale E2E caches** after compiler, runtime and eco/system changes.

## 6. Follow-ups (not in this plan)

- **F1.** Narrow `NullableMaybe.admissiblePayload` and the `TaggedUnions` kernel-owned exclusion for
  kernel-owned types that are always heap objects (`Hashed`, `SeqDict`), if H8(d) shows the costs.
- **F2.** The compiler adopting `Hashed` for its own hash-consing (D5).
- **F3.** A fully bottom-up hash definition, as an experiment (D8).
- **F6.** Local-package cache race (found while testing H6): parallel E2E compiles that see a changed
  eco/system fingerprint each replace `~/.eco/<ver>/packages/eco/system/1.0.0`; two can interleave so that
  one writes `eco-local-fingerprint` while the other is deleting, leaving a copy that has the fingerprint but
  no `elm.json` or `src/`, which is then never repaired (every compile fails "file not found: .../elm.json").
  Seen when the eco/system sources were edited during a run. `Builder/Deps/Details.elm` describes the
  replacement as done "under the registry lock"; the lock evidently does not serialise these processes.
- **F5.** License the Debug kernels (`Debug.log` scope `Transports`, `toString`, `todo`), weighing the
  small precision gain against pinning `RuntimeExports.cpp` (D4).
- **F4. DONE (2026-11-25).** Inline `value` / `hashOf` (and the hash of a `Hashed` in a typed chain) as field loads
  (`KernelIntrinsics` or an MLIR op) instead of kernel calls, if H8(d) shows the calls. Built without
  the profile, at the user's request: `eco.hash` and `eco.hash.mix` take kind `hashed` and the new
  `eco.hashed.value` op loads the value slot, all through `__eco_resolve_fwd` (CGEN_095); the front
  end's hash planner has a `HashHashed` case, and `FNV.value` calls at a known type emit the op
  (`FNV.hashOf` did too until it was removed). Tests: `test/codegen/hash_hashed_inline.mlir`, the `HashedIdentityTest` /
  `HashedIdentityGenericTest` pair (inline against the walker; negative control with `kHashed` = 19
  failed as it should), extra groups in `HashTypedTest` and `HashedTest`.

## 10. Review record (adversarial review, 2026-11-25)

A separate reviewer checked the first draft (then using a reserved constructor tag for `Hashed`)
against the code. Findings and what was done:

| # | finding | disposition |
|---|---|---|
| R1 | Two checks fail on JS: a depth-20 difference (FNV.js is bounded at 16) and `hash (hashed x) == hash x` (JS walked the `{$, a, b}` object). | Depth checks are SKIP-JS (H5c.2). With D7 the JS kernel tags the object and FNV.js recognises it (§2.5), so the transparency check runs on both backends. |
| R2 | NaN canonicalisation was specified for the walker only; the inline float hash (`valuehash::mixPrimitive`) normalises -0.0 only. | Fixed: H5b.4; NaN cases in the MLIR test and the E2E tests. |
| R3 | Licensing as written fails `check-kernel-license-manifest.sh`: CSV kernels must equal the `TypeFaithful` rows; a license changes compilation; Debug kernels are unlicensed; the pinned-files bullet was empty. | Fixed: H4 gives the rows, the procedure, the compile-change warning and the `Utils.cpp` re-audits; licensing Debug is left out by the user's decision (D4, F5). |
| R4 | "Primitives, Strings and constants hash as in v4" was false for null-cons/spare words with an index, and `()` is the Empty constant. | Moot under D8 (v5 keeps v4's stream, so those numbers do not change); §3 states the tag behaviour. |
| R5 | Bytes rows unsound: `eqHelp` compares Bytes by content across buffer, slice and large forms; the walker hashes `kOther ·tag`. A v4 bug. | Fixed: §2.1 row 3; exposed first as a test (H1). |
| R6 | TLA+ claim false: no census pin for ValueHash.cpp; the census regex does not match `__atomic_load_n`. | Fixed in §3. (With D7 the GC switches change, and pinned regions do fire: H2.7.) |
| R7 | Bottom-up v5 is not needed for composition: v4 unbounded plus `mix(kHashed); mix(h)` is sound, O(1) at `Hashed` children, keeps every pin and the chain shape, and avoids a `fmix32` per field. | Adopted as D8; confirmed by the user. |
| R8 | Kernel-owned costs: `Maybe (Hashed a)` always allocates a `Just`; `TList (Hashed Ty)` is a boxed Custom. | Documented in §2.2; measured in H8(d); F1. |
| R9 | HEAP_088 and `ValueHash.hpp` name `eco_hash_walk` / `eco_hash_mix_string`. | H5a.6 and H9.2-3 update them. |
| R10 | Walker holes: per-frame vectors for Dict/SeqDict would `malloc`; `ListCursor` cannot sit in a plain frame array; a zero-length heap String must hash as Empty. | Fixed in H5a.2. |
| R11 | A `Hashed` key from compiled code goes through `eco_hash_value`; the hit compare is a full compare unless the probe is the stored object. | §2.4 and §1.2 state both; the call is cheap (O(1), no box since `Hashed` is a heap pointer); F4 for inline loads. |
| R12 | `hashed (0/0) /= hashed (0/0)` could flip if a pass merges the two objects. | Fixed: operands built through different routes (H3.7, §5). |
| nits | The MLIR test has no mix/walk ops; record order is unboxed-first by name; `print_ctor_arg` parenthesises from text; FNV `Transparent` comment; EraseWrappers "usually". | Applied. |

After the review the user chose D7 (`Tag_Hashed`), which replaced the reserved-tag design (the
`CtorTag` entry, `check-ctor-tags.sh`, `HashedLayout.hpp` and the `HashHashed` plan case are gone)
with H2's heap object, H3's kernels and H4's licenses for them.

## 11. Log

- 2026-11-25: plan written; adversarial review (§10) applied; D7 changed to `Tag_Hashed` and D8
  confirmed by the user; lowered to steps H0-H10.
- 2026-11-25: **implemented H1-H9** (H10 gates owed to the USER). Notes against the plan:
  - Tests: the unit tests are one file, `test/allocator/HashedValueTest.cpp` (suite `HashedValue`, tests named
    `HEAP_089 ...` and `Hash v5 ...`), not two. A negative control (the walker hashing a `Hashed` as `kOther`)
    first passed the suite: no check that `Hashed` values with different stored hashes make different
    containers. That check was added to the unit test and to `HashDeepTest`; the control then failed as it
    should.
  - Licenses: all four FNV kernels are `Transports`, not `Inert` (their types have a function-capable `a`).
    The `Utils.cpp` re-audits covered nine licensed kernels.
  - `SeqDict.insert` of a key equal to a stored one stores the NEW key object, so `HashedSet.insert`
    replaces the canonical element; its doc says so and points to `intern`.
  - `docs.json` is a git-ignored build product (`compiler/CMakeLists.txt` regenerates it); no manual step.
  - The TLA+ canary fired on `MinorWork.hpp` (M3, M4, W3, W5) and `NP.scanEntryP` (M3): audited, no model
    change, pins updated.
  - Tests run: unit `HEAP_089` 2/2, `Hash v5` 5/5, `HEAP_088` 12/12, `LOS:` 12/12, `TaggedWordGc` 7/7, the
    retuned boxed-Int walk 1/1, codegen `hash_inline_matches_runtime.mlir` (NaN cases added); E2E native
    `eco-system/Hash*` 10/10, `SeqDict*` 12/12, `SeqSet*` 1/1; E2E JS 20/20 (3 native-only skipped);
    `elm-tests` 22,136 passed (`FactsTest` expectations updated for the three new KernelFacts rows);
    `--target bootstrap` passed. No HashIdentity pin moved.
  - Benchmarks, interleaved against Part B's final binary (`local-dev/hashreuse/ab-hv-results.txt`, native ms):

    | workload | Part B | this plan | change |
    |---|--:|--:|--:|
    | seqdict-multi-lookup | 252 | 318 | +26.2 % |
    | seqdict-intern | 321 | 390 | +21.5 % |
    | seqdict-prefixkey-fresh / built-keys | 103 / 76 | 95 / 71 | -7.8 / -6.6 % |
    | other 22 hash workloads | | | -4.1 % to +2.2 % (seqdict-update +8.7 % re-measured at -2.6 %: noise) |
    | hashcons-plain / hashcons-hashed (100,000) | - | 159 / 131 | hashed -18 % |
    | seqdict-structkeys / hasheddict-structkeys | - | 140 / 39 | hashed -72 % |

    The two regressions key a SeqDict on type trees of roughly 250-300 fields and elements, past v4's
    256-item cap: v5 walks all of each key (D2's accepted cost; such keys belong in `Hashed`). Hash-consing
    gains only 18 % because these terms are small and table work dominates; structured keys reused through
    `HashedDict` gain 72 %. Compiler self-build (benchmarks/fe-opt-loop.md row `hashed`): 77.99 s, +1.5 %,
    FLAT.
- 2026-11-25: **D2 revised by the user: bounds kept, rolled back to v4 + the Bytes and `Hashed` rows.** The
  unbounded walker, its explicit stack, canonical NaN and the new walk signature were reverted (H5 note);
  the licenses pinned to ValueHash.cpp (`FNV.hash`, `FNV.hashed`) got re-audit rows. Tests re-run: unit
  `HEAP_089` 2/2, `Hash v5` 3/3, `HEAP_088` 12/12, `TaggedWordGc` 7/7, `LOS:` 12/12, the boxed-Int walk 1/1,
  codegen `hash_inline_matches_runtime.mlir`; `elm-tests` 22,136 passed; E2E native `Hash*` 10/10,
  `SeqDict*` 12/12, `SeqSet*` 1/1, JS 21/21 (HashDeepTest now runs on JS too); `--target bootstrap`
  passed; no HashIdentity pin moved. Benchmarks against Part B's final binary, interleaved
  (`local-dev/hashreuse/ab-hv-results.txt`; the unbounded run is `ab-hv-results-unbounded.txt`), native ms:

  | workload | Part B | unbounded v5 | bounded v5 (kept) |
  |---|--:|--:|--:|
  | seqdict-multi-lookup | 246-252 | 318 | 240 |
  | seqdict-intern | 321-322 | 390 | 315 |
  | other 24 hash workloads | | -8 % to +2 % | -10 % to +5 % (seqdict-update swings -14 % to +9 % between runs: noise) |
  | hashcons-plain / hashcons-hashed (100,000) | - | 159 / 131 | 117 / 121 |
  | seqdict-structkeys / hasheddict-structkeys | - | 140 / 39 | 135 / 40 |

  With the bounds back, a plain small term hashes in bounded time, so `hashcons-hashed` no longer beats
  `hashcons-plain` (+3 %: the `Hashed` objects, kernel calls and boxed `Just`s cost about what they save
  on small terms). Reusing `Hashed` structured keys still saves 70 %. The compiler self-build row `hashed`
  in benchmarks/fe-opt-loop.md was measured on the unbounded tree; the compiler uses `Eco.Hash`, so it is
  unaffected either way.
- 2026-11-25: **F4 built** (inline `Hashed` reads, CGEN_095). Tests: codegen 2/2, native Hash* 10/10 (with
  the new `HashedIdentity` pair 2/2), SeqDict/SeqSet 13/13, JS HashTypedTest/HashedTest 2/2, elm-tests
  22,136; bootstrap rebuilt. The benchmark binary has 7 `eco_hash_value` call sites instead of 10.
  Interleaved A/B (local-dev/hashreuse/ab-f4.sh, 5 rounds, bench-hv against bench-f4):
  hasheddict-structkeys 40 -> 39 ms (-2.5 %), hashcons-hashed 122 -> 118 (-3.3 %); controls
  seqdict-structkeys +1.4 %, hashcons-plain 0.0 %, seqdict-intern +0.6 %, seqdict-tuple +1.3 % (noise).
  Found on the way, not fixed: HashTypedTest's `viaKernel` (`List.map Hash.hash [ x ]`) is now
  specialised to the inline hash, so its typed-chain-against-walker comparisons no longer reach the
  walker.
- 2026-11-25: **F4's `Hash.value` measured** with new workloads traverse-plain / traverse-hashed
  (examples/benchmarks/src/HashCons.elm: a 2^14-leaf tree built once, its leaves summed `size` times,
  the second through `Hash.value` on `Hashed` children). Baseline = the same compiler with
  ECO_HASH_INTRINSIC=0 (`value` a kernel call; the timed part hashes nothing). Interleaved A/B
  (local-dev/hashreuse/ab-val.sh, 5 rounds): traverse-hashed 30 -> 16 ms at size 200, 144 -> 75 ms at
  1000 (-47.9 %, about 2 ns per call over 32.8 M calls); the control traverse-plain moved -8.3 % / -7.1 %
  (12 -> 11, 56 -> 52 ms) though it has no hash or `value` in it, read as layout between the two
  binaries. So the inline `value` is worth about 45 % on a traversal of `Hashed` children, where the
  hash path (above) gave 2-3 %.
- 2026-11-25: **`Hash.hashOf` removed from the API** (user decision): `Hash.hash h` gives the same number
  for a `Hashed` (its stored hash, inline natively). Gone: the export and `Eco_Kernel_FNV_hashOf`,
  `_FNV_hashOf`, its Facts / KernelSetFacts / Visibility rows (Facts table 81 -> 80), its license and
  elm_kernel_functions.csv rows, and its F4 intrinsic; `FNV.hash`, `hashed` and `value` got re-audit
  rows for the FNVExports.cpp edit. Tests use `Hash.hash` instead (HashedTest's `transparent` group took
  over the long-String and `Circle` cases of the removed `hashOf` group). The API sketches above still
  show `hashOf` as it was planned.
