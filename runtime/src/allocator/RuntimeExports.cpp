//===- RuntimeExports.cpp - C-linkage runtime function implementations ----===//
//
// This file implements the C-linkage functions that are called from
// LLVM-generated code.
//
//===----------------------------------------------------------------------===//

#include "RuntimeExports.h"
#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "PermanentSpace.hpp"
#include "StringOps.hpp"
#include "ThreadLocalHeap.hpp"
#include "TypeInfo.hpp"

#include <algorithm>
#include <atomic>
#include <cassert>
#include <array>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <deque>
#include <map>  // call-census row merge
#include <memory>
#include <mutex>
#include <new>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

using namespace Elm;

//===----------------------------------------------------------------------===//
// HPointer Conversion Helpers
//===----------------------------------------------------------------------===//

namespace {

/// Convert a raw void* pointer to a uint64_t HPointer representation.
/// The HPointer will have constant=0, indicating a regular heap pointer.
/// Note: Elm never produces null pointers, so obj must be a valid heap pointer.
/// Validation is performed in Allocator::wrap().
inline HPtr ptrToHPointer(void* obj) {
    HPointer hp = Allocator::instance().wrap(obj);
    return HPtr::fromHPointer(hp);
}

/// Convert a uint64_t HPointer representation to a raw void* pointer.
/// Uses Allocator::resolve() to handle forwarding pointers during GC.
/// Returns nullptr for embedded constants (Nil, True, False, Unit, etc.)
/// since they don't have actual heap objects.
inline void* hpointerToPtr(uint64_t val) {
    HPointer hp;
    memcpy(&hp, &val, sizeof(hp));
    // Embedded constants don't have heap objects - return nullptr.
    if (hp.ptr_ind != 0) {
        return nullptr;
    }
    return Allocator::instance().resolve(hp);
}

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Thread-Local Output Stream for Capture Support
//===----------------------------------------------------------------------===//

namespace {

/// Thread-local output stream. When non-null, print output goes here instead of stderr.
thread_local std::ostringstream* tl_output_stream = nullptr;

/// Helper to output text - either to capture stream or stderr.
void output_text(const char* text) {
    if (tl_output_stream) {
        *tl_output_stream << text;
    } else {
        fputs(text, stderr);
    }
}

/// Helper to output formatted text.
template<typename... Args>
void output_format(const char* fmt, Args... args) {
    char buffer[256];
    snprintf(buffer, sizeof(buffer), fmt, args...);
    output_text(buffer);
}

/// Helper to output a single character.
void output_char(char c) {
    if (tl_output_stream) {
        *tl_output_stream << c;
    } else {
        fputc(c, stderr);
    }
}

/// Helper to print float values with proper Infinity and NaN formatting.
/// Elm uses "Infinity", "-Infinity", and "NaN" (not "inf", "-inf", "nan").
/// -0.0 is printed as "0", like Elm does.
void print_float(double d) {
    if (std::isinf(d)) {
        if (d > 0) {
            output_text("Infinity");
        } else {
            output_text("-Infinity");
        }
    } else if (std::isnan(d)) {
        output_text("NaN");
    } else if (d == 0.0) {
        // Print both +0.0 and -0.0 as "0", like Elm does.
        output_text("0");
    } else {
        // Use std::to_chars for the shortest round-trip representation,
        // matching JavaScript/Elm's Number.prototype.toString() behavior.
        char buf[32];
        auto [ptr, ec] = std::to_chars(buf, buf + sizeof(buf), d);
        *ptr = '\0';
        output_text(buf);
    }
}

} // namespace

//===----------------------------------------------------------------------===//
// Output Capture API Implementation
//===----------------------------------------------------------------------===//

extern "C" void* eco_set_output_stream(void* stream) {
    void* prev = tl_output_stream;
    tl_output_stream = static_cast<std::ostringstream*>(stream);
    return prev;
}

extern "C" void* eco_get_output_stream() {
    return tl_output_stream;
}

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

extern "C" void* eco_alloc_with_roots(uint32_t tag, uint64_t size,
                                       uint64_t* roots, uint32_t n_roots,
                                       uint64_t hptr_mask) {
    Allocator& alloc = Allocator::instance();
    // threaded-gc-04b: a large object takes the placement policy (P§3.1:
    // nursery up to the cap, else the YLOS, or old-gen pinned when
    // pointer-free), never the size-blind bump below. It may GC, so the
    // caller's roots are open across it, as on the slow path.
    if (__builtin_expect(size >= alloc.getLargeObjectThreshold(), 0)) {
        size_t saved = eco_gc_stack_range_point();
        if (n_roots > 0 && hptr_mask != 0) {
            eco_gc_push_stack_range(roots, n_roots, hptr_mask);
        }
        void* obj = alloc.allocate(static_cast<size_t>(size), static_cast<Tag>(tag));
        eco_gc_restore_stack_range_point(saved);
        return obj;
    }

    // Fast path: bump-pointer with no rooting. allocateFast cannot trigger
    // GC, so values in roots[] cannot move during this call.
    void* obj = alloc.allocateFast(static_cast<size_t>(size));
    if (obj) {
        // allocateFast does not init the header; do it consistently with
        // the slow path (which calls initHeaderForTag inside allocateSlow).
        initHeaderForTag(getHeader(obj), static_cast<Tag>(tag),
                         static_cast<size_t>(size));
        return obj;
    }

    // Slow path: open a stack root range over roots[], run allocateSlow,
    // close the range. After return, caller reads HPointer slots from
    // roots[] to pick up GC-relocated addresses.
    size_t saved = eco_gc_stack_range_point();
    if (n_roots > 0 && hptr_mask != 0) {
        eco_gc_push_stack_range(roots, n_roots, hptr_mask);
    }
    obj = alloc.allocateSlow(static_cast<size_t>(size), static_cast<Tag>(tag));
    eco_gc_restore_stack_range_point(saved);
    return obj;
}

//===----------------------------------------------------------------------===//
// Inline nursery allocation (plans/inline-nursery-allocation.md, HEAP_034)
//===----------------------------------------------------------------------===//

// Address of the calling thread's nursery bump state {ptr at +0, end at +8}.
// Declared memory(none) + gc-leaf on the codegen side (expandInlineAllocs)
// so LLVM can CSE/hoist it per function: the ADDRESS is thread-stable, only
// the contents change (minor GC), and the expansion re-loads
// them per allocation.
extern "C" void* eco_bump_state(void) {
    // Call-free fast path (benchmarks/tier2-opt.md Run L): inline TLS read
    // instead of the out-of-line Allocator::bumpState() call — 6
    // instructions, no call, no TLS-init guard (see tl_heap_'s constinit +
    // tls_model in Allocator.hpp). Only compiled Elm code calls this, and
    // the runtime is initialized before any compiled code runs (the
    // backend already declares it speculatable on exactly that basis), so
    // Allocator::bumpState()'s tl_heap_ assert is deliberately not
    // replicated here.
    return Allocator::instance().getCurrentThreadHeap()->getNursery().bumpState();
}

// Slow path for the codegen inline nursery bump: the inline compare missed,
// which under the contiguous from-space (HEAP_042) means one thing — the
// proactive-GC threshold tripped, or the space is exhausted. Returns
// UNINITIALIZED nursery storage — the caller stores the full header word and
// every payload field before its next safepoint (HEAP_034). Never returns
// null (aborts on OOM, HEAP_017 discipline). Statepointed: the ONLY
// statepoint in an inline-allocated construct sequence; field values live
// across it are relocated by RS4GC as ordinary SSA values (no hand-rooting).
extern "C" HPtr eco_alloc_inline_slow(uint64_t size) {
    assert(size <= 4096 && (size & 7) == 0 &&
           "eco_alloc_inline_slow: size out of inline-alloc bounds");
    // No pre-GC retry: with one contiguous extent the C++ compare tests the
    // SAME clamped end the inline compare just failed, so `allocateFast`
    // would be a guaranteed miss. (The block design retried it to pick up a
    // block advance without collecting.)
    return ptrToHPointer(Allocator::instance().allocateSlowRaw(size));
}

// Capacity guarantee for hoisted allocation checks (plans/
// capacity-check-hoisting.md, CGEN_074 / HEAP_041): establishes
// `bump_.end - bump_.ptr >= n` for the calling thread, allocating NOTHING.
// `n` is a compile-time-constant run budget, 8-aligned, in (0, 4096]
// (asserted). May run a minor GC; the post-GC bump resumes immediately after
// the survivors, so the headroom test is a single comparison against the
// contiguous from-space's clamped end (HEAP_042) rather than the block
// design's advance loop.
//
// Deliberately NOT gc-leaf: this is the ONE statepoint of a covered region.
// Values live across it are relocated by RS4GC as ordinary SSA. Called only
// from the cold edge of an ensure diamond, so the counter is free.
extern "C" void eco_ensure_nursery_slow(uint64_t n) {
    assert(n <= 4096 && (n & 7) == 0 &&
           "eco_ensure_nursery_slow: budget out of inline-alloc bounds");
    Allocator::instance().ensureNursery(static_cast<size_t>(n));
}

extern "C" HPtr eco_alloc_custom(uint32_t ctor_id, uint32_t field_count) {
    // Single-representation backstop (HEAP_044): nullary customs are embedded
    // null-cons constants; post-CGEN_079 nothing may allocate the 0-field
    // shape. Mirrors the fast/slow variants below.
    assert(field_count > 0 &&
           "0-field custom allocation forbidden (HEAP_044): embed a null-cons constant");
    if (field_count > CUSTOM_MAX_FIELDS) ecoFatalWideObject("eco_alloc_custom", field_count);
    // Layout C: Header + ctor/unboxed (8 bytes) + fields + K ext kind words.
    size_t size = wideByteSize(Tag_Custom, field_count);

    // No HPointer args to root: ctor_id/field_count are scalars, and the field
    // values are written by the caller after this returns. initHeaderForTag
    // sets size = field_count, unboxed = K and zeroes the ext words.
    void* obj = eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    assert(getHeader(obj)->size == field_count);

    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;
    return ptrToHPointer(obj);
}

extern "C" void eco_set_unboxed(HPtr obj_hptr, uint64_t bitmap) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);
    switch (header->tag) {
        case Tag_Custom: {
            // Custom's 48-bit bitmap stores 24 × 2-bit kinds.
            assert((bitmap >> 48) == 0 && "Custom unboxed bitmap overflow (>48 bits)");
            Custom* custom = static_cast<Custom*>(obj);
            custom->unboxed = bitmap & 0x0000FFFFFFFFFFFFULL;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            tuple->header.unboxed = static_cast<u8>(bitmap & 0xF);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            tuple->header.unboxed = static_cast<u8>(bitmap & 0x3F);
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            cons->header.unboxed = static_cast<u8>(bitmap & 0x3);
            break;
        }
        case Tag_Record:
        case Tag_Closure:
            // B11: their kinds live in Record::unboxed / Closure::unboxed, not header.unboxed;
            // the old default arm wrote a 2-bit kind where no reader looks.
            std::fprintf(stderr, "[eco] FATAL: eco_set_unboxed on tag %u (its kinds are not in header.unboxed)\n",
                         unsigned(header->tag));
            std::abort();
        default:
            // Array's uniform kind (and other header.unboxed users).
            header->unboxed = static_cast<u8>(bitmap & 0x3);
            break;
    }
}

// Chunked-list production switch (plans/chunked-list-representation.md §6).
// The backend injects a call to eco_enable_list_chunks() into @main's entry
// for modules compiled with config.list.chunks, so kernel bulk builders
// produce chunk spines exactly when compiled projections are chunk-aware.
extern "C" bool eco_g_list_chunks = false;

extern "C" void eco_enable_list_chunks(void) {
    eco_g_list_chunks = true;
}

// Cons-site tally (ECO_CONS_SITES=1, measurement builds): counts cons
// allocations by caller return address; dumped at exit with the main-module
// base so sites can be symbolized offline via addr2line. Thread-local maps
// merge into the global on thread destruction to keep the hot path lock-free.
extern "C" bool eco_g_cons_sites = false;

namespace {

std::mutex g_consSiteMu;
std::unordered_map<void *, uint64_t> g_consSitesAll;

void dumpConsSites() {
    std::lock_guard<std::mutex> l(g_consSiteMu);
    // Base of the main module: lowest mapping backed by the executable
    // itself (the heap arenas map lower, so the first line won't do).
    uintptr_t base = 0;
    char exe[512] = {0};
    ssize_t exeLen = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (FILE *f = fopen("/proc/self/maps", "r")) {
        char line[1024];
        while (fgets(line, sizeof line, f)) {
            if (exeLen > 0 && strstr(line, exe)) {
                base = static_cast<uintptr_t>(strtoull(line, nullptr, 16));
                break;
            }
        }
        fclose(f);
    }
    std::vector<std::pair<void *, uint64_t>> v(g_consSitesAll.begin(),
                                               g_consSitesAll.end());
    std::sort(v.begin(), v.end(),
              [](auto &a, auto &b) { return a.second > b.second; });
    uint64_t total = 0;
    for (auto &kv : v) total += kv.second;
    fprintf(stderr, "[cons-sites] base=%#zx total=%llu sites=%zu\n",
            static_cast<size_t>(base),
            static_cast<unsigned long long>(total), v.size());
    for (size_t i = 0; i < v.size() && i < 80; ++i) {
        fprintf(stderr, "[cons-sites] +%#zx %llu\n",
                reinterpret_cast<uintptr_t>(v[i].first) - base,
                static_cast<unsigned long long>(v[i].second));
    }
}

struct ConsSiteTls {
    std::unordered_map<void *, uint64_t> sites;
    ~ConsSiteTls() {
        std::lock_guard<std::mutex> l(g_consSiteMu);
        for (auto &kv : sites) g_consSitesAll[kv.first] += kv.second;
    }
};

thread_local ConsSiteTls g_consSiteTls;

struct ConsSiteInit {
    ConsSiteInit() {
        if (std::getenv("ECO_CONS_SITES")) {
            eco_g_cons_sites = true;
            std::atexit([] {
                {
                    // Merge the main thread's tally (its TLS destructor runs
                    // after atexit handlers).
                    std::lock_guard<std::mutex> l(g_consSiteMu);
                    for (auto &kv : g_consSiteTls.sites)
                        g_consSitesAll[kv.first] += kv.second;
                    g_consSiteTls.sites.clear();
                }
                dumpConsSites();
            });
        }
    }
};

ConsSiteInit g_consSiteInit;

} // namespace

extern "C" void eco_cons_site_tally(void *ra) {
    g_consSiteTls.sites[ra]++;
}

// `head_kind`: 2-bit primitive kind for the head slot (0=boxed, 1=Int, 2=Float,
// 3=Char). Stored into `cons->header.unboxed` at slot 0 (bits 1:0).
extern "C" HPtr eco_alloc_cons(uint64_t head, HPtr tail, uint32_t head_kind) {
    if (__builtin_expect(eco_g_cons_sites, 0))
        eco_cons_site_tally(__builtin_return_address(0));
    // Pack the field values as roots so the generic helper can keep them
    // valid across a slow-path GC. Mask bit i is set iff slot i is an
    // HPointer. tail (slot 1) is always a list HPointer; head (slot 0) is
    // a boxed HPointer iff head_kind == 0.
    uint64_t roots[2] = { head, tail.toBits() };
    uint64_t mask = (head_kind != 0) ? 0x2 : 0x3;

    void* obj = eco_alloc_with_roots(Tag_Cons, sizeof(Cons), roots, 2, mask);
    if (!obj) return HPtr::fromBits(0);

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = static_cast<i64>(roots[0]);
    HPointer tail_hp;
    memcpy(&tail_hp, &roots[1], sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

// `unboxed_mask`: 2-bit-per-slot kind bitmap (4 bits used for 2 slots).
extern "C" HPtr eco_alloc_tuple2(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    uint64_t roots[2] = { a, b };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 2);

    void* obj = eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, mask);
    if (!obj) return HPtr::fromBits(0);

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);
    return ptrToHPointer(obj);
}

