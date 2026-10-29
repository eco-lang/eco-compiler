#include "StackUnwind.hpp"

#include <cstdio>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#define UNW_LOCAL_ONLY
#include <libunwind.h>
#endif

namespace Elm {
namespace StackUnwind {

#if defined(_WIN32)

// Win64 implementation. A cursor holds its own copy of the `CONTEXT`, which `RtlVirtualUnwind` rewrites
// in place to the caller's registers at each step.

// Returns the field of `c` that holds the register with AMD64 DWARF number `r`, or null for a number
// outside 0..16. The pointer is into `c`.
static const DWORD64* dwarfRegInContext(const CONTEXT* c, uint16_t r) {
    switch (r) {
    case 0:  return &c->Rax;
    case 1:  return &c->Rdx;
    case 2:  return &c->Rcx;
    case 3:  return &c->Rbx;
    case 4:  return &c->Rsi;
    case 5:  return &c->Rdi;
    case 6:  return &c->Rbp;
    case 7:  return &c->Rsp;
    case 8:  return &c->R8;
    case 9:  return &c->R9;
    case 10: return &c->R10;
    case 11: return &c->R11;
    case 12: return &c->R12;
    case 13: return &c->R13;
    case 14: return &c->R14;
    case 15: return &c->R15;
    case 16: return &c->Rip;
    default: return nullptr;
    }
}

/**
 * The registers captured by `RtlCaptureContext`.
 */
struct Context::Impl { CONTEXT ctx; };

Context::Context() : impl_(std::make_unique<Impl>()) {
    RtlCaptureContext(&impl_->ctx);
}
Context::~Context() = default;

/**
 * The registers of the current frame, a copy taken from the `Context` and then unwound.
 */
struct Cursor::Impl { CONTEXT ctx; };

Cursor::Cursor(Context& ctx) : impl_(std::make_unique<Impl>()) {
    impl_->ctx = ctx.impl_->ctx;
}
Cursor::~Cursor() = default;

bool Cursor::step() {
    DWORD64 imageBase = 0;
    PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(impl_->ctx.Rip, &imageBase, nullptr);
    if (!rf) {
#if ECO_GC_DEBUG
        fprintf(stderr, "[ECO_GC_DEBUG] RtlLookupFunctionEntry NULL at Rip=0x%llx\n",
                (unsigned long long)impl_->ctx.Rip);
#endif
        return false;
    }
    PVOID handlerData = nullptr;
    DWORD64 estFrame = 0;
    RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, impl_->ctx.Rip, rf,
                     &impl_->ctx, &handlerData, &estFrame, nullptr);
    return impl_->ctx.Rip != 0;
}

uintptr_t Cursor::ip() const {
    return static_cast<uintptr_t>(impl_->ctx.Rip);
}

bool Cursor::getRegister(uint16_t dwarfRegNum, uintptr_t& outValue) const {
    const DWORD64* p = dwarfRegInContext(&impl_->ctx, dwarfRegNum);
    if (!p) {
#if ECO_GC_DEBUG
        fprintf(stderr, "[ECO_GC_DEBUG] unknown DWARF reg %u\n", dwarfRegNum);
#endif
        return false;
    }
    outValue = static_cast<uintptr_t>(*p);
    return true;
}

#else  // POSIX libunwind backend

// Returns the libunwind register number for DWARF register `dwarfRegNum`. The mapping is the identity
// on every architecture. On x86-64, DWARF 0..15 coincide with `UNW_X86_64_RAX`..`UNW_X86_64_R15`.
static int mapDwarfToUnwindReg(uint16_t dwarfRegNum) {
    return static_cast<int>(dwarfRegNum);
}

/**
 * The registers captured by `unw_getcontext`.
 */
struct Context::Impl {
    unw_context_t uctx;
};

Context::Context() : impl_(std::make_unique<Impl>()) {
    unw_getcontext(&impl_->uctx);
}

Context::~Context() = default;

/**
 * The libunwind cursor, initialised from the `Context`'s `unw_context_t`.
 */
struct Cursor::Impl {
    unw_cursor_t cursor;
};

Cursor::Cursor(Context& ctx) : impl_(std::make_unique<Impl>()) {
    unw_init_local(&impl_->cursor, &ctx.impl_->uctx);
}

Cursor::~Cursor() = default;

bool Cursor::step() {
    int rc = unw_step(&impl_->cursor);
    if (rc < 0) {
#if ECO_GC_DEBUG
        fprintf(stderr, "[ECO_GC_DEBUG] unw_step failed: %d\n", rc);
#endif
        return false;
    }
    return rc > 0;
}

uintptr_t Cursor::ip() const {
    unw_word_t val;
    int rc = unw_get_reg(&impl_->cursor, UNW_REG_IP, &val);
    if (rc != 0) {
#if ECO_GC_DEBUG
        fprintf(stderr, "[ECO_GC_DEBUG] unw_get_reg(IP) failed: %d\n", rc);
#endif
        return 0;
    }
    return static_cast<uintptr_t>(val);
}

bool Cursor::getRegister(uint16_t dwarfRegNum, uintptr_t& outValue) const {
    int unwReg = mapDwarfToUnwindReg(dwarfRegNum);
    unw_word_t val;
    int rc = unw_get_reg(&impl_->cursor, unwReg, &val);
    if (rc != 0) {
#if ECO_GC_DEBUG
        fprintf(stderr, "[ECO_GC_DEBUG] unw_get_reg(dwarf=%u, unw=%d) failed: %d\n",
                dwarfRegNum, unwReg, rc);
#endif
        return false;
    }
    outValue = static_cast<uintptr_t>(val);
    return true;
}

#endif  // _WIN32 vs POSIX

} // namespace StackUnwind
} // namespace Elm
