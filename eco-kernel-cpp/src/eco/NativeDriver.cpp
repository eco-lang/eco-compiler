//===- NativeDriver.cpp - Eco kernel module impl --------------------------===//

#include "NativeDriver.hpp"
#include "KernelHelpers.hpp"

#include "../../../runtime/src/allocator/Allocator.hpp"
#include "../../../runtime/src/allocator/Heap.hpp"
#include "../../../runtime/src/allocator/HeapHelpers.hpp"

#include <string>

namespace Eco::Kernel::NativeDriver {

// Strong external declarations — the symbols are guaranteed to exist at
// link time because EcoEntryStatic ships weak stub definitions (see
// eco_native_stub.cpp). When EcoNativeDriverStatic is also linked in (as
// it is for the unified `eco` binary), its strong definitions override
// the weak stubs and lowering happens in-process; otherwise the stubs
// return -1 and we surface a Task failure.
extern "C" {
int eco_native_lower_and_link(const char *mlirPath, const char *outputPath);
int eco_native_lower_and_link_bytes(const char *bytes, size_t len,
                                     const char *outputPath);
}

uint64_t lowerAndLink(uint64_t mlirPath, uint64_t outputPath) {
    std::string mp = toString(mlirPath);
    std::string op = toString(outputPath);
    int rc = eco_native_lower_and_link(mp.c_str(), op.c_str());
    if (rc != 0) {
        return taskFailString(
            "Eco.NativeDriver.lowerAndLink: lowering/linking failed "
            "(rc=" + std::to_string(rc) + ")");
    }
    return taskSucceedUnit();
}

uint64_t lowerAndLinkBytes(uint64_t bytes, uint64_t outputPath) {
    HPointer h = Export::decode(bytes);
    void *ptr = Elm::Allocator::instance().resolve(h);
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t *data = Elm::alloc::byteBufferData(ptr);
    std::string op = toString(outputPath);

    int rc = eco_native_lower_and_link_bytes(
        reinterpret_cast<const char *>(data), len, op.c_str());
    if (rc != 0) {
        return taskFailString(
            "Eco.NativeDriver.lowerAndLinkBytes: lowering/linking failed "
            "(rc=" + std::to_string(rc) + ")");
    }
    return taskSucceedUnit();
}

} // namespace Eco::Kernel::NativeDriver
