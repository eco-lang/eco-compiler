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

HPtr Elm_Kernel_Platform_batch(HPtr commands) {
    uint64_t commands_bits = commands.toBits();
    // Create a NODE bag: Custom with ctor=Fx_Node, 1 boxed field (list of bags)
    HPointer list = decode(commands_bits);
    std::vector<Unboxable> fields(1);
    fields[0].p = list;
    HPointer bag = alloc::custom(alloc::Fx_Node, fields, 0);
    return HPtr::fromBits(encode(bag));
}

HPtr Elm_Kernel_Platform_map(HPtr closure, HPtr cmd) {
    uint64_t closure_bits = closure.toBits();
    uint64_t cmd_bits = cmd.toBits();
    // Create a MAP bag: Custom with ctor=Fx_Map, 2 boxed fields (tagger, inner bag)
    HPointer tagger = decode(closure_bits);
    HPointer bag = decode(cmd_bits);
    std::vector<Unboxable> fields(2);
    fields[0].p = tagger;
    fields[1].p = bag;
    HPointer mapped = alloc::custom(alloc::Fx_Map, fields, 0);
    return HPtr::fromBits(encode(mapped));
}

void Elm_Kernel_Platform_sendToApp(HPtr router, HPtr msg) {
    uint64_t router_bits = router.toBits();
    uint64_t msg_bits = msg.toBits();
    HPointer routerHP = decode(router_bits);
    HPointer msgHP = decode(msg_bits);
    Elm::Platform::PlatformRuntime::instance().sendToApp(routerHP, msgHP);
}

HPtr Elm_Kernel_Platform_sendToSelf(HPtr router, HPtr msg) {
    uint64_t router_bits = router.toBits();
    uint64_t msg_bits = msg.toBits();
    HPointer routerHP = decode(router_bits);
    HPointer msgHP = decode(msg_bits);
    HPointer task = Elm::Platform::PlatformRuntime::instance().sendToSelf(routerHP, msgHP);
    return HPtr::fromBits(encode(task));
}

HPtr Elm_Kernel_Platform_worker(HPtr impl) {
    uint64_t impl_bits = impl.toBits();
    HPointer implHP = decode(impl_bits);
    HPointer result = Elm::Platform::PlatformRuntime::instance().initWorker(implHP);
    return HPtr::fromBits(encode(result));
}

HPtr Elm_Kernel_Platform_leaf(HPtr home, HPtr value) {
    uint64_t home_bits = home.toBits();
    uint64_t value_bits = value.toBits();
    // Create a LEAF bag: Custom with ctor=Fx_Leaf, 2 boxed fields (home string, value)
    HPointer homeHP = decode(home_bits);
    HPointer valueHP = decode(value_bits);
    std::vector<Unboxable> fields(2);
    fields[0].p = homeHP;
    fields[1].p = valueHP;
    HPointer bag = alloc::custom(alloc::Fx_Leaf, fields, 0);
    return HPtr::fromBits(encode(bag));
}

} // extern "C"
