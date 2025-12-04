#ifndef ELM_KERNEL_JSARRAY_HPP
#define ELM_KERNEL_JSARRAY_HPP

#include <cstddef>
#include <functional>

namespace Elm::Kernel::JsArray {

// Forward declarations
struct Value;
struct Array;
struct List;

// Create an empty array
Array* empty();

// Create a singleton array
Array* singleton(Value* value);

// Get array length
size_t length(Array* array);

// Initialize array with a function
Array* initialize(size_t len, size_t offset, std::function<Value*(size_t)> func);

// Initialize from a list, returning (array, remaining_list)
Array* initializeFromList(size_t max, List* list);

// Get element at index (unsafe - no bounds check)
Value* unsafeGet(size_t index, Array* array);

// Set element at index (unsafe - no bounds check)
Array* unsafeSet(size_t index, Value* value, Array* array);

// Push element to end
Array* push(Value* value, Array* array);

// Fold left over array
Value* foldl(std::function<Value*(Value*, Value*)> func, Value* acc, Array* array);

// Fold right over array
Value* foldr(std::function<Value*(Value*, Value*)> func, Value* acc, Array* array);

// Map over array
Array* map(std::function<Value*(Value*)> func, Array* array);

// Indexed map over array
Array* indexedMap(std::function<Value*(size_t, Value*)> func, size_t offset, Array* array);

// Slice array
Array* slice(int start, int end, Array* array);

// Append N elements from second array to first
Array* appendN(size_t n, Array* dest, Array* source);

} // namespace Elm::Kernel::JsArray

#endif // ELM_KERNEL_JSARRAY_HPP
