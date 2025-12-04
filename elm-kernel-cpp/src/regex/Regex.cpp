#include "Regex.hpp"
#include <stdexcept>

namespace Elm::Kernel::Regex {

Regex* never() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Regex.never not implemented");
}

Value* fromStringWith(const std::u16string& pattern, bool caseInsensitive, bool multiline) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Regex.fromStringWith not implemented");
}

bool contains(Regex* regex, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Regex.contains not implemented");
}

List* findAtMost(int n, Regex* regex, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Regex.findAtMost not implemented");
}

std::u16string replaceAtMost(int n, Regex* regex, std::function<std::u16string(Value*)> replacer, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Regex.replaceAtMost not implemented");
}

List* splitAtMost(int n, Regex* regex, const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Regex.splitAtMost not implemented");
}

} // namespace Elm::Kernel::Regex
