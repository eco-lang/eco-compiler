//===- KernelHelpers.hpp - Shared helpers for Eco kernel C++ functions -----===//
//
// The eco kernel functions take and return Elm values as `uint64_t` words (see `ExportHelpers.hpp`), and most of
// them deal in Strings, Lists and Tasks. This header holds the conversions and Task builders they share.
//
// It has three parts. `toString`, `fromString` and `listToStringVector` convert between Elm Strings or Lists of
// Strings and `std::string`. The `taskSucceed*` and `taskFail*` functions allocate a Task that succeeds or fails
// with a given value and return its word. `ioErrorTagFromErrno`, `ioErrorTagFromErrorCode`, `taskFailIO`,
// `taskFailErrno` and `taskFailErrorCode` build the *IO error tuple*, the value an eco kernel IO operation fails
// with: `( tag, path, message )`, where `tag` is an Int classifying the error, `path` is the path the failing
// operation concerns, as the caller passes it, and `message` describes the failure.
//
// A Task built here is a finished value: building it performs no IO. An eco kernel function that returns a Task
// and performs IO is expected to defer the IO to a Task binding (`Eco::Kernel::makeBinding`, in
// `TaskBinding.hpp`), whose body runs each time the scheduler runs the Task and may use these builders to
// produce the Task it delivers. Nothing here checks how they are called.
//
// Every function that allocates is a GC point, and each roots the Strings it allocates before the next
// allocation. The Task builders use `Elm::Platform::Scheduler::instance()`, so they run on the eco thread, the
// thread that runs the Elm scheduler.
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
#include <cerrno>
#include <string>
#include <system_error>
#include <vector>

