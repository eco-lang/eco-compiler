#include "JsArray.hpp"
#include <stdexcept>
#include <algorithm>

namespace Elm::Kernel::JsArray {

/*
 * JsArray is a mutable JavaScript array used internally by Elm's Array type.
 * Elm's Array uses a relaxed radix balanced tree (RRB tree) structure,
 * and JsArray provides the leaf node operations.
 *
 * IMPORTANT: These operations create NEW arrays (immutable semantics)
 * rather than mutating in place.
 */

Array* empty() {
    /*
     * JS: var _JsArray_empty = [];
     *
     * PSEUDOCODE:
     * - Return an empty array
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.empty: needs Array type integration");
}

Array* singleton(Value* value) {
    /*
     * JS: function _JsArray_singleton(value) { return [value]; }
     *
     * PSEUDOCODE:
     * - Create array with single element
     * - Return the array
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.singleton: needs Array type integration");
}

size_t length(Array* array) {
    /*
     * JS: function _JsArray_length(array) { return array.length; }
     *
     * PSEUDOCODE:
     * - Return the length of the array
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.length: needs Array type integration");
}

Array* initialize(size_t len, size_t offset, std::function<Value*(size_t)> func) {
    /*
     * JS: var _JsArray_initialize = F3(function(size, offset, func)
     *     {
     *         var result = new Array(size);
     *         for (var i = 0; i < size; i++)
     *         {
     *             result[i] = func(offset + i);
     *         }
     *         return result;
     *     });
     *
     * PSEUDOCODE:
     * - Create new array of given size
     * - For each index i from 0 to size-1:
     *   - Call func(offset + i) to get value
     *   - Store result at index i
     * - Return the array
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.initialize: needs Array type integration");
}

Array* initializeFromList(size_t max, List* list) {
    /*
     * JS: var _JsArray_initializeFromList = F2(function (max, ls)
     *     {
     *         var result = new Array(max);
     *         for (var i = 0; i < max && ls.b; i++)
     *         {
     *             result[i] = ls.a;
     *             ls = ls.b;
     *         }
     *         result.length = i;
     *         return __Utils_Tuple2(result, ls);
     *     });
     *
     * PSEUDOCODE:
     * - Create new array of max size
     * - Copy up to max elements from list to array
     * - Stop when max reached or list exhausted
     * - Trim array to actual number of elements copied
     * - Return tuple of (array, remaining list)
     *
     * NOTE: Returns both the array AND the unconsumed portion of the list.
     * This is used for efficiently building RRB tree leaves from lists.
     *
     * HELPERS:
     * - __Utils_Tuple2 (creates 2-tuple)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Array and List types are available
    throw std::runtime_error("Elm.Kernel.JsArray.initializeFromList: needs type integration");
}

Value* unsafeGet(size_t index, Array* array) {
    /*
     * JS: var _JsArray_unsafeGet = F2(function(index, array) { return array[index]; });
     *
     * PSEUDOCODE:
     * - Return element at given index
     * - No bounds checking (caller must ensure valid index)
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.unsafeGet: needs Array type integration");
}

Array* unsafeSet(size_t index, Value* value, Array* array) {
    /*
     * JS: var _JsArray_unsafeSet = F3(function(index, value, array)
     *     {
     *         var length = array.length;
     *         var result = new Array(length);
     *         for (var i = 0; i < length; i++)
     *         {
     *             result[i] = array[i];
     *         }
     *         result[index] = value;
     *         return result;
     *     });
     *
     * PSEUDOCODE:
     * - Create new array of same length
     * - Copy all elements from original
     * - Set element at index to new value
     * - Return new array (original unchanged - immutable!)
     *
     * NOTE: Despite "unsafe" name, this creates a copy.
     * The "unsafe" refers to no bounds checking.
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.unsafeSet: needs Array type integration");
}

Array* push(Value* value, Array* array) {
    /*
     * JS: var _JsArray_push = F2(function(value, array)
     *     {
     *         var length = array.length;
     *         var result = new Array(length + 1);
     *         for (var i = 0; i < length; i++)
     *         {
     *             result[i] = array[i];
     *         }
     *         result[length] = value;
     *         return result;
     *     });
     *
     * PSEUDOCODE:
     * - Create new array with length + 1
     * - Copy all elements from original
     * - Append new value at end
     * - Return new array (immutable - original unchanged)
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.push: needs Array type integration");
}

Value* foldl(std::function<Value*(Value*, Value*)> func, Value* acc, Array* array) {
    /*
     * JS: var _JsArray_foldl = F3(function(func, acc, array)
     *     {
     *         var length = array.length;
     *         for (var i = 0; i < length; i++)
     *         {
     *             acc = A2(func, array[i], acc);
     *         }
     *         return acc;
     *     });
     *
     * PSEUDOCODE:
     * - Initialize accumulator with acc
     * - Iterate left-to-right through array
     * - For each element: acc = func(element, acc)
     * - Return final accumulator
     *
     * HELPERS:
     * - A2 (apply 2-argument function)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.foldl: needs Array type integration");
}

Value* foldr(std::function<Value*(Value*, Value*)> func, Value* acc, Array* array) {
    /*
     * JS: var _JsArray_foldr = F3(function(func, acc, array)
     *     {
     *         for (var i = array.length - 1; i >= 0; i--)
     *         {
     *             acc = A2(func, array[i], acc);
     *         }
     *         return acc;
     *     });
     *
     * PSEUDOCODE:
     * - Initialize accumulator with acc
     * - Iterate right-to-left through array
     * - For each element: acc = func(element, acc)
     * - Return final accumulator
     *
     * HELPERS:
     * - A2 (apply 2-argument function)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.foldr: needs Array type integration");
}

Array* map(std::function<Value*(Value*)> func, Array* array) {
    /*
     * JS: var _JsArray_map = F2(function(func, array)
     *     {
     *         var length = array.length;
     *         var result = new Array(length);
     *         for (var i = 0; i < length; i++)
     *         {
     *             result[i] = func(array[i]);
     *         }
     *         return result;
     *     });
     *
     * PSEUDOCODE:
     * - Create new array of same length
     * - For each element, apply func and store result
     * - Return new array
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.map: needs Array type integration");
}

Array* indexedMap(std::function<Value*(size_t, Value*)> func, size_t offset, Array* array) {
    /*
     * JS: var _JsArray_indexedMap = F3(function(func, offset, array)
     *     {
     *         var length = array.length;
     *         var result = new Array(length);
     *         for (var i = 0; i < length; i++)
     *         {
     *             result[i] = A2(func, offset + i, array[i]);
     *         }
     *         return result;
     *     });
     *
     * PSEUDOCODE:
     * - Create new array of same length
     * - For each element at index i:
     *   - Apply func(offset + i, element)
     *   - Store result
     * - Return new array
     *
     * NOTE: offset is added to index, useful for RRB tree traversal
     * where leaf arrays need to know their absolute position.
     *
     * HELPERS:
     * - A2 (apply 2-argument function)
     *
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.indexedMap: needs Array type integration");
}

Array* slice(int start, int end, Array* array) {
    /*
     * JS: var _JsArray_slice = F3(function(from, to, array) { return array.slice(from, to); });
     *
     * PSEUDOCODE:
     * - Extract subarray from start (inclusive) to end (exclusive)
     * - Handle negative indices (from end)
     * - Return new array with sliced elements
     *
     * HELPERS: None
     * LIBRARIES: None (std::vector::assign or similar)
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.slice: needs Array type integration");
}

Array* appendN(size_t n, Array* dest, Array* source) {
    /*
     * JS: var _JsArray_appendN = F3(function(n, dest, source)
     *     {
     *         var destLen = dest.length;
     *         var itemsToCopy = n - destLen;
     *         if (itemsToCopy > source.length)
     *         {
     *             itemsToCopy = source.length;
     *         }
     *         var size = destLen + itemsToCopy;
     *         var result = new Array(size);
     *         for (var i = 0; i < destLen; i++)
     *         {
     *             result[i] = dest[i];
     *         }
     *         for (var i = 0; i < itemsToCopy; i++)
     *         {
     *             result[i + destLen] = source[i];
     *         }
     *         return result;
     *     });
     *
     * PSEUDOCODE:
     * - Calculate items to copy: min(n - dest.length, source.length)
     * - Create new array of size dest.length + itemsToCopy
     * - Copy all elements from dest
     * - Copy itemsToCopy elements from start of source
     * - Return new array
     *
     * NOTE: This is used for RRB tree rebalancing. The target size is n,
     * so we copy enough from source to reach that size (or all of source).
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: Implement when Array type is available
    throw std::runtime_error("Elm.Kernel.JsArray.appendN: needs Array type integration");
}

} // namespace Elm::Kernel::JsArray
