//===- Hash.cpp - Native string hashing ----------------------------------===//

#include "Hash.hpp"

#include "allocator/StringOps.hpp"

namespace Eco {
namespace Kernel {
namespace Hash {

namespace {

constexpr int64_t kBase = 67108864; // 2^26, == Monomorphized.hashBase

inline int64_t mix(int64_t h, int64_t x) {
    // Mirrors Elm's `modBy 67108864 (h * 33 + modBy 67108864 x + 7)`.
    // Every intermediate stays far inside i64: h < 2^26, so h * 33 < 2^31.
    return (h * 33 + (x % kBase) + 7) % kBase;
}

} // namespace

int64_t stringWithSeed(void* str, int64_t seed) {
    int64_t h = seed % kBase;
    if (!str) {
        return h; // Const_Empty and friends: the empty string.
    }

    if (Elm::StringOps::isUtf8(str)) {
        // Fast path. The gate that produces this form is all-ASCII, so one
        // byte is one code unit and no widening is needed — the same identity
        // StringExports.cpp's snapshotChars relies on.
        auto pr = Elm::StringOps::utf8Bytes(str);
        const Elm::u8* p = pr.first;
        for (Elm::u32 i = 0; i < pr.second; ++i) {
            h = mix(h, static_cast<int64_t>(p[i]));
        }
        return h;
    }

    // Rope / UTF-16 / slice forms: index through charAt, which resolves
    // forwarding pointers but never allocates.
    const Elm::i64 n = Elm::StringOps::length(str);
    for (Elm::i64 i = 0; i < n; ++i) {
        h = mix(h, static_cast<int64_t>(Elm::StringOps::charAt(str, i)));
    }
    return h;
}

int64_t string64(void* str, int64_t seed) {
    // FNV-1a, 64-bit. Unsigned throughout: signed overflow is UB, and the
    // final cast to int64_t is the well-defined two's-complement conversion.
    // The Elm side receives it as a plain `Int`; see the header for why a
    // negative bucket key is fine.
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
