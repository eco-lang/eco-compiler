#ifndef ELM_KERNEL_JSON_HPP
#define ELM_KERNEL_JSON_HPP

#include <string>
#include <functional>

namespace Elm::Kernel::Json {

// Forward declarations
struct Value;
struct Decoder;
struct JsonValue;
struct List;

// Decoders
Decoder* decodeString();
Decoder* decodeBool();
Decoder* decodeInt();
Decoder* decodeFloat();
Decoder* decodeNull(Value* fallback);
Decoder* decodeList(Decoder* decoder);
Decoder* decodeArray(Decoder* decoder);
Decoder* decodeField(const std::u16string& field, Decoder* decoder);
Decoder* decodeIndex(int index, Decoder* decoder);
Decoder* decodeKeyValuePairs(Decoder* decoder);
Decoder* decodeValue();

// Decoder combinators
Decoder* map1(std::function<Value*(Value*)> func, Decoder* d1);
Decoder* map2(std::function<Value*(Value*, Value*)> func, Decoder* d1, Decoder* d2);
Decoder* map3(std::function<Value*(Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3);
Decoder* map4(std::function<Value*(Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4);
Decoder* map5(std::function<Value*(Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5);
Decoder* map6(std::function<Value*(Value*, Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5, Decoder* d6);
Decoder* map7(std::function<Value*(Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5, Decoder* d6, Decoder* d7);
Decoder* map8(std::function<Value*(Value*, Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5, Decoder* d6, Decoder* d7, Decoder* d8);

Decoder* andThen(std::function<Decoder*(Value*)> callback, Decoder* decoder);
Decoder* oneOf(List* decoders);
Decoder* succeed(Value* value);
Decoder* fail(const std::u16string& message);

// Running decoders
Value* run(Decoder* decoder, JsonValue* value);
Value* runOnString(Decoder* decoder, const std::u16string& jsonString);

// Encoding
std::u16string encode(int indent, JsonValue* value);
JsonValue* wrap(Value* value);
JsonValue* encodeNull();
JsonValue* emptyArray();
JsonValue* emptyObject();
JsonValue* addEntry(std::function<JsonValue*(Value*)> func, Value* entry, JsonValue* array);
JsonValue* addField(const std::u16string& key, JsonValue* value, JsonValue* object);

} // namespace Elm::Kernel::Json

#endif // ELM_KERNEL_JSON_HPP
