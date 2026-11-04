// The C-linkage definitions of elm/file's kernel functions, declared in `KernelExports.h`.
//
// Every function here stands for a browser File operation that has no native counterpart. Each one asserts, and in
// a build without assertions ignores its arguments and returns 0 (the word 0 for an `HPtr` result). The one
// exception is `makeBytesSafeForInternetExplorer`, which returns its argument unchanged.

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_File_decoder() {
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
    return bytes;
}

} // extern "C"
