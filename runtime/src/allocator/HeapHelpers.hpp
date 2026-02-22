/**
 * Heap Allocation Helpers for Elm Runtime.
 *
 * This file provides high-level allocation utilities for creating Elm values
 * on the GC-managed heap. These helpers abstract the low-level allocator
 * interface and handle header initialization, unboxing decisions, and
 * pointer wrapping.
 *
 * Usage Pattern:
 *   auto& alloc = Allocator::instance();
 *   HPointer str = alloc::allocString(u"Hello");
 *   HPointer list = alloc::cons(Unboxable{.i = 42}, listNil(), true);
 *
 * Key concepts:
 *   - HPointer: Logical pointer (40-bit offset) for heap references
 *   - Unboxable: Union of i64/f64/char16_t/HPointer for polymorphic storage
 *   - Embedded constants: Nil, True, False, Unit, Nothing stored in HPointer
 *   - Unboxing: Primitives stored directly without heap allocation
 */

#ifndef ECO_HEAP_HELPERS_H
#define ECO_HEAP_HELPERS_H

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "Heap.hpp"
#include <cstring>
#include <string>
#include <vector>
#include <initializer_list>

namespace Elm {
namespace alloc {

// ============================================================================
// Embedded Constants
// ============================================================================

/**
 * Returns an HPointer representing the Nil constant (empty list).
 */
inline HPointer listNil() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nil + 1;  // +1 because 0 means "real pointer"
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the Unit constant ().
 */
inline HPointer unit() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Unit + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the True boolean.
 */
inline HPointer elmTrue() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_True + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the False boolean.
 */
inline HPointer elmFalse() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_False + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing Nothing (Maybe).
 */
inline HPointer nothing() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nothing + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing the empty string.
 */
inline HPointer emptyString() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_EmptyString + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Returns an HPointer representing an empty record {}.
 */
inline HPointer emptyRecord() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_EmptyRec + 1;
    ptr.padding = 0;
    return ptr;
}

/**
 * Checks if an HPointer is an embedded constant.
 */
inline bool isConstant(HPointer ptr) {
    return ptr.constant != 0;
}

/**
 * Returns true if pointer represents Nil (empty list).
 */
inline bool isNil(HPointer ptr) {
    return ptr.constant == Const_Nil + 1;
}

// ============================================================================
// Primitive Allocation
// ============================================================================

/**
 * Allocates a boxed Int on the heap.
 *
 * In most cases, prefer storing ints unboxed in container fields.
 * Only use this when a heap-allocated Int object is required.
 */
inline HPointer allocInt(i64 value) {
    auto& allocator = Allocator::instance();
    ElmInt* obj = static_cast<ElmInt*>(allocator.allocate(sizeof(ElmInt), Tag_Int));
    obj->header.size = 0;
    obj->value = value;
    return allocator.wrap(obj);
}

/**
 * Allocates a boxed Float on the heap.
 *
 * In most cases, prefer storing floats unboxed in container fields.
 * Only use this when a heap-allocated Float object is required.
 */
inline HPointer allocFloat(f64 value) {
    auto& allocator = Allocator::instance();
    ElmFloat* obj = static_cast<ElmFloat*>(allocator.allocate(sizeof(ElmFloat), Tag_Float));
    obj->header.size = 0;
    obj->value = value;
    return allocator.wrap(obj);
}

/**
 * Allocates a boxed Char on the heap.
 *
 * In most cases, prefer storing chars unboxed in container fields.
 * Only use this when a heap-allocated Char object is required.
 */
inline HPointer allocChar(u16 value) {
    auto& allocator = Allocator::instance();
    ElmChar* obj = static_cast<ElmChar*>(allocator.allocate(sizeof(ElmChar), Tag_Char));
    obj->header.size = 0;
    obj->value = value;
    return allocator.wrap(obj);
}

// ============================================================================
// Unboxable Helpers
// ============================================================================

/**
 * Creates an Unboxable containing an unboxed integer.
 */
inline Unboxable unboxedInt(i64 value) {
    Unboxable u;
    u.i = value;
    return u;
}

/**
 * Creates an Unboxable containing an unboxed float.
 */
inline Unboxable unboxedFloat(f64 value) {
    Unboxable u;
    u.f = value;
    return u;
}

/**
 * Creates an Unboxable containing an unboxed char.
 */
inline Unboxable unboxedChar(u16 value) {
    Unboxable u;
    u.c = value;
    return u;
}

/**
 * Creates an Unboxable containing a heap pointer.
 */
inline Unboxable boxed(HPointer ptr) {
    Unboxable u;
    u.p = ptr;
    return u;
}

// ============================================================================
// String Allocation
// ============================================================================

/**
 * Allocates an ElmString from a UTF-16 buffer.
 *
 * @param chars  Pointer to UTF-16 code units.
 * @param length Number of code units.
 * @return HPointer to the allocated string.
 *
 * Returns the empty string constant for zero-length input.
 */
inline HPointer allocString(const u16* chars, size_t length) {
    if (length == 0) {
        return emptyString();
    }

    auto& allocator = Allocator::instance();
    size_t data_size = length * sizeof(u16);
    size_t total_size = sizeof(ElmString) + data_size;
    // Round up to 8-byte alignment
    total_size = (total_size + 7) & ~7;

    ElmString* str = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
    str->header.size = static_cast<u32>(length);
    std::memcpy(str->chars, chars, data_size);

    return allocator.wrap(str);
}

/**
 * Allocates an ElmString from a std::u16string.
 */
inline HPointer allocString(const std::u16string& s) {
    return allocString(reinterpret_cast<const u16*>(s.data()), s.size());
}

/**
 * Allocates an ElmString from a UTF-8 std::string.
 * Converts UTF-8 to UTF-16 internally.
 */
inline HPointer allocStringFromUTF8(const std::string& utf8) {
    if (utf8.empty()) {
        return emptyString();
    }

    // Simple UTF-8 to UTF-16 conversion
    std::u16string utf16;
    utf16.reserve(utf8.size());

    size_t i = 0;
    while (i < utf8.size()) {
        uint32_t codepoint;
        unsigned char c = static_cast<unsigned char>(utf8[i]);

        if ((c & 0x80) == 0) {
            // 1-byte sequence (ASCII)
            codepoint = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            // 2-byte sequence
            codepoint = (c & 0x1F) << 6;
            if (i + 1 < utf8.size()) {
                codepoint |= (utf8[i + 1] & 0x3F);
            }
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte sequence
            codepoint = (c & 0x0F) << 12;
            if (i + 1 < utf8.size()) codepoint |= (utf8[i + 1] & 0x3F) << 6;
            if (i + 2 < utf8.size()) codepoint |= (utf8[i + 2] & 0x3F);
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte sequence (produces surrogate pair)
            codepoint = (c & 0x07) << 18;
            if (i + 1 < utf8.size()) codepoint |= (utf8[i + 1] & 0x3F) << 12;
            if (i + 2 < utf8.size()) codepoint |= (utf8[i + 2] & 0x3F) << 6;
            if (i + 3 < utf8.size()) codepoint |= (utf8[i + 3] & 0x3F);
            i += 4;
        } else {
            // Invalid byte, skip
            i += 1;
            continue;
        }

        // Convert codepoint to UTF-16
        if (codepoint <= 0xFFFF) {
            utf16.push_back(static_cast<char16_t>(codepoint));
        } else if (codepoint <= 0x10FFFF) {
            // Surrogate pair
            codepoint -= 0x10000;
            utf16.push_back(static_cast<char16_t>(0xD800 | (codepoint >> 10)));
            utf16.push_back(static_cast<char16_t>(0xDC00 | (codepoint & 0x3FF)));
        }
    }

    return allocString(utf16);
}

/**
 * Returns the length (in code units) of an ElmString.
 */
inline size_t stringLength(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    return s->header.size;
}

/**
 * Returns a pointer to the character data of an ElmString.
 */
inline const u16* stringData(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    return s->chars;
}

// ============================================================================
// List Allocation
// ============================================================================

/**
 * Allocates a Cons cell for building lists.
 *
 * @param head      The head value (may be boxed or unboxed).
 * @param tail      Pointer to the tail list (or Nil).
 * @param head_is_boxed  True if head contains a heap pointer.
 * @return HPointer to the allocated Cons cell.
 *
 * The unboxed flag is stored in the header for GC scanning.
 */
inline HPointer cons(Unboxable head, HPointer tail, bool head_is_boxed) {
    auto& allocator = Allocator::instance();
    Cons* cell = static_cast<Cons*>(allocator.allocate(sizeof(Cons), Tag_Cons));
    cell->header.size = 0;
    cell->header.unboxed = head_is_boxed ? 0 : 1;  // unboxed=1 means head is primitive
    cell->head = head;
    cell->tail = tail;
    return allocator.wrap(cell);
}

/**
 * Builds a list from a vector of boxed HPointers.
 * All elements are treated as boxed pointers.
 *
 * @param elements Vector of HPointers (first element becomes head).
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromPointers(const std::vector<HPointer>& elements) {
    HPointer result = listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = cons(boxed(*it), result, true);
    }
    return result;
}

/**
 * Builds a list from a vector of unboxed integers.
 *
 * @param elements Vector of i64 values.
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromInts(const std::vector<i64>& elements) {
    HPointer result = listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = cons(unboxedInt(*it), result, false);
    }
    return result;
}

/**
 * Builds a list from a vector of unboxed floats.
 *
 * @param elements Vector of f64 values.
 * @return HPointer to the list head (or Nil if empty).
 */
inline HPointer listFromFloats(const std::vector<f64>& elements) {
    HPointer result = listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = cons(unboxedFloat(*it), result, false);
    }
    return result;
}

