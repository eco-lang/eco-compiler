#include "List.hpp"
#include <stdexcept>
#include <vector>
#include <algorithm>

namespace Elm::Kernel::List {

/*
 * List representation in Elm/JS:
 *
 * var _List_Nil = { $: 0 };  // Empty list (PROD) or { $: '[]' } (DEBUG)
 *
 * function _List_Cons(hd, tl) { return { $: 1, a: hd, b: tl }; }  // PROD
 * // or { $: '::', a: hd, b: tl } (DEBUG)
 *
 * List is a singly-linked list:
 * - $.$ == 0 or '[]': Nil (empty)
 * - $.$ == 1 or '::': Cons node with head ($.a) and tail ($.b)
 *
 * In C++, we use a List struct with tag, head, and tail pointers.
 */

List* cons(Value* head, List* tail) {
    /*
     * JS: var _List_cons = F2(_List_Cons);
     *     function _List_Cons(hd, tl) { return { $: 1, a: hd, b: tl }; }
     *
     * PSEUDOCODE:
     * - Create a new Cons cell with given head and tail
     * - Return the new list node
     *
     * HELPERS: _List_Cons (constructor)
     * LIBRARIES: None (memory allocation)
     */
    // TODO: Allocate new Cons cell using runtime allocator
    throw std::runtime_error("Elm.Kernel.List.cons: needs runtime allocator integration");
}

List* fromArray(Array* array) {
    /*
     * JS: function _List_fromArray(arr)
     *     {
     *         var out = _List_Nil;
     *         for (var i = arr.length; i--; )
     *         {
     *             out = _List_Cons(arr[i], out);
     *         }
     *         return out;
     *     }
     *
     * PSEUDOCODE:
     * - Start with empty list (Nil)
     * - Iterate backwards through array
     * - For each element, prepend to list using Cons
     * - Return the resulting list
     *
     * NOTE: Iterating backwards ensures the list is in the same order
     * as the array (since cons prepends).
     *
     * HELPERS:
     * - _List_Nil (empty list constant)
     * - _List_Cons (constructs Cons cell)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Array and List types are available
    throw std::runtime_error("Elm.Kernel.List.fromArray: needs type integration");
}

Array* toArray(List* list) {
    /*
     * JS: function _List_toArray(xs)
     *     {
     *         for (var out = []; xs.b; xs = xs.b) // WHILE_CONS
     *         {
     *             out.push(xs.a);
     *         }
     *         return out;
     *     }
     *
     * PSEUDOCODE:
     * - Create empty output array
     * - While list is a Cons cell (has tail):
     *   - Push head to array
     *   - Move to tail
     * - Return array
     *
     * NOTE: xs.b being truthy means xs is a Cons (has tail).
     * When xs is Nil, xs.b is undefined (falsy), loop ends.
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array and List types are available
    throw std::runtime_error("Elm.Kernel.List.toArray: needs type integration");
}

List* map2(std::function<Value*(Value*, Value*)> func, List* xs, List* ys) {
    /*
     * JS: var _List_map2 = F3(function(f, xs, ys)
     *     {
     *         for (var arr = []; xs.b && ys.b; xs = xs.b, ys = ys.b) // WHILE_CONSES
     *         {
     *             arr.push(A2(f, xs.a, ys.a));
     *         }
     *         return _List_fromArray(arr);
     *     });
     *
     * PSEUDOCODE:
     * - Create empty array for results
     * - While both lists are non-empty (Cons):
     *   - Apply f to heads of both lists
     *   - Push result to array
     *   - Advance both lists to their tails
     * - Convert array to list and return
     *
     * NOTE: Stops when either list is exhausted (zip behavior).
     *
     * HELPERS:
     * - A2 (apply 2-argument function)
     * - _List_fromArray (converts array to list)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when types are available
    throw std::runtime_error("Elm.Kernel.List.map2: needs type integration");
}

List* map3(std::function<Value*(Value*, Value*, Value*)> func, List* xs, List* ys, List* zs) {
    /*
     * JS: var _List_map3 = F4(function(f, xs, ys, zs)
     *     {
     *         for (var arr = []; xs.b && ys.b && zs.b; xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
     *         {
     *             arr.push(A3(f, xs.a, ys.a, zs.a));
     *         }
     *         return _List_fromArray(arr);
     *     });
     *
     * PSEUDOCODE:
     * - Create empty array for results
     * - While all three lists are non-empty (Cons):
     *   - Apply f to heads of all three lists
     *   - Push result to array
     *   - Advance all lists to their tails
     * - Convert array to list and return
     *
     * HELPERS:
     * - A3 (apply 3-argument function)
     * - _List_fromArray (converts array to list)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when types are available
    throw std::runtime_error("Elm.Kernel.List.map3: needs type integration");
}

List* map4(std::function<Value*(Value*, Value*, Value*, Value*)> func, List* ws, List* xs, List* ys, List* zs) {
    /*
     * JS: var _List_map4 = F5(function(f, ws, xs, ys, zs)
     *     {
     *         for (var arr = []; ws.b && xs.b && ys.b && zs.b; ws = ws.b, xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
     *         {
     *             arr.push(A4(f, ws.a, xs.a, ys.a, zs.a));
     *         }
     *         return _List_fromArray(arr);
     *     });
     *
     * PSEUDOCODE:
     * - Create empty array for results
     * - While all four lists are non-empty (Cons):
     *   - Apply f to heads of all four lists
     *   - Push result to array
     *   - Advance all lists to their tails
     * - Convert array to list and return
     *
     * HELPERS:
     * - A4 (apply 4-argument function)
     * - _List_fromArray (converts array to list)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when types are available
    throw std::runtime_error("Elm.Kernel.List.map4: needs type integration");
}

List* map5(std::function<Value*(Value*, Value*, Value*, Value*, Value*)> func, List* vs, List* ws, List* xs, List* ys, List* zs) {
    /*
     * JS: var _List_map5 = F6(function(f, vs, ws, xs, ys, zs)
     *     {
     *         for (var arr = []; vs.b && ws.b && xs.b && ys.b && zs.b; vs = vs.b, ws = ws.b, xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
     *         {
     *             arr.push(A5(f, vs.a, ws.a, xs.a, ys.a, zs.a));
     *         }
     *         return _List_fromArray(arr);
     *     });
     *
     * PSEUDOCODE:
     * - Create empty array for results
     * - While all five lists are non-empty (Cons):
     *   - Apply f to heads of all five lists
     *   - Push result to array
     *   - Advance all lists to their tails
     * - Convert array to list and return
     *
     * HELPERS:
     * - A5 (apply 5-argument function)
     * - _List_fromArray (converts array to list)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when types are available
    throw std::runtime_error("Elm.Kernel.List.map5: needs type integration");
}

List* sortBy(std::function<Value*(Value*)> func, List* list) {
    /*
     * JS: var _List_sortBy = F2(function(f, xs)
     *     {
     *         return _List_fromArray(_List_toArray(xs).sort(function(a, b) {
     *             return __Utils_cmp(f(a), f(b));
     *         }));
     *     });
     *
     * PSEUDOCODE:
     * - Convert list to array
     * - Sort array using comparison function:
     *   - For each pair (a, b), compare f(a) with f(b)
     *   - Use Utils.cmp for Elm-compatible comparison
     * - Convert sorted array back to list
     * - Return result
     *
     * HELPERS:
     * - _List_toArray (converts list to array)
     * - _List_fromArray (converts array to list)
     * - __Utils_cmp (Elm comparison function returning -1, 0, or 1)
     *
     * LIBRARIES: std::sort (or manual sort implementation)
     */
    // TODO: Implement when types are available
    throw std::runtime_error("Elm.Kernel.List.sortBy: needs type integration");
}

List* sortWith(std::function<int(Value*, Value*)> func, List* list) {
    /*
     * JS: var _List_sortWith = F2(function(f, xs)
     *     {
     *         return _List_fromArray(_List_toArray(xs).sort(function(a, b) {
     *             var ord = A2(f, a, b);
     *             return ord === __Basics_EQ ? 0 : ord === __Basics_LT ? -1 : 1;
     *         }));
     *     });
     *
     * PSEUDOCODE:
     * - Convert list to array
     * - Sort array using custom comparison function:
     *   - Apply f(a, b) to get Elm Order (LT, EQ, GT)
     *   - Convert Order to numeric: EQ->0, LT->-1, GT->1
     * - Convert sorted array back to list
     * - Return result
     *
     * HELPERS:
     * - _List_toArray (converts list to array)
     * - _List_fromArray (converts array to list)
     * - A2 (apply 2-argument function)
     * - __Basics_EQ, __Basics_LT (Order constructors)
     *
     * LIBRARIES: std::sort (or manual sort implementation)
     */
    // TODO: Implement when types are available
    throw std::runtime_error("Elm.Kernel.List.sortWith: needs type integration");
}

} // namespace Elm::Kernel::List
