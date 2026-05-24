/**
 * Byte Fusion Runtime ABI for Elm Compiler.
 *
 * This header defines the C ABI functions used by the bf MLIR dialect lowering.
 * All heap values are represented as u64 (eco.value) at the ABI boundary.
 * Internal pointer conversion happens only inside ElmBytesRuntime.cpp.
 *
 * These functions are the ONLY code allowed to access ByteBuffer/ElmString
 * header layout directly. Generated MLIR/LLVM code must call these helpers
 * instead of using GEPs into the structures.
 */

#pragma once
#include <stdint.h>
#include "Heap.hpp"

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t  u8;
typedef uint32_t u32;
using Elm::HPtr;

// ============================================================================
// ByteBuffer operations (heap values are u64)
// ============================================================================

/**
 * Allocate ByteBuffer with byteCount bytes.
 * Returns eco.value (u64) representing the allocated ByteBuffer.
 */
HPtr elm_alloc_bytebuffer(u32 byteCount);

/**
 * Return ByteBuffer byte length.
 * Takes eco.value (u64) representing a ByteBuffer.
 */
u32 elm_bytebuffer_len(HPtr bb);

/**
 * Return pointer to first payload byte.
 * Takes eco.value (u64) representing a ByteBuffer.
 * Returns raw pointer (for cursor setup only - not an eco.value).
 *
 * SAFETY: The returned pointer does NOT survive GC. Callers that hold it
 * across any allocation will read freed/moved memory. For GC-safe access,
 * use elm_bytebuffer_with_data, which guarantees the buffer body is stable
 * during the callback by virtue of being a non-allocating runtime call.
 */
u8* elm_bytebuffer_data(HPtr bb);

/**
 * Callback variant of elm_bytebuffer_data. Invokes `fn(data, length, ctx)`
 * with a pointer to the payload that is guaranteed stable for the duration
 * of the call — the callback MUST NOT allocate on the Elm heap. Handles all
 * ByteBuffer forms (flat, large-header, slice).
 *
 * Intended for new code paths that read a buffer's bytes inline; existing
 * elm_bytebuffer_data callers remain on the raw-pointer form until each
 * call site is audited for GC safety.
 */
typedef void (*elm_bytebuffer_callback)(const u8* data, u32 length, void* ctx);
void elm_bytebuffer_with_data(HPtr bb, elm_bytebuffer_callback fn, void* ctx);

// ============================================================================
// String operations (heap values are u64)
// ============================================================================

/**
 * Return UTF-8 byte width of an ElmString.
 * Takes eco.value (u64) representing an ElmString.
 * Returns the number of bytes needed to represent the string in UTF-8.
 */
u32 elm_utf8_width(HPtr elmString);

/**
 * Copy ElmString as UTF-8 bytes to dst buffer.
 * Takes eco.value (u64) representing an ElmString and a destination buffer.
 * Returns number of bytes written.
 *
 * IMPORTANT: Caller must ensure dst has at least elm_utf8_width(elmString) bytes.
 */
u32 elm_utf8_copy(HPtr elmString, u8* dst);

/**
 * Decode UTF-8 bytes into an ElmString.
 * Returns eco.value (u64) representing the ElmString, or 0 on failure.
 *
 * Failure semantics: Returns 0 on invalid UTF-8 input.
 * eco.value == 0 is guaranteed to never represent a valid Elm heap value
 * (null pointer is invalid in the Elm runtime).
 */
HPtr elm_utf8_decode(const u8* src, u32 len);

// ============================================================================
// Encoder-tree operations (bytes-fusion escape hatch)
// ============================================================================

/**
 * Compute the total byte width of a Bytes.Encode.Encoder tree.
 * Takes eco.value (u64) representing a runtime Encoder Custom.
 *
 * Used by the bf.encoder.width MLIR op to size the destination buffer
 * when the compile-time reifier couldn't recognise an encoder subtree.
 *
 * GC-safe: no allocation. The tree is walked once via cached widths
 * in Seq/Utf8 leaves and primitive sizes elsewhere.
 */
u32 elm_encoder_size(HPtr encoder);

/**
 * Write a Bytes.Encode.Encoder tree's bytes into dst.
 * Takes eco.value (u64) representing a runtime Encoder Custom and a
 * destination pointer. Returns the number of bytes written (matches
 * elm_encoder_size for any encoder tree).
 *
 * Used by the bf.write.encoder MLIR op to delegate unfusable encoder
 * subtrees to the existing runtime walker.
 *
 * SAFETY: dst must have at least elm_encoder_size(encoder) bytes.
 * GC-safe: no Eco-heap allocation. The walker uses Allocator::resolve
 * for HPointer traversal; the destination is a raw pointer into a
 * caller-owned buffer that the walker never re-roots.
 */
u32 elm_encoder_write_into(HPtr encoder, u8* dst);

// ============================================================================
// Maybe operations (heap values are u64)
// ============================================================================

/**
 * Return Nothing as eco.value (u64).
 * Returns the embedded constant for Nothing.
 */
HPtr elm_maybe_nothing(void);

/**
 * Return Just(value) as eco.value (u64).
 * Takes the value to wrap and returns Just containing that value.
 */
HPtr elm_maybe_just(HPtr value);

// ============================================================================
// List operations (heap values are u64)
// ============================================================================

/**
 * Reverse a list.
 * Takes eco.value (u64) representing a list.
 * Returns eco.value (u64) representing the reversed list.
 *
 * Used by fused byte decoders to reverse the accumulator after loop decode.
 */
HPtr elm_list_reverse(HPtr list);

#ifdef __cplusplus
}
#endif
