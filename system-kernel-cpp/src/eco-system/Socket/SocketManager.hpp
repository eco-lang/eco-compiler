//===- SocketManager.hpp - The C++ effect manager of Socket ---------------===//
//
// plans/eco-system-sockets.md §3.5 and Appendix C.1 (manager key "Socket").
// The Elm declaration lives in system-kernel-cpp/src/Socket.elm, section
// "EFFECT MANAGER":
//
//     type MySub msg
//         = OnConnection Int (( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) ) -> msg)
//     -- tag 0: [listenerId unboxed Int (mask 0b01), tagger boxed]
//
// Tagger argument: ConnT (§3.2) = ( connId, ( readableId, writableId ),
// ( localEpT, remoteEpT ) ): the outer tuple3 has mask 0x1 (slot 0 Int), the
// id pair 0x5, the endpoint pair 0; each EpT ( kind, text, port ) has mask
// 0x11 (slots 0 and 2 Int).
//
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm).
// Keep the two in sync.
//
// The manager records the subscriptions (router and taggers per listener
// id, T5); delivery follows §3.4 (SocketTables.hpp declares the two hooks
// socketManagerHasSubscribers / socketManagerDeliver it implements).
//
// Templates used: T6 (manager), T5 (state), T8 (delivery).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_SOCKET_MANAGER_HPP
#define ECO_SYSTEM_SOCKET_SOCKET_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace SocketManager {

// MySub
constexpr uint16_t CTOR_ON_CONNECTION = 0;
constexpr int ON_CONNECTION_LISTENER_FIELD = 0;   // unboxed Int
constexpr int ON_CONNECTION_TAGGER_FIELD = 1;
constexpr uint64_t ON_CONNECTION_MASK = 0x1;      // slot 0 Int

// ConnT masks (§3.2).
constexpr uint32_t CONN_T_MASK = 0x1;        // ( Int, ( Int, Int ), ( EpT, EpT ) )
constexpr uint32_t CONN_IDS_MASK = 0x5;      // ( Int, Int )
constexpr uint32_t CONN_ENDPOINTS_MASK = 0;  // ( EpT, EpT )
constexpr uint32_t EP_T_MASK = 0x11;         // ( Int, String, Int )

} // namespace SocketManager

} // namespace Eco::System

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (base plan
// §3.6); returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_Socket();
}

#endif // ECO_SYSTEM_SOCKET_SOCKET_MANAGER_HPP
