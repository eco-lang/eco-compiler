#ifndef ELM_KERNEL_BYTES_HPP
#define ELM_KERNEL_BYTES_HPP

#include <cstdint>
#include <cstddef>
#include <string>

namespace Elm::Kernel::Bytes {

// Forward declarations
struct Value;
struct Bytes;
struct Decoder;
struct Encoder;

// Get width of bytes
size_t width(Bytes* bytes);

// Get host machine endianness
Value* getHostEndianness();

// Get width needed for a string in bytes
size_t getStringWidth(const std::u16string& str);

// Decode bytes with a decoder
Value* decode(Decoder* decoder, Bytes* bytes);

// Indicate decode failure
Value* decodeFailure();

// Encode to bytes
Bytes* encode(Encoder* encoder);

// Read operations (all return pair of (value, offset))
Value* read_i8(Bytes* bytes, size_t offset);
Value* read_i16(bool littleEndian, Bytes* bytes, size_t offset);
Value* read_i32(bool littleEndian, Bytes* bytes, size_t offset);
Value* read_u8(Bytes* bytes, size_t offset);
Value* read_u16(bool littleEndian, Bytes* bytes, size_t offset);
Value* read_u32(bool littleEndian, Bytes* bytes, size_t offset);
Value* read_f32(bool littleEndian, Bytes* bytes, size_t offset);
Value* read_f64(bool littleEndian, Bytes* bytes, size_t offset);
Value* read_bytes(size_t length, Bytes* bytes, size_t offset);
Value* read_string(size_t length, Bytes* bytes, size_t offset);

// Write operations (all return encoder)
Encoder* write_i8(int8_t value);
Encoder* write_i16(bool littleEndian, int16_t value);
Encoder* write_i32(bool littleEndian, int32_t value);
Encoder* write_u8(uint8_t value);
Encoder* write_u16(bool littleEndian, uint16_t value);
Encoder* write_u32(bool littleEndian, uint32_t value);
Encoder* write_f32(bool littleEndian, float value);
Encoder* write_f64(bool littleEndian, double value);
Encoder* write_bytes(Bytes* bytes);
Encoder* write_string(const std::u16string& str);

} // namespace Elm::Kernel::Bytes

#endif // ELM_KERNEL_BYTES_HPP
