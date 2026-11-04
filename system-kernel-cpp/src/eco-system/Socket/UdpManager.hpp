//===- UdpManager.hpp - The C++ effect manager of Socket.Udp --------------===//
//
// An Elm program subscribes to the datagrams of a bound UDP socket with `Socket.Udp.onMessage`, and on the native
// backend those subscriptions are kept by a C++ effect manager, registered with the platform runtime under the key
// "Socket.Udp". This header holds the `OnMessage` layout constants that manager reads, the two DgramT kind masks
// `buildDgramT` in `Udp.cpp` builds a datagram with, and the export that registers it.
//
// The manager knows a subscription only by its constructor layout. In `system-kernel-cpp/src/Socket/Udp.elm`, with the
// alias `DatagramArg` written out, it is
//
//     type MySub msg = OnMessage Int (( Bytes, ( String, Int ) ) -> msg)
//
// The socket id is an unboxed Int in slot 0 and the tagger a boxed closure in slot 1. A constructor's tag is its
// zero-based index in the declaration, so the constants below must change whenever that declaration does; nothing
// checks that they agree.
//
// A tagger is called with a DgramT, the received datagram as the Elm value `( data, ( fromAddress, fromPort ) )`.
//
// At each subscription update the manager replaces the taggers it holds for every socket id, and each datagram
// delivered to a socket goes to every tagger of that socket, in subscription order. It has no commands. On Windows
// a non-empty subscription list is fatal.
//
// The manager also implements the two delivery hooks `Udp.hpp` declares, `udpManagerHasSubscribers` and
// `udpManagerDeliver`, which carry their own contracts there.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_UDP_MANAGER_HPP
#define ECO_SYSTEM_SOCKET_UDP_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace UdpManager {

/// The constructor tag of `OnMessage`, the only constructor of `MySub`.
constexpr uint16_t CTOR_ON_MESSAGE = 0;
/// The slot of an `OnMessage` value that holds the socket id, as an unboxed Int.
constexpr int ON_MESSAGE_SOCKET_FIELD = 0;
/// The slot of an `OnMessage` value that holds the tagger closure.
constexpr int ON_MESSAGE_TAGGER_FIELD = 1;
/// The kind mask of an `OnMessage` value: slot 0 is an unboxed Int, slot 1 is boxed.
constexpr uint64_t ON_MESSAGE_MASK = 0x1;

/// The kind mask of the outer DgramT tuple `( data, from )`: both slots boxed. `buildDgramT` builds it with this.
constexpr uint32_t DGRAM_T_MASK = 0;
/// The kind mask of the DgramT's `( fromAddress, fromPort )` tuple: the port in slot 1 is an unboxed Int.
/// `buildDgramT` builds it with this.
constexpr uint32_t DGRAM_FROM_MASK = 0x4;

} // namespace UdpManager

} // namespace Eco::System

extern "C" {
/// Registers the Socket.Udp effect manager with the platform runtime under the key "Socket.Udp", and returns the
/// encoded unit value. Generated code calls it from the `@__eco_register_ports` preamble. A C++ exception escaping the
/// registration is made fatal through `Eco::Kernel::reportFatal`.
uint64_t Eco_System_registerManager_Socket_Udp();
}

#endif // ECO_SYSTEM_SOCKET_UDP_MANAGER_HPP
