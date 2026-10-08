//===- TlsExports.cpp - C exports of Eco.Kernel.Tls -----------------------===//
//
// plans/eco-system-sockets.md §3.6 and Appendix B.3. The ABI follows the
// Elm annotations of the wrappers in Socket/Tls.elm (base plan F7): Int →
// int64_t, tuples → an encoded uint64_t.
//
// Exports only decode, root and pack their arguments and return a binding
// (G2); the bodies are in Tls.cpp. Payload layouts (F5 masks):
//   connect, listen   tuple3( boxed target, boxed settings, boxed tls )   mask 0
//   info              boxed ElmInt connection id
// No OpenSSL header is included here, so this file builds on Windows as is.
//
// Templates used: T1 (info), T2/T7 (connect, listen).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Tls/Tls.hpp"

using namespace Eco::System;

namespace {

// tuple3( boxed a, boxed b, boxed c ), mask 0: every argument rooted across the allocation.
HPointer triplePayload(uint64_t a, uint64_t b, uint64_t c) {
    HPointer aHP = dec(a);
    HPointer bHP = dec(b);
    HPointer cHP = dec(c);
    Elm::StackRootGuard g(&aHP, &bHP, &cHP);
    return alloc::tuple3(alloc::boxed(aHP), alloc::boxed(bHP), alloc::boxed(cHP), 0);
}

} // namespace

extern "C" {

// connect : ( String, Int, Int ) -> ( Bool, Int ) -> ( String, ( Int, String ), List String )
//           -> Task FErr ConnT
uint64_t Eco_Kernel_Tls_connect(uint64_t target, uint64_t settings, uint64_t tls) {
    ECO_KERNEL_GUARD(
        HPointer payload = triplePayload(target, settings, tls);
        return enc(makeAsyncBinding<tlsConnectBody>(payload));
    )
}

// listen : ( String, Int ) -> ( Int, Bool ) -> ( String, String, List String ) -> Task FErr ListenT
uint64_t Eco_Kernel_Tls_listen(uint64_t target, uint64_t settings, uint64_t tls) {
    ECO_KERNEL_GUARD(
        HPointer payload = triplePayload(target, settings, tls);
        return enc(makeAsyncBinding<tlsListenBody>(payload));
    )
}

// info : Int -> Task FErr InfoT
uint64_t Eco_Kernel_Tls_info(int64_t connId) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(connId);
        return enc(makeBinding<tlsInfoBody>(payload));
    )
}

} // extern "C"
