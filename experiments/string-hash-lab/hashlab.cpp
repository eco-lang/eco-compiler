// hashlab.cpp: a side experiment, not part of eco. Composable (associative) String hashes measured
// against eco's String hash v3, over UTF-16 units. A composable hash has
//   raw(a ++ b) = combine(raw(a), raw(b), length b)
// so a rope or `++` could get its hash from its sides' hashes without reading a unit.
//
// Methods (each a `raw` state plus a finisher to the 32-bit, never-0 hash SeqDict reads):
//   v3          eco's definition (ValueHash.cpp stringHash), copied; not composable.
//   v3-masked   the same hash, its partial last block read by a masked load (no stack copy).
//   crc32c-1    CRC32C, one stream of the SSE4.2 crc32 instruction (8 bytes per step).
//   crc32c-3    CRC32C, three interleaved instruction streams, joined with carry-less multiplies.
//   crc32c-fold CRC32C by VPCLMULQDQ folding, 4 x 512-bit accumulators (256 bytes per step);
//               under 64 units it uses crc32c-3. crc32c-foldonly: folding down to 32 units.
//   rabin64     a Rabin fingerprint: the units as a polynomial over GF(2) mod a random irreducible
//               degree-64 polynomial, by the same folding, with a Barrett reduction at the end.
//   poly61-*    sum u_i B^(n-1-i) mod 2^61-1: scalar (mulx), AVX2 and AVX-512 (vpmuludq).
//   poly52-ifma the same mod the largest prime below 2^52, with AVX-512 IFMA (vpmadd52lo/hi).
//   read-floor  not a hash: xor of every 64-byte block, the cost of reading the units at all.
//
// x86-64-v3 variants (AVX2, BMI2, SSE4.2 crc32, plus PCLMULQDQ; no AVX-512). Built alone by
// `-march=x86-64-v3 -mpclmul`, where every AVX-512 method above is compiled out:
//   v3-avx2tail     v3 with its tail read by vpmaskmovd (32-bit lanes) and an odd last unit cleared.
//   crc32c-fold128  CRC32C folded 64 bytes per step with four 16-byte PCLMULQDQ accumulators.
//   crc32c-fold256  the same with 32-byte VPCLMULQDQ (AVX2 CPUs from Ice Lake / Zen 3; not Skylake).
//   rabin64-fold128 rabin64 folded with 16-byte PCLMULQDQ.
//   read-floor-avx2 read-floor with 32-byte loads.
//
// Every method is checked against a bit-by-bit (or unit-by-unit) reference, then for composition.
//
// Modes: test (references, composition), quality (collisions on structured keys), avalanche, windows,
// diff <lll.txt> (differentials; lll.py makes the polynomial ones from `params`), time, v3vec (for
// check-v3.py). run.sh runs them all. Results and conclusions: design_docs/string-hash-algorithm.md.
#include <immintrin.h>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include <vector>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef unsigned __int128 u128;
#define NOINLINE __attribute__((noinline))
#define INLINE inline __attribute__((always_inline))

static INLINE u32 nonZero(u32 h) { return h ? h : 1u; }
static INLINE u32 fmix32(u32 h) {
    h ^= h >> 16; h *= 0x85ebca6bu; h ^= h >> 13; h *= 0xc2b2ae35u; h ^= h >> 16;
    return h;
}
static INLINE u64 fmix64(u64 k) {
    k ^= k >> 33; k *= 0xff51afd7ed558ccdull; k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53ull; k ^= k >> 33;
    return k;
}
// The finisher of the 64-bit raw states: the length goes in here, so leading zero units count.
static INLINE u32 finish64(u64 raw, size_t n) {
    u64 h = fmix64(raw ^ (n * 0x9E3779B97F4A7C15ull));
    return nonZero(static_cast<u32>(h ^ (h >> 32)));
}
static INLINE u64 rev64(u64 x) { return __builtin_bitreverse64(x); }

// ============================================================================ v3 (eco, copied)
namespace v3 {
constexpr u64 K = 0xa0761d6478bd642full;
constexpr u64 S[4] = {0xe7037ed1a0b428dbull, 0x8ebc6af09c88c6e3ull, 0x589965cc75374cc3ull,
                      0x1d8e4e27c47d124full};
static INLINE u64 mum(u64 a, u64 b) {
    u128 r = static_cast<u128>(a) * b;
    return static_cast<u64>(r) ^ static_cast<u64>(r >> 64);
}
NOINLINE u32 hash(const u16* p, size_t n) {
    if (n <= 8) {
        u16 buf[8] = {0};
        memcpy(buf, p, n * 2);
        u64 w[2];
        memcpy(w, buf, 16);
        u64 h = mum(w[0] ^ K, w[1] ^ S[0]);
        h = mum(h ^ K, static_cast<u64>(n) ^ S[0]);
        return nonZero(static_cast<u32>(h ^ (h >> 32)));
    }
    u64 l0 = S[0], l1 = S[1], l2 = S[2], l3 = S[3];
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        u64 w[8];
        memcpy(w, p + i, 64);
        l0 = mum(w[0] ^ K, w[1] ^ l0);
        l1 = mum(w[2] ^ K, w[3] ^ l1);
        l2 = mum(w[4] ^ K, w[5] ^ l2);
        l3 = mum(w[6] ^ K, w[7] ^ l3);
    }
    if (i < n) {
        u16 buf[32] = {0};
        memcpy(buf, p + i, (n - i) * 2);
        u64 w[8];
        memcpy(w, buf, 64);
        l0 = mum(w[0] ^ K, w[1] ^ l0);
        l1 = mum(w[2] ^ K, w[3] ^ l1);
        l2 = mum(w[4] ^ K, w[5] ^ l2);
        l3 = mum(w[6] ^ K, w[7] ^ l3);
    }
    u64 h = mum(l0 ^ S[1], l1 ^ S[2]) ^ mum(l2 ^ S[3], l3 ^ S[0]);
    h = mum(h ^ K, static_cast<u64>(n) ^ S[0]);
    return nonZero(static_cast<u32>(h ^ (h >> 32)));
}
#ifdef __AVX512F__
// v3 with the partial last block (and a short String) read by one masked load instead of a copy into a
// stack buffer: the same zero-padded words, so the same hash, without the store-forwarding stall of
// reading 8-byte words back from a variable-length memcpy.
NOINLINE u32 hashMasked(const u16* p, size_t n) {
    if (n <= 8) {
        __m128i x = _mm_maskz_loadu_epi16(static_cast<__mmask8>((1u << n) - 1), p);
        u64 h = mum(static_cast<u64>(_mm_cvtsi128_si64(x)) ^ K, static_cast<u64>(_mm_extract_epi64(x, 1)) ^ S[0]);
        h = mum(h ^ K, static_cast<u64>(n) ^ S[0]);
        return nonZero(static_cast<u32>(h ^ (h >> 32)));
    }
    u64 l0 = S[0], l1 = S[1], l2 = S[2], l3 = S[3];
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        u64 w[8];
        memcpy(w, p + i, 64);
        l0 = mum(w[0] ^ K, w[1] ^ l0);
        l1 = mum(w[2] ^ K, w[3] ^ l1);
        l2 = mum(w[4] ^ K, w[5] ^ l2);
        l3 = mum(w[6] ^ K, w[7] ^ l3);
    }
    if (i < n) {
        // The words straight from the register: storing the vector and reloading 8-byte words stalls too.
        const __m512i z = _mm512_maskz_loadu_epi16(static_cast<__mmask32>((1ull << (n - i)) - 1), p + i);
        const __m128i q0 = _mm512_castsi512_si128(z), q1 = _mm512_extracti32x4_epi32(z, 1),
                      q2 = _mm512_extracti32x4_epi32(z, 2), q3 = _mm512_extracti32x4_epi32(z, 3);
        l0 = mum(static_cast<u64>(_mm_cvtsi128_si64(q0)) ^ K, static_cast<u64>(_mm_extract_epi64(q0, 1)) ^ l0);
        l1 = mum(static_cast<u64>(_mm_cvtsi128_si64(q1)) ^ K, static_cast<u64>(_mm_extract_epi64(q1, 1)) ^ l1);
        l2 = mum(static_cast<u64>(_mm_cvtsi128_si64(q2)) ^ K, static_cast<u64>(_mm_extract_epi64(q2, 1)) ^ l2);
        l3 = mum(static_cast<u64>(_mm_cvtsi128_si64(q3)) ^ K, static_cast<u64>(_mm_extract_epi64(q3, 1)) ^ l3);
    }
    u64 h = mum(l0 ^ S[1], l1 ^ S[2]) ^ mum(l2 ^ S[3], l3 ^ S[0]);
    h = mum(h ^ K, static_cast<u64>(n) ^ S[0]);
    return nonZero(static_cast<u32>(h ^ (h >> 32)));
}
#endif
// v3 with the tail read by AVX2 masked loads. vpmaskmovd masks 32-bit lanes, so for an odd count it reads
// the 2 bytes after the last unit (in eco, inside the String object's 8-byte-rounded size) and then
// clears that unit.
alignas(64) const int32_t kDwordMask[16] = {-1, -1, -1, -1, -1, -1, -1, -1, 0, 0, 0, 0, 0, 0, 0, 0};
alignas(64) const u16 kUnitMask[64] = {
    0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF,
    0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF};
