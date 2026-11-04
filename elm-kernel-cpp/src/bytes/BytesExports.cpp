//===- BytesExports.cpp - C-linkage exports for Bytes module ---------------===//
//
// The elm/bytes kernel functions that compiled Elm code calls, over the runtime's ByteBuffer values.
// They are the path taken where the compiler's bytes fusion does not apply.
//
// Encoding is in two steps. The `write_*` functions build nodes of an encoder tree, a
// `Bytes.Encode.Encoder` value: a Custom whose ctor is an `EncoderTag` and whose fields have the
// layout of the matching Elm constructor, so a tree built here and one built by Elm code are read
// the same way. `encode` then sizes the tree, allocates one buffer of that size, and writes the tree
// into it without allocating again. Sizing is cheap because a sequence node and a String node carry
// their byte width in field 0.
//
// Decoding runs a decoder closure over `(bytes, 0)`. Each primitive read takes the buffer and an
// offset, and returns `Tuple2(newOffset, value)`, the offset first. A read that fails (past the end,
// a negative offset or length, or malformed UTF-8 for `read_string`), and `Bytes.Decode.fail`, do not
// return: they throw `Elm::BytesDecodeFailure`, which only `decode` catches, turning the whole decode
// into Nothing.
//
// Endianness arrives in two forms. A read's `isLE` is a Bool, True meaning little-endian. An encoder
// node holds an `Endianness` value, whose ctor 0 is `LE` and 1 is `BE`.
//
// Pointers into the heap taken here, such as a `ByteBufferView` or `U16View`, stay valid only until
// the next allocation, which may move the object. Every function either finishes with them before it
// allocates, roots the handle across the allocation and resolves it again afterwards, or hands the
// bytes to a callee that copies them before it allocates.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/BytesOps.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/RootSet.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/Scheduler.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>

// The runtime's `elm_bytebuffer_len`, declared in `allocator/ElmBytesRuntime.h` with an `HPtr`
// parameter, here with its bits.
extern "C" uint32_t elm_bytebuffer_len(uint64_t bb);

// Runtime functions this file calls, declared here rather than through their headers.
namespace Elm { struct EvalParamLayout; }
extern "C" HPtr eco_apply_closure_typed(HPtr closure_hptr, int64_t* typed_args,
                                        uint32_t num_args,
                                        const Elm::EvalParamLayout* args_layout);
extern "C" size_t eco_gc_stack_range_point();
extern "C" void   eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask);
extern "C" void   eco_gc_restore_stack_range_point(size_t saved);

using namespace Elm;
using namespace Elm::Kernel;

// ============================================================================
// Helpers
// ============================================================================

/// Returns whether `isLE`, the word of a Bool, is True, which a read takes to mean little-endian.
static bool isLittleEndian(uint64_t isLE) {
    return Elm::boolValueBits(isLE) != 0;
}

/// Allocates and returns `Tuple2(a, b)` with both fields unboxed Ints.
static uint64_t makeTuple2_ii(int64_t a, int64_t b) {
    Tuple2* t = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), nullptr, 0, 0));
    // 2-bit kinds: slot 0 Int (01) + slot 1 Int (01) = 0b0101 = 5
    t->header.unboxed = 5;
    t->a.i = a;
    t->b.i = b;
    return Export::encode(Allocator::instance().wrap(t));
}

/// Allocates and returns `Tuple2(a, b)` with `a` an unboxed Int and `b` an unboxed Float.
static uint64_t makeTuple2_if(int64_t a, double b) {
    Tuple2* t = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), nullptr, 0, 0));
    // 2-bit kinds: slot 0 Int (01) + slot 1 Float (10) = 0b1001 = 9
    t->header.unboxed = 9;
    t->a.i = a;
    t->b.f = b;
    return Export::encode(Allocator::instance().wrap(t));
}

/// Allocates and returns `Tuple2(a, b)` with `a` an unboxed Int and `b` boxed. `b` is rooted across
/// the allocation.
static uint64_t makeTuple2_ip(int64_t a, HPointer b) {
    // Only slot 1, `b`, is marked as an HPointer.
    uint64_t roots[2] = { static_cast<uint64_t>(a), 0 };
    std::memcpy(&roots[1], &b, sizeof(b));
    Tuple2* t = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, 0x2));
    std::memcpy(&b, &roots[1], sizeof(b));
    t->header.unboxed = 1;  // only field a unboxed
    t->a.i = a;
    t->b.p = b;
    return Export::encode(Allocator::instance().wrap(t));
}

