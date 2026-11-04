//===- SocketManager.hpp - The C++ effect manager of Socket ---------------===//
//
// Elm code subscribes to the connections a listener accepts with `Socket.onConnection`, and a subscription is
// carried out by an effect manager. This component is that manager, written in C++ and registered under the key
// "Socket".
//
// Two Elm effect-manager terms are used throughout. The *router* is the value the runtime passes to `onEffects`,
// through which a manager sends messages to the application. A *tagger* is the function a subscription carries,
// which turns what the manager delivers into the application's message.
//
// The Elm side declares the manager's subscription type in `system-kernel-cpp/src/Socket.elm`:
//
//     type MySub msg
//         = OnConnection Int (ConnArg -> msg)
//
// The `Int` is the listener id, stored unboxed; the tagger is boxed. A tagger receives the connection as a ConnT,
// the tuple `( connId, ( readableId, writableId ), ( localEp, remoteEp ) )` in which each endpoint is the tuple
// `( kind, text, port )`. The constants below are that layout as the heap stores it: constructor tags, field
// indexes, and the unboxed-field masks of each tuple. A mask gives each field two bits, field 0 in the lowest two;
// `0b01` marks an unboxed Int and `0` a boxed value. Tags are the zero-based declaration indexes of the
// constructors (`Compiler/Data/CtorTag.elm`), so a change to `MySub` must be made here too; nothing checks it.
//
// The manager keeps, for each listener id, the taggers of the subscriptions naming it, replaced as a whole each
// time the subscriptions change. The socket tables reach them only through `socketManagerHasSubscribers` and
// `socketManagerDeliver`, declared in `SocketTables.hpp` and defined here. There are no commands.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_SOCKET_MANAGER_HPP
#define ECO_SYSTEM_SOCKET_SOCKET_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace SocketManager {

/// The constructor tag of `OnConnection`, the only constructor of `MySub`.
constexpr uint16_t CTOR_ON_CONNECTION = 0;
/// The field index of an `OnConnection`'s listener id, an unboxed Int.
constexpr int ON_CONNECTION_LISTENER_FIELD = 0;
/// The field index of an `OnConnection`'s tagger, a boxed closure.
constexpr int ON_CONNECTION_TAGGER_FIELD = 1;
/// The unboxed-field mask of an `OnConnection`: field 0, the listener id, is an unboxed Int.
constexpr uint64_t ON_CONNECTION_MASK = 0x1;

/// The unboxed-field mask of a ConnT `( Int, ( Int, Int ), ( EpT, EpT ) )`: only the connection id is unboxed.
constexpr uint32_t CONN_T_MASK = 0x1;
/// The unboxed-field mask of a ConnT's stream id pair `( Int, Int )`: both ids are unboxed.
constexpr uint32_t CONN_IDS_MASK = 0x5;
/// The unboxed-field mask of a ConnT's endpoint pair `( EpT, EpT )`: both endpoints are boxed.
constexpr uint32_t CONN_ENDPOINTS_MASK = 0;
/// The unboxed-field mask of an endpoint `( Int, String, Int )`: the kind and the port are unboxed Ints.
constexpr uint32_t EP_T_MASK = 0x11;

} // namespace SocketManager

} // namespace Eco::System

extern "C" {
/// Registers the Socket effect manager with the platform runtime under the key "Socket", and returns the encoded
/// unit value. Generated code calls it from the `@__eco_register_ports` preamble. A C++ exception escaping the
/// registration is made fatal through `Eco::Kernel::reportFatal`.
uint64_t Eco_System_registerManager_Socket();
}

#endif // ECO_SYSTEM_SOCKET_SOCKET_MANAGER_HPP