NOINLINE u32 hashAvx2Tail(const u16* p, size_t n) {
    if (n <= 8) {
        const size_t d = (n + 1) / 2;
        __m128i x = _mm_maskload_epi32(reinterpret_cast<const int*>(p), _mm_loadu_si128(reinterpret_cast<const __m128i*>(kDwordMask + 8 - d)));
        x = _mm_and_si128(x, _mm_loadu_si128(reinterpret_cast<const __m128i*>(kUnitMask + 32 - n)));
        u64 h = mum(static_cast<u64>(_mm_cvtsi128_si64(x)) ^ K, static_cast<u64>(_mm_extract_epi64(x, 1)) ^ S[0]);
        h = mum(h ^ K, static_cast<u64>(n) ^ S[0]);
        return nonZero(static_cast<u32>(h ^ (h >> 32)));
    }
    u64 l0 = S[0], l1 = S[1], l2 = S[2], l3 = S[3];
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        u64 w[8];
        memcpy(w, p + i, 64);
        l0 = mum(w[0] ^ K, w[1] ^ l0);
        l1 = mum(w[2] ^ K, w[3] ^ l1);
        l2 = mum(w[4] ^ K, w[5] ^ l2);
        l3 = mum(w[6] ^ K, w[7] ^ l3);
    }
    if (i < n) {
        const size_t t = n - i, d = (t + 1) / 2;
        const int* q = reinterpret_cast<const int*>(p + i);
        __m256i y0 = _mm256_maskload_epi32(q, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(kDwordMask + 8 - (d < 8 ? d : 8))));
        __m256i y1 = _mm256_maskload_epi32(q + 8, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(kDwordMask + 8 - (d > 8 ? d - 8 : 0))));
        y0 = _mm256_and_si256(y0, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(kUnitMask + 32 - t)));
        y1 = _mm256_and_si256(y1, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(kUnitMask + 48 - t)));
        const __m128i q0 = _mm256_castsi256_si128(y0), q1 = _mm256_extracti128_si256(y0, 1),
                      q2 = _mm256_castsi256_si128(y1), q3 = _mm256_extracti128_si256(y1, 1);
        l0 = mum(static_cast<u64>(_mm_cvtsi128_si64(q0)) ^ K, static_cast<u64>(_mm_extract_epi64(q0, 1)) ^ l0);
        l1 = mum(static_cast<u64>(_mm_cvtsi128_si64(q1)) ^ K, static_cast<u64>(_mm_extract_epi64(q1, 1)) ^ l1);
        l2 = mum(static_cast<u64>(_mm_cvtsi128_si64(q2)) ^ K, static_cast<u64>(_mm_extract_epi64(q2, 1)) ^ l2);
        l3 = mum(static_cast<u64>(_mm_cvtsi128_si64(q3)) ^ K, static_cast<u64>(_mm_extract_epi64(q3, 1)) ^ l3);
    }
    u64 h = mum(l0 ^ S[1], l1 ^ S[2]) ^ mum(l2 ^ S[3], l3 ^ S[0]);
    h = mum(h ^ K, static_cast<u64>(n) ^ S[0]);
    return nonZero(static_cast<u32>(h ^ (h >> 32)));
}
}  // namespace v3

#ifdef __AVX512F__
// ============================================================================ GF(2) folding engine
// A 16-byte chunk at byte offset o of the stream is the polynomial whose bit m (little-endian bit
// numbering over the 16 bytes) is the coefficient of x^(127-m), shifted by the bits after the chunk:
// the "reflected" order of CRC32C, which keeps every unit's degree a function of its distance from the
// end, the property composition needs. Folding a chunk X forward by D bits onto the chunk D bits later
// is X.lo64 * klo ^ X.hi64 * khi (carry-less), with constants given by the method.
struct FoldK {
    __m512i k2048, k512, kred;
    __m128i k128;
};
static INLINE __m512i fold512(__m512i a, __m512i k, __m512i data) {
    return _mm512_ternarylogic_epi64(_mm512_clmulepi64_epi128(a, k, 0x00),
                                     _mm512_clmulepi64_epi128(a, k, 0x11), data, 0x96);
}
static INLINE __m128i fold128(__m128i a, __m128i k, __m128i data) {
    return _mm_ternarylogic_epi64(_mm_clmulepi64_si128(a, k, 0x00), _mm_clmulepi64_si128(a, k, 0x11),
                                  data, 0x96);
}
// Folds the L stream bytes at b into one 16-byte chunk congruent to the stream (mod the polynomial),
// aligned to the stream's end. The stream is read as if prefixed by pad zero bytes, so that its length
// is a multiple of 16: leading zeros do not change a polynomial. The masked first load reads nothing
// before b (AVX-512 masked loads do not fault on masked-off bytes). With INIT, 0xFFFFFFFF is xored
// into the first four stream bytes (CRC32C's initial value; needs L >= 64 here).
template <bool INIT>
static INLINE __m128i foldStream(const u8* b, size_t L, const FoldK& K) {
    const size_t pad = (16 - (L & 15)) & 15;
    const u8* q = reinterpret_cast<const u8*>(reinterpret_cast<uintptr_t>(b) - pad);
    const size_t N = L + pad;
    size_t pos;
    __m128i x;
    if (N >= 64) {
        __m512i a = _mm512_maskz_loadu_epi8(~0ull << pad, q);
        if (INIT) a = _mm512_xor_si512(a, _mm512_maskz_set1_epi8(0xFull << pad, static_cast<char>(0xFF)));
        if (N >= 256) {
            __m512i a1 = _mm512_loadu_si512(q + 64), a2 = _mm512_loadu_si512(q + 128),
                    a3 = _mm512_loadu_si512(q + 192);
            for (pos = 256; pos + 256 <= N; pos += 256) {
                a = fold512(a, K.k2048, _mm512_loadu_si512(q + pos));
                a1 = fold512(a1, K.k2048, _mm512_loadu_si512(q + pos + 64));
                a2 = fold512(a2, K.k2048, _mm512_loadu_si512(q + pos + 128));
                a3 = fold512(a3, K.k2048, _mm512_loadu_si512(q + pos + 192));
            }
            a1 = fold512(a, K.k512, a1);
            a2 = fold512(a1, K.k512, a2);
            a = fold512(a2, K.k512, a3);
        } else {
            pos = 64;
        }
        for (; pos + 64 <= N; pos += 64) a = fold512(a, K.k512, _mm512_loadu_si512(q + pos));
        // Lanes 0-2 folded onto lane 3 (kred's lane 3 is zero), then the four lanes xored together.
        __m512i t = _mm512_xor_si512(_mm512_clmulepi64_epi128(a, K.kred, 0x00),
                                     _mm512_clmulepi64_epi128(a, K.kred, 0x11));
        __m256i h = _mm256_xor_si256(_mm512_castsi512_si256(t), _mm512_extracti64x4_epi64(t, 1));
        x = _mm_xor_si128(_mm_xor_si128(_mm256_castsi256_si128(h), _mm256_extracti128_si256(h, 1)),
                          _mm512_extracti32x4_epi32(a, 3));
    } else {
        x = _mm_maskz_loadu_epi8(static_cast<__mmask16>(0xFFFFu << pad), q);
        pos = 16;
    }
    for (; pos + 16 <= N; pos += 16) x = fold128(x, K.k128, _mm_loadu_si128(reinterpret_cast<const __m128i*>(q + pos)));
    return x;
}

#endif

// ============================================================================ 16/32-byte folding (x86-64-v3)
// The same folding with 16-byte PCLMULQDQ (on every x86-64-v3 CPU in practice, though the level does
// not promise it) or 32-byte VPCLMULQDQ (AVX2 CPUs from Ice Lake and Zen 3). No masked loads: the caller
// gives the first chunk, built however it likes, and the rest are whole chunks at q + 16, q + 32, ...
struct Fold2K {
    __m128i k512, k128;
    __m256i k1024, k256;
};
static INLINE __m128i ld16(const u8* p) { return _mm_loadu_si128(reinterpret_cast<const __m128i*>(p)); }
static INLINE __m128i fx(__m128i a, __m128i k, __m128i data) {
    return _mm_xor_si128(_mm_xor_si128(_mm_clmulepi64_si128(a, k, 0x00), _mm_clmulepi64_si128(a, k, 0x11)), data);
}
// Folds chunk x0 (at q) and the whole chunks q[16, N) into one chunk; N is a multiple of 16.
static INLINE __m128i fold128Core(__m128i x0, const u8* q, size_t N, const Fold2K& K) {
    size_t pos = 16;
    if (N >= 64) {
        __m128i x1 = ld16(q + 16), x2 = ld16(q + 32), x3 = ld16(q + 48);
        for (pos = 64; pos + 64 <= N; pos += 64) {
            x0 = fx(x0, K.k512, ld16(q + pos));
            x1 = fx(x1, K.k512, ld16(q + pos + 16));
            x2 = fx(x2, K.k512, ld16(q + pos + 32));
            x3 = fx(x3, K.k512, ld16(q + pos + 48));
        }
        x1 = fx(x0, K.k128, x1);
        x2 = fx(x1, K.k128, x2);
        x0 = fx(x2, K.k128, x3);
    }
    for (; pos + 16 <= N; pos += 16) x0 = fx(x0, K.k128, ld16(q + pos));
    return x0;
}
#define VPCL __attribute__((target("avx2,vpclmulqdq,pclmul")))
VPCL static INLINE __m256i ld32(const u8* p) { return _mm256_loadu_si256(reinterpret_cast<const __m256i*>(p)); }
VPCL static INLINE __m256i fy(__m256i a, __m256i k, __m256i data) {
    return _mm256_xor_si256(_mm256_xor_si256(_mm256_clmulepi64_epi128(a, k, 0x00), _mm256_clmulepi64_epi128(a, k, 0x11)), data);
}
// The same with 32-byte vectors, 128 bytes per step; y0 is the first 32 bytes at q; N >= 128.
VPCL static INLINE __m128i fold256Core(__m256i y0, const u8* q, size_t N, const Fold2K& K) {
    __m256i y1 = ld32(q + 32), y2 = ld32(q + 64), y3 = ld32(q + 96);
    size_t pos;
    for (pos = 128; pos + 128 <= N; pos += 128) {
        y0 = fy(y0, K.k1024, ld32(q + pos));
        y1 = fy(y1, K.k1024, ld32(q + pos + 32));
        y2 = fy(y2, K.k1024, ld32(q + pos + 64));
        y3 = fy(y3, K.k1024, ld32(q + pos + 96));
    }
    y1 = fy(y0, K.k256, y1);
    y2 = fy(y1, K.k256, y2);
    y0 = fy(y2, K.k256, y3);
    for (; pos + 32 <= N; pos += 32) y0 = fy(y0, K.k256, ld32(q + pos));
    __m128i x = fx(_mm256_castsi256_si128(y0), K.k128, _mm256_extracti128_si256(y0, 1));
    for (; pos + 16 <= N; pos += 16) x = fx(x, K.k128, ld16(q + pos));
    return x;
}