/// Returns a read-only view of the bytes of `bytes`, the word of a Bytes value in any of its forms,
/// so that `data[i]` is byte `i` whether the value is a flat buffer, a large one or a slice. The empty
/// Bytes, an embedded constant, gives a null `data` and a length of 0.
///
/// The view is valid until the next allocation.
static alloc::ByteBufferView resolveByteBufferView(uint64_t bytes) {
    return alloc::byteBufferView(alloc::resolveBytesOrNull(Export::decode(bytes)));
}

// ============================================================================
// Encoder tree walker for non-fused Bytes.Encode.encode fallback
// ============================================================================

/// The ctor of each kind of encoder-tree node.
///
/// The values are the declaration order of the constructors of the Elm `Encoder` type, and must
/// match it, since Elm code builds nodes too.
enum EncoderTag : u16 {
    ENC_I8   = 0,
    ENC_I16  = 1,
    ENC_I32  = 2,
    ENC_U8   = 3,
    ENC_U16  = 4,
    ENC_U32  = 5,
    ENC_F32  = 6,
    ENC_F64  = 7,
    ENC_SEQ  = 8,
    ENC_UTF8 = 9,
    ENC_BYTES = 10,
};

/// Returns whether `endianness`, an `Endianness` value, is `BE`, ctor 1.
///
/// Both constructors have no fields, so the value is a null-cons word holding the ctor, not a heap
/// object, and is read without resolving anything.
static bool endiannessHPointerToBool(HPointer endianness) {
    return nullConsTagBits(hpBits(endianness)) == 1;
}

/// Returns the number of bytes `writeEncoder` writes for the encoder node `c`, or 0 for an unknown
/// ctor.
///
/// The cost does not depend on the size of the tree. A sequence node (`Seq Int (List Encoder)`) and a
/// String node (`Utf8 Int String`) carry their width in field 0, and a Bytes node's width is the
/// length of its buffer. Does not allocate.
static size_t encoderSize(Custom* c) {
    switch (c->ctor) {
        case ENC_I8:   return 1;
        case ENC_I16:  return 2;
        case ENC_I32:  return 4;
        case ENC_U8:   return 1;
        case ENC_U16:  return 2;
        case ENC_U32:  return 4;
        case ENC_F32:  return 4;
        case ENC_F64:  return 8;
        case ENC_SEQ:  return static_cast<size_t>(c->values[0].i);
        case ENC_UTF8: return static_cast<size_t>(c->values[0].i);
        case ENC_BYTES: {
            void* bbPtr = alloc::resolveBytesOrNull(c->values[0].p);
            return alloc::byteBufferLength(bbPtr);
        }
        default: return 0;
    }
}

