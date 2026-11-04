#ifndef ECO_FILE_HPP
#define ECO_FILE_HPP

// elm/file's Elm code calls JavaScript kernel functions for working with browser `File` objects: reading a file
// the user picked, opening a file picker, and starting a download. A native program has no browser, so none of
// these can do their job here. This component exists so that a program which uses elm/file still compiles and links.
//
// The live definitions are the `extern "C"` exports in `FileExports.cpp`, declared in `KernelExports.h`. Each one
// asserts, and in a build without assertions returns the word 0, except `makeBytesSafeForInternetExplorer`, which
// returns its argument.
//
// This header declares a second, C++ API in `Elm::Kernel::File`. It is compiled but nothing calls it, and it differs
// from the exports: its record accessors read fields, and its other functions assert and return Unit. The accessors
// assume a record of five fields numbered alphabetically. elm/file's `File` is an opaque browser object, not a
// record, so nothing natively produces that shape; and in a compiler-built record unboxed fields come first, so
// the numbering would not match one either.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../json/Json.hpp"

namespace Elm::Kernel::File {

/// Another name for `Json::DecoderPtr`, the handle to a compiled JSON decoder.
using DecoderPtr = Json::DecoderPtr;

/// Returns a null `DecoderPtr`. No decoder for File values exists natively. Unused.
DecoderPtr decoder();

/// Returns `bytes` unchanged. Unused; the export of the same name behaves the same way.
HPointer makeBytesSafeForInternetExplorer(HPointer bytes);

/// Returns the `name` field of the File record at `file`, or the empty string if `file` is null, is not a
/// `Record`, or has too few fields. Unused. `file` is read as a raw pointer to a heap object, not decoded as an
/// HPointer, and the field is read at its alphabetical slot number, not where the compiler places it.
HPointer name(void* file);

/// Returns the `mime` field of the File record at `file`, with the same fallbacks and caveats as `name`. Unused.
HPointer mime(void* file);

/// Returns the `size` field of the File record at `file`: the slot's word as is, boxed first if the slot is
/// unboxed, or a newly allocated boxed 0 for the fallbacks `name` lists. Unused, with the same slot caveat as `name`.
HPointer size(void* file);

/// Returns the `lastModified` field of the File record at `file`, as `size` does. Unused.
HPointer lastModified(void* file);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `toString`,
/// which reads a file as a String in a browser.
HPointer toString(void* file);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `toBytes`,
/// which reads a file as Bytes in a browser.
HPointer toBytes(void* file);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `toUrl`,
/// which reads a file as a data URL in a browser.
HPointer toUrl(void* file);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `uploadOne`,
/// which opens a picker for one file in a browser.
HPointer uploadOne(void* mimeTypes);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `uploadOneOrMore`,
/// which opens a picker for one or more files in a browser.
HPointer uploadOneOrMore(void* mimeTypes);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `download`,
/// which downloads `content` as a file in a browser.
HPointer download(void* fileName, void* mimeType, void* content);

/// Asserts, and in a build without assertions returns Unit. Unused. It stands for elm/file's `downloadUrl`,
/// which downloads a URL as a file in a browser.
HPointer downloadUrl(void* fileName, void* url);

} // namespace Elm::Kernel::File

#endif // ECO_FILE_HPP
