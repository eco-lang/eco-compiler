#ifndef ECO_SCHEDULER_HPP
#define ECO_SCHEDULER_HPP

// Forwards to the runtime's `platform/Scheduler.hpp`, which declares `Elm::Platform::Scheduler`, the singleton
// that runs Elm Tasks and processes. This header declares nothing of its own. The C-linkage exports of
// elm/core's `Scheduler` kernel module, defined in `SchedulerExports.cpp`, include the runtime header directly.
#include "platform/Scheduler.hpp"

#endif // ECO_SCHEDULER_HPP
