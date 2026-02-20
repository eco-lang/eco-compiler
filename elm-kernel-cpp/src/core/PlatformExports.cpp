//===- PlatformExports.cpp - C-linkage exports for Platform module ---------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using Export::encode;
using Export::decode;

extern "C" {

uint64_t Elm_Kernel_Platform_batch(uint64_t commands) {
    // Create a NODE bag: Custom with ctor=Fx_Node, 1 boxed field (list of bags)
    HPointer list = decode(commands);
    std::vector<Unboxable> fields(1);
    fields[0].p = list;
    HPointer bag = alloc::custom(alloc::Fx_Node, fields, 0);
    return encode(bag);
}

uint64_t Elm_Kernel_Platform_map(uint64_t closure, uint64_t cmd) {
    // Create a MAP bag: Custom with ctor=Fx_Map, 2 boxed fields (tagger, inner bag)
    HPointer tagger = decode(closure);
    HPointer bag = decode(cmd);
    std::vector<Unboxable> fields(2);
    fields[0].p = tagger;
    fields[1].p = bag;
    HPointer mapped = alloc::custom(alloc::Fx_Map, fields, 0);
    return encode(mapped);
}

void Elm_Kernel_Platform_sendToApp(uint64_t router, uint64_t msg) {
    HPointer routerHP = decode(router);
    HPointer msgHP = decode(msg);
    Elm::Platform::PlatformRuntime::instance().sendToApp(routerHP, msgHP);
}

uint64_t Elm_Kernel_Platform_sendToSelf(uint64_t router, uint64_t msg) {
    HPointer routerHP = decode(router);
    HPointer msgHP = decode(msg);
    HPointer task = Elm::Platform::PlatformRuntime::instance().sendToSelf(routerHP, msgHP);
    return encode(task);
}

uint64_t Elm_Kernel_Platform_worker(uint64_t impl) {
    HPointer implHP = decode(impl);
    HPointer result = Elm::Platform::PlatformRuntime::instance().initWorker(implHP);
    return encode(result);
}

} // extern "C"
