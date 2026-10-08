//===- UdpExports.cpp - C exports of Eco.Kernel.Socket (UDP) --------------===//
//
// plans/eco-system-sockets.md Appendix B.2. The ABI follows the Elm
// annotations of the wrappers in Socket/Udp.elm (base plan F7): Int →
// int64_t, everything else (Bool, String, Bytes, tuples) → an encoded
// uint64_t.
//
// Exports only decode, root and pack their arguments and return a binding
// (G2); the bodies are in Udp.cpp. Payload layouts (F5 masks):
//   udpBind          tuple2( boxed target, boxed settings )             mask 0
//   udpSend          tuple3( boxed to, boxed data, Int socketId )       mask 0x10
//   udpReceive,
//   udpClose         boxed ElmInt socket id
//   udpMembership    tuple2( boxed ( join, group, iface ), Int id )     mask 0x4 (inner 0)
//
// Templates used: T1 (S-mode export), T2/T7 (async exports).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Udp.hpp"

using namespace Eco::System;

extern "C" {

// udpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task FErr UdpT
uint64_t Eco_Kernel_Socket_udpBind(uint64_t target, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer t = dec(target);
        HPointer s = dec(settings);
        Elm::StackRootGuard g(&t, &s);
        HPointer payload = alloc::tuple2(alloc::boxed(t), alloc::boxed(s), 0);
        return enc(makeAsyncBinding<udpBindBody>(payload));
    )
}

// udpSend : ( String, Int ) -> Bytes -> Int -> Task FErr ()
uint64_t Eco_Kernel_Socket_udpSend(uint64_t to, uint64_t data, int64_t socketId) {
    ECO_KERNEL_GUARD(
        HPointer t = dec(to);
        HPointer d = dec(data);
        Elm::StackRootGuard g(&t, &d);
        HPointer payload =
            alloc::tuple3(alloc::boxed(t), alloc::boxed(d), alloc::unboxedInt(socketId), 0x10);
        return enc(makeAsyncBinding<udpSendBody>(payload));
    )
}

// udpReceive : Int -> Task FErr DgramT
uint64_t Eco_Kernel_Socket_udpReceive(int64_t socketId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(socketId);
        return enc(makeAsyncBinding<udpReceiveBody>(payload));
    )
}

// udpClose : Int -> Task Never ()
uint64_t Eco_Kernel_Socket_udpClose(int64_t socketId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(socketId);
        return enc(makeBinding<udpCloseBody>(payload));
    )
}

// udpMembership : Bool -> String -> String -> Int -> Task FErr ()
//   (join, group, interface or "", socketId)
uint64_t Eco_Kernel_Socket_udpMembership(uint64_t join, uint64_t group, uint64_t iface,
                                         int64_t socketId) {
    ECO_KERNEL_GUARD(
        HPointer j = dec(join);   // True/False: embedded constants
        HPointer gr = dec(group);
        HPointer i = dec(iface);
        HPointer args = alloc::listNil();
        Elm::StackRootGuard g({&j, &gr, &i, &args});
        args = alloc::tuple3(alloc::boxed(j), alloc::boxed(gr), alloc::boxed(i), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(args), alloc::unboxedInt(socketId), 0x4);
        return enc(makeAsyncBinding<udpMembershipBody>(payload));
    )
}

} // extern "C"
