//===- KernelExports.h - C-linkage exports of the Eco kernel functions ----===//
//
// Declarations of the eco kernel exports: the C-linkage functions through which compiled Elm code reaches the
// native implementations of the `Eco.*` modules (MVar, Crash, GC, Hash and NativeDriver).
//
// Each export is named `Eco_Kernel_<Module>_<function>`, after the kernel function `Eco.Kernel.<Module>.<function>`
// that Elm code calls, and is declared `extern "C"` so that the name is not mangled and generated code can be
// linked against it by that name.
//
// Every argument and result is one 64-bit word. An Int travels as an `int64_t` and a Float as a `double`; every
// other value is an `HPtr`, the encoded `HPointer` of a heap value or of an embedded constant. A Bool is one of the
// True and False constants, never a C `bool`. One departure from the declared C types recurs: an MVar id arrives
// as a `uint64_t` holding the Int.
//
// Most exports return a Task, and calling one does none of its work. It captures its arguments and returns a Task
// whose work is done each time the scheduler runs it, as `Elm::Platform::makeBinding` describes. The comment on
// each export says what that Task succeeds with and how it fails. An IO failure is the IO error tuple
// `(tag, path, message)`: an Int classifying the error (derived from `errno` where there is one), the path concerned
// or an empty string, and a message. A few Tasks fail with a plain String instead, and each such comment says so.
// The exports that act when called, and return no Task, are `Crash.crash`, the two
// Hash functions and the GC root hooks.
//
// This header also provides `ECO_KERNEL_GUARD`, which every export's definition wraps around its body so that a C++
// exception becomes a fatal abort instead of unwinding out of a C-linkage function
// (test/scripts/check-eco-kernel-guard.sh checks this). For a Task-returning export the guard covers only building the
// Task; an exception from the Task's body, when it runs, is caught by the binding trampoline (TaskBinding.hpp).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_KERNEL_EXPORTS_H
#define ECO_KERNEL_EXPORTS_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <new>
#include "../../../runtime/src/allocator/Heap.hpp"
#include "../../../runtime/src/platform/Fatal.hpp"
using Elm::HPtr;

namespace Eco {
namespace Kernel {

/// Reports an unrecoverable native fault and aborts the process, through the runtime's one fatal path,
/// `Elm::Platform::reportFatal` (platform/Fatal.hpp).
///
/// It flushes stdout, runs the runtime's pre-fatal hooks (the terminal-mode restore among them), writes
/// `[eco-runtime] FATAL: ` followed by `what` (or `(null)` when `what` is null) to stderr, and calls `std::abort`. It
/// is for faults that cannot be delivered as a Task failure, such as a C++ exception that has reached an export.
[[noreturn]] inline void reportFatal(const char* what) {
    ::Elm::Platform::reportFatal(what);
}

} // namespace Kernel
} // namespace Eco

/// Runs `BODY` and turns any C++ exception that escapes it into `Eco::Kernel::reportFatal`, so that no exception
/// unwinds out of an `extern "C"` function, which is undefined behaviour.
///
/// A `std::bad_alloc` is reported as running out of memory, any other `std::exception` by its `what()`, and anything
/// else as an unknown native exception. The macro expands to a `try` statement, so `BODY` must contain its own
/// `return`: control never leaves the statement normally. `BODY` is a single macro argument, so a comma in it that is
/// not inside parentheses splits it.
#define ECO_KERNEL_GUARD(BODY)                                                 \
    try {                                                                      \
        BODY                                                                   \
    } catch (const std::bad_alloc&) {                                          \
        ::Eco::Kernel::reportFatal("out of memory in kernel");                 \
    } catch (const std::exception& ecoGuardEx) {                               \
        ::Eco::Kernel::reportFatal(ecoGuardEx.what());                         \
    } catch (...) {                                                            \
        ::Eco::Kernel::reportFatal("unknown native exception in kernel");      \
    }

