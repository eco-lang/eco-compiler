//===- WsManager.hpp - The C++ effect manager of WebSocket ----------------===//
//
// An Elm program learns what arrives on a WebSocket through subscriptions, and this component is the native effect
// manager, registered under the key "WebSocket", that serves them.
//
// `src/WebSocket.elm` declares the subscription type, in its "EFFECT MANAGER" section:
//
//     type MySub msg
//         = OnMessage Int (( Int, String, Bytes ) -> msg)
//         | OnClose Int (( Int, String, Bool ) -> msg)
//
// Both constructors name a WebSocket by its id, the key of its entry in `WsTables`, and carry a tagger: the function
// that turns what the subscription reports into a message for the program. An `OnMessage` tagger is given
// `( tag, text, bytes )` for each message received, where `tag` is the chunk's `ChannelResult::tag` and a text message
// fills `text` and leaves `bytes` empty, a binary one the reverse. An `OnClose` tagger is given
// `( code, reason, clean )`, the `WsCloseInfo` of the WebSocket's end, once. The constants below mirror that
// declaration. Constructor tags are the zero-based declaration indexes, and nothing checks them against the Elm file,
// so the two must be kept in sync by hand.
//
// Messages are not queued here. A WebSocket's received messages are its readable stream, and while some `OnMessage`
// subscription names the WebSocket the manager attaches a subscription reader to that readable (`attachReader`), so
// that each message is handed to every `OnMessage` tagger as it is read. When the last such subscription goes, the
// reader is detached and later messages wait on the readable for an ordinary read. Attaching fails while the readable
// is in use, for instance by a parked read, and is tried again whenever the manager next reconciles the WebSocket.
//
// The end of a WebSocket is reported by `wsManagerOnClosed`. A close is delivered only after every message read before
// it: while a reader is attached and has not yet seen the readable's end, the close waits for it. A close that finds no
// `OnClose` subscriber is held, in the WebSocket's `WsTables` entry or, once that is erased, in its record among the
// recently closed WebSockets (while the record lasts), and is delivered once an `OnClose` subscription names the
// WebSocket and no reader holds it back. A WebSocket's close is delivered at most once.
//
// The manager keeps at most one Scheduler hold (a liveness count that keeps the program running) per WebSocket that
// has an entry in `WsTables` or an undelivered close in its recently closed record. It holds it while an `OnMessage`
// subscription names the WebSocket and the WebSocket has not ended or still has messages to deliver, or while an
// `OnClose` subscription names it and its close has not been delivered. All of this runs on the eco thread.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_MANAGER_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace WsManager {

/// The constructor tag of `OnMessage`.
constexpr uint16_t CTOR_ON_MESSAGE = 0;
/// The constructor tag of `OnClose`.
constexpr uint16_t CTOR_ON_CLOSE = 1;
/// The field of a `MySub` that holds the WebSocket id, an unboxed Int in both constructors.
constexpr int SUB_WS_FIELD = 0;
/// The field of a `MySub` that holds the tagger.
constexpr int SUB_TAGGER_FIELD = 1;
/// The unboxed-field mask of a `MySub`: the id is an unboxed Int and the tagger is boxed.
constexpr uint64_t SUB_MASK = 0x1;

/// The unboxed-field mask of the `( tag, text, bytes )` tuple given to an `OnMessage` tagger: `tag` is an unboxed
/// Int and the other two are boxed.
constexpr uint32_t MESSAGE_ARG_MASK = 0x1;
/// The unboxed-field mask of the `( code, reason, clean )` tuple given to an `OnClose` tagger: `code` is an unboxed
/// Int and the other two are boxed, the Bool included.
constexpr uint32_t CLOSE_ARG_MASK = 0x1;

} // namespace WsManager

/// Reports that WebSocket `wsId` has ended, its entry holding the `WsCloseInfo`.
///
/// Delivers the close to the `OnClose` subscribers, running the scheduler after each message, unless there are none or
/// the attached reader has not yet seen the readable's end, in which case the close is not delivered now. Then updates
/// the WebSocket's hold and, once no subscription, reader or hold of this manager refers to the WebSocket, asks
/// `wsTablesRetire` to erase its entry if nothing else still needs it. Eco thread only; it calls Elm code.
void wsManagerOnClosed(int64_t wsId);

/// Returns whether some subscription, of either kind, names WebSocket `wsId`. Eco thread only.
bool wsManagerHasSubscribers(int64_t wsId);

} // namespace Eco::System

extern "C" {
/// Registers this effect manager under "WebSocket", and returns the Unit value. It is meant to be called from the
/// compiler-emitted `@__eco_register_ports` preamble, on the eco thread. The manager has no commands: its cmdMap is
/// registered as the empty list.
uint64_t Eco_System_registerManager_WebSocket();
}

#endif // ECO_SYSTEM_WEBSOCKET_WS_MANAGER_HPP
