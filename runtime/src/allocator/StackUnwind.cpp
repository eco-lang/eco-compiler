#include "StackUnwind.hpp"

#define UNW_LOCAL_ONLY
#include <libunwind.h>

#include <cstdio>

namespace Elm {
namespace StackUnwind {

// On x86-64, DWARF register numbers 0..15 map directly to libunwind's
// UNW_X86_64_RAX..UNW_X86_64_R15. This function exists as an extension
// point for other architectures (e.g. ARM64) where the mapping may differ.
static int mapDwarfToUnwindReg(uint16_t dwarfRegNum) {
    // x86-64: identity mapping for GPRs 0..15
    return static_cast<int>(dwarfRegNum);
}

//===----------------------------------------------------------------------===//
// Context
//===----------------------------------------------------------------------===//

struct Context::Impl {
    unw_context_t uctx;
};

Context::Context() : impl_(std::make_unique<Impl>()) {
    unw_getcontext(&impl_->uctx);
}

Context::~Context() = default;

//===----------------------------------------------------------------------===//
// Cursor
//===----------------------------------------------------------------------===//

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

} // namespace StackUnwind
} // namespace Elm
