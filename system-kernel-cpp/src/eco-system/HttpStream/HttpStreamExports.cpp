//===- HttpStreamExports.cpp - C exports of Eco.Kernel.HttpStream ---------===//
//
// plans/eco-system-library.md Appendix B.7. The export only decodes, roots,
// packs and binds (G2); the body is in HttpStream.cpp.
//
// Templates used: T1 (export shape: four arguments in nested tuples), T2.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpStream/HttpStream.hpp"

using namespace Eco::System;

extern "C" {

// send : ( String, String, Int ) -> List Http.Header -> ( Int, String, ( Bytes, Int ) )
//        -> Bool -> Task Never ( Int, String, ( ( Int, String, String ), List ( String, String ), Int ) )
uint64_t Eco_Kernel_HttpStream_send(uint64_t request, uint64_t headers, uint64_t body,
                                    uint64_t discard) {
    ECO_KERNEL_GUARD(
        HPointer requestHP = dec(request);
        HPointer headersHP = dec(headers);
        HPointer bodyHP = dec(body);
        HPointer discardHP = dec(discard);
        HPointer a = alloc::listNil();
        HPointer b = alloc::listNil();
        Elm::StackRootGuard g({&requestHP, &headersHP, &bodyHP, &discardHP, &a, &b});
        a = alloc::tuple2(alloc::boxed(requestHP), alloc::boxed(headersHP), 0);
        b = alloc::tuple2(alloc::boxed(bodyHP), alloc::boxed(discardHP), 0);
        HPointer payload = alloc::tuple2(alloc::boxed(a), alloc::boxed(b), 0);
        return enc(makeAsyncBinding<httpStreamSendBody>(payload));
    )
}

} // extern "C"
