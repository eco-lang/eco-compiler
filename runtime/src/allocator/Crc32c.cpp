//===- Crc32c.cpp - CRC32C over String units, with composition --------------===//
//
// See Crc32c.hpp. The hardware paths are experiments/string-hash-lab's crc32c-fold128: 16-byte
// PCLMULQDQ folding with four accumulators from 128 stream bytes (64 units), three interleaved crc32
// streams joined by carry-less multiplies below that. A polynomial here is "reflected": bit i of a 32-bit
// word is the coefficient of x^(31-i), so 1 is 1 << 31 and x is 1 << 30.
//
//===----------------------------------------------------------------------===//

#include "Crc32c.hpp"

#include <cstring>

#if (defined(__x86_64__) || defined(_M_X64)) && (defined(__GNUC__) || defined(__clang__))
#define ECO_CRC32C_X86 1
#include <cpuid.h>
#include <immintrin.h>
#endif

namespace Elm::crc32c {
namespace {

constexpr uint32_t kPoly = 0x82F63B78u;
constexpr uint32_t kOne = 1u << 31;
constexpr uint32_t kX = 1u << 30;

// a * b mod P (zlib's multmodp).
uint32_t mulmod(uint32_t a, uint32_t b) {
    if (a == 0) return 0;
    uint32_t m = kOne, r = 0;
    for (;;) {
        if (a & m) {
            r ^= b;
            if ((a & (m - 1)) == 0) break;
        }
        m >>= 1;
        b = (b & 1) ? (b >> 1) ^ kPoly : b >> 1;
    }
    return r;
}

// x^e mod P.
uint32_t powx(uint64_t e) {
    uint32_t r = kOne, base = kX;
    while (e) {
        if (e & 1) r = mulmod(r, base);
        base = mulmod(base, base);
        e >>= 1;
    }
    return r;
}

// Four bytes, each widened to a 16-bit unit: the word four units of the same values make.
inline uint64_t widen4(uint32_t bytes) {
    uint64_t v = bytes;
    v = (v | (v << 16)) & 0x0000FFFF0000FFFFull;
    v = (v | (v << 8)) & 0x00FF00FF00FF00FFull;
    return v;
}

// Slicing-by-8 tables, and x^(2^k) for the portable combine.
struct Portable {
    uint32_t t[8][256];
    uint32_t x2k[64];
    Portable() {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (kPoly & (0u - (c & 1)));
            t[0][i] = c;
        }
        for (uint32_t i = 0; i < 256; ++i)
            for (int k = 1; k < 8; ++k) t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xFF];
        x2k[0] = kX;
        for (int k = 1; k < 64; ++k) x2k[k] = mulmod(x2k[k - 1], x2k[k - 1]);
    }
};
const Portable& portable() {
    static const Portable p;
    return p;
}

// One slicing-by-8 step: the register `c` over the 8 stream bytes of `w` (little-endian).
inline uint32_t step8(const Portable& P, uint32_t c, uint64_t w) {
    w ^= c;
    return P.t[7][w & 0xFF] ^ P.t[6][(w >> 8) & 0xFF] ^ P.t[5][(w >> 16) & 0xFF] ^
           P.t[4][(w >> 24) & 0xFF] ^ P.t[3][(w >> 32) & 0xFF] ^ P.t[2][(w >> 40) & 0xFF] ^
           P.t[1][(w >> 48) & 0xFF] ^ P.t[0][w >> 56];
}
inline uint32_t step1(const Portable& P, uint32_t c, uint8_t b) { return P.t[0][(c ^ b) & 0xFF] ^ (c >> 8); }

#ifdef ECO_CRC32C_X86

#define ECO_HW __attribute__((target("sse4.2,pclmul")))

// Constants of the hardware paths. M(a, b) = a * b * x^33 (one carry-less multiply, reduced by the
// crc32 instruction); with hat(v) = v * x^-33, M(c, hat(v)) = c * v. Folding a 16-byte chunk forward by
// D bits multiplies its first and second halves by x^(D+31) and x^(D-33).
struct Hw {
    bool ok = false;
    uint32_t hatPow[64];      // hat(x^(2^k))
    uint32_t k3a = 0, k3b = 0; // hat(x^512), hat(x^256): the 3-stream join of 32-byte blocks
    uint64_t f512[2] = {0, 0}, f128[2] = {0, 0};
};

