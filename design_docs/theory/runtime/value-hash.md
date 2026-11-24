# Value hashing (`FNV.hash`, `Hash.hash`, `eco.hash`)

eco hashes any Elm value with one function, defined here. eco/system's `SeqDict` and `SeqSet` key
their tries on it. The native definition lives in the generic walker
(`runtime/src/allocator/ValueHash.cpp`, `Hasher` and `stringHash`); every specialised path must
give bit-identical results to it on the same value (plans/seq-data-structures-performance.md §4.6).
The JavaScript backend has its own function (`system-kernel-cpp/src/Eco/Kernel/FNV.js`) with the same
guarantee and different numbers.

## Guarantees

- Values that `==` finds equal hash equal, within one compiled program on one backend.
- The result is in `[0, 2^32)`; on the native backend it is never 0 (since v2).
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
  `kMaxUnits = 4096` UTF-16 units (a UTF-8 form's bytes, which are ASCII) with `mix(unit)`. (v3 drops
  the cap.)
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

## Definition v2 (D0, 2026-11-23, until v3)

Three changes to v1, everything else unchanged:

1. **Strings are hashed on their own and mixed in as one word.** A non-empty String contributes
   `mix(kString); mix(stringHash(s))`, where `stringHash(s)` runs a fresh FNV-1a state from the offset
   basis: `mix64(n)`, then the first `kMaxUnits` units two per step as `u1 | (u2 << 16)` (a last odd unit
   alone), then `fmix32`, then `0 → 1`. A cached String hash (D5) can therefore serve a String nested in
   any key.
2. **Units are read from contiguous segments** (`StringOps::forEachSegmentEx`), never one at a time
   through `charAt`. (Implementation only; the numbers follow from 1.)
3. **The result is never 0**: a 0 from `fmix32` becomes 1, so 0 can mean "not cached".

## Definition v3 (current since 2026-11-24)

One change to v2: `stringHash(s)` reads **every** unit of the String (no `kMaxUnits` cap) and is a
word-at-a-time hash instead of FNV-1a, so that a long key costs a few cycles per 32 units instead of
one multiply per two, and Strings that agree in a long prefix no longer collide. Everything else,
including how the result is mixed into the walk (`mix(kString); mix(stringHash(s))`), is unchanged.

- `mum(a, b)`: the 128-bit product of two `u64`s, its low and high halves XORed (wyhash's step).
- Constants: `kWordKey = 0xa0761d6478bd642f`; lane seeds `S0 = 0xe7037ed1a0b428db`,
  `S1 = 0x8ebc6af09c88c6e3`, `S2 = 0x589965cc75374cc3`, `S3 = 0x1d8e4e27c47d124f`.
- The `n` UTF-16 units (a UTF-8 form's bytes are its units), zero-padded to a multiple of 32, are
  read as words of four units, `w = u0 | u1 << 16 | u2 << 32 | u3 << 48`.
- Otherwise lanes start at `S0..S3`. Each round of 32 units (words `w0..w7`) updates every lane:
  `lane[j] = mum(w[2j] ^ kWordKey, w[2j+1] ^ lane[j])`. The four multiplies are independent.
- `h = mum(lane0 ^ S1, lane1 ^ S2) ^ mum(lane2 ^ S3, lane3 ^ S0)`, then
  `h = mum(h ^ kWordKey, n ^ S0)`; the result is `low32(h ^ (h >> 32))`, and 0 becomes 1.
- **Short Strings** (`n <= 8`): no lanes. The units, zero-padded to 8, are two words `w0, w1`;
  `h = mum(w0 ^ kWordKey, w1 ^ S0)`, then the same final step `h = mum(h ^ kWordKey, n ^ S0)` and
  reduction. This keeps short keys as cheap as v2's FNV-1a (seqdict-string was 10-15 % slower with
  the lanes alone).

The padding is told apart from real zero units by `n`. A String costs time linear in its length, as
`==` on it does; the walk's other bounds (depth 16, 256 items) still apply to structures. The
implementation streams the String's contiguous segments (`forEachSegmentEx`) through a 32-unit
buffer, widening UTF-8 bytes four at a time, so every form gives the same number.

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