/// Writes the bytes of the encoder tree `encoder` into `buf`, starting at `offset`, and advances
/// `offset` past them. An unknown ctor writes nothing.
///
/// `buf` must have room for `encoderSize(encoder)` bytes from `offset`. Does not allocate, so `buf`
/// and `encoder` stay valid throughout.
static void writeEncoder(Custom* encoder, u8* buf, size_t& offset) {
    auto& allocator = Allocator::instance();

    // For the multi-byte numbers field 0 is the `Endianness` (a boxed slot holding a null-cons word)
    // and field 1 is the unboxed Int or Float.
    switch (encoder->ctor) {
        case ENC_I8:
        case ENC_U8: {
            buf[offset++] = static_cast<u8>(encoder->values[0].i & 0xFF);
            break;
        }
        case ENC_I16:
        case ENC_U16: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            uint16_t val = static_cast<uint16_t>(encoder->values[1].i);
            if (be) val = __builtin_bswap16(val);
            std::memcpy(buf + offset, &val, 2);
            offset += 2;
            break;
        }
        case ENC_I32:
        case ENC_U32: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            uint32_t val = static_cast<uint32_t>(encoder->values[1].i);
            if (be) val = __builtin_bswap32(val);
            std::memcpy(buf + offset, &val, 4);
            offset += 4;
            break;
        }
        case ENC_F32: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            float val = static_cast<float>(encoder->values[1].f);
            uint32_t bits;
            std::memcpy(&bits, &val, 4);
            if (be) bits = __builtin_bswap32(bits);
            std::memcpy(buf + offset, &bits, 4);
            offset += 4;
            break;
        }
        case ENC_F64: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            double val = encoder->values[1].f;
            uint64_t bits;
            std::memcpy(&bits, &val, 8);
            if (be) bits = __builtin_bswap64(bits);
            std::memcpy(buf + offset, &bits, 8);
            offset += 8;
            break;
        }
        case ENC_SEQ: {
            // ListCursor walks the list without allocating.
            for (alloc::ListCursor l(encoder->values[1].p); !l.done(); l.next()) {
                void* subPtr = allocator.resolve(l.current().p);
                writeEncoder(static_cast<Custom*>(subPtr), buf, offset);
            }
            break;
        }
        case ENC_UTF8: {
            // The empty String is an embedded constant, which cannot be resolved, and has nothing to
            // write.
            if (alloc::isEmptyString(encoder->values[1].p)) {
                break;
            }
            void* strPtr = allocator.resolve(encoder->values[1].p);

            // A UTF-8 form holds only ASCII, so its bytes are already the encoding.
            if (Elm::StringOps::isUtf8(strPtr)) {
                auto pr = Elm::StringOps::utf8Bytes(strPtr);
                std::memcpy(buf + offset, pr.first, pr.second);
                offset += pr.second;
                break;
            }

            // A flat leaf is read in place; nothing below allocates, so `chars` stays valid. Any
            // other form is copied out once with toStdU16String. A surrogate that is not part of a
            // high-low pair is written as a three-byte sequence.
            const u16* chars = nullptr;
            size_t nchars = 0;
            std::u16string snapshot_storage;
            if (Elm::StringOps::isLeaf(strPtr)) {
                alloc::U16View s = alloc::flatStringView(strPtr);
                chars = s.chars;
                nchars = s.length;
            } else {
                snapshot_storage = Elm::StringOps::toStdU16String(strPtr);
                chars = reinterpret_cast<const u16*>(snapshot_storage.data());
                nchars = snapshot_storage.size();
            }
            for (size_t i = 0; i < nchars; i++) {
                u16 ch = chars[i];
                if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < nchars) {
                    u16 lo = chars[i + 1];
                    if (lo >= 0xDC00 && lo <= 0xDFFF) {
                        uint32_t cp = 0x10000 + ((ch - 0xD800) << 10) + (lo - 0xDC00);
                        buf[offset++] = static_cast<u8>(0xF0 | ((cp >> 18) & 0x07));
                        buf[offset++] = static_cast<u8>(0x80 | ((cp >> 12) & 0x3F));
                        buf[offset++] = static_cast<u8>(0x80 | ((cp >> 6) & 0x3F));
                        buf[offset++] = static_cast<u8>(0x80 | (cp & 0x3F));
                        i++;
                        continue;
                    }
                }
                if (ch < 0x80) {
                    buf[offset++] = static_cast<u8>(ch);
                } else if (ch < 0x800) {
                    buf[offset++] = static_cast<u8>(0xC0 | ((ch >> 6) & 0x1F));
                    buf[offset++] = static_cast<u8>(0x80 | (ch & 0x3F));
                } else {
                    buf[offset++] = static_cast<u8>(0xE0 | ((ch >> 12) & 0x0F));
                    buf[offset++] = static_cast<u8>(0x80 | ((ch >> 6) & 0x3F));
                    buf[offset++] = static_cast<u8>(0x80 | (ch & 0x3F));
                }
            }
            break;
        }
        case ENC_BYTES: {
            void* bbPtr = alloc::resolveBytesOrNull(encoder->values[0].p);
            auto vbb = alloc::byteBufferView(bbPtr);
            if (vbb.length > 0) std::memcpy(buf + offset, vbb.data, vbb.length);
            offset += vbb.length;
            break;
        }
    }
}