Hw makeHw() {
    Hw h;
    unsigned a = 0, b = 0, c = 0, d = 0;
    if (!__get_cpuid(1, &a, &b, &c, &d)) return h;
    if (!(c & bit_SSE4_2) || !(c & bit_PCLMUL)) return h;
    const uint32_t xinv = (kPoly << 1) | 1u; // x^-1: x * xinv = P + 1 = 1 mod P
    uint32_t xneg33 = kOne;
    for (int i = 0; i < 33; ++i) xneg33 = mulmod(xneg33, xinv);
    auto hat = [&](uint32_t v) { return mulmod(v, xneg33); };
    for (int k = 0; k < 64; ++k) h.hatPow[k] = hat(powx(1ull << k));
    h.k3a = hat(powx(512));
    h.k3b = hat(powx(256));
    h.f512[0] = powx(512 + 31);
    h.f512[1] = powx(512 - 33);
    h.f128[0] = powx(128 + 31);
    h.f128[1] = powx(128 - 33);
    h.ok = true;
    return h;
}
const Hw* hw() {
    static const Hw h = makeHw();
    return h.ok ? &h : nullptr;
}

ECO_HW inline uint32_t M(uint32_t a, uint32_t b) {
    const __m128i r = _mm_clmulepi64_si128(_mm_cvtsi32_si128(static_cast<int>(a)),
                                           _mm_cvtsi32_si128(static_cast<int>(b)), 0);
    return static_cast<uint32_t>(_mm_crc32_u64(0, static_cast<uint64_t>(_mm_cvtsi128_si64(r))));
}

// c * x^bits.
ECO_HW uint32_t shiftHw(const Hw& h, uint32_t c, uint64_t bits) {
    if (!bits) return c;
    uint32_t k = h.hatPow[__builtin_ctzll(bits)];
    bits &= bits - 1;
    while (bits) {
        k = M(k, h.hatPow[__builtin_ctzll(bits)]);
        bits &= bits - 1;
    }
    return M(c, k);
}

// The byte stream of a UTF-16 run, as it is in memory.
struct Units16 {
    const uint8_t* b;
    ECO_HW uint64_t ld8(size_t o) const {
        uint64_t w;
        std::memcpy(&w, b + o, 8);
        return w;
    }
    ECO_HW __m128i ld16(size_t o) const { return _mm_loadu_si128(reinterpret_cast<const __m128i*>(b + o)); }
    // The stream bytes [o, L), fewer than 8.
    ECO_HW uint64_t tail(uint64_t c, size_t o, size_t L) const {
        if (L - o >= 4) {
            uint32_t w;
            std::memcpy(&w, b + o, 4);
            c = _mm_crc32_u32(static_cast<uint32_t>(c), w);
            o += 4;
        }
        if (L - o >= 2) {
            uint16_t w;
            std::memcpy(&w, b + o, 2);
            c = _mm_crc32_u16(static_cast<uint32_t>(c), w);
        }
        return c;
    }
};

// The byte stream of a UTF-8 run widened to units: run byte i is stream bytes 2i and 2i + 1.
struct Units8 {
    const uint8_t* b;
    ECO_HW uint64_t ld8(size_t o) const {
        uint32_t w;
        std::memcpy(&w, b + o / 2, 4);
        return widen4(w);
    }
    ECO_HW __m128i ld16(size_t o) const {
        return _mm_cvtepu8_epi16(_mm_loadl_epi64(reinterpret_cast<const __m128i*>(b + o / 2)));
    }
    ECO_HW uint64_t tail(uint64_t c, size_t o, size_t L) const {
        for (; o < L; o += 2) c = _mm_crc32_u16(static_cast<uint32_t>(c), b[o / 2]);
        return c;
    }
};

ECO_HW inline __m128i fold(__m128i a, __m128i k, __m128i data) {
    return _mm_xor_si128(_mm_xor_si128(_mm_clmulepi64_si128(a, k, 0x00), _mm_clmulepi64_si128(a, k, 0x11)), data);
}

