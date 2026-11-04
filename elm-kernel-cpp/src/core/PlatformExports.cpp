//===- PlatformExports.cpp - C-linkage exports for Platform module ---------===//
//
// Each export decodes its arguments, then either builds a node of an effect bag or forwards to
// `PlatformRuntime` or `PortRuntime`. A bag node is a Custom whose constructor is an `FxBagTag` value and
// whose fields are all boxed: `Fx_Leaf` holds the home and the value, `Fx_Node` the list of bags, and
// `Fx_Map` the tagger and the inner bag. The registration exports return Unit.

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
    HPointer list = decode(commands_bits);
    std::vector<Unboxable> fields(1);
    fields[0].p = list;
    HPointer bag = alloc::custom(alloc::Fx_Node, fields, 0);
    return HPtr::fromBits(encode(bag));
}

HPtr Elm_Kernel_Platform_map(HPtr closure, HPtr cmd) {
    uint64_t closure_bits = closure.toBits();
    uint64_t cmd_bits = cmd.toBits();
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
    HPointer homeHP = decode(home_bits);
    HPointer valueHP = decode(value_bits);
    std::vector<Unboxable> fields(2);
    fields[0].p = homeHP;
    fields[1].p = valueHP;
    HPointer bag = alloc::custom(alloc::Fx_Leaf, fields, 0);
    return HPtr::fromBits(encode(bag));
}

// The port and flags-decoder registrations are called from the generated @__eco_register_ports preamble
// before Platform.worker runs. A port name is the bare port name; PortRuntime rejects a duplicate
// (invariant PORT_001). A name that is an embedded constant (the empty String) registers as "".

HPtr Elm_Kernel_Platform_registerIncomingPort(HPtr name, HPtr decoder) {
    HPointer nameHP = decode(name.toBits());
    HPointer decoderHP = decode(decoder.toBits());
    // The name is copied out before registerIncoming, which may collect. toStdString itself does not
    // allocate on the Elm heap.
    void* namePtr = (nameHP.ptr_ind != 0)
                        ? nullptr
                        : Allocator::instance().resolve(nameHP);
    std::string portName =
        namePtr ? Elm::StringOps::toStdString(namePtr) : std::string();
    Elm::Platform::PortRuntime::instance().registerIncoming(portName,
                                                            decoderHP);
    return HPtr::fromBits(encode(alloc::unit()));
}

// initWorker runs this decoder on the flags JSON the host supplies.
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
