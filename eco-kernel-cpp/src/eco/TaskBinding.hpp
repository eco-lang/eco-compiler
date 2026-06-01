//===- TaskBinding.hpp - Eco-namespaced Task_Binding helpers --------------===//
//
// Thin Eco::Kernel namespace shim over runtime/src/platform/TaskBinding.hpp:
//
//   * exposes `makeBinding<Body>(captured)` under `Eco::Kernel::makeBinding`
//   * provides HPointer-returning `succeed*` / `fail*` wrappers around the
//     uint64_t-returning helpers in KernelHelpers.hpp so binding bodies can
//     `return succeedString(s)` without going through `Export::decode`.
//
// See plans/defer-eager-kernel-tasks-via-binding.md (Q1, Q2) and the
// KERNEL_TASK_IO_001/002 invariants for the design rationale.
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

// Re-export Elm::Platform::makeBinding into the Eco::Kernel namespace so
// callers in eco-kernel-cpp/src/eco/ don't have to qualify.
template <BindingBody Body>
inline HPointer makeBinding(HPointer captured) {
    return ::Elm::Platform::makeBinding<Body>(captured);
}

// ============================================================================
// HPointer-returning Task constructor wrappers
// ----------------------------------------------------------------------------
// The helpers in KernelHelpers.hpp return uint64_t-encoded HPointers (the
// JIT-facing kernel ABI shape). Binding bodies, however, work in HPointer
// space — having to write `Export::decode(taskSucceedString(s))` at every
// return site is noisy. These thin wrappers let bodies say `succeedString(s)`
// / `failErrno(...)` directly.
// ============================================================================

inline HPointer succeed(HPointer value) {
    return Export::decode(taskSucceed(value));
}

inline HPointer succeedUnit() {
    return Export::decode(taskSucceedUnit());
}

inline HPointer succeedString(const std::string& s) {
    return Export::decode(taskSucceedString(s));
}

inline HPointer succeedInt(int64_t value) {
    return Export::decode(taskSucceedInt(value));
}

inline HPointer succeedFloat(double value) {
    return Export::decode(taskSucceedFloat(value));
}

inline HPointer succeedBool(bool b) {
    return Export::decode(taskSucceedBool(b));
}

inline HPointer succeedMaybeString(const char* value) {
    return Export::decode(taskSucceedMaybeString(value));
}

inline HPointer succeedStringList(const std::vector<std::string>& items) {
    return Export::decode(taskSucceedStringList(items));
}

inline HPointer fail(HPointer error) {
    return Export::decode(taskFail(error));
}

inline HPointer failString(const std::string& msg) {
    return Export::decode(taskFailString(msg));
}

inline HPointer failIO(int tag, const std::string& path, const std::string& message) {
    return Export::decode(taskFailIO(tag, path, message));
}

inline HPointer failErrno(int err, const std::string& path, const std::string& message) {
    return Export::decode(taskFailErrno(err, path, message));
}

} // namespace Eco::Kernel

#endif // ECO_KERNEL_TASK_BINDING_HPP
