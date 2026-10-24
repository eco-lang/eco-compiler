#include "Bitwise.hpp"

namespace Elm::Kernel::Bitwise {

int64_t and_(int64_t a, int64_t b) {
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

int64_t or_(int64_t a, int64_t b) {
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

int64_t xor_(int64_t a, int64_t b) {
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

int64_t complement(int64_t a) {
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

int64_t shiftLeftBy(int64_t offset, int64_t a) {
    /*
     * JS: var _Bitwise_shiftLeftBy = F2(function(offset, a) { return a << offset; });
     *
     * PSEUDOCODE:
     * - Return a shifted left by (offset & 63) bits (CGEN_085: count mod 64)
     * - Note: argument order is (offset, a) to match Elm's curried style
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return static_cast<int64_t>(static_cast<uint64_t>(a) << (offset & 63));
}

int64_t shiftRightBy(int64_t offset, int64_t a) {
    /*
     * JS: var _Bitwise_shiftRightBy = F2(function(offset, a) { return a >> offset; });
     *
     * PSEUDOCODE:
     * - Return a shifted right by (offset & 63) bits (arithmetic, sign-extending; CGEN_085)
     * - Note: argument order is (offset, a) to match Elm's curried style
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return a >> (offset & 63);
}

uint64_t shiftRightZfBy(int64_t offset, int64_t a) {
    /*
     * JS: var _Bitwise_shiftRightZfBy = F2(function(offset, a) { return a >>> offset; });
     *
     * PSEUDOCODE:
     * - Return a shifted right by (offset & 63) bits (logical, zero-filling; CGEN_085)
     * - Note: argument order is (offset, a) to match Elm's curried style
     * - In C++, we cast to unsigned to get zero-fill behavior
     *
     * HELPERS: None
     * LIBRARIES: None (built-in operator)
     */
    return static_cast<uint64_t>(a) >> (offset & 63);
}

} // namespace Elm::Kernel::Bitwise
