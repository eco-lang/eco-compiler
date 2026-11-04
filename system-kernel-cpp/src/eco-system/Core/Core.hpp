//===- Core.hpp - Shared helpers for eco/system kernels -------------------===//
//
// eco/system kernels turn C++ results into Elm values and Tasks, and turn C++ failures into the Elm
// error values their APIs promise, so this header gathers the few helpers they share.
//
// It provides namespace aliases into the runtime and eco-kernel; `enc` and `dec`, which convert between an
// `HPointer` and the 64-bit word kernel exports pass; copy-out helpers that read an Elm String or Bytes into a
// `std::string`; the stream failure-reason format; Task builders; `makeKillHandle`; and two body guards.
//
// An eco/system failure has one of three error shapes, which are the Elm error values a kernel's Tasks fail
// with:
// - FErr, `( String code, String message )`, built by `failFErr` and `failErrno`;
// - SErr, `( Int kind, String reason )`, built by `failSErr`;
// - RunErr, `( Int kind, String code, ( Int exitCode, Bytes stdout, Bytes stderr ) )`, built by `failRun`.
// A kernel whose Task cannot fail has the shape `Never`. The body guards wrap a kernel body so that a C++
// exception escaping it becomes a failure of the kernel's shape instead of propagating out into the
// scheduler, or, for `Never`, a fatal error.
//
// The builders allocate on the Elm heap and root their own temporaries. Like all Elm heap access they must
// run on the eco thread, the thread that runs the Elm scheduler (`Elm::Platform::Scheduler`), which is not
// necessarily the process's `main` thread. The eco-kernel headers are used for their inline helpers only;
// nothing here needs an `EcoKernel_*` library linked.
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
#include "platform/TestHooks.hpp"

#include <cstdint>
#include <exception>
#include <new>
#include <string>