// ============================================================================
// Tuple Allocation
// ============================================================================

/**
 * Allocates a Tuple2.
 *
 * @param a           First element.
 * @param b           Second element.
 * @param unboxed_mask Bitmask: bit 0 = a is unboxed, bit 1 = b is unboxed.
 * @return HPointer to the allocated tuple.
 */
inline HPointer tuple2(Unboxable a, Unboxable b, u32 unboxed_mask) {
    auto& allocator = Allocator::instance();
    Tuple2* tuple = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    tuple->header.size = 0;
    tuple->header.unboxed = unboxed_mask & 0x3;  // Only 2 bits used for Tuple2
    tuple->a = a;
    tuple->b = b;
    return allocator.wrap(tuple);
}

/**
 * Allocates a Tuple3.
 *
 * @param a           First element.
 * @param b           Second element.
 * @param c           Third element.
 * @param unboxed_mask Bitmask: bit 0 = a, bit 1 = b, bit 2 = c is unboxed.
 * @return HPointer to the allocated tuple.
 */
inline HPointer tuple3(Unboxable a, Unboxable b, Unboxable c, u32 unboxed_mask) {
    auto& allocator = Allocator::instance();
    Tuple3* tuple = static_cast<Tuple3*>(allocator.allocate(sizeof(Tuple3), Tag_Tuple3));
    tuple->header.size = 0;
    tuple->header.unboxed = unboxed_mask & 0x7;  // Only 3 bits used for Tuple3
    tuple->a = a;
    tuple->b = b;
    tuple->c = c;
    return allocator.wrap(tuple);
}

