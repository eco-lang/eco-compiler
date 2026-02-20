/**
 * Elm Kernel File Module - Runtime Heap Integration
 *
 * Provides file operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific file dialogs.
 */

#include "File.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/BytesOps.hpp"
#include <cassert>

namespace Elm::Kernel::File {

// File is represented as a Record with fields:
// { name : String, mime : String, size : Int, lastModified : Int, content : Bytes }
// Field indices (alphabetical order):
constexpr u32 FIELD_CONTENT = 0;
constexpr u32 FIELD_LAST_MODIFIED = 1;
constexpr u32 FIELD_MIME = 2;
constexpr u32 FIELD_NAME = 3;
constexpr u32 FIELD_SIZE = 4;

// ============================================================================
// Decoder and Compatibility
// ============================================================================

DecoderPtr decoder() {
    // Return a decoder that extracts a File from a JSON event
    // In practice, this decodes files from drag/drop and form events
    return Json::decodeValue();
}

HPointer makeBytesSafeForInternetExplorer(HPointer bytes) {
    // In modern environments, this is a no-op
    // It was originally needed because IE had issues with certain byte sequences
    return bytes;
}

// ============================================================================
// File Property Accessors
// ============================================================================

HPointer name(void* file) {
    if (!file) return alloc::emptyString();

    Record* rec = static_cast<Record*>(file);
    if (rec->header.tag != Tag_Record) return alloc::emptyString();
    if (rec->header.size <= FIELD_NAME) return alloc::emptyString();

    return rec->values[FIELD_NAME].p;
}

HPointer mime(void* file) {
    if (!file) return alloc::emptyString();

    Record* rec = static_cast<Record*>(file);
    if (rec->header.tag != Tag_Record) return alloc::emptyString();
    if (rec->header.size <= FIELD_MIME) return alloc::emptyString();

    return rec->values[FIELD_MIME].p;
}

HPointer size(void* file) {
    if (!file) return alloc::allocInt(0);

    Record* rec = static_cast<Record*>(file);
    if (rec->header.tag != Tag_Record) return alloc::allocInt(0);
    if (rec->header.size <= FIELD_SIZE) return alloc::allocInt(0);

    // Size might be unboxed
    if ((rec->unboxed >> FIELD_SIZE) & 1) {
        return alloc::allocInt(rec->values[FIELD_SIZE].i);
    }
    return rec->values[FIELD_SIZE].p;
}

HPointer lastModified(void* file) {
    if (!file) return alloc::allocInt(0);

    Record* rec = static_cast<Record*>(file);
    if (rec->header.tag != Tag_Record) return alloc::allocInt(0);
    if (rec->header.size <= FIELD_LAST_MODIFIED) return alloc::allocInt(0);

    // lastModified might be unboxed
    if ((rec->unboxed >> FIELD_LAST_MODIFIED) & 1) {
        return alloc::allocInt(rec->values[FIELD_LAST_MODIFIED].i);
    }
    return rec->values[FIELD_LAST_MODIFIED].p;
}

// ============================================================================
// File Reading - Stubs
// ============================================================================

HPointer toString(void* file) {
    (void)file;
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer toBytes(void* file) {
    (void)file;
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer toUrl(void* file) {
    (void)file;
    assert(false && "not implemented");
    return alloc::unit();
}

// ============================================================================
// File Selection - Stubs (Browser/GUI specific)
// ============================================================================

HPointer uploadOne(void* mimeTypes) {
    (void)mimeTypes;
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer uploadOneOrMore(void* mimeTypes) {
    (void)mimeTypes;
    assert(false && "not implemented");
    return alloc::unit();
}

// ============================================================================
// File Downloading - Stubs
// ============================================================================

HPointer download(void* fileName, void* mimeType, void* content) {
    (void)fileName;
    (void)mimeType;
    (void)content;
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer downloadUrl(void* fileName, void* url) {
    (void)fileName;
    (void)url;
    assert(false && "not implemented");
    return alloc::unit();
}

} // namespace Elm::Kernel::File