// `unboxed_mask`: 2-bit-per-slot kind bitmap (6 bits used for 3 slots).
extern "C" HPtr eco_alloc_tuple3(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    uint64_t roots[3] = { a, b, c };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 3);

    void* obj = eco_alloc_with_roots(Tag_Tuple3, sizeof(Tuple3), roots, 3, mask);
    if (!obj) return HPtr::fromBits(0);

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);
    tup->c.i = static_cast<i64>(roots[2]);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap) {
    if (field_count > RECORD_MAX_FIELDS) ecoFatalWideObject("eco_alloc_record", field_count);
    // Size: Header (8) + unboxed bitmap (8) + fields (N * 8) + K ext kind words.
    // The ext words stay zero (boxed) until codegen stores them (HEAP_077).
    size_t size = wideByteSize(Tag_Record, field_count);

    // No HPointer args to root: field values are written by caller after.
    void* obj = eco_alloc_with_roots(Tag_Record, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    Record* rec = static_cast<Record*>(obj);
    rec->header.size = field_count;   // equal to initHeaderForTag's inversion
    assert(rec->header.unboxed == extWords(field_count, RECORD_HDR_SLOTS));
    rec->unboxed = unboxed_bitmap;
    return ptrToHPointer(obj);
}

extern "C" void eco_store_record_field(HPtr record_hptr, uint32_t index, HPtr value) {
    // Per-write stale-pointer tripwire on the boxed value being stored.
    alloc::validateNurseryHPtrBits(value.toBits());
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    // Store as raw 64-bit value (HPointer).
    rec->values[index].i = static_cast<i64>(value.toBits());
}

extern "C" void eco_store_record_field_i64(HPtr record_hptr, uint32_t index, int64_t value) {
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    rec->values[index].i = value;
}

extern "C" void eco_store_record_field_f64(HPtr record_hptr, uint32_t index, double value) {
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    rec->values[index].f = value;
}

//===----------------------------------------------------------------------===//
// Uninit allocators + field stores for Tuple2 / Tuple3 / Cons (forward ABI;
// not yet exercised by lowering — see plans/wrapper-fca-fix.md).
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_alloc_tuple2_uninit(uint32_t unboxed_mask) {
    void* obj = eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = 0;
    tup->b.i = 0;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple3_uninit(uint32_t unboxed_mask) {
    void* obj = eco_alloc_with_roots(Tag_Tuple3, sizeof(Tuple3), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = 0;
    tup->b.i = 0;
    tup->c.i = 0;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_cons_uninit(uint32_t head_kind) {
    void* obj = eco_alloc_with_roots(Tag_Cons, sizeof(Cons), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = 0;
    HPointer null_hp;
    memset(&null_hp, 0, sizeof(null_hp));
    cons->tail = null_hp;
    return ptrToHPointer(obj);
}

static inline Unboxable* tupleSlots(void* tuple) {
    return reinterpret_cast<Unboxable*>(
        reinterpret_cast<uint8_t*>(tuple) + sizeof(Header));
}

extern "C" void eco_store_tuple_field(HPtr tuple_hptr, uint32_t index, HPtr value) {
    alloc::validateNurseryHPtrBits(value.toBits());
    void* tuple = hpointerToPtr(tuple_hptr.toBits());
    if (!tuple) return;
    tupleSlots(tuple)[index].i = static_cast<i64>(value.toBits());
}

extern "C" void eco_store_tuple_field_i64(HPtr tuple_hptr, uint32_t index, int64_t value) {
    void* tuple = hpointerToPtr(tuple_hptr.toBits());
    if (!tuple) return;
    tupleSlots(tuple)[index].i = value;
}

extern "C" void eco_store_tuple_field_f64(HPtr tuple_hptr, uint32_t index, double value) {
    void* tuple = hpointerToPtr(tuple_hptr.toBits());
    if (!tuple) return;
    tupleSlots(tuple)[index].f = value;
}

extern "C" void eco_store_cons_head(HPtr cons_hptr, HPtr value) {
    alloc::validateNurseryHPtrBits(value.toBits());
    void* cons = hpointerToPtr(cons_hptr.toBits());
    if (!cons) return;
    static_cast<Cons*>(cons)->head.i = static_cast<i64>(value.toBits());
}

extern "C" void eco_store_cons_head_i64(HPtr cons_hptr, int64_t value) {
    void* cons = hpointerToPtr(cons_hptr.toBits());
    if (!cons) return;
    static_cast<Cons*>(cons)->head.i = value;
}

extern "C" void eco_store_cons_head_f64(HPtr cons_hptr, double value) {
    void* cons = hpointerToPtr(cons_hptr.toBits());
    if (!cons) return;
    static_cast<Cons*>(cons)->head.f = value;
}

extern "C" void eco_store_cons_tail(HPtr cons_hptr, HPtr value) {
    alloc::validateNurseryHPtrBits(value.toBits());
    void* cons = hpointerToPtr(cons_hptr.toBits());
    if (!cons) return;
    HPointer tail_hp;
    uint64_t bits = value.toBits();
    memcpy(&tail_hp, &bits, sizeof(tail_hp));
    static_cast<Cons*>(cons)->tail = tail_hp;
}

extern "C" HPtr eco_alloc_string(uint32_t length) {
    // Size: Header + length * sizeof(u16), aligned to 8 bytes
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;  // Align to 8 bytes

    void* obj = eco_alloc_with_roots(Tag_String, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    // initHeaderForTag derives Tag_String header.size from byte size; for the
    // common case that matches `length`, but writing it explicitly is robust
    // to subsequent rounding.
    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;
    return ptrToHPointer(obj);
}

// -----------------------------------------------------------------------------
// String-literal interning.
//
// Each `eco.string_literal` / string-`case` pattern lowers to a call to one of
// the eco_alloc_string_literal* functions, passing the address of its unique,
// stable rodata global (`__eco_str_N` / `__eco_str_case_*`). Historically each
// call allocated a fresh permanent old-gen object *every time the op executed*
// — repeated allocation churn and old-gen pressure for literals in hot code.
//
// We intern by that global's address: the first call for a given global
// allocates the permanent object and caches its HPointer in an addRoot'd slot;
// subsequent calls return the cached value. The cache is THREAD-LOCAL because
// permanent allocation and the RootSet are per-thread (ThreadLocalHeap): a
// literal is interned at most once per thread, its object lives in that
// thread's old gen, and the cached HPointer is registered as a long-lived root
// in that thread's RootSet (for liveness across major GC and fixup across
// compaction). No HPointer is ever shared across threads.
// -----------------------------------------------------------------------------
namespace {

struct LiteralTable {
    uint64_t generation = 0;  // heap epoch this cache was built under
    std::unordered_map<const void*, Elm::HPointer*> byGlobal;
    // Stable storage for the root slots: a deque of fixed chunks so slot
    // addresses never move as the table grows (addRoot holds these pointers).
    std::deque<std::array<Elm::HPointer, 64>> chunks;
    size_t nextSlot = 64;  // forces a fresh chunk on first use

    // Drops the whole cache if the heap was reset since it was built: reset()
    // destroys all thread heaps and RootSets, so every cached HPointer (and
    // every addRoot registration) is stale. The next miss rebuilds against the
    // fresh heap. Never fires in the AOT runtime (one heap epoch for the whole
    // process); only the test harness resets.
    void syncEpoch(uint64_t gen) {
        if (gen != generation) {
            byGlobal.clear();
            chunks.clear();
            nextSlot = 64;
            generation = gen;
        }
    }

    Elm::HPointer* newSlot() {
        if (nextSlot == 64) {
            chunks.emplace_back();
            nextSlot = 0;
        }
        Elm::HPointer* slot = &chunks.back()[nextSlot++];
        *slot = Elm::HPointer{};  // null until filled by the caller
        // NOT rooted here: interned objects are born in the PermanentSpace
        // (GC-invisible, immortal — HEAP_036), so the cached HPointer never
        // needs GC fixup or liveness. internLiteral roots the slot only on
        // the old-gen fallback path (PermanentSpace exhaustion).
        return slot;
    }
};

LiteralTable& literalTable() {
    static thread_local LiteralTable table;
    return table;
}

// Allocates an intern object as a TRUE permanent (Elm::PermanentSpace —
// GC-invisible, never rooted, HEAP_036); falls back to rooted old-gen
// allocation only if the permanent reservation is exhausted. Interned
// string literals are pointer-free and interned closure0s have zeroed
// value slots, so both are CLOSED subgraphs by construction — no copier
// involved.
inline void* allocInternObject(Elm::Tag tag, size_t size) {
    // ECO_CAF_PERMANENT=0 reverts interning to rooted old-gen allocation
    // too, so the escape hatch restores the entire pre-HEAP_036 behavior.
    static const bool permanent_enabled = [] {
        const char* e = std::getenv("ECO_CAF_PERMANENT");
        return e == nullptr || e[0] != '0';
    }();
    size = (size + 7) & ~static_cast<size_t>(7);
    if (permanent_enabled) {
        auto& perm = Elm::PermanentSpace::instance();
        if (void* obj = perm.allocate(size)) {
            initHeaderForTag(getHeader(obj), tag, size);
            perm.stats.interned_objects++;
            perm.stats.interned_bytes += size;
            return obj;
        }
    }
    return Allocator::instance().allocatePermanent(size, tag);
}

// Shared interning body: `alloc` allocates + fills the permanent object on a
// cache miss and returns its HPointer word. The cached slot is GC-rooted
// only when the object did NOT land in the PermanentSpace (old-gen
// fallback) — permanent objects never move and never die, so their cached
// pointers need no GC attention.
template <class AllocFn>
inline HPtr internLiteral(const void* key, AllocFn&& alloc) {
    LiteralTable& table = literalTable();
    table.syncEpoch(Allocator::instance().heapGeneration());
    auto it = table.byGlobal.find(key);
    if (it != table.byGlobal.end()) {
        return HPtr::fromHPointer(*it->second);
    }
    HPtr result = alloc();
    Elm::HPointer* slot = table.newSlot();
    *slot = result.toHPointer();
    table.byGlobal[key] = slot;
    uint64_t raw = result.toBits();
    if (!Elm::isConstantBits(raw) &&
        !Elm::PermanentSpace::instance().contains(
            reinterpret_cast<void*>(raw))) {
        Elm::Allocator::instance().getRootSet().addRoot(slot);
    }
    return result;
}

}  // namespace

extern "C" HPtr eco_alloc_string_literal(const uint16_t* chars, uint32_t length) {
    return internLiteral(chars, [&]() -> HPtr {
        // Allocate directly in old gen (permanent). Size: Header + UTF-16 payload.
        size_t size = sizeof(Header) + length * sizeof(u16);
        size = (size + 7) & ~7;
        void* obj = allocInternObject(Tag_String, size);
        if (!obj) return HPtr::fromBits(0);
        ElmString* str = static_cast<ElmString*>(obj);
        str->header.size = length;
        std::memcpy(str->chars, chars, length * sizeof(u16));
        return ptrToHPointer(obj);
    });
}

// ASCII string literal: the compiler emits an [N x i8] global and calls this
// for literals whose bytes are all < 0x80. Interned (like the UTF-16 form) and
// allocated as a permanent inline Tag_StringUtf8Leaf — half the memory of the
// UTF-16 form and no transcode. `byteLen` == the logical UTF-16 unit count
// (1 ASCII byte per unit). When UTF-8 strings are disabled it widens to a
// permanent UTF-16 leaf so the master switch fully rolls back.
extern "C" HPtr eco_alloc_string_literal_utf8(const uint8_t* bytes,
                                              uint32_t byteLen) {
    return internLiteral(bytes, [&]() -> HPtr {
        if (!Allocator::instance().getConfig().utf8_strings_enabled) {
            size_t size = sizeof(Header) + byteLen * sizeof(u16);
            size = (size + 7) & ~7;
            void* obj = allocInternObject(Tag_String, size);
            if (!obj) return HPtr::fromBits(0);
            ElmString* str = static_cast<ElmString*>(obj);
            str->header.size = byteLen;
            for (uint32_t i = 0; i < byteLen; ++i)
                str->chars[i] = static_cast<u16>(bytes[i]);
            return ptrToHPointer(obj);
        }
        size_t size = sizeof(ElmStringUtf8Leaf) + byteLen * sizeof(u8);
        size = (size + 7) & ~7;
        void* obj =
            allocInternObject(Tag_StringUtf8Leaf, size);
        if (!obj) return HPtr::fromBits(0);
        ElmStringUtf8Leaf* leaf = static_cast<ElmStringUtf8Leaf*>(obj);
        leaf->header.size = byteLen;
        std::memcpy(leaf->bytes, bytes, byteLen);
        return ptrToHPointer(obj);
    });
}

// -----------------------------------------------------------------------------
// Slot-filling twins of the two interning entry points (LSS loop step 18b).
//
// Generated code caches the interned HPointer word in a zero-initialised i64
// global (`__eco_strlit$__eco_str_N`) next to the literal's bytes, and only
// calls in here when that slot still reads 0. The word is published ONLY when
// the interned object landed in the PermanentSpace (HEAP_036: immortal,
// GC-invisible, never moves, shared by every thread), so the slot needs no GC
// root and no fixup — which is exactly why createGlobalRootInitFunction skips
// the `__eco_strlit$` prefix. On the old-gen fallback (permanent reservation
// exhausted) the slot stays 0 and every evaluation keeps calling through, where
// internLiteral roots the cached HPointer as it always did.
//
// Cross-thread: LiteralTable is thread_local but permanent objects are
// process-wide, so a word published by one thread denotes a valid immortal
// object for every thread; two threads racing publish either the same object or
// two equivalent immortal ones, both correct String values. Relaxed atomics keep
// it formally race-free. `Allocator::reset` (test harness only) does not free
// the PermanentSpace, so a surviving slot still denotes a live object.
// -----------------------------------------------------------------------------
static inline void publishLiteralSlot(HPtr r, uint64_t* slot) {
    uint64_t raw = r.toBits();
    if (raw == 0 || Elm::isConstantBits(raw)) return;
    if (!Elm::PermanentSpace::instance().contains(reinterpret_cast<void*>(raw)))
        return;
    __atomic_store_n(slot, raw, __ATOMIC_RELAXED);
}

extern "C" HPtr eco_string_literal_fill(const uint16_t* chars, uint32_t length,
                                        uint64_t* slot) {
    HPtr r = eco_alloc_string_literal(chars, length);
    publishLiteralSlot(r, slot);
    return r;
}

extern "C" HPtr eco_string_literal_utf8_fill(const uint8_t* bytes,
                                             uint32_t byteLen, uint64_t* slot) {
    HPtr r = eco_alloc_string_literal_utf8(bytes, byteLen);
    publishLiteralSlot(r, slot);
    return r;
}

//===----------------------------------------------------------------------===//
// Closure allocation census (ECO_CLOSURE_STATS=1)
//
// Counts every closure allocation, keyed by evaluator function pointer, so
// the top allocation sites can be ranked (HOF-elimination plan H0.1,
// plans/hof-elimination-closure-alloc-reduction.md). `creates` counts fresh
// closures (papCreate paths incl. group allocation); `extends` counts the
// copy-allocations eco_pap_extend_l performs.
//
// The table is a fixed-size open-addressed array claimed with CAS so worker
// threads (scheduler/timers) can record safely. Zero overhead when the env
// var is unset beyond one cached-bool branch per allocation. The dump runs
// via atexit and prints an `anchor=` line (runtime address of
// eco_alloc_closure) so benchmarks/closure-census.sh can compute the ASLR slide
// against `nm` output when symbolizing.
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_alloc_closure(void* func_ptr, uint32_t num_captures);

namespace {

struct ClosureStatsEntry {
    std::atomic<uint64_t> fp{0};
    std::atomic<uint64_t> creates{0};
    std::atomic<uint64_t> extends{0};
};

constexpr size_t kClosureStatsSlots = 1 << 16; // 64Ki slots, power of two
constexpr size_t kClosureStatsMaxProbe = 128;

ClosureStatsEntry* g_closure_stats_table = nullptr;
std::atomic<uint64_t> g_closure_stats_overflow{0};
std::atomic<uint64_t> g_closure_creates_total{0};
std::atomic<uint64_t> g_closure_extends_total{0};
std::atomic<bool> g_closure_stats_dumped{false};

void closureStatsDumpImpl() {
    if (g_closure_stats_dumped.exchange(true)) return;
    if (!g_closure_stats_table) return;

    struct Row {
        uint64_t fp;
        uint64_t creates;
        uint64_t extends;
    };
    std::vector<Row> rows;
    for (size_t i = 0; i < kClosureStatsSlots; ++i) {
        uint64_t fp = g_closure_stats_table[i].fp.load(std::memory_order_relaxed);
        if (fp == 0) continue;
        rows.push_back({fp,
                        g_closure_stats_table[i].creates.load(std::memory_order_relaxed),
                        g_closure_stats_table[i].extends.load(std::memory_order_relaxed)});
    }
    std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
        return a.creates + a.extends > b.creates + b.extends;
    });

    std::fprintf(stderr, "[closure-stats] anchor=eco_alloc_closure:0x%llx\n",
                 static_cast<unsigned long long>(
                     reinterpret_cast<uint64_t>(&eco_alloc_closure)));
    std::fprintf(stderr,
                 "[closure-stats] creates=%llu extends=%llu distinct=%zu overflow=%llu\n",
                 static_cast<unsigned long long>(
                     g_closure_creates_total.load(std::memory_order_relaxed)),
                 static_cast<unsigned long long>(
                     g_closure_extends_total.load(std::memory_order_relaxed)),
                 rows.size(),
                 static_cast<unsigned long long>(
                     g_closure_stats_overflow.load(std::memory_order_relaxed)));
    for (const Row& r : rows) {
        std::fprintf(stderr, "[closure-stats] fp=0x%llx creates=%llu extends=%llu\n",
                     static_cast<unsigned long long>(r.fp),
                     static_cast<unsigned long long>(r.creates),
                     static_cast<unsigned long long>(r.extends));
    }
    std::fflush(stderr);
}

bool closureStatsInit() {
    const char* e = std::getenv("ECO_CLOSURE_STATS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return false;
    // Value-initialize so the atomics start at zero.
    g_closure_stats_table = new (std::nothrow) ClosureStatsEntry[kClosureStatsSlots]();
    if (!g_closure_stats_table) return false;
    std::atexit(closureStatsDumpImpl);
    return true;
}

inline bool closureStatsEnabled() {
    static const bool enabled = closureStatsInit();
    return enabled;
}

void closureStatsRecord(const void* func_ptr, bool isExtend) {
    if (!closureStatsEnabled()) return;
    uint64_t fp = reinterpret_cast<uint64_t>(func_ptr);
    if (fp == 0) fp = 1; // 0 marks an empty slot
    if (isExtend) {
        g_closure_extends_total.fetch_add(1, std::memory_order_relaxed);
    } else {
        g_closure_creates_total.fetch_add(1, std::memory_order_relaxed);
    }
    size_t idx = (fp >> 3) & (kClosureStatsSlots - 1);
    for (size_t probe = 0; probe < kClosureStatsMaxProbe; ++probe) {
        ClosureStatsEntry& entry =
            g_closure_stats_table[(idx + probe) & (kClosureStatsSlots - 1)];
        uint64_t cur = entry.fp.load(std::memory_order_relaxed);
        if (cur == 0) {
            uint64_t expected = 0;
            if (!entry.fp.compare_exchange_strong(expected, fp,
                                                  std::memory_order_relaxed)) {
                if (expected != fp) continue; // lost race to a different fp
            }
            cur = fp;
        }
        if (cur == fp) {
            (isExtend ? entry.extends : entry.creates)
                .fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }
    g_closure_stats_overflow.fetch_add(1, std::memory_order_relaxed);
}

} // anonymous namespace

// Manual/embedder hook: dump the census now (idempotent). The atexit path
// covers normal AOT exits; embed hosts that never exit can call this.
extern "C" void eco_closure_stats_dump(void) { closureStatsDumpImpl(); }

//===----------------------------------------------------------------------===//
// Closure-dispatch census (ECO_DISPATCH_STATS=1)
//
// Counts every DYNAMIC dispatch — an indirect call through a closure's
// evaluator function pointer — keyed by that evaluator, so the hottest
// dynamically-dispatched call sites can be ranked (LSS dispatch-value plan E0,
// plans/lss-dispatch-value-extraction.md). Statically-resolved calls (a direct
// call to a $cap fast clone) never make an indirect evaluator call and so are
// NOT counted here (their coverage is tracked separately as `fast`, below).
//
// WHERE the indirect call actually happens (verified): there are exactly two
// leaf primitives that invoke `closure->evaluator`:
//   1. invokeSaturatedTyped()            — the K-switch; reached from
//      eco_apply_closure_eval's exact branch, eco_closure_call_saturated_eval,
//      and eco_closure_call_saturated's K!=0 branch.
//   2. eco_closure_call_saturated()'s K==0 boxed-result direct call.
// Recording `sat` at those two points counts every saturated indirect call
// EXACTLY ONCE regardless of how the site was lowered — the generic/unknown-
// saturation funnel (eco_apply_closure_eval / eco_apply_segmentation_unknown),
// the typed statically-known-saturation path (emitInlineClosureCall ->
// eco_closure_call_saturated{,_eval}), C++ kernel callers, and thunk force.
//
// Counter semantics:
//   sat  : a saturated indirect evaluator call — THE dynamic-dispatch total,
//          and the population LSS singleton/small-set stamping would convert to
//          direct calls. Recorded at the two leaf primitives above.
//   gen  : the SUBSET of `sat` that flowed through the generic/unknown-
//          saturation funnel (recorded at eco_apply_closure_eval's exact + over
//          branches, which each lead to exactly one `sat` for that stage). So
//          `gen` <= `sat`, and `typed = sat - gen` is the statically-known-
//          arity dispatch (the emitInlineClosureCall path). An over-saturated
//          apply records one `gen` per stage, matching its per-stage `sat`.
//   fast : statically-stamped fast-dispatch executions (a direct $cap call,
//          no indirect evaluator call), emitted by eco_dispatch_stats_fast at
//          the call site under the ECO_LSS_DISPATCH_SITE_COUNTERS lowering env.
//          Kept for LSS coverage = fast / (sat + fast).
//
// NB under-saturated applies (num_args < remaining) do NOT call the evaluator —
// they grow a PAP via eco_pap_extend_l, an allocation already counted by the
// closure census (ECO_CLOSURE_STATS `extends`). They are intentionally NOT in
// this dispatch census.
//
// Same fixed 64Ki open-addressed CAS table as the closure census; zero cost
// (one cached-bool branch) when ECO_DISPATCH_STATS is unset. Dumps at exit with
// an `anchor=eco_alloc_closure:0x...` line (shared with the closure census) so
// benchmarks/dispatch-census.sh can slide-correct fp values against `nm`.
//===----------------------------------------------------------------------===//

namespace {

enum class DispatchKind { Sat, Generic, Fast };

struct DispatchStatsEntry {
    std::atomic<uint64_t> fp{0};
    std::atomic<uint64_t> sat{0};   // saturated indirect evaluator calls (dispatch total)
    std::atomic<uint64_t> gen{0};   // subset of sat reached via the generic funnel
    std::atomic<uint64_t> fast{0};  // stamped direct $cap calls (coverage; E0.4)
};

constexpr size_t kDispatchStatsSlots = 1 << 16; // 64Ki slots, power of two
constexpr size_t kDispatchStatsMaxProbe = 128;

DispatchStatsEntry* g_dispatch_stats_table = nullptr;
std::atomic<uint64_t> g_dispatch_stats_overflow{0};
std::atomic<uint64_t> g_dispatch_sat_total{0};
std::atomic<uint64_t> g_dispatch_gen_total{0};
std::atomic<uint64_t> g_dispatch_fast_total{0};
std::atomic<bool> g_dispatch_stats_dumped{false};

// Generic-call reason census (plans/staging-honesty-and-production-test-pipeline.md
// P0.4): one counter per `_gencall_reason` tag the compiler puts on a
// segmentation_unknown / generic_apply papExtend under the census flag, bumped
// by eco_gencall_stats when the lowering ran with ECO_GENCALL_COUNTERS.
constexpr int kGencallReasons = 16;
std::atomic<uint64_t> g_gencall_counts[kGencallReasons] = {};

void dispatchStatsDumpImpl() {
    if (g_dispatch_stats_dumped.exchange(true)) return;
    if (!g_dispatch_stats_table) return;

    struct Row {
        uint64_t fp, sat, gen, fast;
    };
    std::vector<Row> rows;
    for (size_t i = 0; i < kDispatchStatsSlots; ++i) {
        uint64_t fp = g_dispatch_stats_table[i].fp.load(std::memory_order_relaxed);
        if (fp == 0) continue;
        rows.push_back({fp,
                        g_dispatch_stats_table[i].sat.load(std::memory_order_relaxed),
                        g_dispatch_stats_table[i].gen.load(std::memory_order_relaxed),
                        g_dispatch_stats_table[i].fast.load(std::memory_order_relaxed)});
    }
    std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
        return a.sat > b.sat; // rank by dynamic-dispatch weight
    });

    uint64_t sat_total = g_dispatch_sat_total.load(std::memory_order_relaxed);
    uint64_t gen_total = g_dispatch_gen_total.load(std::memory_order_relaxed);
    std::fprintf(stderr, "[dispatch-stats] anchor=eco_alloc_closure:0x%llx\n",
                 static_cast<unsigned long long>(
                     reinterpret_cast<uint64_t>(&eco_alloc_closure)));
    std::fprintf(stderr,
                 "[dispatch-stats] sat=%llu gen=%llu typed=%llu fast=%llu "
                 "distinct=%zu overflow=%llu\n",
                 static_cast<unsigned long long>(sat_total),
                 static_cast<unsigned long long>(gen_total),
                 static_cast<unsigned long long>(sat_total - gen_total),
                 static_cast<unsigned long long>(g_dispatch_fast_total.load(std::memory_order_relaxed)),
                 rows.size(),
                 static_cast<unsigned long long>(g_dispatch_stats_overflow.load(std::memory_order_relaxed)));
    std::fprintf(stderr, "[gencall-stats]");
    for (int i = 0; i < kGencallReasons; ++i) {
        uint64_t n = g_gencall_counts[i].load(std::memory_order_relaxed);
        if (n != 0) std::fprintf(stderr, " r%d=%llu", i, static_cast<unsigned long long>(n));
    }
    std::fprintf(stderr, "\n");
    for (const Row& r : rows) {
        std::fprintf(stderr,
                     "[dispatch-stats] fp=0x%llx sat=%llu gen=%llu fast=%llu\n",
                     static_cast<unsigned long long>(r.fp),
                     static_cast<unsigned long long>(r.sat),
                     static_cast<unsigned long long>(r.gen),
                     static_cast<unsigned long long>(r.fast));
    }
    std::fflush(stderr);
}

bool dispatchStatsInit() {
    const char* e = std::getenv("ECO_DISPATCH_STATS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return false;
    // Value-initialize so the atomics start at zero.
    g_dispatch_stats_table = new (std::nothrow) DispatchStatsEntry[kDispatchStatsSlots]();
    if (!g_dispatch_stats_table) return false;
    std::atexit(dispatchStatsDumpImpl);
    return true;
}

inline bool dispatchStatsEnabled() {
    static const bool enabled = dispatchStatsInit();
    return enabled;
}

// Record one dispatch event. Allocation-free and heap-free (reads only the
// evaluator code pointer), so it is safe to call anywhere in the apply path,
// including between GC stack-range pushes.
void dispatchStatsRecord(const void* evaluator_fp, DispatchKind kind) {
    if (!dispatchStatsEnabled()) return;
    uint64_t fp = reinterpret_cast<uint64_t>(evaluator_fp);
    if (fp == 0) fp = 1; // 0 marks an empty slot
    switch (kind) {
        case DispatchKind::Sat:     g_dispatch_sat_total.fetch_add(1, std::memory_order_relaxed); break;
        case DispatchKind::Generic: g_dispatch_gen_total.fetch_add(1, std::memory_order_relaxed); break;
        case DispatchKind::Fast:    g_dispatch_fast_total.fetch_add(1, std::memory_order_relaxed); break;
    }
    size_t idx = (fp >> 3) & (kDispatchStatsSlots - 1);
    for (size_t probe = 0; probe < kDispatchStatsMaxProbe; ++probe) {
        DispatchStatsEntry& entry =
            g_dispatch_stats_table[(idx + probe) & (kDispatchStatsSlots - 1)];
        uint64_t cur = entry.fp.load(std::memory_order_relaxed);
        if (cur == 0) {
            uint64_t expected = 0;
            if (!entry.fp.compare_exchange_strong(expected, fp,
                                                  std::memory_order_relaxed)) {
                if (expected != fp) continue; // lost race to a different fp
            }
            cur = fp;
        }
        if (cur == fp) {
            switch (kind) {
                case DispatchKind::Sat:     entry.sat.fetch_add(1, std::memory_order_relaxed); break;
                case DispatchKind::Generic: entry.gen.fetch_add(1, std::memory_order_relaxed); break;
                case DispatchKind::Fast:    entry.fast.fetch_add(1, std::memory_order_relaxed); break;
            }
            return;
        }
    }
    g_dispatch_stats_overflow.fetch_add(1, std::memory_order_relaxed);
}

} // anonymous namespace

// Manual/embedder hook: dump the dispatch census now (idempotent).
extern "C" void eco_dispatch_stats_dump(void) { dispatchStatsDumpImpl(); }

// Lowering-time hook (LSS plan E0.4): the MLIR lowering emits a call to this
// immediately before a stamped fast-dispatch `$cap` call when
// ECO_LSS_DISPATCH_SITE_COUNTERS is set at lowering time, passing the closure's
// generic-clone ($clo) symbol so the fast row keys to the same fp the sat rows
// use. Allocation-free / GC-leaf.
extern "C" void eco_dispatch_stats_fast(void* evaluator_fp) {
    dispatchStatsRecord(evaluator_fp, DispatchKind::Fast);
}

// Lowering-time hook (plans/staging-honesty-and-production-test-pipeline.md
// P0.4): emitted before a generic papExtend that carries `_gencall_reason`
// when ECO_GENCALL_COUNTERS is set at lowering time. Counts under
// ECO_DISPATCH_STATS only. Allocation-free / GC-leaf.
extern "C" void eco_gencall_stats(int32_t reason) {
    if (!dispatchStatsEnabled()) return;
    g_gencall_counts[static_cast<uint32_t>(reason) & (kGencallReasons - 1)].fetch_add(
        1, std::memory_order_relaxed);
}

// ---- Call-kind survivor census (plans/call-survivor-census.md) -------------
//
// The backend's instrumentCallCensus (EcoBackend.cpp, under ECO_CALL_CENSUS at
// lowering time) gives every SURVIVING call instruction in generated code a
// per-site i64 slot plus name/kind tables, and registers each partition's
// tables here from a llvm.global_ctors constructor. Counters increment
// unconditionally in an instrumented binary; only the exit dump is gated (on
// ECO_DISPATCH_STATS, the census workflow's runtime knob).
//
// Kind enum MIRRORED from the backend's CallCensusKind — keep in sync.
namespace {

constexpr int kCallCensusKinds = 7;
const char* const kCallCensusKindNames[kCallCensusKinds] = {
    "elm", "kernel", "cap", "helper", "runtime", "extern", "indirect"};

struct CallCensusTable {
    const uint64_t* counts;
    const char* const* names;
    const uint8_t* kinds;
    uint64_t n;
};

// Function-local static: constructors run pre-main, serial — no SIOF, no lock.
std::vector<CallCensusTable>& callCensusTables() {
    static std::vector<CallCensusTable> tables;
    return tables;
}

std::atomic<bool> g_call_census_dumped{false};

void callCensusDumpImpl() {
    if (g_call_census_dumped.exchange(true)) return;
    const char* e = std::getenv("ECO_DISPATCH_STATS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return;
    const auto& tables = callCensusTables();
    if (tables.empty()) return;

    uint64_t perKind[kCallCensusKinds] = {};
    uint64_t sites = 0;
    // Merge rows by callee name — cross-partition callees appear in several
    // tables, and inlining duplicates sites within one.
    std::map<std::string, std::pair<uint8_t, uint64_t>> rows;
    for (const CallCensusTable& t : tables) {
        sites += t.n;
        for (uint64_t i = 0; i < t.n; ++i) {
            uint8_t k = t.kinds[i];
            uint64_t c = t.counts[i];
            if (k < kCallCensusKinds) perKind[k] += c;
            auto& row = rows[t.names[i]];
            row.first = k;
            row.second += c;
        }
    }

    std::fprintf(stderr, "[call-census]");
    for (int k = 0; k < kCallCensusKinds; ++k)
        std::fprintf(stderr, " %s=%llu", kCallCensusKindNames[k],
                     static_cast<unsigned long long>(perKind[k]));
    std::fprintf(stderr, " sites=%llu tables=%zu\n",
                 static_cast<unsigned long long>(sites), tables.size());

    // Every row (grep/awk is the consumer), sorted count-desc, name-asc for
    // determinism.
    std::vector<const std::pair<const std::string, std::pair<uint8_t, uint64_t>>*>
        sorted;
    sorted.reserve(rows.size());
    for (const auto& kv : rows) sorted.push_back(&kv);
    std::sort(sorted.begin(), sorted.end(), [](const auto* a, const auto* b) {
        if (a->second.second != b->second.second)
            return a->second.second > b->second.second;
        return a->first < b->first;
    });
    for (const auto* kv : sorted)
        std::fprintf(stderr, "[call-census] row kind=%s name=%s count=%llu\n",
                     kCallCensusKindNames[kv->second.first % kCallCensusKinds],
                     kv->first.c_str(),
                     static_cast<unsigned long long>(kv->second.second));
    std::fflush(stderr);
}

} // anonymous namespace

// Called from each instrumented partition's llvm.global_ctors constructor,
// pre-main, serial.
extern "C" void eco_call_census_register(const void* counts, const void* names,
                                         const void* kinds, uint64_t n) {
    auto& tables = callCensusTables();
    if (tables.empty()) std::atexit(callCensusDumpImpl);
    tables.push_back({static_cast<const uint64_t*>(counts),
                      static_cast<const char* const*>(names),
                      static_cast<const uint8_t*>(kinds), n});
}

// Manual/embedder hook: dump the call census now (idempotent).
extern "C" void eco_call_census_dump(void) { callCensusDumpImpl(); }

//===----------------------------------------------------------------------===//
// Kernel evaluator descriptors (plans/gc-root-registration-cost.md Phase 2, R6)
//
// Compiled code carries an `EvaluatorDesc` global beside every closure wrapper.
// A C++ kernel building a closure has only a function pointer, so one descriptor
// per (fn, stage_arity, result_kind) is interned here for the life of the
// process — never freed, never GC-visible (it is static data by construction,
// exactly like the emitted globals).
//
// `kinds` is 0 (all PK_Boxed): kernel evaluators take the `void*[]` convention.
// Every `sat[]` slot is null, so such a closure fails the arity fast-path guard
// closed and takes the same route it takes today. `sat` is sized
// `stage_arity + 1` so that a `sat[N]` load behind the `rem == N` guard is
// always in bounds.
//===----------------------------------------------------------------------===//

namespace {

struct KernelDescKey {
    Elm::EvalFunction fn;
    unsigned arity;
    unsigned char rk;
    bool operator==(const KernelDescKey& o) const {
        return fn == o.fn && arity == o.arity && rk == o.rk;
    }
};

struct KernelDescKeyHash {
    size_t operator()(const KernelDescKey& k) const {
        return std::hash<const void*>()(reinterpret_cast<const void*>(k.fn)) * 31
             + k.arity * 7 + k.rk;
    }
};

std::mutex g_kernel_desc_mutex;
std::unordered_map<KernelDescKey, Elm::EvaluatorDesc*, KernelDescKeyHash>
    g_kernel_descs;

}  // namespace

namespace Elm {

const EvaluatorDesc* ecoDescForKernelEvaluator(EvalFunction fn,
                                               unsigned stage_arity,
                                               unsigned char result_kind) {
    KernelDescKey key{fn, stage_arity, static_cast<unsigned char>(result_kind & 3)};
    std::lock_guard<std::mutex> lock(g_kernel_desc_mutex);
    auto it = g_kernel_descs.find(key);
    if (it != g_kernel_descs.end())
        return it->second;

    // sat[] has stage_arity + 1 slots only when the sat fast path can serve
    // this evaluator (stage_arity <= SAT_MAX_ARITY); otherwise it is empty
    // (the EcoBackend guard max_values <= SAT_MAX_ARITY makes it unreadable).
    size_t bytes = sizeof(EvaluatorDesc)
                 + (stage_arity <= SAT_MAX_ARITY
                        ? (static_cast<size_t>(stage_arity) + 1) * sizeof(void*)
                        : 0);
    auto* desc = static_cast<EvaluatorDesc*>(std::calloc(1, bytes));
    if (!desc) {
        std::fprintf(stderr, "[eco] FATAL: out of memory interning an "
                             "EvaluatorDesc for a kernel closure\n");
        std::abort();
    }
    desc->generic = fn;
    desc->kinds = 0;
    desc->stage_arity = static_cast<unsigned short>(stage_arity);
    desc->result_kind = static_cast<unsigned char>(result_kind & 3);
    // calloc already nulled every sat[] slot.
    g_kernel_descs.emplace(key, desc);
    return desc;
}

}  // namespace Elm

// Closure layout v2 (HEAP_078/HEAP_077): capacity `max` value slots followed by
// K = extWords(max, CLOSURE_HDR_SLOTS) extension kind words; header.size = max + K.
static inline size_t closureBytesFor(uint32_t slots, uint32_t max) {
    return sizeof(Closure)
         + (static_cast<size_t>(slots) + extWords(max, CLOSURE_HDR_SLOTS)) * sizeof(Unboxable);
}
static inline void closureArityCheck(uint32_t max, const char* who) {
    if (max > CLOSURE_MAX_ARITY) {
        std::fprintf(stderr, "[eco] FATAL: %s: closure arity %u exceeds %u\n",
                     who, max, CLOSURE_MAX_ARITY);
        std::abort();
    }
}
// Writes the K ext kind words (zeros included) at the object's tail: every
// allocation writes all K words (HEAP_077; zeroNewObject clears only the header).
static inline void writeClosureExtWords(Closure* c, uint32_t slots, uint32_t max,
                                        const uint64_t* ext) {
    const uint32_t K = extWords(max, CLOSURE_HDR_SLOTS);
    uint64_t* dst = reinterpret_cast<uint64_t*>(&c->values[slots]);
    for (uint32_t j = 0; j < K; ++j) dst[j] = ext ? ext[j] : 0;
}

extern "C" HPtr eco_alloc_closure_k(void* func_ptr, uint32_t num_captures,
                                    uint8_t result_kind) {
    assert(result_kind <= 3 && "eco_alloc_closure_k: result_kind out of range");
    closureArityCheck(num_captures, "eco_alloc_closure_k");
    closureStatsRecord(func_ptr, /*isExtend=*/false);
    // Size: Header + packed word + evaluator ptr + capacity slots + K ext words.
    // eco_alloc_with_roots derives header.size from the bytes (= n + K).
    size_t size = closureBytesFor(num_captures, num_captures);

    // No HPointer args to root (func_ptr is a code pointer, not a heap pointer;
    // captures are filled by the caller via closureCapture afterwards).
    void* obj = eco_alloc_with_roots(Tag_Closure, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->result_kind = result_kind;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(func_ptr);
    writeClosureExtWords(closure, num_captures, num_captures, nullptr);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure(void* func_ptr, uint32_t num_captures) {
    return eco_alloc_closure_k(func_ptr, num_captures, /*result_kind=*/0);
}

// Same allocation, but `fn` is a raw EVALUATOR FUNCTION pointer rather than an
// `EvaluatorDesc*` (plans/gc-root-registration-cost.md Phase 2). Compiled code
// always has a descriptor emitted beside its wrapper and uses the entries
// above; C++ that mints a closure from a plain function pointer — kernels via
// `alloc::allocClosureK`, and the allocator unit tests — goes through the
// interning registry instead.
extern "C" HPtr eco_alloc_closure_fn(void* fn, uint32_t num_captures,
                                     uint8_t result_kind) {
    const EvaluatorDesc* desc = ecoDescForKernelEvaluator(
        reinterpret_cast<EvalFunction>(fn), num_captures, result_kind);
    return eco_alloc_closure_k(const_cast<EvaluatorDesc*>(desc), num_captures,
                               result_kind);
}

// Zero-capture closure interning (HOF-elimination plan H4.2, HEAP_033).
//
// A zero-capture closure is immutable after construction: capture writes
// only happen for num_captured > 0 creates, self-capturing creates are
// excluded by the caller, and eco_pap_extend_l COPIES instead of mutating.
// So one permanent object per evaluator can serve every papCreate
// execution of that site. Reuses the string-literal interning machinery
// (thread-local table, heap-generation epoch sync for harness resets,
// rooted slots).
//
// `packed` is the header word the papCreate lowering computes
// (n_values | max_values<<11 | result_kind<<22 | unboxed<<24, HEAP_078, stored
// at byte offset 8 — must match EcoToLLVMClosures.cpp and Heap.hpp exactly);
// it is a per-site compile-time constant and a pure function of the
// wrapper `func_ptr`, so cache hits always agree with it. `arity` sizes
// the value-slot area identically to eco_alloc_closure_k's capacity.
extern "C" HPtr eco_intern_closure0(void* func_ptr, uint32_t arity,
                                    uint64_t packed) {
    // HEAP_033: only closures whose kinds are all inline are interned (the
    // codegen never interns wider), so K = 0 and the size is unchanged.
    assert(arity <= CLOSURE_HDR_SLOTS && "eco_intern_closure0: arity > CLOSURE_HDR_SLOTS");
    return internLiteral(func_ptr, [&]() -> HPtr {
        closureStatsRecord(func_ptr, /*isExtend=*/false);
        size_t size = sizeof(Header) + 8 + sizeof(const EvaluatorDesc*)
                    + static_cast<size_t>(arity) * sizeof(Unboxable);
        void* obj = allocInternObject(Tag_Closure, size);
        if (!obj) return HPtr::fromBits(0);
        Closure* closure = static_cast<Closure*>(obj);
        std::memcpy(reinterpret_cast<char*>(obj) + 8, &packed,
                    sizeof(uint64_t));
        closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(func_ptr);
        // `packed` sets max_values == arity, but the closure scans
        // (OldGenSpace::scanChildren / NurserySpace::scanObject, Tag_Closure)
        // iterate `n_values` slots (0 here): this interned singleton never
        // writes its value slots (it is immutable; eco_pap_extend_l COPIES for
        // application). allocatePermanent does NOT zero the old-gen body; the
        // memset keeps the body defined for debug walkers and permanent-space
        // copies.
        std::memset(closure->values, 0,
                    static_cast<size_t>(arity) * sizeof(Unboxable));
        return ptrToHPointer(obj);
    });
}

extern "C" HPtr eco_alloc_int(int64_t value) {
    void* obj = eco_alloc_with_roots(Tag_Int, sizeof(ElmInt), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    static_cast<ElmInt*>(obj)->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_float(double value) {
    void* obj = eco_alloc_with_roots(Tag_Float, sizeof(ElmFloat), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    static_cast<ElmFloat*>(obj)->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char(uint32_t value) {
    void* obj = eco_alloc_with_roots(Tag_Char, sizeof(ElmChar), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    static_cast<ElmChar*>(obj)->value = static_cast<u16>(value);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_allocate(uint64_t size, uint32_t tag) {
    // Generic allocation with specified size and tag. Used by the JIT for
    // sizes/tags not covered by the per-type entry points; rare.
    void* obj = eco_alloc_with_roots(tag, size, nullptr, 0, 0);
    return ptrToHPointer(obj);
}

//===----------------------------------------------------------------------===//
// Fast/Slow Allocation Split
//
// Fast variants: bump-pointer only, no GC trigger, return 0/nullptr on failure.
// Slow variants: may trigger GC, always succeed or abort.
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_alloc_custom_fast(uint32_t ctor_id, uint32_t field_count) {
    // Single-representation backstop (HEAP_044): nullary customs are embedded
    // null-cons constants; post-CGEN_079 the compiler never emits a 0-field
    // allocation, so reaching here with one is a codegen bug.
    assert(field_count > 0 &&
           "0-field custom allocation forbidden (HEAP_044): embed a null-cons constant");
    if (field_count > CUSTOM_MAX_FIELDS) ecoFatalWideObject("eco_alloc_custom_fast", field_count);
    size_t size = wideByteSize(Tag_Custom, field_count);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    // Init header (size = n, unboxed = K, ext words zeroed) + ctor
    initWideHeader(getHeader(obj), Tag_Custom, field_count);
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_custom_slow(uint32_t ctor_id, uint32_t field_count) {
    // Single-representation backstop (HEAP_044) — see eco_alloc_custom_fast.
    assert(field_count > 0 &&
           "0-field custom allocation forbidden (HEAP_044): embed a null-cons constant");
    if (field_count > CUSTOM_MAX_FIELDS) ecoFatalWideObject("eco_alloc_custom_slow", field_count);
    size_t size = wideByteSize(Tag_Custom, field_count);
    void* obj = Allocator::instance().allocateSlow(size, Tag_Custom);   // initHeaderForTag: n, K, ext zeroed
    if (!obj) return HPtr::fromBits(0);
    assert(getHeader(obj)->size == field_count);

    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_cons_fast(uint64_t head, HPtr tail, uint32_t head_kind) {
    size_t size = sizeof(Cons);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Cons;
    hdr->size = static_cast<u32>(size);
    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = static_cast<i64>(head);
    uint64_t tail_bits = tail.toBits();
    HPointer tail_hp;
    memcpy(&tail_hp, &tail_bits, sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_cons_slow(uint64_t head, HPtr tail, uint32_t head_kind) {
    size_t size = sizeof(Cons);

    // Root head/tail across allocateSlow. Caller's RS4GC statepoint covers
    // these args at the call site, but our by-value parameter copies are
    // local to this frame and the caller's stackmap doesn't see them, so
    // a GC during allocateSlow would leave them pointing at the pre-swap
    // location. Mask bit i set iff slot i is an HPointer.
    uint64_t roots[2] = { head, tail.toBits() };
    uint64_t mask = (head_kind != 0) ? 0x2 : 0x3;

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 2, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Cons);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    // Read post-GC values back from roots[].
    cons->head.i = static_cast<i64>(roots[0]);
    HPointer tail_hp;
    memcpy(&tail_hp, &roots[1], sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple2_fast(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple2);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple2;
    hdr->size = static_cast<u32>(size);
    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple2_slow(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple2);

    // Root HPointer slots across allocateSlow (see eco_alloc_cons_slow above
    // for the full rationale).
    uint64_t roots[2] = { a, b };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 2);

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 2, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Tuple2);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple3_fast(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple3);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple3;
    hdr->size = static_cast<u32>(size);
    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    tup->c.i = static_cast<i64>(c);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple3_slow(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple3);

    // Root HPointer slots across allocateSlow (see eco_alloc_cons_slow above
    // for the full rationale).
    uint64_t roots[3] = { a, b, c };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 3);

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 3, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Tuple3);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);
    tup->c.i = static_cast<i64>(roots[2]);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_record_fast(uint32_t field_count, uint64_t unboxed_bitmap) {
    if (field_count > RECORD_MAX_FIELDS) ecoFatalWideObject("eco_alloc_record_fast", field_count);
    size_t size = wideByteSize(Tag_Record, field_count);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    initWideHeader(getHeader(obj), Tag_Record, field_count);   // size = n, unboxed = K, ext zeroed
    Record* rec = static_cast<Record*>(obj);
    rec->unboxed = unboxed_bitmap;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_record_slow(uint32_t field_count, uint64_t unboxed_bitmap) {
    if (field_count > RECORD_MAX_FIELDS) ecoFatalWideObject("eco_alloc_record_slow", field_count);
    size_t size = wideByteSize(Tag_Record, field_count);
    void* obj = Allocator::instance().allocateSlow(size, Tag_Record);   // initHeaderForTag: n, K, ext zeroed
    if (!obj) return HPtr::fromBits(0);

    Record* rec = static_cast<Record*>(obj);
    assert(rec->header.size == field_count);
    rec->unboxed = unboxed_bitmap;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_string_fast(uint32_t length) {
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    zeroNewObject(hdr, size);
    hdr->tag = Tag_String;
    hdr->size = length;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_string_slow(uint32_t length) {
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;
    void* obj = Allocator::instance().allocateSlow(size, Tag_String);
    if (!obj) return HPtr::fromBits(0);

    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure_fast(void* func_ptr, uint32_t num_captures) {
    closureArityCheck(num_captures, "eco_alloc_closure_fast");
    size_t size = closureBytesFor(num_captures, num_captures);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);
    closureStatsRecord(func_ptr, /*isExtend=*/false);

    Header* hdr = getHeader(obj);
    zeroNewObject(hdr, size);
    hdr->tag = Tag_Closure;
    hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);   // n + K
    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->result_kind = 0;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(func_ptr);
    writeClosureExtWords(closure, num_captures, num_captures, nullptr);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure_slow(void* func_ptr, uint32_t num_captures) {
    closureArityCheck(num_captures, "eco_alloc_closure_slow");
    size_t size = closureBytesFor(num_captures, num_captures);
    void* obj = Allocator::instance().allocateSlow(size, Tag_Closure);
    if (!obj) return HPtr::fromBits(0);
    closureStatsRecord(func_ptr, /*isExtend=*/false);

    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->result_kind = 0;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(func_ptr);
    writeClosureExtWords(closure, num_captures, num_captures, nullptr);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_int_fast(int64_t value) {
    void* obj = Allocator::instance().allocateFast(sizeof(ElmInt));
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Int;
    hdr->size = static_cast<u32>(sizeof(ElmInt));
    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_int_slow(int64_t value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmInt), Tag_Int);
    if (!obj) return HPtr::fromBits(0);

    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_float_fast(double value) {
    void* obj = Allocator::instance().allocateFast(sizeof(ElmFloat));
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Float;
    hdr->size = static_cast<u32>(sizeof(ElmFloat));
    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_float_slow(double value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmFloat), Tag_Float);
    if (!obj) return HPtr::fromBits(0);

    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char_fast(uint32_t value) {
    void* obj = Allocator::instance().allocateFast(sizeof(ElmChar));
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Char;
    hdr->size = static_cast<u32>(sizeof(ElmChar));
    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char_slow(uint32_t value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmChar), Tag_Char);
    if (!obj) return HPtr::fromBits(0);

    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);

    return ptrToHPointer(obj);
}

extern "C" void* eco_gc_alloc_region_fast(size_t total) {
    return Allocator::instance().allocateFast(total);
}

extern "C" void* eco_gc_alloc_region_slow(size_t total) {
    return Allocator::instance().allocateRegionSlow(total);
}

extern "C" void eco_alloc_closure_group_l(
    uint64_t numSiblings,
    const void* const* evaluators,     // EvaluatorDesc* per sibling
    const uint32_t* arities,           // max_values per sibling (<= CLOSURE_MAX_ARITY)
    const uint32_t* numCaptured,       // n_values per sibling
    const uint64_t* hdrKinds,          // per sibling: inline 40-bit kind field (params 0..19)
    const uint64_t* extKinds,          // concatenated ext words of all siblings
    const uint32_t* extOffsets,        // numSiblings+1 prefix offsets into extKinds
    const uint8_t*  resultKinds,
    const uint32_t* captureOffsets,    // numSiblings+1
    const uint64_t* captures,
    const uint64_t* crossEdges,        // (producer, consumer, slot) triples
    uint64_t numCrossEdges,
    uint64_t* outClosures) {
    // Compute total size: sum of per-sibling closure sizes, all naturally
    // 8-byte aligned. Closure capacity uses `arities[i]` (max_values) so the
    // allocated storage has room for future PAP-extend slots too, followed by
    // K_i = extWords(arities[i], CLOSURE_HDR_SLOTS) ext kind words (HEAP_078).
    size_t totalBytes = 0;
    for (uint64_t i = 0; i < numSiblings; ++i) {
        closureArityCheck(arities[i], "eco_alloc_closure_group_l");
        assert(extOffsets[i + 1] - extOffsets[i] == extWords(arities[i], CLOSURE_HDR_SLOTS) &&
               "eco_alloc_closure_group_l: ext word count != extWords(arity)");
        totalBytes += closureBytesFor(arities[i], arities[i]);
    }

    // Reserve one contiguous region so every sibling lives in a single
    // generation (nursery or pinned large-obj). Any GC triggered by the
    // slow path happens BEFORE any sibling is written, so input
    // `captures[]` raw HPointers passed in must have been kept alive by
    // the caller's GC-root frame up to this call.
    void* region = eco_gc_alloc_region_fast(totalBytes);
    if (!region) {
        region = eco_gc_alloc_region_slow(totalBytes);
    }

    // First pass: initialize each sibling's header and publish HPointer.
    // Producers need each sibling's HPointer to be known before we wire
    // up cross-edges in pass two.
    char* cursor = static_cast<char*>(region);
    for (uint64_t i = 0; i < numSiblings; ++i) {
        const uint32_t arity = arities[i];
        const uint32_t nc = numCaptured[i];
        const size_t perSibling = closureBytesFor(arity, arity);

        void* obj = cursor;
        Header* hdr = getHeader(obj);
        zeroNewObject(hdr, perSibling);
        hdr->tag = Tag_Closure;
        hdr->size = static_cast<u32>(
            (perSibling - sizeof(Closure)) / sizeof(Unboxable));   // arity + K

        Closure* closure = static_cast<Closure*>(obj);
        closure->n_values = nc;
        closure->max_values = arity;
        // result_kind matches the wrapper's real C-ABI return type so the
        // closure-invocation paths can cast `evaluator` correctly without
        // per-call-site plumbing.
        closure->result_kind = resultKinds[i] & 0x3;
        closure->unboxed = hdrKinds[i];
        closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(evaluators[i]);
        writeClosureExtWords(closure, arity, arity, extKinds + extOffsets[i]);
        closureStatsRecord(evaluators[i], /*isExtend=*/false);

        // Non-sibling captures: pre-ordered into slots [0 .. capture_counts[i]).
        const uint32_t capStart = captureOffsets[i];
        const uint32_t capEnd = captureOffsets[i + 1];
        for (uint32_t k = capStart, slot = 0; k < capEnd; ++k, ++slot) {
            closure->values[slot].i = static_cast<i64>(captures[k]);
        }

        outClosures[i] = ptrToHPointer(obj).toBits();
        cursor += perSibling;
    }

    // Second pass: wire cross-edges. All siblings share a generation so a
    // plain i64 store is correct — no write barrier needed.
    for (uint64_t e = 0; e < numCrossEdges; ++e) {
        const uint64_t producer = crossEdges[3 * e + 0];
        const uint64_t consumer = crossEdges[3 * e + 1];
        const uint64_t slot     = crossEdges[3 * e + 2];

        Closure* consumerClosure = static_cast<Closure*>(
            hpointerToPtr(outClosures[consumer]));
        consumerClosure->values[slot].i = static_cast<i64>(outClosures[producer]);
    }
}

//===----------------------------------------------------------------------===//
// Init-at-pointer Functions (for group allocation)
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_init_int_at(void* obj, int64_t value) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Int;
    hdr->size = static_cast<u32>(sizeof(ElmInt));
    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_float_at(void* obj, double value) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Float;
    hdr->size = static_cast<u32>(sizeof(ElmFloat));
    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_char_at(void* obj, uint32_t value) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Char;
    hdr->size = static_cast<u32>(sizeof(ElmChar));
    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_cons_at(void* obj, uint64_t head, HPtr tail, uint32_t head_kind) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Cons;
    hdr->size = static_cast<u32>(sizeof(Cons));
    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = static_cast<i64>(head);
    uint64_t tail_bits = tail.toBits();
    HPointer tail_hp;
    memcpy(&tail_hp, &tail_bits, sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_tuple2_at(void* obj, uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple2;
    hdr->size = static_cast<u32>(sizeof(Tuple2));
    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_tuple3_at(void* obj, uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple3;
    hdr->size = static_cast<u32>(sizeof(Tuple3));
    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    tup->c.i = static_cast<i64>(c);
    return ptrToHPointer(obj);
}

// Precondition (eco_init_*_at): the codegen group region reserved
// wideByteSize(tag, field_count) bytes at obj (K = 0 while the verifier caps hold).
extern "C" HPtr eco_init_record_at(void* obj, uint32_t field_count, uint64_t unboxed_bitmap) {
    initWideHeader(getHeader(obj), Tag_Record, field_count);
    Record* rec = static_cast<Record*>(obj);
    rec->unboxed = unboxed_bitmap;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_custom_at(void* obj, uint32_t ctor_id, uint32_t field_count) {
    initWideHeader(getHeader(obj), Tag_Custom, field_count);
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_string_at(void* obj, uint32_t length) {
    Header* hdr = getHeader(obj);
    zeroNewObject(hdr, (sizeof(Header) + length * sizeof(u16) + 7) & ~size_t{7});
    hdr->tag = Tag_String;
    hdr->size = length;
    return ptrToHPointer(obj);
}

//===----------------------------------------------------------------------===//
// Stale-pointer validator (called from the EcoBoxedStoreVerify-inserted
// barrier in front of compiled-Elm direct heap stores)
//===----------------------------------------------------------------------===//

extern "C" void eco_validate_nursery_hptr_bits(uint64_t bits) {
    alloc::validateNurseryHPtrBits(bits);
}

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

extern "C" void eco_store_field(HPtr obj_hptr, uint32_t index, HPtr value) {
    // Always-on per-write stale-pointer tripwire. Catches stale `value`
    // writes at the moment they happen, producing a backtrace showing the
    // compiled function. Skips null/zero and embedded constants. See
    // HeapHelpers.hpp `validateNurseryHPtr` for the rationale.
    alloc::validateNurseryHPtrBits(value.toBits());
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    // Get the header to determine object type
    Header* header = static_cast<Header*>(obj);

    // In JIT mode, pointers are full 64-bit addresses.
    // Store the full value directly in the Unboxable union's i field.
    // This preserves all 64 bits for proper pointer traversal.

    uint64_t value_bits = value.toBits();
    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].i = static_cast<i64>(value_bits);
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            Unboxable* field = (index == 0) ? &tuple->a : &tuple->b;
            field->i = static_cast<i64>(value_bits);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            Unboxable* field = (index == 0) ? &tuple->a : (index == 1) ? &tuple->b : &tuple->c;
            field->i = static_cast<i64>(value_bits);
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            if (index == 0) {
                cons->head.i = static_cast<i64>(value_bits);
            } else {
                // Tail is HPointer, not Unboxable - store as raw bits
                // Note: This may cause issues with 64-bit pointers in JIT mode
                cons->tail = hpFromBits(value_bits);
            }
            break;
        }
        case Tag_Closure: {
            // eco_store_field* is NOT a legal way to fill closure captures.
            // The collector's closure scan bounds on n_values, and this path
            // writes a value slot without touching it — so a capture stored
            // here is never traced and is reclaimed. Raising n_values to
            // index+1 does NOT fix it either: a store at index 3 with slots
            // 0..2 unwritten would then have the scan trace three
            // uninitialised slots.
            //
            // Use closureCapture (HeapHelpers.hpp), which appends at
            // n_values and increments, making ascending order structural.
            // There are no production callers of this arm: the compiler
            // emits eco_store_field* only for CustomConstructOp, and no
            // kernel calls it on a closure.
            assert(false && "eco_store_field on a Closure: use closureCapture");
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = static_cast<i64>(value_bits);
            break;
        }
        default:
            // Unknown object type
            fprintf(stderr, "eco_store_field: unknown object type %d\n", header->tag);
            break;
    }
}

extern "C" void eco_store_field_i64(HPtr obj_hptr, uint32_t index, int64_t value) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].i = value;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            if (index == 0) tuple->a.i = value;
            else tuple->b.i = value;
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            if (index == 0) tuple->a.i = value;
            else if (index == 1) tuple->b.i = value;
            else tuple->c.i = value;
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            if (index == 0) cons->head.i = value;
            break;
        }
        case Tag_Closure: {
            // See eco_store_field's Tag_Closure arm: use closureCapture.
            assert(false && "eco_store_field_i64 on a Closure: use closureCapture");
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = value;
            break;
        }
        default:
            fprintf(stderr, "eco_store_field_i64: unknown object type %d\n", header->tag);
            break;
    }
}

extern "C" void eco_store_field_f64(HPtr obj_hptr, uint32_t index, double value) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].f = value;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            if (index == 0) tuple->a.f = value;
            else tuple->b.f = value;
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            if (index == 0) tuple->a.f = value;
            else if (index == 1) tuple->b.f = value;
            else tuple->c.f = value;
            break;
        }
        case Tag_Closure: {
            // See eco_store_field's Tag_Closure arm: use closureCapture.
            assert(false && "eco_store_field_f64 on a Closure: use closureCapture");
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].f = value;
            break;
        }
        default:
            fprintf(stderr, "eco_store_field_f64: unknown object type %d\n", header->tag);
            break;
    }
}

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

namespace {

// Phase C shim support: all-`PK_Boxed`-args `EvalParamLayout`s indexed by
// `(result_kind, num_params)`. The legacy `eco_apply_closure` entry — called
// by C++ effect-manager kernels and the platform runtime with
// HPointer-encoded args — looks up the right row from the closure header's
// `result_kind` field, so it forwards through `eco_apply_closure_typed` with
// a layout whose `result_kind` matches the closure's wrapper return ABI.
// Without this, primitive-return wrappers would be mis-cast as
// `void *(void *[])` on the dispatch path.
//
// n <= 64: a static table of `EvalParamLayoutN<64>` (4 kinds x 65 entries).
// n > 64 (up to CLOSURE_MAX_ARITY): an interned, mutex-guarded on-demand cache
// keyed (K << 16) | n of zeroed `4 + n`-byte layouts (B19: no clamp).
constexpr unsigned kStaticBoxedLayouts = 64;
constexpr unsigned kNumResultKinds = 4;  // PK_Boxed, PK_Int, PK_Float, PK_Char

constexpr auto buildAllBoxedLayouts() {
    struct Holder {
        EvalParamLayoutN<kStaticBoxedLayouts> data[kNumResultKinds][kStaticBoxedLayouts + 1];
    };
    Holder h{};
    for (unsigned k = 0; k < kNumResultKinds; ++k) {
        for (unsigned n = 0; n <= kStaticBoxedLayouts; ++n) {
            h.data[k][n].num_params = static_cast<unsigned short>(n);
            h.data[k][n].result_kind = static_cast<unsigned char>(k);
            // kinds[] are PK_Boxed (0) from value-initialisation.
        }
    }
    return h;
}
constexpr auto kAllBoxedLayoutsHolder = buildAllBoxedLayouts();

std::mutex g_wide_boxed_layout_mutex;
std::unordered_map<uint32_t, std::unique_ptr<unsigned char[]>> g_wide_boxed_layouts;

} // anonymous namespace

namespace Elm {
// Pick the layout whose `result_kind` byte matches `K`. The legacy entry
// `eco_apply_closure` reads K off the closure header so primitive-return
// wrappers are dispatched correctly even for callers that don't carry K.
const EvalParamLayout* getAllBoxedLayout(unsigned n, uint8_t K) {
    assert(n <= CLOSURE_MAX_ARITY && "getAllBoxedLayout: n exceeds CLOSURE_MAX_ARITY");
    if (K >= kNumResultKinds) K = 0;
    if (n <= kStaticBoxedLayouts)
        return asLayout(&kAllBoxedLayoutsHolder.data[K][n]);
    const uint32_t key = (static_cast<uint32_t>(K) << 16) | n;
    std::lock_guard<std::mutex> lock(g_wide_boxed_layout_mutex);
    auto& slot = g_wide_boxed_layouts[key];
    if (!slot) {
        slot.reset(new unsigned char[4 + n]());   // zeroed: every kind PK_Boxed
        auto* l = reinterpret_cast<EvalParamLayout*>(slot.get());
        l->num_params = static_cast<unsigned short>(n);
        l->result_kind = K;
    }
    return reinterpret_cast<const EvalParamLayout*>(slot.get());
}
} // namespace Elm

// Phase C: legacy boxed-args entry point. C++ callers that construct a
// `uint64_t* args` of HPointer-encoded values (effect-manager workers,
// `Scheduler::callClosureN`, `PlatformRuntime`) reach
// `eco_apply_closure_typed` through here. The layout's `result_kind`
// byte is filled from `closure->result_kind` so primitive-return
// wrappers route via the correct `invokeSaturatedTyped` cast. Boxed-args
// callers that target a primitive-result closure get a freshly boxed
// `ElmInt`/`ElmFloat`/`ElmChar` back — semantics-preserving for legacy
// callers that always expected an `HPtr`.
extern "C" HPtr eco_apply_closure(HPtr closure_hptr, uint64_t* args, uint32_t num_args) {
    void* closure_ptr = hpointerToPtr(closure_hptr.toBits());
    uint8_t K = closure_ptr ? static_cast<Closure*>(closure_ptr)->result_kind : 0;
    const EvalParamLayout* layout =
        (num_args == 0) ? nullptr : getAllBoxedLayout(num_args, K);
    return eco_apply_closure_typed(closure_hptr,
                                   reinterpret_cast<int64_t*>(args),
                                   num_args, layout);
}

namespace {

// Forward declarations for helpers defined further down. `eco_apply_closure_eval`
// needs to call `invokeSaturatedTyped`, which itself uses
// `spliceArgsForSaturatedCall`; both are also reused by
// `eco_closure_call_saturated`.
inline Closure* spliceArgsForSaturatedCall(uint64_t& closure_bits_inout,
                                            uint64_t* new_args,
                                            uint32_t num_newargs,
                                            const EvalParamLayout* layout,
                                            void** combined_args,
                                            uint32_t& max_values_out,
                                            ClosureKinds& kinds_out);

void invokeSaturatedTyped(uint64_t closure_bits,
                          int64_t* typed_args,
                          uint32_t num_args,
                          const EvalParamLayout* args_layout,
                          uint8_t K,
                          uint8_t desired_kind,
                          void* result_slot);

// Extract a primitive payload from an HPointer-encoded boxed value (an
// ElmInt / ElmFloat / ElmChar) and store it into `result_slot` per
// `desired_kind`. Used by the boxed-evaluator path of
// `eco_apply_closure_eval` when the caller wants a typed primitive.
void deliverPrimitiveFromBoxed(HPtr boxed, uint8_t desired_kind, void* result_slot) {
    void* obj = hpointerToPtr(boxed.toBits());
    assert(obj && "deliverPrimitiveFromBoxed: cannot un-box null/embedded HPointer");
    const char* base = static_cast<const char*>(obj) + sizeof(Header);
    switch (desired_kind) {
        case 1: { // PK_Int
            int64_t v;
            memcpy(&v, base, sizeof(v));
            *static_cast<int64_t*>(result_slot) = v;
            break;
        }
        case 2: { // PK_Float
            double f;
            memcpy(&f, base, sizeof(f));
            *static_cast<double*>(result_slot) = f;
            break;
        }
        case 3: { // PK_Char
            uint16_t c;
            memcpy(&c, base, sizeof(c));
            *static_cast<uint16_t*>(result_slot) = c;
            break;
        }
        default:
            assert(false && "deliverPrimitiveFromBoxed: unreachable desired_kind");
            __builtin_unreachable();
    }
}

} // anonymous namespace

// NOTE (plans/gc-root-registration-cost.md Phase 4, second correction):
// no LOWERING emits a call to this — the decline census records zero events
// and `getOrCreateApplySegmentationUnknown` has been deleted — but
// test/allocator/EcoApplyClosureTypedTest.cpp exercises it directly, so the
// definition stays. Only the dead codegen-side wiring was removed.
// Phase D Part 2: typed-args entry point for segmentation-unknown apply.
//
// Takes a single typed `int64_t*` buffer plus an `EvalParamLayout` (instead
// of the previous dual buffer + bitmap form). The runtime decides at the
// closure header whether the call is under- or saturated, and routes:
//
//   under-saturated  → eco_pap_extend_l (with the caller's layout)
//   saturated/over   → eco_apply_closure_typed (which centralises any
//                      necessary primitive re-boxing for the saturated path)
//
// `args_layout` may be null only for the all-boxed fallback case; every
// emitter today passes a non-null layout.
extern "C" HPtr eco_apply_segmentation_unknown(HPtr closure_hptr,
                                               int64_t* typed_args,
                                               uint32_t num_args,
                                               const EvalParamLayout* args_layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) return HPtr::fromBits(0);

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;
    uint32_t max_values = closure->max_values;

    // DIAG: Check for corrupted closure header
    if (max_values == 0 || max_values > CLOSURE_MAX_ARITY) {
        uint64_t packed;
        memcpy(&packed, reinterpret_cast<char*>(closure_ptr) + 8, sizeof(packed));
        // Check if the closure has been forwarded (GC moved it)
        fprintf(stderr, "DIAG: eco_apply_segmentation_unknown bad closure: hptr=0x%lx ptr=%p tag=%u n_values=%u max_values=%u num_args=%u packed=0x%lx\n",
                closure_bits, closure_ptr, closure->header.tag, n_values, max_values, num_args, packed);
        fprintf(stderr, "  header: color=%u pin=%u age=%u unboxed=%u size=%u\n",
                closure->header.color, closure->header.pin,
                closure->header.age, closure->header.unboxed, closure->header.size);
        fprintf(stderr, "  evaluator=%p\n", (void*)closure->evaluator);
        fflush(stderr);
        // Abort early so we get the full output before the assertion
        abort();
    }
    uint32_t remaining = max_values - n_values;

    // Root closure_bits across the inner call.
    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    HPtr result;

    if (num_args < remaining) {
        // Under-saturated: hand the typed args and their layout to
        // eco_pap_extend_l, which roots them by caller kind and converts
        // each one to its slot kind.
        result = eco_pap_extend_l(HPtr::fromBits(closure_bits),
                                  reinterpret_cast<uint64_t*>(typed_args),
                                  num_args, args_layout);
    } else {
        // Saturated/over-saturated: forward to the typed-apply entry point,
        // which reaches eco_apply_closure_eval; the `gen`+`sat` are recorded
        // there.
        // which centralises any required primitive re-boxing before invoking
        // the evaluator. No parallel boxed buffer is needed.
        result = eco_apply_closure_typed(HPtr::fromBits(closure_bits),
                                         typed_args, num_args, args_layout);
    }

    ecoRootRelease(saved_range);
    return result;
}
// Phase E: canonical generic-apply entry point with typed result delivery.
//
// Args interpretation is fully typed per REP_ABI_001:
//   - layout->kinds[i] == 0 (PK_Boxed)  → typed_args[i] is an HPointer.
//   - layout->kinds[i] == 1 (PK_Int)    → typed_args[i] is a raw i64.
//   - layout->kinds[i] == 2 (PK_Float)  → typed_args[i] is f64 bits in i64.
//   - layout->kinds[i] == 3 (PK_Char)   → typed_args[i] is i16 zext in i64.
// `args_layout` may be null only when num_args == 0.
//
// `args_layout->result_kind` (`K`) is the closure evaluator's real C-ABI
// return kind. The saturated branch reinterprets `closure->evaluator`
// based on `K`. `desired_kind` is what the caller wants delivered into
// `result_slot`; the helper boxes/unboxes across the K↔desired_kind
// boundary as needed.
//
// Saturation cases:
//   - num_args == 0        → no-op apply, return closure unchanged
//                            (`desired_kind` must be PK_Boxed).
//   - num_args <  remaining → eco_pap_extend_l (always returns a closure HPtr;
//                              `desired_kind` must be PK_Boxed).
//   - num_args == remaining → call evaluator (per K), then deliver result.
//   - num_args >  remaining → saturate this stage, recurse with trailing args
//                              and a PK_Boxed sub-layout.
extern "C" void eco_apply_closure_eval(HPtr closure_hptr,
                                       int64_t* typed_args,
                                       uint32_t num_args,
                                       const EvalParamLayout* args_layout,
                                       void* result_slot,
                                       uint8_t desired_kind) {
    assert(desired_kind <= 3 && "eco_apply_closure_eval: desired_kind out of range");

    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) {
        // Null/embedded closure: deliver zero in the desired slot so the
        // caller doesn't read uninitialised storage.
        switch (desired_kind) {
            case 0: *static_cast<HPtr*>(result_slot) = HPtr::fromBits(0); break;
            case 1: *static_cast<int64_t*>(result_slot) = 0; break;
            case 2: *static_cast<double*>(result_slot) = 0.0; break;
            case 3: *static_cast<uint16_t*>(result_slot) = 0; break;
        }
        return;
    }

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;
    uint32_t max_values = closure->max_values;
    assert(max_values <= CLOSURE_MAX_ARITY && "max_values exceeds the 11-bit field cap");
    uint32_t remaining = max_values - n_values;

    // Phase C/D: K is read from the closure header, not the layout. The
    // layout's `result_kind` byte (if present) is a redundant hint and
    // is allowed to drift — the frontend can only derive layout K from
    // the static call-site type, which loses precision for staged-curried
    // closures (e.g. `Mono.stageReturnType` peels one MFunction layer,
    // returning the inner MFunction for a flat single-stage closure
    // whose actual return type lives one more level in). The closure
    // header is the authoritative source of truth so C++-kernel callers
    // (which don't see the layout) still get correct dispatch via
    // `eco_apply_closure(legacy)` → `eco_apply_closure_typed` → here.
    uint8_t K = closure->result_kind;
    assert(K <= 3 && "eco_apply_closure_eval: closure result_kind out of range");

    if (num_args == 0) {
        // No-op apply: closure is unchanged. By construction the caller
        // wants a boxed result here (a no-op apply on a closure is itself
        // a closure HPtr).
        assert(desired_kind == 0 &&
               "eco_apply_closure_eval: no-op apply requires PK_Boxed desired_kind");
        *static_cast<HPtr*>(result_slot) = closure_hptr;
        return;
    }

    // Root `closure_bits` and the typed args buffer's HPointer slots
    // across the inner runtime call. Mask comes from the layout's kinds
    // so primitive slots are correctly skipped by the GC scan.
    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    if (num_args > 0 && args_layout) {
        pushRootsByKinds(reinterpret_cast<uint64_t*>(typed_args), num_args,
                         [&](uint32_t i) { return args_layout->kinds[i]; });
    }

#if ECO_HEAP_VALIDATE
    // Stale-arg tripwire: every PK_Boxed slot must resolve to an allocated
    // region. Catches callers that hold an HPointer by-value across an
    // earlier `eco_alloc_*` GC point. Primitive slots carry raw bits, not
    // HPointers, so they are skipped via `args_layout`.
    for (uint32_t dbg_i = 0; dbg_i < num_args; ++dbg_i) {
        uint8_t kind = args_layout ? args_layout->kinds[dbg_i] : 0;
        if (kind != 0) continue;
        uint64_t raw = static_cast<uint64_t>(typed_args[dbg_i]);
        HPointer hp;
        memcpy(&hp, &raw, sizeof(hp));
        if (hp.ptr_ind == 0 && hp.ptr != 0) {
            hpointerToPtr(raw);
        }
    }
#endif

    if (num_args < remaining) {
        // Under-saturated: extend with newargs. Always produces a closure
        // HPtr regardless of `K`, so the caller must want PK_Boxed.
        // (No dispatch here — this grows a PAP via eco_pap_extend_l, an
        //  allocation the closure census counts as an `extend`.)
        assert(desired_kind == 0 &&
               "eco_apply_closure_eval: under-saturated apply requires PK_Boxed "
               "desired_kind (well-typed IR cannot have a primitive result on "
               "an under-saturated apply)");
        HPtr extended = eco_pap_extend_l(HPtr::fromBits(closure_bits),
                                         reinterpret_cast<uint64_t*>(typed_args),
                                         num_args, args_layout);
        *static_cast<HPtr*>(result_slot) = extended;
        ecoRootRelease(saved_range);
        return;
    }

    if (num_args == remaining) {
        // Generic funnel reached a saturated call — tag the subset; the actual
        // `sat` is recorded inside invokeSaturatedTyped below.
        dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                            DispatchKind::Generic);
        // Exactly saturated. Dispatch on the evaluator's real C ABI (`K`).
        // `invokeSaturatedTyped` casts `closure->evaluator` to the matching
        // primitive-return signature and converts the result to
        // `desired_kind` (boxing if the caller wants a boxed result).
        invokeSaturatedTyped(closure_bits, typed_args, num_args, args_layout,
                             K, desired_kind, result_slot);
        ecoRootRelease(saved_range);
        return;
    }

    // Generic funnel reached an over-saturated call — tag this stage's subset;
    // the actual `sat` is recorded inside eco_closure_call_saturated below, and
    // the recursive trailing stage records its own gen/sat.
    dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                        DispatchKind::Generic);
    // Over-saturated: saturate this stage (always boxed result intermediate,
    // since under-saturation produces a closure HPtr), then apply the
    // remainder to the result closure with a PK_Boxed sub-layout. If the
    // caller wants a primitive result, we recurse asking for that primitive
    // on the final saturated apply.
    HPtr intermediate = eco_closure_call_saturated(
        HPtr::fromBits(closure_bits),
        reinterpret_cast<uint64_t*>(typed_args),
        remaining, args_layout);

    uint32_t trailing = num_args - remaining;
    // EvalParamLayout = {u16 num_params, u8 result_kind, u8 pad, u8 kinds[]}.
    alignas(EvalParamLayout) unsigned char sub_inline[4 + 64] = {};
    std::unique_ptr<unsigned char[]> sub_heap;
    unsigned char* sub_buf = sub_inline;
    if (trailing > 64) {
        sub_heap.reset(new unsigned char[4 + trailing]());
        sub_buf = sub_heap.get();
    }
    EvalParamLayout* sub = reinterpret_cast<EvalParamLayout*>(sub_buf);
    sub->num_params = static_cast<unsigned short>(trailing);
    // Phase C: the recursive call reads K from `intermediate->result_kind`,
    // not from the sub-layout. Mirror it on the layout so the
    // layout-vs-closure cross-check assertion holds.
    {
        void* inter_ptr = hpointerToPtr(intermediate.toBits());
        sub->result_kind = inter_ptr
            ? static_cast<Closure*>(inter_ptr)->result_kind
            : 0;
    }
    if (args_layout != nullptr) {
        memcpy(sub->kinds, args_layout->kinds + remaining, trailing);
    }
    eco_apply_closure_eval(intermediate, typed_args + remaining,
                           trailing, sub, result_slot, desired_kind);

    ecoRootRelease(saved_range);
}

// Phase E: legacy boxed-result entry point, now a thin shim around
// `eco_apply_closure_eval` with `desired_kind = PK_Boxed`. Every existing
// caller that wants an HPtr result reaches the canonical helper through
// here. For primitive-result closures the inner helper allocates the
// matching ElmInt/ElmFloat/ElmChar to satisfy the boxed return.
extern "C" HPtr eco_apply_closure_typed(HPtr closure_hptr,
                                        int64_t* typed_args,
                                        uint32_t num_args,
                                        const EvalParamLayout* args_layout) {
    HPtr result = HPtr::fromBits(0);
    eco_apply_closure_eval(closure_hptr, typed_args, num_args, args_layout,
                           &result, /*desired_kind=*/0);
    return result;
}


namespace {

// Converts one new arg from the CALLER's encoding (`callerKind`) to the
// closure's SLOT encoding (`slotKind`) — "new args are converted by the
// runtime to match the slot's declared kind", the Phase-D contract
// (REP_CLOSURE_002). Matched kinds — every typed emission site — copy
// through untouched. Boxing may GC: the caller roots everything it holds.
inline uint64_t convertArgToSlotKind(uint64_t raw, uint32_t callerKind, uint32_t slotKind) {
    if (callerKind == slotKind) return raw;   // the universal case
    if (callerKind == 0) {
        // Boxed -> primitive: un-box (no allocation).
        void* hp_ptr = hpointerToPtr(raw);
        assert(hp_ptr && "eco_pap_extend_l: cannot un-box null/embedded HPointer");
        const char* base = reinterpret_cast<const char*>(hp_ptr) + sizeof(Header);
        switch (slotKind) {
            case 1: { int64_t v; memcpy(&v, base, sizeof(v)); return static_cast<uint64_t>(v); }
            case 2: { double f; memcpy(&f, base, sizeof(f)); uint64_t r; memcpy(&r, &f, sizeof(r)); return r; }
            case 3: { u16 c; memcpy(&c, base, sizeof(c)); return static_cast<uint64_t>(c); }
            default: assert(false && "unreachable slotKind"); __builtin_unreachable();
        }
    }
    if (slotKind == 0) {
        // Primitive -> boxed: box via the matching allocator (may GC).
        switch (callerKind) {
            case 1: return eco_alloc_int(static_cast<int64_t>(raw)).toBits();
            case 2: { double f; memcpy(&f, &raw, sizeof(f)); return eco_alloc_float(f).toBits(); }
            case 3: return eco_alloc_char(static_cast<uint32_t>(raw & 0xFFFFu)).toBits();
            default: assert(false && "unreachable callerKind"); __builtin_unreachable();
        }
    }
    // Both primitive but distinct: a representation mismatch the compiler
    // rules out. Pass through (old behaviour).
    return raw;
}

} // anonymous namespace

// Extends a PAP with `num_newargs` args whose CALLER kinds come from
// `caller_layout` (null = all boxed). The new closure has n_values + num_newargs
// value slots followed by the old closure's K = extWords(max_values, 20) ext
// kind words, copied from a snapshot (closure layout v2, HEAP_078); each new
// arg is converted to its slot kind before the allocation (boxing may GC, which
// would move a partially-built, unrooted closure).
extern "C" HPtr eco_pap_extend_l(HPtr closure_hptr, uint64_t* args, uint32_t num_newargs,
                                 const EvalParamLayout* caller_layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    Closure* old = static_cast<Closure*>(hpointerToPtr(closure_bits));
    if (!old) return HPtr::fromBits(0);

    // Kinds survive the boxing GC in the snapshot (ext words are immutable).
    ClosureKinds ks;
    snapshotClosureKinds(old, ks);
    const uint32_t old_n = old->n_values;
    const uint32_t max = old->max_values;
    const uint32_t new_n = old_n + num_newargs;
    const uint8_t rk = old->result_kind;
#if ECO_HEAP_VALIDATE
    // Premise of the empty-sat[] argument (2.6.8): max_values == stage_arity.
    assert((!old->evaluator || old->evaluator->stage_arity == max) &&
           "eco_pap_extend_l: max_values != evaluator->stage_arity");
#endif
    // Saturated calls use eco_closure_call_saturated instead.
    if (new_n > max) {
        std::fprintf(stderr, "[eco] FATAL: eco_pap_extend_l: new_n_values (%u) exceeds max_values (%u)\n",
                     new_n, max);
        std::abort();
    }
    auto callerKind = [&](uint32_t i) -> uint32_t {
        return caller_layout ? (caller_layout->kinds[i] & 3u) : 0u;
    };

    uint64_t conv_inline[64] = {0};
    std::unique_ptr<uint64_t[]> conv_heap;
    uint64_t* conv = conv_inline;
    if (num_newargs > 64) {
        conv_heap.reset(new uint64_t[num_newargs]());
        conv = conv_heap.get();
    }
    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    // Root the caller's args by CALLER kind, the conversion buffer by TARGET
    // kind (zero-filled slots are null HPtrs, skipped by the scan).
    pushRootsByKinds(args, num_newargs, callerKind);
    pushRootsByKinds(conv, num_newargs,
                     [&](uint32_t i) { return closureKindAt(ks, old_n + i); });
    for (uint32_t i = 0; i < num_newargs; ++i)
        conv[i] = convertArgToSlotKind(args[i], callerKind(i), closureKindAt(ks, old_n + i));

    // Allocate: new_n value slots + K ext words (header.size = new_n + K).
    const uint32_t K = ks.k;
    const size_t size = sizeof(Closure) + (static_cast<size_t>(new_n) + K) * sizeof(Unboxable);
    // Fast path: bump-pointer with no rooting — allocateFast cannot GC.
    void* obj = Allocator::instance().allocateFast(size);
    if (obj) {
        Header* hdr = getHeader(obj);
        zeroNewObject(hdr, size);
        hdr->tag = Tag_Closure;
        hdr->size = new_n + K;
    } else if (!(obj = Allocator::instance().allocateSlow(size, Tag_Closure))) {
        ecoRootRelease(saved_range);
        return HPtr::fromBits(0);
    }

    // Re-resolve: allocateSlow (or the boxing above) may have moved it.
    old = static_cast<Closure*>(hpointerToPtr(closure_bits));
    Closure* nc = static_cast<Closure*>(obj);
    // `result_kind` propagates: the extended closure shares the evaluator.
    nc->n_values = new_n;
    nc->max_values = max;
    nc->result_kind = rk;
    // Stored values were converted to the closure's slot encodings above, so
    // the kinds are simply the closure's own kind map.
    nc->unboxed = ks.hdr;
    nc->evaluator = old->evaluator;
    for (uint32_t i = 0; i < old_n; i++) nc->values[i] = old->values[i];
    for (uint32_t i = 0; i < num_newargs; i++)
        nc->values[old_n + i].i = static_cast<i64>(conv[i]);
    // The last K words: the ext kind words, zeros included (HEAP_077).
    u64* ext = reinterpret_cast<u64*>(&nc->values[new_n]);
    for (uint32_t j = 0; j < K; ++j) ext[j] = ks.ext[j];
    closureStatsRecord(reinterpret_cast<const void*>(nc->evaluator), /*isExtend=*/true);

    ecoRootRelease(saved_range);
    return ptrToHPointer(obj);
}

namespace {

// Splice captures + newargs into a single typed buffer matching the
// closure's wrapper convention. Used by both `eco_closure_call_saturated`
// (boxed-result path) and `eco_apply_closure_eval`'s K!=0 saturated path
// (primitive-result path).
//
// On entry `closure_bits_inout` and the buffer must already be GC-rooted
// by the caller. Returns the (possibly re-resolved) `Closure*` after any
// boxing allocations, since `eco_alloc_*` calls inside this helper may
// trigger GC.
//
// `closure_bits_inout` is updated to reflect the (re-)resolved closure
// pointer, and `kinds_out` holds the closure's kinds snapshot.
inline Closure* spliceArgsForSaturatedCall(uint64_t& closure_bits_inout,
                                            uint64_t* new_args,
                                            uint32_t num_newargs,
                                            const EvalParamLayout* layout,
                                            void** combined_args,
                                            uint32_t& max_values_out,
                                            ClosureKinds& kinds_out) {
    Closure* closure = static_cast<Closure*>(hpointerToPtr(closure_bits_inout));
    assert(closure && "spliceArgsForSaturatedCall: null closure");
    uint32_t max_values = closure->max_values;
    uint32_t n_values = closure->n_values;
    assert(n_values + num_newargs == max_values
           && "spliceArgsForSaturatedCall: argument count mismatch");
    assert(max_values <= CLOSURE_MAX_ARITY && "max_values exceeds the 11-bit field cap");

    // Kinds come from a snapshot (boxing below may move the closure): the
    // inline kinds plus the copied ext words (closure layout v2).
    ClosureKinds& ks = kinds_out;
    snapshotClosureKinds(closure, ks);

    // Captures: stored raw per closure->unboxed; copy directly.
    for (uint32_t i = 0; i < n_values; ++i) {
        combined_args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }

    // Newargs: convert from caller's layout convention to closure's
    // wrapper convention slot-by-slot.
    for (uint32_t i = 0; i < num_newargs; ++i) {
        uint32_t slot = n_values + i;
        uint64_t closureKind = closureKindAt(ks, slot);
        uint64_t callerKind = layout ? (layout->kinds[i] & 0x3ULL) : 0ULL;
        uint64_t raw = new_args[i];
        if (closureKind == callerKind) {
            // Already in the right encoding.
        } else if (callerKind == 0 && closureKind != 0) {
            // Boxed → primitive: un-box. The HPointer points at an
            // ElmInt/ElmFloat/ElmChar with the value at offset 8.
            void* hp_ptr = hpointerToPtr(raw);
            assert(hp_ptr && "spliceArgsForSaturatedCall: cannot un-box null/embedded HPointer");
            const char* base = reinterpret_cast<const char*>(hp_ptr) + sizeof(Header);
            switch (closureKind) {
                case 1: { // PK_Int
                    int64_t v;
                    memcpy(&v, base, sizeof(int64_t));
                    raw = static_cast<uint64_t>(v);
                    break;
                }
                case 2: { // PK_Float
                    double f;
                    memcpy(&f, base, sizeof(double));
                    memcpy(&raw, &f, sizeof(uint64_t));
                    break;
                }
                case 3: { // PK_Char
                    u16 c;
                    memcpy(&c, base, sizeof(u16));
                    raw = static_cast<uint64_t>(c);
                    break;
                }
                default:
                    assert(false && "unreachable closureKind");
                    __builtin_unreachable();
            }
        } else if (callerKind != 0 && closureKind == 0) {
            // Primitive → boxed: box via the matching allocator. (Rare —
            // happens when a typed-args caller targets a closure whose
            // wrapper expects an !eco.value at this slot.)
            switch (callerKind) {
                case 1:
                    raw = eco_alloc_int(static_cast<int64_t>(raw)).toBits();
                    break;
                case 2: {
                    double f;
                    memcpy(&f, &raw, sizeof(double));
                    raw = eco_alloc_float(f).toBits();
                    break;
                }
                case 3:
                    raw = eco_alloc_char(static_cast<uint32_t>(raw & 0xFFFFu)).toBits();
                    break;
                default:
                    assert(false && "unreachable callerKind");
                    __builtin_unreachable();
            }
            // Re-resolve closure: eco_alloc_* may have GC'd.
            closure = static_cast<Closure*>(hpointerToPtr(closure_bits_inout));
            snapshotClosureKinds(closure, ks);
        } else {
            // Both kinds primitive but distinct (e.g. Int vs Float). This
            // is a representation mismatch the compiler should have ruled
            // out. Trust it and pass through.
        }
        combined_args[slot] = reinterpret_cast<void*>(raw);
    }

#if ECO_HEAP_VALIDATE
    // Stale-arg tripwire: validate combined_args before the helper returns.
    // Catches stale entries arising from caller bugs or missed re-resolves
    // across the boxing/un-boxing GC points above. Primitive slots carry
    // raw bits, not HPointers, so they are skipped via the kinds snapshot
    // (closure->unboxed). Centralised here so both `eco_closure_call_saturated`
    // (K==0) and `invokeSaturatedTyped` (K!=0) get the check.
    for (uint32_t dbg_i = 0; dbg_i < max_values; ++dbg_i) {
        uint64_t closureKind = closureKindAt(ks, dbg_i);
        if (closureKind != 0) continue;
        uint64_t raw = reinterpret_cast<uint64_t>(combined_args[dbg_i]);
        HPointer hp;
        memcpy(&hp, &raw, sizeof(hp));
        if (hp.ptr_ind == 0 && hp.ptr != 0) {
            hpointerToPtr(raw);
        }
    }
#endif

    max_values_out = max_values;
    return closure;
}

} // anonymous namespace

// Typed-result sibling of `eco_closure_call_saturated`. Caller asserts the
// closure is saturated by `num_newargs` (n_values + num_newargs ==
// max_values); the helper writes the result into `result_slot` cast to the
// type implied by `desired_kind`. When the closure evaluator's K matches
// `desired_kind`, no boxing/unboxing happens — the primitive flows directly
// from the wrapper into the result slot. When K and desired_kind disagree,
// `invokeSaturatedTyped` boxes or extracts as needed.
//
// This entry point exists so JIT-emitted call sites whose SSA result type
// is primitive (i64/f64/i16) can avoid `eco_closure_call_saturated`'s
// hardcoded `desired_kind=0` boxing on the K!=0 path.
extern "C" void eco_closure_call_saturated_eval(
    HPtr closure_hptr, uint64_t* new_args, uint32_t num_newargs,
    const EvalParamLayout* layout, void* result_slot, uint8_t desired_kind) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) {
        // Zero-init the result slot for a defined value on null-closure.
        // (Same shape as `eco_apply_closure_eval`'s null guard.)
        switch (desired_kind) {
            case 0: *static_cast<HPtr*>(result_slot) = HPtr::fromBits(0); break;
            case 1: *static_cast<int64_t*>(result_slot) = 0; break;
            case 2: *static_cast<double*>(result_slot) = 0.0; break;
            case 3: *static_cast<uint16_t*>(result_slot) = 0; break;
        }
        return;
    }
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint8_t K = closure->result_kind;

    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    if (num_newargs > 0 && layout) {
        pushRootsByKinds(new_args, num_newargs,
                         [&](uint32_t i) { return layout->kinds[i]; });
    }
    invokeSaturatedTyped(closure_bits,
                         reinterpret_cast<int64_t*>(new_args),
                         num_newargs, layout, K, desired_kind, result_slot);
    ecoRootRelease(saved_range);
}

extern "C" HPtr eco_closure_call_saturated(HPtr closure_hptr, uint64_t* new_args, uint32_t num_newargs, const EvalParamLayout* layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) return HPtr::fromBits(0);

    // Phase C: dispatch on the closure evaluator's real C-ABI return
    // kind, read from `closure->result_kind` (set by papCreate /
    // eco_alloc_closure_k from the wrapper's compiled return ABI).
    // Reading from the closure header — rather than from the optional
    // `layout` argument — lets C++ kernel callers (List, JsArray,
    // String, Bytes) keep passing `layout=nullptr` and still dispatch
    // primitive-return wrappers correctly.
    Closure* hdr_closure = static_cast<Closure*>(closure_ptr);
    uint8_t K = hdr_closure->result_kind;
    if (K != 0) {
        EcoRootMark saved_range = ecoRootMark();
        ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
        // Root the typed-args buffer's HPointer slots so GC inside the
        // evaluator can update them in place.
        if (num_newargs > 0 && layout) {
            pushRootsByKinds(new_args, num_newargs,
                             [&](uint32_t i) { return layout->kinds[i]; });
        }
        HPtr result = HPtr::fromBits(0);
        invokeSaturatedTyped(closure_bits,
                             reinterpret_cast<int64_t*>(new_args),
                             num_newargs, layout, K,
                             /*desired_kind=*/0, &result);
        ecoRootRelease(saved_range);
        return result;
    }

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t max_values = closure->max_values;

    // Phase E: typed calling convention (REP_ABI_001). Splice captures +
    // newargs into a single buffer matching the closure's wrapper
    // convention via the shared helper.
    void* stack_args[16];
    // Up to 2047 slots: alloca up to 256 (2 KiB), heap above (open question 1).
    std::unique_ptr<void*[]> heap_args;
    void** combined_args = stack_args;
    if (max_values > 256) {
        heap_args.reset(new void*[max_values]);
        combined_args = heap_args.get();
    } else if (max_values > 16) {
        combined_args = static_cast<void**>(alloca(max_values * sizeof(void*)));
    }

    memset(combined_args, 0, max_values * sizeof(void*));

    // Open a stack root range over closure_bits and the combined buffer.
    // The boxed-slot kinds come from `closure->unboxed` (the full-params
    // bitmap; slots past the inline kinds read boxed), so primitive slots
    // are correctly skipped by GC.
    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    {
        ClosureKinds ks;
        snapshotClosureKinds(closure, ks);
        pushRootsByKinds(reinterpret_cast<uint64_t*>(combined_args), max_values,
                         [&](uint32_t i) { return closureKindAt(ks, i); });
    }
    // Also root the caller's new_args buffer's HPointer slots: when the
    // layout declares a primitive but the wrapper expects a boxed value,
    // spliceArgsForSaturatedCall allocates inside its Primitive→Boxed
    // branch, and the GC could otherwise move HPointer values held in
    // `new_args[i+1..]` between iterations of the splice loop.
    if (num_newargs > 0 && layout) {
        pushRootsByKinds(new_args, num_newargs,
                         [&](uint32_t i) { return layout->kinds[i]; });
    }

    uint32_t out_max_values = 0;
    ClosureKinds out_kinds;
    closure = spliceArgsForSaturatedCall(closure_bits, new_args, num_newargs,
                                         layout, combined_args,
                                         out_max_values, out_kinds);

    // Dispatch census (E0): the K==0 (boxed-result) direct evaluator call — the
    // one indirect call that does NOT flow through invokeSaturatedTyped.
    dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                        DispatchKind::Sat);
    void* result = closure->evaluator->generic(combined_args);

    ecoRootRelease(saved_range);
    return HPtr::fromBits(reinterpret_cast<uint64_t>(result));
}

