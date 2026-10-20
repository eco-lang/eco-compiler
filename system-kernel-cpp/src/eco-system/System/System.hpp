//===- System.hpp - eco/system kernel module System (internal) ------------===//
//
// plans/eco-system-library.md Appendix B.1: the binding bodies of
// Eco.Kernel.System (System.cpp), bound by SystemExports.cpp. The effect
// manager is in SystemManager.{hpp,cpp} (Appendix C.1).
//
// Templates used: T1.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SYSTEM_SYSTEM_HPP
#define ECO_SYSTEM_SYSTEM_SYSTEM_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

HPointer systemEnvironmentNow();
HPointer systemGetEnvironmentVariablesBody(HPointer captured);
HPointer systemExitWithCodeBody(HPointer captured);
HPointer systemSetExitCodeBody(HPointer captured);
HPointer systemRearmEmptyEventLoopBody(HPointer captured);

} // namespace Eco::System

#endif // ECO_SYSTEM_SYSTEM_SYSTEM_HPP