// ============================================================================
// Decoder read functions
// ============================================================================
//
// A read takes `(bytes, offset)`, or `(arg, bytes, offset)` when it has an argument (`isLE` or a
// length). The argument comes first because the Elm decoder combinators partially apply a read to
// it and later call the result with the buffer and offset.
//
// Every parameter is a 64-bit word; `isLE` is the word of a Bool. A read that succeeds returns
// `Tuple2(newOffset, value)`, `newOffset` an unboxed Int. One that fails throws instead.

// ============================================================================
// extern "C" exports
// ============================================================================

extern "C" {

HPtr Elm_Kernel_Bytes_width(HPtr bytes) {
    return HPtr::fromBits(static_cast<uint64_t>(elm_bytebuffer_len(bytes.toBits())));
}

/// Returns a Task that succeeds with `le` on a little-endian host and with `be` on a big-endian one. elm/bytes
/// calls it as `Elm.Kernel.Bytes.getHostEndianness LE BE`. The host is tested here, when the Task is built; it
/// does no IO, so it is a plain succeeded Task rather than a binding.
HPtr Elm_Kernel_Bytes_getHostEndianness(HPtr le, HPtr be) {
    uint16_t test = 1;
    bool isLE = (*reinterpret_cast<uint8_t*>(&test) == 1);
    HPointer result = Export::decode((isLE ? le : be).toBits());
    return HPtr::fromBits(Export::encode(
        Elm::Platform::Scheduler::instance().taskSucceed(result)));
}

int64_t Elm_Kernel_Bytes_getStringWidth(HPtr str) {
    uint64_t strBits = str.toBits();
    HPointer h = Export::decode(strBits);
    if (Elm::alloc::isEmptyString(h)) {
        return 0;
    }
    void* ptr = Export::toPtr(strBits);
    if (!ptr) return 0;

    // A UTF-8 form holds only ASCII, so its width is its length.
    if (Elm::StringOps::isUtf8(ptr)) {
        return static_cast<int64_t>(Elm::StringOps::length(ptr));
    }

    // A flat leaf is read in place; nothing below allocates, so `chars_data` stays valid. Any other
    // form is copied out once with toStdU16String. A surrogate that is not part of a high-low pair
    // counts as 3 bytes, as writeEncoder writes it.
    const u16* chars_data = nullptr;
    size_t utf16_length = 0;
    std::u16string snapshot_storage;
    if (Elm::StringOps::isLeaf(ptr)) {
        alloc::U16View s = alloc::flatStringView(ptr);
        chars_data = s.chars;
        utf16_length = s.length;
    } else {
        snapshot_storage = Elm::StringOps::toStdU16String(ptr);
        chars_data = reinterpret_cast<const u16*>(snapshot_storage.data());
        utf16_length = snapshot_storage.size();
    }
    if (utf16_length == 0) return 0;

    int64_t utf8_bytes = 0;
    for (size_t i = 0; i < utf16_length; i++) {
        uint16_t codeUnit = chars_data[i];
        if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
            if (i + 1 < utf16_length) {
                uint16_t lo = chars_data[i + 1];
                if (lo >= 0xDC00 && lo <= 0xDFFF) {
                    utf8_bytes += 4;
                    i++;
                    continue;
                }
            }
            utf8_bytes += 3;
        } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
            utf8_bytes += 3;
        } else if (codeUnit < 0x80) {
            utf8_bytes += 1;
        } else if (codeUnit < 0x800) {
            utf8_bytes += 2;
        } else {
            utf8_bytes += 3;
        }
    }
    return utf8_bytes;
}

// The two encoder-tree operations declared in `allocator/ElmBytesRuntime.h`, which owns their
// contract. Each resolves the encoder and hands it to encoderSize or writeEncoder. The width is
// narrowed to u32 with no check, so an encoder wider than 4 GiB gives a wrong result.

extern "C" u32 elm_encoder_size(HPtr encoderVal) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal.toBits());
    Custom* enc = static_cast<Custom*>(allocator.resolve(h));
    return static_cast<u32>(encoderSize(enc));
}

extern "C" u32 elm_encoder_write_into(HPtr encoderVal, u8* dst) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal.toBits());
    Custom* enc = static_cast<Custom*>(allocator.resolve(h));
    size_t offset = 0;
    writeEncoder(enc, dst, offset);
    return static_cast<u32>(offset);
}

