//===- WsManager.hpp - The C++ effect manager of WebSocket ----------------===//
//
// plans/eco-system-websockets.md §3.6 and Appendix C.2 (manager key
// "WebSocket"). The Elm declaration lives in
// system-kernel-cpp/src/WebSocket.elm, section "EFFECT MANAGER":
//
//     type MySub msg
//         = OnMessage Int (( Int, String, Bytes ) -> msg)
//         | OnClose Int (( Int, String, Bool ) -> msg)
//     -- tag 0 / 1: [wsId unboxed Int (mask 0b01), tagger boxed]
//
// Tagger arguments: ( kind, text, bytes ) (the mapped-source tags of
// Appendix B.1; mask 0x1) and ( code, reason, clean ) (mask 0x1).
//
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm).
// Keep the two in sync.
//
// Phase WS4 (WsManager.cpp): a registry wsId → taggers of each kind; the
// first OnMessage of a connection attaches a subscription reader to its
// readable (Stream.hpp attachReader, retried on every onEffects while a
// read is parked), the last one detaches it; a message goes to every
// tagger in subscription order (T8, G12). OnClose: the CloseInfo is
// delivered once; a close with no subscriber is held for the first one.
// Keep-alive (§3.6): a connection with subscriptions holds one count while
// it is open (OnMessage) or until its close was delivered (OnClose).
//
// Templates used: T6 (manager).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_MANAGER_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace WsManager {

// MySub
constexpr uint16_t CTOR_ON_MESSAGE = 0;
constexpr uint16_t CTOR_ON_CLOSE = 1;
constexpr int SUB_WS_FIELD = 0;       // unboxed Int (both constructors)
constexpr int SUB_TAGGER_FIELD = 1;
constexpr uint64_t SUB_MASK = 0x1;    // slot 0 Int

// Tagger argument masks.
constexpr uint32_t MESSAGE_ARG_MASK = 0x1;   // ( Int, String, Bytes )
constexpr uint32_t CLOSE_ARG_MASK = 0x1;     // ( Int, String, Bool )

} // namespace WsManager

// Main thread, from the WsEvent drain: WebSocket `wsId` is Closed (its entry
// holds the CloseInfo): deliver it to the OnClose subscribers (sendToApp +
// drain per message) or hold it, and release the subscriptions' count.
void wsManagerOnClosed(int64_t wsId);

// True if some subscription names `wsId`.
bool wsManagerHasSubscribers(int64_t wsId);

} // namespace Eco::System

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (base plan
// §3.6); returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_WebSocket();
}

#endif // ECO_SYSTEM_WEBSOCKET_WS_MANAGER_HPP
