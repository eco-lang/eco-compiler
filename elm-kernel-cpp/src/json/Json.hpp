#ifndef ELM_KERNEL_JSON_HPP
#define ELM_KERNEL_JSON_HPP

/**
 * Elm Kernel Json Module - Runtime Heap Integration
 *
 * Provides JSON encoding/decoding using GC-managed heap values.
 * Note: This is a stub - full implementation requires JSON parser.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <functional>
#include <memory>

namespace Elm::Kernel::Json {

// Forward declarations
struct JsonValue;
struct Decoder;

using JsonValuePtr = std::shared_ptr<JsonValue>;
using DecoderPtr = std::shared_ptr<Decoder>;

// JSON value types
enum class JsonType { Null, Bool, Int, Float, String, Array, Object };

// Decoder callback types
using AndThenCallback = std::function<DecoderPtr(HPointer)>;
using MapFn = std::function<HPointer(std::vector<HPointer>&)>;

// ============================================================================
// Primitive Decoders
// ============================================================================

DecoderPtr decodeString();
DecoderPtr decodeBool();
DecoderPtr decodeInt();
DecoderPtr decodeFloat();
DecoderPtr decodeNull(HPointer fallback);

// ============================================================================
// Collection Decoders
// ============================================================================

DecoderPtr decodeList(DecoderPtr decoder);
DecoderPtr decodeArray(DecoderPtr decoder);
DecoderPtr decodeField(void* fieldName, DecoderPtr decoder);
DecoderPtr decodeIndex(i64 index, DecoderPtr decoder);
DecoderPtr decodeKeyValuePairs(DecoderPtr decoder);
DecoderPtr decodeValue();

// ============================================================================
// Decoder Combinators
// ============================================================================

DecoderPtr succeed(HPointer value);
DecoderPtr fail(void* message);
DecoderPtr andThen(AndThenCallback callback, DecoderPtr decoder);
DecoderPtr oneOf(HPointer decoders);

// ============================================================================
// Running Decoders
// ============================================================================

/**
 * Run decoder on JSON value.
 * Returns Result (Ok value | Err error).
 */
HPointer run(DecoderPtr decoder, JsonValuePtr value);

/**
 * Run decoder on JSON string.
 * Returns Result (Ok value | Err error).
 */
HPointer runOnString(DecoderPtr decoder, void* jsonString);

// ============================================================================
// Encoding
// ============================================================================

/**
 * Encode JSON value to string with indentation.
 */
HPointer encode(i64 indent, JsonValuePtr value);

/**
 * Wrap an Elm value as JSON.
 */
JsonValuePtr wrap(HPointer value);

/**
 * Create JSON null.
 */
JsonValuePtr encodeNull();

/**
 * Create empty JSON array.
 */
JsonValuePtr emptyArray();

/**
 * Create empty JSON object.
 */
JsonValuePtr emptyObject();

// ============================================================================
// Parsing
// ============================================================================

/**
 * Parse JSON string to JsonValue.
 * Returns nullptr on parse error.
 */
JsonValuePtr parse(void* jsonString);

} // namespace Elm::Kernel::Json

#endif // ELM_KERNEL_JSON_HPP