HPtr Elm_Kernel_Bytes_encode(HPtr encoderVal) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal.toBits());

    size_t totalSize = encoderSize(static_cast<Custom*>(allocator.resolve(h)));

    // The encoder tree is rooted across the allocByteBufferBlank allocation and resolved again after it.
    alloc::BlankByteBuffer dst;
    {
        StackRootRangeGuard guard(&h, 1, 0x1);
        dst = alloc::allocByteBufferBlank(totalSize);
    }

    Custom* encoder = static_cast<Custom*>(allocator.resolve(h));
    size_t offset = 0;
    writeEncoder(encoder, dst.bytes, offset);
    return HPtr::fromBits(Export::encode(dst.hp));
}

HPtr Elm_Kernel_Bytes_decode(HPtr decoder, HPtr bytes) {
    auto& allocator = Allocator::instance();

    // The decoder is applied to (bytes, 0), the offset passed as an unboxed Int. A combined decoder
    // may be a partial application rather than a plain two-argument function, so it goes through
    // eco_apply_closure_typed, which accepts both.
    static constexpr auto kLayoutBoxedInt = Elm::makeEvalParamLayout<2>(0, {0, 1});
    const auto* layout = Elm::asLayout(&kLayoutBoxedInt);
    int64_t args[2] = { static_cast<int64_t>(bytes.toBits()), 0 };

    // Failure is a non-local exit: a failing read or `fail` throws BytesDecodeFailure from wherever it
    // sits under the combinators, and it is caught here, so no combinator sees a missing tuple. The
    // frames it unwinds are compiled Elm code and the closure-apply trampolines. Those push kernel
    // root-stack entries, range records and scratch entries that they pop on a normal return, and the
    // throw skips those pops, so both root-stack cursors and the scratch stack are put back to their
    // state on entry.
    const EcoRootMark rootMark = ecoRootMark();
    const int64_t scratchMark = eco_scratch_mark();
    uint64_t result;
    try {
        result = eco_apply_closure_typed(decoder, args, 2, layout).toBits();
    } catch (const Elm::BytesDecodeFailure&) {
        ecoRootRelease(rootMark);
        eco_scratch_abandon(scratchMark);
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    // A decoder that returns rather than throws gives Tuple2(newOffset, value). An embedded constant
    // in its place is reported as Nothing rather than resolved.
    HPointer resultHP = Export::decode(result);
    if (resultHP.ptr_ind != 0) {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    // The result tuple is rooted across the allocation of the Just and resolved again after it. The
    // Just's one field takes the tuple's field b with its slot kind.
    size_t justSize = sizeof(Custom) + sizeof(Unboxable);
    justSize = (justSize + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &resultHP, sizeof(resultHP));
    Custom* just = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, justSize, roots, 1, 0x1));
    std::memcpy(&resultHP, &roots[0], sizeof(resultHP));
    just->header.size = 1;
    just->ctor = 0;  // Just

    Tuple2* tuple = static_cast<Tuple2*>(allocator.resolve(resultHP));

    uint32_t bKind = Elm::tupleFieldKind(tuple->header.unboxed, 1);
    just->unboxed = bKind;  // slot 0 kind matches source slot 1 kind
    just->values[0] = tuple->b;

    return HPtr::fromBits(Export::encode(allocator.wrap(just)));
}

HPtr Elm_Kernel_Bytes_decodeFailure() {
    throw Elm::BytesDecodeFailure{};
}

// --- arity 2 read functions: (bytes, offset) ---

// Each numeric read copies the bytes into an integer, byte-swaps it when the requested order is
// big-endian, and reinterprets it. The swap assumes a little-endian host. A negative offset, or one
// with fewer bytes after it than the width, fails the read.

/// Fails the current read by throwing `Elm::BytesDecodeFailure`.
///
/// It is typed as returning `HPtr` so that a read can write `return decoderNothing();`.
[[noreturn]] static HPtr decoderNothing() {
    throw Elm::BytesDecodeFailure{};
}

