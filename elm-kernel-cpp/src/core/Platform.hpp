/// @file
/// The header for elm/core's `Platform` kernel module. It declares nothing of its own and only includes
/// `platform/Scheduler.hpp`; no kernel source currently includes it.
///
/// The module's C-linkage entry points are declared in `KernelExports.h` and defined in
/// `PlatformExports.cpp`. They are thin wrappers over the runtime's `Elm::Platform::PlatformRuntime` and
/// `Elm::Platform::PortRuntime`, which own effect managers, routers, ports and the event loop.

#ifndef ECO_PLATFORM_HPP
#define ECO_PLATFORM_HPP

#include "platform/Scheduler.hpp"

#endif // ECO_PLATFORM_HPP
