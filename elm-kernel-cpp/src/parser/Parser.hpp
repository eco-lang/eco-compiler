#ifndef ELM_KERNEL_PARSER_HPP
#define ELM_KERNEL_PARSER_HPP

#include <string>
#include <cstdint>

namespace Elm::Kernel::Parser {

// Forward declarations
struct Value;

// Check if character at offset matches ASCII code
bool isAsciiCode(uint16_t code, size_t offset, const std::u16string& str);

// Check if character at offset satisfies predicate, returns new offset or -1
int isSubChar(uint16_t (*predicate)(uint16_t), size_t offset, const std::u16string& str);

// Check if substring exists at offset
Value* isSubString(const std::u16string& sub, size_t offset, size_t row, size_t col, const std::u16string& str);

// Find substring starting from offset
Value* findSubString(const std::u16string& sub, size_t offset, size_t row, size_t col, const std::u16string& str);

// Consume characters matching a base (for number parsing)
Value* consumeBase(int base, size_t offset, const std::u16string& str);

// Consume hexadecimal characters
Value* consumeBase16(size_t offset, const std::u16string& str);

// Chomp base-10 digits
Value* chompBase10(size_t offset, const std::u16string& str);

} // namespace Elm::Kernel::Parser

#endif // ELM_KERNEL_PARSER_HPP
