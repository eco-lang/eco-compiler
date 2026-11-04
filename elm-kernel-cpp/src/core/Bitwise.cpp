#include "Bitwise.hpp"

namespace Elm::Kernel::Bitwise {

int64_t and_(int64_t a, int64_t b) {
    return a & b;
}

int64_t or_(int64_t a, int64_t b) {
    return a | b;
}

int64_t xor_(int64_t a, int64_t b) {
    return a ^ b;
}

int64_t complement(int64_t a) {
    return ~a;
}

int64_t shiftLeftBy(int64_t offset, int64_t a) {
    // Masking keeps the count below 64: a larger shift is undefined behaviour in C++.
    return static_cast<int64_t>(static_cast<uint64_t>(a) << (offset & 63));
}

int64_t shiftRightBy(int64_t offset, int64_t a) {
    return a >> (offset & 63);
}

uint64_t shiftRightZfBy(int64_t offset, int64_t a) {
    return static_cast<uint64_t>(a) >> (offset & 63);
}

} // namespace Elm::Kernel::Bitwise
