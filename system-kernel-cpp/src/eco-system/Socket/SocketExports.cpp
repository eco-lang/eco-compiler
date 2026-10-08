//===- SocketExports.cpp - C exports of Eco.Kernel.Socket (stream) --------===//
//
// plans/eco-system-sockets.md Appendix B.1 (stream sockets and lookup). The
// ABI follows the Elm annotations of the wrappers in Socket.elm,
// Socket/Tcp.elm and Socket/Unix.elm (base plan F7): Int → int64_t,
// everything else (Bool, String, tuples) → an encoded uint64_t.
//
// Exports only decode, root and pack their arguments and return a binding
// (G2); the bodies are in Socket.cpp. Payload layouts (F5 masks):
//   lookup, unixConnect         the String
//   tcpConnect, tcpListen,
//   unixListen                  tuple2( boxed arg1, boxed arg2 )   mask 0
//   accept, closeListener,
//   close, reset,
//   peerCredentials             boxed ElmInt id
//   setNoDelay                  tuple2( boxed Bool, Int id )       mask 0x4
//   setKeepAlive                tuple2( Int seconds, Int id )      mask 0x5
//
// Templates used: T1 (S-mode exports), T2/T7 (async exports).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Socket.hpp"

using namespace Eco::System;

namespace {

// tuple2( boxed a, boxed b ), mask 0: both arguments rooted across the allocation.
HPointer pairPayload(uint64_t a, uint64_t b) {
    HPointer aHP = dec(a);
    HPointer bHP = dec(b);
    Elm::StackRootGuard g(&aHP, &bHP);
    return alloc::tuple2(alloc::boxed(aHP), alloc::boxed(bHP), 0);
}

} // namespace

extern "C" {

// lookup : String -> Task FErr (List String)
uint64_t Eco_Kernel_Socket_lookup(uint64_t name) {
    ECO_KERNEL_GUARD(return enc(makeAsyncBinding<socketLookupBody>(dec(name)));)
}

// tcpConnect : ( String, Int, Int ) -> ( Bool, Int ) -> Task FErr ConnT
uint64_t Eco_Kernel_Socket_tcpConnect(uint64_t target, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer payload = pairPayload(target, settings);
        return enc(makeAsyncBinding<socketTcpConnectBody>(payload));
    )
}

// unixConnect : String -> Task FErr ConnT
uint64_t Eco_Kernel_Socket_unixConnect(uint64_t path) {
    ECO_KERNEL_GUARD(return enc(makeAsyncBinding<socketUnixConnectBody>(dec(path)));)
}

// tcpListen : ( String, Int ) -> ( Int, Bool ) -> Task FErr ListenT
uint64_t Eco_Kernel_Socket_tcpListen(uint64_t target, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer payload = pairPayload(target, settings);
        return enc(makeAsyncBinding<socketTcpListenBody>(payload));
    )
}

// unixListen : String -> ( Bool, Int ) -> Task FErr ListenT
uint64_t Eco_Kernel_Socket_unixListen(uint64_t path, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer payload = pairPayload(path, settings);
        return enc(makeAsyncBinding<socketUnixListenBody>(payload));
    )
}

// accept : Int -> Task FErr ConnT
uint64_t Eco_Kernel_Socket_accept(int64_t listenerId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(listenerId);
        return enc(makeAsyncBinding<socketAcceptBody>(payload));
    )
}

// closeListener : Int -> Task FErr ()
uint64_t Eco_Kernel_Socket_closeListener(int64_t listenerId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(listenerId);
        return enc(makeAsyncBinding<socketCloseListenerBody>(payload));
    )
}

// close : Int -> Task Never ()
uint64_t Eco_Kernel_Socket_close(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<socketCloseBody>(payload));
    )
}

// reset : Int -> Task Never ()
uint64_t Eco_Kernel_Socket_reset(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<socketResetBody>(payload));
    )
}

// setNoDelay : Bool -> Int -> Task FErr ()
uint64_t Eco_Kernel_Socket_setNoDelay(uint64_t noDelay, int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer b = dec(noDelay);   // True/False: embedded constants (no GC hazard)
        HPointer payload = alloc::tuple2(alloc::boxed(b), alloc::unboxedInt(connId), 0x4);
        return enc(makeAsyncBinding<socketSetNoDelayBody>(payload));
    )
}

// setKeepAlive : Int -> Int -> Task FErr ()   (seconds; 0 off, connId)
uint64_t Eco_Kernel_Socket_setKeepAlive(int64_t seconds, int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload =
            alloc::tuple2(alloc::unboxedInt(seconds), alloc::unboxedInt(connId), 0x5);
        return enc(makeAsyncBinding<socketSetKeepAliveBody>(payload));
    )
}

// peerCredentials : Int -> Task FErr CredT
uint64_t Eco_Kernel_Socket_peerCredentials(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<socketPeerCredentialsBody>(payload));
    )
}

} // extern "C"
