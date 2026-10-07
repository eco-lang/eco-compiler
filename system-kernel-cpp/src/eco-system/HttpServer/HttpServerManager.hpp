//===- HttpServerManager.hpp - The C++ effect manager of Http.Server ------===//
//
// plans/eco-system-library.md §3.6 and Appendix C.5 (manager key
// "Http.Server"). The Elm declaration lives in
// system-kernel-cpp/src/Http/Server.elm, section "EFFECT MANAGER":
//
//     type MySub msg
//         = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), Int ) -> msg)
//     -- tag 0: [serverId unboxed Int (mask 0b01), tagger boxed]
//
// Tagger argument: ( ( method, absoluteUrl ), ( headers, body ), responseKey ),
// a tuple3 whose slot 2 is an unboxed Int (mask 1 << 4 = 0x10, HEAP_046);
// the inner tuples are all boxed (mask 0). Each header occurrence is one
// ( name, [ value ] ) entry, in arrival order (Elm keeps the last, E.5).
//
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm).
// Keep the two in sync.
//
// Templates used: T6 (manager), T5 (state), T8 (delivery).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace HttpServerManager {

// MySub
constexpr uint16_t CTOR_ON_REQUEST = 0;
constexpr int ON_REQUEST_SERVER_FIELD = 0;   // unboxed Int
constexpr int ON_REQUEST_TAGGER_FIELD = 1;
constexpr uint64_t ON_REQUEST_MASK = 0x1;    // slot 0 Int

// The tagger argument's tuple3 mask: slot 2 (responseKey) is an Int.
constexpr uint32_t TAGGER_ARG_MASK = 0x10;

} // namespace HttpServerManager

// Main thread. Registers the module drain (requests to the subscribed
// taggers, respond completions) with the eco/system async source. Idempotent.
void ensureHttpServerDrain();

} // namespace Eco::System

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (§3.6);
// returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_Http_Server();
}

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP
