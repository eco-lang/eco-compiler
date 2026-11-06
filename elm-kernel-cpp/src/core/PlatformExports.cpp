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
#include "platform/TaskBinding.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using Export::encode;
using Export::decode;

namespace {

// Returns a copy of the port name `name`, "" for an embedded constant. Taken before a registration, which
// may collect; toStdString itself does not allocate on the Elm heap.
std::string portNameOf(HPtr name) {
    HPointer nameHP = decode(name.toBits());
    void* namePtr = (nameHP.ptr_ind != 0) ? nullptr : Allocator::instance().resolve(nameHP);
    return namePtr ? Elm::StringOps::toStdString(namePtr) : std::string();
}

// `Platform.sendToApp` and `sendToSelf` return Tasks, as in elm/core: a call builds a Task over
// `( router, msg )` and sends nothing; the message goes out each time the Task runs (KERNEL_TASK_IO_001).
// Until 2026-11-06 both sent at once, when called.

// Returns the `( router, msg )` a send Task captures. Allocates.
HPointer captureSend(HPtr router, HPtr msg) {
    Unboxable r;
    Unboxable m;
    r.p = decode(router.toBits());
    m.p = decode(msg.toBits());
    return alloc::tuple2(r, m, 0);
}

// Reads the router and the message out of a send Task's captured tuple.
void unpackSend(HPointer captured, HPointer& router, HPointer& msg) {
    Tuple2* t = static_cast<Tuple2*>(Allocator::instance().resolve(captured));
    router = t->a.p;
    msg = t->b.p;
}

// The body of a `sendToApp` Task: sends the message to the program, then succeeds with `()`.
HPointer sendToAppBody(HPointer captured) {
    HPointer router;
    HPointer msg;
    unpackSend(captured, router, msg);
    Elm::Platform::PlatformRuntime::instance().sendToApp(router, msg);
    return Elm::Platform::Scheduler::instance().taskSucceed(alloc::unit());
}

// The body of a `sendToSelf` Task: puts the message in the manager's mailbox, then succeeds with `()`.
HPointer sendToSelfBody(HPointer captured) {
    HPointer router;
    HPointer msg;
    unpackSend(captured, router, msg);
    return Elm::Platform::PlatformRuntime::instance().sendToSelf(router, msg);
}

} // namespace

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

HPtr Elm_Kernel_Platform_sendToApp(HPtr router, HPtr msg) {
    HPointer captured = captureSend(router, msg);
    return HPtr::fromBits(encode(Elm::Platform::makeBinding<sendToAppBody>(captured)));
}

HPtr Elm_Kernel_Platform_sendToSelf(HPtr router, HPtr msg) {
    HPointer captured = captureSend(router, msg);
    return HPtr::fromBits(encode(Elm::Platform::makeBinding<sendToSelfBody>(captured)));
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

HPtr Elm_Kernel_Platform_registerIncomingPort(HPtr name, HPtr decoder, HPtr schema) {
    HPointer decoderHP = decode(decoder.toBits());
    // The payload descriptor (PORT_009) is an Elm string literal, read like the name.
    Elm::Platform::PortRuntime::instance().registerIncoming(portNameOf(name), decoderHP, portNameOf(schema));
    return HPtr::fromBits(encode(alloc::unit()));
}

// A bytes port, whose whole payload is Bytes, has no decoder: the runtime hands the bytes over as they are
// (PORT_008).
HPtr Elm_Kernel_Platform_registerIncomingBytesPort(HPtr name) {
    Elm::Platform::PortRuntime::instance().registerIncomingBytes(portNameOf(name));
    return HPtr::fromBits(encode(alloc::unit()));
}

HPtr Elm_Kernel_Platform_registerOutgoingBytesPort(HPtr name) {
    Elm::Platform::PortRuntime::instance().registerOutgoing(portNameOf(name), /*bytes=*/true);
    return HPtr::fromBits(encode(alloc::unit()));
}

// initWorker runs this decoder on the flags JSON the host supplies.
HPtr Elm_Kernel_Platform_registerFlagsDecoder(HPtr decoder) {
    HPointer decoderHP = decode(decoder.toBits());
    Elm::Platform::PlatformRuntime::instance().setFlagsDecoder(decoderHP);
    return HPtr::fromBits(encode(alloc::unit()));
}

HPtr Elm_Kernel_Platform_registerOutgoingPort(HPtr name) {
    Elm::Platform::PortRuntime::instance().registerOutgoing(portNameOf(name), /*bytes=*/false);
    return HPtr::fromBits(encode(alloc::unit()));
}

} // extern "C"
