#ifndef ELM_KERNEL_UTILS_HPP
#define ELM_KERNEL_UTILS_HPP

namespace Elm::Kernel::Utils {

// Forward declarations
struct Value;

// Append two appendable values (strings or lists)
Value* append(Value* a, Value* b);

// Compare two comparable values
// Returns -1, 0, or 1
int compare(Value* a, Value* b);

// Check equality of two values
bool equal(Value* a, Value* b);

// Check inequality of two values
bool notEqual(Value* a, Value* b);

// Less than comparison
bool lt(Value* a, Value* b);

// Less than or equal comparison
bool le(Value* a, Value* b);

// Greater than comparison
bool gt(Value* a, Value* b);

// Greater than or equal comparison
bool ge(Value* a, Value* b);

} // namespace Elm::Kernel::Utils

#endif // ELM_KERNEL_UTILS_HPP