namespace Eco::Kernel {

using namespace Elm;
using namespace Elm::alloc;

/// Returns the text of the Elm String whose word is `val`, as UTF-8.
///
/// `val` must be a String or the empty-string constant. Does not allocate on the Elm heap.
inline std::string toString(uint64_t val) {
    HPointer h = Export::decode(val);
    if (Elm::alloc::isEmptyString(h)) {
        return "";
    }
    void* ptr = Allocator::instance().resolve(h);
    return StringOps::toStdString(ptr);
}

/// Allocates an Elm String holding the UTF-8 text `s` and returns its word. A GC point.
inline uint64_t fromString(const std::string& s) {
    HPointer h = allocStringFromUTF8(s);
    return Export::encode(h);
}

/// Returns the word of a new Task that succeeds with the boxed value `value`. A GC point.
///
/// `value` must be rooted by the caller if it is a heap object that the caller uses afterwards.
inline uint64_t taskSucceed(HPointer value) {
    HPointer task = Elm::Platform::Scheduler::instance().taskSucceed(value);
    return Export::encode(task);
}

/// Returns the word of a new Task that succeeds with the boxed value whose word is `encodedValue`, as
/// `taskSucceed` does.
inline uint64_t taskSucceedEncoded(uint64_t encodedValue) {
    return taskSucceed(Export::decode(encodedValue));
}

/// Returns the word of a new Task that succeeds with Unit. A GC point.
inline uint64_t taskSucceedUnit() {
    return taskSucceed(unit());
}

/// Returns the word of a new Task that fails with the boxed value `error`. A GC point.
inline uint64_t taskFail(HPointer error) {
    HPointer task = Elm::Platform::Scheduler::instance().taskFail(error);
    return Export::encode(task);
}

/// Returns the word of a new Task that fails with an Elm String holding the UTF-8 text `msg`. A GC point.
inline uint64_t taskFailString(const std::string& msg) {
    HPointer str = allocStringFromUTF8(msg);
    Elm::StackRootGuard guard(&str);
    return taskFail(str);
}

/// Returns the IO error tag that classifies the `errno` value `err`.
///
/// The tags are 1 FileNotFound (`ENOENT`), 2 PermissionDenied (`EACCES`, `EPERM`), 3 NotADirectory (`ENOTDIR`),
/// 4 IsADirectory (`EISDIR`), 5 AlreadyExists (`EEXIST`), 6 NoSpaceLeft (`ENOSPC`), 7 TooManyOpenFiles
/// (`EMFILE`, `ENFILE`), 8 BrokenPipe (`EPIPE`), 9 BadFileDescriptor (`EBADF`), and 0 OtherIOError for any other
/// value. The numbers are decoded on the Elm side by `Eco.IO.Error.decodeIOError` and `tagFromCode`, and by the
/// JS kernels, so a change here must be made there too; nothing checks that they agree.
inline int ioErrorTagFromErrno(int err) {
    switch (err) {
        case ENOENT: return 1;  // FileNotFound
        case EACCES:            // PermissionDenied
        case EPERM:  return 2;
        case ENOTDIR: return 3; // NotADirectory
        case EISDIR:  return 4; // IsADirectory
        case EEXIST:  return 5; // AlreadyExists
        case ENOSPC:  return 6; // NoSpaceLeft
        case EMFILE:            // TooManyOpenFiles
        case ENFILE: return 7;
        case EPIPE:  return 8;  // BrokenPipe
        case EBADF:  return 9;  // BadFileDescriptor
        default:     return 0;  // OtherIOError
    }
}

/// Returns the word of a new Task that fails with the IO error tuple `( tag, path, message )`. A GC point.
///
/// `tag` is stored as an unboxed Int and is not checked against the tags `ioErrorTagFromErrno` returns. `path`
/// and `message` become Elm Strings. The tuple is what `Eco.IO.Error.ofKernelTuple` reads on the Elm side.
inline uint64_t taskFailIO(int tag, const std::string& path, const std::string& message) {
    HPointer pathStr = allocStringFromUTF8(path);
    Elm::StackRootGuard g1(&pathStr);
    HPointer msgStr = allocStringFromUTF8(message);
    Elm::StackRootGuard g2(&msgStr);
    HPointer tup = tuple3(unboxedInt(tag), boxed(pathStr), boxed(msgStr), 0x1);
    Elm::StackRootGuard g3(&tup);
    return taskFail(tup);
}

/// Returns the word of a new Task that fails with the IO error tuple for the `errno` value `err`, as
/// `taskFailIO` does with the tag `ioErrorTagFromErrno` gives `err`.
inline uint64_t taskFailErrno(int err, const std::string& path, const std::string& message) {
    return taskFailIO(ioErrorTagFromErrno(err), path, message);
}

/// Returns the IO error tag that classifies the `std::error_code` `ec`, with the numbering of
/// `ioErrorTagFromErrno`.
///
/// `ec` is compared with `std::errc` conditions rather than read as an `errno` value, so a code in another
/// category maps by its meaning: on Windows, `std::filesystem` reports Win32 codes in the system category,
/// such as ERROR_PATH_NOT_FOUND (3) or ERROR_ALREADY_EXISTS (183), and those map to the same tags as their
/// POSIX counterparts. On POSIX the generic and system codes are `errno` values, and the result equals
/// `ioErrorTagFromErrno(ec.value())`.
inline int ioErrorTagFromErrorCode(const std::error_code& ec) {
    using std::errc;
    if (ec == errc::no_such_file_or_directory) return 1;  // FileNotFound
    if (ec == errc::permission_denied || ec == errc::operation_not_permitted) return 2;  // PermissionDenied
    if (ec == errc::not_a_directory) return 3;  // NotADirectory
    if (ec == errc::is_a_directory) return 4;   // IsADirectory
    if (ec == errc::file_exists) return 5;      // AlreadyExists
    if (ec == errc::no_space_on_device) return 6;  // NoSpaceLeft
    if (ec == errc::too_many_files_open || ec == errc::too_many_files_open_in_system) return 7;  // TooManyOpenFiles
    if (ec == errc::broken_pipe) return 8;          // BrokenPipe
    if (ec == errc::bad_file_descriptor) return 9;  // BadFileDescriptor
    return 0;                                       // OtherIOError
}

/// Returns the word of a new Task that fails with the IO error tuple for the `std::error_code` `ec`, as
/// `taskFailIO` does with the tag `ioErrorTagFromErrorCode` gives `ec`. The message is `message`, then ": ",
/// then `ec.message()`. A GC point.
///
/// Use this for failures a `std::filesystem` call reports, and `taskFailErrno` for those an `errno` reports.
inline uint64_t taskFailErrorCode(const std::error_code& ec, const std::string& path,
                                  const std::string& message) {
    return taskFailIO(ioErrorTagFromErrorCode(ec), path, message + ": " + ec.message());
}

/// Returns the word of a new Task that succeeds with the Bool `b`, a boxed constant word. A GC point.
inline uint64_t taskSucceedBool(bool b) {
    return taskSucceed(b ? elmTrue() : elmFalse());
}

/// Returns the word of a new Task that succeeds with the Int `value`. A GC point.
///
/// The Int is stored unboxed in the Task, so the Task is the only object allocated.
inline uint64_t taskSucceedInt(int64_t value) {
    HPointer task = Elm::Platform::Scheduler::instance().taskSucceedKind(
        Elm::alloc::unboxedInt(value), 1);
    return Export::encode(task);
}

/// Returns the word of a new Task that succeeds with the Float `value`, stored unboxed in the Task. A GC point.
inline uint64_t taskSucceedFloat(double value) {
    HPointer task = Elm::Platform::Scheduler::instance().taskSucceedKind(
        Elm::alloc::unboxedFloat(value), 2);
    return Export::encode(task);
}

/// Returns the word of a new Task that succeeds with an Elm String holding the UTF-8 text `s`. A GC point.
inline uint64_t taskSucceedString(const std::string& s) {
    HPointer str = allocStringFromUTF8(s);
    Elm::StackRootGuard guard(&str);
    return taskSucceed(str);
}

/// Returns the word of a new Task that succeeds with `Just` an Elm String holding the UTF-8 text at `value`,
/// or with `Nothing` when `value` is null. A GC point.
///
/// A non-null `value` must point to a NUL-terminated string; it is not kept.
inline uint64_t taskSucceedMaybeString(const char* value) {
    if (value) {
        HPointer str = allocStringFromUTF8(std::string(value));
        Elm::StackRootGuard guard(&str);
        HPointer wrapped = just(boxed(str), true);
        return taskSucceed(wrapped);
    } else {
        return taskSucceed(nothing());
    }
}

/// Returns the word of a new Task that succeeds with a List of Elm Strings holding the UTF-8 texts in `items`,
/// in order. A GC point.
inline uint64_t taskSucceedStringList(const std::vector<std::string>& items) {
    std::vector<HPointer> ptrs(items.size(), listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    // One all-boxed root range covers the whole buffer; the slots not yet filled hold the Nil constant, which
    // the GC skips.
    rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);

    for (size_t i = 0; i < items.size(); ++i) {
        ptrs[i] = allocStringFromUTF8(items[i]);
    }

    rs.restoreStackRangePoint(saved);
    return taskSucceed(listFromPointers(ptrs));
}

/// Calls `visitor` on each element of the Elm List whose word is `encodedList`, first to last.
///
/// `visitor` is called as `visitor(element, isBoxed)`, where `element` is the `Unboxable` slot value and
/// `isBoxed` is whether its slot kind is boxed. The walk is an `Elm::alloc::ListCursor`, which is stale after
/// any heap allocation, so `visitor` must not allocate on the Elm heap. Does not allocate itself.
template<typename F>
inline void forEachListElement(uint64_t encodedList, F&& visitor) {
    for (Elm::alloc::ListCursor c(Export::decode(encodedList)); !c.done();
         c.next()) {
        visitor(c.current(), c.currentKind() == 0);
    }
}

/// Returns the texts of the Elm Strings in the List whose word is `encodedList`, in order, as UTF-8.
///
/// Each element is read as `toString` reads it, so an element that is the empty-string constant gives `""`
/// and is never passed to `Allocator::resolve` (HEAP_014). Does not allocate on the Elm heap.
inline std::vector<std::string> listToStringVector(uint64_t encodedList) {
    std::vector<std::string> result;
    forEachListElement(encodedList, [&](Unboxable head, bool /*is_boxed*/) {
        result.push_back(toString(Export::encode(head.p)));
    });
    return result;
}

} // namespace Eco::Kernel

#endif // ECO_KERNEL_HELPERS_H
