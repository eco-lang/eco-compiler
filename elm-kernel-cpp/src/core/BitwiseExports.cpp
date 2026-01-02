//===- BitwiseExports.cpp - C-linkage exports for Bitwise module -----------===//

#include "../KernelExports.h"
#include "Bitwise.hpp"

using namespace Elm::Kernel;

extern "C" {

int64_t Elm_Kernel_Bitwise_and(int64_t a, int64_t b) {
    return Bitwise::and_(a, b);
}

int64_t Elm_Kernel_Bitwise_or(int64_t a, int64_t b) {
    return Bitwise::or_(a, b);
}

int64_t Elm_Kernel_Bitwise_xor(int64_t a, int64_t b) {
    return Bitwise::xor_(a, b);
}

int64_t Elm_Kernel_Bitwise_complement(int64_t a) {
    return Bitwise::complement(a);
}

int64_t Elm_Kernel_Bitwise_shiftLeftBy(int64_t offset, int64_t a) {
    return Bitwise::shiftLeftBy(offset, a);
}

int64_t Elm_Kernel_Bitwise_shiftRightBy(int64_t offset, int64_t a) {
    return Bitwise::shiftRightBy(offset, a);
}

uint64_t Elm_Kernel_Bitwise_shiftRightZfBy(int64_t offset, int64_t a) {
    return Bitwise::shiftRightZfBy(offset, a);
}

} // extern "C"
