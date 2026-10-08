//===- HttpServerManager.hpp - The C++ effect manager of Http.Server ------===//
//
// plans/eco-system-library.md §3.6 and Appendix C.5 (manager key
// "Http.Server"). The Elm declaration lives in
// system-kernel-cpp/src/Http/Server.elm, section "EFFECT MANAGER":
//
//     type MySub msg
//         = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) ) -> msg)
//     -- tag 0: [serverId unboxed Int (mask 0b01), tagger boxed]
//
// Tagger argument (plans/eco-system-websockets.md Appendix C.1):
// ( ( method, absoluteUrl ), ( headers, body ), ( responseKey, flags,
// upgradeToken ) ), a tuple3 of boxed slots (mask 0); the inner pairs are
// all boxed (mask 0); the inner triple has two unboxed Ints (mask 0x5,
// HEAP_046). flags: bits 0-1 the HTTP version (0 = 1.0, 1 = 1.1, 2 = 2),
// bit 2 TLS; upgradeToken: the lower-cased protocol an upgrade request asks
// for, "" for none. Each header occurrence is one ( name, [ value ] ) entry,
// in arrival order (Elm keeps the last, E.5).
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

// The tagger argument's tuple3 mask: every slot boxed.
constexpr uint32_t TAGGER_ARG_MASK = 0;
// The inner ( responseKey, flags, upgradeToken ) triple: slots 0 and 1 Int.
constexpr uint32_t TAGGER_KEY_MASK = 0x5;

// flags (C.1).
constexpr int64_t FLAG_VERSION_MASK = 0x3;   // 0 = HTTP/1.0, 1 = HTTP/1.1, 2 = HTTP/2
constexpr int64_t FLAG_TLS = 0x4;

} // namespace HttpServerManager

// The delivery hooks the HttpTables drain calls (httpManagerHasSubscriber,
// httpManagerDeliver) are declared in HttpTables.hpp.

} // namespace Eco::System

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (§3.6);
// returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_Http_Server();
}

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_MANAGER_HPP
