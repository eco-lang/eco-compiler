//===- UdpExports.cpp - C exports of Eco.Kernel.Socket (UDP) --------------===//
//
// The C-linkage functions compiled Elm code calls for the UDP kernels of `Socket.Udp`. Each one decodes its
// arguments, packs them into one heap payload and returns a Task binding whose step is the matching body in Udp.cpp;
// nothing happens until the Task runs. The argument types follow the Elm type of the kernel: an Int arrives as a raw
// `int64_t`, and everything else (Bool, String, Bytes, tuples) as an encoded `uint64_t` word.
//
// Payload layouts (kind masks are 2 bits per slot, 1 meaning an unboxed Int):
//   udpBind          tuple2( boxed target, boxed settings )             mask 0
//   udpSend          tuple3( boxed to, boxed data, Int socketId )       mask 0x10
//   udpReceive,
//   udpClose         boxed ElmInt socket id
//   udpMembership    tuple2( boxed ( join, group, iface ), Int id )     mask 0x4 (inner 0)
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Udp.hpp"

using namespace Eco::System;

extern "C" {

// udpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task FErr UdpT
/// Returns the Task that binds a UDP socket to the address `target`, with the options `settings`
/// (reuseAddress, broadcast, ipv6Only).
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
/// Returns the Task that sends `data` as one datagram from socket `socketId` to the address `to`.
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
/// Returns the Task that receives the next datagram on socket `socketId`.
uint64_t Eco_Kernel_Socket_udpReceive(int64_t socketId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(socketId);
        return enc(makeAsyncBinding<udpReceiveBody>(payload));
    )
}

// udpClose : Int -> Task Never ()
/// Returns the Task that closes socket `socketId`.
uint64_t Eco_Kernel_Socket_udpClose(int64_t socketId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(socketId);
        return enc(makeBinding<udpCloseBody>(payload));
    )
}

// udpMembership : Bool -> String -> String -> Int -> Task FErr ()
/// Returns the Task that makes socket `socketId` join (`join` True) or leave the multicast group `group`, on the
/// interface `iface` names, as `UdpHandler::membership` describes.
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
