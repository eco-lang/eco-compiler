#ifndef ELM_KERNEL_TIME_HPP
#define ELM_KERNEL_TIME_HPP

#include <string>
#include <functional>

namespace Elm::Kernel::Time {

// Forward declarations
struct Value;
struct Task;
struct Process;

// Get current POSIX time in milliseconds
Task* now();

// Get the local time zone
Task* here();

// Get the time zone name
Value* getZoneName();

// Set up an interval subscription
Process* setInterval(double interval, std::function<void(double)> callback);

} // namespace Elm::Kernel::Time

#endif // ELM_KERNEL_TIME_HPP
