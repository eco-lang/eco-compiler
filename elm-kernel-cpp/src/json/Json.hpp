#ifndef ECO_JSON_HPP
#define ECO_JSON_HPP

// A name for a decoder that the C++ APIs of other kernel modules can use in their signatures.
//
// elm/json itself is implemented by the kernel `Json` exports, and there a decoder is a value
// on the GC heap, not a C++ object. This header declares nothing about those. It declares only
// `DecoderPtr`, which `browser/Browser` and `file/File` use in functions that are stubs.

#include "allocator/Heap.hpp"
#include <memory>

namespace Elm::Kernel::Json {

/// A decoder type that is declared and never defined, so no `Decoder` object can exist.
struct Decoder;

/// A shared pointer to a `Decoder`. No `Decoder` can be created, so a `DecoderPtr` never owns one.
using DecoderPtr = std::shared_ptr<Decoder>;

} // namespace Elm::Kernel::Json

#endif // ECO_JSON_HPP
