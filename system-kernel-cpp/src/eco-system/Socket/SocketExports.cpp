//===- SocketExports.cpp - C exports of Eco.Kernel.Socket (stream) --------===//
//
// The C-linkage entry points of the stream-socket and lookup kernels of `Eco.Kernel.Socket`, called by compiled Elm
// code. The argument types follow the Elm annotations of the wrappers in Socket.elm, Socket/Tcp.elm and
// Socket/Unix.elm: an Int arrives as `int64_t`, and anything else (Bool, String, tuple) as an encoded `uint64_t`.
//
// An export does no IO. It passes one heap value, the payload, to `makeAsyncBinding` or `makeBinding`, and returns
// the Task binding made, whose body, declared in Socket.hpp, does the work each time the Task runs. The payloads are:
//
//   lookup, unixConnect              the String itself
//   tcpConnect, tcpListen,
//   unixListen                       a 2-tuple of the two arguments, both boxed (mask 0)
//   accept, closeListener,
//   close, reset, peerCredentials    the id as a boxed `ElmInt`
//   setNoDelay                       a 2-tuple of the boxed Bool and the unboxed Int id (mask 0x4)
//   setKeepAlive                     a 2-tuple of the unboxed Int seconds and the unboxed Int id (mask 0x5)
//
// A tuple's mask gives each slot's kind in two bits, slot 0 lowest, with 1 meaning an unboxed Int.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Socket/Socket.hpp"

using namespace Eco::System;

namespace {

// Returns a 2-tuple, mask 0, of the encoded values `a` and `b`, both rooted while it is allocated.
HPointer pairPayload(uint64_t a, uint64_t b) {
    HPointer aHP = dec(a);
    HPointer bHP = dec(b);
    Elm::StackRootGuard g(&aHP, &bHP);
    return alloc::tuple2(alloc::boxed(aHP), alloc::boxed(bHP), 0);
}

} // namespace

extern "C" {

// lookup : String -> Task FErr (List String)
// Returns a Task that resolves the host name `name`, as `socketLookupBody` describes.
uint64_t Eco_Kernel_Socket_lookup(uint64_t name) {
    ECO_KERNEL_GUARD(return enc(makeAsyncBinding<socketLookupBody>(dec(name)));)
}

// tcpConnect : ( String, Int, Int ) -> ( Bool, Int ) -> Task FErr ConnT
// Returns a Task that connects to `target`, ( address, port, timeoutMs ), with `settings`, ( noDelay, keepAliveSec ),
// as `socketTcpConnectBody` describes.
uint64_t Eco_Kernel_Socket_tcpConnect(uint64_t target, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer payload = pairPayload(target, settings);
        return enc(makeAsyncBinding<socketTcpConnectBody>(payload));
    )
}

// unixConnect : String -> Task FErr ConnT
// Returns a Task that connects to the Unix socket at `path`, as `socketUnixConnectBody` describes.
uint64_t Eco_Kernel_Socket_unixConnect(uint64_t path) {
    ECO_KERNEL_GUARD(return enc(makeAsyncBinding<socketUnixConnectBody>(dec(path)));)
}

// tcpListen : ( String, Int ) -> ( Int, Bool ) -> Task FErr ListenT
// Returns a Task that listens on `target`, ( address, port ), with `settings`, ( backlog, ipv6Only ), as
// `socketTcpListenBody` describes.
uint64_t Eco_Kernel_Socket_tcpListen(uint64_t target, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer payload = pairPayload(target, settings);
        return enc(makeAsyncBinding<socketTcpListenBody>(payload));
    )
}

// unixListen : String -> ( Bool, Int ) -> Task FErr ListenT
// Returns a Task that listens at `path` with `settings`, ( removeExisting, mode ), as `socketUnixListenBody`
// describes; a negative mode leaves the file's permissions alone.
uint64_t Eco_Kernel_Socket_unixListen(uint64_t path, uint64_t settings) {
    ECO_KERNEL_GUARD(
        HPointer payload = pairPayload(path, settings);
        return enc(makeAsyncBinding<socketUnixListenBody>(payload));
    )
}

// accept : Int -> Task FErr ConnT
// Returns a Task that accepts one connection on listener `listenerId`, as `socketAcceptBody` describes.
uint64_t Eco_Kernel_Socket_accept(int64_t listenerId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(listenerId);
        return enc(makeAsyncBinding<socketAcceptBody>(payload));
    )
}

// closeListener : Int -> Task FErr ()
// Returns a Task that closes listener `listenerId`, as `socketCloseListenerBody` describes.
uint64_t Eco_Kernel_Socket_closeListener(int64_t listenerId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(listenerId);
        return enc(makeAsyncBinding<socketCloseListenerBody>(payload));
    )
}

// close : Int -> Task Never ()
// Returns a Task that aborts connection `connId`, as `socketCloseBody` describes.
uint64_t Eco_Kernel_Socket_close(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<socketCloseBody>(payload));
    )
}

// reset : Int -> Task Never ()
// Returns a Task that resets connection `connId`, as `socketResetBody` describes.
uint64_t Eco_Kernel_Socket_reset(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<socketResetBody>(payload));
    )
}

// setNoDelay : Bool -> Int -> Task FErr ()
// Returns a Task that sets TCP_NODELAY to `noDelay` on connection `connId`, as `socketSetNoDelayBody` describes.
uint64_t Eco_Kernel_Socket_setNoDelay(uint64_t noDelay, int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer b = dec(noDelay);   // True/False: embedded constants (no GC hazard)
        HPointer payload = alloc::tuple2(alloc::boxed(b), alloc::unboxedInt(connId), 0x4);
        return enc(makeAsyncBinding<socketSetNoDelayBody>(payload));
    )
}

// setKeepAlive : Int -> Int -> Task FErr ()
// Returns a Task that sets TCP keep-alive on connection `connId` to `seconds`, as `socketSetKeepAliveBody`
// describes.
uint64_t Eco_Kernel_Socket_setKeepAlive(int64_t seconds, int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload =
            alloc::tuple2(alloc::unboxedInt(seconds), alloc::unboxedInt(connId), 0x5);
        return enc(makeAsyncBinding<socketSetKeepAliveBody>(payload));
    )
}

// peerCredentials : Int -> Task FErr CredT
// Returns a Task that gives the peer credentials of connection `connId`, as `socketPeerCredentialsBody` describes.
uint64_t Eco_Kernel_Socket_peerCredentials(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<socketPeerCredentialsBody>(payload));
    )
}

} // extern "C"
