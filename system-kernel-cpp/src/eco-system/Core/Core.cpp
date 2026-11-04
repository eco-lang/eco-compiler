//===- Core.cpp - Shared helpers for eco/system kernels -------------------===//
//
// The builders here root each fresh HPointer local before the next allocation, and keep no raw heap pointer
// across one, because any allocation may move objects. `alloc::tuple2` and `alloc::tuple3` root their own
// boxed fields across their allocation, so a value passed straight to them needs no root of its own.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"

#include <cerrno>
#include <cstring>

namespace Eco::System {

namespace {

// Returns a new Elm Bytes value holding the bytes of `b`, or the empty-Bytes constant when `b` is empty
// (HEAP_071: no zero-length buffer is allocated).
HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());
    return bb.hp;
}

} // namespace

// ---------------------------------------------------------------------------
// Copy-out
// ---------------------------------------------------------------------------

std::string toStdString(HPointer s) {
    return ::Eco::Kernel::toString(enc(s));
}

std::string toStdBytes(HPointer b) {
    std::string copy;
    void* p = alloc::resolveBytesOrNull(b);   // nullptr for emptyBytes()
    if (p) {
        auto v = alloc::byteBufferView(p);
        copy.assign(reinterpret_cast<const char*>(v.data), v.length);
    }
    return copy;
}

// ---------------------------------------------------------------------------
// Success
// ---------------------------------------------------------------------------

HPointer succeed(HPointer v) {
    return Scheduler::instance().taskSucceed(v);   // allocTask roots `v`
}

HPointer succeedUnit() {
    return Scheduler::instance().taskSucceed(alloc::unit());
}

HPointer succeedInt(int64_t n) {
    return Scheduler::instance().taskSucceedKind(alloc::unboxedInt(n), /*kind=*/1);
}

HPointer succeedString(const std::string& s) {
    return succeed(alloc::allocStringFromUTF8(s));
}

HPointer succeedBytes(const std::string& b) {
    return succeed(makeBytes(b));
}

// ---------------------------------------------------------------------------
// Failure
// ---------------------------------------------------------------------------

HPointer failFErr(const std::string& code, const std::string& msg) {
    HPointer codeHP = alloc::allocStringFromUTF8(code);
    HPointer msgHP = alloc::listNil();
    Elm::StackRootGuard g(&codeHP, &msgHP);
    msgHP = alloc::allocStringFromUTF8(msg);
    HPointer tup = alloc::tuple2(alloc::boxed(codeHP), alloc::boxed(msgHP), 0);
    return Scheduler::instance().taskFail(tup);    // allocTask roots `tup`
}

HPointer failErrno(int err) {
    const char* m = std::strerror(err);            // not synchronised; eco thread only
    return failFErr(errnoName(err), m ? m : "");
}

HPointer failSErr(int kind, const std::string& reason) {
    HPointer reasonHP = alloc::allocStringFromUTF8(reason);
    HPointer tup = alloc::tuple2(alloc::unboxedInt(kind), alloc::boxed(reasonHP), 0x1);
    return Scheduler::instance().taskFail(tup);
}

HPointer failRun(int kind, const std::string& code, int exitCode,
                 const std::string& out, const std::string& err) {
    // ( Int kind, String code, ( Int exitCode, Bytes stdout, Bytes stderr ) )
    HPointer outHP = makeBytes(out);
    HPointer errHP = alloc::listNil();
    HPointer inner = alloc::listNil();
    HPointer codeHP = alloc::listNil();
    Elm::StackRootGuard g(&outHP, &errHP, &inner, &codeHP);
    errHP = makeBytes(err);
    inner = alloc::tuple3(alloc::unboxedInt(exitCode), alloc::boxed(outHP),
                          alloc::boxed(errHP), 0x1);
    codeHP = alloc::allocStringFromUTF8(code);
    HPointer outer = alloc::tuple3(alloc::unboxedInt(kind), alloc::boxed(codeHP),
                                   alloc::boxed(inner), 0x1);
    return Scheduler::instance().taskFail(outer);
}

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

namespace detail {

HPointer failureFor(ErrShape shape, const char* what) {
    std::string w = what ? what : "(null)";
    switch (shape) {
        case ErrShape::FErr:   return failFErr("EIO", w);
        case ErrShape::SErr:   return failSErr(1, w);
        case ErrShape::RunErr: return failRun(0, "EIO", -1, "", "");
        case ErrShape::Never:  break;
    }
    ::Eco::Kernel::reportFatal(w.c_str());
}

HPointer asyncFailure(ErrShape shape, HPointer& resume, uint64_t token,
                      bool counted, const char* what) {
    auto& s = Scheduler::instance();
    if (token != 0) {
        // A registration left behind would keep its closure alive for the rest of the run.
        (void)s.takePendingResume(token);
    }
    HPointer task = failureFor(shape, what);
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    // Released only after `resume` has run, so the hold covers the completion of the Task.
    if (token != 0 && counted) s.releaseHold(token);
    return alloc::unit();
}

} // namespace detail

// ---------------------------------------------------------------------------
// Stream failure reasons
// ---------------------------------------------------------------------------

std::string failureReason(const std::string& origin, const std::string& code,
                          const std::string& message) {
    std::string r;
    r.reserve(origin.size() + code.size() + message.size() + 3);
    r.push_back('\x01');
    r += origin;
    r.push_back('\x1f');
    r += code;
    r.push_back('\x1f');
    r += message;
    return r;
}

std::string errnoFailureReason(const std::string& origin, int err) {
    const char* m = std::strerror(err);   // not synchronised; eco thread only
    std::string code = errnoName(err);
    return failureReason(origin, code, code + ": " + (m ? m : ""));
}

bool isMarkedReason(const std::string& reason) {
    return !reason.empty() && (reason[0] == '\x01' || reason[0] == '\x02');
}

namespace {

// Returns whether `code` is one the TLS layer reports: an "ERR_SSL_", "ERR_TLS_" or "CERT_" prefix, "_CERT"
// anywhere, or "UNABLE_TO_VERIFY_LEAF_SIGNATURE".
bool isTlsCode(const std::string& code) {
    return code.rfind("ERR_SSL_", 0) == 0 || code.rfind("ERR_TLS_", 0) == 0 ||
           code.rfind("CERT_", 0) == 0 || code.find("_CERT") != std::string::npos ||
           code == "UNABLE_TO_VERIFY_LEAF_SIGNATURE";
}

} // namespace

std::string socketFailureReason(int err, const std::string& reason) {
    if (isMarkedReason(reason)) return reason;
    if (reason.empty()) return errnoFailureReason("socket", err != 0 ? err : EIO);
    if (reason == "socket closed") return failureReason("socket", "ECANCELED", reason);
    if (reason == "upgraded to WebSocket") return failureReason("socket", "ECO_TAKEN_OVER", reason);
    std::string code;
    if (reason.rfind("read ", 0) == 0) code = reason.substr(5);
    else if (reason.rfind("write ", 0) == 0) code = reason.substr(6);
    else code = err != 0 ? errnoName(err) : "";
    return failureReason(isTlsCode(code) ? "tls" : "socket", code, reason);
}

std::string websocketFailureReason(int err, const std::string& reason) {
    if (isMarkedReason(reason)) return reason;
    if (reason == "heartbeat ETIMEDOUT") return failureReason("websocket", "ECO_WS_HEARTBEAT", reason);
    if (reason.rfind("ERR_WS_", 0) == 0) {
        std::string code = reason.substr(0, reason.find(':'));
        return failureReason("websocket", code, reason);
    }
    return socketFailureReason(err, reason);
}

} // namespace Eco::System
