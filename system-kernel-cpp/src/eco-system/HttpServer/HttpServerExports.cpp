//===- HttpServerExports.cpp - C exports of Eco.Kernel.HttpServer ---------===//
//
// plans/eco-system-library.md Appendix B.6 and plans/eco-system-websockets.md
// Appendix B.2. Exports only pack and bind
// (G2); the bodies are in HttpServer.cpp. The `Http.Server` effect-manager
// registration is in HttpServerManager.cpp.
//
// Templates used: T1 (packing), T2 (async bindings).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServer.hpp"

using namespace Eco::System;

extern "C" {

// createServer : String -> Int -> Task ( String, String ) ( Int, Int )
uint64_t Eco_Kernel_HttpServer_createServer(uint64_t host, int64_t port) {
    ECO_KERNEL_GUARD(
        HPointer hostHP = dec(host);
        Elm::StackRootGuard g(&hostHP);
        HPointer payload = alloc::tuple2(alloc::boxed(hostHP), alloc::unboxedInt(port), 0x4);
        return enc(makeAsyncBinding<httpServerCreateServerBody>(payload));
    )
}

// respond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
uint64_t Eco_Kernel_HttpServer_respond(int64_t key, int64_t status, uint64_t headers,
                                       uint64_t body) {
    ECO_KERNEL_GUARD(
        HPointer headersHP = dec(headers);
        HPointer bodyHP = dec(body);
        HPointer ks = alloc::listNil();
        HPointer hb = alloc::listNil();
        Elm::StackRootGuard g({&headersHP, &bodyHP, &ks, &hb});
        // Four arguments: nested tuples (G2). Each inner tuple is rooted
        // before the next allocation (argument evaluation order is
        // unspecified, so no allocation is nested inside another's arguments).
        ks = alloc::tuple2(alloc::unboxedInt(key), alloc::unboxedInt(status), 0x5);
        hb = alloc::tuple2(alloc::boxed(headersHP), alloc::boxed(bodyHP), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(ks), alloc::boxed(hb), 0);
        return enc(makeAsyncBinding<httpServerRespondBody>(payload));
    )
}

// respondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Http.Dom.Node -> Task Never ()
// plans/elm-html-native-kernel.md §7.3: `respond` with an HTML body, serialized in the body's
// copy-out scope.
uint64_t Eco_Kernel_HttpServer_respondHtml(int64_t key, int64_t status, uint64_t headers,
                                           uint64_t doctype, uint64_t node) {
    ECO_KERNEL_GUARD(
        HPointer headersHP = dec(headers);
        HPointer doctypeHP = dec(doctype);
        HPointer nodeHP = dec(node);
        HPointer ks = alloc::listNil();
        HPointer hdn = alloc::listNil();
        Elm::StackRootGuard g({&headersHP, &doctypeHP, &nodeHP, &ks, &hdn});
        // Five arguments: nested tuples (G2), each rooted before the next allocation.
        ks = alloc::tuple2(alloc::unboxedInt(key), alloc::unboxedInt(status), 0x5);
        hdn = alloc::tuple3(alloc::boxed(headersHP), alloc::boxed(doctypeHP), alloc::boxed(nodeHP), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(ks), alloc::boxed(hdn), 0);
        return enc(makeAsyncBinding<httpServerRespondHtmlBody>(payload));
    )
}

// --- plans/eco-system-websockets.md Appendix B.2 ---------------------------------

// createServerWith : ( ( String, Int ), ( Bool, Int ) ) -> Maybe ( String, String )
//     -> ( ( Int, Int, Int ), ( Int, Int, Int ) ) -> Task ( String, String ) ( Int, Int )
uint64_t Eco_Kernel_HttpServer_createServerWith(uint64_t target, uint64_t tls, uint64_t limits) {
    ECO_KERNEL_GUARD(
        HPointer targetHP = dec(target);
        HPointer tlsHP = dec(tls);
        HPointer limitsHP = dec(limits);
        Elm::StackRootGuard g({&targetHP, &tlsHP, &limitsHP});
        HPointer payload =
            alloc::tuple3(alloc::boxed(targetHP), alloc::boxed(tlsHP), alloc::boxed(limitsHP), 0);
        return enc(makeAsyncBinding<httpServerCreateServerWithBody>(payload));
    )
}

// closeServer : Int -> Int -> Task Never ()
uint64_t Eco_Kernel_HttpServer_closeServer(int64_t serverId, int64_t deadlineMs) {
    ECO_KERNEL_GUARD(
        HPointer payload =
            alloc::tuple2(alloc::unboxedInt(serverId), alloc::unboxedInt(deadlineMs), 0x5);
        return enc(makeAsyncBinding<httpServerCloseServerBody>(payload));
    )
}

// takeUpgrade : Int -> Task ( String, String )
//     ( Int, ( String, String, String ), ( List ( String, List String ), Bool, ( Int, String, Int ) ) )
// Phase WS5 (HttpUpgrade.cpp): the payload is the boxed key.
uint64_t Eco_Kernel_HttpServer_takeUpgrade(int64_t key) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<httpServerTakeUpgradeBody>(alloc::allocInt(key)));
    )
}

} // extern "C"