// ============================================================================
// Custom Type Allocation
// ============================================================================

/**
 * Allocates a Custom type value (algebraic data type).
 *
 * @param ctor         Constructor index.
 * @param values       Vector of field values.
 * @param unboxed_mask Bitmap indicating which fields are unboxed.
 * @return HPointer to the allocated Custom value.
 */
inline HPointer custom(u16 ctor, const std::vector<Unboxable>& values, u64 unboxed_mask) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(Custom) + values.size() * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    Custom* obj = static_cast<Custom*>(allocator.allocate(total_size, Tag_Custom));
    obj->header.size = static_cast<u32>(values.size());
    obj->ctor = ctor;
    obj->unboxed = unboxed_mask;
    for (size_t i = 0; i < values.size(); ++i) {
        obj->values[i] = values[i];
    }
    return allocator.wrap(obj);
}

/**
 * Allocates a Just value (Maybe with a value).
 *
 * @param value The wrapped value.
 * @param is_boxed True if value is a heap pointer.
 * @return HPointer to the Just value.
 */
inline HPointer just(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(0, vals, mask);  // Just is ctor 0 for Maybe
}

/**
 * Allocates an Ok value (Result.Ok).
 *
 * @param value The success value.
 * @param is_boxed True if value is a heap pointer.
 * @return HPointer to the Ok value.
 */
