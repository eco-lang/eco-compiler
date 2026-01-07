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

uint64_t Elm_Kernel_File_decoder() {
    // Returns a JSON decoder for File objects.
    assert(false && "Elm_Kernel_File_decoder not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_name(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_name not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_mime(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_mime not implemented");
    return 0;
}

int64_t Elm_Kernel_File_size(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_size not implemented");
    return 0;
}

int64_t Elm_Kernel_File_lastModified(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_lastModified not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_toString(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_toString not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_toBytes(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_toBytes not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_toUrl(uint64_t file) {
    (void)file;
    assert(false && "Elm_Kernel_File_toUrl not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_download(uint64_t name, uint64_t mime, uint64_t content) {
    (void)name;
    (void)mime;
    (void)content;
    assert(false && "Elm_Kernel_File_download not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_downloadUrl(uint64_t name, uint64_t url) {
    (void)name;
    (void)url;
    assert(false && "Elm_Kernel_File_downloadUrl not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_uploadOne(uint64_t mimes) {
    (void)mimes;
    assert(false && "Elm_Kernel_File_uploadOne not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_uploadOneOrMore(uint64_t mimes) {
    (void)mimes;
    assert(false && "Elm_Kernel_File_uploadOneOrMore not implemented");
    return 0;
}

uint64_t Elm_Kernel_File_makeBytesSafeForInternetExplorer(uint64_t bytes) {
    // This is an IE-specific workaround that's probably not needed.
    // Just return the bytes unchanged.
    return bytes;
}

} // extern "C"