// ============================================================================ CRC32C
namespace crc {
constexpr u32 POLY = 0x82F63B78u;  // Castagnoli, reflected: bit i is the coefficient of x^(31-i)
constexpr u32 ONE = 1u << 31, X = 1u << 30;

u32 ref(u32 c, const u8* p, size_t n) {
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (POLY & (0u - (c & 1)));
    }
    return c;
}
u32 mulRef(u32 a, u32 b) {  // a * b mod P (zlib's multmodp)
    if (!a) return 0;
    u32 m = ONE, r = 0;
    for (;;) {
        if (a & m) {
            r ^= b;
            if ((a & (m - 1)) == 0) break;
        }
        m >>= 1;
        b = (b & 1) ? (b >> 1) ^ POLY : b >> 1;
    }
    return r;
}
u32 powRef(u64 e) {  // x^e mod P
    u32 r = ONE, base = X;
    while (e) {
        if (e & 1) r = mulRef(r, base);
        base = mulRef(base, base);
        e >>= 1;
    }
    return r;
}
u32 xinv;  // x^-1 mod P
u32 powSigned(int64_t e) {
    if (e >= 0) return powRef(static_cast<u64>(e));
    u32 r = ONE;
    for (int64_t i = 0; i < -e; ++i) r = mulRef(r, xinv);
    return r;
}
// M(a, b) = a * b * x^33 mod P: one carry-less multiply, reduced by the crc32 instruction. With
// hat(v) = v * x^-33, M(hat a, hat b) = hat(a b) and M(a, hat b) = a b.
static INLINE u32 M(u32 a, u32 b) {
    __m128i r = _mm_clmulepi64_si128(_mm_cvtsi32_si128(static_cast<int>(a)), _mm_cvtsi32_si128(static_cast<int>(b)), 0);
    return static_cast<u32>(_mm_crc32_u64(0, static_cast<u64>(_mm_cvtsi128_si64(r))));
}
u32 hatPow[64];  // hat(x^(2^k))
u32 hat(u32 v) { return mulRef(v, powSigned(-33)); }
// c * x^bits.
static INLINE u32 shiftBits(u32 c, u64 bits) {
    if (!bits) return c;
    u32 h = hatPow[__builtin_ctzll(bits)];
    bits &= bits - 1;
    while (bits) {
        h = M(h, hatPow[__builtin_ctzll(bits)]);
        bits &= bits - 1;
    }
    return M(c, h);
}
// raw = the CRC register after the units' bytes from 0xFFFFFFFF, without the final inversion.
// raw(a ++ b) = (raw(a) ^ ~0) * x^(16 |b|) ^ raw(b).
NOINLINE u64 combine(u64 a, u64 b, size_t nb) { return shiftBits(static_cast<u32>(a) ^ 0xFFFFFFFFu, 16ull * nb) ^ static_cast<u32>(b); }
u64 combineRef(u64 a, u64 b, size_t nb) { return mulRef(static_cast<u32>(a) ^ 0xFFFFFFFFu, powRef(16ull * nb)) ^ static_cast<u32>(b); }
u64 rawRef(const u16* p, size_t n) { return ref(0xFFFFFFFFu, reinterpret_cast<const u8*>(p), 2 * n); }
static INLINE u32 fin(u64 raw, size_t n) { return nonZero(fmix32(static_cast<u32>(raw) ^ static_cast<u32>(n))); }

static INLINE u64 ld8(const u8* p) { u64 w; memcpy(&w, p, 8); return w; }
static INLINE u64 tail(u64 c, const u8* b, size_t L) {  // L < 8, even
    if (L >= 4) { u32 w; memcpy(&w, b, 4); c = _mm_crc32_u32(static_cast<u32>(c), w); b += 4; L -= 4; }
    if (L) { u16 w; memcpy(&w, b, 2); c = _mm_crc32_u16(static_cast<u32>(c), w); }
    return c;
}
static INLINE u64 seq(u64 c, const u8* b, size_t L) {
    size_t i = 0;
    for (; i + 8 <= L; i += 8) c = _mm_crc32_u64(c, ld8(b + i));
    return tail(c, b + i, L - i);
}
NOINLINE u64 raw1(const u16* p, size_t n) { return static_cast<u32>(seq(0xFFFFFFFFu, reinterpret_cast<const u8*>(p), 2 * n)); }

struct Tier { u32 k2, k1; };  // hat(x^(8 * 2 BLK)), hat(x^(8 * BLK))
Tier tiers[3];
template <size_t BLK>
static INLINE u64 stride3(const u8*& b, size_t& L, u64 c0, const Tier& t) {
    while (L >= 3 * BLK) {
        u64 c1 = 0, c2 = 0;
        for (size_t i = 0; i < BLK; i += 8) {
            c0 = _mm_crc32_u64(c0, ld8(b + i));
            c1 = _mm_crc32_u64(c1, ld8(b + BLK + i));
            c2 = _mm_crc32_u64(c2, ld8(b + 2 * BLK + i));
        }
        c0 = M(static_cast<u32>(c0), t.k2) ^ M(static_cast<u32>(c1), t.k1) ^ c2;
        b += 3 * BLK;
        L -= 3 * BLK;
    }
    return c0;
}
static INLINE u64 raw3b(const u8* b, size_t L) {
    u64 c = 0xFFFFFFFFu;
    c = stride3<2048>(b, L, c, tiers[0]);
    c = stride3<256>(b, L, c, tiers[1]);
    c = stride3<32>(b, L, c, tiers[2]);
    return static_cast<u32>(seq(c, b, L));
}
NOINLINE u64 raw3(const u16* p, size_t n) { return raw3b(reinterpret_cast<const u8*>(p), 2 * n); }

NOINLINE u32 hash1(const u16* p, size_t n) { return fin(raw1(p, n), n); }
NOINLINE u32 hash3(const u16* p, size_t n) { return fin(raw3(p, n), n); }
#ifdef __AVX512F__
FoldK fk;
static INLINE u64 foldRaw(const u8* b, size_t L) {
    __m128i x = foldStream<true>(b, L, fk);
    u64 c = _mm_crc32_u64(0, static_cast<u64>(_mm_cvtsi128_si64(x)));
    return static_cast<u32>(_mm_crc32_u64(c, static_cast<u64>(_mm_extract_epi64(x, 1))));
}
NOINLINE u64 rawFold(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    return 2 * n >= 128 ? foldRaw(b, 2 * n) : raw3b(b, 2 * n);
}
NOINLINE u64 rawFoldOnly(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    return 2 * n >= 64 ? foldRaw(b, 2 * n) : raw3b(b, 2 * n);
}
NOINLINE u32 hashFold(const u16* p, size_t n) { return fin(rawFold(p, n), n); }
NOINLINE u32 hashFoldOnly(const u16* p, size_t n) { return fin(rawFoldOnly(p, n), n); }
#endif

// 16/32-byte folding over the whole 16-byte chunks from the start (0xFFFFFFFF xored into the first four
// bytes), then the last chunk and the tail through the crc32 instruction. Under 64 units: crc32c-3.
Fold2K fk2;
static INLINE u64 chunkCrc(__m128i x) {
    u64 c = _mm_crc32_u64(0, static_cast<u64>(_mm_cvtsi128_si64(x)));
    return _mm_crc32_u64(c, static_cast<u64>(_mm_extract_epi64(x, 1)));
}
static INLINE u64 fold128Raw(const u8* b, size_t L) {
    const size_t N = L & ~size_t(15);
    __m128i x = fold128Core(_mm_xor_si128(ld16(b), _mm_cvtsi32_si128(-1)), b, N, fk2);
    return static_cast<u32>(seq(chunkCrc(x), b + N, L - N));
}
NOINLINE u64 rawFold128(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    return 2 * n >= 128 ? fold128Raw(b, 2 * n) : raw3b(b, 2 * n);
}
VPCL NOINLINE u64 rawFold256(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    const size_t L = 2 * n;
    if (L < 256) return L >= 128 ? fold128Raw(b, L) : raw3b(b, L);
    const size_t N = L & ~size_t(15);
    __m128i x = fold256Core(_mm256_xor_si256(ld32(b), _mm256_set_epi64x(0, 0, 0, 0xFFFFFFFFll)), b, N, fk2);
    return static_cast<u32>(seq(chunkCrc(x), b + N, L - N));
}
NOINLINE u32 hashFold128(const u16* p, size_t n) { return fin(rawFold128(p, n), n); }
// A control for the quality tests: the raw CRC with no finisher (only the length xored in). Linear, so
// it must fail avalanche.
NOINLINE u32 hashRawControl(const u16* p, size_t n) { return nonZero(static_cast<u32>(rawFold128(p, n)) ^ static_cast<u32>(n)); }
VPCL NOINLINE u32 hashFold256(const u16* p, size_t n) { return fin(rawFold256(p, n), n); }

void init() {
    xinv = ((POLY << 1) | 1u);
    if (mulRef(xinv, X) != ONE) { fprintf(stderr, "crc: x^-1 wrong\n"); exit(1); }
    for (int k = 0; k < 64; ++k) hatPow[k] = hat(powRef(1ull << k));
    const size_t blks[3] = {2048, 256, 32};
    for (int i = 0; i < 3; ++i) tiers[i] = {hat(powRef(16ull * blks[i])), hat(powRef(8ull * blks[i]))};
    auto kp = [](u64 D) { return _mm_set_epi64x(powSigned(static_cast<int64_t>(D) - 33), powRef(D + 31)); };
    fk2.k512 = kp(512);
    fk2.k128 = kp(128);
    fk2.k1024 = _mm256_set_m128i(kp(1024), kp(1024));
    fk2.k256 = _mm256_set_m128i(kp(256), kp(256));
#ifdef __AVX512F__
    fk.k2048 = _mm512_broadcast_i32x4(kp(2048));
    fk.k512 = _mm512_broadcast_i32x4(kp(512));
    fk.k128 = kp(128);
    __m128i r384 = kp(384), r256 = kp(256), r128 = kp(128);
    fk.kred = _mm512_inserti32x4(_mm512_inserti32x4(_mm512_inserti32x4(_mm512_setzero_si512(), r384, 0), r256, 1), r128, 2);
#endif
}
}  // namespace crc

