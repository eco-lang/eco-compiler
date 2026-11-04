//===- HttpServerExports.cpp - C exports of Eco.Kernel.HttpServer ---------===//
//
// The C-linkage symbols that compiled Elm code calls for the kernels of `Eco.Kernel.HttpServer`. Each export
// packs its arguments into one payload value and returns, as an encoded word, a Task bound to the body that
// HttpServer.hpp declares; nothing happens until the Task runs. Int arguments arrive as `int64_t` and are stored
// unboxed, except `takeUpgrade`'s key, which is boxed; every other argument arrives as an encoded word and is
// stored boxed. Each decoded argument, and each inner tuple, is rooted before the next allocation, since an
// allocation may move it.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServer.hpp"

using namespace Eco::System;

extern "C" {

// createServer : String -> Int -> Task ( String, String ) ( Int, String, Int )
/// Returns the Task that starts a server on `host` and `port`, as `httpServerCreateServerBody` describes.
uint64_t Eco_Kernel_HttpServer_createServer(uint64_t host, int64_t port) {
    ECO_KERNEL_GUARD(
        HPointer hostHP = dec(host);
        Elm::StackRootGuard g(&hostHP);
        HPointer payload = alloc::tuple2(alloc::boxed(hostHP), alloc::unboxedInt(port), 0x4);
        return enc(makeAsyncBinding<httpServerCreateServerBody>(payload));
    )
}

// respond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
/// Returns the Task that answers request `key`, as `httpServerRespondBody` describes.
uint64_t Eco_Kernel_HttpServer_respond(int64_t key, int64_t status, uint64_t headers,
                                       uint64_t body) {
    ECO_KERNEL_GUARD(
        HPointer headersHP = dec(headers);
        HPointer bodyHP = dec(body);
        HPointer ks = alloc::listNil();
        HPointer hb = alloc::listNil();
        Elm::StackRootGuard g({&headersHP, &bodyHP, &ks, &hb});
        // No allocation is nested in another's arguments: their evaluation order is unspecified, so an
        // inner tuple could be moved by its sibling's allocation before being rooted.
        ks = alloc::tuple2(alloc::unboxedInt(key), alloc::unboxedInt(status), 0x5);
        hb = alloc::tuple2(alloc::boxed(headersHP), alloc::boxed(bodyHP), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(ks), alloc::boxed(hb), 0);
        return enc(makeAsyncBinding<httpServerRespondBody>(payload));
    )
}

// respondHtml : Int -> Int -> List ( String, List String ) -> Bool -> Html.Dom.Node -> Task Never ()
/// Returns the Task that answers request `key` with an HTML body, as `httpServerRespondHtmlBody` describes.
uint64_t Eco_Kernel_HttpServer_respondHtml(int64_t key, int64_t status, uint64_t headers,
                                           uint64_t doctype, uint64_t node) {
    ECO_KERNEL_GUARD(
        HPointer headersHP = dec(headers);
        HPointer doctypeHP = dec(doctype);
        HPointer nodeHP = dec(node);
        HPointer ks = alloc::listNil();
        HPointer hdn = alloc::listNil();
        Elm::StackRootGuard g({&headersHP, &doctypeHP, &nodeHP, &ks, &hdn});
        ks = alloc::tuple2(alloc::unboxedInt(key), alloc::unboxedInt(status), 0x5);
        hdn = alloc::tuple3(alloc::boxed(headersHP), alloc::boxed(doctypeHP), alloc::boxed(nodeHP), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(ks), alloc::boxed(hdn), 0);
        return enc(makeAsyncBinding<httpServerRespondHtmlBody>(payload));
    )
}

// createServerWith : ( ( String, Int ), ( Int, Int ) ) -> Maybe ( String, String )
//     -> ( ( Int, Int, Int ), ( Int, Int, Int ) ) -> Task ( String, String ) ( Int, String, Int )
/// Returns the Task that starts a server with explicit options, as `httpServerCreateServerWithBody` describes.
/// The three arguments are stored as Elm passed them.
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
/// Returns the Task that closes server `serverId`, as `httpServerCloseServerBody` describes.
uint64_t Eco_Kernel_HttpServer_closeServer(int64_t serverId, int64_t deadlineMs) {
    ECO_KERNEL_GUARD(
        HPointer payload =
            alloc::tuple2(alloc::unboxedInt(serverId), alloc::unboxedInt(deadlineMs), 0x5);
        return enc(makeAsyncBinding<httpServerCloseServerBody>(payload));
    )
}

// takeUpgrade : Int -> Task ( String, String )
//     ( Int, ( String, String, String ), ( List ( String, List String ), Bool, ( Int, String, Int ) ) )
/// Returns the Task that takes over upgrade request `key`, as `httpServerTakeUpgradeBody` describes. The payload
/// is `key` boxed.
uint64_t Eco_Kernel_HttpServer_takeUpgrade(int64_t key) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<httpServerTakeUpgradeBody>(alloc::allocInt(key)));
    )
}

} // extern "C"
