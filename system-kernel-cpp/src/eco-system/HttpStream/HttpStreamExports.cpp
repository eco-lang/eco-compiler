//===- HttpStreamExports.cpp - C exports of Eco.Kernel.HttpStream ---------===//
//
// The C-linkage entry point of `Http.Stream.send`. It packs its four
// arguments into one payload and binds `httpStreamSendBody` (HttpStream.hpp)
// to it, so the request is made each time the returned Task runs.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpStream/HttpStream.hpp"

using namespace Eco::System;

extern "C" {

// send : ( String, String, Int ) -> List Http.Header -> ( Int, String, ( Bytes, Int ) )
//        -> Bool -> Task Never ( Int, String, ( ( Int, String, String ), List ( String, String ), Int ) )
// Returns the Task binding for one request; the payload layout and the result
// are described at `httpStreamSendBody`.
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
