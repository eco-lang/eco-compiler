// The C-linkage functions that compiled byte-fusion code calls when it needs the runtime: to allocate or
// measure a Bytes buffer, to convert between Strings and UTF-8 bytes, to fall back to the runtime's
// encoder walker, and to build a Maybe or reverse a list.
//
// Byte-fusion code reads and writes the bytes of a buffer directly, through a raw cursor, but it never
// looks inside a heap object. Everything that depends on how a Bytes value or a String is laid out (the
// flat, large-header and slice forms of Bytes, the UTF-16 and UTF-8 forms of String) is done here, by
// calling the `Elm::alloc` and `Elm::StringOps` helpers that own those layouts.
//
// Every heap value crosses this boundary as an `HPtr`, the 64-bit HPointer word that `Heap.hpp` defines.
// Some functions are GC points: they allocate on the Elm heap, which may run a collection that moves any
// nursery object, so a caller must root every other HPointer it holds across them, and any raw pointer
// into a nursery object, such as the one `elm_bytebuffer_data` returns, is stale afterwards. Each
// function's comment says whether it is one.
//
// The header declares `u8` and `u32` at global scope and names `Elm::HPtr`, so it can be included only
// from C++, despite the `extern "C"` block.

#pragma once
#include <stdint.h>
#include "Heap.hpp"

#ifdef __cplusplus
extern "C" {
#endif

/// An unsigned 8-bit byte.
typedef uint8_t  u8;
/// An unsigned 32-bit integer, the width of every length and count in this interface.
typedef uint32_t u32;
using Elm::HPtr;

// ============================================================================
// ByteBuffer operations
// ============================================================================

/// Allocates a Bytes value of `byteCount` bytes, or returns the Empty constant when `byteCount` is 0.
/// When `byteCount` plus the buffer header, rounded up to 8, reaches the large-object threshold, the
/// buffer is a nursery header with a pinned body, which is zeroed; otherwise it is one nursery object
/// whose contents are not written. A GC point.
HPtr elm_alloc_bytebuffer(u32 byteCount);

/// Returns the length in bytes of the Bytes value `bb`, in any of its forms, or 0 for any embedded
/// constant, which includes the empty Bytes. Not a GC point.
u32 elm_bytebuffer_len(HPtr bb);

/// Returns a pointer to the first byte of the Bytes value `bb`, in any of its forms, or null for any
/// embedded constant. Not a GC point.
///
/// For a large buffer, or a slice of one, the pointer is into the pinned body, which a collection does not
/// move. For any other buffer, in the nursery or the old generation, it is stale once a collection may
/// have moved the buffer, so after any GC point.
u8* elm_bytebuffer_data(HPtr bb);

/// A function given the bytes of a buffer by `elm_bytebuffer_with_data`: `data` points at `length` bytes,
/// and `ctx` is the pointer the caller passed. `data` is valid only during the call.
typedef void (*elm_bytebuffer_callback)(const u8* data, u32 length, void* ctx);

/// Calls `fn` once with the bytes of the Bytes value `bb`, in any of its forms, and `ctx`, or with null
/// and 0 when `bb` is an embedded constant. Does nothing if `fn` is null. Not a GC point itself.
///
/// `fn` must not allocate on the Elm heap: the pointer it is given is not re-derived, so it stays valid
/// only while nothing can move the buffer. Nothing checks this.
void elm_bytebuffer_with_data(HPtr bb, elm_bytebuffer_callback fn, void* ctx);

/// Makes the Bytes object `bb` a builder, an object still being filled that Elm code cannot yet see, or
/// does nothing when `bb` is an embedded constant. Not a GC point.
///
/// A builder is not promoted, so a half-built object never becomes an old-generation object pointing at
/// young ones; the rules are those of `Elm::alloc::mark_as_builder`, and the object must be young. Every
/// builder must be ended with `elm_bytebuffer_builder_end` before Elm code can see it.
void elm_bytebuffer_builder_begin(HPtr bb);

/// Ends the builder state that `elm_bytebuffer_builder_begin` set on `bb`, after which it ages and is
/// promoted like any object, or does nothing when `bb` is an embedded constant. Not a GC point.
void elm_bytebuffer_builder_end(HPtr bb);

// ============================================================================
// String operations
// ============================================================================

/// Returns the number of bytes `elm_utf8_copy` writes for the String `elmString`: its UTF-8 length,
/// counting each unpaired surrogate as three bytes. Not a GC point.
u32 elm_utf8_width(HPtr elmString);

/// Writes the String `elmString` to `dst` as UTF-8 and returns the number of bytes written.
///
/// `dst` must have room for `elm_utf8_width(elmString)` bytes. A surrogate pair is written as one 4-byte
/// sequence, and an unpaired surrogate as the 3-byte encoding of its own value, which is not valid UTF-8.
/// Not a GC point.
u32 elm_utf8_copy(HPtr elmString, u8* dst);

/// Returns the String decoded from the `len` bytes at `offset` in the Bytes value `buffer`, or the null
/// word 0 if those bytes are not valid UTF-8. A GC point when `len` is not 0 and
/// the bytes are valid.
///
/// `buffer` must hold at least `offset + len` bytes; nothing checks it. Overlong encodings, encoded
/// surrogates and code points above U+10FFFF count as invalid. A valid result is always a UTF-16 String,
/// or the Empty constant when `len` is 0, and 0 is never an Elm value, so it cannot be mistaken for one.
/// The buffer is taken as an HPointer rather than a pointer to its bytes because the function allocates
/// partway through; it roots `buffer` across that allocation and finds its bytes again afterwards.
HPtr elm_utf8_decode(HPtr buffer, u32 offset, u32 len);

// ============================================================================
// Encoder-tree operations (bytes-fusion escape hatch)
// ============================================================================

/// Returns the number of bytes `elm_encoder_write_into` writes for `encoder`, a `Bytes.Encode.Encoder`
/// value.
///
/// For a sequence or a String encoder this is the width cached in the encoder itself, so the call does
/// not walk the tree. Defined by the Bytes kernel, not in this component. Not a GC point.
u32 elm_encoder_size(HPtr encoder);

/// Writes the bytes of `encoder`, a `Bytes.Encode.Encoder` value, to `dst` and returns how many were
/// written.
///
/// `dst` must have room for `elm_encoder_size(encoder)` bytes. Defined by the Bytes kernel, not in this
/// component. Not a GC point, so a `dst` into a nursery buffer stays valid throughout.
u32 elm_encoder_write_into(HPtr encoder, u8* dst);

// ============================================================================
// Maybe operations
// ============================================================================

/// Returns `Nothing`, which is the Empty constant. Not a GC point.
HPtr elm_maybe_nothing(void);

/// Returns `Just value`, with `value` stored as a boxed field. A GC point; `value` itself is rooted across
/// the allocation.
HPtr elm_maybe_just(HPtr value);

// ============================================================================
// List operations
// ============================================================================

/// Returns the elements of `list` in reverse order, keeping each element's slot kind, as
/// `Elm::ListOps::reverse` does. A GC point.
HPtr elm_list_reverse(HPtr list);

#ifdef __cplusplus
}
#endif