// ============================================================================ Rabin fingerprint, 64-bit
namespace rabin {
u64 Pl;            // P = x^64 + Pl (normal order: bit k is the coefficient of x^k)
u64 PlR, muR;      // reflected Pl, reflected mu* (mu = floor(x^128 / P) = x^64 + mu*)
static u64 xtimes(u64 r) { u64 top = r >> 63; r <<= 1; return top ? r ^ Pl : r; }
static u64 mulN(u64 a, u64 b) {  // normal order, mod P
    u64 r = 0;
    for (int k = 63; k >= 0; --k) {
        r = xtimes(r);
        if ((b >> k) & 1) r ^= a;
    }
    return r;
}
static u64 powN(u128 e) {
    u64 r = 1, base = 2;
    while (e) {
        if (e & 1) r = mulN(r, base);
        base = mulN(base, base);
        e >>= 1;
    }
    return r;
}
static int deg128(u128 a) { if (!a) return -1; u64 hi = static_cast<u64>(a >> 64); return hi ? 127 - __builtin_clzll(hi) : 63 - __builtin_clzll(static_cast<u64>(a)); }
static u128 gcdN(u128 a, u128 b) {
    while (b) {
        while (deg128(a) >= deg128(b)) a ^= b << (deg128(a) - deg128(b));
        std::swap(a, b);
    }
    return a;
}
static bool irreducible(u64 pl) {
    Pl = pl;
    u64 t = 2;
    for (int i = 0; i < 32; ++i) t = mulN(t, t);  // x^(2^32)
    u128 P = (static_cast<u128>(1) << 64) | pl;
    if (deg128(gcdN(P, static_cast<u128>(t ^ 2))) != 0) return false;
    for (int i = 0; i < 32; ++i) t = mulN(t, t);  // x^(2^64)
    return t == 2;
}
// Reference: the stream's bits, highest degree first (bytes in order, each least significant bit
// first), as a polynomial mod P; returned reflected.
u64 rawRef(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    u64 r = 0;
    for (size_t i = 0; i < 2 * n; ++i)
        for (int k = 0; k < 8; ++k) r = xtimes(r) ^ ((b[i] >> k) & 1);
    return rev64(r);
}
// Reduces a folded chunk (low qword = the high-degree half) mod P.
static INLINE u64 barrett(__m128i X) {
    const __m128i K = _mm_set_epi64x(static_cast<long long>(PlR), static_cast<long long>(muR));
    const u64 A = static_cast<u64>(_mm_cvtsi128_si64(X)), B = static_cast<u64>(_mm_extract_epi64(X, 1));
    const __m128i t = _mm_clmulepi64_si128(X, K, 0x00);
    const u64 q = A ^ (static_cast<u64>(_mm_cvtsi128_si64(t)) << 1);
    const __m128i u = _mm_clmulepi64_si128(_mm_cvtsi64_si128(static_cast<long long>(q)), K, 0x10);
    const u64 ulo = static_cast<u64>(_mm_cvtsi128_si64(u)), uhi = static_cast<u64>(_mm_extract_epi64(u, 1));
    return B ^ ((ulo >> 63) | (uhi << 1));
}
// M(a, b) = a * b * x mod P; hat(v) = v * x^-1.
static INLINE u64 M(u64 a, u64 b) {
    return barrett(_mm_clmulepi64_si128(_mm_cvtsi64_si128(static_cast<long long>(a)), _mm_cvtsi64_si128(static_cast<long long>(b)), 0));
}
u64 hatPow[64];
static INLINE u64 shiftBits(u64 c, u64 bits) {
    if (!bits) return c;
    u64 h = hatPow[__builtin_ctzll(bits)];
    bits &= bits - 1;
    while (bits) {
        h = M(h, hatPow[__builtin_ctzll(bits)]);
        bits &= bits - 1;
    }
    return M(c, h);
}
NOINLINE u64 combine(u64 a, u64 b, size_t nb) { return shiftBits(a, 16ull * nb) ^ b; }
u64 combineRef(u64 a, u64 b, size_t nb) { return rev64(mulN(rev64(a), powN(16ull * nb))) ^ b; }

#ifdef __AVX512F__
FoldK fk;
NOINLINE u64 raw(const u16* p, size_t n) {
    if (!n) return 0;
    return barrett(foldStream<false>(reinterpret_cast<const u8*>(p), 2 * n, fk));
}
NOINLINE u32 hash(const u16* p, size_t n) { return finish64(raw(p, n), n); }
#endif

// 16-byte folding. The stream is read as if prefixed by zeros up to a multiple of 16 bytes; the
// leading partial chunk (r = L mod 16 bytes, at its end) is built from scalar loads inside the String.
Fold2K fk2;
static INLINE u64 ld8(const u8* p) { u64 w; memcpy(&w, p, 8); return w; }
static INLINE u32 ld4(const u8* p) { u32 w; memcpy(&w, p, 4); return w; }
static INLINE u16 ld2(const u8* p) { u16 w; memcpy(&w, p, 2); return w; }
static INLINE __m128i partialChunk(const u8* b, size_t r) {  // r even, 2..14
    u64 lo, hi = 0;
    if (r >= 8) {
        lo = ld8(b);
        if (r > 8) hi = ld8(b + r - 8) >> (8 * (16 - r));
    } else if (r >= 4) {
        lo = ld4(b);
        if (r == 6) lo |= static_cast<u64>(ld4(b + 2) >> 16) << 32;
    } else {
        lo = ld2(b);
    }
    const u128 v = ((static_cast<u128>(hi) << 64) | lo) << (8 * (16 - r));
    return _mm_set_epi64x(static_cast<long long>(static_cast<u64>(v >> 64)), static_cast<long long>(static_cast<u64>(v)));
}
NOINLINE u64 raw128(const u16* p, size_t n) {
    if (!n) return 0;
    const u8* b = reinterpret_cast<const u8*>(p);
    const size_t L = 2 * n, r = L & 15;
    if (!r) return barrett(fold128Core(ld16(b), b, L, fk2));
    const u8* q = reinterpret_cast<const u8*>(reinterpret_cast<uintptr_t>(b) + r - 16);  // chunk 0's virtual start
    return barrett(fold128Core(partialChunk(b, r), q, L + 16 - r, fk2));
}
NOINLINE u32 hash128(const u16* p, size_t n) { return finish64(raw128(p, n), n); }

void init() {
    std::mt19937_64 rng(20261124);
    do Pl = rng() | 1; while (!irreducible(Pl));
    PlR = rev64(Pl);
    // mu = floor(x^128 / P): long division, the dividend's 129 bits shifted in highest first.
    u64 rem = 0;
    u128 q = 0;
    for (int i = 128; i >= 0; --i) {
        u64 top = rem >> 63;
        rem = (rem << 1) | (i == 128 ? 1 : 0);
        q = (q << 1) | top;
        if (top) rem ^= Pl;
    }
    muR = rev64(static_cast<u64>(q));
    for (int k = 0; k < 64; ++k) hatPow[k] = rev64(powN((static_cast<u128>(1) << k) - 1));
    auto kp = [](u64 D) { return _mm_set_epi64x(static_cast<long long>(rev64(powN(D - 1))), static_cast<long long>(rev64(powN(D + 63)))); };
    fk2.k512 = kp(512);
    fk2.k128 = kp(128);
#ifdef __AVX512F__
    fk.k2048 = _mm512_broadcast_i32x4(kp(2048));
    fk.k512 = _mm512_broadcast_i32x4(kp(512));
    fk.k128 = kp(128);
    fk.kred = _mm512_inserti32x4(_mm512_inserti32x4(_mm512_inserti32x4(_mm512_setzero_si512(), kp(384), 0), kp(256), 1), kp(128), 2);
#endif
}
}  // namespace rabin

