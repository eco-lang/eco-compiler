//===- PlatformExports.cpp - C-linkage exports for Platform module ---------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "platform/Scheduler.hpp"
#include "platform/PlatformRuntime.hpp"
#include "platform/PortRuntime.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"
#include <string>
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

// Port registration (called from the generated @__eco_register_ports
// preamble before Platform.worker runs). The name is the bare port name;
// PortRuntime enforces global uniqueness (PORT_001).

HPtr Elm_Kernel_Platform_registerIncomingPort(HPtr name, HPtr decoder) {
    HPointer nameHP = decode(name.toBits());
    HPointer decoderHP = decode(decoder.toBits());
    // Extract the name BEFORE handing decoderHP over: toStdString does not
    // allocate, but keep the order conservative anyway.
    void* namePtr = (nameHP.ptr_ind != 0)
                        ? nullptr
                        : Allocator::instance().resolve(nameHP);
    std::string portName =
        namePtr ? Elm::StringOps::toStdString(namePtr) : std::string();
    Elm::Platform::PortRuntime::instance().registerIncoming(portName,
                                                            decoderHP);
    return HPtr::fromBits(encode(alloc::unit()));
}

// Flags decoder registration (Phase 5): called from the generated
// @__eco_register_ports preamble before Platform.worker runs. The decoder
// is compiled from the root main's `Program flags model msg` type;
// initWorker runs it against the host-supplied flags JSON.
HPtr Elm_Kernel_Platform_registerFlagsDecoder(HPtr decoder) {
    HPointer decoderHP = decode(decoder.toBits());
    Elm::Platform::PlatformRuntime::instance().setFlagsDecoder(decoderHP);
    return HPtr::fromBits(encode(alloc::unit()));
}

HPtr Elm_Kernel_Platform_registerOutgoingPort(HPtr name) {
    HPointer nameHP = decode(name.toBits());
    void* namePtr = (nameHP.ptr_ind != 0)
                        ? nullptr
                        : Allocator::instance().resolve(nameHP);
    std::string portName =
        namePtr ? Elm::StringOps::toStdString(namePtr) : std::string();
    Elm::Platform::PortRuntime::instance().registerOutgoing(portName);
    return HPtr::fromBits(encode(alloc::unit()));
}

} // extern "C"