inline HPointer ok(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(0, vals, mask);  // Ok is ctor 0
}

/**
 * Allocates an Err value (Result.Err).
 *
 * @param value The error value.
 * @param is_boxed True if value is a heap pointer.
 * @return HPointer to the Err value.
 */
inline HPointer err(Unboxable value, bool is_boxed) {
    std::vector<Unboxable> vals = {value};
    u64 mask = is_boxed ? 0 : 1;
    return custom(1, vals, mask);  // Err is ctor 1
}

// ============================================================================
// Record Allocation
// ============================================================================

/**
 * Allocates a fixed-layout Record.
 *
 * @param values       Vector of field values (in canonical field order).
 * @param unboxed_mask Bitmap indicating which fields are unboxed.
 * @return HPointer to the allocated Record.
 */
inline HPointer record(const std::vector<Unboxable>& values, u64 unboxed_mask) {
    if (values.empty()) {
        return emptyRecord();
    }

    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(Record) + values.size() * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    Record* obj = static_cast<Record*>(allocator.allocate(total_size, Tag_Record));
    obj->header.size = static_cast<u32>(values.size());
    obj->unboxed = unboxed_mask;
    for (size_t i = 0; i < values.size(); ++i) {
        obj->values[i] = values[i];
    }
    return allocator.wrap(obj);
}

// ============================================================================
// ByteBuffer Allocation
// ============================================================================

/**
 * Allocates an immutable ByteBuffer.
 *
 * @param data   Pointer to byte data.
 * @param length Number of bytes.
 * @return HPointer to the allocated ByteBuffer.
 */
inline HPointer allocByteBuffer(const u8* data, size_t length) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(ByteBuffer) + length;
    total_size = (total_size + 7) & ~7;

    ByteBuffer* buf = static_cast<ByteBuffer*>(allocator.allocate(total_size, Tag_ByteBuffer));
    buf->header.size = static_cast<u32>(length);
    if (data && length > 0) {
        std::memcpy(buf->bytes, data, length);
    }
    return allocator.wrap(buf);
}

/**
 * Allocates a zero-initialized ByteBuffer.
 *
 * @param length Number of bytes.
 * @return HPointer to the allocated ByteBuffer.
 */
inline HPointer allocByteBufferZero(size_t length) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(ByteBuffer) + length;
    total_size = (total_size + 7) & ~7;

    ByteBuffer* buf = static_cast<ByteBuffer*>(allocator.allocate(total_size, Tag_ByteBuffer));
    buf->header.size = static_cast<u32>(length);
    if (length > 0) {
        std::memset(buf->bytes, 0, length);
    }
    return allocator.wrap(buf);
}

/**
 * Returns the length of a ByteBuffer.
 */
inline size_t byteBufferLength(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    return b->header.size;
}

/**
 * Returns a pointer to the byte data of a ByteBuffer.
 */
inline const u8* byteBufferData(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    return b->bytes;
}

// ============================================================================
// Array Allocation
// ============================================================================

/**
 * Allocates a mutable Array with specified capacity.
 *
 * @param capacity  Maximum number of elements.
 * @return HPointer to the allocated Array (length starts at 0).
 */
