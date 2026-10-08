//===- UdpManager.hpp - The C++ effect manager of Socket.Udp --------------===//
//
// plans/eco-system-sockets.md §3.5 and Appendix C.2 (manager key
// "Socket.Udp"). The Elm declaration lives in
// system-kernel-cpp/src/Socket/Udp.elm, section "EFFECT MANAGER":
//
//     type MySub msg = OnMessage Int (( Bytes, ( String, Int ) ) -> msg)
//     -- tag 0: [socketId unboxed Int (mask 0b01), tagger boxed]
//
// Tagger argument: DgramT (§3.2) = ( data, ( fromAddress, fromPort ) ): the
// outer tuple2 has mask 0, the inner one 0x4 (slot 1 Int).
//
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm).
// Keep the two in sync.
//
// The manager records the subscriptions (router and taggers per socket id,
// T5); delivery follows §3.4 (Udp.hpp declares the two hooks
// udpManagerHasSubscribers / udpManagerDeliver it implements).
//
// Templates used: T6 (manager), T5 (state), T8 (delivery).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_UDP_MANAGER_HPP
#define ECO_SYSTEM_SOCKET_UDP_MANAGER_HPP

#include <cstdint>

namespace Eco::System {

namespace UdpManager {

// MySub
constexpr uint16_t CTOR_ON_MESSAGE = 0;
constexpr int ON_MESSAGE_SOCKET_FIELD = 0;   // unboxed Int
constexpr int ON_MESSAGE_TAGGER_FIELD = 1;
constexpr uint64_t ON_MESSAGE_MASK = 0x1;    // slot 0 Int

// DgramT masks (§3.2).
constexpr uint32_t DGRAM_T_MASK = 0;      // ( Bytes, ( String, Int ) )
constexpr uint32_t DGRAM_FROM_MASK = 0x4; // ( String, Int )

} // namespace UdpManager

} // namespace Eco::System

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (base plan
// §3.6); returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_Socket_Udp();
}

#endif // ECO_SYSTEM_SOCKET_UDP_MANAGER_HPP
