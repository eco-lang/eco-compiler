//===- NativeDriver.cpp - Eco kernel module impl --------------------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 6: `lowerAndLink` and `lowerAndLinkBytes` are returned as
// Task_Bindings. The MLIR→LLVM→linker pipeline still runs on the scheduler
// thread (LLVM / linker stacks aren't obviously thread-safe), but now at
// scheduler-step time rather than kernel-call time, matching the
// KERNEL_TASK_IO_001 invariant.
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

// Strong external declarations — the symbols are guaranteed to exist at
// link time because EcoEntryStatic ships weak stub definitions (see
// eco_native_stub.cpp). When EcoNativeDriverStatic is also linked in (as
// it is for the unified `eco` binary), its strong definitions override
// the weak stubs and lowering happens in-process; otherwise the stubs
// return -1 and we surface a Task failure.
extern "C" {
int eco_native_lower_and_link(const char *mlirPath, const char *outputPath,
                              const char *rootModule);
int eco_native_lower_and_link_bytes(const char *bytes, size_t len,
                                     const char *outputPath);
}

namespace {

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

HPointer lowerAndLinkBytesBody(HPointer captured) {
    HPointer bytesHP;
    HPointer outputPathHP;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        bytesHP = tup->a.p;
        outputPathHP = tup->b.p;
    }
    void* ptr = Elm::Allocator::instance().resolve(bytesHP);
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    std::string op = toString(Export::encode(outputPathHP));

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
