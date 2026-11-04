//===- Hash.cpp - Native string hashing ----------------------------------===//

#include "Hash.hpp"

#include "allocator/StringOps.hpp"

namespace Eco {
namespace Kernel {
namespace Hash {

namespace {

/// The modulus of the narrow hash, 2^26. It must equal the Elm side's
/// `Monomorphized.hashBase`.
constexpr int64_t kBase = 67108864;

/// Returns one step of the narrow hash: `(h * 33 + (x mod 2^26) + 7) mod 2^26`.
///
/// With |h| < 2^26 every intermediate is below 2^32 in magnitude, far inside
/// i64.
inline int64_t mix(int64_t h, int64_t x) {
    return (h * 33 + (x % kBase) + 7) % kBase;
}

} // namespace

int64_t stringWithSeed(void* str, int64_t seed) {
    int64_t h = seed % kBase;
    if (!str) {
        return h;
    }

    if (Elm::StringOps::isUtf8(str)) {
        // A UTF-8 form holds only ASCII, so each byte is one code unit.
        auto pr = Elm::StringOps::utf8Bytes(str);
        const Elm::u8* p = pr.first;
        for (Elm::u32 i = 0; i < pr.second; ++i) {
            h = mix(h, static_cast<int64_t>(p[i]));
        }
        return h;
    }

    // Every other form is read a unit at a time through charAt, which does
    // not allocate; on a rope each call descends from the root.
    const Elm::i64 n = Elm::StringOps::length(str);
    for (Elm::i64 i = 0; i < n; ++i) {
        h = mix(h, static_cast<int64_t>(Elm::StringOps::charAt(str, i)));
    }
    return h;
}

int64_t string64(void* str, int64_t seed) {
    // Unsigned throughout because signed overflow is undefined; the final
    // conversion to int64_t keeps the bit pattern.
    uint64_t h = 1469598103934665603ULL ^ static_cast<uint64_t>(seed);

    auto step = [&h](uint64_t c) {
        h ^= c;
        h *= 1099511628211ULL;
    };

    if (!str) {
        return static_cast<int64_t>(h);
    }

    if (Elm::StringOps::isUtf8(str)) {
        auto pr = Elm::StringOps::utf8Bytes(str);
        const Elm::u8* p = pr.first;
        for (Elm::u32 i = 0; i < pr.second; ++i) {
            step(p[i]);
        }
        return static_cast<int64_t>(h);
    }

    const Elm::i64 n = Elm::StringOps::length(str);
    for (Elm::i64 i = 0; i < n; ++i) {
        step(Elm::StringOps::charAt(str, i));
    }
    return static_cast<int64_t>(h);
}

} // namespace Hash
} // namespace Kernel
} // namespace Eco
