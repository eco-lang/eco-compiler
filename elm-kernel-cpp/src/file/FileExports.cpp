// The C-linkage definitions of elm/file's kernel functions, declared in `KernelExports.h`.
//
// Every function here stands for a browser File operation that has no native counterpart, and none of their
// Tasks can fail. Each one therefore ends the program with "<Elm function> is not supported natively" and exit
// status 1 (`unsupportedNatively`, decision D9 of plans/kernel-lib-bug-fixes.md). The one exception is
// `makeBytesSafeForInternetExplorer`, which returns its argument unchanged.

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "../NotSupportedNatively.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_File_decoder() {
    unsupportedNatively("File.decoder");
}

HPtr Elm_Kernel_File_name(HPtr file) {
    (void)file;
    unsupportedNatively("File.name");
}

HPtr Elm_Kernel_File_mime(HPtr file) {
    (void)file;
    unsupportedNatively("File.mime");
}

int64_t Elm_Kernel_File_size(HPtr file) {
    (void)file;
    unsupportedNatively("File.size");
}

int64_t Elm_Kernel_File_lastModified(HPtr file) {
    (void)file;
    unsupportedNatively("File.lastModified");
}

HPtr Elm_Kernel_File_toString(HPtr file) {
    (void)file;
    unsupportedNatively("File.toString");
}

HPtr Elm_Kernel_File_toBytes(HPtr file) {
    (void)file;
    unsupportedNatively("File.toBytes");
}

HPtr Elm_Kernel_File_toUrl(HPtr file) {
    (void)file;
    unsupportedNatively("File.toUrl");
}

HPtr Elm_Kernel_File_download(HPtr name, HPtr mime, HPtr content) {
    (void)name;
    (void)mime;
    (void)content;
    unsupportedNatively("File.Download.string/bytes");
}

HPtr Elm_Kernel_File_downloadUrl(HPtr name, HPtr url) {
    (void)name;
    (void)url;
    unsupportedNatively("File.Download.url");
}

HPtr Elm_Kernel_File_uploadOne(HPtr mimes) {
    (void)mimes;
    unsupportedNatively("File.Select.file");
}

HPtr Elm_Kernel_File_uploadOneOrMore(HPtr mimes) {
    (void)mimes;
    unsupportedNatively("File.Select.files");
}

HPtr Elm_Kernel_File_makeBytesSafeForInternetExplorer(HPtr bytes) {
    return bytes;
}

} // extern "C"
