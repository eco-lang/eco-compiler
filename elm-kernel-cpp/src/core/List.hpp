#ifndef ELM_KERNEL_LIST_HPP
#define ELM_KERNEL_LIST_HPP

#include <functional>

namespace Elm::Kernel::List {

// Forward declarations
struct Value;
struct List;
struct Array;

// Cons - prepend element to list
List* cons(Value* head, List* tail);

// Convert array to list
List* fromArray(Array* array);

// Convert list to array
Array* toArray(List* list);

// Map over two lists in parallel
List* map2(std::function<Value*(Value*, Value*)> func, List* xs, List* ys);

// Map over three lists in parallel
List* map3(std::function<Value*(Value*, Value*, Value*)> func, List* xs, List* ys, List* zs);

// Map over four lists in parallel
List* map4(std::function<Value*(Value*, Value*, Value*, Value*)> func, List* ws, List* xs, List* ys, List* zs);

// Map over five lists in parallel
List* map5(std::function<Value*(Value*, Value*, Value*, Value*, Value*)> func, List* vs, List* ws, List* xs, List* ys, List* zs);

// Sort list by a key function
List* sortBy(std::function<Value*(Value*)> func, List* list);

// Sort list with a comparison function
List* sortWith(std::function<int(Value*, Value*)> func, List* list);

} // namespace Elm::Kernel::List

#endif // ELM_KERNEL_LIST_HPP