// ============================================================================ polynomial mod 2^61-1
namespace p61 {
constexpr u64 P = (1ull << 61) - 1;
constexpr size_t BLK = 256, SBLK = 32;
static INLINE u64 red(u128 x) {  // x < 2^122
    u64 r = (static_cast<u64>(x) & P) + static_cast<u64>(x >> 61);
    r = (r & P) + (r >> 61);
    return r >= P ? r - P : r;
}
static INLINE u64 mulm(u64 a, u64 b) { return red(static_cast<u128>(a) * b); }
u64 B;
u64 PW[BLK + 1];                     // B^k
alignas(64) u64 TL[BLK], TH[BLK];    // B^(BLK-1-j), low 32 and high 29 bits
u64 BP[64];                          // B^(2^k)

u64 rawRef(const u16* p, size_t n) {
    u64 h = 0;
    for (size_t i = 0; i < n; ++i) h = red(static_cast<u128>(h) * B + p[i]);
    return h;
}
static INLINE u64 powB(u64 e) {
    if (e <= BLK) return PW[e];
    u64 r = 1;
    while (e) { r = mulm(r, BP[__builtin_ctzll(e)]); e &= e - 1; }
    return r;
}
NOINLINE u64 combine(u64 a, u64 b, size_t nb) { u64 r = mulm(a, powB(nb)) + b; return r >= P ? r - P : r; }
u64 combineRef(u64 a, u64 b, size_t nb) {
    u64 r = a;
    for (size_t i = 0; i < nb; ++i) r = mulm(r, B);
    r += b;
    return r >= P ? r - P : r;
}

// Scalar: blocks of 32 units, each a sum of independent 64 x 64 -> 128 multiplies.
NOINLINE u64 rawScalar(const u16* p, size_t n) {
    size_t r = n % SBLK, i = 0;
    u128 s = 0;
    for (; i < r; ++i) s += static_cast<u128>(p[i]) * PW[r - 1 - i];
    u64 h = red(s);
    for (; i < n; i += SBLK) {
        u128 a0 = 0, a1 = 0;
        for (size_t j = 0; j < SBLK; j += 2) {
            a0 += static_cast<u128>(p[i + j]) * PW[SBLK - 1 - j];
            a1 += static_cast<u128>(p[i + j + 1]) * PW[SBLK - 2 - j];
        }
        h = red(static_cast<u128>(mulm(h, PW[SBLK])) + a0 + a1);
    }
    return h;
}

#ifdef __AVX512F__
// AVX-512: units zero-extended to 64-bit lanes, times B^k split into 32-bit halves (vpmuludq), summed
// per lane; one dependent multiply-mod per 256 units.
static INLINE u128 block512(const u16* p, size_t cnt, const u64* tl, const u64* th) {
    __m512i l0 = _mm512_setzero_si512(), h0 = l0, l1 = l0, h1 = l0;
    size_t j = 0;
    for (; j + 16 <= cnt; j += 16) {
        __m512i u0 = _mm512_cvtepu16_epi64(_mm_loadu_si128(reinterpret_cast<const __m128i*>(p + j)));
        __m512i u1 = _mm512_cvtepu16_epi64(_mm_loadu_si128(reinterpret_cast<const __m128i*>(p + j + 8)));
        l0 = _mm512_add_epi64(l0, _mm512_mul_epu32(u0, _mm512_loadu_si512(tl + j)));
        h0 = _mm512_add_epi64(h0, _mm512_mul_epu32(u0, _mm512_loadu_si512(th + j)));
        l1 = _mm512_add_epi64(l1, _mm512_mul_epu32(u1, _mm512_loadu_si512(tl + j + 8)));
        h1 = _mm512_add_epi64(h1, _mm512_mul_epu32(u1, _mm512_loadu_si512(th + j + 8)));
    }
    for (; j < cnt; j += 8) {
        __mmask8 m = cnt - j >= 8 ? 0xFF : static_cast<__mmask8>((1u << (cnt - j)) - 1);
        __m512i u = _mm512_cvtepu16_epi64(_mm_maskz_loadu_epi16(m, p + j));
        l0 = _mm512_add_epi64(l0, _mm512_mul_epu32(u, _mm512_maskz_loadu_epi64(m, tl + j)));
        h0 = _mm512_add_epi64(h0, _mm512_mul_epu32(u, _mm512_maskz_loadu_epi64(m, th + j)));
    }
    u64 sl = static_cast<u64>(_mm512_reduce_add_epi64(_mm512_add_epi64(l0, l1)));
    u64 sh = static_cast<u64>(_mm512_reduce_add_epi64(_mm512_add_epi64(h0, h1)));
    return static_cast<u128>(sl) + (static_cast<u128>(sh) << 32);
}
NOINLINE u64 rawAvx512(const u16* p, size_t n) {
    size_t r = n % BLK;
    u64 h = red(block512(p, r, TL + (BLK - r), TH + (BLK - r)));
    for (size_t i = r; i < n; i += BLK) h = red(static_cast<u128>(mulm(h, PW[BLK])) + block512(p + i, BLK, TL, TH));
    return h;
}
#endif
// AVX2: the same with 4 lanes; the last partial group of 4 is scalar.
static INLINE u128 block256(const u16* p, size_t cnt, const u64* tl, const u64* th) {
    __m256i l0 = _mm256_setzero_si256(), h0 = l0, l1 = l0, h1 = l0;
    size_t j = 0;
    for (; j + 8 <= cnt; j += 8) {
        __m256i u0 = _mm256_cvtepu16_epi64(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(p + j)));
        __m256i u1 = _mm256_cvtepu16_epi64(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(p + j + 4)));
        l0 = _mm256_add_epi64(l0, _mm256_mul_epu32(u0, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(tl + j))));
        h0 = _mm256_add_epi64(h0, _mm256_mul_epu32(u0, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(th + j))));
        l1 = _mm256_add_epi64(l1, _mm256_mul_epu32(u1, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(tl + j + 4))));
        h1 = _mm256_add_epi64(h1, _mm256_mul_epu32(u1, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(th + j + 4))));
    }
    __m256i l = _mm256_add_epi64(l0, l1), h = _mm256_add_epi64(h0, h1);
    alignas(32) u64 lv[4], hv[4];
    _mm256_store_si256(reinterpret_cast<__m256i*>(lv), l);
    _mm256_store_si256(reinterpret_cast<__m256i*>(hv), h);
    u64 sl = lv[0] + lv[1] + lv[2] + lv[3], sh = hv[0] + hv[1] + hv[2] + hv[3];
    for (; j < cnt; ++j) { sl += p[j] * tl[j]; sh += p[j] * th[j]; }
    return static_cast<u128>(sl) + (static_cast<u128>(sh) << 32);
}
__attribute__((target("no-avx512f"))) NOINLINE u64 rawAvx2(const u16* p, size_t n) {
    size_t r = n % BLK;
    u64 h = red(block256(p, r, TL + (BLK - r), TH + (BLK - r)));
    for (size_t i = r; i < n; i += BLK) h = red(static_cast<u128>(mulm(h, PW[BLK])) + block256(p + i, BLK, TL, TH));
    return h;
}
NOINLINE u32 hashScalar(const u16* p, size_t n) { return finish64(rawScalar(p, n), n); }
NOINLINE u32 hashAvx2(const u16* p, size_t n) { return finish64(rawAvx2(p, n), n); }
#ifdef __AVX512F__
NOINLINE u32 hashAvx512(const u16* p, size_t n) { return finish64(rawAvx512(p, n), n); }
#endif

void init() {
    std::mt19937_64 rng(61);
    B = (rng() % (P - (1ull << 40))) + (1ull << 40);
    PW[0] = 1;
    for (size_t k = 1; k <= BLK; ++k) PW[k] = mulm(PW[k - 1], B);
    for (size_t j = 0; j < BLK; ++j) { TL[j] = PW[BLK - 1 - j] & 0xFFFFFFFFu; TH[j] = PW[BLK - 1 - j] >> 32; }
    BP[0] = B;
    for (int k = 1; k < 64; ++k) BP[k] = mulm(BP[k - 1], BP[k - 1]);
}
}  // namespace p61

#ifdef __AVX512F__
// ============================================================================ polynomial mod p < 2^52, IFMA
namespace p52 {
constexpr u64 M52 = (1ull << 52) - 1;
constexpr size_t BLK = 256;
u64 P, C;  // P = 2^52 - C, prime
static INLINE u64 red(u128 x) {
    while (x >> 52) x = (x & M52) + (x >> 52) * C;
    u64 r = static_cast<u64>(x);
    return r >= P ? r - P : r;
}
static INLINE u64 mulm(u64 a, u64 b) { return red(static_cast<u128>(a) * b); }
u64 B;
u64 PW[BLK + 1], BP[64];
alignas(64) u64 T[BLK];  // B^(BLK-1-j)
u64 rawRef(const u16* p, size_t n) {
    u64 h = 0;
    for (size_t i = 0; i < n; ++i) h = red(static_cast<u128>(h) * B + p[i]);
    return h;
}
static INLINE u64 powB(u64 e) {
    if (e <= BLK) return PW[e];
    u64 r = 1;
    while (e) { r = mulm(r, BP[__builtin_ctzll(e)]); e &= e - 1; }
    return r;
}
NOINLINE u64 combine(u64 a, u64 b, size_t nb) { u64 r = mulm(a, powB(nb)) + b; return r >= P ? r - P : r; }
u64 combineRef(u64 a, u64 b, size_t nb) {
    u64 r = a;
    for (size_t i = 0; i < nb; ++i) r = mulm(r, B);
    r += b;
    return r >= P ? r - P : r;
}
// unit * B^k is at most 68 bits: vpmadd52luq adds its low 52 bits to one accumulator and vpmadd52huq
// its high bits to another, multiply and add in one instruction each.
static INLINE u128 block(const u16* p, size_t cnt, const u64* t) {
    __m512i l0 = _mm512_setzero_si512(), h0 = l0, l1 = l0, h1 = l0;
    size_t j = 0;
    for (; j + 16 <= cnt; j += 16) {
        __m512i u0 = _mm512_cvtepu16_epi64(_mm_loadu_si128(reinterpret_cast<const __m128i*>(p + j)));
        __m512i u1 = _mm512_cvtepu16_epi64(_mm_loadu_si128(reinterpret_cast<const __m128i*>(p + j + 8)));
        __m512i t0 = _mm512_loadu_si512(t + j), t1 = _mm512_loadu_si512(t + j + 8);
        l0 = _mm512_madd52lo_epu64(l0, u0, t0);
        h0 = _mm512_madd52hi_epu64(h0, u0, t0);
        l1 = _mm512_madd52lo_epu64(l1, u1, t1);
        h1 = _mm512_madd52hi_epu64(h1, u1, t1);
    }
    for (; j < cnt; j += 8) {
        __mmask8 m = cnt - j >= 8 ? 0xFF : static_cast<__mmask8>((1u << (cnt - j)) - 1);
        __m512i u = _mm512_cvtepu16_epi64(_mm_maskz_loadu_epi16(m, p + j));
        __m512i tt = _mm512_maskz_loadu_epi64(m, t + j);
        l0 = _mm512_madd52lo_epu64(l0, u, tt);
        h0 = _mm512_madd52hi_epu64(h0, u, tt);
    }
    u64 sl = static_cast<u64>(_mm512_reduce_add_epi64(_mm512_add_epi64(l0, l1)));
    u64 sh = static_cast<u64>(_mm512_reduce_add_epi64(_mm512_add_epi64(h0, h1)));
    return static_cast<u128>(sl) + (static_cast<u128>(sh) << 52);
}
NOINLINE u64 raw(const u16* p, size_t n) {
    size_t r = n % BLK;
    u64 h = red(block(p, r, T + (BLK - r)));
    for (size_t i = r; i < n; i += BLK) h = red(static_cast<u128>(mulm(h, PW[BLK])) + block(p + i, BLK, T));
    return h;
}
NOINLINE u32 hash(const u16* p, size_t n) { return finish64(raw(p, n), n); }

static u64 powmod(u64 a, u64 e, u64 m) { u64 r = 1; a %= m; while (e) { if (e & 1) r = static_cast<u64>(static_cast<u128>(r) * a % m); a = static_cast<u64>(static_cast<u128>(a) * a % m); e >>= 1; } return r; }
static bool prime(u64 n) {
    u64 d = n - 1; int s = 0;
    while (!(d & 1)) { d >>= 1; ++s; }
    for (u64 a : {2ull, 3ull, 5ull, 7ull, 11ull, 13ull, 17ull, 19ull, 23ull, 29ull, 31ull, 37ull}) {
        u64 x = powmod(a, d, n);
        if (x == 1 || x == n - 1) continue;
        bool ok = false;
        for (int i = 1; i < s && !ok; ++i) { x = static_cast<u64>(static_cast<u128>(x) * x % n); ok = x == n - 1; }
        if (!ok) return false;
    }
    return true;
}
void init() {
    for (C = 1; !prime((1ull << 52) - C); C += 2) {}
    P = (1ull << 52) - C;
    std::mt19937_64 rng(52);
    B = (rng() % (P - (1ull << 40))) + (1ull << 40);
    PW[0] = 1;
    for (size_t k = 1; k <= BLK; ++k) PW[k] = mulm(PW[k - 1], B);
    for (size_t j = 0; j < BLK; ++j) T[j] = PW[BLK - 1 - j];
    BP[0] = B;
    for (int k = 1; k < 64; ++k) BP[k] = mulm(BP[k - 1], BP[k - 1]);
}
}  // namespace p52
#endif

