//===- KernelHelpers.hpp - Shared helpers for Eco kernel C++ functions -----===//
//
// String conversion, task wrapping, and Elm list traversal utilities used by
// all Eco kernel module implementations.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_HELPERS_H
#define ECO_KERNEL_HELPERS_H

#include "ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "platform/Scheduler.hpp"
#include <string>
#include <vector>

namespace Eco::Kernel {

using namespace Elm;
using namespace Elm::alloc;

// Extract UTF-8 std::string from a uint64_t-encoded ElmString.
inline std::string toString(uint64_t val) {
    HPointer h = Export::decode(val);
    if (h.constant == Const_EmptyString + 1) {
        return "";
    }
    void* ptr = Allocator::instance().resolve(h);
    return StringOps::toStdString(ptr);
}

// Allocate an ElmString from UTF-8 and return as encoded uint64_t.
inline uint64_t fromString(const std::string& s) {
    HPointer h = allocStringFromUTF8(s);
    return Export::encode(h);
}

// Wrap result HPointer in Task.succeed and return as uint64_t.
inline uint64_t taskSucceed(HPointer value) {
    HPointer task = Elm::Platform::Scheduler::instance().taskSucceed(value);
    return Export::encode(task);
}

// Wrap a uint64_t-encoded value in Task.succeed.
inline uint64_t taskSucceedEncoded(uint64_t encodedValue) {
    return taskSucceed(Export::decode(encodedValue));
}

// Wrap result in Task.succeed(Unit).
inline uint64_t taskSucceedUnit() {
    return taskSucceed(unit());
}

// Wrap error HPointer in Task.fail and return as uint64_t.
inline uint64_t taskFail(HPointer error) {
    HPointer task = Elm::Platform::Scheduler::instance().taskFail(error);
    return Export::encode(task);
}

// Wrap a string error message in Task.fail.
inline uint64_t taskFailString(const std::string& msg) {
    return taskFail(allocStringFromUTF8(msg));
}

// Wrap a boxed Bool in Task.succeed.
inline uint64_t taskSucceedBool(bool b) {
    return taskSucceed(b ? elmTrue() : elmFalse());
}

// Wrap an unboxed Int in Task.succeed (boxes it first).
inline uint64_t taskSucceedInt(int64_t value) {
    return taskSucceed(allocInt(value));
}

// Wrap an unboxed Float in Task.succeed (boxes it first).
inline uint64_t taskSucceedFloat(double value) {
    return taskSucceed(allocFloat(value));
}

// Wrap an ElmString (as uint64_t) in Task.succeed.
inline uint64_t taskSucceedString(const std::string& s) {
    return taskSucceed(allocStringFromUTF8(s));
}

// Wrap a Maybe String in Task.succeed.
inline uint64_t taskSucceedMaybeString(const char* value) {
    if (value) {
        HPointer str = allocStringFromUTF8(std::string(value));
        return taskSucceed(just(boxed(str), true));
    } else {
        return taskSucceed(nothing());
    }
}

// Wrap a List String in Task.succeed.
inline uint64_t taskSucceedStringList(const std::vector<std::string>& items) {
    std::vector<HPointer> ptrs;
    ptrs.reserve(items.size());
    for (const auto& s : items) {
        ptrs.push_back(allocStringFromUTF8(s));
    }
    return taskSucceed(listFromPointers(ptrs));
}

// Iterate over an Elm List (Cons chain) calling a visitor function on each element.
// The visitor receives the head Unboxable and whether it's boxed.
template<typename F>
inline void forEachListElement(uint64_t encodedList, F&& visitor) {
    HPointer current = Export::decode(encodedList);
    auto& allocator = Allocator::instance();
    while (!isConstant(current) || current.constant != Const_Nil + 1) {
        Cons* cell = static_cast<Cons*>(allocator.resolve(current));
        bool head_is_boxed = (cell->header.unboxed == 0);
        visitor(cell->head, head_is_boxed);
        current = cell->tail;
    }
}

// Convert an Elm List String to a std::vector<std::string>.
inline std::vector<std::string> listToStringVector(uint64_t encodedList) {
    std::vector<std::string> result;
    forEachListElement(encodedList, [&](Unboxable head, bool /*is_boxed*/) {
        void* ptr = Allocator::instance().resolve(head.p);
        result.push_back(StringOps::toStdString(ptr));
    });
    return result;
}

} // namespace Eco::Kernel

#endif // ECO_KERNEL_HELPERS_H