namespace {

// Saturated dispatch for `eco_apply_closure_eval`. Builds the combined
// captures+newargs buffer and invokes `closure->evaluator` with the C-ABI
// signature matched to `K`. Stores the result into `result_slot`,
// converting between the evaluator's actual return ABI (`K`) and the
// caller's `desired_kind` as needed (boxing or extracting primitives).
//
// `closure_bits` is passed by value and rooted here; `typed_args`' boxed
// slots must be GC-rooted by the caller across this call. `typed_args` holds newargs in the format described by `args_layout`.
void invokeSaturatedTyped(uint64_t closure_bits,
                          int64_t* typed_args,
                          uint32_t num_args,
                          const EvalParamLayout* args_layout,
                          uint8_t K,
                          uint8_t desired_kind,
                          void* result_slot) {
    Closure* closure = static_cast<Closure*>(hpointerToPtr(closure_bits));
    assert(closure && "invokeSaturatedTyped: null closure");
    // Dispatch census (E0): THE saturated indirect evaluator call. This is the
    // single leaf primitive for every typed saturated dispatch — funnel-exact,
    // eco_closure_call_saturated_eval, eco_closure_call_saturated (K!=0). The
    // evaluator code pointer is invariant under GC relocation, so reading it
    // pre-splice keys to the same fp that is actually called below.
    dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                        DispatchKind::Sat);
    uint32_t max_values = closure->max_values;

