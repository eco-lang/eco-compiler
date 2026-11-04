// The `Eco.Env` kernel: a program's environment variables and command-line arguments, read when the Task that
// asks for them is run.
//
// A kernel function that returns a Task must do its IO when the Task is run, not when the function is called.
// So `lookup` and `rawArgs` only build a Binding Task (`Eco::Kernel::makeBinding` in `TaskBinding.hpp`); the
// `getenv` call or the walk over the arguments happens each time the scheduler steps that Task. The arguments
// come from `init`, which keeps the `argc`/`argv` it is given rather than copying them.

#ifndef ECO_ENV_HPP
#define ECO_ENV_HPP

#include <cstdint>

namespace Eco::Kernel::Env {

/// Records `argc` and `argv` as the arguments that `rawArgs` Tasks report. Intended to be called before any
/// Elm code runs.
///
/// `argv` is kept, not copied: the array and its strings must stay valid for as long as a `rawArgs` Task can
/// be stepped. Until `init` is called, `rawArgs` Tasks report no arguments.
void init(int argc, char** argv);

/// Returns the word of a new Task that, when run, succeeds with `Just` the value of the environment variable
/// named by the Elm String `name`, or `Nothing` if it is not set. A GC point.
///
/// The variable is read each time the Task is run, not when this is called. The Task keeps `name` reachable.
uint64_t lookup(uint64_t name);

/// Returns the word of a new Task that, when run, succeeds with a List of the command-line arguments recorded
/// by `init`, in order, without `argv[0]` (the program name). A GC point.
///
/// The arguments are read each time the Task is run, not when this is called.
uint64_t rawArgs();

} // namespace Eco::Kernel::Env

#endif // ECO_ENV_HPP
