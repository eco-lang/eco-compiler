//===- HttpServerExports.cpp - C exports of Eco.Kernel.HttpServer ---------===//
//
// plans/eco-system-library.md Appendix B.6. Exports only pack and bind
// (G2); the bodies are in HttpServer.cpp. The `Http.Server` effect-manager
// registration is in HttpServerManager.cpp.
//
// Templates used: T1 (packing), T2 (async bindings).
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpServer/HttpServer.hpp"

using namespace Eco::System;

extern "C" {

// createServer : String -> Int -> Task ( String, String ) Int
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

} // extern "C"