    // Splice captures + newargs into combined_args. Re-uses the shared
    // helper used by the boxed-result path.
    void* stack_args[16];
    // Up to 2047 slots: alloca up to 256 (2 KiB), heap above (open question 1).
    std::unique_ptr<void*[]> heap_args;
    void** combined_args = stack_args;
    if (max_values > 256) {
        heap_args.reset(new void*[max_values]);
        combined_args = heap_args.get();
    } else if (max_values > 16) {
        combined_args = static_cast<void**>(alloca(max_values * sizeof(void*)));
    }
    memset(combined_args, 0, max_values * sizeof(void*));

    // Root the combined buffer's boxed slots, and this function's own copy
    // of closure_bits: it arrives by value, so the caller's root does not
    // cover it, and the splice re-resolves it after a boxing allocation.
    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    {
        ClosureKinds ks;
        snapshotClosureKinds(closure, ks);
        pushRootsByKinds(reinterpret_cast<uint64_t*>(combined_args), max_values,
                         [&](uint32_t i) { return closureKindAt(ks, i); });
    }

    uint32_t out_max_values = 0;
    ClosureKinds out_kinds;
    closure = spliceArgsForSaturatedCall(closure_bits,
                                         reinterpret_cast<uint64_t*>(typed_args),
                                         num_args,
                                         args_layout, combined_args,
                                         out_max_values, out_kinds);

