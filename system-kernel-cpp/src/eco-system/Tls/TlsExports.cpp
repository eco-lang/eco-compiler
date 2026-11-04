//===- TlsExports.cpp - C exports of Eco.Kernel.Tls -----------------------===//
//
// The C exports of `Socket.Tls`. Each takes its arguments as the words of the Elm values in the annotation above
// it, an Int as `int64_t` and any other value as an encoded `uint64_t`, packs them into a payload and returns a
// binding of the body in Tls.cpp, which does the work when the Task runs. No OpenSSL header is included here, so
// this file builds on Windows, where the bodies fail with ENOTSUP.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Tls/Tls.hpp"

using namespace Eco::System;

namespace {

// Returns `tuple3( a, b, c )` of the decoded words, every slot boxed; each is rooted across the allocation.
HPointer triplePayload(uint64_t a, uint64_t b, uint64_t c) {
    HPointer aHP = dec(a);
    HPointer bHP = dec(b);
    HPointer cHP = dec(c);
    Elm::StackRootGuard g(&aHP, &bHP, &cHP);
    return alloc::tuple3(alloc::boxed(aHP), alloc::boxed(bHP), alloc::boxed(cHP), 0);
}

} // namespace

extern "C" {

// Returns the Task that connects as `tlsConnectBody` describes.
// connect : ( String, Int, Int ) -> ( Bool, Int ) -> ( String, ( Int, String ), List String )
//           -> Task FErr ConnT
uint64_t Eco_Kernel_Tls_connect(uint64_t target, uint64_t settings, uint64_t tls) {
    ECO_KERNEL_GUARD(
        HPointer payload = triplePayload(target, settings, tls);
        return enc(makeAsyncBinding<tlsConnectBody>(payload));
    )
}

// Returns the Task that listens as `tlsListenBody` describes.
// listen : ( String, Int ) -> ( Int, Bool ) -> ( String, String, List String ) -> Task FErr ListenT
uint64_t Eco_Kernel_Tls_listen(uint64_t target, uint64_t settings, uint64_t tls) {
    ECO_KERNEL_GUARD(
        HPointer payload = triplePayload(target, settings, tls);
        return enc(makeAsyncBinding<tlsListenBody>(payload));
    )
}

// Returns the Task that reports connection `connId`'s TLS details as `tlsInfoBody` describes.
// info : Int -> Task FErr InfoT
uint64_t Eco_Kernel_Tls_info(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<tlsInfoBody>(payload));
    )
}

} // extern "C"
