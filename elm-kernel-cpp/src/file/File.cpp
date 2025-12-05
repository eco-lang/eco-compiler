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

TaskPtr toString(void* file) {
    (void)file;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return empty string
        callback(alloc::emptyString());
        return []() {};
    });
}

TaskPtr toBytes(void* file) {
    (void)file;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return empty bytes
        callback(BytesOps::empty());
        return []() {};
    });
}

TaskPtr toUrl(void* file) {
    (void)file;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return empty data URL
        HPointer result = alloc::allocStringFromUTF8("data:;base64,");
        callback(result);
        return []() {};
    });
}

// ============================================================================
// File Selection - Stubs (Browser/GUI specific)
// ============================================================================

TaskPtr uploadOne(void* mimeTypes) {
    (void)mimeTypes;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return Nothing (no file selected)
        callback(alloc::nothing());
        return []() {};
    });
}

TaskPtr uploadOneOrMore(void* mimeTypes) {
    (void)mimeTypes;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return Nothing (no files selected)
        callback(alloc::nothing());
        return []() {};
    });
}

// ============================================================================
// File Downloading - Stubs
// ============================================================================

TaskPtr download(void* fileName, void* mimeType, void* content) {
    (void)fileName;
    (void)mimeType;
    (void)content;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return unit
        callback(alloc::unit());
        return []() {};
    });
}

TaskPtr downloadUrl(void* fileName, void* url) {
    (void)fileName;
    (void)url;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Stub - return unit
        callback(alloc::unit());
        return []() {};
    });
}

} // namespace Elm::Kernel::File