    // Cast the evaluator function pointer to its real C ABI (per K) and
    // invoke. The wrapper was generated with this exact return ABI by
    // `getOrCreateWrapper(.., resultKind=K)` in the JIT pass.
    void* eval = reinterpret_cast<void*>(closure->evaluator->generic);
    switch (K) {
        case 0: {  // PK_Boxed (HPtr)
            using FnT = void* (*)(void**);
            void* r = reinterpret_cast<FnT>(eval)(combined_args);
            HPtr boxed = HPtr::fromBits(reinterpret_cast<uint64_t>(r));
            if (desired_kind == 0) {
                *static_cast<HPtr*>(result_slot) = boxed;
            } else {
                deliverPrimitiveFromBoxed(boxed, desired_kind, result_slot);
            }
            break;
        }
        case 1: {  // PK_Int (i64)
            using FnT = int64_t (*)(void**);
            int64_t r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 1) {
                *static_cast<int64_t*>(result_slot) = r;
            } else if (desired_kind == 0) {
                // Caller wants a boxed result: allocate ElmInt.
                *static_cast<HPtr*>(result_slot) = eco_alloc_int(r);
            } else {
                assert(false && "PK_Int evaluator with non-Int/Boxed desired_kind");
                __builtin_unreachable();
            }
            break;
        }
        case 2: {  // PK_Float (f64)
            using FnT = double (*)(void**);
            double r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 2) {
                *static_cast<double*>(result_slot) = r;
            } else if (desired_kind == 0) {
                *static_cast<HPtr*>(result_slot) = eco_alloc_float(r);
            } else {
                assert(false && "PK_Float evaluator with non-Float/Boxed desired_kind");
                __builtin_unreachable();
            }
            break;
        }
        case 3: {  // PK_Char (i16)
            using FnT = uint16_t (*)(void**);
            uint16_t r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 3) {
                *static_cast<uint16_t*>(result_slot) = r;
            } else if (desired_kind == 0) {
                *static_cast<HPtr*>(result_slot) = eco_alloc_char(static_cast<uint32_t>(r));
            } else {
                assert(false && "PK_Char evaluator with non-Char/Boxed desired_kind");
                __builtin_unreachable();
            }
            break;
        }
        default:
            assert(false && "invokeSaturatedTyped: unreachable result_kind K");
            __builtin_unreachable();
    }

    ecoRootRelease(saved_range);
}

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

