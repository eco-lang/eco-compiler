#include "Bitwise.hpp"

namespace Elm::Kernel::Bitwise {

int32_t and_(int32_t a, int32_t b) {
    /*
     * JS: var _Bitwise_and = F2(function(a, b) { return a & b; });
     *
     * PSEUDOCODE:
     * - Return bitwise AND of a and b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a & b;
}

int32_t or_(int32_t a, int32_t b) {
    /*
     * JS: var _Bitwise_or = F2(function(a, b) { return a | b; });
     *
     * PSEUDOCODE:
     * - Return bitwise OR of a and b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a | b;
}

int32_t xor_(int32_t a, int32_t b) {
    /*
     * JS: var _Bitwise_xor = F2(function(a, b) { return a ^ b; });
     *
     * PSEUDOCODE:
     * - Return bitwise XOR of a and b
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a ^ b;
}

int32_t complement(int32_t a) {
    /*
     * JS: function _Bitwise_complement(a) { return ~a; }
     *
     * PSEUDOCODE:
     * - Return bitwise complement (NOT) of a
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return ~a;
}

int32_t shiftLeftBy(int32_t offset, int32_t a) {
    /*
     * JS: var _Bitwise_shiftLeftBy = F2(function(offset, a) { return a << offset; });
     *
     * PSEUDOCODE:
     * - Return a shifted left by offset bits
     * - Note: argument order is (offset, a) to match Elm's curried style
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a << offset;
}

int32_t shiftRightBy(int32_t offset, int32_t a) {
    /*
     * JS: var _Bitwise_shiftRightBy = F2(function(offset, a) { return a >> offset; });
     *
     * PSEUDOCODE:
     * - Return a shifted right by offset bits (arithmetic shift, sign-extending)
     * - Note: argument order is (offset, a) to match Elm's curried style
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a >> offset;
}

uint32_t shiftRightZfBy(int32_t offset, int32_t a) {
    /*
     * JS: var _Bitwise_shiftRightZfBy = F2(function(offset, a) { return a >>> offset; });
     *
     * PSEUDOCODE:
     * - Return a shifted right by offset bits (logical shift, zero-filling)
     * - Note: argument order is (offset, a) to match Elm's curried style
     * - In C++, we cast to unsigned to get zero-fill behavior
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return static_cast<uint32_t>(a) >> offset;
}

} // namespace Elm::Kernel::Bitwise
