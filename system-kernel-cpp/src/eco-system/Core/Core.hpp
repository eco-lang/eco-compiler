//===- Core.hpp - Shared helpers for eco/system kernels -------------------===//
//
// The one header every C++ file in system-kernel-cpp/src/eco-system/ starts
// with (plans/eco-system-library.md §3.3.2). It declares the helper list of
// §3.3.2 (namespace aliases, enc/dec, tuple access, copy-out helpers, the
// Task builders for the four error shapes of B2, makeKillHandle) and the
// two body guards ECO_SYSTEM_BODY_GUARD / ECO_SYSTEM_ASYNC_GUARD (G2).
//
// Everything is built on the eco-kernel helper headers (KernelHelpers.hpp,
// ExportHelpers.hpp, KernelExports.h for ECO_KERNEL_GUARD/reportFatal). They
// are header-only here: eco/system never links EcoKernel_* (D1).
//
// Templates used: T1, T2, T4, T7 (helpers only).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_HPP
#define ECO_SYSTEM_CORE_HPP

#include "eco-kernel/ExportHelpers.hpp"
#include "eco-kernel/KernelExports.h"
#include "eco-kernel/KernelHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "platform/PlatformRuntime.hpp"
#include "platform/Scheduler.hpp"
#include "platform/TaskBinding.hpp"

#include <cstdint>
#include <exception>
#include <new>
#include <string>

namespace Eco::System {

using namespace ::Elm;                                   // HPointer, Unboxable, Tuple2, Custom, PK_*
namespace alloc  = ::Elm::alloc;                         // HeapHelpers.hpp
namespace Export = ::Eco::Kernel::Export;                // eco-kernel ExportHelpers.hpp
using ::Elm::Platform::Scheduler;
using ::Elm::Platform::PlatformRuntime;
using ::Elm::Platform::makeBinding;
using ::Elm::Platform::makeAsyncBinding;

// T7: `cancel(token)` returns true only if it removed a job that had not yet
// produced a result (the kill handle then decrements pendingAsync).
using CancelFn = bool (*)(uint64_t token);

// ---------------------------------------------------------------------------
// Encoding and raw access (no allocation)
// ---------------------------------------------------------------------------

inline uint64_t enc(HPointer h) { return Export::encode(h); }
inline HPointer dec(uint64_t w) { return Export::decode(w); }
inline HPointer dec(void* w) { return Export::decode(reinterpret_cast<uint64_t>(w)); }

// Resolve a Tuple2/Tuple3. No allocation; the pointer dies at the next
// allocation or Elm call (G5).
inline Tuple2* asTuple2(HPointer h) {
    return static_cast<Tuple2*>(Allocator::instance().resolve(h));
}
inline Tuple3* asTuple3(HPointer h) {
    return static_cast<Tuple3*>(Allocator::instance().resolve(h));
}

// ---------------------------------------------------------------------------
// Copy-out (G3): heap → std::string. No allocation.
// ---------------------------------------------------------------------------

std::string toStdString(HPointer s);   // empty-string safe
std::string toStdBytes(HPointer b);    // T4 copy-out; empty-Bytes safe

// errno → "ENOENT" etc. ("UNKNOWN" when unknown). ErrnoNames.cpp, §3.8.
const char* errnoName(int err);

// ---------------------------------------------------------------------------
// Task builders (main thread; they allocate and root their own temporaries)
// ---------------------------------------------------------------------------

HPointer succeed(HPointer v);
HPointer succeedUnit();
HPointer succeedInt(int64_t n);
HPointer succeedString(const std::string& s);
HPointer succeedBytes(const std::string& b);

HPointer failFErr(const std::string& code, const std::string& msg);   // ( String, String )
HPointer failErrno(int err);                                          // failFErr(errnoName(err), strerror(err))
HPointer failSErr(int kind, const std::string& reason);               // ( Int, String ) mask 0x1
HPointer failRun(int kind, const std::string& code, int exitCode,
                 const std::string& out, const std::string& err);     // B.4 triple

// T7 (KillHandle.cpp).
HPointer makeKillHandle(uint64_t token, CancelFn cancel);

// ---------------------------------------------------------------------------
// Body guards (G2, §3.3.2). Implementation details; use the macros.
// ---------------------------------------------------------------------------

// The kernel's error shape (B2). Named so the guard macros can take the bare
// shape token: ECO_SYSTEM_BODY_GUARD(FErr, ...).
enum class ErrShape { FErr, SErr, RunErr, Never };

namespace detail {

// The failure Task for `shape` on an unexpected exception:
//   FErr → failFErr("EIO", what), SErr → failSErr(1, what),
//   RunErr → failRun(0, "EIO", -1, "", ""), Never → reportFatal(what).
HPointer failureFor(ErrShape shape, const char* what);

// The async-guard exception path: (1) take the token's resume and
// decrement if counted; (2) resume with failureFor(shape, what); (3) return
// unit() as the kill handle. `resume` must be rooted by the caller (the
// macro roots the body's parameter).
HPointer asyncFailure(ErrShape shape, HPointer& resume, uint64_t token,
                      bool counted, const char* what);

} // namespace detail

} // namespace Eco::System

// ECO_SYSTEM_BODY_GUARD(Shape, ...) wraps a makeBinding body. BODY must
// return on every path; on an exception it returns the failure Task of the
// kernel's error shape instead (B2), so no exception escapes stepProcess
// (F21).
#define ECO_SYSTEM_BODY_GUARD(Shape, ...)                                       \
    try {                                                                      \
        __VA_ARGS__                                                            \
    } catch (const std::bad_alloc&) {                                          \
        return ::Eco::System::detail::failureFor(                              \
            ::Eco::System::ErrShape::Shape, "out of memory in kernel");        \
    } catch (const std::exception& ecoSysGuardEx) {                            \
        return ::Eco::System::detail::failureFor(                              \
            ::Eco::System::ErrShape::Shape, ecoSysGuardEx.what());             \
    } catch (...) {                                                            \
        return ::Eco::System::detail::failureFor(                              \
            ::Eco::System::ErrShape::Shape,                                    \
            "unknown native exception in kernel");                             \
    }

// ECO_SYSTEM_ASYNC_GUARD(Shape, resume, token, counted, ...) wraps a
// makeAsyncBinding body. `token` (uint64_t, initialised to 0) is set by the
// body when it registers; `counted` (bool) when it calls
// incrementPendingAsync(). It roots the body's `resume` parameter for the
// whole body (the trampoline only roots its own copy). On an exception the
// task is always completed with the shape's failure (G10).
#define ECO_SYSTEM_ASYNC_GUARD(Shape, resume, token, counted, ...)              \
    ::Elm::StackRootGuard ecoSysResumeRoot(&(resume));                         \
    try {                                                                      \
        __VA_ARGS__                                                            \
    } catch (const std::bad_alloc&) {                                          \
        return ::Eco::System::detail::asyncFailure(                            \
            ::Eco::System::ErrShape::Shape, (resume), (token), (counted),      \
            "out of memory in kernel");                                        \
    } catch (const std::exception& ecoSysGuardEx) {                            \
        return ::Eco::System::detail::asyncFailure(                            \
            ::Eco::System::ErrShape::Shape, (resume), (token), (counted),      \
            ecoSysGuardEx.what());                                             \
    } catch (...) {                                                            \
        return ::Eco::System::detail::asyncFailure(                            \
            ::Eco::System::ErrShape::Shape, (resume), (token), (counted),      \
            "unknown native exception in kernel");                             \
    }

#endif // ECO_SYSTEM_CORE_HPP