extern "C" [[noreturn]] void eco_crash(HPtr message_val) {
    // message_val must be an HPointer to a heap-allocated string (any form).
    void* message = hpointerToPtr(message_val.toBits());

    if (message && alloc::isString(message)) {
        // Read via charAt so this works for both flat leaves and slices.
        size_t len = static_cast<Header*>(message)->size;
        fprintf(stderr, "Elm runtime error: ");
        for (size_t i = 0; i < len; i++) {
            u16 cu = Elm::StringOps::charAt(message, static_cast<i64>(i));
            char c = (cu < 128) ? static_cast<char>(cu) : '?';
            fputc(c, stderr);
        }
        fputc('\n', stderr);
    }

    // Use exit(1) instead of abort() to avoid triggering LLVM's signal handlers
    // which would print a misleading "PLEASE submit a bug report" message.
    std::exit(1);
}

// Forward declaration for recursive printing
static void print_value(uint64_t val, int depth);

// Print string content (without quotes) - for Debug.log labels.
// Accepts any string form (Tag_String / Tag_StringSlice) via tag-aware
// Elm::StringOps::charAt.
static void print_string_content(void* str) {
    if (!str) return;
    size_t len = static_cast<Header*>(str)->size;
    for (size_t i = 0; i < len; i++) {
        u16 c = Elm::StringOps::charAt(str, static_cast<i64>(i));
        if (c < 128) {
            output_char(static_cast<char>(c));
        } else {
            output_format("\\u%04X", c);
        }
    }
}

// Print a string value (with quotes). See print_string_content for tag handling.
static void print_string(void* str) {
    output_char('"');
    if (str) {
        size_t len = static_cast<Header*>(str)->size;
        for (size_t i = 0; i < len; i++) {
            u16 c = Elm::StringOps::charAt(str, static_cast<i64>(i));
            if (c == '"') {
                output_text("\\\"");
            } else if (c == '\\') {
                output_text("\\\\");
            } else if (c == '\n') {
                output_text("\\n");
            } else if (c == '\r') {
                output_text("\\r");
            } else if (c == '\t') {
                output_text("\\t");
            } else if (c < 32 || c >= 127) {
                output_format("\\u%04X", c);
            } else {
                output_char(static_cast<char>(c));
            }
        }
    }
    output_char('"');
}

// Print a character value in Elm syntax
static void print_char(u16 c) {
    output_char('\'');
    if (c == '\'') {
        output_text("\\'");
    } else if (c == '\\') {
        output_text("\\\\");
    } else if (c == '\n') {
        output_text("\\n");
    } else if (c == '\r') {
        output_text("\\r");
    } else if (c == '\t') {
        output_text("\\t");
    } else if (c < 32 || c >= 127) {
        output_format("\\u%04X", c);
    } else {
        output_char(static_cast<char>(c));
    }
    output_char('\'');
}

// Print an unboxed primitive value from a container field.
// ONLY called when: (1) unboxed bitmap indicates field is unboxed, AND
//                   (2) type graph says field type is primitive.
// NEVER called from eco_dbg_print_typed directly - that always receives
// boxed HPointer values.
static void printPrimitive(uint64_t bits, Elm::EcoPrimKind kind) {
    switch (kind) {
    case Elm::EcoPrimKind::Int:
        output_format("%lld", (long long)static_cast<int64_t>(bits));
        break;
    case Elm::EcoPrimKind::Float: {
        double d;
        std::memcpy(&d, &bits, sizeof(d));
        print_float(d);
        break;
    }
    case Elm::EcoPrimKind::Char:
        print_char(static_cast<u16>(bits));
        break;
    case Elm::EcoPrimKind::Bool:
        // Works for an unboxed i1 (0/1) and a boxed Bool word (False 0x4 / True
        // 0x5): the i1 value is bit 0 in both.
        output_text((bits & 1) ? "True" : "False");
        break;
    case Elm::EcoPrimKind::String:
        // String is NEVER unboxed - if we get here, it's a bug.
        // Fall through to print as pointer (will likely show <null> or garbage).
        assert(false && "String cannot be unboxed");
        output_text("<unboxed-string-bug>");
        break;
    case Elm::EcoPrimKind::Unit:
        // Unit is never unboxed (always the embedded empty constant), but handle
        // it for switch-completeness.
        output_text("()");
        break;
    }
}

// MLIR ConstantKind enum (1-based, from Ops.td)
// Type-erased fallback printer for the embedded constants. This path has NO type
// information (unlike print_typed_value), and under the merged representation the
// five empties share one bit pattern, so it can no longer name them individually
// — it prints a generic "<empty>". Bool stays distinguishable via bit 0. The
// real Debug.toString/log path is type-graph driven and names them correctly
// (see print_typed_value); this is only reached without a type graph. Plan D3.
// Returns true if `val` was a constant.
static bool print_if_constant(uint64_t val) {
    if (!isConstantBits(val)) {
        return false;  // Regular pointer.
    }
    if (isNullConsBits(val)) {
        // Nullary ctor embedded as a null-cons word (HEAP_044). No type info
        // here, so print the ctor index; the type-graph-driven printer names
        // it properly.
        output_format("<ctor %u>", nullConsTagBits(val));
    } else if (isEmptyBits(val)) {
        output_text("<empty>");
    } else {
        output_text(boolValueBits(val) ? "True" : "False");
    }
    return true;
}

// Check if a value is the Nil / merged empty constant (list terminator).
static bool is_nil(uint64_t val) {
    return isEmptyBits(val);
}

// Check if a Custom object is a list cons cell.
// MLIR generates: List Nil with tag=0, size=0; List Cons with tag=1, size=2.
// The tail (field 1) must be boxed (not unboxed) since it points to next cell or Nil.
static inline bool is_list_cons(const Custom* custom) {
    // Field 1 (the tail) must be boxed: kind 0 at bits [2,3] → mask 0xC is zero.
    return custom->ctor == 1 &&
           custom->header.size == 2 &&
           fieldKind(custom->unboxed, 1) == 0;
}

// Print a list in Elm syntax: [1, 2, 3]
static void print_list(uint64_t val, int depth) {
    output_char('[');

    bool first = true;
    uint64_t current = val;
    int count = 0;
    const int MAX_LIST_ITEMS = 100;  // Prevent infinite loops

    while (count < MAX_LIST_ITEMS) {
        // Any embedded constant terminates the list. The merged empty is Nil;
        // a non-empty constant (a Bool) in a tail position is malformed.
        if (isConstantBits(current)) {
            if (!isEmptyBits(current)) {
                if (!first) output_text(", ");
                output_text("<invalid_list_tail>");
            }
            break;
        }

        // Convert HPointer to raw pointer
        void* ptr = hpointerToPtr(current);
        if (!ptr) {
            if (!first) output_text(", ");
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        // eco.construct uses Tag_Custom with ctor=1 for list cons cells
        // MLIR: List Nil has tag=0, size=0; List Cons has tag=1, size=2
        // Native Cons type uses Tag_Cons
        if (header->tag == Tag_Custom) {
            Custom* custom = static_cast<Custom*>(ptr);
            // Use is_list_cons helper to validate cons cell
            if (!is_list_cons(custom)) {
                if (!first) output_text(", ");
                output_text("<non_cons_custom>");
                break;
            }

            if (!first) {
                output_text(", ");
            }
            first = false;

            // Print the head element (field 0)
            switch (fieldKind(custom->unboxed, 0)) {
                case 1: output_format("%lld", (long long)custom->values[0].i); break;
                case 2: output_format("%g", (double)custom->values[0].f); break;
                case 3: output_format("'%c'", (int)custom->values[0].c); break;
                default: {
                    uint64_t head_val = static_cast<uint64_t>(custom->values[0].i);
                    print_value(head_val, depth + 1);
                    break;
                }
            }

            // Move to tail (field 1) - read as full 64-bit value
            current = static_cast<uint64_t>(custom->values[1].i);
        } else if (header->tag == Tag_Cons) {
            Cons* cons = static_cast<Cons*>(ptr);

            if (!first) {
                output_text(", ");
            }
            first = false;

            // Print the head element
            switch (tupleFieldKind(header->unboxed, 0)) {
                case 1: output_format("%lld", (long long)cons->head.i); break;
                case 2: output_format("%g", (double)cons->head.f); break;
                case 3: output_format("'%c'", (int)cons->head.c); break;
                default: {
                    uint64_t head_val = hpBits(cons->head.p);
                    print_value(head_val, depth + 1);
                    break;
                }
            }

            // Move to tail
            current = hpBits(cons->tail);
        } else if (header->tag == Tag_ConsChunk) {
            // Chunk view (hybrid spines): print the dense run from the
            // backing by uniform element kind, then continue with `next`.
            ConsChunk* cv = static_cast<ConsChunk*>(ptr);
            ListBacking* lb = static_cast<ListBacking*>(hpointerToPtr(hpBits(cv->backing)));
            u32 cap = lb->header.size;
            u32 run = cap - cv->offset;
            u32 k = (cv->len < run) ? cv->len : run;
            uint32_t kind = static_cast<uint32_t>(header->unboxed & 0x3);
            for (u32 i = 0; i < k && count < MAX_LIST_ITEMS; i++, count++) {
                if (!first) output_text(", ");
                first = false;
                const Unboxable& v = lb->elems[cv->offset + i];
                switch (kind) {
                    case 1: output_format("%lld", (long long)v.i); break;
                    case 2: output_format("%g", (double)v.f); break;
                    case 3: output_format("'%c'", (int)v.c); break;
                    default: print_value(hpBits(v.p), depth + 1); break;
                }
            }
            current = hpBits(cv->next);
            continue; // count already advanced per element
        } else {
            if (!first) output_text(", ");
            output_format("<non_cons_tag_%d>", header->tag);
            break;
        }

        count++;
    }

    if (count >= MAX_LIST_ITEMS) {
        output_text(", ...");
    }

    output_char(']');
}

// Print a single slot whose kind is encoded in `kind` (0=boxed, 1=Int, 2=Float, 3=Char).
static void print_unboxable_slot(const Unboxable& v, uint32_t kind, int depth) {
    switch (kind) {
        case 1: output_format("%lld", (long long)v.i); break;
        case 2: output_format("%g", (double)v.f); break;
        case 3: output_format("'%c'", (int)v.c); break;
        default: print_value(static_cast<uint64_t>(v.i), depth + 1); break;
    }
}

// Print a tuple
static void print_tuple2(Tuple2* tuple, int depth) {
    output_char('(');
    print_unboxable_slot(tuple->a, tupleFieldKind(tuple->header.unboxed, 0), depth);
    output_text(", ");
    print_unboxable_slot(tuple->b, tupleFieldKind(tuple->header.unboxed, 1), depth);
    output_char(')');
}

static void print_tuple3(Tuple3* tuple, int depth) {
    output_char('(');
    print_unboxable_slot(tuple->a, tupleFieldKind(tuple->header.unboxed, 0), depth);
    output_text(", ");
    print_unboxable_slot(tuple->b, tupleFieldKind(tuple->header.unboxed, 1), depth);
    output_text(", ");
    print_unboxable_slot(tuple->c, tupleFieldKind(tuple->header.unboxed, 2), depth);
    output_char(')');
}

// Print a custom type constructor
static void print_custom(Custom* custom, int depth) {
    uint32_t ctor = custom->ctor;
    uint32_t size = custom->header.size;

    // Print generic constructor name (1-indexed for readability)
    output_format("Ctor%u", ctor);

    // Print fields if any
    if (size > 0) {
        output_char(' ');
        for (uint32_t i = 0; i < size; i++) {
            if (i > 0) output_char(' ');

            uint32_t k = customSlotKind(custom, i);
            if (k != 0) {
                print_unboxable_slot(custom->values[i], k, depth);
            } else {
                // Read as full 64-bit value for JIT mode
                uint64_t val = static_cast<uint64_t>(custom->values[i].i);

                if (val == 0) {
                    // Null pointer
                    output_text("<null>");
                } else if (!print_if_constant(val)) {
                    // Heap pointer - resolve HPointer
                    void* ptr = hpointerToPtr(val);
                    bool needs_parens = false;
                    if (ptr) {
                        Header* h = static_cast<Header*>(ptr);
                        needs_parens = (h->tag == Tag_Custom && static_cast<Custom*>(ptr)->header.size > 0);
                    }
                    if (needs_parens) output_char('(');
                    print_value(val, depth + 1);
                    if (needs_parens) output_char(')');
                }
            }
        }
    }
}

// Print a record
static void print_record(Record* record, int depth) {
    uint32_t size = record->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        // We don't have field names, so use numeric indices
        output_format("f%u = ", i);

        uint32_t k = recordSlotKind(record, i);
        if (k != 0) {
            print_unboxable_slot(record->values[i], k, depth);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(record->values[i].i), depth + 1);
        }
    }
    output_text(" }");
}

// Print a dynamic record
static void print_dynrecord(DynRecord* dynrec, int depth) {
    uint32_t size = dynrec->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        // We don't have field names, so use numeric indices
        output_format("f%u = ", i);

        // DynRecord values are HPointer, not Unboxable.
        uint64_t val = hpBits(dynrec->values[i]);
        print_value(val, depth + 1);
    }
    output_text(" }");
}

// Print an array
static void print_array(ElmArray* array, int depth) {
    output_text("Array.fromList [");
    uint32_t kind = array->header.unboxed & 0x3;
    for (uint32_t i = 0; i < array->length; i++) {
        if (i > 0) output_text(", ");

        if (kind != 0) {
            print_unboxable_slot(array->elements[i], kind, depth);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(array->elements[i].i), depth + 1);
        }
    }
    output_char(']');
}

// Main value printer
static void print_value(uint64_t val, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        output_text("...");
        return;
    }

    // Check for embedded constants first
    if (print_if_constant(val)) {
        return;
    }

    // Convert HPointer to raw pointer via allocator
    void* ptr = hpointerToPtr(val);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    switch (header->tag) {
        case Tag_Int: {
            ElmInt* intval = static_cast<ElmInt*>(ptr);
            output_format("%lld", (long long)intval->value);
            break;
        }

        case Tag_Float: {
            ElmFloat* floatval = static_cast<ElmFloat*>(ptr);
            print_float(floatval->value);
            break;
        }

        case Tag_Char: {
            ElmChar* charval = static_cast<ElmChar*>(ptr);
            print_char(charval->value);
            break;
        }

        case Tag_String:
        case Tag_StringSlice:
        case Tag_StringRope:
        case Tag_LargeStringHeader:
        case Tag_StringUtf8View:
        case Tag_StringUtf8Leaf: {
            print_string(ptr);
            break;
        }

        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(ptr);
            print_tuple2(tuple, depth);
            break;
        }

        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(ptr);
            print_tuple3(tuple, depth);
            break;
        }

        case Tag_Cons:
        case Tag_ConsChunk: {
            // Print as a list (either hybrid spine-node form)
            print_list(val, depth);
            break;
        }

        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(ptr);
            // Check if this is a list cons cell using the is_list_cons helper.
            // MLIR: List Cons has ctor=1, size=2 (NOT ctor=0 which is used for tuples).
            if (is_list_cons(custom)) {
                print_list(val, depth);
            } else {
                print_custom(custom, depth);
            }
            break;
        }

        case Tag_Record: {
            Record* record = static_cast<Record*>(ptr);
            print_record(record, depth);
            break;
        }

        case Tag_DynRecord: {
            DynRecord* dynrec = static_cast<DynRecord*>(ptr);
            print_dynrecord(dynrec, depth);
            break;
        }

        case Tag_Closure: {
            output_text("<fn>");
            break;
        }

        case Tag_Process: {
            Process* proc = static_cast<Process*>(ptr);
            output_format("<process:%llu>", (unsigned long long)proc->id);
            break;
        }

        case Tag_Task: {
            output_text("<task>");
            break;
        }

        case Tag_FieldGroup: {
            output_text("<fieldgroup>");
            break;
        }

        case Tag_ByteBuffer:
        case Tag_LargeByteHeader:
        case Tag_ByteBufferSlice: {
            // All three forms carry the logical byte count in header.size;
            // the slice/split-header forms reference their payload via an
            // HPointer we don't need for the size-only debug rendering.
            output_format("<bytes:%u>", header->size);
            break;
        }

        case Tag_Array: {
            ElmArray* array = static_cast<ElmArray*>(ptr);
            print_array(array, depth);
            break;
        }

        case Tag_Forward: {
            output_text("<forward>");
            break;
        }

        case Tag_Free: {
            output_text("<free>");
            break;
        }

        default:
            output_format("<unknown_tag_%u>", header->tag);
            break;
    }
}

extern "C" void eco_dbg_print(uint64_t* args, uint32_t num_args) {
    output_text("[eco.dbg] ");
    for (uint32_t i = 0; i < num_args; i++) {
        if (i > 0) output_char(' ');
        print_value(args[i], 0);
    }
    output_text("\n");
}

// Debug print for unboxed integer (i64)
extern "C" void eco_dbg_print_int(int64_t value) {
    output_format("[eco.dbg] %lld\n", (long long)value);
}

// Debug print for unboxed float (f64)
extern "C" void eco_dbg_print_float(double value) {
    output_text("[eco.dbg] ");
    print_float(value);
    output_text("\n");
}

// Debug print for unboxed char (i32 Unicode code point)
extern "C" void eco_dbg_print_char(int32_t value) {
    output_text("[eco.dbg] ");
    print_char(static_cast<u16>(value));
    output_text("\n");
}

