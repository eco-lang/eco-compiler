//===- WebSocketExports.cpp - C exports of Eco.Kernel.WebSocket -----------===//
//
// The C-linkage symbols that generated code calls for the `Eco.Kernel.WebSocket` kernels. Each export's argument and
// result types follow the kernel's annotation in the Elm WebSocket module: an Int crosses as `int64_t`, and every
// other value (a Bool, a String, a tuple, a closure, a Task) as an encoded `uint64_t` word (`enc`, `dec`).
//
// Apart from `acceptFor`, which is pure and returns its String, an export does no IO. It decodes its arguments, packs
// them into one payload, and binds the payload to the matching body in WebSocket.hpp, returning the Task; the body
// runs each time the Task runs. A payload is built with every boxed argument rooted across the allocations. The
// "WebSocket" effect manager is registered in WsManager.cpp; the three kernels only its JavaScript bodies call,
// `attachMessageListener`, `attachCloseListener` and `holdClose`, have no symbol here.
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WebSocket.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"

using namespace Eco::System;

namespace {

/// Builds `dial`'s payload, the 3-tuple of the boxed `target`, `tls` and `request`.
HPointer dialPayload(uint64_t target, uint64_t tls, uint64_t request) {
    HPointer a = dec(target);
    HPointer b = dec(tls);
    HPointer c = dec(request);
    Elm::StackRootGuard g({&a, &b, &c});
    return alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(c), 0);
}

/// Builds `open`'s payload, the 3-tuple of the boxed `( id, response )`, `params` and `( fromWire, toWire )`, with
/// `id` unboxed in its pair.
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

/// Implements `handshakeKey : Task Never ( String, String )`, as `wsHandshakeKeyBody` describes.
uint64_t Eco_Kernel_WebSocket_handshakeKey() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<wsHandshakeKeyBody>(alloc::unit()));
    )
}

/// Implements `acceptFor : String -> String`: returns the `Sec-WebSocket-Accept` value that `key` calls for, as
/// `wsAcceptFor` computes it. Unlike the other kernels it returns a value, not a Task.
uint64_t Eco_Kernel_WebSocket_acceptFor(uint64_t key) {
    ECO_KERNEL_GUARD(
        std::string accept = wsAcceptFor(toStdString(dec(key)));
        return enc(alloc::allocStringFromUTF8(accept));
    )
}

/// Implements `dial : ( List String, Int, Int ) -> ( ( Bool, String ), ( Int, String ), ( Bool, Bool ) )
/// -> ( String, List ( String, String ) ) -> Task FErr ( Int, ( Int, Bool ), List ( String, List String ) )`, as
/// `wsDialBody` describes.
uint64_t Eco_Kernel_WebSocket_dial(uint64_t target, uint64_t tls, uint64_t request) {
    ECO_KERNEL_GUARD(
        HPointer payload = dialPayload(target, tls, request);
        return enc(makeAsyncBinding<wsDialBody>(payload));
    )
}

/// Implements `readUpgrade : Int -> Int -> Task FErr
/// ( Int, ( String, String, String ), ( List ( String, List String ), Bool, ( Int, String, Int ) ) )`, as
/// `wsReadUpgradeBody` describes.
uint64_t Eco_Kernel_WebSocket_readUpgrade(int64_t connId, int64_t timeoutMs) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(connId), alloc::unboxedInt(timeoutMs), 0x5);
        return enc(makeAsyncBinding<wsReadUpgradeBody>(payload));
    )
}

/// Implements `open : Int -> ( Int, List ( String, String ) )
/// -> ( ( Int, Int, Int ), ( Int, Int, Int ), ( Int, ( Bool, Int ), ( Bool, Int ) ) )
/// -> (( Int, String, Bytes ) -> a) -> (b -> ( Int, String, Bytes ))
/// -> Task FErr ( Int, ( Int, Int ), ( EpT, EpT ) )`, as `wsOpenBody` describes. An `EpT` is an endpoint
/// `( Int, String, Int )`.
uint64_t Eco_Kernel_WebSocket_open(int64_t id, uint64_t response, uint64_t params,
                                   uint64_t fromWire, uint64_t toWire) {
    ECO_KERNEL_GUARD(
        HPointer payload = openPayload(id, response, params, fromWire, toWire);
        return enc(makeAsyncBinding<wsOpenBody>(payload));
    )
}

/// Implements `reject : Int -> ( Int, List ( String, String ), String ) -> Task Never ()`, as `wsRejectBody`
/// describes.
uint64_t Eco_Kernel_WebSocket_reject(int64_t id, uint64_t response) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(response);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple2(alloc::unboxedInt(id), alloc::boxed(r), 0x1);
        return enc(makeAsyncBinding<wsRejectBody>(payload));
    )
}

/// Implements `abandon : Int -> Task Never ()`, as `wsAbandonBody` describes.
uint64_t Eco_Kernel_WebSocket_abandon(int64_t id) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<wsAbandonBody>(alloc::allocInt(id)));
    )
}

/// Implements `close : Int -> Int -> String -> Task Never ()`, as `wsCloseBody` describes.
uint64_t Eco_Kernel_WebSocket_close(int64_t wsId, int64_t code, uint64_t reason) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(reason);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple3(alloc::unboxedInt(wsId), alloc::unboxedInt(code),
                                         alloc::boxed(r), 0x5);
        return enc(makeAsyncBinding<wsCloseBody>(payload));
    )
}

/// Implements `closed : Int -> Task Never ( Int, String, Bool )`, as `wsClosedBody` describes.
uint64_t Eco_Kernel_WebSocket_closed(int64_t wsId) {
    ECO_KERNEL_GUARD(
        return enc(makeAsyncBinding<wsClosedBody>(alloc::allocInt(wsId)));
    )
}

/// Implements `ping : Int -> Task FErr Int`, as `wsPingBody` describes.
uint64_t Eco_Kernel_WebSocket_ping(int64_t wsId) {
    ECO_KERNEL_GUARD(
        return enc(makeAsyncBinding<wsPingBody>(alloc::allocInt(wsId)));
    )
}

/// Implements `openOutgoing : Int -> Int -> Task FErr Int`, as `wsOpenOutgoingBody` describes.
uint64_t Eco_Kernel_WebSocket_openOutgoing(int64_t wsId, int64_t kind) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(wsId), alloc::unboxedInt(kind), 0x5);
        return enc(makeBinding<wsOpenOutgoingBody>(payload));
    )
}

} // extern "C"
