//===- WebSocketExports.cpp - C exports of Eco.Kernel.WebSocket -----------===//
//
// plans/eco-system-websockets.md Appendix B.1. The ABI follows the Elm
// annotations of the wrappers in WebSocket.elm (base plan F7): Int →
// int64_t, everything else (Bool, String, tuples, closures) → an encoded
// uint64_t. Exports only decode, root and pack one payload, then bind (G2);
// the bodies are in WebSocket.cpp (payload layouts listed there). The
// "WebSocket" effect-manager registration is in WsManager.cpp; the JS-only
// manager kernels (attachMessageListener, attachCloseListener, holdClose)
// have no C++ symbol (base plan D15).
//
// Templates used: T1.
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WebSocket.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"

using namespace Eco::System;

namespace {

// dial's payload: tuple3( boxed target, boxed tls, boxed request ), mask 0.
HPointer dialPayload(uint64_t target, uint64_t tls, uint64_t request) {
    HPointer a = dec(target);
    HPointer b = dec(tls);
    HPointer c = dec(request);
    Elm::StackRootGuard g({&a, &b, &c});
    return alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(c), 0);
}

// open's payload: tuple3( boxed ( Int id, response ), boxed params,
// boxed ( fromWire, toWire ) ), mask 0.
HPointer openPayload(int64_t id, uint64_t response, uint64_t params, uint64_t fromWire,
                     uint64_t toWire) {
    HPointer r = dec(response);
    HPointer p = dec(params);
    HPointer f = dec(fromWire);
    HPointer t = dec(toWire);
    HPointer first = alloc::listNil();
    HPointer fns = alloc::listNil();
    Elm::StackRootGuard g({&r, &p, &f, &t, &first, &fns});
    first = alloc::tuple2(alloc::unboxedInt(id), alloc::boxed(r), 0x1);
    fns = alloc::tuple2(alloc::boxed(f), alloc::boxed(t), 0);
    return alloc::tuple3(alloc::boxed(first), alloc::boxed(p), alloc::boxed(fns), 0);
}

} // namespace

extern "C" {

// handshakeKey : Task Never ( String, String )
uint64_t Eco_Kernel_WebSocket_handshakeKey() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<wsHandshakeKeyBody>(alloc::unit()));
    )
}

// acceptFor : String -> String (pure, B5 exception)
uint64_t Eco_Kernel_WebSocket_acceptFor(uint64_t key) {
    ECO_KERNEL_GUARD(
        std::string accept = wsAcceptFor(toStdString(dec(key)));   // G3: copy out first
        return enc(alloc::allocStringFromUTF8(accept));
    )
}

// dial : ( List String, Int, Int ) -> ( ( Bool, String ), ( Int, String ), ( Bool, Bool ) )
//     -> ( String, List ( String, String ) )
//     -> Task FErr ( Int, ( Int, Bool ), List ( String, List String ) )
uint64_t Eco_Kernel_WebSocket_dial(uint64_t target, uint64_t tls, uint64_t request) {
    ECO_KERNEL_GUARD(
        HPointer payload = dialPayload(target, tls, request);
        return enc(makeAsyncBinding<wsDialBody>(payload));
    )
}

// readUpgrade : Int -> Int -> Task FErr
//     ( Int, ( String, String, String ), ( List ( String, List String ), Bool, ( Int, String, Int ) ) )
uint64_t Eco_Kernel_WebSocket_readUpgrade(int64_t connId, int64_t timeoutMs) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(connId), alloc::unboxedInt(timeoutMs), 0x5);
        return enc(makeAsyncBinding<wsReadUpgradeBody>(payload));
    )
}

// open : Int -> ( Int, List ( String, String ) )
//     -> ( ( Int, Int, Int ), ( Int, Int, Int ), ( Bool, ( Bool, Int ), ( Bool, Int ) ) )
//     -> (( Int, String, Bytes ) -> a) -> (b -> ( Int, String, Bytes ))
//     -> Task FErr ( Int, ( Int, Int ), ( EpT, EpT ) )
uint64_t Eco_Kernel_WebSocket_open(int64_t id, uint64_t response, uint64_t params,
                                   uint64_t fromWire, uint64_t toWire) {
    ECO_KERNEL_GUARD(
        HPointer payload = openPayload(id, response, params, fromWire, toWire);
        return enc(makeAsyncBinding<wsOpenBody>(payload));
    )
}

// reject : Int -> ( Int, List ( String, String ), String ) -> Task Never ()
uint64_t Eco_Kernel_WebSocket_reject(int64_t id, uint64_t response) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(response);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple2(alloc::unboxedInt(id), alloc::boxed(r), 0x1);
        return enc(makeAsyncBinding<wsRejectBody>(payload));
    )
}

// abandon : Int -> Task Never ()  (WS4: releases a handshake id; §10 WS4)
uint64_t Eco_Kernel_WebSocket_abandon(int64_t id) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<wsAbandonBody>(alloc::allocInt(id)));
    )
}

// close : Int -> Int -> String -> Task Never ()
uint64_t Eco_Kernel_WebSocket_close(int64_t wsId, int64_t code, uint64_t reason) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(reason);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple3(alloc::unboxedInt(wsId), alloc::unboxedInt(code),
                                         alloc::boxed(r), 0x5);
        return enc(makeAsyncBinding<wsCloseBody>(payload));
    )
}

// closed : Int -> Task Never ( Int, String, Bool )
uint64_t Eco_Kernel_WebSocket_closed(int64_t wsId) {
    ECO_KERNEL_GUARD(
        return enc(makeAsyncBinding<wsClosedBody>(alloc::allocInt(wsId)));
    )
}

// ping : Int -> Task FErr Int
uint64_t Eco_Kernel_WebSocket_ping(int64_t wsId) {
    ECO_KERNEL_GUARD(
        return enc(makeAsyncBinding<wsPingBody>(alloc::allocInt(wsId)));
    )
}

// openOutgoing : Int -> Int -> Task FErr Int  (streamed send: WS6)
uint64_t Eco_Kernel_WebSocket_openOutgoing(int64_t wsId, int64_t kind) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(wsId), alloc::unboxedInt(kind), 0x5);
        return enc(makeBinding<wsOpenOutgoingBody>(payload));
    )
}

} // extern "C"