// Global type graph pointer - set by eco_register_type_graph from JITed code
static const Elm::EcoTypeGraph* g_type_graph = nullptr;

// Register the type graph from JITed code
extern "C" void eco_register_type_graph(const void* graph) {
    g_type_graph = static_cast<const Elm::EcoTypeGraph*>(graph);
}

// Forward declaration for recursive printing
static void print_typed_value(uint64_t value, uint32_t type_id, int depth);

// Helper to print a label (string value without quotes).
// Accepts any string form (leaf or slice) via Elm::alloc::isString.
static void print_label(uint64_t value) {
    void* ptr = hpointerToPtr(value);
    if (ptr) {
        if (alloc::isString(ptr)) {
            print_string_content(ptr);
        } else {
            print_value(value, 0);
        }
    } else {
        output_text("<null>");
    }
}

// Helper: check if a type_id refers to a String primitive in the type graph.
static bool isStringType(uint32_t type_id) {
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        return false;
    }
    const Elm::EcoTypeInfo* info = &g_type_graph->types[type_id];
    return info->kind == Elm::EcoTypeKind::Primitive &&
           info->data.primitive.prim_kind == Elm::EcoPrimKind::String;
}

// Debug print with full type information using the global type graph.
// When called with 2 args where type_ids[0] is a String type, this is a Debug.log call
// and we format as "label: value\n"
extern "C" void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args) {
    // Special case for Debug.log: 2 args, first is a string label
    if (num_args == 2 && isStringType(type_ids[0])) {
        print_label(values[0]);
        output_text(": ");
        print_typed_value(values[1], type_ids[1], 0);
        output_text("\n");
        return;
    }

    // General case: print each value on its own line
    for (uint32_t i = 0; i < num_args; ++i) {
        print_typed_value(values[i], type_ids[i], 0);
        output_text("\n");
    }
}

// Print a value using type information from the type graph
static void print_typed_value(uint64_t value, uint32_t type_id, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        output_text("...");
        return;
    }

    // Assert type graph is available and type_id is valid
    assert(g_type_graph && "Type graph not initialized");
    assert(g_type_graph->types && "Type graph has no types array");
    assert(type_id < g_type_graph->type_count && "Invalid type_id");
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        // Safety fallback in release builds
        print_value(value, depth);
        return;
    }

    const Elm::EcoTypeInfo* typeInfo = &g_type_graph->types[type_id];

    switch (typeInfo->kind) {
    case Elm::EcoTypeKind::Primitive: {
        // At the dbg boundary primitives are boxed (!eco.value): a heap object
        // (ElmInt/Float/Char/String) or an embedded constant. The only primitive
        // constants are Bool (True/False) and the empty String — name them from
        // the known prim_kind so we do not depend on the constant's specific
        // value (post-merge all empties share one bit pattern). See plan D3/D4.
        if (isConstantBits(value)) {
            Elm::EcoPrimKind pk = typeInfo->data.primitive.prim_kind;
            if (pk == Elm::EcoPrimKind::Bool) {
                output_text(boolValueBits(value) ? "True" : "False");
            } else if (pk == Elm::EcoPrimKind::String) {
                output_text("\"\"");
            } else if (pk == Elm::EcoPrimKind::Unit) {
                output_text("()");
            } else {
                print_value(value, depth);  // unexpected primitive constant
            }
        } else {
            print_value(value, depth);  // heap ElmInt/Float/Char/String
        }
        break;
    }

    case Elm::EcoTypeKind::List: {
        // Get element type for typed recursive printing
        uint32_t elem_type_id = typeInfo->data.list.elem_type_id;

        // Assert element type is in valid range
        assert(elem_type_id < g_type_graph->type_count && "Invalid elem_type_id in List type graph");

        output_char('[');
        bool first = true;
        uint64_t current = value;
        int count = 0;
        const int MAX_LIST_ITEMS = 100;

        while (count < MAX_LIST_ITEMS) {
            // Any embedded constant in a list tail is the end of the list. In a
            // List-typed context the only constant that can appear is Nil, so we
            // need not distinguish it from the other empties (plan D3).
            if (isConstantBits(current)) {
                break;
            }

            void* ptr = hpointerToPtr(current);
            if (!ptr) break;

            Header* header = static_cast<Header*>(ptr);

            // Handle both Tag_Cons and Tag_Custom (ctor=1) for list cons cells
            uint64_t head_val;
            uint64_t tail_val;
            bool head_unboxed = false;

            if (header->tag == Tag_Cons) {
                Cons* cons = static_cast<Cons*>(ptr);
                head_val = static_cast<uint64_t>(cons->head.i);
                head_unboxed = (tupleFieldKind(cons->header.unboxed, 0) != 0);
                tail_val = hpBits(cons->tail);
            } else if (header->tag == Tag_ConsChunk) {
                // Chunk view (hybrid spines): head is the first live slot of
                // the run; the logical tail is the rest of the run — which
                // has no materialized node, so synthesize by walking the run
                // inline here instead. Simplest correct handling for the
                // bounded debug printer: print the whole run, continue at
                // `next`.
                ConsChunk* cv = static_cast<ConsChunk*>(ptr);
                ListBacking* lb =
                    static_cast<ListBacking*>(hpointerToPtr(hpBits(cv->backing)));
                u32 cap = lb->header.size;
                u32 run = cap - cv->offset;
                u32 k = (cv->len < run) ? cv->len : run;
                bool ub = (header->unboxed & 0x3) != 0;
                for (u32 i = 0; i < k && count < MAX_LIST_ITEMS; i++, count++) {
                    if (!first) output_text(", ");
                    first = false;
                    uint64_t hv =
                        static_cast<uint64_t>(lb->elems[cv->offset + i].i);
                    if (ub) {
                        const Elm::EcoTypeInfo* elemType =
                            &g_type_graph->types[elem_type_id];
                        if (elemType->kind == Elm::EcoTypeKind::Primitive) {
                            printPrimitive(hv, elemType->data.primitive.prim_kind);
                        } else {
                            printPrimitive(hv, Elm::EcoPrimKind::Int);
                        }
                    } else {
                        print_typed_value(hv, elem_type_id, depth + 1);
                    }
                }
                current = hpBits(cv->next);
                continue;
            } else if (header->tag == Tag_Custom) {
                Custom* custom = static_cast<Custom*>(ptr);
                if (!is_list_cons(custom)) break;
                head_val = static_cast<uint64_t>(custom->values[0].i);
                head_unboxed = (fieldKind(custom->unboxed, 0) != 0);
                tail_val = static_cast<uint64_t>(custom->values[1].i);
            } else {
                break;
            }

            if (!first) output_text(", ");
            first = false;

            // Print head with type info
            if (head_unboxed) {
                // Value is unboxed - use printPrimitive based on element type
                const Elm::EcoTypeInfo* elemType = &g_type_graph->types[elem_type_id];
                if (elemType->kind == Elm::EcoTypeKind::Primitive) {
                    printPrimitive(head_val, elemType->data.primitive.prim_kind);
                } else if (elemType->kind == Elm::EcoTypeKind::Polymorphic &&
                           elemType->data.polymorphic.constraint == Elm::EcoConstraintKind::Number) {
                    // Number constraint with unboxed value - assume Int
                    printPrimitive(head_val, Elm::EcoPrimKind::Int);
                } else {
                    // Unboxed but type graph says non-primitive - type mismatch
                    assert(false && "List head is unboxed but element type is not primitive");
                    output_format("<unboxed-non-prim:0x%llx>", (unsigned long long)head_val);
                }
            } else {
                // Value is boxed (HPointer) - recurse with type info
                print_typed_value(head_val, elem_type_id, depth + 1);
            }

            current = tail_val;
            count++;
        }

        if (count >= MAX_LIST_ITEMS) {
            output_text(", ...");
        }
        output_char(']');
        break;
    }

    case Elm::EcoTypeKind::Tuple: {
        uint16_t arity = typeInfo->data.tuple.arity;
        uint32_t first_field = typeInfo->data.tuple.first_field;

        // Assert fields array is valid
        assert(g_type_graph->fields && "Type graph has no fields array");
        assert(first_field + arity <= g_type_graph->field_count && "Tuple field indices out of bounds");

        // Assert field types are in valid range
        for (uint16_t i = 0; i < arity; i++) {
            assert(g_type_graph->fields[first_field + i].type_id < g_type_graph->type_count &&
                   "Invalid field type_id in Tuple type graph");
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        if (header->tag == Tag_Tuple2 && arity == 2) {
            Tuple2* tuple = static_cast<Tuple2*>(ptr);
            uint32_t type_a = g_type_graph->fields[first_field].type_id;
            uint32_t type_b = g_type_graph->fields[first_field + 1].type_id;
            uint8_t unboxed = tuple->header.unboxed;

            output_char('(');
            // Field a
            if (tupleFieldKind(unboxed, 0) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_a];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple field a is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->a.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->a.i), type_a, depth + 1);
            }
            output_text(", ");
            // Field b
            if (tupleFieldKind(unboxed, 1) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_char(')');
        } else if (header->tag == Tag_Tuple3 && arity == 3) {
            Tuple3* tuple = static_cast<Tuple3*>(ptr);
            uint32_t type_a = g_type_graph->fields[first_field].type_id;
            uint32_t type_b = g_type_graph->fields[first_field + 1].type_id;
            uint32_t type_c = g_type_graph->fields[first_field + 2].type_id;
            uint8_t unboxed = tuple->header.unboxed;

            output_char('(');
            // Field a
            if (tupleFieldKind(unboxed, 0) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_a];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field a is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->a.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->a.i), type_a, depth + 1);
            }
            output_text(", ");
            // Field b
            if (tupleFieldKind(unboxed, 1) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_text(", ");
            // Field c
            if (tupleFieldKind(unboxed, 2) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_c];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field c is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->c.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->c.i), type_c, depth + 1);
            }
            output_char(')');
        } else {
            // Tag doesn't match expected tuple type
            assert(false && "Tuple tag mismatch - value doesn't match type");
            output_text("<tuple-mismatch>");
        }
        break;
    }

    case Elm::EcoTypeKind::Record: {
        uint32_t first_field = typeInfo->data.record.first_field;
        uint32_t field_count = typeInfo->data.record.field_count;

        // An embedded constant of a Record type is the empty record {} (plan D3).
        if (isConstantBits(value)) {
            output_text("{}");
            break;
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);
        if (header->tag != Tag_Record) {
            print_value(value, depth);
            break;
        }

        Record* record = static_cast<Record*>(ptr);
        uint32_t actual_size = record->header.size;

        output_text("{ ");
        for (uint32_t i = 0; i < actual_size && i < field_count; i++) {
            if (i > 0) output_text(", ");

            // Get field info from type graph
            if (g_type_graph->fields && first_field + i < g_type_graph->field_count) {
                const Elm::EcoFieldInfo* field = &g_type_graph->fields[first_field + i];

                // Print field name if available
                if (g_type_graph->strings && field->name_index < g_type_graph->string_count) {
                    output_text(g_type_graph->strings[field->name_index]);
                } else {
                    output_format("f%u", i);
                }
                output_text(" = ");

                // Print field value - check unboxed bitmap from heap
                uint64_t field_val = static_cast<uint64_t>(record->values[i].i);
                bool is_unboxed = recordSlotKind(record, i) != 0;

                if (is_unboxed) {
                    const Elm::EcoTypeInfo* ft = &g_type_graph->types[field->type_id];
                    assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                           "Record field is unboxed but type is not primitive");
                    printPrimitive(field_val, ft->data.primitive.prim_kind);
                } else {
                    print_typed_value(field_val, field->type_id, depth + 1);
                }
            } else {
                // Fallback without type info
                output_format("f%u = ", i);
                uint64_t field_val = static_cast<uint64_t>(record->values[i].i);
                print_value(field_val, depth + 1);
            }
        }
        output_text(" }");
        break;
    }

    case Elm::EcoTypeKind::Custom: {
        uint32_t first_ctor = typeInfo->data.custom.first_ctor;
        uint32_t ctor_count = typeInfo->data.custom.ctor_count;

        // An embedded constant of a Custom type is one of that type's nullary
        // constructors. A null-cons word (HEAP_044) carries its declaration
        // index — look the ctor up by id. The legacy merged empty (0x6, e.g.
        // Maybe's Nothing) carries no index, so name the type's first nullary
        // ctor as before (plan D3). Bool is a Primitive, not a Custom, so a
        // Custom constant is never a Bool.
        if (isConstantBits(value)) {
            assert(g_type_graph->ctors && "Type graph has no ctors array");
            if (isNullConsBits(value)) {
                uint32_t want = nullConsTagBits(value);
                bool found = false;
                for (uint32_t ci = 0; ci < ctor_count; ++ci) {
                    const Elm::EcoCtorInfo* nInfo = &g_type_graph->ctors[first_ctor + ci];
                    if (nInfo->ctor_id == want) {
                        output_text(g_type_graph->strings[nInfo->name_index]);
                        found = true;
                        break;
                    }
                }
                if (!found) output_format("<ctor %u>", want);
                break;
            }
            for (uint32_t ci = 0; ci < ctor_count; ++ci) {
                const Elm::EcoCtorInfo* nInfo = &g_type_graph->ctors[first_ctor + ci];
                if (nInfo->field_count == 0) {
                    output_text(g_type_graph->strings[nInfo->name_index]);
                    break;
                }
            }
            break;
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);
        assert(header->tag == Tag_Custom && "Expected Custom tag for Custom type");
        if (header->tag != Tag_Custom) {
            output_text("<not-custom>");
            break;
        }

        Custom* custom = static_cast<Custom*>(ptr);
        uint32_t ctor_id = custom->ctor;
        uint32_t size = custom->header.size;

        // Assert constructor info is available
        assert(g_type_graph->ctors && "Type graph has no ctors array");
        assert(ctor_count > 0 && "Custom type has no constructors in type graph - codegen bug");

        // Runtime-recognised types (e.g. Dict) use reserved ctor_id values
        // outside 0..ctor_count-1, so search linearly instead of indexing.
        const Elm::EcoCtorInfo* ctor_info = nullptr;
        for (uint32_t ci = 0; ci < ctor_count; ++ci) {
            if (g_type_graph->ctors[first_ctor + ci].ctor_id == ctor_id) {
                ctor_info = &g_type_graph->ctors[first_ctor + ci];
                break;
            }
        }
        assert(ctor_info != nullptr && "Constructor id not found in type graph");

        // Assert constructor name is available
        assert(g_type_graph->strings && "Type graph has no strings array");
        assert(ctor_info->name_index < g_type_graph->string_count &&
               "Constructor name_index out of bounds");

        // Print constructor name
        output_text(g_type_graph->strings[ctor_info->name_index]);

        // Print fields if any
        if (size > 0) {
            // Assert field info is available
            assert(g_type_graph->fields && "Type graph has no fields array");
            assert(ctor_info->field_count == size && "Field count mismatch");
            assert(ctor_info->first_field + size <= g_type_graph->field_count &&
                   "Field indices out of bounds");

            for (uint32_t i = 0; i < size; i++) {
                output_char(' ');

                uint64_t field_val = static_cast<uint64_t>(custom->values[i].i);
                bool is_unboxed = customSlotKind(custom, i) != 0;

                // Get field type from ctor info
                uint32_t field_type_id = g_type_graph->fields[ctor_info->first_field + i].type_id;

                // Assert field type is in valid range
                assert(field_type_id < g_type_graph->type_count &&
                       "Invalid field type_id in Custom type graph");

                // Check if nested custom needs parentheses (only for boxed values)
                bool needs_parens = false;
                if (!is_unboxed) {
                    void* field_ptr = hpointerToPtr(field_val);
                    if (field_ptr) {
                        Header* h = static_cast<Header*>(field_ptr);
                        needs_parens = (h->tag == Tag_Custom &&
                                       static_cast<Custom*>(field_ptr)->header.size > 0);
                    }
                }

                if (needs_parens) output_char('(');

                if (is_unboxed) {
                    // Unboxed value - use printPrimitive with type from type graph
                    const Elm::EcoTypeInfo* ft = &g_type_graph->types[field_type_id];
                    assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                           "Custom field is unboxed but type is not primitive");
                    printPrimitive(field_val, ft->data.primitive.prim_kind);
                } else {
                    print_typed_value(field_val, field_type_id, depth + 1);
                }

                if (needs_parens) output_char(')');
            }
        }
        break;
    }

    case Elm::EcoTypeKind::Function:
        // Functions are printed as closures
        output_text("<function>");
        break;

    case Elm::EcoTypeKind::Polymorphic:
        // Polymorphic type variable - value is always boxed (!eco.value).
        // Just dispatch based on heap tag via print_value.
        // For Number constraint, this will print Int or Float correctly.
        // For EcoValue constraint, it handles any heap type.
        print_value(value, depth);
        break;
    }
}

// Output text to the current output stream (for kernel functions)
extern "C" void eco_output_text(const char* text) {
    output_text(text);
}

// Print an Elm value to the current output stream
extern "C" void eco_print_value(HPtr value) {
    print_value(value.toBits(), 0);
}

// Print an Elm value, unwrapping the Ctor0 box wrapper used by Guida compiler.
// This is used by Debug.log to show clean Elm values.
extern "C" void eco_print_elm_value(HPtr value) {
    uint64_t value_bits = value.toBits();
    // Check for embedded constants first
    if (print_if_constant(value_bits)) {
        return;
    }

    // Convert HPointer to raw pointer via allocator
    void* ptr = hpointerToPtr(value_bits);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    // Check if this is a Ctor0 size=1 wrapper (Guida's box for polymorphic values)
    if (header->tag == Tag_Custom) {
        Custom* custom = static_cast<Custom*>(ptr);
        if (custom->ctor == 0 && custom->header.size == 1) {
            // Unwrap: print the inner value directly
            uint32_t k = static_cast<uint32_t>(fieldKind(custom->unboxed, 0));
            if (k != 0) {
                print_unboxable_slot(custom->values[0], k, 0);
            } else {
                uint64_t inner = static_cast<uint64_t>(custom->values[0].i);
                // Safety check for small integers
                if (inner < 0x10000) {
                    output_format("%lld", (long long)inner);
                } else if (!print_if_constant(inner)) {
                    // Recursively print the inner value (also unwrapping if needed)
                    eco_print_elm_value(HPtr::fromBits(inner));
                }
            }
            return;
        }
    }

    // Not a wrapper, print normally
    print_value(value_bits, 0);
}

// Convert an Elm value to its string representation
extern "C" HPtr eco_value_to_string(HPtr value) {
    // Temporarily capture output to a string
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    // Print the value
    print_value(value.toBits(), 0);

    // Restore previous stream
    tl_output_stream = prev;

    // Allocate and return an ElmString from the captured output
    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    return HPtr::fromHPointer(strPtr);
}

extern "C" HPtr eco_value_to_string_typed(HPtr value, int64_t type_id) {
    uint64_t value_bits = value.toBits();
    // Temporarily capture output to a string
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    // Print the value using type information for constructor names
    if (type_id >= 0 && g_type_graph && g_type_graph->types &&
        static_cast<uint32_t>(type_id) < g_type_graph->type_count) {
        print_typed_value(value_bits, static_cast<uint32_t>(type_id), 0);
    } else {
        print_value(value_bits, 0);
    }

    // Restore previous stream
    tl_output_stream = prev;

    // Allocate and return an ElmString from the captured output
    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    return HPtr::fromHPointer(strPtr);
}

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

extern "C" void eco_safepoint() {
    // No-op for now
    // In the future, this will check if GC needs to run
}

extern "C" void __eco_safepoint_poll() {
    auto& alloc = Elm::Allocator::instance();
    if (!alloc.shouldCollectAtSafepoint())
        return;
    alloc.collectAtSafepoint();
}

extern "C" void eco_minor_gc() {
    Allocator::instance().minorGC();
}

extern "C" void eco_major_gc() {
    Allocator::instance().majorGC();
}

extern "C" void eco_gc_add_root(uint64_t* root_ptr) {
    Allocator::instance().getRootSet().addJitRoot(root_ptr);
}

extern "C" void eco_gc_remove_root(uint64_t* root_ptr) {
    Allocator::instance().getRootSet().removeJitRoot(root_ptr);
}

extern "C" uint64_t eco_gc_jit_root_count() {
    return Allocator::instance().getRootSet().getJitRoots().size();
}

extern "C" void eco_gc_add_value_root(uint64_t* value_ptr) {
    Allocator::instance().getRootSet().addRoot(reinterpret_cast<HPointer*>(value_ptr));
}

extern "C" void eco_gc_remove_value_root(uint64_t* value_ptr) {
    Allocator::instance().getRootSet().removeRoot(reinterpret_cast<HPointer*>(value_ptr));
}

extern "C" size_t eco_gc_stack_range_point() {
    return Allocator::instance().getRootSet().stackRangePoint();
}

extern "C" void eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask) {
    if (!base || count == 0) return;
    assert(count <= 64 && "stack root range exceeds 64-slot limit");
    Allocator::instance().getRootSet().pushStackRootRange(
        reinterpret_cast<HPointer*>(base), count, hpointer_mask);
}

extern "C" void eco_gc_restore_stack_range_point(size_t point) {
    Allocator::instance().getRootSet().restoreStackRangePoint(point);
}

//===----------------------------------------------------------------------===//
// Tag Extraction
//===----------------------------------------------------------------------===//

extern "C" uint32_t eco_get_header_tag(HPtr obj_hptr) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return 0;

    Header* header = static_cast<Header*>(obj);
    return header->tag;
}

extern "C" uint32_t eco_get_custom_ctor(HPtr obj_hptr) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return 0;

    Custom* custom = static_cast<Custom*>(obj);
    return custom->ctor;
}

