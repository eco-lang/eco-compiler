//===- StringExports.cpp - C-linkage exports for String module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "String.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

int64_t Elm_Kernel_String_length(uint64_t str) {
    return String::length(Export::toPtr(str));
}

uint64_t Elm_Kernel_String_append(uint64_t a, uint64_t b) {
    HPointer result = String::append(Export::toPtr(a), Export::toPtr(b));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_join(uint64_t sep, uint64_t stringList) {
    HPointer result = String::join(Export::toPtr(sep), Export::decode(stringList));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_cons(uint16_t c, uint64_t str) {
    HPointer result = String::cons(c, Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_uncons(uint64_t str) {
    HPointer result = String::uncons(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_fromList(uint64_t chars) {
    HPointer result = String::fromList(Export::decode(chars));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_slice(int64_t start, int64_t end, uint64_t str) {
    HPointer result = String::slice(start, end, Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_split(uint64_t sep, uint64_t str) {
    HPointer result = String::split(Export::toPtr(sep), Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_lines(uint64_t str) {
    HPointer result = String::lines(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_words(uint64_t str) {
    HPointer result = String::words(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_reverse(uint64_t str) {
    HPointer result = String::reverse(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toUpper(uint64_t str) {
    HPointer result = String::toUpper(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toLower(uint64_t str) {
    HPointer result = String::toLower(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_trim(uint64_t str) {
    HPointer result = String::trim(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_trimLeft(uint64_t str) {
    HPointer result = String::trimLeft(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_trimRight(uint64_t str) {
    HPointer result = String::trimRight(Export::toPtr(str));
    return Export::encode(result);
}

bool Elm_Kernel_String_startsWith(uint64_t prefix, uint64_t str) {
    return String::startsWith(Export::toPtr(prefix), Export::toPtr(str));
}

bool Elm_Kernel_String_endsWith(uint64_t suffix, uint64_t str) {
    return String::endsWith(Export::toPtr(suffix), Export::toPtr(str));
}

bool Elm_Kernel_String_contains(uint64_t needle, uint64_t haystack) {
    return String::contains(Export::toPtr(needle), Export::toPtr(haystack));
}

uint64_t Elm_Kernel_String_indexes(uint64_t needle, uint64_t haystack) {
    HPointer result = String::indexes(Export::toPtr(needle), Export::toPtr(haystack));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toInt(uint64_t str) {
    HPointer result = String::toInt(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toFloat(uint64_t str) {
    HPointer result = String::toFloat(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_fromNumber(uint64_t n) {
    HPointer result = String::fromNumber(Export::toPtr(n));
    return Export::encode(result);
}

} // extern "C"