HPtr Elm_Kernel_Bytes_read_i8(HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 1 > v.length) return decoderNothing();
    int8_t val = static_cast<int8_t>(v.data[offset]);
    return HPtr::fromBits(makeTuple2_ii(offset + 1, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_u8(HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 1 > v.length) return decoderNothing();
    return HPtr::fromBits(makeTuple2_ii(offset + 1, static_cast<int64_t>(v.data[offset])));
}

// --- arity 3 read functions: (isLE_or_length, bytes, offset) ---

HPtr Elm_Kernel_Bytes_read_i16(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 2 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint16_t raw;
    std::memcpy(&raw, v.data + offset, 2);
    if (!le) raw = __builtin_bswap16(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 2,
        static_cast<int64_t>(static_cast<int16_t>(raw))));
}

HPtr Elm_Kernel_Bytes_read_i32(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 4 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint32_t raw;
    std::memcpy(&raw, v.data + offset, 4);
    if (!le) raw = __builtin_bswap32(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 4,
        static_cast<int64_t>(static_cast<int32_t>(raw))));
}

HPtr Elm_Kernel_Bytes_read_u16(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 2 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint16_t raw;
    std::memcpy(&raw, v.data + offset, 2);
    if (!le) raw = __builtin_bswap16(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 2, static_cast<int64_t>(raw)));
}

HPtr Elm_Kernel_Bytes_read_u32(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 4 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint32_t raw;
    std::memcpy(&raw, v.data + offset, 4);
    if (!le) raw = __builtin_bswap32(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 4, static_cast<int64_t>(raw)));
}

HPtr Elm_Kernel_Bytes_read_f32(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 4 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint32_t bits;
    std::memcpy(&bits, v.data + offset, 4);
    if (!le) bits = __builtin_bswap32(bits);
    float fval;
    std::memcpy(&fval, &bits, 4);
    return HPtr::fromBits(makeTuple2_if(offset + 4, static_cast<double>(fval)));
}

HPtr Elm_Kernel_Bytes_read_f64(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 8 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint64_t bits;
    std::memcpy(&bits, v.data + offset, 8);
    if (!le) bits = __builtin_bswap64(bits);
    double dval;
    std::memcpy(&dval, &bits, 8);
    return HPtr::fromBits(makeTuple2_if(offset + 8, dval));
}

HPtr Elm_Kernel_Bytes_read_bytes(int64_t length, HPtr bytes, int64_t offset) {
    // makeByteBufferSlice gives a slice over the source without copying, or a copy for a range
    // shorter than MAKE_BYTEBUFFER_SLICE_MIN_LEN bytes.
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || length < 0 || static_cast<size_t>(offset) + static_cast<size_t>(length) > v.length) return decoderNothing();
    HPointer srcHP = Export::decode(bytes.toBits());
    HPointer sliceHP = alloc::makeByteBufferSlice(srcHP,
        static_cast<u32>(offset), static_cast<u32>(length));
    return HPtr::fromBits(makeTuple2_ip(offset + length, sliceHP));
}

