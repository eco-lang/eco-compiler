// DirectCall: one closure, called many times by a kernel that calls it once per element.
//
// Kernels such as String.foldl, List.map and List.foldl call the same closure for every element.
// `eco_apply_closure_eval` works out on each call what `DirectCall` works out once: whether the
// arguments exactly fill the closure, the kind of every slot, the result kind, which slots hold
// pointers, and the root range for the argument array. Each call then calls the descriptor's
// `sat[]` entry with the arguments in registers when the compiler made one (the fast edge compiled
// code takes, closures-and-calls.md), and otherwise copies the captures and the arguments into the
// array and calls the evaluator's generic entry.
//
// It also tells the kernel the kind each argument slot wants, so a kernel can pass a value in the
// closure's own kind. A fold whose accumulator slot and result are both an unboxed Int, Float or
// Char can then carry its accumulator unboxed from one call to the next, where the general path
// boxes the accumulator after every call and unboxes it before the next.
//
// When the fast path does not apply (`ok()` is false) the kernel uses `eco_apply_closure_eval` as
// before. Validating builds always take that path, which checks each argument for staleness.

#ifndef ECO_DIRECT_CALL_HPP
#define ECO_DIRECT_CALL_HPP

#include "ExportHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RootSet.hpp"
#include "allocator/RuntimeExports.h"
#include <cstdint>
#include <cstring>

namespace Elm {

class DirectCall {
public:
    // The most slots (captures plus arguments) a closure may have for the fast path.
    static constexpr uint32_t kMaxSlots = 16;

    // Sets up calls of the closure `*closure` with `nargs` arguments. `closure` must point at a
    // rooted HPointer that stays rooted, and current, for the life of this object: each call reads
    // the captures through it, so a collection between calls is harmless. Pushes a root range for
    // the argument array, popped by the destructor, so a DirectCall must be destroyed before any
    // root pushed after it is popped (scope it as an RAII guard).
    DirectCall(const HPointer* closure, uint32_t nargs) : closure_(closure), nargs_(nargs) {
#if ECO_HEAP_VALIDATE
        return;
#endif
        const Closure* c = static_cast<const Closure*>(Allocator::resolveFast(*closure));
        if (!c) return;
        const uint32_t maxv = c->max_values;
        nvals_ = c->n_values;
        if (maxv > kMaxSlots || maxv < nvals_ || maxv - nvals_ != nargs) return;
        uint64_t mask = 0;
        const uint64_t empty = Kernel::Export::encode(alloc::listNil());
        for (uint32_t i = 0; i < maxv; ++i) {
            kinds_[i] = static_cast<uint8_t>(closureSlotKind(c, i));
            if (kinds_[i] == 0) mask |= uint64_t{1} << i;
            // Until the first call fills it, a pointer slot holds the Empty constant, which a
            // collection skips.
            args_[i] = (i < nvals_) ? static_cast<uint64_t>(c->values[i].i) : (kinds_[i] == 0 ? empty : 0);
        }
        K_ = static_cast<uint8_t>(c->result_kind);
        eval_ = reinterpret_cast<void*>(c->evaluator->generic);
        // The descriptor's `sat[nargs]` entry, when the compiler made one, takes the closure's
        // address and the arguments in registers and loads the captures itself, so a call skips
        // the argument array. Its parameters have the closure's own slot types, which is what
        // `call` passes; only integer-register kinds are used here (no Float argument).
        if (maxv <= SAT_MAX_ARITY && nargs >= 1 && nargs <= 3 && c->evaluator->stage_arity == maxv) {
            bool intRegs = true;
            for (uint32_t i = nvals_; i < maxv; ++i) intRegs = intRegs && kinds_[i] != 2;
            if (intRegs) sat_ = c->evaluator->sat[nargs];
        }
        maxv_ = maxv;
        mark_ = ecoRootMark();
        if (mask) eco_gc_push_stack_range(args_, maxv, mask);
        ok_ = true;
    }

    DirectCall(const DirectCall&) = delete;
    DirectCall& operator=(const DirectCall&) = delete;

    ~DirectCall() {
        if (ok_) ecoRootRelease(mark_);
    }

    // Whether the fast path applies; when false, nothing below may be called.
    bool ok() const { return ok_; }

    // The kind (0 boxed, 1 Int, 2 Float, 3 Char) the closure wants for argument `i` (0-based).
    uint32_t argKind(uint32_t i) const { return kinds_[nvals_ + i]; }

    // The kind the closure returns.
    uint32_t resultKind() const { return K_; }

