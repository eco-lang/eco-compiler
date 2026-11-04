//===- TaskBinding.hpp - Eco-namespaced Task_Binding helpers --------------===//
//
// A kernel function that returns a Task must do its IO when the Task is run, not when the function is called
// (invariant KERNEL_TASK_IO_001). It meets that rule by putting the IO in a binding body, a function the
// scheduler calls each time it steps the Task; `Elm::Platform::makeBinding` in the runtime's
// `platform/TaskBinding.hpp` owns that mechanism and its rooting rules. This header makes it convenient to
// write binding bodies inside `Eco::Kernel`.
//
// It has two parts. `makeBinding` forwards to the runtime's function, so callers in this namespace need not
// qualify it. The `succeed*` and `fail*` functions build the Task a body returns. They wrap the `taskSucceed*`
// and `taskFail*` builders of `KernelHelpers.hpp`, which return the `uint64_t` word of the Task (the kernel ABI
// shape), and decode that word back to an `HPointer`, the form a binding body returns. Each one allocates, so
// each is a GC point; what each Task holds is stated on its `KernelHelpers.hpp` builder.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_TASK_BINDING_HPP
#define ECO_KERNEL_TASK_BINDING_HPP

#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "platform/TaskBinding.hpp"

namespace Eco::Kernel {

using ::Elm::HPointer;
using ::Elm::Platform::BindingBody;

/// Returns a new Binding Task that calls `Body(captured)` each time the scheduler steps it. Making the
/// Task does no IO. A GC point.
///
/// The Task keeps `captured` reachable for as long as the Task is. `Body` receives an unrooted copy of it,
/// so a body that allocates must root it, or unpack it, before its first allocation.
template <BindingBody Body>
inline HPointer makeBinding(HPointer captured) {
    return ::Elm::Platform::makeBinding<Body>(captured);
}

/// Returns a new Task that succeeds with the boxed value `value`. A GC point.
///
/// `value` must be rooted by the caller if it is a heap object that the caller uses afterwards.
inline HPointer succeed(HPointer value) {
    return Export::decode(taskSucceed(value));
}

/// Returns a new Task that succeeds with Unit. A GC point.
inline HPointer succeedUnit() {
    return Export::decode(taskSucceedUnit());
}

/// Returns a new Task that succeeds with an Elm String holding the UTF-8 text `s`. A GC point.
inline HPointer succeedString(const std::string& s) {
    return Export::decode(taskSucceedString(s));
}

/// Returns a new Task that succeeds with the Int `value`. A GC point.
inline HPointer succeedInt(int64_t value) {
    return Export::decode(taskSucceedInt(value));
}

/// Returns a new Task that succeeds with the Float `value`. A GC point.
inline HPointer succeedFloat(double value) {
    return Export::decode(taskSucceedFloat(value));
}

/// Returns a new Task that succeeds with the Bool `b`. A GC point.
inline HPointer succeedBool(bool b) {
    return Export::decode(taskSucceedBool(b));
}

/// Returns a new Task that succeeds with `Just` an Elm String holding the UTF-8 text at `value`, or with
/// `Nothing` when `value` is null. A GC point.
///
/// A non-null `value` must point to a NUL-terminated string; it is not kept.
inline HPointer succeedMaybeString(const char* value) {
    return Export::decode(taskSucceedMaybeString(value));
}

/// Returns a new Task that succeeds with a List of Elm Strings holding the UTF-8 texts in `items`, in order.
/// A GC point.
inline HPointer succeedStringList(const std::vector<std::string>& items) {
    return Export::decode(taskSucceedStringList(items));
}

/// Returns a new Task that fails with the boxed value `error`. A GC point.
///
/// `error` must be rooted by the caller if it is a heap object that the caller uses afterwards.
inline HPointer fail(HPointer error) {
    return Export::decode(taskFail(error));
}

/// Returns a new Task that fails with an Elm String holding the UTF-8 text `msg`. A GC point.
inline HPointer failString(const std::string& msg) {
    return Export::decode(taskFailString(msg));
}

/// Returns a new Task that fails with the IO error tuple `( tag, path, message )`, as `taskFailIO` builds it.
/// A GC point.
inline HPointer failIO(int tag, const std::string& path, const std::string& message) {
    return Export::decode(taskFailIO(tag, path, message));
}

/// Returns a new Task that fails with the IO error tuple for the `errno` value `err`, as `taskFailErrno`
/// builds it. A GC point.
///
/// This is not the error `Eco::System::failErrno` builds, which has a different shape.
inline HPointer failErrno(int err, const std::string& path, const std::string& message) {
    return Export::decode(taskFailErrno(err, path, message));
}

} // namespace Eco::Kernel

#endif // ECO_KERNEL_TASK_BINDING_HPP