HPtr Elm_Kernel_Bytes_read_string(int64_t length, HPtr bytes, int64_t offset) {
    auto& allocator = Allocator::instance();

    // An empty string is the empty-String constant, not a zero-length heap String, which equality
    // would not treat as equal to it. A zero length is accepted at any offset, with no bounds check.
    if (length == 0) {
        return HPtr::fromBits(makeTuple2_ip(offset, alloc::emptyString()));
    }

    // `src` is read through a raw pointer until the first allocation; after it the source is resolved
    // again through the rooted handle.
    HPointer srcHP = Export::decode(bytes.toBits());
    auto src_view = alloc::byteBufferView(alloc::resolveBytesOrNull(srcHP));
    if (offset < 0 || length < 0 ||
        static_cast<size_t>(offset) + static_cast<size_t>(length) > src_view.length) {
        return decoderNothing();
    }
    const u8* src = src_view.data + offset;

    // Utf8::scan rejects malformed input: a truncated sequence, a stray continuation or 0xF8+ lead
    // byte, an overlong form, a surrogate, or a code point above 0x10FFFF. Rejected input fails the
    // read. Because every multi-byte sequence then lies wholly inside [offset, offset + length), the
    // transcode below reads no byte outside that range, neither past the buffer nor past a slice into
    // its parent.
    Elm::Utf8::ScanResult scan = Elm::Utf8::scan(src, static_cast<size_t>(length));
    if (!scan.valid) {
        return decoderNothing();
    }

    // When UTF-8 strings are enabled, all-ASCII input becomes a UTF-8 String with no transcode: a view
    // over the source for at least utf8_view_min_len bytes, otherwise a small UTF-8 leaf. Other input
    // is transcoded to UTF-16 below.
    const auto& cfg = allocator.getConfig();
    if (cfg.utf8_strings_enabled && scan.ascii) {
        HPointer result;
        if (static_cast<size_t>(length) >= cfg.utf8_view_min_len) {
            // makeUtf8View takes `offset` relative to the Bytes value, as byteBufferView does, for
            // a flat, large or slice source alike.
            result = Elm::StringOps::makeUtf8View(
                srcHP, static_cast<u32>(offset), static_cast<u32>(length));
        } else {
            // makeUtf8LeafFromBytes copies `src` out of the heap before allocating, so no rooting is needed at
            // this call site.
            result = Elm::StringOps::makeUtf8LeafFromBytes(
                src, static_cast<u32>(length));
        }
        return HPtr::fromBits(makeTuple2_ip(offset + length, result));
    }

    size_t utf16Count = scan.utf16Units;

    size_t strAllocSize = sizeof(ElmString) + utf16Count * sizeof(u16);
    strAllocSize = (strAllocSize + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &srcHP, sizeof(srcHP));
    ElmString* str = static_cast<ElmString*>(
        eco_alloc_with_roots(Tag_String, strAllocSize, roots, 1, 0x1));
    std::memcpy(&srcHP, &roots[0], sizeof(srcHP));
    str->header.size = static_cast<u32>(utf16Count);

    src_view = alloc::byteBufferView(allocator.resolve(srcHP));
    src = src_view.data + offset;

    size_t srcPos = 0, dstPos = 0;
    while (srcPos < static_cast<size_t>(length)) {
        uint8_t byte = src[srcPos];
        uint32_t codepoint;
        if (byte < 0x80) {
            codepoint = byte;
            srcPos++;
        } else if (byte < 0xE0) {
            codepoint = (byte & 0x1F) << 6;
            codepoint |= (src[srcPos + 1] & 0x3F);
            srcPos += 2;
        } else if (byte < 0xF0) {
            codepoint = (byte & 0x0F) << 12;
            codepoint |= (src[srcPos + 1] & 0x3F) << 6;
            codepoint |= (src[srcPos + 2] & 0x3F);
            srcPos += 3;
        } else {
            codepoint = (byte & 0x07) << 18;
            codepoint |= (src[srcPos + 1] & 0x3F) << 12;
            codepoint |= (src[srcPos + 2] & 0x3F) << 6;
            codepoint |= (src[srcPos + 3] & 0x3F);
            srcPos += 4;
        }

        if (codepoint <= 0xFFFF) {
            str->chars[dstPos++] = static_cast<u16>(codepoint);
        } else {
            codepoint -= 0x10000;
            str->chars[dstPos++] = static_cast<u16>(0xD800 + (codepoint >> 10));
            str->chars[dstPos++] = static_cast<u16>(0xDC00 + (codepoint & 0x3FF));
        }
    }
    // The input is valid UTF-8, so the transcode wrote exactly scan.utf16Units units.
    assert(dstPos == utf16Count);

    return HPtr::fromBits(makeTuple2_ip(offset + length, allocator.wrap(str)));
}

// --- write functions: create Encoder tree nodes (Custom types) ---
//
// Each node has the layout of the Elm `Encoder` constructor with the same ctor, which is what
// writeEncoder reads.

/// Allocates and returns an encoder node with ctor `tag` and one unboxed Int field, `value`. Used for
/// the 8-bit writes.
static uint64_t makeEncoder1(u16 tag, int64_t value) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = tag;
    enc->unboxed = 1;  // value is unboxed
    enc->values[0].i = value;
    return Export::encode(Allocator::instance().wrap(enc));
}