// ============================================================================ read floor
#ifdef __AVX512F__
NOINLINE u32 readFloor(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    size_t L = 2 * n, i = 0;
    __m512i a0 = _mm512_setzero_si512(), a1 = a0, a2 = a0, a3 = a0;
    for (; i + 256 <= L; i += 256) {
        a0 = _mm512_xor_si512(a0, _mm512_loadu_si512(b + i));
        a1 = _mm512_xor_si512(a1, _mm512_loadu_si512(b + i + 64));
        a2 = _mm512_xor_si512(a2, _mm512_loadu_si512(b + i + 128));
        a3 = _mm512_xor_si512(a3, _mm512_loadu_si512(b + i + 192));
    }
    for (; i < L; i += 64) a0 = _mm512_xor_si512(a0, _mm512_maskz_loadu_epi8(L - i >= 64 ? ~0ull : (1ull << (L - i)) - 1, b + i));
    a0 = _mm512_ternarylogic_epi64(a0, a1, _mm512_xor_si512(a2, a3), 0x96);
    return nonZero(static_cast<u32>(_mm512_reduce_or_epi64(a0)));
}
#endif
NOINLINE u32 readFloor2(const u16* p, size_t n) {
    const u8* b = reinterpret_cast<const u8*>(p);
    size_t L = 2 * n, i = 0;
    __m256i a0 = _mm256_setzero_si256(), a1 = a0, a2 = a0, a3 = a0;
    for (; i + 128 <= L; i += 128) {
        a0 = _mm256_xor_si256(a0, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(b + i)));
        a1 = _mm256_xor_si256(a1, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(b + i + 32)));
        a2 = _mm256_xor_si256(a2, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(b + i + 64)));
        a3 = _mm256_xor_si256(a3, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(b + i + 96)));
    }
    for (; i + 32 <= L; i += 32) a0 = _mm256_xor_si256(a0, _mm256_loadu_si256(reinterpret_cast<const __m256i*>(b + i)));
    u64 t = 0;
    for (; i + 8 <= L; i += 8) { u64 w; memcpy(&w, b + i, 8); t ^= w; }
    for (; i < L; i += 2) { u16 w; memcpy(&w, b + i, 2); t ^= w; }
    a0 = _mm256_xor_si256(_mm256_xor_si256(a0, a1), _mm256_xor_si256(a2, a3));
    __m128i x = _mm_xor_si128(_mm256_castsi256_si128(a0), _mm256_extracti128_si256(a0, 1));
    return nonZero(static_cast<u32>(t ^ static_cast<u64>(_mm_cvtsi128_si64(x)) ^ static_cast<u64>(_mm_extract_epi64(x, 1))));
}

// ============================================================================ harness
struct Method {
    const char* name;
    u32 (*hash)(const u16*, size_t);
    u64 (*raw)(const u16*, size_t);  // null: not composable
    u64 (*rawRef)(const u16*, size_t);
    u64 (*combine)(u64, u64, size_t);
    u64 (*combineRef)(u64, u64, size_t);
};
static std::vector<Method> methods;

static std::vector<u16> randomUnits(std::mt19937_64& rng, size_t n, bool ascii) {
    std::vector<u16> v(n);
    for (auto& u : v) u = ascii ? static_cast<u16>(0x20 + rng() % 0x5F) : static_cast<u16>(rng());
    return v;
}

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { if (failures++ < 20) { fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } } while (0)

static void testCorrectness() {
    std::mt19937_64 rng(1);
    std::vector<size_t> lens;
    for (size_t n = 0; n <= 1100; ++n) lens.push_back(n);
    for (size_t n : {2047, 2048, 2049, 4095, 4096, 4097, 65535, 65536, 65537, 100003}) lens.push_back(n);
    // One buffer, 64-byte aligned; the string starts at unit offset `off` (0-7: byte misalignment 0-14).
    std::vector<u16> big = randomUnits(rng, 100003 + 64, false);
    u16* base = reinterpret_cast<u16*>((reinterpret_cast<uintptr_t>(big.data()) + 63) & ~uintptr_t(63));
    size_t checks = 0;
    for (size_t n : lens) {
        for (size_t off = 0; off < 8; ++off) {
            if (n > 1100 && off % 3) continue;
            const u16* p = base + off;
#ifdef __AVX512F__
            CHECK(v3::hashMasked(p, n) == v3::hash(p, n), "v3-masked n=%zu off=%zu", n, off);
#endif
            CHECK(v3::hashAvx2Tail(p, n) == v3::hash(p, n), "v3-avx2tail n=%zu off=%zu", n, off);
            for (auto& m : methods) {
                if (!m.raw) continue;
                u64 got = m.raw(p, n), want = m.rawRef(p, n);
                CHECK(got == want, "%s raw n=%zu off=%zu: %llx vs ref %llx", m.name, n, off, (unsigned long long)got, (unsigned long long)want);
                ++checks;
            }
        }
    }
    printf("raw vs bit-by-bit reference: %zu checks (lengths 0-1100 and 10 large ones, unit offsets 0-7)\n", checks);

    // Composition: raw(a ++ b) = combine(raw a, raw b, |b|), the fast combine against the reference one.
    size_t ccount = 0;
    std::vector<size_t> sizes;
    for (size_t n = 0; n <= 70; ++n) sizes.push_back(n);
    for (size_t n : {127, 128, 129, 255, 256, 257, 1000, 2048, 4099, 70001}) sizes.push_back(n);
    for (size_t na : sizes) {
        for (size_t nb : sizes) {
            if ((na > 300 || nb > 300) && (na + nb) % 5) continue;
            std::vector<u16> a = randomUnits(rng, na, false), b = randomUnits(rng, nb, false), ab = a;
            ab.insert(ab.end(), b.begin(), b.end());
            for (auto& m : methods) {
                if (!m.raw) continue;
                u64 ra = m.raw(a.data(), na), rb = m.raw(b.data(), nb), rab = m.raw(ab.data(), na + nb);
                u64 c = m.combine(ra, rb, nb);
                CHECK(c == rab, "%s combine na=%zu nb=%zu", m.name, na, nb);
                if (nb < 2000) CHECK(m.combineRef(ra, rb, nb) == rab, "%s combineRef na=%zu nb=%zu", m.name, na, nb);
                ++ccount;
            }
        }
    }
    // Many pieces: one 20,000-unit String cut at random points (empty pieces included), joined left to
    // right, right to left and as a balanced tree; all must give the String's own raw state.
    size_t pcount = 0;
    std::vector<u16> s = randomUnits(rng, 20000, true);
    for (int trial = 0; trial < 40; ++trial) {
        size_t k = 2 + rng() % 100;
        std::vector<size_t> cuts = {0, s.size()};
        for (size_t i = 0; i + 1 < k; ++i) cuts.push_back(rng() % (s.size() + 1));
        std::sort(cuts.begin(), cuts.end());
        for (auto& m : methods) {
            if (!m.raw) continue;
            std::vector<std::pair<u64, size_t>> pieces;
            for (size_t i = 0; i + 1 < cuts.size(); ++i) pieces.push_back({m.raw(s.data() + cuts[i], cuts[i + 1] - cuts[i]), cuts[i + 1] - cuts[i]});
            u64 want = m.raw(s.data(), s.size());
            u64 left = m.raw(s.data(), 0);
            for (auto& pc : pieces) left = m.combine(left, pc.first, pc.second);
            u64 right = m.raw(s.data(), 0);
            size_t rlen = 0;
            for (size_t i = pieces.size(); i-- > 0;) { right = m.combine(pieces[i].first, right, rlen); rlen += pieces[i].second; }
            std::vector<std::pair<u64, size_t>> lvl = pieces;
            while (lvl.size() > 1) {
                std::vector<std::pair<u64, size_t>> nx;
                for (size_t i = 0; i + 1 < lvl.size(); i += 2) nx.push_back({m.combine(lvl[i].first, lvl[i + 1].first, lvl[i + 1].second), lvl[i].second + lvl[i + 1].second});
                if (lvl.size() % 2) nx.push_back(lvl.back());
                lvl = nx;
            }
            CHECK(left == want && right == want && lvl[0].first == want, "%s pieces trial %d (k=%zu)", m.name, trial, k);
            ++pcount;
        }
    }
    printf("composition: %zu pairs (a, b), %zu many-piece joins (left, right, tree)\n", ccount, pcount);
}

// v3 against the Python reference (hv3/ref.py): prints the hashes of fixed Strings.
static void printV3Vectors() {
    for (size_t n : {1, 5, 8, 9, 31, 32, 33, 100, 2016, 4099}) {
        for (int k = 0; k < 2; ++k) {
            std::vector<u16> v(n);
            for (size_t i = 0; i < n; ++i) v[i] = k == 0 ? static_cast<u16>(0x20 + (i * 7 + n) % 0x5F) : static_cast<u16>(0x4E00 + (i * 13 + n) % 3000);
            printf("v3 %d %zu %u\n", k, n, v3::hash(v.data(), n));
        }
    }
}

