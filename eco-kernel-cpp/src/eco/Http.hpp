#ifndef ECO_HTTP_HPP
#define ECO_HTTP_HPP

#include <cstdint>

namespace Eco::Kernel::Http {

uint64_t fetch(uint64_t method, uint64_t url, uint64_t headers);
uint64_t getArchive(uint64_t url);

} // namespace Eco::Kernel::Http

#endif // ECO_HTTP_HPP
