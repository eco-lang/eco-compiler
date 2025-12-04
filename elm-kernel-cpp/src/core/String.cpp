#include "String.hpp"
#include <stdexcept>

namespace Elm::Kernel::String {

size_t length(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.length not implemented");
}

std::u16string append(const std::u16string& a, const std::u16string& b) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.append not implemented");
}

std::u16string cons(char32_t c, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.cons not implemented");
}

Value* uncons(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.uncons not implemented");
}

std::u16string fromList(List* chars) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.fromList not implemented");
}

std::u16string map(std::function<char32_t(char32_t)> func, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.map not implemented");
}

std::u16string filter(std::function<bool(char32_t)> pred, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.filter not implemented");
}

Value* foldl(std::function<Value*(char32_t, Value*)> func, Value* acc, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.foldl not implemented");
}

Value* foldr(std::function<Value*(char32_t, Value*)> func, Value* acc, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.foldr not implemented");
}

bool any(std::function<bool(char32_t)> pred, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.any not implemented");
}

bool all(std::function<bool(char32_t)> pred, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.all not implemented");
}

std::u16string reverse(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.reverse not implemented");
}

std::u16string slice(int start, int end, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.slice not implemented");
}

List* split(const std::u16string& sep, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.split not implemented");
}

std::u16string join(const std::u16string& sep, List* strings) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.join not implemented");
}

List* lines(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.lines not implemented");
}

List* words(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.words not implemented");
}

std::u16string trim(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.trim not implemented");
}

std::u16string trimLeft(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.trimLeft not implemented");
}

std::u16string trimRight(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.trimRight not implemented");
}

bool startsWith(const std::u16string& prefix, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.startsWith not implemented");
}

bool endsWith(const std::u16string& suffix, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.endsWith not implemented");
}

bool contains(const std::u16string& sub, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.contains not implemented");
}

List* indexes(const std::u16string& sub, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.indexes not implemented");
}

std::u16string toLower(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.toLower not implemented");
}

std::u16string toUpper(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.toUpper not implemented");
}

Value* toInt(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.toInt not implemented");
}

Value* toFloat(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.toFloat not implemented");
}

std::u16string fromNumber(double n) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.String.fromNumber not implemented");
}

} // namespace Elm::Kernel::String
