#ifndef ECO_JSON_HPP
#define ECO_JSON_HPP

/**
 * Elm Kernel Json Module - Minimal header for dependent stubs.
 *
 * The actual JSON implementation lives entirely in JsonExports.cpp.
 * This header only provides type aliases needed by other stub modules
 * (Browser, VirtualDom, File) that reference Json::DecoderPtr.
 */

#include "allocator/Heap.hpp"
#include <memory>

namespace Elm::Kernel::Json {

// Opaque decoder type used by dependent stub headers.
struct Decoder;
using DecoderPtr = std::shared_ptr<Decoder>;

} // namespace Elm::Kernel::Json

#endif // ECO_JSON_HPP
