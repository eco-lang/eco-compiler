//===- NativeDriver.cpp - Eco kernel module impl --------------------------===//
//
// The bodies run the whole lowering and link on the thread stepping the Task; nothing is handed to another thread.
//
//===----------------------------------------------------------------------===//

#include "NativeDriver.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"

#include "../../../runtime/src/allocator/Allocator.hpp"
#include "../../../runtime/src/allocator/Heap.hpp"
#include "../../../runtime/src/allocator/HeapHelpers.hpp"

#include <string>

namespace Eco::Kernel::NativeDriver {

// The driver entry points, declared here rather than by including the runtime's `codegen/EcoNativeAPI.h`, which
// owns their contracts. A definition exists in any binary built on `EcoEntryStatic` or `EcoEmbedStatic`: the weak
// stand-ins returning -1 are compiled into those, and `EcoNativeDriverStatic`'s definitions replace them when linked.
extern "C" {
int eco_native_lower_and_link(const char *mlirPath, const char *outputPath,
                              const char *rootModule);
int eco_native_lower_and_link_bytes(const char *bytes, size_t len,
                                     const char *outputPath);
}

namespace {

// Runs the file form of the driver on the `( mlirPath, outputPath, rootModule )` tuple of Strings `captured` and
// returns the Task described on `lowerAndLink`.
HPointer lowerAndLinkBody(HPointer captured) {
    HPointer mlirPathHP;
    HPointer outputPathHP;
    HPointer rootModuleHP;
    {
        Tuple3* tup = static_cast<Tuple3*>(
            Elm::Allocator::instance().resolve(captured));
        mlirPathHP = tup->a.p;
        outputPathHP = tup->b.p;
        rootModuleHP = tup->c.p;
    }
    std::string mp = toString(Export::encode(mlirPathHP));
    std::string op = toString(Export::encode(outputPathHP));
    std::string rm = toString(Export::encode(rootModuleHP));
    int rc = eco_native_lower_and_link(mp.c_str(), op.c_str(), rm.c_str());
    if (rc != 0) {
        return failString(
            "Eco.NativeDriver.lowerAndLink: lowering/linking failed "
            "(rc=" + std::to_string(rc) + ")");
    }
    return succeedUnit();
}

// Runs the in-memory form of the driver on the `( bytes, outputPath )` tuple `captured` and returns the Task
// described on `lowerAndLinkBytes`. The driver reads the bytes in place in the heap through `data`; nothing
// allocates on the Elm heap between taking that pointer and the driver's return.
HPointer lowerAndLinkBytesBody(HPointer captured) {
    HPointer bytesHP;
    HPointer outputPathHP;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        bytesHP = tup->a.p;
        outputPathHP = tup->b.p;
    }
    // The empty Bytes is an embedded constant (HEAP_014), which resolve must not see; it reads as null, length 0.
    void* ptr = Elm::alloc::resolveBytesOrNull(bytesHP);
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    std::string op = toString(Export::encode(outputPathHP));
    if (len == 0) {
        // Empty MLIR holds no program; it is rejected here rather than handed to the driver.
        return failString("Eco.NativeDriver.lowerAndLinkBytes: the MLIR is empty");
    }

    int rc = eco_native_lower_and_link_bytes(
        reinterpret_cast<const char *>(data), len, op.c_str());
    if (rc != 0) {
        return failString(
            "Eco.NativeDriver.lowerAndLinkBytes: lowering/linking failed "
            "(rc=" + std::to_string(rc) + ")");
    }
    return succeedUnit();
}

} // anonymous namespace

uint64_t lowerAndLink(uint64_t mlirPath, uint64_t outputPath,
                      uint64_t rootModule) {
    HPointer mlirPathHP = Export::decode(mlirPath);
    HPointer outputPathHP = Export::decode(outputPath);
    HPointer rootModuleHP = Export::decode(rootModule);
    Elm::StackRootGuard g(&mlirPathHP, &outputPathHP, &rootModuleHP);
    HPointer payload = Elm::alloc::tuple3(
        Elm::alloc::boxed(mlirPathHP), Elm::alloc::boxed(outputPathHP),
        Elm::alloc::boxed(rootModuleHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<lowerAndLinkBody>(payload));
}

uint64_t lowerAndLinkBytes(uint64_t bytes, uint64_t outputPath) {
    HPointer bytesHP = Export::decode(bytes);
    HPointer outputPathHP = Export::decode(outputPath);
    Elm::StackRootGuard g(&bytesHP, &outputPathHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(bytesHP), Elm::alloc::boxed(outputPathHP), 0);
    return Export::encode(
        Eco::Kernel::makeBinding<lowerAndLinkBytesBody>(payload));
}

} // namespace Eco::Kernel::NativeDriver
