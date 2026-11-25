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

## Definition v3 (2026-11-24, until v4)

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

## Definition v4 (2026-11-24, until v5)

One change to v3: `stringHash(s)` is CRC32C, which composes, so that a String built from parts can be
given its hash from theirs (plans/hash-reuse-explicit-vs-cached.md §4.2; the choice and its
measurements: design_docs/string-hash-algorithm.md). Everything else, including how the result is
mixed into the walk (`mix(kString); mix(stringHash(s))`), is unchanged.

- `raw(s)`: the CRC32C register (Castagnoli, reflected polynomial `0x82F63B78`) after the String's
  `n` UTF-16 units, each as two little-endian bytes, starting from `0xFFFFFFFF`, without the final
  inversion. A UTF-8 form's bytes are its units, each widened to the byte pair `(b, 0)`.
  `raw("") = 0xFFFFFFFF`.
- `stringHash(s) = nonZero(fmix32(raw(s) ^ n))`.
- **Composition:** `raw(a ++ b) = combine(raw(a), raw(b), |b|) = (raw(a) ^ 0xFFFFFFFF) · x^(16|b|) ^ raw(b)`
  mod P. The runtime multiplies with one carry-less multiply reduced by the `crc32` instruction, from a
  table of `x^(2^k)`: a few nanoseconds at any length (`runtime/src/allocator/Crc32c.cpp`).

Every form gives the same number. `Crc32c.cpp` folds long runs 64 bytes per step with PCLMULQDQ and
runs three `crc32` instruction streams below 64 units, on x86-64 CPUs that have SSE4.2 and PCLMULQDQ
(checked once); elsewhere a table-driven CRC gives the same numbers. CRC32C is linear over GF(2): two
Strings of one length whose XOR is a multiple of P (for example P·x^s) have one hash, which the
SeqDict collision tests use to build colliding keys (`experiments/string-hash-lab/v4ref.py`); no
two Strings of one length that differ only within 32 consecutive bits collide.

## Definition v5 (current since 2026-11-25)

plans/hashed-values-and-hash-consing.md. v5 is v4, bounds included (16 levels of nesting, 256 list
elements, Dict and SeqDict entries and fields in all), with two rows changed and two markers added:

1. **Bytes** (`Tag_ByteBuffer`, `Tag_ByteBufferSlice`, `Tag_LargeByteHeader`, which `==` compares by
   content across forms): `mix(kBytes); mix(n); mix(CRC32C register of the n bytes from 0xFFFFFFFF)`,
   mixed whatever the bounds, as a String is. v4 mixed `kOther` and the heap tag, so a buffer and a
   slice with equal bytes, which `==` finds equal, hashed differently: a v4 bug.
2. **`Hashed`** (eco/system's `Hash.Hashed`, a `Tag_Hashed` object holding `hash` = `Hash.hash value`
   and the value, HEAP_089): nested anywhere, it contributes `mix(kHashed); mix(hash)`, whatever the
   bounds, and its value is not walked; hashed on its own, the result is `hash` itself, so
   `Hash.hash (hashed x) == Hash.hash x`.
3. **New markers** `kBytes = 17` and `kHashed = 18`, appended after `kTag = 16`.

Every value with no Bytes or `Hashed` in it has its v4 number. Row 2 is sound because a `Hashed`'s hash
is its value's (equal values, equal hashes), and it is consistent with the bounds: a `Hashed` is mixed as
its own number, never as a stand-in for a walk of its value. So a recursive type that keeps its parts as
`Hashed` hashes each node in time proportional to its own fields, however deep the structure, and the
bounds still cap the cost of hashing a large plain value. (An unbounded v5 with canonical NaN was built
and measured on 2026-11-25 and rolled back: plans/hashed-values-and-hash-consing.md §11.)

## `Hashed` values (HEAP_089)

