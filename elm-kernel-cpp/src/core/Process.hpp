#ifndef ECO_PROCESS_HPP
#define ECO_PROCESS_HPP

// elm/core's `Process` kernel module, which gives Elm `Process.sleep`: a Task that succeeds with `()` after a
// delay and can be cancelled by killing its process.
//
// This header declares nothing of its own; it includes the runtime's `platform/Scheduler.hpp`, which declares
// `Elm::Platform::Scheduler`, and no file includes it. The one kernel function, `Elm_Kernel_Process_sleep`, is
// declared in `KernelExports.h` and defined in `ProcessExports.cpp`. `Process.cpp` is an empty compilation
// unit.
//
// `Process.sleep` is a Task binding (see `makeAsyncBinding` in the runtime's `platform/TaskBinding.hpp`): each
// run of the Task parks its resume closure with `Scheduler::parkResume`, which also takes a hold that keeps
// the program running, and asks `TimerService` (`platform/TimerService.hpp`) for a timer carrying the
// returned resume token. When the timer fires, the scheduler resumes the parked closure. The Task's kill
// handle, the closure the scheduler applies to `()` when the process is killed, calls `withdrawParkedTimer`
// on the same token. Which of the two releases the hold is stated by `withdrawParkedTimer`.
#include "platform/Scheduler.hpp"

#endif // ECO_PROCESS_HPP