/// Allocates and returns an encoder node with ctor `tag`, the `Endianness` value `endianness` in
/// boxed field 0, and `value` in unboxed Int field 1. Used for the multi-byte integer writes.
static uint64_t makeEncoder2_pi(u16 tag, uint64_t endianness, int64_t value) {
    HPointer endHP = Export::decode(endianness);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[2];
    std::memcpy(&roots[0], &endHP, sizeof(endHP));
    roots[1] = static_cast<uint64_t>(value);

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 2, 0x1));
    enc->header.size = 2;
    enc->ctor = tag;
    enc->unboxed = 4;  // slot 0 boxed (00) + slot 1 Int (01) = 0b0100
    std::memcpy(&enc->values[0].p, &roots[0], sizeof(HPointer));
    enc->values[1].i = static_cast<int64_t>(roots[1]);
    return Export::encode(Allocator::instance().wrap(enc));
}

/// Allocates and returns an encoder node as `makeEncoder2_pi` does, with `value` in an unboxed Float
/// field 1. Used for the float writes.
static uint64_t makeEncoder2_pf(u16 tag, uint64_t endianness, double value) {
    HPointer endHP = Export::decode(endianness);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &endHP, sizeof(endHP));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&endHP, &roots[0], sizeof(endHP));
    enc->header.size = 2;
    enc->ctor = tag;
    enc->unboxed = 8;  // slot 0 boxed (00) + slot 1 Float (10) = 0b1000
    enc->values[0].p = endHP;
    enc->values[1].f = value;
    return Export::encode(Allocator::instance().wrap(enc));
}

/// Allocates and returns an encoder node with ctor `tag` and one boxed field, the value whose word is
/// `ptr`. Nothing calls it.
static uint64_t makeEncoder1_p(u16 tag, uint64_t ptr) {
    HPointer payload = Export::decode(ptr);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &payload, sizeof(payload));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&payload, &roots[0], sizeof(payload));
    enc->header.size = 1;
    enc->ctor = tag;
    enc->unboxed = 0;
    enc->values[0].p = payload;
    return Export::encode(Allocator::instance().wrap(enc));
}

/// Allocates and returns a String encoder node for `str`: its UTF-8 width as an unboxed Int in field
/// 0, and `str` boxed in field 1.
static uint64_t makeEncoderUtf8(HPtr str) {
    int64_t utf8Size = Elm_Kernel_Bytes_getStringWidth(str);

    HPointer strHP = Export::decode(str.toBits());
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &strHP, sizeof(strHP));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&strHP, &roots[0], sizeof(strHP));
    enc->header.size = 2;
    enc->ctor = ENC_UTF8;
    enc->unboxed = 1;  // field 0 unboxed (size), field 1 boxed (string)
    enc->values[0].i = utf8Size;
    enc->values[1].p = strHP;
    return Export::encode(Allocator::instance().wrap(enc));
}

/// Allocates and returns a Bytes encoder node holding `bytes`, the word of a Bytes value, in its one
/// boxed field.
static uint64_t makeEncoderBytes(uint64_t bytes) {
    HPointer payload = Export::decode(bytes);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &payload, sizeof(payload));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&payload, &roots[0], sizeof(payload));
    enc->header.size = 1;
    enc->ctor = ENC_BYTES;
    enc->unboxed = 0;
    enc->values[0].p = payload;
    return Export::encode(Allocator::instance().wrap(enc));
}

HPtr Elm_Kernel_Bytes_write_i8(int64_t value) {
    return HPtr::fromBits(makeEncoder1(ENC_I8, value));
}

HPtr Elm_Kernel_Bytes_write_i16(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_I16, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_i32(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_I32, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_u8(int64_t value) {
    return HPtr::fromBits(makeEncoder1(ENC_U8, value));
}

HPtr Elm_Kernel_Bytes_write_u16(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_U16, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_u32(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_U32, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_f32(HPtr endianness, double value) {
    return HPtr::fromBits(makeEncoder2_pf(ENC_F32, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_f64(HPtr endianness, double value) {
    return HPtr::fromBits(makeEncoder2_pf(ENC_F64, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_bytes(HPtr bytes) {
    return HPtr::fromBits(makeEncoderBytes(bytes.toBits()));
}

HPtr Elm_Kernel_Bytes_write_string(HPtr str) {
    return HPtr::fromBits(makeEncoderUtf8(str));
}

} // extern "C"
