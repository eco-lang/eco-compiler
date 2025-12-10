#ifndef ECO_PARSER_HPP
#define ECO_PARSER_HPP

/**
 * Elm Kernel Parser Module - Runtime Heap Integration
 *
 * Provides string parsing utilities using GC-managed heap values.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <functional>

namespace Elm::Kernel::Parser {

// Predicate function type for isSubChar
using CharPredicate = std::function<bool(u32)>;

/**
 * Check if character at offset matches ASCII code.
 */
bool isAsciiCode(u16 code, i64 offset, void* str);

/**
 * Check if character at offset satisfies predicate.
 * Returns new offset or -1 (no match) / -2 (end of string).
 */
i64 isSubChar(CharPredicate predicate, i64 offset, void* str);

/**
 * Check if substring exists at offset.
 * Returns Tuple3(newOffset, row, col).
 */
HPointer isSubString(void* sub, i64 offset, i64 row, i64 col, void* str);

/**
 * Find substring starting from offset.
 * Returns Tuple3(targetOffset, row, col).
 */
HPointer findSubString(void* sub, i64 offset, i64 row, i64 col, void* str);

/**
 * Consume characters matching a base (for number parsing).
 * Returns Tuple2(offset, total).
 */
HPointer consumeBase(i64 base, i64 offset, void* str);

/**
 * Consume hexadecimal characters.
 * Returns Tuple2(offset, total).
 */
HPointer consumeBase16(i64 offset, void* str);

/**
 * Chomp base-10 digits.
 * Returns new offset.
 */
i64 chompBase10(i64 offset, void* str);

} // namespace Elm::Kernel::Parser

#endif // ECO_PARSER_HPP
