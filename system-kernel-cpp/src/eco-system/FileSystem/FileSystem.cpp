//===- FileSystem.cpp - eco/system kernel module FileSystem (bodies) ------===//
//
// The bodies behind FileSystem.hpp. Everything here runs on the eco thread except the lambda that
// `fsPoolSubmit` hands to the pool, which runs the worker operation on a worker thread and captures only the
// operation and a copy of its `FsArgs`.
//
//===----------------------------------------------------------------------===//

#include "eco-system/FileSystem/FileSystem.hpp"

#include "eco-system/Core/FdChannel.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Stream/Stream.hpp"

#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <unordered_set>
#include <vector>

#if defined(_WIN32)
#include <direct.h>
#else
#include <pwd.h>
#include <unistd.h>
#endif

namespace Eco::System::Fs {

namespace {

/// Returns the open-handle table: the fds that a successful `open` returned and that no `close` has removed
/// since. Eco thread only; nothing guards it. It is never destroyed once created.
std::unordered_set<int64_t>& openHandles() {
    static auto* s = new std::unordered_set<int64_t>();   // leaky
    return *s;
}

/// Returns a copy of the payload `captured`, built by `packFsArgs`, with `s2` copied as Bytes when `s2Bytes`
/// and as a String otherwise. Does not allocate on the Elm heap, so the raw tuple pointers it reads stay valid.
FsArgs unpack(HPointer captured, bool s2Bytes) {
    FsArgs a;
    Tuple2* outer = asTuple2(captured);
    HPointer strs = outer->a.p;
    HPointer ints = outer->b.p;
    Tuple2* st = asTuple2(strs);
    a.s1 = toStdString(st->a.p);
    a.s2 = s2Bytes ? toStdBytes(st->b.p) : toStdString(st->b.p);
    Tuple3* it = asTuple3(ints);
    a.i0 = it->a.i;
    a.i1 = it->b.i;
    a.i2 = it->c.i;
    return a;
}

/// Returns a message in node's style for errno `err` named `code`: `code`, ": ", and `strerror(err)` with its
/// first letter lower-cased, followed by ", " and `syscall` when that is not empty, and then, only in that case,
/// by the quoted `path` when that is not empty, as in "ENOENT: no such file or directory, open '/x'". `syscall` may be
/// null. Eco thread only, since `strerror` is not synchronised.
std::string nodeMessage(const char* code, int err, const char* syscall, const std::string& path) {
    const char* m = std::strerror(err);
    std::string desc = m ? m : "unknown error";
    if (!desc.empty()) desc[0] = static_cast<char>(std::tolower(static_cast<unsigned char>(desc[0])));
    std::string out = std::string(code) + ": " + desc;
    if (syscall && *syscall) {
        out += ", ";
        out += syscall;
        if (!path.empty()) out += " '" + path + "'";
    }
    return out;
}

/// Returns the Task that fails with the FErr for the failed result `r`: its own `code` and `message` when it
/// has a code, otherwise the errno's name and `nodeMessage` for it.
HPointer failRes(const FsRes& r) {
    if (!r.code.empty()) return failFErr(r.code, r.message);
    const char* code = errnoName(r.err);
    return failFErr(code, nodeMessage(code, r.err, r.syscall, r.path));
}

/// Returns a new Elm `List ( String, Int )` holding `entries` in order.
HPointer dirList(const std::vector<std::pair<std::string, int64_t>>& entries) {
    // The tuples built so far are rooted as one range while the rest are allocated; `ptrs` is never resized,
    // so the range stays valid.
    std::vector<HPointer> ptrs(entries.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
    for (size_t i = 0; i < entries.size(); ++i) {
        HPointer name = alloc::allocStringFromUTF8(entries[i].first);
        ptrs[i] = alloc::tuple2(alloc::boxed(name), alloc::unboxedInt(entries[i].second), 0x4);
    }
    HPointer list = alloc::listFromPointers(ptrs);
    rs.restoreStackRangePoint(saved);
    return list;
}

/// Returns the Task for the finished operation in `pr`, which must hold an `FsRes`: the FErr failure when it
/// failed, and otherwise a Task that succeeds with the value its `kind` names. For a stream kind, the fd is
/// handed to a new `FdChannel` with the options in the result, the channel to a new stream pair, and the
/// Task succeeds with the pair's id. It is the completion for every kind but `Open`.
HPointer fsComplete(PoolResult& pr) {
    FsRes& r = pr.as<FsRes>();
    if (r.err != 0 || !r.code.empty()) return failRes(r);
    switch (r.kind) {
    case FsRes::Kind::Unit:
        return succeedUnit();
    case FsRes::Kind::Int:
        return succeedInt(r.n);
    case FsRes::Kind::Str:
        return succeedString(r.data);
    case FsRes::Kind::Bytes:
        return succeedBytes(r.data);
    case FsRes::Kind::Ints:
        return succeed(alloc::listFromInts(std::vector<i64>(r.ints.begin(), r.ints.end())));
    case FsRes::Kind::Dir:
        return succeed(dirList(r.entries));
    case FsRes::Kind::ReadStream: {
        FdChannelOptions o;
        o.readLimit = r.readLimit;
        int64_t id = createChannelSource(new FdChannel(static_cast<int>(r.n), o));
        return succeedInt(id);
    }
    case FsRes::Kind::WriteStream: {
        FdChannelOptions o;
        o.truncateOnClose = r.truncateOnClose;
        o.syncOnClose = r.syncOnClose;
        int64_t id = createChannelSink(new FdChannel(static_cast<int>(r.n), o));
        return succeedInt(id);
    }
    }
    return succeedUnit();
}

/// Returns the Task for a finished `open`, as `fsComplete` does, first adding the new fd to the open-handle
/// table when the open succeeded.
HPointer fsCompleteOpen(PoolResult& pr) {
    FsRes& r = pr.as<FsRes>();
    if (r.err == 0 && r.code.empty()) openHandles().insert(r.n);
    return fsComplete(pr);
}

/// Returns `prefix` placed in directory `tmp`, joined with a '/' unless `tmp` already ends in one.
std::string joinTmp(const std::string& tmp, const std::string& prefix) {
    if (!tmp.empty() && tmp.back() == '/') return tmp + prefix;
    return tmp + "/" + prefix;
}

} // namespace

// ---------------------------------------------------------------------------
// Export side
// ---------------------------------------------------------------------------

HPointer packFsArgs(uint64_t s1, uint64_t s2, int64_t i0, int64_t i1, int64_t i2) {
    HPointer a = s1 ? dec(s1) : alloc::emptyString();
    HPointer b = s2 ? dec(s2) : alloc::emptyString();
    HPointer strs = alloc::listNil();
    Elm::StackRootGuard g(&a, &b, &strs);
    strs = alloc::tuple2(alloc::boxed(a), alloc::boxed(b), 0);
    HPointer ints = alloc::tuple3(alloc::unboxedInt(i0), alloc::unboxedInt(i1),
                                  alloc::unboxedInt(i2), 0x15);
    // `ints` needs no guard: `tuple2` roots its boxed arguments across its own allocation.
    return alloc::tuple2(alloc::boxed(strs), alloc::boxed(ints), 0);
}

// ---------------------------------------------------------------------------
// The pool body
// ---------------------------------------------------------------------------

HPointer fsPoolSubmit(FsOp op, FsKind kind, HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        bool bytes = kind == FsKind::PathBytes || kind == FsKind::HandleBytes;
        FsArgs args = unpack(captured, bytes);   // before anything that allocates
        bool handle = kind == FsKind::Handle || kind == FsKind::HandleBytes || kind == FsKind::Close;
        if (handle) {
            auto& open = openHandles();
            if (open.find(args.i0) == open.end()) {
                HPointer task = failFErr("EBADF", "EBADF: bad file descriptor");
                Elm::StackRootGuard g(&task);
                Scheduler::callClosure1(resume, task);
                return alloc::unit();
            }
            if (kind == FsKind::Close) open.erase(args.i0);
        }
        if (kind == FsKind::TempDir) args.s1 = joinTmp(tmpDirectoryString(), args.s1);

        auto& s = Scheduler::instance();
        token = s.parkResume(resume, HoldKind::Task, "FileSystem.op");
        counted = true;
        CompleteFn complete = kind == FsKind::Open ? &fsCompleteOpen : &fsComplete;
        SysWorkPool::instance().submit(
            token,
            [op, a = std::move(args)]() -> PoolResult { return PoolResult::of(op(a)); },
            complete, ErrShape::FErr);
        return alloc::unit();
    )
}

// ---------------------------------------------------------------------------
// Directory getters
// ---------------------------------------------------------------------------

std::string homeDirectoryString() {
    const char* h = std::getenv("HOME");
    if (h && *h) return h;
#if defined(_WIN32)
    const char* up = std::getenv("USERPROFILE");
    if (up && *up) return up;
    return "";
#else
    struct passwd* pw = ::getpwuid(::getuid());
    if (pw && pw->pw_dir) return pw->pw_dir;
    return "";
#endif
}

std::string currentWorkingDirectoryString() {
    // The buffer doubles from 4096 bytes while the path does not fit, at most eight tries.
    std::vector<char> buf(4096);
    for (int i = 0; i < 8; ++i) {
#if defined(_WIN32)
        if (::_getcwd(buf.data(), static_cast<int>(buf.size()))) return buf.data();
#else
        if (::getcwd(buf.data(), buf.size())) return buf.data();
#endif
        if (errno != ERANGE) break;
        buf.resize(buf.size() * 2);
    }
    return ".";
}

std::string tmpDirectoryString() {
    for (const char* var : {"TMPDIR", "TMP", "TEMP"}) {
        const char* v = std::getenv(var);
        if (v && *v) {
            std::string s = v;
            while (s.size() > 1 && s.back() == '/') s.pop_back();
            return s;
        }
    }
#if defined(_WIN32)
    return "C:/Windows/Temp";
#else
    return "/tmp";
#endif
}

std::string devNullString() {
#if defined(_WIN32)
    return "//./nul";
#else
    return "/dev/null";
#endif
}

HPointer fsHomeDirectoryBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never, return succeedString(homeDirectoryString());)
}

HPointer fsCurrentWorkingDirectoryBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never, return succeedString(currentWorkingDirectoryString());)
}

HPointer fsTmpDirectoryBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never, return succeedString(tmpDirectoryString());)
}

HPointer fsDevNullBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never, return succeedString(devNullString());)
}

} // namespace Eco::System::Fs
