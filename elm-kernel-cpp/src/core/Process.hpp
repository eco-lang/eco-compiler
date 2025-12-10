#ifndef ECO_PROCESS_HPP
#define ECO_PROCESS_HPP

namespace Elm::Kernel::Process {

// Forward declarations.
struct Task;

// Creates a task that sleeps for the given number of milliseconds.
Task* sleep(double time);

} // namespace Elm::Kernel::Process

#endif // ECO_PROCESS_HPP
