//===- BytesExports.cpp - C-linkage exports for Bytes module (STUBS) -------===//
//
// These are stub implementations that will crash if called.
// Full implementation requires a proper Bytes type in the runtime.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include <cassert>
#include <cstdint>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Bytes_width(uint64_t bytes) {
    (void)bytes;
    assert(false && "Elm_Kernel_Bytes_width not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_getHostEndianness() {
    // This one we can actually implement - detect host endianness.
    // Return 0 for little-endian, 1 for big-endian.
    uint16_t test = 1;
    bool isLittleEndian = (*reinterpret_cast<uint8_t*>(&test) == 1);
    return isLittleEndian ? 0 : 1;
}

int64_t Elm_Kernel_Bytes_getStringWidth(uint64_t str) {
    (void)str;
    assert(false && "Elm_Kernel_Bytes_getStringWidth not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_encode(uint64_t encoder) {
    (void)encoder;
    assert(false && "Elm_Kernel_Bytes_encode not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_decode(uint64_t decoder, uint64_t bytes) {
    (void)decoder;
    (void)bytes;
    assert(false && "Elm_Kernel_Bytes_decode not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_decodeFailure() {
    assert(false && "Elm_Kernel_Bytes_decodeFailure not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_i8(uint64_t bytes, int64_t offset) {
    (void)bytes;
    (void)offset;
    assert(false && "Elm_Kernel_Bytes_read_i8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_i16(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_i16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_i32(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_i32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_u8(uint64_t bytes, int64_t offset) {
    (void)bytes;
    (void)offset;
    assert(false && "Elm_Kernel_Bytes_read_u8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_u16(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_u16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_u32(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_u32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_f32(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_f32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_f64(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_f64 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_bytes(uint64_t bytes, int64_t offset, int64_t length) {
    (void)bytes;
    (void)offset;
    (void)length;
    assert(false && "Elm_Kernel_Bytes_read_bytes not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_string(uint64_t bytes, int64_t offset, int64_t length) {
    (void)bytes;
    (void)offset;
    (void)length;
    assert(false && "Elm_Kernel_Bytes_read_string not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i8(int64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Bytes_write_i8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i16(int64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_i16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i32(int64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_i32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u8(uint64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Bytes_write_u8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u16(uint64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_u16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u32(uint64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_u32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_f32(double value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_f32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_f64(double value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_f64 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_bytes(uint64_t bytes) {
    (void)bytes;
    assert(false && "Elm_Kernel_Bytes_write_bytes not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_string(uint64_t str) {
    (void)str;
    assert(false && "Elm_Kernel_Bytes_write_string not implemented");
    return 0;
}

} // extern "C"
