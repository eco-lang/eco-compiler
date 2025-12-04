#include "Bytes.hpp"
#include <stdexcept>

namespace Elm::Kernel::Bytes {

size_t width(Bytes* bytes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.width not implemented");
}

Value* getHostEndianness() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.getHostEndianness not implemented");
}

size_t getStringWidth(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.getStringWidth not implemented");
}

Value* decode(Decoder* decoder, Bytes* bytes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.decode not implemented");
}

Value* decodeFailure() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.decodeFailure not implemented");
}

Bytes* encode(Encoder* encoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.encode not implemented");
}

Value* read_i8(Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_i8 not implemented");
}

Value* read_i16(bool littleEndian, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_i16 not implemented");
}

Value* read_i32(bool littleEndian, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_i32 not implemented");
}

Value* read_u8(Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_u8 not implemented");
}

Value* read_u16(bool littleEndian, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_u16 not implemented");
}

Value* read_u32(bool littleEndian, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_u32 not implemented");
}

Value* read_f32(bool littleEndian, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_f32 not implemented");
}

Value* read_f64(bool littleEndian, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_f64 not implemented");
}

Value* read_bytes(size_t length, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_bytes not implemented");
}

Value* read_string(size_t length, Bytes* bytes, size_t offset) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_string not implemented");
}

Encoder* write_i8(int8_t value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_i8 not implemented");
}

Encoder* write_i16(bool littleEndian, int16_t value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_i16 not implemented");
}

Encoder* write_i32(bool littleEndian, int32_t value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_i32 not implemented");
}

Encoder* write_u8(uint8_t value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_u8 not implemented");
}

Encoder* write_u16(bool littleEndian, uint16_t value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_u16 not implemented");
}

Encoder* write_u32(bool littleEndian, uint32_t value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_u32 not implemented");
}

Encoder* write_f32(bool littleEndian, float value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_f32 not implemented");
}

Encoder* write_f64(bool littleEndian, double value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_f64 not implemented");
}

Encoder* write_bytes(Bytes* bytes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_bytes not implemented");
}

Encoder* write_string(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_string not implemented");
}

} // namespace Elm::Kernel::Bytes
