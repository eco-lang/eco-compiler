#include "Parser.hpp"
#include <stdexcept>

namespace Elm::Kernel::Parser {

bool isAsciiCode(uint16_t code, size_t offset, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.isAsciiCode not implemented");
}

int isSubChar(uint16_t (*predicate)(uint16_t), size_t offset, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.isSubChar not implemented");
}

Value* isSubString(const std::u16string& sub, size_t offset, size_t row, size_t col, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.isSubString not implemented");
}

Value* findSubString(const std::u16string& sub, size_t offset, size_t row, size_t col, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.findSubString not implemented");
}

Value* consumeBase(int base, size_t offset, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.consumeBase not implemented");
}

Value* consumeBase16(size_t offset, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.consumeBase16 not implemented");
}

Value* chompBase10(size_t offset, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Parser.chompBase10 not implemented");
}

} // namespace Elm::Kernel::Parser