// Collisions of the 32-bit hash on structured key sets, and the spread of the two lowest 5-bit
// groups (a SeqDict's first two HAMT levels): chi-square over 32 buckets, 31 degrees of freedom.
struct Family { const char* name; std::vector<std::vector<u16>> keys; };
static std::vector<Family> buildFamilies() {
    const size_t N = 1u << 20;
    std::vector<Family> fams;
    {
        Family f{"prefix 500 + 6 digits", {}};
        std::vector<u16> pre(500);
        for (size_t i = 0; i < 500; ++i) pre[i] = static_cast<u16>('a' + i % 26);
        for (size_t i = 0; i < N; ++i) {
            auto k = pre;
            char d[16];
            snprintf(d, sizeof d, "%06zu", i);
            for (char* c = d; *c; ++c) k.push_back(static_cast<u16>(*c));
            f.keys.push_back(std::move(k));
        }
        fams.push_back(std::move(f));
    }
    {
        Family f{"String.fromInt 0..2^20", {}};
        for (size_t i = 0; i < N; ++i) {
            char d[16];
            snprintf(d, sizeof d, "%zu", i);
            std::vector<u16> k;
            for (char* c = d; *c; ++c) k.push_back(static_cast<u16>(*c));
            f.keys.push_back(std::move(k));
        }
        fams.push_back(std::move(f));
    }
    {
        Family f{"64 zeros, two units set", {}};
        std::mt19937_64 rng(7);
        for (size_t i = 0; i < N; ++i) {
            std::vector<u16> k(64, 0);
            size_t a = rng() % 64, b = rng() % 64;
            k[a] = static_cast<u16>(1 + rng() % 255);
            k[b] ^= static_cast<u16>(1 + rng() % 255);
            f.keys.push_back(std::move(k));
        }
        // distinct keys only
        std::sort(f.keys.begin(), f.keys.end());
        f.keys.erase(std::unique(f.keys.begin(), f.keys.end()), f.keys.end());
        fams.push_back(std::move(f));
    }
    {
        Family f{"random 32 units", {}};
        std::mt19937_64 rng(8);
        for (size_t i = 0; i < N; ++i) f.keys.push_back(randomUnits(rng, 32, true));
        fams.push_back(std::move(f));
    }
    return fams;
}
static void testQuality() {
    std::vector<Family> fams = buildFamilies();
    printf("\n## Quality: 32-bit hash collisions (expected for random hashes in brackets) and chi-square of 5-bit groups 0 and 1 (31 dof: 95%% < 45)\n");
    printf("%-26s", "method");
    for (auto& f : fams) printf(" | %-27s", f.name);
    printf("\n");
    for (auto& m : methods) {
        if (!strcmp(m.name, "read-floor") || !strcmp(m.name, "v3-masked") || !strcmp(m.name, "crc32c-1") || !strcmp(m.name, "crc32c-3") || !strcmp(m.name, "crc32c-foldonly") || !strcmp(m.name, "poly61-scalar") || !strcmp(m.name, "poly61-avx2")) continue;
        printf("%-26s", m.name);
        for (auto& f : fams) {
            std::vector<u32> hs;
            hs.reserve(f.keys.size());
            for (auto& k : f.keys) hs.push_back(m.hash(k.data(), k.size()));
            double chi[2];
            for (int g = 0; g < 2; ++g) {
                double cnt[32] = {0};
                for (u32 h : hs) cnt[(h >> (5 * g)) & 31] += 1;
                double e = hs.size() / 32.0, c = 0;
                for (double x : cnt) c += (x - e) * (x - e) / e;
                chi[g] = c;
            }
            std::sort(hs.begin(), hs.end());
            size_t col = 0;
            for (size_t i = 1; i < hs.size(); ++i) col += hs[i] == hs[i - 1];
            double n = static_cast<double>(hs.size());
            printf(" | %5zu [%4.0f] chi %5.0f %5.0f", col, n * (n - 1) / 2 / 4294967296.0, chi[0], chi[1]);
        }
        printf("\n");
    }
}

// ============================================================================ SMHasher-style tests
// One implementation per family: the others give identical values.
static std::vector<const Method*> deepMethods() {
    static const char* const names[] = {"v3", "crc32c-fold128", "rabin64-fold128", "poly61-avx2", "poly52-ifma", "control:raw-crc"};
    std::vector<const Method*> r;
    for (const char* nm : names)
        for (auto& m : methods)
            if (!strcmp(m.name, nm)) r.push_back(&m);
    return r;
}

// 1. Avalanche. For S random keys of n units, every one of the 16n input bits is flipped in turn, and
// each output bit's flip rate p is counted per (input bit, output bit) cell; a perfect hash has p = 1/2.
// Bias = |2p - 1|. With S samples a perfect hash's cells have standard deviation 1/sqrt(S): its expected
// worst over M cells is about sqrt(2 ln M / S) and its expected mean sqrt(2 / (pi S)). Both are printed
// with the ratios; a ratio well above 1 is a real bias, not sampling noise.
static void testAvalanche() {
    printf("\n## Avalanche: bias |2p-1| over (input bit, output bit) cells, worst and mean, against a perfect hash's expected values\n");
    printf("%-16s %6s %8s %9s %9s %6s %9s %9s %6s\n", "method", "units", "samples", "worst", "perfect", "ratio", "mean", "perfect", "ratio");
    std::mt19937_64 rng(11);
    for (const Method* m : deepMethods()) {
        for (size_t n : {4, 8, 31, 64, 256}) {
            const size_t bits = 16 * n, S = std::max<size_t>(10000, 60000000 / bits);
            std::vector<u32> cnt(bits * 32, 0);
            std::vector<u16> k(n);
            for (size_t s = 0; s < S; ++s) {
                for (auto& u : k) u = static_cast<u16>(rng());
                const u32 h0 = m->hash(k.data(), n);
                for (size_t i = 0; i < bits; ++i) {
                    k[i >> 4] ^= static_cast<u16>(1u << (i & 15));
                    const u32 d = m->hash(k.data(), n) ^ h0;
                    k[i >> 4] ^= static_cast<u16>(1u << (i & 15));
                    u32* c = &cnt[i * 32];
                    for (int j = 0; j < 32; ++j) c[j] += (d >> j) & 1;
                }
            }
            double worst = 0, sum = 0;
            size_t wi = 0, wj = 0;
            for (size_t i = 0; i < bits; ++i)
                for (size_t j = 0; j < 32; ++j) {
                    const double b = std::fabs(2.0 * cnt[i * 32 + j] / S - 1.0);
                    sum += b;
                    if (b > worst) { worst = b; wi = i; wj = j; }
                }
            const double M = bits * 32.0, sd = 1 / std::sqrt(static_cast<double>(S));
            const double pw = sd * std::sqrt(2 * std::log(M)), pm = sd * std::sqrt(2 / M_PI);
            printf("%-16s %6zu %8zu %8.3f%% %8.3f%% %6.2f %8.4f%% %8.4f%% %6.2f   worst cell: input bit %zu (unit %zu) -> output bit %zu\n",
                   m->name, n, S, 100 * worst, 100 * pw, worst / pw, 100 * sum / M, 100 * pm, (sum / M) / pm, wi, wi / 16, wj);
            fflush(stdout);
        }
    }
}

// 2. Every window. Each w-bit window of the 32-bit hash (w = 5, 8 and 12 at every bit offset, and the top
// 2-bit group SeqDict's seventh level reads) bucketed over a key family: chi-square with 2^w - 1 degrees
// of freedom, as z = (chi2 - dof) / sqrt(2 dof). For a perfect hash the worst |z| of these 75 windows is
// typically 2-3.5.
static void testWindows() {
    std::vector<Family> fams = buildFamilies();
    std::vector<std::pair<int, int>> wins;  // (width, offset)
    for (int w : {5, 8, 12})
        for (int o = 0; o + w <= 32; ++o) wins.push_back({w, o});
    wins.push_back({2, 30});
    printf("\n## Every window: worst |z| over %zu windows (w-bit window at offset o shown as w@o), and windows with |z| > 4\n", wins.size());
    printf("%-16s", "method");
    for (auto& f : fams) printf(" | %-26s", f.name);
    printf("\n");
    for (const Method* m : deepMethods()) {
        printf("%-16s", m->name);
        for (auto& f : fams) {
            std::vector<u32> hs;
            hs.reserve(f.keys.size());
            for (auto& k : f.keys) hs.push_back(m->hash(k.data(), k.size()));
            double worst = 0;
            int ww = 0, wo = 0, over = 0;
            std::vector<double> cnt;
            for (auto [w, o] : wins) {
                cnt.assign(size_t(1) << w, 0);
                for (u32 h : hs) cnt[(h >> o) & ((1u << w) - 1)] += 1;
                const double e = static_cast<double>(hs.size()) / cnt.size(), dof = cnt.size() - 1.0;
                double c = 0;
                for (double x : cnt) c += (x - e) * (x - e) / e;
                const double z = (c - dof) / std::sqrt(2 * dof);
                over += std::fabs(z) > 4;
                if (std::fabs(z) > std::fabs(worst)) { worst = z; ww = w; wo = o; }
            }
            char wbuf[16];
            snprintf(wbuf, sizeof wbuf, "%d@%d", ww, wo);
            printf(" | z %6.2f at %-6s >4: %2d", worst, wbuf, over);
        }
        printf("\n");
        fflush(stdout);
    }
}

