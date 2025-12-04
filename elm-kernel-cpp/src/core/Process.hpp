#ifndef ELM_KERNEL_PROCESS_HPP
#define ELM_KERNEL_PROCESS_HPP

namespace Elm::Kernel::Process {

// Forward declarations
struct Task;

// Sleep for a given number of milliseconds
Task* sleep(double time);

} // namespace Elm::Kernel::Process

#endif // ELM_KERNEL_PROCESS_HPP