inline HPointer allocArray(size_t capacity) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    ElmArray* arr = static_cast<ElmArray*>(allocator.allocate(total_size, Tag_Array));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = 0;
    arr->padding = 0;
    arr->header.unboxed = 0;
    return allocator.wrap(arr);
}

/**
 * Allocates an Array and initializes it with boxed pointers.
 *
 * @param elements Vector of HPointers.
 * @return HPointer to the allocated Array.
 */
inline HPointer arrayFromPointers(const std::vector<HPointer>& elements) {
    auto& allocator = Allocator::instance();
    size_t capacity = elements.size();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    ElmArray* arr = static_cast<ElmArray*>(allocator.allocate(total_size, Tag_Array));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = static_cast<u32>(elements.size());
    arr->padding = 0;
    arr->header.unboxed = 0;  // All elements are boxed pointers

    for (size_t i = 0; i < elements.size(); ++i) {
        arr->elements[i].p = elements[i];
    }
    return allocator.wrap(arr);
}

/**
 * Allocates an Array and initializes it with unboxed integers.
 *
 * @param elements Vector of i64 values.
 * @return HPointer to the allocated Array.
 */
inline HPointer arrayFromInts(const std::vector<i64>& elements) {
    auto& allocator = Allocator::instance();
    size_t capacity = elements.size();
    size_t total_size = sizeof(ElmArray) + capacity * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    ElmArray* arr = static_cast<ElmArray*>(allocator.allocate(total_size, Tag_Array));
    arr->header.size = static_cast<u32>(capacity);
    arr->length = static_cast<u32>(elements.size());
    arr->header.unboxed = 1;  // All elements are unboxed
    arr->padding = 0;

    for (size_t i = 0; i < elements.size(); ++i) {
        arr->elements[i].i = elements[i];
    }
    return allocator.wrap(arr);
}

/**
 * Returns the length of an Array.
 */
inline size_t arrayLength(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->length;
}

/**
 * Returns the capacity of an Array.
 */
inline size_t arrayCapacity(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->header.size;
}

/**
 * Pushes a value onto an Array (must have capacity).
 *
 * Arrays are uniform: all elements must be either boxed or unboxed.
 * The first push sets the unboxed flag; subsequent pushes must be consistent.
 *
 * @param arr      Pointer to the Array.
 * @param value    Value to push.
 * @param is_boxed True if value is a heap pointer.
 * @return True if successful, false if at capacity.
 */
inline bool arrayPush(void* arr, Unboxable value, bool is_boxed) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    if (a->length >= a->header.size) {
        return false;  // At capacity
    }

    size_t idx = a->length;
    a->elements[idx] = value;

    // Set unboxed flag on first push; arrays are uniform
    if (idx == 0) {
        a->header.unboxed = is_boxed ? 0 : 1;
    }
    // Note: subsequent pushes must be consistent (not enforced here)

    a->length++;
    return true;
}

/**
 * Gets an element from an Array.
 *
 * @param arr   Pointer to the Array.
 * @param index Index of element to get.
 * @return The element value (undefined if index >= length).
 */
inline Unboxable arrayGet(void* arr, size_t index) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->elements[index];
}

/**
 * Checks if an array's elements are unboxed.
 *
 * Arrays are uniform: either ALL elements are unboxed or ALL are boxed.
 *
 * @param arr   Pointer to the Array.
 * @return True if all elements are unboxed primitives, false if all are boxed pointers.
 */
inline bool arrayIsUnboxed(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return a->header.unboxed != 0;
}

// ============================================================================
// Closure Allocation
// ============================================================================

/**
 * Allocates a Closure (function value).
 *
 * @param evaluator   Function pointer to the evaluator.
 * @param max_values  Maximum number of captured values.
 * @return HPointer to the allocated Closure.
 */
