#ifndef ECO_JSON_HPP
#define ECO_JSON_HPP

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
// Map Functions (for combining decoders)
// ============================================================================

using Map1Fn = std::function<HPointer(HPointer)>;
using Map2Fn = std::function<HPointer(HPointer, HPointer)>;
using Map3Fn = std::function<HPointer(HPointer, HPointer, HPointer)>;
using Map4Fn = std::function<HPointer(HPointer, HPointer, HPointer, HPointer)>;
using Map5Fn = std::function<HPointer(HPointer, HPointer, HPointer, HPointer, HPointer)>;
using Map6Fn = std::function<HPointer(HPointer, HPointer, HPointer, HPointer, HPointer, HPointer)>;
using Map7Fn = std::function<HPointer(HPointer, HPointer, HPointer, HPointer, HPointer, HPointer, HPointer)>;
using Map8Fn = std::function<HPointer(HPointer, HPointer, HPointer, HPointer, HPointer, HPointer, HPointer, HPointer)>;

DecoderPtr map1(Map1Fn f, DecoderPtr d1);
DecoderPtr map2(Map2Fn f, DecoderPtr d1, DecoderPtr d2);
DecoderPtr map3(Map3Fn f, DecoderPtr d1, DecoderPtr d2, DecoderPtr d3);
DecoderPtr map4(Map4Fn f, DecoderPtr d1, DecoderPtr d2, DecoderPtr d3, DecoderPtr d4);
DecoderPtr map5(Map5Fn f, DecoderPtr d1, DecoderPtr d2, DecoderPtr d3, DecoderPtr d4, DecoderPtr d5);
DecoderPtr map6(Map6Fn f, DecoderPtr d1, DecoderPtr d2, DecoderPtr d3, DecoderPtr d4, DecoderPtr d5, DecoderPtr d6);
DecoderPtr map7(Map7Fn f, DecoderPtr d1, DecoderPtr d2, DecoderPtr d3, DecoderPtr d4, DecoderPtr d5, DecoderPtr d6, DecoderPtr d7);
DecoderPtr map8(Map8Fn f, DecoderPtr d1, DecoderPtr d2, DecoderPtr d3, DecoderPtr d4, DecoderPtr d5, DecoderPtr d6, DecoderPtr d7, DecoderPtr d8);

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

/**
 * Add entry to JSON array.
 */
JsonValuePtr addEntry(JsonValuePtr entry, JsonValuePtr array);

/**
 * Add field to JSON object.
 */
JsonValuePtr addField(void* key, JsonValuePtr value, JsonValuePtr object);

} // namespace Elm::Kernel::Json

#endif // ECO_JSON_HPP
