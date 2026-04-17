//===- FileExports.cpp - C-linkage exports for File module (STUBS) ---------===//
//
// These are stub implementations that will crash if called.
// Full implementation requires browser/platform file APIs.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_File_decoder() {
    // Returns a JSON decoder for File objects.
    assert(false && "Elm_Kernel_File_decoder not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_name(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_name not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_mime(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_mime not implemented");
    return HPtr::fromBits(0);
}

int64_t Elm_Kernel_File_size(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_size not implemented");
    return 0;
}

int64_t Elm_Kernel_File_lastModified(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_lastModified not implemented");
    return 0;
}

HPtr Elm_Kernel_File_toString(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_toString not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_toBytes(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_toBytes not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_toUrl(HPtr file) {
    (void)file;
    assert(false && "Elm_Kernel_File_toUrl not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_download(HPtr name, HPtr mime, HPtr content) {
    (void)name;
    (void)mime;
    (void)content;
    assert(false && "Elm_Kernel_File_download not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_downloadUrl(HPtr name, HPtr url) {
    (void)name;
    (void)url;
    assert(false && "Elm_Kernel_File_downloadUrl not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_uploadOne(HPtr mimes) {
    (void)mimes;
    assert(false && "Elm_Kernel_File_uploadOne not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_uploadOneOrMore(HPtr mimes) {
    (void)mimes;
    assert(false && "Elm_Kernel_File_uploadOneOrMore not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_File_makeBytesSafeForInternetExplorer(HPtr bytes) {
    // This is an IE-specific workaround that's probably not needed.
    // Just return the bytes unchanged.
    return bytes;
}

} // extern "C"
