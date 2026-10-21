//===- Core.cpp - Shared helpers for eco/system kernels -------------------===//
//
// Implements the helper list of Core.hpp (plans/eco-system-library.md
// §3.3.2). Every builder here runs on the main thread (G1), copies nothing
// raw across an allocation (G5) and roots each fresh HPointer local before
// the next allocation (G4).
//
// Templates used: T4 (Bytes in/out), B2 error tuples.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"

#include <cerrno>
#include <cstring>

namespace Eco::System {

namespace {

// A Bytes value holding `b` (T4). Empty → the embedded empty-Bytes constant
// (HEAP_071). The buffer is filled immediately after allocation (G8).
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
// Failure (B2)
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
    const char* m = std::strerror(err);            // main thread only (G1)
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
        // Remove the registration (a stale entry would keep the closure alive
        // forever). `resume` is the body's own rooted copy.
        (void)s.takePendingResume(token);
    }
    HPointer task = failureFor(shape, what);   // `resume` rooted by the macro
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    // Release after the failure is published (plans/program-liveness-rule.md
    // §6.2, L6).
    if (token != 0 && counted) s.releaseHold(token);
    return alloc::unit();
}

} // namespace detail

// --- Stream failure reasons -------------------------------------------------

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
    const char* m = std::strerror(err);   // main thread only (G1)
    std::string code = errnoName(err);
    return failureReason(origin, code, code + ": " + (m ? m : ""));
}

bool isMarkedReason(const std::string& reason) {
    return !reason.empty() && (reason[0] == '\x01' || reason[0] == '\x02');
}

namespace {

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