    // Calls the closure with the `nargs` argument words in `args`, each already in the kind
    // `argKind` gives it (an encoded HPointer for kind 0, the raw value otherwise), and returns the
    // result word in the kind `resultKind` gives it: an encoded HPointer, an int64_t, the bits of a
    // double, or a code point. May collect: the caller must root every HPointer it holds except
    // those it passes here, which this call roots.
    uint64_t call(const uint64_t* args) {
        const Closure* c = static_cast<const Closure*>(Allocator::resolveFast(*closure_));
        if (sat_) return callSat(c, args);
        for (uint32_t i = 0; i < nvals_; ++i) args_[i] = static_cast<uint64_t>(c->values[i].i);
        for (uint32_t i = 0; i < nargs_; ++i) args_[nvals_ + i] = args[i];
        void** argv = reinterpret_cast<void**>(args_);
        switch (K_) {
            case 0: {
                using FnT = void* (*)(void**);
                return reinterpret_cast<uint64_t>(reinterpret_cast<FnT>(eval_)(argv));
            }
            case 1: {
                using FnT = int64_t (*)(void**);
                return static_cast<uint64_t>(reinterpret_cast<FnT>(eval_)(argv));
            }
            case 2: {
                using FnT = double (*)(void**);
                double r = reinterpret_cast<FnT>(eval_)(argv);
                uint64_t bits;
                std::memcpy(&bits, &r, sizeof(bits));
                return bits;
            }
            default: {
                using FnT = uint32_t (*)(void**);
                return static_cast<uint64_t>(reinterpret_cast<FnT>(eval_)(argv));
            }
        }
    }

    // Returns the value of the boxed Int, Float or Char `word` as a raw word of kind `kind` (1 to
    // 3), or `word` itself for kind 0.
    static uint64_t unbox(uint64_t word, uint32_t kind) {
        if (kind == 0) return word;
        const char* base = static_cast<const char*>(Kernel::Export::toPtr(word)) + sizeof(Header);
        switch (kind) {
            case 1: { int64_t v; std::memcpy(&v, base, sizeof(v)); return static_cast<uint64_t>(v); }
            case 2: { uint64_t v; std::memcpy(&v, base, sizeof(v)); return v; }
            default: { uint32_t v; std::memcpy(&v, base, sizeof(v)); return v; }
        }
    }

    // Returns the raw word `raw` of kind `kind` boxed, as an encoded HPointer; `raw` itself for kind
    // 0. Boxing allocates and may collect.
    static uint64_t box(uint64_t raw, uint32_t kind) {
        switch (kind) {
            case 0: return raw;
            case 1: return eco_alloc_int(static_cast<int64_t>(raw)).toBits();
            case 2: { double f; std::memcpy(&f, &raw, sizeof(f)); return eco_alloc_float(f).toBits(); }
            default: return eco_alloc_char(static_cast<uint32_t>(raw)).toBits();
        }
    }

private:
    // Calls `sat_` for the closure at `c`, its arguments in registers.
    uint64_t callSat(const Closure* c, const uint64_t* a) {
        void* cp = const_cast<Closure*>(c);
        switch (K_) {
            case 0: return reinterpret_cast<uint64_t>(satCall<void*>(cp, a));
            case 1: return static_cast<uint64_t>(satCall<int64_t>(cp, a));
            case 2: {
                double r = satCall<double>(cp, a);
                uint64_t bits;
                std::memcpy(&bits, &r, sizeof(bits));
                return bits;
            }
            default: return static_cast<uint64_t>(satCall<uint32_t>(cp, a));
        }
    }

    template <class R>
    R satCall(void* cp, const uint64_t* a) {
        switch (nargs_) {
            case 1: return reinterpret_cast<R (*)(void*, uint64_t)>(sat_)(cp, a[0]);
            case 2: return reinterpret_cast<R (*)(void*, uint64_t, uint64_t)>(sat_)(cp, a[0], a[1]);
            default: return reinterpret_cast<R (*)(void*, uint64_t, uint64_t, uint64_t)>(sat_)(cp, a[0], a[1], a[2]);
        }
    }

    const HPointer* closure_;
    void* sat_ = nullptr;
    uint32_t nargs_;
    uint32_t nvals_ = 0;
    uint32_t maxv_ = 0;
    uint8_t K_ = 0;
    bool ok_ = false;
    void* eval_ = nullptr;
    EcoRootMark mark_{};
    uint8_t kinds_[kMaxSlots] = {};
    uint64_t args_[kMaxSlots];
};

} // namespace Elm

#endif
