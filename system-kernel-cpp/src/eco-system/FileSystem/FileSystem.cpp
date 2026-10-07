//===- FileSystem.cpp - eco/system kernel module FileSystem (bodies) ------===//
//
// plans/eco-system-library.md Appendix B.3 / E.3. See FileSystem.hpp for the
// module layout and the payload shape.
//
//   * fsPoolSubmit — the one P-mode body (T2): copies the payload out (G3),
//     checks FileHandle fds against the open-handle table, registers the
//     resume, counts pendingAsync, submits the worker operation. The pool
//     drain (Core) takes the resume, calls the completion, resumes and
//     decrements exactly once (G10).
//   * fsComplete / fsCompleteOpen — main thread: build the result (T3 for
//     lists, T4 for Bytes) or the FErr tuple; file streams are handed to the
//     stream table as ChannelSource / ChannelSink over an FdChannel.
//   * The four directory getters (S mode, T1).
//
// The open-handle table (main thread only, no heap words) holds the fds that
// FileHandle.open returned and close has not yet released, so an operation
// on a closed handle fails with EBADF instead of reaching a reused fd number.
//
// Templates used: T1, T2, T3, T4.
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

// fds returned by FileHandle.open and not yet closed (main thread only).
std::unordered_set<int64_t>& openHandles() {
    static auto* s = new std::unordered_set<int64_t>();   // leaky (§3.4)
    return *s;
}

// G3: copy the payload out of the heap. No allocation in this scope.
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

// node's message shape: "ENOENT: no such file or directory, open '/x'".
std::string nodeMessage(const char* code, int err, const char* syscall, const std::string& path) {
    const char* m = std::strerror(err);   // main thread only (G1)
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

HPointer failRes(const FsRes& r) {
    if (!r.code.empty()) return failFErr(r.code, r.message);
    const char* code = errnoName(r.err);
    return failFErr(code, nodeMessage(code, r.err, r.syscall, r.path));
}

// T3: List ( String, Int ), one root range for the whole list (G6).
HPointer dirList(const std::vector<std::pair<std::string, int64_t>>& entries) {
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

// Main thread (pool drain): the Task for a finished operation.
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
        return succeed(alloc::listFromInts(std::vector<i64>(r.ints.begin(), r.ints.end())));   // fresh → allocTask roots it
    case FsRes::Kind::Dir:
        return succeed(dirList(r.entries));
    case FsRes::Kind::ReadStream: {
        FdChannelOptions o;
        o.readLimit = r.readLimit;
        int64_t id = createChannelSource(new FdChannel(static_cast<int>(r.n), o));   // owns the fd
        return succeedInt(id);
    }
    case FsRes::Kind::WriteStream: {
        FdChannelOptions o;
        o.truncateOnClose = r.truncateOnClose;
        int64_t id = createChannelSink(new FdChannel(static_cast<int>(r.n), o));
        return succeedInt(id);
    }
    }
    return succeedUnit();
}

// FileHandle.open: the new fd enters the open-handle table.
HPointer fsCompleteOpen(PoolResult& pr) {
    FsRes& r = pr.as<FsRes>();
    if (r.err == 0 && r.code.empty()) openHandles().insert(r.n);
    return fsComplete(pr);
}

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
    return alloc::tuple2(alloc::boxed(strs), alloc::boxed(ints), 0);   // `ints` fresh: helper roots it
}

// ---------------------------------------------------------------------------
// T2: the pool body
// ---------------------------------------------------------------------------

HPointer fsPoolSubmit(FsOp op, FsKind kind, HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        bool bytes = kind == FsKind::PathBytes || kind == FsKind::HandleBytes;
        FsArgs args = unpack(captured, bytes);   // G3: read first
        bool handle = kind == FsKind::Handle || kind == FsKind::HandleBytes || kind == FsKind::Close;
        if (handle) {
            auto& open = openHandles();
            if (open.find(args.i0) == open.end()) {   // closed or never opened
                HPointer task = failFErr("EBADF", "EBADF: bad file descriptor");
                Elm::StackRootGuard g(&task);
                Scheduler::callClosure1(resume, task);
                return alloc::unit();
            }
            if (kind == FsKind::Close) open.erase(args.i0);   // no later op reaches the fd
        }
        if (kind == FsKind::TempDir) args.s1 = joinTmp(tmpDirectoryString(), args.s1);

        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);   // G10
        s.incrementPendingAsync();
        counted = true;
        CompleteFn complete = kind == FsKind::Open ? &fsCompleteOpen : &fsComplete;
        SysWorkPool::instance().submit(
            token,
            [op, a = std::move(args)]() -> PoolResult { return PoolResult::of(op(a)); },   // worker: POD only
            complete, ErrShape::FErr);
        return alloc::unit();   // kill handle: unit (pool jobs are short)
    )
}

// ---------------------------------------------------------------------------
// Directory getters (S mode, E.3)
// ---------------------------------------------------------------------------

std::string homeDirectoryString() {
    const char* h = std::getenv("HOME");
    if (h && *h) return h;
#if defined(_WIN32)
    const char* up = std::getenv("USERPROFILE");
    if (up && *up) return up;
    return "";
#else
    struct passwd* pw = ::getpwuid(::getuid());   // main thread only
    if (pw && pw->pw_dir) return pw->pw_dir;
    return "";
#endif
}

std::string currentWorkingDirectoryString() {
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
