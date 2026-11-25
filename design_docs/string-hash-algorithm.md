# String hash algorithm: composable candidates against v3

**Status:** experiment report, 2026-11-24. Nothing in the compiler or runtime was changed to produce
it. The code is `experiments/string-hash-lab/` (one C++ file, `run.sh` reruns everything), and the raw
output is in `experiments/string-hash-lab/results/`.

**Decision:** **crc32c-fold128** (CRC32C, 16-byte PCLMULQDQ folding, the `crc32` instruction below
64 units) is the hash for the composability experiment: step B5 of
`plans/hash-reuse-explicit-vs-cached.md`, where `++` and ropes get their hash from their sides' hashes.
§7 gives the reasons.

**Question:** eco's String hash v3 (`runtime/src/allocator/ValueHash.cpp`, `stringHash`;
`design_docs/theory/runtime/value-hash.md`) cannot be composed: v3(a ++ b) cannot be computed from
v3(a) and v3(b). Which hash functions can be composed, how fast can they be made on the CPUs eco
targets, and is their quality as good as v3's?

**Evidence tags:** **[M]** measured here; **[E]** estimate or reasoning, not measured.

**Host:** Intel Xeon 6521P (Granite Rapids: AVX-512 with IFMA, VPCLMULQDQ), clang 14, `-O3`, one core
pinned (`taskset`). Builds: `-march=sapphirerapids` (every method), and `-march=x86-64-v3 -mtune=generic
-mpclmul` (eco's CPU floor, `design_docs/compatability.md`, plus PCLMULQDQ; no AVX-512 instruction in the
binary, checked with `objdump`).

## 1. Composable hashes

A hash is composable when it has a **raw state** and a join with

    raw(a ++ b) = combine(raw(a), raw(b), length b)

A String caches the raw state; the 32-bit, never-0 hash SeqDict reads is a finisher applied to it
(the finisher is not invertible, so the finished hash cannot be joined). Every such hash is a
polynomial evaluated in some algebra (a monoid homomorphism from Strings):