`Hash.hashed : a -> Hashed a` (the kernel `Eco_Kernel_FNV_hashed`) hashes its argument once and
allocates a `Tag_Hashed` object, `ElmHashed` in `Heap.hpp`: the header, the u32 hash, a reserved u32
and the value, boxed. It is never written after it is created. `Hash.value` and `Hash.hashOf` read its
fields. `==` on two `Hashed` compares the hashes first and then the values (`eqHelp`), and
`Debug.toString` prints the value alone, natively (`RuntimeExports.cpp`) and on JavaScript (the kernel
override `compiler/kernel-overrides/HashedDebug.js`). On JavaScript a `Hashed` is the object
`{ $: 'Hashed_elm_builtin', a: hash, b: value }`, and FNV.js gives it the same treatment as row 2.
A recursive type that keeps its parts as `Hashed` hashes each node in time proportional to its own
fields, and `HashedSet.intern` hash-conses it.

## Cached String hashes (HEAP_088)

`stringHash(s)` is cached in the String: slices, ropes, UTF-8 views and large Strings have a 32-bit
hash slot in a field, and a flat UTF-16 String or UTF-8 leaf has one in a tail word when it is at least
`kStringHashSlotMinUnits` = 32 units long (shorter ones hash in a few nanoseconds, and a slot would add
8 bytes to each). Under v4 the slot holds `raw(s)`, or 0 when not yet computed (a String whose raw state
is 0 is never cached). The walker's String step (`mix(kString); mix(stringHash(s))`, and so
`eco_hash_string`, `eco_hash_mix_string`, the typed chains' String fields and nested Strings) reads a
filled slot instead of the units and fills an empty one; a rope's raw state is composed from its
children's, whose slots are filled on the way; literals of 32+ units are filled when they are interned.
A String built from parts (`++`, `concat`, `join`, `cons`, a rope) is given its raw state at build by
composing its parts' when they are known (a filled slot, or a part short enough to hash on the spot), and
a long part whose slot is empty is hashed on the way and its slot filled; a new form of a String
(`flattenToLeaf`) keeps its slot. A hash is therefore computed once per String object, however often and
in however many dicts or keys it is used, and often not at all. The numbers are unchanged: the slot only
caches them. `StringOps::equal` also answers False for two Strings whose slots are filled and
differ. Filling the slot is a write after publication that HEAP_088 allows as an exception to P1
(HEAP_SNAPSHOT_001): see that row for the concurrency argument and the validate-build checks.

## One hash per key per function

Natively, the eco/system SeqDict and SeqSet wrappers that hash their key (`get`, `member`,
`insert`, `remove`) are always inlined, and the hash mode of the Mono CSE pass
(`Compiler.MonoOpt.Cse`, `cse.hashMerge`, on by default) binds repeated `FNV.hash` calls of one
value in a function once (invariant CSE_001; plans/seqdict-hash-once-per-function.md). It runs
before code generation, so a tuple or record key's typed chain below is generated once too. The
merge changes no hash value, only how many times one is computed.

## Typed hashing (`eco.hash.mix` chains, D2)

`Hash.hash` at a known tuple or record type is compiled to a chain that computes exactly the walker's
number. The value's type gives a plan: an Int, Float, Char, Bool or String field is one `eco.hash.mix`;
a nested tuple or record is unrolled (its marker, then its fields one level deeper); anything else (a
list, a custom type in any representation, a `Hashed`, unit) is `eco.hash.walk`, the walker's
`boxed(value, depth)` resumed from the chain's state and item budget (`eco_hash_walk`). The bounds follow
the walker: depth is known statically, so an aggregate at depth 16 or more contributes nothing; the items
left are an `i64` threaded through the chain, starting at 256, and an aggregate with none left, or a
record field with none left, keeps the old state through an `arith.select` (a record field uses an item
up even when it took the last one, so the count can go negative). Primitives and Strings are mixed
whatever the bounds, as in the walker. A plan of more than 64 nodes, and any value that is not a tuple or
record, is hashed whole (`eco.hash` of kind `value`). `test/eco-system/src/HashTypedTest.elm` compares
the chains with the walker, bounds included.
