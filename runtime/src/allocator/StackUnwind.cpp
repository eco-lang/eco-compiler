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

// Win64 backend: GC stack walking via RtlCaptureContext + RtlLookupFunctionEntry
// + RtlVirtualUnwind. Verified end-to-end by E-W1 / E-W2
// (experiments/win-statepoint-smoke + experiments/win-jit-smoke) — those
// experiments exercised exactly this pipeline on JITed and AOT code.
//
// The DWARF→CONTEXT register map is the AMD64 numbering:
//   0=rax 1=rdx 2=rcx 3=rbx 4=rsi 5=rdi 6=rbp 7=rsp 8..15=r8..r15 16=rip.

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

struct Context::Impl { CONTEXT ctx; };

Context::Context() : impl_(std::make_unique<Impl>()) {
    RtlCaptureContext(&impl_->ctx);
}
Context::~Context() = default;

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

// On x86-64, DWARF register numbers 0..15 map directly to libunwind's
// UNW_X86_64_RAX..UNW_X86_64_R15. This function exists as an extension
// point for other architectures (e.g. ARM64) where the mapping may differ.
static int mapDwarfToUnwindReg(uint16_t dwarfRegNum) {
    // x86-64: identity mapping for GPRs 0..15
    return static_cast<int>(dwarfRegNum);
}

struct Context::Impl {
    unw_context_t uctx;
};

Context::Context() : impl_(std::make_unique<Impl>()) {
    unw_getcontext(&impl_->uctx);
}

Context::~Context() = default;

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