/// Get the constructor tag for a value, handling both heap objects and embedded constants.
/// For heap Custom objects: returns the ctor field (16-bit constructor tag).
/// For embedded constants: returns the appropriate ctor tag:
///   - Nothing (kind=6) -> tag=1 (second constructor of Maybe)
///   - Nil (kind=5) -> tag=0 (first constructor of List)
///   - Other embedded constants -> tag=0
extern "C" uint32_t eco_get_tag(HPtr val) {
    // Null HPointer (bits == 0) is neither an embedded constant nor a valid
    // heap allocation — offset 0 in the heap is never the address of a real
    // object. Seeing this indicates an upstream bug (uninitialized field or
    // stale reference after GC). Abort loudly rather than silently reading
    // heap_base and returning a bogus tag, which can mask bugs as infinite
    // recursion (see stage-7 Dict_foldl crash, 2026-04-24).
    assert(val.bits != 0 && "eco_get_tag: null HPointer");
    HPointer hp = val.toHPointer();
    // Embedded constant? Derive the ctor tag without needing its type (see D9):
    //   - a null-cons constant (HEAP_044) -> its embedded declaration index,
    //     verbatim. MUST be tested first: the fallthrough below reads any
    //     non-Empty constant as a Bool and would misread a null-cons word.
    //   - any "empty" constant (Nil/Nothing/Unit/EmptyRec/EmptyString) -> the
    //     reserved CONSTANT_TAG; the compiler tags the matching branch the same.
    //   - a Bool constant -> its i1 value (0 = False, 1 = True), matching the
    //     IsBool tag convention (Bool normally dispatches via the i1 path; this
    //     is defense-in-depth).
    if (isConstantBits(val.bits)) {
        if (isNullConsBits(val.bits)) {
            return nullConsTagBits(val.bits);
        }
        if (isEmptyBits(val.bits)) {
            return CONSTANT_TAG;
        }
        return static_cast<uint32_t>(boolValueBits(val.bits));
    }

    // Heap object: resolve pointer and check header tag.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;

    // Get the header to check the object type.
    Header* header = static_cast<Header*>(obj);

    // Handle based on heap object type.
    switch (header->tag) {
        case Tag_Cons:
        case Tag_ConsChunk:
            // Both hybrid spine-node forms are the list Cons constructor
            // (ctor 1) for case dispatch; Nil is the Empty constant
            // (CONSTANT_TAG) and never reaches here.
            return 1;
        case Tag_Custom:
            return static_cast<Custom*>(obj)->ctor;
        default:
            return 0;
    }
}

//===----------------------------------------------------------------------===//
// List Element Access
//===----------------------------------------------------------------------===//

/// Gets the head of a Cons cell as an unboxed i64.
/// Handles both boxed and unboxed heads.
// First element of a hybrid list node — a Cons cell's head or a chunk
// view's first run slot — with its 2-bit kind. Non-allocating.
// (plans/chunked-list-representation.md §6 hybrid spines.)
static inline bool listFirstElem(void* obj, Unboxable& out, uint32_t& kind) {
    Header* hdr = getHeader(obj);
    if (hdr->tag == Tag_Cons) {
        Cons* c = static_cast<Cons*>(obj);
        out = c->head;
        kind = tupleFieldKind(hdr->unboxed, 0);
        return true;
    }
    if (hdr->tag == Tag_ConsChunk) {
        ConsChunk* cv = static_cast<ConsChunk*>(obj);
        ListBacking* lb = static_cast<ListBacking*>(
            Allocator::instance().resolve(cv->backing));
        out = lb->elems[cv->offset];
        kind = hdr->unboxed & 0x3;
        return true;
    }
    return false;
}

extern "C" int64_t eco_cons_head_i64(HPtr cons) {
    HPointer hp = cons.toHPointer();

    // Resolve the list node (Cons cell or chunk view).
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;  // Should not happen for valid list node

    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return 0;

    // Head is unboxed iff the element kind is non-zero (2-bit encoding).
    if (kind != 0) {
        return head.i;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmInt.
        void* headObj = Allocator::instance().resolve(head.p);
        if (!headObj) return 0;  // Should not happen
        return static_cast<ElmInt*>(headObj)->value;
    }
}

/// Gets the head of a Cons cell as an unboxed f64.
/// Handles both boxed and unboxed heads.
extern "C" double eco_cons_head_f64(HPtr cons) {
    HPointer hp = cons.toHPointer();

    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0.0;  // Should not happen for valid list node

    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return 0.0;

    if (kind != 0) {
        return head.f;
    } else {
        void* headObj = Allocator::instance().resolve(head.p);
        if (!headObj) return 0.0;  // Should not happen
        return static_cast<ElmFloat*>(headObj)->value;
    }
}

/// Gets the head of a Cons cell as an unboxed i16 (Elm Char).
/// Handles both boxed and unboxed heads.
extern "C" int16_t eco_cons_head_i16(HPtr cons) {
    HPointer hp = cons.toHPointer();

    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;  // Should not happen for valid list node

    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return 0;

    if (kind != 0) {
        return head.c;
    } else {
        void* headObj = Allocator::instance().resolve(head.p);
        if (!headObj) return 0;  // Should not happen
        return static_cast<int16_t>(static_cast<ElmChar*>(headObj)->value);
    }
}

/// Hybrid-spine head projection for !eco.value results: returns the raw
/// 8-byte element slot bits (boxed HPointer or unboxed primitive — the
/// caller's static typing decides, exactly like the inline
/// ConsHeadOffset load it replaces). Non-allocating; gc-leaf.
extern "C" HPtr eco_list_head_hybrid(HPtr list) {
    void* obj = Allocator::instance().resolve(list.toHPointer());
    if (!obj) return HPtr::fromBits(0);
    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return HPtr::fromBits(0);
    return HPtr::fromBits(static_cast<uint64_t>(head.i));
}

/// Hybrid-spine tail projection: a Cons cell's stored tail, or a chunk
/// view's successor (MATERIALIZING a new view when the run has more than
/// one element left — ALLOCATING, so this is statepointed, not gc-leaf).
extern "C" HPtr eco_list_tail_hybrid(HPtr list) {
    HPointer tail = alloc::listTailOf(list.toHPointer());
    return HPtr::fromBits(hpBits(tail));
}

// Materializes the list VALUE for a mixed-spine cursor position (node, idx)
// — the EcoListCursor while-rewrite keeps loop stepping allocation-free and
// pays this single view allocation only when the remaining list escapes the
// loop. idx > 0 implies the node is a chunk view (the inline step markers
// normalize cell positions to idx == 0). NOT gc-leaf: allocates.
extern "C" HPtr eco_list_pos_view(HPtr node, int64_t idx) {
    if (idx == 0) return node;
    auto& allocator = Allocator::instance();
    HPointer hp = node.toHPointer();
    ConsChunk* cv = static_cast<ConsChunk*>(allocator.resolve(hp));
    assert(getHeader(cv)->tag == Tag_ConsChunk &&
           "eco_list_pos_view: idx > 0 on a non-chunk node");
    u8 kind = static_cast<u8>(getHeader(cv)->unboxed & 0x3);
    HPointer view = alloc::consChunkView(
        cv->backing, cv->offset + static_cast<u32>(idx),
        cv->len - static_cast<u32>(idx), cv->next, kind);
    return HPtr::fromBits(hpBits(view));
}

//===----------------------------------------------------------------------===//
// List scratch stack (chunked-list Tier-B templates, plan §6 L1.3).
//
// The EcoListTemplate pass rewrites cons-accumulation loops to push each
// element here instead of allocating a cell per iteration; after the loop a
// single eco_scratch_finish builds the whole result as one dense chunk (or
// cells when small / over-cap / chunks-off — semantics identical to the loop
// it replaced). Entries are GC roots: an external root scanner evacuates and
// updates boxed entries in place, so loop bodies may allocate freely between
// pushes (this is what makes templates safe WITHOUT the §10 builder-pinning
// machinery — the growing state lives outside the heap). Nested accumulating
// loops interleave safely under mark/finish stack discipline: an inner loop
// finishes (popping to its own mark) before the outer loop pushes again.
//===----------------------------------------------------------------------===//

namespace {

struct ListScratch {
    std::vector<uint64_t> bits;
    std::vector<u8> kinds;  // 2-bit slot kind per entry (0 = boxed HPointer)
    bool registered = false;
};

ListScratch& listScratch() {
    static thread_local ListScratch s;  // matches the per-thread RootSet
    if (!s.registered) {
        s.registered = true;
        s.bits.reserve(1024);
        s.kinds.reserve(1024);
        ListScratch* sp = &s;  // thread_local has no automatic storage
        Allocator::instance().getRootSet().addExternalRootScanner(
            [sp](RootSet::EvacuateFn evac) {
                for (size_t i = 0; i < sp->bits.size(); ++i) {
                    if (sp->kinds[i] == 0 && sp->bits[i] != 0) {
                        evac(sp->bits[i]);
                    }
                }
            }, "list-scratch");
    }
    return s;
}

}  // namespace

extern "C" int64_t eco_scratch_mark(void) {
    return static_cast<int64_t>(listScratch().bits.size());
}

extern "C" void eco_scratch_push_boxed(HPtr value) {
    ListScratch& s = listScratch();
    s.bits.push_back(value.toBits());
    s.kinds.push_back(0);
}

extern "C" void eco_scratch_push_scalar(uint64_t bits, int64_t kind) {
    ListScratch& s = listScratch();
    s.bits.push_back(bits);
    s.kinds.push_back(static_cast<u8>(kind & 0x3));
}

// Discards entries above `mark` without building anything — early-failure
// paths (e.g. a failing element decoder mid-list) must rebalance the stack.
extern "C" void eco_scratch_abandon(int64_t mark) {
    ListScratch& s = listScratch();
    size_t m = static_cast<size_t>(mark);
    if (m <= s.bits.size()) {
        s.bits.resize(m);
        s.kinds.resize(m);
    }
}

// Forward variant for unwind-cons recursion (cons around a self-call
// result): pushes happen top-down in DESCENT order, so the logical result
// is entry[mark] :: entry[mark+1] :: ... :: entry[top-1] :: rest. Pops the
// entries back to `mark`.
extern "C" HPtr eco_scratch_finish_fwd(int64_t mark, HPtr rest,
                                       int64_t kind) {
    ListScratch& s = listScratch();
    size_t m = static_cast<size_t>(mark);
    size_t end = s.bits.size();
    assert(m <= end && "eco_scratch_finish_fwd: unbalanced mark");
    size_t n = end - m;
    if (n == 0) return rest;

    HPointer acc = rest.toHPointer();
    u8 k = static_cast<u8>(kind & 0x3);

    if (eco_g_list_chunks && n >= 4 && alloc::chunkChainFits(static_cast<u32>(n))) {
        StackRootGuard guard(&acc);
        u32 nn = static_cast<u32>(n);
        HPointer head = alloc::listChunkChain(nn, k, acc);
        alloc::ListChainWriter w(head);
        for (size_t i = m; i < end; ++i) {
            Unboxable v;
            v.i = static_cast<i64>(s.bits[i]);
            w.put(v);
        }
        alloc::finishChunkChain(head, nn);
        s.bits.resize(m);
        s.kinds.resize(m);
        return HPtr::fromBits(hpBits(head));
    }

    {
        StackRootGuard guard(&acc);
        for (size_t i = end; i > m; --i) {
            Unboxable v;
            v.i = static_cast<i64>(s.bits[i - 1]);
            acc = alloc::cons(v, acc, s.kinds[i - 1]);
        }
    }
    s.bits.resize(m);
    s.kinds.resize(m);
    return HPtr::fromBits(hpBits(acc));
}

// Builds the list the replaced loop would have produced: entries [mark..top)
// were pushed in cons order (each PREPENDED to the accumulator), so the
// logical result is entry[top-1] :: ... :: entry[mark] :: next. Pops the
// entries back to `mark`. `kind` is the loop's static element kind.
extern "C" HPtr eco_scratch_finish(int64_t mark, HPtr next, int64_t kind) {
    ListScratch& s = listScratch();
    size_t m = static_cast<size_t>(mark);
    size_t end = s.bits.size();
    assert(m <= end && "eco_scratch_finish: unbalanced mark");
    size_t n = end - m;
    if (n == 0) return next;

    HPointer acc = next.toHPointer();
    u8 k = static_cast<u8>(kind & 0x3);
    auto& allocator = Allocator::instance();

    if (eco_g_list_chunks && n >= 4 && alloc::chunkChainFits(static_cast<u32>(n))) {
        StackRootGuard guard(&acc);
        u32 nn = static_cast<u32>(n);
        HPointer head = alloc::listChunkChain(nn, k, acc);
        // The chain is fully allocated; the scanner kept the entries
        // current, so read them fresh and fill without further allocation.
        alloc::ListChainWriter w(head);
        for (u32 i = 0; i < nn; ++i) {
            Unboxable v;
            v.i = static_cast<i64>(s.bits[end - 1 - i]);
            w.put(v);
        }
        alloc::finishChunkChain(head, nn);
        s.bits.resize(m);
        s.kinds.resize(m);
        return HPtr::fromBits(hpBits(head));
    }

    // Small / mixed / chunks-off: exactly the cell loop the template
    // replaced. cons() may GC per step; the scanner updates the remaining
    // entries and `acc` is rooted, so each iteration reads fresh values.
    {
        StackRootGuard guard(&acc);
        for (size_t i = m; i < end; ++i) {
            Unboxable v;
            v.i = static_cast<i64>(s.bits[i]);
            acc = alloc::cons(v, acc, s.kinds[i]);
        }
    }
    s.bits.resize(m);
    s.kinds.resize(m);
    return HPtr::fromBits(hpBits(acc));
}

//===----------------------------------------------------------------------===//
// Tuple / Record / Custom / Array unboxed-primitive field access.
//
// Pattern C fix: keeping resolve + slot read inside a single runtime call
// prevents LLVM's RS4GC + later code motion from rematerialising heap
// pointer arithmetic past a statepoint and reloading from a stale address.
//
// Unlike eco_cons_head_* these are single-path: tuple/record/custom slots
// are stored in the kind matching the SSA type at construct time
// (i64 → Unboxable.i, f64 → Unboxable.f, i16 → Unboxable.c), so no dual
// boxed/unboxed dispatch is needed. Bool is always boxed at heap
// boundaries, so an i1 result here is a frontend bug and the lowering
// surfaces it via emitOpError rather than calling these helpers.
//===----------------------------------------------------------------------===//

extern "C" int64_t eco_tuple2_get0_i64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get0_i64: null resolve");
    return static_cast<Tuple2*>(obj)->a.i;
}

extern "C" int64_t eco_tuple2_get1_i64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get1_i64: null resolve");
    return static_cast<Tuple2*>(obj)->b.i;
}

extern "C" double eco_tuple2_get0_f64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get0_f64: null resolve");
    return static_cast<Tuple2*>(obj)->a.f;
}

extern "C" double eco_tuple2_get1_f64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get1_f64: null resolve");
    return static_cast<Tuple2*>(obj)->b.f;
}

extern "C" int16_t eco_tuple2_get0_i16(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get0_i16: null resolve");
    return static_cast<int16_t>(static_cast<Tuple2*>(obj)->a.c);
}

extern "C" int16_t eco_tuple2_get1_i16(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get1_i16: null resolve");
    return static_cast<int16_t>(static_cast<Tuple2*>(obj)->b.c);
}

extern "C" int64_t eco_tuple3_get0_i64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get0_i64: null resolve");
    return static_cast<Tuple3*>(obj)->a.i;
}

extern "C" int64_t eco_tuple3_get1_i64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get1_i64: null resolve");
    return static_cast<Tuple3*>(obj)->b.i;
}

extern "C" int64_t eco_tuple3_get2_i64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get2_i64: null resolve");
    return static_cast<Tuple3*>(obj)->c.i;
}

extern "C" double eco_tuple3_get0_f64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get0_f64: null resolve");
    return static_cast<Tuple3*>(obj)->a.f;
}

extern "C" double eco_tuple3_get1_f64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get1_f64: null resolve");
    return static_cast<Tuple3*>(obj)->b.f;
}

extern "C" double eco_tuple3_get2_f64(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get2_f64: null resolve");
    return static_cast<Tuple3*>(obj)->c.f;
}

extern "C" int16_t eco_tuple3_get0_i16(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get0_i16: null resolve");
    return static_cast<int16_t>(static_cast<Tuple3*>(obj)->a.c);
}

extern "C" int16_t eco_tuple3_get1_i16(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get1_i16: null resolve");
    return static_cast<int16_t>(static_cast<Tuple3*>(obj)->b.c);
}

extern "C" int16_t eco_tuple3_get2_i16(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get2_i16: null resolve");
    return static_cast<int16_t>(static_cast<Tuple3*>(obj)->c.c);
}

extern "C" int64_t eco_record_get_i64(HPtr rec, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(rec.toHPointer());
    assert(obj != nullptr && "eco_record_get_i64: null resolve");
    return static_cast<Record*>(obj)->values[field_index].i;
}

extern "C" double eco_record_get_f64(HPtr rec, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(rec.toHPointer());
    assert(obj != nullptr && "eco_record_get_f64: null resolve");
    return static_cast<Record*>(obj)->values[field_index].f;
}

extern "C" int16_t eco_record_get_i16(HPtr rec, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(rec.toHPointer());
    assert(obj != nullptr && "eco_record_get_i16: null resolve");
    return static_cast<int16_t>(static_cast<Record*>(obj)->values[field_index].c);
}

extern "C" int64_t eco_custom_get_i64(HPtr val, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(val.toHPointer());
    assert(obj != nullptr && "eco_custom_get_i64: null resolve");
    return static_cast<Custom*>(obj)->values[field_index].i;
}

extern "C" double eco_custom_get_f64(HPtr val, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(val.toHPointer());
    assert(obj != nullptr && "eco_custom_get_f64: null resolve");
    return static_cast<Custom*>(obj)->values[field_index].f;
}

extern "C" int16_t eco_custom_get_i16(HPtr val, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(val.toHPointer());
    assert(obj != nullptr && "eco_custom_get_i16: null resolve");
    return static_cast<int16_t>(static_cast<Custom*>(obj)->values[field_index].c);
}

extern "C" int64_t eco_array_get_i64(HPtr arr, int64_t index) {
    void* obj = Allocator::instance().resolve(arr.toHPointer());
    assert(obj != nullptr && "eco_array_get_i64: null resolve");
    return static_cast<ElmArray*>(obj)->elements[index].i;
}

extern "C" double eco_array_get_f64(HPtr arr, int64_t index) {
    void* obj = Allocator::instance().resolve(arr.toHPointer());
    assert(obj != nullptr && "eco_array_get_f64: null resolve");
    return static_cast<ElmArray*>(obj)->elements[index].f;
}

extern "C" int16_t eco_array_get_i16(HPtr arr, int64_t index) {
    void* obj = Allocator::instance().resolve(arr.toHPointer());
    assert(obj != nullptr && "eco_array_get_i16: null resolve");
    return static_cast<int16_t>(static_cast<ElmArray*>(obj)->elements[index].c);
}

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

// Integer exponentiation: base^exp
// Returns 0 for negative exponents (caller handles this)
extern "C" int64_t eco_int_pow(int64_t base, int64_t exp) {
    if (exp < 0) {
        // Negative exponent returns 0 (caller should prevent this,
        // but handle defensively)
        return 0;
    }
    if (exp == 0) {
        return 1;
    }

    // Binary exponentiation for efficiency
    int64_t result = 1;
    while (exp > 0) {
        if (exp & 1) {
            result *= base;
        }
        base *= base;
        exp >>= 1;
    }
    return result;
}

//===----------------------------------------------------------------------===//
// HPointer Conversion
//===----------------------------------------------------------------------===//

extern "C" void* eco_resolve_hptr(HPtr hptr) {
    void* ptr = hpointerToPtr(hptr.toBits());
#if ECO_HEAP_VALIDATE
    assert(ptr && "eco_resolve_hptr: received an embedded constant (not a heap pointer)");
#endif
    return ptr;
}

// Cold slow path for the inline-deref lowering (plan D1/P2). Generated code
// checks the object header tag inline; only when it is Tag_Forward — i.e. old-
// gen compaction has moved the object and left a forwarding tombstone that the
// fixup pass has not yet rewritten — does it call here to follow the forward
// chain. Input and output are HPointer words (== raw addresses under HEAP_028),
// typed `ptr addrspace(1)` on the codegen side so the result stays a GC-tracked
// pointer. gc-leaf: no allocation, so RS4GC inserts no statepoint around it.
//
// NB the caller only reaches this on the cold branch, but the function is
// correct for any heap HPointer (it re-checks the tag and returns the input
// unchanged when there is no forward), so it is also a safe standalone resolve.
extern "C" void* eco_follow_forward(HPtr hptr) {
    void* obj = Elm::hpToAddr(hptr.toHPointer());
    Elm::Header* hdr = static_cast<Elm::Header*>(obj);
    while (__builtin_expect(hdr->tag == Elm::Tag_Forward, 1)) {
        Elm::Forward* fwd = static_cast<Elm::Forward*>(obj);
        obj = Elm::decodeForwardPtr(fwd->header.forward_ptr, nullptr);
        hdr = static_cast<Elm::Header*>(obj);
    }
    return obj;
}

// Update an ElmArray's `header.unboxed` to the kind of the value about
// to be stored at one of its element slots. Called from the JIT lowering
// of `eco.array.set` immediately after `eco_clone_array`, so the cloned
// array's kind flag always matches what `elements[]` actually contains.
//
// Without this, an `Array.empty`-derived array (header.unboxed=0) that
// receives a raw-i64 store via `eco.array.set` keeps `unboxed=0` while
// the slot holds an int — the next minor GC then mis-traces that int
// as an HPointer and aborts on the heap-bounds check in
// NurserySpace::evacuate.
extern "C" void eco_array_set_fix_kind(HPtr array_hptr, uint32_t intended_kind) {
    HPointer hp;
    uint64_t bits = array_hptr.toBits();
    std::memcpy(&hp, &bits, sizeof(hp));
    if (hp.ptr_ind != 0) return;
    void* ptr = Allocator::instance().resolve(hp);
    if (!ptr) return;
    ElmArray* arr = static_cast<ElmArray*>(ptr);
    arr->header.unboxed = intended_kind & 0x3F;
}

extern "C" HPtr eco_clone_array(HPtr array_hptr) {
    uint64_t array_bits = array_hptr.toBits();

    // Root source array across allocation so GC updates it
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(reinterpret_cast<HPointer*>(&array_bits), 1, 1);

    void* srcPtr = hpointerToPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;

    HPointer resultHp = alloc::allocArray(len);
    // Re-resolve source (GC may have updated array_bits through the root)
    srcPtr = hpointerToPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);

    rs.restoreStackRangePoint(saved);

    void* dstPtr = Allocator::instance().resolve(resultHp);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    // Copy header flags (unboxed), length, and all elements
    dst->header.unboxed = src->header.unboxed;
    dst->length = len;
    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }

#if ECO_HEAP_VALIDATE
    // Stale-pointer barrier — only when the array claims to be boxed.
    // Unconditional validation false-positives on integer arrays whose
    // values happen to bit-decode as in-nursery addresses (e.g. a BitSet
    // chunk = 0x60082000), which is plenty common in compiler internals.
    if ((dst->header.unboxed & 0x3) == 0) {
        for (uint32_t i = 0; i < len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromHPointer(resultHp);
}