inline HPointer allocClosure(EvalFunction evaluator, u32 max_values) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(Closure) + max_values * sizeof(Unboxable);
    total_size = (total_size + 7) & ~7;

    Closure* cl = static_cast<Closure*>(allocator.allocate(total_size, Tag_Closure));
    cl->header.size = 0;
    cl->n_values = 0;
    cl->max_values = max_values;
    cl->unboxed = 0;
    cl->evaluator = evaluator;
    return allocator.wrap(cl);
}

/**
 * Appends a captured value to a Closure.
 *
 * @param closure   Pointer to the Closure.
 * @param value     Value to capture.
 * @param is_boxed  True if value is a heap pointer.
 * @return True if successful, false if at capacity.
 */
inline bool closureCapture(void* closure, Unboxable value, bool is_boxed) {
    Closure* cl = static_cast<Closure*>(closure);
    if (cl->n_values >= cl->max_values) {
        return false;
    }

    size_t idx = cl->n_values;
    cl->values[idx] = value;

    // Update unboxed bitmap
    if (!is_boxed && idx < 52) {
        cl->unboxed |= (1ULL << idx);
    }

    cl->n_values++;
    return true;
}

// ============================================================================
// Task / Process / StackFrame Allocation
// ============================================================================

enum TaskCtor : u16 {
    Task_Succeed  = 0,
    Task_Fail     = 1,
    Task_Binding  = 2,
    Task_AndThen  = 3,
    Task_OnError  = 4,
    Task_Receive  = 5,
};

static constexpr u16 CTOR_StackFrame = 0xFFFE;
static constexpr u16 CTOR_Router     = 0xFFFD;

enum FxBagTag : u16 {
    Fx_Leaf = 0,
    Fx_Node = 1,
    Fx_Map  = 2,
};

inline HPointer allocTask(u16 ctor, HPointer value, HPointer callback,
                          HPointer kill, HPointer innerTask) {
    auto& allocator = Allocator::instance();
    size_t total_size = (sizeof(Task) + 7) & ~7;
    Task* t = static_cast<Task*>(allocator.allocate(total_size, Tag_Task));
    t->ctor = ctor;
    t->id = 0;
    t->padding = 0;
    t->value = value;
    t->callback = callback;
    t->kill = kill;
    t->task = innerTask;
    return allocator.wrap(t);
}

inline HPointer allocProcess(u16 id, HPointer root, HPointer stack, HPointer mailbox) {
    auto& allocator = Allocator::instance();
    size_t total_size = (sizeof(Process) + 7) & ~7;
    Process* p = static_cast<Process*>(allocator.allocate(total_size, Tag_Process));
    p->id = id;
    p->padding = 0;
    p->root = root;
    p->stack = stack;
    p->mailbox = mailbox;
    return allocator.wrap(p);
}

inline HPointer stackFrame(u64 expectedTag, HPointer callback, HPointer rest) {
    std::vector<Unboxable> fields(3);
    fields[0].i = static_cast<i64>(expectedTag);
    fields[1].p = callback;
    fields[2].p = rest;
    return custom(CTOR_StackFrame, fields, 0x1);  // bit 0 = field 0 is unboxed
}

// ============================================================================
// Type Checking Helpers
// ============================================================================

/**
 * Returns the tag of a heap object.
 */
inline Tag getTag(void* obj) {
    Header* hdr = static_cast<Header*>(obj);
    return static_cast<Tag>(hdr->tag);
}

/**
 * Returns true if the object is a Cons cell.
 */
inline bool isCons(void* obj) {
    return getTag(obj) == Tag_Cons;
}

/**
 * Returns true if the object is an ElmString.
 */
inline bool isString(void* obj) {
    return getTag(obj) == Tag_String;
}

/**
 * Returns true if the object is a ByteBuffer.
 */
inline bool isByteBuffer(void* obj) {
    return getTag(obj) == Tag_ByteBuffer;
}

/**
 * Returns true if the object is an ElmArray.
 */
inline bool isArray(void* obj) {
    return getTag(obj) == Tag_Array;
}

} // namespace alloc
} // namespace Elm

#endif // ECO_HEAP_HELPERS_H
