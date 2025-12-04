#include "Json.hpp"
#include <stdexcept>

namespace Elm::Kernel::Json {

Decoder* decodeString() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeString not implemented");
}

Decoder* decodeBool() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeBool not implemented");
}

Decoder* decodeInt() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeInt not implemented");
}

Decoder* decodeFloat() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeFloat not implemented");
}

Decoder* decodeNull(Value* fallback) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeNull not implemented");
}

Decoder* decodeList(Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeList not implemented");
}

Decoder* decodeArray(Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeArray not implemented");
}

Decoder* decodeField(const std::u16string& field, Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeField not implemented");
}

Decoder* decodeIndex(int index, Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeIndex not implemented");
}

Decoder* decodeKeyValuePairs(Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeKeyValuePairs not implemented");
}

Decoder* decodeValue() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.decodeValue not implemented");
}

Decoder* map1(std::function<Value*(Value*)> func, Decoder* d1) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map1 not implemented");
}

Decoder* map2(std::function<Value*(Value*, Value*)> func, Decoder* d1, Decoder* d2) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map2 not implemented");
}

Decoder* map3(std::function<Value*(Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map3 not implemented");
}

Decoder* map4(std::function<Value*(Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map4 not implemented");
}

Decoder* map5(std::function<Value*(Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map5 not implemented");
}

Decoder* map6(std::function<Value*(Value*, Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5, Decoder* d6) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map6 not implemented");
}

Decoder* map7(std::function<Value*(Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5, Decoder* d6, Decoder* d7) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map7 not implemented");
}

Decoder* map8(std::function<Value*(Value*, Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Decoder* d1, Decoder* d2, Decoder* d3, Decoder* d4, Decoder* d5, Decoder* d6, Decoder* d7, Decoder* d8) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.map8 not implemented");
}

Decoder* andThen(std::function<Decoder*(Value*)> callback, Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.andThen not implemented");
}

Decoder* oneOf(List* decoders) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.oneOf not implemented");
}

Decoder* succeed(Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.succeed not implemented");
}

Decoder* fail(const std::u16string& message) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.fail not implemented");
}

Value* run(Decoder* decoder, JsonValue* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.run not implemented");
}

Value* runOnString(Decoder* decoder, const std::u16string& jsonString) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.runOnString not implemented");
}

std::u16string encode(int indent, JsonValue* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.encode not implemented");
}

JsonValue* wrap(Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.wrap not implemented");
}

JsonValue* encodeNull() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.encodeNull not implemented");
}

JsonValue* emptyArray() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.emptyArray not implemented");
}

JsonValue* emptyObject() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.emptyObject not implemented");
}

JsonValue* addEntry(std::function<JsonValue*(Value*)> func, Value* entry, JsonValue* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.addEntry not implemented");
}

JsonValue* addField(const std::u16string& key, JsonValue* value, JsonValue* object) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Json.addField not implemented");
}

} // namespace Elm::Kernel::Json
