//===- BitwiseExports.cpp - C-linkage exports for Bitwise module -----------===//

#include "../KernelExports.h"
#include "Bitwise.hpp"

using namespace Elm::Kernel;

extern "C" {

int32_t Elm_Kernel_Bitwise_and(int32_t a, int32_t b) {
    return Bitwise::and_(a, b);
}

int32_t Elm_Kernel_Bitwise_or(int32_t a, int32_t b) {
    return Bitwise::or_(a, b);
}

int32_t Elm_Kernel_Bitwise_xor(int32_t a, int32_t b) {
    return Bitwise::xor_(a, b);
}

int32_t Elm_Kernel_Bitwise_complement(int32_t a) {
    return Bitwise::complement(a);
}

int32_t Elm_Kernel_Bitwise_shiftLeftBy(int32_t offset, int32_t a) {
    return Bitwise::shiftLeftBy(offset, a);
}

int32_t Elm_Kernel_Bitwise_shiftRightBy(int32_t offset, int32_t a) {
    return Bitwise::shiftRightBy(offset, a);
}

uint32_t Elm_Kernel_Bitwise_shiftRightZfBy(int32_t offset, int32_t a) {
    return Bitwise::shiftRightZfBy(offset, a);
}

} // extern "C"
