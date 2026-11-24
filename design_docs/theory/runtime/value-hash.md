# Value hashing (`FNV.hash`, `Hash.hash`, `eco.hash`)

eco hashes any Elm value with one function, defined here. eco/system's `SeqDict` and `SeqSet` key
their tries on it. The native definition lives in the generic walker
(`system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp`, `Hasher`); every specialised path must
give bit-identical results to it on the same value (plans/seq-data-structures-performance.md §4.6).
The JavaScript backend has its own function (`system-kernel-cpp/src/Eco/Kernel/FNV.js`) with the same
guarantee and different numbers.

## Guarantees

- Values that `==` finds equal hash equal, within one compiled program on one backend.
- The result is in `[0, 2^32)`; on the native backend it is never 0 (v2).
- Nothing else: the numbers differ between backends, programs, compiler versions and build modes
  (they follow the heap representation the compiler chose), and must not be persisted.

## Definition v1 (the walker until D0, 2026-11-23)

State: `h : u32`, starting at the FNV offset basis `2166136261`, and `items : int`, starting at
`kMaxItems = 256` and shared by the whole walk.

- `mix(x : u32)`: `h = (h ^ x) * 16777619` (32-bit FNV-1a step).
- `mix64(x : u64)`: `mix(low 32 bits)`, then `mix(high 32 bits)`.
- Markers (`u32`): `kInt=1, kFloat=2, kChar=3, kString=4, kEmpty=5, kConst=6, kTuple=7, kList=8,
  kListEnd=9, kCustom=10, kRecord=11, kArray=12, kDict=13, kSeqDict=14, kOther=15, kTag=16`.

A value is hashed by `boxed(word, depth)` starting at depth 0, or by `slot(field, kind, depth)` for an
unboxed field:

- **Int** (unboxed slot or boxed `ElmInt`): `mix(kInt); mix64(value)`.
- **Float**: `mix(kFloat)`, then `-0.0` becomes `0.0`, then `mix64(bits)`.
- **Char**: `mix(kChar); mix(code point)`.
- **Word tag bits.** A word whose bits 43–52 are non-zero (a tagged-union index, HEAP_086, or the index
  of a null-cons or spare word) first does `mix(kTag); mix(tag)`, and the rest is hashed with those bits
  cleared.
- **Constants.** The Empty constant: `mix(kEmpty)` (as the empty String, since `==` finds them equal).
  Any other constant word: `mix(kConst); mix64(word bits)`.
- **String** of length `n` (every form: flat UTF-16, slice, rope, UTF-8 leaf or view, large):
  `n == 0` → `mix(kEmpty)`; otherwise `mix(kString); mix64(n)`, then each of the first
  `kMaxUnits = 4096` UTF-16 units (a UTF-8 form's bytes, which are ASCII) with `mix(unit)`.
- Strings and primitives are hashed at any depth. For everything below, nothing more is mixed once
  `depth >= kMaxDepth (16)` or `items <= 0`:
  - **Tuple2/Tuple3**: `mix(kTuple)`, then each field at `depth + 1`.
  - **List** (cons cells and chunks alike): `mix(kList)`, then for each element while `items > 0`:
    `items--`, the element at `depth + 1`; then `mix(kListEnd)`.
  - **Dict** (`RBNode_elm_builtin`, ctor 0xFFFF): `mix(kDict)`, then each entry in key order while
    `items > 0`: `items--`, key and value at `depth + 1`.
  - **SeqDict** (ctor `CTOR_SEQDICT`): `mix(kSeqDict)`, then each entry in insertion order while
    `items > 0`: `items--`, key and value at `depth + 1`.
  - **Custom**: `mix(kCustom); mix(ctor)`, then each field while `items > 0`: `items--`, the field at
    `depth + 1`.
  - **Record**: `mix(kRecord)`, then each field in heap slot order while `items > 0` (as for Custom).
  - **Array**: `mix(kArray)`, then each element while `items > 0` (as for Custom).
  - **Anything else** (Bytes, closures, …): `mix(kOther); mix(tag)`.
- **Finaliser**: the result is MurmurHash3's `fmix32(h)`, zero-extended.

## Definition v2 (current since D0, 2026-11-23)

Three changes to v1, everything else unchanged:

1. **Strings are hashed on their own and mixed in as one word.** A non-empty String contributes
   `mix(kString); mix(stringHash(s))`, where `stringHash(s)` runs a fresh FNV-1a state from the offset
   basis: `mix64(n)`, then the first `kMaxUnits` units two per step as `u1 | (u2 << 16)` (a last odd unit
   alone), then `fmix32`, then `0 → 1`. A cached String hash (D5) can therefore serve a String nested in
   any key.
2. **Units are read from contiguous segments** (`StringOps::forEachSegmentEx`), never one at a time
   through `charAt`. (Implementation only; the numbers follow from 1.)
3. **The result is never 0**: a 0 from `fmix32` becomes 1, so 0 can mean "not cached".

## Typed hashing (`eco.hash.mix` chains, D2)

`Hash.hash` at a known tuple or record type is compiled to a chain that computes exactly the walker's
number. The value's type gives a plan: an Int, Float, Char, Bool or String field is one `eco.hash.mix`;
a nested tuple or record is unrolled (its marker, then its fields one level deeper); anything else (a
list, a custom type in any representation, unit) is `eco.hash.walk`, the walker's `boxed(value, depth)`
resumed from the chain's state and item budget (`eco_hash_walk`). The bounds follow the walker: depth
is known statically, so an aggregate at depth 16 or more contributes nothing; the items left are an
`i64` threaded through the chain, starting at 256, and an aggregate with none left, or a record field
with none left, keeps the old state through an `arith.select` (a record field uses an item up even
when it took the last one, so the count can go negative). Primitives and Strings are mixed whatever
the bounds, as in the walker. A plan of more than 64 nodes, and any value that is not a tuple or
record, is hashed whole (`eco.hash` of kind `value`). `test/eco-system/src/HashTypedTest.elm` compares
the chains with the walker, bounds included.
