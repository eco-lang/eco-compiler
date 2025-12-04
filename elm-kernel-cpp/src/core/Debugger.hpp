#ifndef ELM_KERNEL_DEBUGGER_HPP
#define ELM_KERNEL_DEBUGGER_HPP

#include <string>

namespace Elm::Kernel::Debugger {

// Forward declaration for generic Elm value
struct Value;
struct Model;

// Initialize the debugger
Value* init(Value* value);

// Check if debugger is open
bool isOpen();

// Open the debugger
void open();

// Scroll in the debugger history
void scroll(Value* args);

// Convert a message to string for display
std::string messageToString(Value* message);

// Download the debugger history
void download(Value* history);

// Upload debugger history
void upload(Value* args);

// Unsafe type coercion (for debugger internals)
Value* unsafeCoerce(Value* value);

} // namespace Elm::Kernel::Debugger

#endif // ELM_KERNEL_DEBUGGER_HPP