// 3. Differentials: H(k) == H(k with difference d) for many keys k. Sparse XOR differences (every 1- and
// 2-bit d, and every 3-bit d in the first 64 bits) over random keys, where a perfect hash collides about
// tests / 2^32 times; then one difference per design, built from its structure, that should collide for
// every key in that design and almost never in the others.
static std::map<std::string, std::vector<int64_t>> readLll(const char* path) {
    std::map<std::string, std::vector<int64_t>> r;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream ss(line);
        std::string name;
        ss >> name;
        int64_t v;
        while (ss >> v) r[name].push_back(v);
    }
    return r;
}
static void flipDegree(std::vector<u16>& k, size_t e) {  // flips the stream bit of degree e
    const size_t t = 16 * k.size() - 1 - e;             // stream bit: byte t/8, bit t%8 (least first)
    reinterpret_cast<u8*>(k.data())[t / 8] ^= static_cast<u8>(1u << (t % 8));
}
static void testDifferential(const char* lllPath) {
    auto lll = readLll(lllPath);
    std::mt19937_64 rng(13);
    printf("\n## Differentials: collisions / tests (a perfect 32-bit hash: tests / 2^32, i.e. 0 here)\n");
    printf("%-16s %16s %16s %16s %14s %14s %14s %14s %14s\n", "method", "1-bit", "2-bit", "3-bit (64 bits)", "CRC32C P", "Rabin P", "v3 K-block", "poly61 LLL", "poly52 LLL");
    for (const Method* m : deepMethods()) {
        printf("%-16s", m->name);
        // Sparse XOR differences on keys of 8, 32 and 64 units, 16 random keys each.
        size_t col[3] = {0, 0, 0}, tst[3] = {0, 0, 0};
        for (size_t n : {8, 32, 64}) {
            const size_t bits = 16 * n, b2 = std::min<size_t>(bits, 256);
            std::vector<std::vector<u16>> keys;
            std::vector<u32> h0;
            for (int i = 0; i < 16; ++i) { keys.push_back(randomUnits(rng, n, false)); h0.push_back(m->hash(keys.back().data(), n)); }
            auto flip = [](std::vector<u16>& k, size_t i) { k[i >> 4] ^= static_cast<u16>(1u << (i & 15)); };
            for (size_t q = 0; q < keys.size(); ++q) {
                auto& k = keys[q];
                for (size_t a = 0; a < bits; ++a) {
                    flip(k, a);
                    col[0] += m->hash(k.data(), n) == h0[q];
                    ++tst[0];
                    if (a < b2)
                        for (size_t b = a + 1; b < b2; ++b) {
                            flip(k, b);
                            col[1] += m->hash(k.data(), n) == h0[q];
                            ++tst[1];
                            if (b < 64)
                                for (size_t c = b + 1; c < 64; ++c) {
                                    flip(k, c);
                                    col[2] += m->hash(k.data(), n) == h0[q];
                                    ++tst[2];
                                    flip(k, c);
                                }
                            flip(k, b);
                        }
                    flip(k, a);
                }
            }
        }
        for (int i = 0; i < 3; ++i) printf(" %8zu/%-7zu", col[i], tst[i]);
        const int T = 1000;
        // CRC32C: d = P(x) x^s at a random degree s, keys of 64 units (1024 bits).
        {
            int c = 0;
            for (int t = 0; t < T; ++t) {
                auto k = randomUnits(rng, 64, false), k2 = k;
                const size_t sft = rng() % (1024 - 33);
                flipDegree(k2, sft + 32);
                for (int i = 0; i < 32; ++i)
                    if ((crc::POLY >> i) & 1) flipDegree(k2, sft + 31 - i);  // reflected bit i is x^(31-i)
                c += m->hash(k.data(), 64) == m->hash(k2.data(), 64);
            }
            printf(" %8d/%-5d", c, T);
        }
        // Rabin: d = P(x) x^s with its degree-64 P.
        {
            int c = 0;
            for (int t = 0; t < T; ++t) {
                auto k = randomUnits(rng, 64, false), k2 = k;
                const size_t sft = rng() % (1024 - 65);
                flipDegree(k2, sft + 64);
                for (int i = 0; i < 64; ++i)
                    if ((rabin::Pl >> i) & 1) flipDegree(k2, sft + i);
                c += m->hash(k.data(), 64) == m->hash(k2.data(), 64);
            }
            printf(" %8d/%-5d", c, T);
        }
        // v3: different first 32 units, then a 32-unit block whose four even words equal K, then a shared
        // tail; all compared with the first such key.
        {
            int c = 0;
            std::vector<u16> blk(32), tail(40);
            for (int j = 0; j < 4; ++j)
                for (int u = 0; u < 4; ++u) {
                    blk[8 * j + u] = static_cast<u16>(v3::K >> (16 * u));
                    blk[8 * j + 4 + u] = static_cast<u16>(rng());
                }
            for (auto& u : tail) u = static_cast<u16>(rng());
            auto mk = [&]() {
                auto k = randomUnits(rng, 32, false);
                k.insert(k.end(), blk.begin(), blk.end());
                k.insert(k.end(), tail.begin(), tail.end());
                return k;
            };
            auto k0 = mk();
            const u32 h0 = m->hash(k0.data(), k0.size());
            for (int t = 0; t < T; ++t) {
                auto k = mk();
                c += m->hash(k.data(), k.size()) == h0;
            }
            printf(" %8d/%-5d", c, T);
        }
        // Polynomials: an additive difference d (found by lattice reduction, lll.py) with
        // sum d_j B^(m-1-j) = 0 mod p, added at a random offset into keys whose units leave room for it.
        for (const char* nm : {"poly61", "poly52"}) {
            auto it = lll.find(nm);
            if (it == lll.end()) { printf(" %14s", "-"); continue; }
            const auto& d = it->second;
            int64_t D = 0;
            for (auto v : d) D = std::max<int64_t>(D, std::llabs(v));
            int c = 0;
            for (int t = 0; t < T; ++t) {
                std::vector<u16> k(64);
                for (auto& u : k) u = static_cast<u16>(D + rng() % (65536 - 2 * D));
                auto k2 = k;
                const size_t o = rng() % (64 - d.size() + 1);
                for (size_t j = 0; j < d.size(); ++j) k2[o + j] = static_cast<u16>(k2[o + j] + d[j]);
                c += m->hash(k.data(), 64) == m->hash(k2.data(), 64);
            }
            printf(" %8d/%-5d", c, T);
        }
        printf("\n");
        fflush(stdout);
    }
}

static INLINE u64 opaqueZero(u64 dep) {
    asm volatile("and $0, %0" : "+r"(dep));  // a real data dependency the compiler cannot see through
    return dep;
}
template <class F>
static double timeLatency(F f, size_t work) {
    // ns per call, calls chained through their results, best of 7 trials.
    size_t iters = std::max<size_t>(300, 40000000 / (work + 32));
    double best = 1e30;
    for (int t = 0; t < 7; ++t) {
        u64 dep = 0;
        auto t0 = std::chrono::steady_clock::now();
        for (size_t i = 0; i < iters; ++i) dep = f(opaqueZero(dep));
        auto t1 = std::chrono::steady_clock::now();
        asm volatile("" ::"r"(dep));
        best = std::min(best, std::chrono::duration<double, std::nano>(t1 - t0).count() / iters);
    }
    return best;
}

static void timeAll() {
    std::mt19937_64 rng(3);
    const size_t MAXN = (1u << 20) + 8;
    std::vector<u16> buf = randomUnits(rng, MAXN + 64, true);
    u16* base = reinterpret_cast<u16*>((reinterpret_cast<uintptr_t>(buf.data()) + 63) & ~uintptr_t(63));
    std::vector<size_t> lens = {1, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257,
                                500, 512, 1000, 1024, 2016, 2048, 2049, 4096, 4099, 16384, 65536, 65539, 1u << 20};
    printf("\n## Time: ns per hash (raw + finish), calls chained, best of 7; String 64-byte aligned\n");
    printf("%8s", "units");
    for (auto& m : methods) printf(" %12s", m.name);
    printf("\n");
    for (size_t n : lens) {
        printf("%8zu", n);
        for (auto& m : methods) {
            auto h = m.hash;
            double ns = timeLatency([&](u64 z) { return static_cast<u64>(h(base + z, n)); }, n);
            printf(" %12.2f", ns);
        }
        printf("\n");
        fflush(stdout);
    }
    printf("\n## Time, String starting 1 unit (2 bytes) past a 64-byte boundary\n");
    for (size_t n : {33, 257, 2016, 65536}) {
        printf("%8zu", n);
        for (auto& m : methods) {
            auto h = m.hash;
            printf(" %12.2f", timeLatency([&](u64 z) { return static_cast<u64>(h(base + 1 + z, n)); }, n));
        }
        printf("\n");
    }
    printf("\n## Units per ns at 2016, 65536 and 2^20 units\n");
    for (size_t n : {2016, 65536, 1048576}) {
        printf("%8zu", n);
        for (auto& m : methods) {
            auto h = m.hash;
            printf(" %12.1f", n / timeLatency([&](u64 z) { return static_cast<u64>(h(base + z, n)); }, n));
        }
        printf("\n");
    }
    printf("\n## combine(raw a, raw b, |b|): ns per call, chained\n%8s", "|b|");
    for (auto& m : methods) if (m.raw) printf(" %12s", m.name);
    printf("\n");
    for (size_t nb : {1, 7, 32, 100, 1000, 2016, 4099, 65536, 1048576}) {
        printf("%8zu", nb);
        for (auto& m : methods) {
            if (!m.raw) continue;
            auto c = m.combine;
            u64 rb = m.raw(base, 50);
            u64 ra = m.raw(base + 100, 70);
            printf(" %12.2f", timeLatency([&](u64 z) { ra = c(ra ^ z, rb, nb); return ra; }, 1));
        }
        printf("\n");
    }
}

int main(int argc, char** argv) {
    crc::init();
    rabin::init();
    p61::init();
#ifdef __AVX512F__
    p52::init();
#endif
    methods = {
        {"v3", v3::hash, nullptr, nullptr, nullptr, nullptr},
#ifdef __AVX512F__
        {"v3-masked", v3::hashMasked, nullptr, nullptr, nullptr, nullptr},
#endif
        {"v3-avx2tail", v3::hashAvx2Tail, nullptr, nullptr, nullptr, nullptr},
        {"crc32c-1", crc::hash1, crc::raw1, crc::rawRef, crc::combine, crc::combineRef},
        {"crc32c-3", crc::hash3, crc::raw3, crc::rawRef, crc::combine, crc::combineRef},
        {"crc32c-fold128", crc::hashFold128, crc::rawFold128, crc::rawRef, crc::combine, crc::combineRef},
        {"crc32c-fold256", crc::hashFold256, crc::rawFold256, crc::rawRef, crc::combine, crc::combineRef},
#ifdef __AVX512F__
        {"crc32c-fold", crc::hashFold, crc::rawFold, crc::rawRef, crc::combine, crc::combineRef},
        {"crc32c-foldonly", crc::hashFoldOnly, crc::rawFoldOnly, crc::rawRef, crc::combine, crc::combineRef},
        {"rabin64", rabin::hash, rabin::raw, rabin::rawRef, rabin::combine, rabin::combineRef},
#endif
        {"rabin64-fold128", rabin::hash128, rabin::raw128, rabin::rawRef, rabin::combine, rabin::combineRef},
        {"poly61-scalar", p61::hashScalar, p61::rawScalar, p61::rawRef, p61::combine, p61::combineRef},
        {"poly61-avx2", p61::hashAvx2, p61::rawAvx2, p61::rawRef, p61::combine, p61::combineRef},
#ifdef __AVX512F__
        {"poly61-avx512", p61::hashAvx512, p61::rawAvx512, p61::rawRef, p61::combine, p61::combineRef},
        {"poly52-ifma", p52::hash, p52::raw, p52::rawRef, p52::combine, p52::combineRef},
        {"read-floor", readFloor, nullptr, nullptr, nullptr, nullptr},
#endif
        {"read-floor-avx2", readFloor2, nullptr, nullptr, nullptr, nullptr},
        {"control:raw-crc", crc::hashRawControl, nullptr, nullptr, nullptr, nullptr},
    };
    std::string mode = argc > 1 ? argv[1] : "all";
    printf("rabin64 P = x^64 + %#llx\n", (unsigned long long)rabin::Pl);
    if (mode == "v3vec") { printV3Vectors(); return 0; }
    if (mode == "params") {
        printf("poly61 %llu %llu\n", (unsigned long long)p61::P, (unsigned long long)p61::B);
#ifdef __AVX512F__
        printf("poly52 %llu %llu\n", (unsigned long long)p52::P, (unsigned long long)p52::B);
#endif
        return 0;
    }
    if (mode == "avalanche") { testAvalanche(); return 0; }
    if (mode == "windows") { testWindows(); return 0; }
    if (mode == "diff") { testDifferential(argc > 2 ? argv[2] : "lll.txt"); return 0; }
    if (mode == "all" || mode == "test") testCorrectness();
    if (failures) { printf("FAILURES: %d\n", failures); return 1; }
    if (mode == "all" || mode == "quality") testQuality();
    if (mode == "all" || mode == "time") timeAll();
    return 0;
}
