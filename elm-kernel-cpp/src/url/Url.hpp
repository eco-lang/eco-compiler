#ifndef ELM_KERNEL_URL_HPP
#define ELM_KERNEL_URL_HPP

#include <string>

namespace Elm::Kernel::Url {

// Forward declarations
struct Value;

// Percent-encode a string for URLs
std::u16string percentEncode(const std::u16string& str);

// Percent-decode a URL string (returns Maybe String)
Value* percentDecode(const std::u16string& str);

} // namespace Elm::Kernel::Url

#endif // ELM_KERNEL_URL_HPP