| family | raw state | combine | composes at |
|---|---|---|---|
| polynomial mod a prime p (Rabin-Karp) | Σ uᵢ B^(n−1−i) mod p | H(a)·B^\|b\| + H(b) | any unit |
| polynomial over GF(2) mod P: CRC, Rabin fingerprint | the units' bits as a polynomial mod P | H(a)·x^(16\|b\|) ⊕ H(b) (CRC: with its initial value folded in) | any bit |
| GF(2^128) evaluation (GHASH, POLYVAL) | per 16-byte block | per block | 16-byte blocks only: **not usable** (a String's sides have any length) |
| 2×2 matrix products (Tillich-Zémor) | product of per-bit matrices | matrix product | any bit: **not used** (one bit at a time, known attacks) |
| wyhash, xxHash, v3, NH, UMAC | lanes seeded at the start / per-position keys | none | **not composable** |

## 2. Candidates and implementations

| name | definition | implementation | ISA |
|---|---|---|---|
| **v3** | eco's hash, copied verbatim (checked against the independent Python reference, 20 Strings) | 4 lanes of `mum` (64×64→128 multiply, folded) per 32 units, scalar `mulx` | x86-64-v3 |
| v3-masked | same values; partial last block read by one masked load, words taken from the register | | AVX-512 |
| v3-avx2tail | same values; tail by `vpmaskmovd` (32-bit lanes), an odd last unit cleared | | x86-64-v3 |
| crc32c-1 / -3 | CRC32C (Castagnoli), init 0xFFFFFFFF, no final inversion; hash = nonZero(fmix32(raw ⊕ n)) | `crc32q`, 1 or 3 interleaved streams (3: joined with carry-less multiplies, tiers of 2,048/256/32 bytes) | SSE4.2 (+PCLMUL for -3) |
| **crc32c-fold128** | the same value | 4 × 16-byte PCLMULQDQ accumulators, 64 bytes per step; last chunk and tail by `crc32q`; crc32c-3 below 64 units | x86-64-v3 + PCLMUL |
| crc32c-fold256 | the same value | 4 × 32-byte VPCLMULQDQ, 128 bytes per step | AVX2 + VPCLMULQDQ (Ice Lake, Zen 3 on; not Skylake) |
| crc32c-fold | the same value | 4 × 64-byte VPCLMULQDQ, 256 bytes per step; masked first load | AVX-512 |
| rabin64 / rabin64-fold128 | units as a GF(2) polynomial mod a random irreducible degree-64 P (fixed seed: P = x⁶⁴ + 0xbe5818203131c5f3), Barrett-reduced; hash = finish64(raw ⊕ n·φ) | 64- or 16-byte folding, leading partial chunk zero-padded | AVX-512 / x86-64-v3 + PCLMUL |
| poly61-scalar / -avx2 / -avx512 | Σ uᵢ B^(n−1−i) mod 2^61−1 | blocks with power tables: every multiply in a block independent, one dependent mul-mod per block (32 or 256 units); vector: `vpmovzxwq` + `vpmuludq` on B^k split into 32-bit halves | x86-64-v3 / AVX-512 |
| poly52-ifma | the same mod 2^52−47 | `vpmadd52luq`/`vpmadd52huq` (multiply and add fused) | AVX-512 IFMA |
| read-floor | not a hash: xor of every block | the cost of reading the units at all | |

Every variant of one family computes the same value, so a runtime may pick the fastest the CPU has
without changing any hash.

**Correctness [M].** Every raw function equals a bit-by-bit (CRC, Rabin) or unit-by-unit (polynomial)
reference on lengths 0-1,100 and 10 large ones up to 100,003 units, at start offsets of 0-7 units
(106,056 checks in the AVX-512 build, 61,866 in the v3 build). `combine` matches on 72,672 pairs
(empty sides and every block boundary), and a 20,000-unit String cut into 2-100 random pieces joins to
its own raw state left to right, right to left and as a balanced tree (480 joins). Negative controls:
one constant broken in each method (a fold constant, Barrett's μ, a 3-stream join constant, a table
entry in each polynomial, the combine shift) is caught every time.

**Generated code [M]** (inner loops, no spills; `objdump`):

| method | hot loop | units per multiply-class instruction |
|---|---|---|
| v3 | scalar `mulx` (x86 has no vector 64×64→128 multiply) | 8 per `mulx` |
| crc32c-3 | 3 streams of `crc32q` | 4 per `crc32` |
| crc32c-fold, rabin64 | `vpclmulqdq zmm` ×8 + `vpternlogq` (load folded in) ×4 per 256 bytes | 16 per `vpclmulqdq` |
| poly61-avx512 | `vpmovzxwq` + `vpmuludq zmm` ×2 + `vpaddq` ×2 per 8 units | 4 per multiply |
| poly52-ifma | `vpmadd52luq`/`huq zmm` per 8 units | 4 per multiply (add fused) |

The 512-bit carry-less multiply handles 4× more units per instruction than any integer-multiply
design; that alone decides the long-String results.

## 3. Speed

Method [M]: ns per hash (raw + finisher), each call's input address depending on the previous result
(latency, not throughput), best of 7 trials, String 64-byte aligned. The harness costs about 2.7 ns per
call (read-floor-avx2 at 1 unit).

### 3.1 AVX-512 host

| units | v3 | v3-masked | crc32c-3 | crc32c-fold | rabin64 | poly61 scalar | poly61 AVX2 | poly61 AVX-512 | poly52 IFMA | read-floor |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 11.8 | 7.6 | 6.6 | 6.8 | 13.8 | 9.9 | 12.4 | 17.4 | 15.2 | 7.4 |
| 8 | 8.4 | 7.6 | 6.8 | 7.2 | 12.0 | 13.0 | 15.7 | 17.4 | 17.9 | 7.4 |
| 16 | 12.8 | 12.3 | 8.3 | 8.7 | 13.2 | 18.9 | 16.6 | 16.4 | 17.4 | 7.4 |
| 31 | 14.1 | 12.3 | 12.2 | 12.4 | 17.0 | 25.1 | 24.3 | 19.1 | 19.6 | 7.4 |
| 32 | 8.3 | 8.8 | 11.2 | 11.6 | 15.3 | 21.4 | 18.2 | 17.8 | 18.8 | 7.4 |
| 33 | 16.7 | 14.5 | 12.2 | 12.4 | 18.1 | 23.3 | 18.7 | 18.9 | 19.4 | 7.4 |
| 64 | 10.5 | 10.3 | 14.6 | 13.5 | 16.6 | 34.0 | 21.8 | 20.4 | 20.8 | 7.4 |
| 127 | 20.1 | 17.1 | 24.2 | 17.7 | 20.6 | 65.4 | 34.7 | 30.4 | 25.1 | 8.4 |
| 256 | 20.2 | 20.4 | 38.0 | 17.2 | 20.1 | 110 | 42.9 | 37.7 | 32.8 | 8.3 |
| 1,000 | 65.5 | 62.4 | 90.1 | 31.5 | 34.8 | 408 | 148 | 112 | 86.6 | 12.3 |
| 2,016 | 109 | 108 | 150 | 45.8 | 49.0 | 806 | 283 | 221 | 162 | 16.6 |
| 4,099 | 223 | 217 | 283 | 79.9 | 82.8 | 1,700 | 572 | 450 | 322 | 31.7 |
| 65,536 | 3,400 | 3,400 | 4,100 | 1,000 | 1,000 | 26,300 | 8,900 | 6,900 | 4,900 | 693 |
| 2^20 | 70,100 | 66,900 | 71,200 | 29,300 | 29,300 | 446,600 | 163,800 | 133,000 | 87,900 | 26,500 |

(read-floor here uses AVX-512 masked loads and a horizontal reduction, so it is not a floor on short
Strings; see read-floor-avx2 in §3.2.)

- crc32c-fold is 2.1-3.4× faster than v3 from 1,000 units (62.9 units/ns against 19.2 at 64K), at
  least as fast below 32 units, slower only at exact multiples of 32 or 64 where v3 has no partial
  block. At 2^20 units (2 MB, L2) it runs at about 90 % of read speed.
- The polynomials lose despite vectorising well: one multiply per 4 units. IFMA is 1.5× slower than v3
  on long Strings, AVX-512 `vpmuludq` 2×, scalar 7×.
- **Alignment:** a String starting 2 bytes past a 64-byte boundary makes every 64-byte load straddle
  two cache lines: crc32c-fold +7 % at 2,016 units, +32 % at 65,536; read-floor shows the same. Lengths
  that are not block multiples cost little (a masked first chunk, no tail loop).

### 3.2 x86-64-v3 build (eco's CPU floor + PCLMULQDQ)

| units | v3 | v3-avx2tail | crc32c-3 | **crc32c-fold128** | crc32c-fold256 | rabin64-fold128 | poly61 AVX2 | read-floor-avx2 |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 11.5 | 7.4 | 6.6 | 6.9 | 6.6 | 12.8 | 12.4 | 2.7 |
| 8 | 8.3 | 7.4 | 6.9 | 7.2 | 7.1 | 10.8 | 15.7 | 3.2 |
| 31 | 13.9 | 13.8 | 12.1 | 12.4 | 12.2 | 16.9 | 24.3 | 5.8 |
| 33 | 16.4 | 15.7 | 12.2 | 12.3 | 12.2 | 18.0 | 18.6 | 5.6 |
| 64 | 10.5 | 12.6 | 14.6 | 13.7 | 13.7 | 16.9 | 22.2 | 6.5 |
| 129 | 21.7 | 20.2 | 24.1 | 18.6 | 16.3 | 22.5 | 29.8 | 6.7 |
| 257 | 29.0 | 29.4 | 38.8 | 26.4 | 20.2 | 30.4 | 46.6 | 7.4 |
| 1,000 | 66.2 | 66.9 | 90.0 | 72.3 | 44.8 | 75.1 | 150 | 14.1 |
| 2,016 | 110 | 112 | 150 | 133 | 75.0 | 137 | 285 | 29.3 |
| 65,536 | 3,440 | 3,440 | 4,100 | 4,020 | 2,020 | 4,020 | 9,000 | 806 |

- Without AVX-512, CRC32C loses its long-String lead: 16-byte folding (about 16 units/ns at 64K) is as
  fast as the 3-stream instruction path, about 1.2× slower than v3 (19 units/ns). Below about 64 units
  it is still faster than v3.
- 32-byte VPCLMULQDQ (crc32c-fold256) is 1.7× faster than v3, on the AVX2 CPUs that have it.
- These are this host running x86-64-v3 code, not an old CPU. On Skylake (for example a user's
  i7-6700), PCLMULQDQ has about 7 cycles of latency against about 3 here, so fold128 is likely held
  further back there and v3 likely the faster on long Strings by about 1.3-1.6× **[E]**.

### 3.3 combine

ns per call, chained through the joined state [M]:

| \|b\| | crc32c (all variants) | rabin64 | poly61 | poly52 |
|--:|--:|--:|--:|--:|
| 1-100 | 3.4-3.6 | 6.6-6.9 | 4.7 | 8.1 |
| 1,000-2,016 | 4.2-4.3 | 16.2 | 11.9 | 38 |
| 4,099 | 3.6 | 6.9 | 6.3 | 18.9 |
| 65,536 / 2^20 | 3.4 | 6.6 | 4.8 | 8.1 |

These measure mostly the data path: x^\|b\| (or B^\|b\|) does not depend on the states, so the CPU
overlaps its computation (one multiply per set bit of \|b\|, from a table of x^(2^k) or B^(2^k)).

## 4. Quality

### 4.1 Collisions on structured key sets [M]

2^20 keys per family; a random 32-bit hash expects about 126-128 collisions.

| method | prefix 500 + 6 digits | `fromInt` 0..2^20 | 64 zeros, two units set | random 32 units |
|---|--:|--:|--:|--:|
| v3 | 117 | 128 | 127 | 129 |
| crc32c | **0** | **0** | 106 | 136 |
| rabin64 | 126 | 111 | 141 | 131 |
| poly61 | 123 | 119 | 136 | 110 |
| poly52 | 119 | 115 | 106 | 120 |

CRC32C is better than random on keys differing in a short stretch: it cannot collide on two keys of
equal length whose difference fits in 32 bits (its error-detection guarantee).

### 4.2 SMHasher-style tests [M]

SMHasher (Austin Appleby; maintained as SMHasher3 and rurban/smhasher) is the de facto standard for
non-cryptographic hashes. Three of its ideas were added to the lab, run on one implementation per
family, plus a **control: raw CRC32C with no finisher**, which is linear and must fail.

**Avalanche.** Every input bit of S random keys flipped in turn; for each (input bit, output bit)
cell, the flip rate p should be ½; bias = |2p − 1|. A perfect hash's cells have standard deviation
1/√S, so its expected worst over M cells is about √(2 ln M / S) and its expected mean √(2/(πS)). The
ratios to those (1 = indistinguishable from random):

| method | worst/perfect at 4, 8, 31, 64, 256 units | mean/perfect |
|---|---|---|
| v3 | 0.88 0.87 0.97 0.93 0.91 | 0.96-1.00 |
| crc32c | 0.80 0.97 0.82 0.93 0.89 | 1.00-1.02 |
| rabin64 | 0.88 0.95 1.00 0.96 0.96 | 0.98-1.00 |
| poly61 | 0.84 1.05 0.99 1.11 0.90 | 0.97-1.00 |
| poly52 | 0.99 1.02 0.86 0.95 0.96 | 0.99-1.00 |
| control: raw CRC | 248 168 79 53 25 (bias 100 %) | 150-1,200 |

Sensitivity: at 4 units a bias of about 0.4 % would show (SMHasher's mark is 1 %); at 256 units about
4 %.

**Every window.** Every 5-, 8- and 12-bit window at every bit offset, plus SeqDict's top 2-bit level
(75 windows), bucketed over each key family; chi-square as z = (χ² − dof)/√(2 dof). A random function's
worst of 75 is typically 2-3.5.

| method | prefix 500 + digits | `fromInt` | two units set | random 32 units | windows over \|z\| 4 |
|---|--:|--:|--:|--:|--:|
| v3 | 2.4 | 3.3 | 3.6 | 2.7 | 0 |
| crc32c | 2.8 | 2.9 | 3.4 | 2.8 | 0 |
| rabin64 | 3.9 | 2.5 | 2.8 | 2.7 | 0 |
| poly61 | 2.2 | 3.1 | 2.3 | 2.5 | 0 |
| poly52 | 2.0 | 2.1 | 3.2 | 2.4 | 0 |
| control: raw CRC | **80.5** | **42.1** | 4.5 | 3.0 | 46 / 44 / 2 / 0 |

The control passes on random keys and fails on structured ones: a distribution test needs structured
key sets.

**Differentials.** H(k) = H(k with difference d) over many keys k. Sparse XOR differences: every 1-
and 2-bit d (2-bit within the first 256 bits) and every 3-bit d within the first 64 bits, on 16 random
keys each of 8, 32 and 64 units, 3.2 million tests per method; a perfect hash expects 0.0007
collisions. Then one difference per design, built from its structure:

| method | 1-, 2-, 3-bit d | CRC32C P·x^s | Rabin P·x^s | v3 K-block | poly61 d | poly52 d |
|---|--:|--:|--:|--:|--:|--:|
| v3 | 0 | 0/1000 | 0/1000 | **1000/1000** | 0/1000 | 0/1000 |
| crc32c | 0 | **1000/1000** | 0 | 0 | 0 | 0 |
| rabin64 | 0 | 0 | **1000/1000** | 0 | 0 | 0 |
| poly61 | 0 | 0 | 0 | 0 | **1000/1000** | 0 |
| poly52 | 0 | 0 | 0 | 0 | 0 | **1000/1000** |

The constructions:
- **CRC32C:** XOR the 33-bit polynomial P, shifted to any bit position: every key collides.
- **rabin64:** the same with its fixed 65-bit P.
- **poly61:** add (1662, 586, 1077, 924, −147) to any 5 consecutive units; **poly52:** add
  (−1624, −1750, 6993, 2687) to any 4. Both found by LLL lattice reduction (`lll.py`, exact rationals,
  under a second).
- **v3:** see §5.2.

### 4.3 What the quality tests show

1. On statistical quality the five hashes cannot be told apart: all pass avalanche, every-window
   distribution and sparse differentials at a sensitivity better than SMHasher's marks.
2. Every hash, v3 included, has a deterministic collision family that is easy to construct. That is
   inherent to a hash with public fixed parameters; accidental hits are as unlikely as random
   collisions for all of them.
3. Keying would close them for some designs only: rabin64 and the polynomials can take a random
   polynomial or base per process (then the provable bounds n/2^64 and n/p apply, and none of these
   constructions works without the secret); v3 could take random seeds and K; CRC32C cannot (its
   polynomial is fixed in hardware). A per-process key matters only for SeqDict keys from untrusted
   input, and makes hash values differ between runs, which matters only if a hash value is ever stored
   (SeqDict's iteration order does not depend on hashes).
4. Not covered: SMHasher's seed tests (no hash here takes a seed) and its other structured key sets
   (Cyclic, Window, Text, Zeroes). The natural next step is SMHasher3 itself, with an adapter that
   reads byte pairs as UTF-16 units.

## 5. Findings about v3 itself

### 5.1 Its tail stalls [M]

v3 copies a String's last partial 32-unit block into a stack buffer with a variable-length `memcpy`
and reads it back as 8-byte words; the loads cannot be forwarded from those stores. Any length that
is not a multiple of 32 costs about 6 ns more (31 units 14.1 ns, 32 units 8.3, 33 units 16.7). The
runtime's `StringHasher` (`ValueHash.cpp`, `units16`/`finish` buffer) has the same design.

The fix keeps every hash value (the same zero-padded words): read the partial block with a masked load
and take the words from the register (`_mm_cvtsi128_si64` / `_mm_extract_epi64`), not through a store.
With AVX-512 (`v3-masked`): −4 ns at 8 units or fewer, −2 to −4 ns on other non-multiples of 32.
Storing the vector and reloading words stalls as well. With AVX2 only (`v3-avx2tail`, `vpmaskmovd`
plus clearing an odd last unit, which reads the 2 bytes after the String's last unit; inside an eco
String's 8-byte-rounded object) it saves 4 ns at 8 units or fewer and nothing at 9-31: `vpmaskmovd` is
slow.

### 5.2 A prefix-erasing collision family [M]

Each v3 lane computes `mum(w ⊕ K, w′ ⊕ lane)`. A word equal to K makes the first factor 0, so the lane
becomes 0 and forgets everything it absorbed. A 32-unit block whose four even words equal K (16 units:
U+642F U+78BD U+1D64 U+A076 per lane, on a 32-unit boundary) erases all four lanes: every String of the
same length that ends with that block and the same suffix hashes the same, whatever precedes it. 1,000
Strings with different first 32 units gave 1 distinct hash (checked in the Python reference and in the
lab). wyhash, which v3 follows, has the same known weakness. Ordinary text essentially never contains
those characters at those positions; the risk is crafted keys in a SeqDict fed untrusted input.
Possible fixes (unmeasured): mix the lane into both factors, or add the product into the lane rather
than replace it. Neither makes v3 safe against an attacker who knows its constants; that needs keying.

## 6. CPU support

eco pins x86-64 code to x86-64-v3 (`kEcoTargetCPU`, `runtime/src/codegen/EcoBackend.h`; the release
preset's `-march=x86-64-v3`): SSE4.2, AVX2, BMI1/2, FMA. A CRC32C design would add:

- **PCLMULQDQ is not part of x86-64-v3**, though every v3-class CPU has it (Haswell, AMD Excavator and
  later). Either `design_docs/compatability.md` states it, or eco falls back to crc32c-3, which needs only
  the SSE4.2 `crc32` instruction.
- **Wider folding needs run-time selection:** fold256 (VPCLMULQDQ on AVX2) and fold512 (AVX-512) are
  not on every v3 CPU. The static musl build has no IFUNC, so eco would check the CPU at start-up and
  set a function pointer. All variants compute the same value, so hashes never differ between machines.
- The String hash is computed only in the runtime: compiled code calls `eco_hash_mix_string`, so a new
  definition changes `stringHash`, `value-hash.md` (a "v4"), the hash pins in the tests and the
  colliding-key triple the tests use, not codegen.
- Not built: ARMv8 (`PMULL`, `crc32c` instructions exist there); UTF-8 leaf input (the folding methods
  would widen bytes with `vpmovzxbw` / `pmovzxbw`).

## 7. Decision: crc32c-fold128 for the composability experiment

- **Composable, with the cheapest join:** 3.4-4.3 ns at any length.
- **Fits Part B's slots:** its raw state is 32 bits, the size of the hash slot in slices, ropes, views
  and large Strings (HEAP_088). rabin64 needs 64 bits, which only a flat String's tail word has.
- **Portable at eco's floor:** x86-64-v3 + PCLMULQDQ, with crc32c-3 as a fallback that needs only
  SSE4.2; faster variants (fold256, fold512) can be selected at start-up with the same values.
- **Speed:** faster than v3 below about 64 units, where most SeqDict keys are; about 1.2× slower on
  long Strings at the v3 level (2.4-3.4× faster with AVX-512).
- **Quality:** equal to v3 on every test here, and better than random on keys with short differences.
- **Accepted costs:** it is linear over GF(2) with a fixed polynomial, so its collision family (§4.2)
  cannot be removed by keying; v3's cannot either without a definition change.

The experiment itself (B5): first a census of how often both sides of a `++` already hold a filled
slot (if rarely, composition cannot pay, whatever the hash costs), then joining the sides' raw CRCs
into the new String's slot in `makeRope` and `concat`, measured on seqdict-prefixkey-fresh and the
String-building workloads.

## 7a. Outcome in eco (2026-11-25)

crc32c-fold128 became value-hash definition v4 (`runtime/src/allocator/Crc32c.cpp`, with a CPUID check
and a portable fallback), and Strings built from parts are given their hash by composition
(plans/hash-reuse-explicit-vs-cached.md B5a-B5c, results in its §7). Measured against the base, with no
program change: seqdict-prefixkey −61 % (ahead of Part A's opt-in `Hashed` keys), seqdict-prefixkey-fresh
−30 %, string-eq-prefix −92 % (built keys carry hashes, so `==` rejects from them); composing hashes no
one reads costs ≤ 2 %. Hashing at build in the per-unit builders was measured and removed: nothing in
the benchmark suite hashes what they build.

## 8. Reproducing

`experiments/string-hash-lab/run.sh` builds both binaries (into `/tmp/string-hash-lab` unless `OUT` is
set), runs the correctness and composition tests for each, checks the v3 copy against `v3ref.py`,
regenerates the polynomial differences (`hashlab params | lll.py`), and writes `results/` (quality,
avalanche, windows, diff, time for both builds; core `CORE`, default 5). The AVX-512 build needs an
AVX-512 host with VPCLMULQDQ and IFMA. Single modes: `hashlab test | quality | avalanche | windows |
diff <lll.txt> | time | params | v3vec`.