namespace Eco::System {

using namespace ::Elm;                                   // HPointer, Unboxable, Tuple2, Custom, PK_*
namespace alloc  = ::Elm::alloc;                         // HeapHelpers.hpp
namespace Export = ::Eco::Kernel::Export;                // eco-kernel ExportHelpers.hpp
using ::Elm::Platform::Scheduler;
// The liveness hold API, as runtime/src/platform/Liveness.hpp defines it.
using ::Elm::Platform::HoldKind;
using ::Elm::Platform::HoldToken;
using ::Elm::Platform::kNoHold;
using ::Elm::Platform::HoldRelease;
using ::Elm::Platform::LivenessHold;
using ::Elm::Platform::PlatformRuntime;
using ::Elm::Platform::makeBinding;
using ::Elm::Platform::makeAsyncBinding;

/// A function that cancels the background job registered under `token`, given to `makeKillHandle`.
///
/// It must return true only if it removed a job that had not yet produced a result; the kill handle then
/// releases the token's hold, which nothing else will release. A null `CancelFn` is accepted by
/// `makeKillHandle` and cancels nothing.
using CancelFn = bool (*)(uint64_t token);

// ---------------------------------------------------------------------------
// Encoding and raw access (no allocation)
// ---------------------------------------------------------------------------

/// Returns the 64-bit word that stands for `h` across the kernel-export ABI, as `Export::encode` defines it.
inline uint64_t enc(HPointer h) { return Export::encode(h); }
/// Returns the `HPointer` that the kernel-export word `w` stands for; the inverse of `enc`.
inline HPointer dec(uint64_t w) { return Export::decode(w); }
/// Returns the `HPointer` for a kernel-export word passed as a `void*`, as `dec(uint64_t)` does.
inline HPointer dec(void* w) { return Export::decode(reinterpret_cast<uint64_t>(w)); }

/// Returns the heap object of the Elm 2-tuple `h`.
///
/// `h` must be a 2-tuple. Does not allocate. The pointer is valid only until the next allocation on the Elm
/// heap or call into Elm, either of which may move the object.
inline Tuple2* asTuple2(HPointer h) {
    return static_cast<Tuple2*>(Allocator::instance().resolve(h));
}
/// Returns the heap object of the Elm 3-tuple `h`, with the same requirement and lifetime as `asTuple2`.
inline Tuple3* asTuple3(HPointer h) {
    return static_cast<Tuple3*>(Allocator::instance().resolve(h));
}

// ---------------------------------------------------------------------------
// Copy-out: Elm heap values to std::string, without allocating on the Elm heap
// ---------------------------------------------------------------------------

/// Returns the text of the Elm String `s` as UTF-8. `s` may be the empty-string constant.
std::string toStdString(HPointer s);
/// Returns a copy of the bytes of the Elm Bytes value `b`. `b` may be the empty-Bytes constant, which gives "".
std::string toStdBytes(HPointer b);

/// Returns the symbolic name of the errno value `err`, such as "ENOENT", or "UNKNOWN" for a value it does not
/// know. Defined in ErrnoNames.cpp.
const char* errnoName(int err);

// ---------------------------------------------------------------------------
// Stream failure reasons
// ---------------------------------------------------------------------------
// A stream's cancellation reason reaches Elm as the String of an SErr, where `Stream.Internal.decodeReason`
// reads it. A reason the kernel makes itself is marked by its first character, which a program's own reason
// does not normally start with:
//   "\x01" origin "\x1f" code "\x1f" message  the resource failed; origin names the kind of resource
//                                            (such as socket, tls, file, pipe, stdio, websocket, http,
//                                            codec) and code is a symbolic error code
//   "\x02" ...                               the stream had ended
// A reason starting with neither is read as a program's own reason.

/// Returns the marked failure reason with origin `origin`, code `code` and message `message`. Nothing is
/// escaped, so a `\x1f` inside `origin` or `code` would shift the fields.
std::string failureReason(const std::string& origin, const std::string& code,
                          const std::string& message);
/// Returns the marked failure reason for errno `err` from `origin`: its code is `errnoName(err)` and its
/// message is that code, ": ", and `strerror(err)`. Must be called on the eco thread, since `strerror` is not
/// synchronised.
std::string errnoFailureReason(const std::string& origin, int err);
/// Returns whether `reason` is a kernel-made reason: one starting with "\x01" (failed) or "\x02" (ended).
bool isMarkedReason(const std::string& reason);
/// The first character of a reason that says the stream had ended, as a string literal, so that a reason can be
/// spelled `ECO_SYSTEM_ENDED_MARKER "text"` (the escape is resolved before the literals are joined, so the text
/// cannot extend it).
#define ECO_SYSTEM_ENDED_MARKER "\x02"
/// The first character of a reason that says the stream had ended.
inline constexpr char kEndedMarker[] = ECO_SYSTEM_ENDED_MARKER;
/// The ended reason for writing to or closing a writable side that is closed, and the reason a pipe cancels its
/// source with when the destination was closed: `Stream.Closed` on the Elm side. Its text is parsed by
/// `Stream.Internal.decodeReason` and must stay byte-identical.
inline constexpr char kWritableClosed[] = ECO_SYSTEM_ENDED_MARKER "WritableStream is closed";
static_assert(kEndedMarker[0] == '\x02' && kEndedMarker[1] == '\0', "the ended marker is the single byte 0x02");
static_assert(kWritableClosed[0] == kEndedMarker[0] && kWritableClosed[1] == 'W',
              "kWritableClosed starts with the ended marker, then its text");

/// Returns the marked failure reason for a socket stream's plain reason `reason`, with `err` its errno or 0.
///
/// A marked `reason` is returned as it is. An empty one gives the reason for `err`, or for EIO when `err` is
/// 0. "socket closed" has code "ECANCELED" and "upgraded to WebSocket" code "ECO_TAKEN_OVER". For
/// "read <rest>" or "write <rest>" the code is `<rest>`, and otherwise it is `errnoName(err)`, or "" when
/// `err` is 0; the message is `reason`. The origin is "tls" when the code starts with "ERR_SSL_", "ERR_TLS_"
/// or "CERT_", contains "_CERT", or is "UNABLE_TO_VERIFY_LEAF_SIGNATURE", and "socket" otherwise.
std::string socketFailureReason(int err, const std::string& reason);
/// Returns the marked failure reason for a WebSocket stream's plain reason `reason`, with `err` its errno or 0.
///
/// A marked `reason` is returned as it is. "heartbeat ETIMEDOUT" has origin "websocket" and code
/// "ECO_WS_HEARTBEAT". A reason starting "ERR_WS_" has origin "websocket" and as its code the part before the
/// first ':', or all of it. Any other reason is treated as the connection's, by `socketFailureReason`.
std::string websocketFailureReason(int err, const std::string& reason);

// ---------------------------------------------------------------------------
// Task builders. Each allocates a new Task on the Elm heap, rooting its own temporaries, and must be called on
// the eco thread
// ---------------------------------------------------------------------------

/// Returns a Task that succeeds with the boxed value `v`.
HPointer succeed(HPointer v);
/// Returns a Task that succeeds with `()`.
HPointer succeedUnit();
/// Returns a Task that succeeds with the Int `n`, stored unboxed.
HPointer succeedInt(int64_t n);
/// Returns a Task that succeeds with a new Elm String holding the UTF-8 text `s`.
HPointer succeedString(const std::string& s);
/// Returns a Task that succeeds with an Elm Bytes value holding the bytes of `b`; the empty-Bytes constant
/// when `b` is empty.
HPointer succeedBytes(const std::string& b);

/// Returns a Task that fails with the FErr `( code, msg )`.
HPointer failFErr(const std::string& code, const std::string& msg);
/// Returns a Task that fails with the FErr `( errnoName(err), strerror(err) )`. This is not the error
/// `Eco::Kernel::failErrno` builds. Must be called on the eco thread, since `strerror` is not synchronised.
HPointer failErrno(int err);
/// Returns a Task that fails with the SErr `( kind, reason )`.
HPointer failSErr(int kind, const std::string& reason);
/// Returns a Task that fails with the RunErr `( kind, code, ( exitCode, out, err ) )`, where `out` and `err`
/// become Bytes values.
HPointer failRun(int kind, const std::string& code, int exitCode,
                 const std::string& out, const std::string& err);

/// Returns the kill handle for a job parked under `token`: a closure that, when the task is killed, drops the
/// task's parked resume and calls `cancel(token)`, releasing the token's hold if that returns true. Defined in
/// KillHandle.cpp.
HPointer makeKillHandle(uint64_t token, CancelFn cancel);

#if ECO_TEST_HOOKS
/// Test-only (SOCK-12): makes the next `makeKillHandle` throw `std::bad_alloc` before it allocates. The fault
/// fires once and then disarms itself. Defined in KillHandle.cpp.
void killHandleFailNextForTest();
#endif

// ---------------------------------------------------------------------------
// Body guards
// ---------------------------------------------------------------------------

/// The error shape of a kernel's Task, as the file comment defines them. The guard macros take an enumerator's
/// bare name, as in `ECO_SYSTEM_BODY_GUARD(FErr, ...)`.
enum class ErrShape { FErr, SErr, RunErr, Never };

/// Helpers that the guard macros expand to; not for direct use.
namespace detail {

/// Returns the failure Task of shape `shape` for an exception whose message is `what` ("(null)" when null):
/// for FErr `failFErr("EIO", what)`, for SErr `failSErr(1, what)`, and for RunErr
/// `failRun(0, "EIO", -1, "", what)`, which carries `what` as the stderr Bytes. For `Never` it does not return: it calls
/// `Eco::Kernel::reportFatal(what)`.
HPointer failureFor(ErrShape shape, const char* what);

/// Completes an async kernel's Task with `failureFor(shape, what)` and returns `()` as its kill handle.
///
/// When `token` is not 0, the closure parked under it is first removed and discarded. If none is parked under
/// it, the body has already completed the Task itself (taking the resume, and releasing the hold if `counted`)
/// before it threw, so nothing more is done: `resume` is not called and no hold is released. Otherwise the
/// failure Task is passed to `resume`, and afterwards, when `token` is not 0 and `counted`, the token's hold is
/// released, so the hold outlasts the call that completes the Task. `resume` must be rooted by the caller; when
/// `token` is 0 it is called without any check, and otherwise whether or not it is the closure parked under
/// `token`.
HPointer asyncFailure(ErrShape shape, HPointer& resume, uint64_t token,
                      bool counted, const char* what);

} // namespace detail

} // namespace Eco::System

/// Runs the statements `...` of a function that returns a Task, such as a `makeBinding` body, and returns the
/// failure Task of `Shape` (an `ErrShape` enumerator name) if they throw, as `detail::failureFor` builds it.
///
/// It expands to a `try` statement, so the statements must return on every path; nothing is returned after
/// it. The exception message is used where the shape keeps one: "out of memory in kernel" for
/// `std::bad_alloc`, `what()` for another `std::exception`, and "unknown native exception in kernel"
/// otherwise.
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

/// Runs the statements `...` of a `makeAsyncBinding` body and, if they throw, completes the Task through
/// `detail::asyncFailure` and returns its result.
///
/// `resume` is the body's resume-closure parameter, an `HPointer` lvalue, which the macro roots from its
/// expansion to the end of the enclosing scope. `token` is a `uint64_t` variable, initialised to 0, that the
/// statements set when they park `resume`, and `counted` a `bool` they set when that parking also acquired the
/// token's hold, as `Scheduler::parkResume` does. Both are read at the time of the exception. The macro
/// declares the local `ecoSysResumeRoot`, and, like `ECO_SYSTEM_BODY_GUARD`, it expands to statements that
/// must return on every path and chooses the exception message the same way. For `Never` an exception is
/// fatal.
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