extern "C" {

//===----------------------------------------------------------------------===//
// Crash Module - unrecoverable errors
//===----------------------------------------------------------------------===//

/// Writes `Eco crash: ` and `message` to stderr, followed by a backtrace where the platform provides one, and exits
/// the process with status 1. It acts when called and does not return.
HPtr Eco_Kernel_Crash_crash(HPtr message);

//===----------------------------------------------------------------------===//
// MVar Module - concurrency primitives
//===----------------------------------------------------------------------===//

// An MVar is a slot that is either empty or holds one value. A Task that must wait for it to become full or empty
// parks: it is set aside, the scheduler goes on running other Tasks, and it resumes when another MVar Task changes
// the slot. The read, take and put functions return Tasks that fail with the IO error tuple, message
// `MVar not found: <id>`, when no MVar has that id when they are run.

/// Returns a Task that creates an empty MVar and succeeds with its id as an Int. Each run creates a new MVar.
HPtr Eco_Kernel_MVar_new();

/// Returns a Task that succeeds with the value held by MVar `id`, leaving it there, and parks while the MVar is
/// empty.
HPtr Eco_Kernel_MVar_read(uint64_t id);

/// Returns a Task that empties MVar `id` and succeeds with the value it held, and parks while the MVar is empty.
HPtr Eco_Kernel_MVar_take(uint64_t id);

/// Returns a Task that stores `value` in MVar `id` and succeeds with Unit, and parks while the MVar is full.
HPtr Eco_Kernel_MVar_put(uint64_t id, HPtr value);

// Each of these is `Eco_Kernel_MVar_put` for a value passed unboxed. It boxes the Int, Float or Char when called,
// because the MVar holds a heap value, and returns the Task `Eco_Kernel_MVar_put` returns for the box. `value_raw`
// holds a Char's code point in its low 32 bits; the upper bits are ignored.

/// Returns the Task of `Eco_Kernel_MVar_put` for the Int `value`, boxed.
HPtr Eco_Kernel_MVar_put_Int  (uint64_t id, int64_t  value);
/// Returns the Task of `Eco_Kernel_MVar_put` for the Float `value`, boxed.
HPtr Eco_Kernel_MVar_put_Float(uint64_t id, double   value);
/// Returns the Task of `Eco_Kernel_MVar_put` for the Char whose code point is the low 32 bits of `value_raw`, boxed.
HPtr Eco_Kernel_MVar_put_Char (uint64_t id, uint64_t value_raw);

/// Returns a Task that destroys MVar `id` and succeeds with Unit. Tasks parked on it are abandoned and never resume.
/// An id with no MVar is not an error.
HPtr Eco_Kernel_MVar_drop(uint64_t id);

//===----------------------------------------------------------------------===//
// Hash Module
//===----------------------------------------------------------------------===//

/// Returns the narrow hash of the String `str` from `seed`, computed when called and without allocating, as
/// `Eco::Kernel::Hash::stringWithSeed` describes. Note the argument order: `seed` comes first here and last there.
int64_t Eco_Kernel_Hash_stringWithSeed(int64_t seed, HPtr str);

/// Returns the full 64-bit hash of the String `str` from `seed`, computed when called and without allocating, as
/// `Eco::Kernel::Hash::string64` describes. `seed` comes first here and last there.
int64_t Eco_Kernel_Hash_string64(int64_t seed, HPtr str);

//===----------------------------------------------------------------------===//
// GC Module - explicit collections
//===----------------------------------------------------------------------===//

// The two Tasks collect when they are run, never when these functions are called, and allocate their result only
// after the collection. The String each succeeds with is a JSON object reporting the collection: its kind
// (`"minor"` or `"major"`), timings in nanoseconds, memory sizes in bytes before and after, the old generation's
// high-water mark, collection counters and the result of the trim, or `{"kind":"error"}` if the report could not be
// formatted.

/// Returns a Task that runs a minor collection and succeeds with its report.
HPtr Eco_Kernel_GC_minorGC();

/// Returns a Task that runs a major collection that also returns freed memory to the operating system
/// (`Elm::Allocator::collectMajorAndRelease`), and succeeds with its report.
HPtr Eco_Kernel_GC_majorGC();

//===----------------------------------------------------------------------===//
// GC root registration hooks. Call each hook, or
// Eco_Kernel_register_all_gc_roots instead of them, once, after the allocator
// is initialised.
//===----------------------------------------------------------------------===//

// Each hook adds a root scanner to the allocator's root set, so that the values a module keeps outside the heap's
// reach survive collections. A hook called twice adds its scanner twice.

/// Registers the scanner for the values held in MVars and carried by Tasks parked to put one.
void Eco_Kernel_MVar_register_gc_roots();
/// Calls the MVar hook, and also elm-kernel-cpp's hook for the Order values when that is linked in.
void Eco_Kernel_register_all_gc_roots();

//===----------------------------------------------------------------------===//
// NativeDriver Module - in-process MLIR lowering + native linking
//===----------------------------------------------------------------------===//

// Lowering and linking are done by `eco_native_lower_and_link` and `eco_native_lower_and_link_bytes`, which are
// linked into the program from outside this package. A program that does not link the real ones gets stand-ins that
// return -1, so the Tasks below fail with the message for code -1 instead of doing any work. The work runs on the
// thread running the Task, and blocks it until the driver returns.

/// Returns a Task that lowers the MLIR file at `mlirPath` to a native executable at `outputPath` and succeeds with
/// Unit. `rootModule` is the name of the program's root module, passed to the driver. It fails with a plain String,
/// `lowering/linking failed (rc=<code>)` after a prefix naming the function, when the driver returns non-zero.
HPtr Eco_Kernel_NativeDriver_lowerAndLink(HPtr mlirPath, HPtr outputPath,
                                          HPtr rootModule);

/// Returns a Task like `Eco_Kernel_NativeDriver_lowerAndLink`, except that the MLIR is the contents of the Bytes
/// value `bytes` instead of a file, and no root module name is passed.
HPtr Eco_Kernel_NativeDriver_lowerAndLinkBytes(HPtr bytes, HPtr outputPath);

} // extern "C"

#endif // ECO_KERNEL_EXPORTS_H