// The register `state` over the `L` stream bytes of `s`.
template <class S>
ECO_HW uint32_t runHw(const Hw& h, const S& s, uint32_t state, size_t L) {
    uint64_t c;
    size_t o;
    if (L >= 128) {
        // Fold whole 16-byte chunks; `state` enters as an xor into the first four stream bytes.
        const size_t N = L & ~size_t(15);
        const __m128i k512 = _mm_set_epi64x(static_cast<long long>(h.f512[1]), static_cast<long long>(h.f512[0]));
        const __m128i k128 = _mm_set_epi64x(static_cast<long long>(h.f128[1]), static_cast<long long>(h.f128[0]));
        __m128i x0 = _mm_xor_si128(s.ld16(0), _mm_cvtsi32_si128(static_cast<int>(state)));
        __m128i x1 = s.ld16(16), x2 = s.ld16(32), x3 = s.ld16(48);
        size_t pos = 64;
        for (; pos + 64 <= N; pos += 64) {
            x0 = fold(x0, k512, s.ld16(pos));
            x1 = fold(x1, k512, s.ld16(pos + 16));
            x2 = fold(x2, k512, s.ld16(pos + 32));
            x3 = fold(x3, k512, s.ld16(pos + 48));
        }
        x1 = fold(x0, k128, x1);
        x2 = fold(x1, k128, x2);
        x0 = fold(x2, k128, x3);
        for (; pos + 16 <= N; pos += 16) x0 = fold(x0, k128, s.ld16(pos));
        c = _mm_crc32_u64(0, static_cast<uint64_t>(_mm_cvtsi128_si64(x0)));
        c = _mm_crc32_u64(c, static_cast<uint64_t>(_mm_extract_epi64(x0, 1)));
        o = N;
    } else {
        // Three streams over 32-byte blocks, joined as c0 * x^512 ^ c1 * x^256 ^ c2.
        c = state;
        o = 0;
        while (L - o >= 96) {
            uint64_t c1 = 0, c2 = 0;
            for (size_t i = 0; i < 32; i += 8) {
                c = _mm_crc32_u64(c, s.ld8(o + i));
                c1 = _mm_crc32_u64(c1, s.ld8(o + 32 + i));
                c2 = _mm_crc32_u64(c2, s.ld8(o + 64 + i));
            }
            c = M(static_cast<uint32_t>(c), h.k3a) ^ M(static_cast<uint32_t>(c1), h.k3b) ^ c2;
            o += 96;
        }
    }
    for (; o + 8 <= L; o += 8) c = _mm_crc32_u64(c, s.ld8(o));
    return static_cast<uint32_t>(s.tail(c, o, L));
}

#endif // ECO_CRC32C_X86

} // namespace

uint32_t update16Portable(uint32_t c, const uint16_t* units, size_t n) {
    const Portable& P = portable();
    const uint8_t* p = reinterpret_cast<const uint8_t*>(units); // little-endian hosts only
    size_t L = 2 * n;
    for (; L >= 8; p += 8, L -= 8) {
        uint64_t w;
        std::memcpy(&w, p, 8);
        c = step8(P, c, w);
    }
    for (; L; --L) c = step1(P, c, *p++);
    return c;
}

uint32_t update8Portable(uint32_t c, const uint8_t* bytes, size_t n) {
    const Portable& P = portable();
    for (; n >= 4; bytes += 4, n -= 4) {
        uint32_t w;
        std::memcpy(&w, bytes, 4);
        c = step8(P, c, widen4(w));
    }
    for (; n; --n) c = step1(P, step1(P, c, *bytes++), 0);
    return c;
}

uint32_t combinePortable(uint32_t a, uint32_t b, uint64_t nb) {
    const Portable& P = portable();
    uint32_t r = a ^ kEmpty;
    uint64_t bits = 16 * nb;
    for (int k = 0; bits; ++k, bits >>= 1)
        if (bits & 1) r = mulmod(r, P.x2k[k]);
    return r ^ b;
}

uint32_t update16(uint32_t state, const uint16_t* units, size_t n) {
    if (n == 0) return state;
#ifdef ECO_CRC32C_X86
    if (const Hw* h = hw()) return runHw(*h, Units16{reinterpret_cast<const uint8_t*>(units)}, state, 2 * n);
#endif
    return update16Portable(state, units, n);
}

uint32_t update8(uint32_t state, const uint8_t* bytes, size_t n) {
    if (n == 0) return state;
#ifdef ECO_CRC32C_X86
    if (const Hw* h = hw()) return runHw(*h, Units8{bytes}, state, 2 * n);
#endif
    return update8Portable(state, bytes, n);
}

uint32_t combine(uint32_t a, uint32_t b, uint64_t nb) {
#ifdef ECO_CRC32C_X86
    if (const Hw* h = hw()) return shiftHw(*h, a ^ kEmpty, 16 * nb) ^ b;
#endif
    return combinePortable(a, b, nb);
}

bool hardware() {
#ifdef ECO_CRC32C_X86
    return hw() != nullptr;
#else
    return false;
#endif
}

} // namespace Elm::crc32c
