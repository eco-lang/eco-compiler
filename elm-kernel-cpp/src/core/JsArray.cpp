#include "JsArray.hpp"
#include <stdexcept>

namespace Elm::Kernel::JsArray {

Array* empty() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.empty not implemented");
}

Array* singleton(Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.singleton not implemented");
}

size_t length(Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.length not implemented");
}

Array* initialize(size_t len, size_t offset, std::function<Value*(size_t)> func) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.initialize not implemented");
}

Array* initializeFromList(size_t max, List* list) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.initializeFromList not implemented");
}

Value* unsafeGet(size_t index, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.unsafeGet not implemented");
}

Array* unsafeSet(size_t index, Value* value, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.unsafeSet not implemented");
}

Array* push(Value* value, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.push not implemented");
}

Value* foldl(std::function<Value*(Value*, Value*)> func, Value* acc, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.foldl not implemented");
}

Value* foldr(std::function<Value*(Value*, Value*)> func, Value* acc, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.foldr not implemented");
}

Array* map(std::function<Value*(Value*)> func, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.map not implemented");
}

Array* indexedMap(std::function<Value*(size_t, Value*)> func, size_t offset, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.indexedMap not implemented");
}

Array* slice(int start, int end, Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.slice not implemented");
}

Array* appendN(size_t n, Array* dest, Array* source) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.JsArray.appendN not implemented");
}

} // namespace Elm::Kernel::JsArray
