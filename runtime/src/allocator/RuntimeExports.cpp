//===- RuntimeExports.cpp - C-linkage runtime function implementations ----===//
//
// Besides the functions RuntimeExports.h declares, this file holds three things that header does not
// describe. A few more C-linkage entry points, used only by generated code or by measurement scripts, are
// defined here with no declaration in the header. Several measurement censuses (cons sites, closure
// allocations, closure dispatches, generic-call reasons, call kinds) count into tables that environment
// variables switch on and that are printed to stderr at exit. And over 1,000 lines are the value
// printer behind the `eco_dbg_print*`, `eco_print_*` and `eco_value_to_string*` functions.
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
#if !defined(_WIN32)
#include <unistd.h>
#endif
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

// Returns the HPointer word for the heap or `PermanentSpace` object at `obj`, as `Allocator::wrap` makes it.
// `obj` must not be null; `wrap` asserts it.
inline HPtr ptrToHPointer(void* obj) {
    HPointer hp = Allocator::instance().wrap(obj);
    return HPtr::fromHPointer(hp);
}

// Returns the address of the object the HPointer word `val` refers to, following forward headers as
// `Allocator::resolve` does, or null if `val` is an embedded constant. `val` must not be 0, which is not a
// constant and is passed to `resolve`.
inline void* hpointerToPtr(uint64_t val) {
    HPointer hp;
    memcpy(&hp, &val, sizeof(hp));
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

// The calling thread's print destination, or null for stderr.
thread_local std::ostringstream* tl_output_stream = nullptr;

// Writes the C string `text` to the calling thread's print destination.
void output_text(const char* text) {
    if (tl_output_stream) {
        *tl_output_stream << text;
    } else {
        fputs(text, stderr);
    }
}

// Writes `fmt` formatted with `args` by `snprintf` to the print destination, cut to 255 characters.
template<typename... Args>
void output_format(const char* fmt, Args... args) {
    char buffer[256];
    snprintf(buffer, sizeof(buffer), fmt, args...);
    output_text(buffer);
}

// Writes the character `c` to the print destination.
void output_char(char c) {
    if (tl_output_stream) {
        *tl_output_stream << c;
    } else {
        fputc(c, stderr);
    }
}

// Writes `d` as Elm prints a Float, which is JavaScript's `Number::toString` (`value + ''`): `NaN`,
// `Infinity`, `-Infinity`, `0` for both zeros, and otherwise the shortest round-trip digits
// d1..dk with decimal exponent n (value = 0.d1..dk x 10^n) laid out as an integer when k <= n <= 21,
// with a point when 0 < n <= 21, as `0.000ddd` when -6 < n <= 0, and as `d[.ddd]e+N` / `e-N`
// (no exponent padding) otherwise.
void print_float(double d) {
    if (std::isinf(d)) {
        output_text(d > 0 ? "Infinity" : "-Infinity");
        return;
    }
    if (std::isnan(d)) {
        output_text("NaN");
        return;
    }
    if (d == 0.0) {
        output_text("0");
        return;
    }
    // Shortest round-trip digits and exponent from the scientific form `[-]d[.ddd]e[+-]XX`.
    char sci[40];
    auto [end, ec] = std::to_chars(sci, sci + sizeof(sci), d, std::chars_format::scientific);
    (void)ec;
    *end = '\0';
    const char* p = sci;
    bool neg = false;
    if (*p == '-') {
        neg = true;
        ++p;
    }
    char digits[32];
    int k = 0;
    for (; *p && *p != 'e'; ++p) {
        if (*p != '.') digits[k++] = *p;
    }
    int exp10 = (*p == 'e') ? std::atoi(p + 1) : 0;
    while (k > 1 && digits[k - 1] == '0') --k; // to_chars is shortest already; defensive.
    int n = exp10 + 1;

    std::string out;
    if (neg) out += '-';
    if (k <= n && n <= 21) {
        out.append(digits, k);
        out.append(static_cast<size_t>(n - k), '0');
    } else if (0 < n && n <= 21) {
        out.append(digits, n);
        out += '.';
        out.append(digits + n, k - n);
    } else if (-6 < n && n <= 0) {
        out += "0.";
        out.append(static_cast<size_t>(-n), '0');
        out.append(digits, k);
    } else {
        out += digits[0];
        if (k > 1) {
            out += '.';
            out.append(digits + 1, k - 1);
        }
        out += 'e';
        int e = n - 1;
        out += (e < 0) ? '-' : '+';
        out += std::to_string(e < 0 ? -e : e);
    }
    output_text(out.c_str());
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
// Process exit code and main thread
//===----------------------------------------------------------------------===//

namespace {
// The process's exit code, as `eco_set_exit_code` last recorded it.
std::atomic<int> g_eco_exit_code{0};
#if !defined(_WIN32)
// Whether `g_eco_main_thread` has been recorded. Its release store publishes `g_eco_main_thread`.
std::atomic<bool> g_eco_main_thread_recorded{false};
// The thread `eco_set_process_main_thread` recorded; read only after `g_eco_main_thread_recorded` is true.
pthread_t g_eco_main_thread;
#endif
} // anonymous namespace

extern "C" void eco_set_exit_code(int code) {
    g_eco_exit_code.store(code, std::memory_order_relaxed);
}

extern "C" int eco_get_exit_code() {
    return g_eco_exit_code.load(std::memory_order_relaxed);
}

#if !defined(_WIN32)
extern "C" void eco_set_process_main_thread(pthread_t thread) {
    g_eco_main_thread = thread;
    g_eco_main_thread_recorded.store(true, std::memory_order_release);
}

extern "C" pthread_t eco_process_main_thread() {
    if (g_eco_main_thread_recorded.load(std::memory_order_acquire))
        return g_eco_main_thread;
    return pthread_self();
}
#endif

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

extern "C" void* eco_alloc_with_roots(uint32_t tag, uint64_t size,
                                       uint64_t* roots, uint32_t n_roots,
                                       uint64_t hptr_mask) {
    Allocator& alloc = Allocator::instance();
    // A large object must be placed by the large-object policy, not by the size-blind bump below.
    if (__builtin_expect(size >= alloc.getLargeObjectThreshold(), 0)) {
        size_t saved = eco_gc_stack_range_point();
        if (n_roots > 0 && hptr_mask != 0) {
            eco_gc_push_stack_range(roots, n_roots, hptr_mask);
        }
        void* obj = alloc.allocate(static_cast<size_t>(size), static_cast<Tag>(tag));
        eco_gc_restore_stack_range_point(saved);
        return obj;
    }

    // allocateFast cannot collect, so nothing needs rooting, but it writes no header.
    void* obj = alloc.allocateFast(static_cast<size_t>(size));
    if (obj) {
        initHeaderForTag(getHeader(obj), static_cast<Tag>(tag),
                         static_cast<size_t>(size));
        return obj;
    }

    size_t saved = eco_gc_stack_range_point();
    if (n_roots > 0 && hptr_mask != 0) {
        eco_gc_push_stack_range(roots, n_roots, hptr_mask);
    }
    obj = alloc.allocateSlow(static_cast<size_t>(size), static_cast<Tag>(tag));
    eco_gc_restore_stack_range_point(saved);
    return obj;
}

//===----------------------------------------------------------------------===//
// Inline nursery allocation (HEAP_034)
//===----------------------------------------------------------------------===//

extern "C" void* eco_bump_state(void) {
    // Reads the heap pointer directly rather than calling Allocator::bumpState, to keep this call-free;
    // so, unlike bumpState, it does not assert that the thread has a heap.
    return Allocator::instance().getCurrentThreadHeap()->getNursery().bumpState();
}

extern "C" HPtr eco_alloc_inline_slow(uint64_t size) {
    assert(size <= 4096 && (size & 7) == 0 &&
           "eco_alloc_inline_slow: size out of inline-alloc bounds");
    // No allocateFast first: the nursery is one contiguous range (HEAP_042), so it would test the same end
    // the inline bump has just failed against.
    return ptrToHPointer(Allocator::instance().allocateSlowRaw(size));
}

extern "C" void eco_ensure_nursery_slow(uint64_t n) {
    assert(n <= 4096 && (n & 7) == 0 &&
           "eco_ensure_nursery_slow: budget out of inline-alloc bounds");
    Allocator::instance().ensureNursery(static_cast<size_t>(n));
}

extern "C" HPtr eco_alloc_custom(uint32_t ctor_id, uint32_t field_count) {
    assert(field_count > 0 &&
           "0-field custom allocation forbidden (HEAP_044): embed a null-cons constant");
    if (field_count > CUSTOM_MAX_FIELDS) ecoFatalWideObject("eco_alloc_custom", field_count);
    size_t size = wideByteSize(Tag_Custom, field_count);

    // initHeaderForTag sets size = field_count, unboxed = K and zeroes the ext words.
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
            // Their kinds are in Record::unboxed / Closure::unboxed, where the default arm's
            // header.unboxed write would not reach.
            std::fprintf(stderr, "[eco] FATAL: eco_set_unboxed on tag %u (its kinds are not in header.unboxed)\n",
                         unsigned(header->tag));
            std::abort();
        default:
            header->unboxed = static_cast<u8>(bitmap & 0x3);
            break;
    }
}

// Whether lists may be built as chunk chains rather than cons cells only. False until
// `eco_enable_list_chunks`; read by the list builders, including `eco_scratch_finish`. Never cleared.
extern "C" bool eco_g_list_chunks = false;

// Sets `eco_g_list_chunks`, so that lists built from then on may be chunk chains. Generated code calls it by
// name (EcoToLLVM, at the start of @main); RuntimeSymbols.cpp maps it for the JIT.
extern "C" void eco_enable_list_chunks(void) {
    eco_g_list_chunks = true;
}

#if ECO_CHAR_CASE_EXPANSION
extern "C" void eco_char_case_expansion_on(void) {}
#else
extern "C" void eco_char_case_expansion_off(void) {}
#endif

// Cons-site census. When the environment variable ECO_CONS_SITES is set (to anything), each
// `eco_alloc_cons` call is counted against its return address in a per-thread map, and the counts are
// printed to stderr at exit as offsets from the executable's load address. A thread's map is merged into
// the global one when the thread ends, so counting takes no lock.

// Whether cons sites are being counted: set at static initialisation when ECO_CONS_SITES is set.
extern "C" bool eco_g_cons_sites = false;

namespace {

// Guards `g_consSitesAll`.
std::mutex g_consSiteMu;
// The merged cons-site counts of the threads that have ended, keyed by return address.
std::unordered_map<void *, uint64_t> g_consSitesAll;

// Prints the merged cons-site total and the 80 most frequent sites to stderr, each as an offset from the
// executable's load address. Without /proc (on Windows) the base is 0, so sites print as addresses.
void dumpConsSites() {
    std::lock_guard<std::mutex> l(g_consSiteMu);
    // The first mapping whose line names the executable; the heap maps lower, so the first line of the
    // file is not it.
    uintptr_t base = 0;
#if !defined(_WIN32)
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
#endif
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

/**
 * One thread's cons-site counts, merged into `g_consSitesAll` when the thread ends.
 */
struct ConsSiteTls {
    std::unordered_map<void *, uint64_t> sites;
    ~ConsSiteTls() {
        std::lock_guard<std::mutex> l(g_consSiteMu);
        for (auto &kv : sites) g_consSitesAll[kv.first] += kv.second;
    }
};

// The calling thread's cons-site counts.
thread_local ConsSiteTls g_consSiteTls;

/**
 * A static initialiser that turns the cons-site census on when ECO_CONS_SITES is set.
 */
struct ConsSiteInit {
    // Sets `eco_g_cons_sites` and registers the exit dump, if ECO_CONS_SITES is set.
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

// The object whose construction runs `ConsSiteInit()`.
ConsSiteInit g_consSiteInit;

} // namespace

// Counts one cons allocation against the return address `ra` in the calling thread's cons-site map. Not
// declared in a header: generated code may call it by name.
extern "C" void eco_cons_site_tally(void *ra) {
    g_consSiteTls.sites[ra]++;
}

extern "C" HPtr eco_alloc_cons(uint64_t head, HPtr tail, uint32_t head_kind) {
    if (__builtin_expect(eco_g_cons_sites, 0))
        eco_cons_site_tally(__builtin_return_address(0));
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
    size_t size = wideByteSize(Tag_Record, field_count);

    void* obj = eco_alloc_with_roots(Tag_Record, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    Record* rec = static_cast<Record*>(obj);
    rec->header.size = field_count;   // equal to initHeaderForTag's inversion
    assert(rec->header.unboxed == extWords(field_count, RECORD_HDR_SLOTS));
    rec->unboxed = unboxed_bitmap;
    return ptrToHPointer(obj);
}

extern "C" void eco_store_record_field(HPtr record_hptr, uint32_t index, HPtr value) {
    alloc::validateNurseryHPtrBits(value.toBits());
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
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
// Allocators that leave the fields to the caller, and their field stores
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

// Returns the address of the first slot of the 2- or 3-tuple at `tuple`.
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
    // A header-only heap String would also compare unequal to "".
    if (length == 0) return HPtr::fromHPointer(alloc::emptyString());

    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;

    void* obj = eco_alloc_with_roots(Tag_String, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    // initHeaderForTag derives header.size from the rounded byte size, which counts more units than
    // `length` whenever `length` is not a multiple of 4.
    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;
    return ptrToHPointer(obj);
}

// -----------------------------------------------------------------------------
// Interning of string literals and zero-capture closures.
//
// The key is an address that stays the same for the life of the process: a literal's constant data, or a
// closure's evaluator descriptor. The cache is per thread. An interned object is allocated in
// PermanentSpace, which is never collected, so its cached word needs no root; only when PermanentSpace
// cannot take it is it an old-generation object, and then the cache slot is registered as a root of the
// thread's heap so that the object stays alive and the word follows it.
// -----------------------------------------------------------------------------
namespace {

/**
 * One thread's interning cache: the word interned for each key address, in slots whose addresses never
 * change, so that a slot can be registered as a root.
 */
struct LiteralTable {
    uint64_t generation = 0;  // The `Allocator::heapGeneration` the cache was built under.
    std::unordered_map<const void*, Elm::HPointer*> byGlobal;
    // The slots, in fixed-size chunks so that growing the table moves none of them.
    std::deque<std::array<Elm::HPointer, 64>> chunks;
    size_t nextSlot = 64;  // Next free index in the last chunk; 64 means a new chunk is needed.

    // Empties the cache if the heap has been reset since it was built (`gen` differs from `generation`):
    // a reset destroys every heap and root set, so every cached word and root registration is stale.
    void syncEpoch(uint64_t gen) {
        if (gen != generation) {
            byGlobal.clear();
            chunks.clear();
            nextSlot = 64;
            generation = gen;
        }
    }

    // Returns a new slot holding 0. The slot is not registered as a root.
    Elm::HPointer* newSlot() {
        if (nextSlot == 64) {
            chunks.emplace_back();
            nextSlot = 0;
        }
        Elm::HPointer* slot = &chunks.back()[nextSlot++];
        *slot = Elm::HPointer{};
        return slot;
    }
};

// Returns the calling thread's interning cache.
LiteralTable& literalTable() {
    static thread_local LiteralTable table;
    return table;
}

// Allocates `size` bytes (rounded up to 8) for an interned object with tag `tag`, writes its header with
// `initHeaderForTag`, and returns its address.
//
// The object is in PermanentSpace (HEAP_036), counted in its statistics. When PermanentSpace has no room,
// or the environment variable ECO_CAF_PERMANENT (read once) starts with `0`, it is allocated in the old
// generation by `Allocator::allocatePermanent` instead, where it lives only while something roots it.
// An object may go to PermanentSpace only if it refers to nothing outside it: interned Strings refer to
// nothing, and interned closures capture nothing.
inline void* allocInternObject(Elm::Tag tag, size_t size) {
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

// Returns the word interned on the calling thread for `key`, calling `alloc` to build it on a miss.
//
// `alloc` must return the new object's HPointer word. A result that is neither an embedded constant nor
// in PermanentSpace has its cache slot registered as a root (`RootSet::addRoot`).
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

// Stores the word `r` in `*slot` with a relaxed atomic store, if it is a nonzero heap word in PermanentSpace;
// otherwise leaves `*slot` alone.
//
// Only a PermanentSpace object may be published, because nothing roots the slot. Two threads may each
// intern the same literal and store different but equal Strings; either is correct. A heap reset does
// not free PermanentSpace, so a published word stays valid across it.
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
// Closure allocation census (ECO_CLOSURE_STATS)
//
// When the environment variable ECO_CLOSURE_STATS is set to anything but empty or `0`, closure allocations
// made by this file's functions are counted per evaluator pointer: `creates` for new closures (including
// interned and group-allocated ones) and `extends` for the copies `eco_pap_extend_l` makes. Closures that
// compiled code allocates inline are not counted. The counts are printed to stderr at exit, after an
// `anchor=` line giving the address of `eco_alloc_closure`, from which a reader can undo address-space
// randomisation when matching the pointers to symbols.
//
// The table is a fixed-size open-addressed array whose slots are claimed with a compare-and-swap, so any
// thread may count. A pointer that finds no slot within `kClosureStatsMaxProbe` probes is counted in the
// totals and in `g_closure_stats_overflow`, with no row of its own.
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_alloc_closure(void* func_ptr, uint32_t num_captures);

namespace {

/**
 * One evaluator's counts in the closure census. `fp` is 0 while the slot is free, and once claimed it does
 * not change.
 */
struct ClosureStatsEntry {
    std::atomic<uint64_t> fp{0};
    std::atomic<uint64_t> creates{0};
    std::atomic<uint64_t> extends{0};
};

// The number of slots in the closure census table; a power of two, so an index is masked.
constexpr size_t kClosureStatsSlots = 1 << 16;
// The number of consecutive slots tried for one evaluator before it is counted as overflow.
constexpr size_t kClosureStatsMaxProbe = 128;

// The closure census table, or null while the census is off.
ClosureStatsEntry* g_closure_stats_table = nullptr;
// The number of counts that found no slot.
std::atomic<uint64_t> g_closure_stats_overflow{0};
// The total of `creates` over all evaluators, overflow included.
std::atomic<uint64_t> g_closure_creates_total{0};
// The total of `extends` over all evaluators, overflow included.
std::atomic<uint64_t> g_closure_extends_total{0};
// Whether the closure census has been printed, so that it is printed once.
std::atomic<bool> g_closure_stats_dumped{false};

// Prints the closure census to stderr, rows ordered by `creates + extends`, on its first call; later
// calls, and any call while the census is off, print nothing. Counts made concurrently may or may not be
// included.
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

// Turns the closure census on if ECO_CLOSURE_STATS asks for it: allocates the table and registers the exit
// dump. Returns whether the census is on; it stays off if the table cannot be allocated.
bool closureStatsInit() {
    const char* e = std::getenv("ECO_CLOSURE_STATS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return false;
    g_closure_stats_table = new (std::nothrow) ClosureStatsEntry[kClosureStatsSlots]();
    if (!g_closure_stats_table) return false;
    std::atexit(closureStatsDumpImpl);
    return true;
}

// Returns whether the closure census is on, deciding it on the first call.
inline bool closureStatsEnabled() {
    static const bool enabled = closureStatsInit();
    return enabled;
}

// Counts one closure allocation for the evaluator `func_ptr` in the closure census, as an extend when
// `isExtend` and a create otherwise. Does nothing while the census is off. A null `func_ptr` is counted
// as 1, since 0 marks a free slot.
void closureStatsRecord(const void* func_ptr, bool isExtend) {
    if (!closureStatsEnabled()) return;
    uint64_t fp = reinterpret_cast<uint64_t>(func_ptr);
    if (fp == 0) fp = 1;
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
                if (expected != fp) continue; // another evaluator claimed the slot first
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

// Prints the closure census now, as the exit dump would, if the census is on and has not been printed. Not
// declared in a header: a host that does not exit normally can call it by name.
extern "C" void eco_closure_stats_dump(void) { closureStatsDumpImpl(); }

//===----------------------------------------------------------------------===//
// Closure dispatch census (ECO_DISPATCH_STATS)
//
// When the environment variable ECO_DISPATCH_STATS is set to anything but empty or `0`, calls made through
// a closure's evaluator pointer are counted per evaluator, in a table of the same shape as the closure
// census, and printed to stderr at exit with the same `anchor=` line. Three counts are kept:
//
//   sat  : calls of an evaluator with exactly its remaining arguments. There are two places in this file
//          that make such a call, `invokeSaturatedTyped` and the boxed-result path of
//          `eco_closure_call_saturated`, and each counts its call there, so every such call is counted
//          once however it was reached.
//   gen  : those of the `sat` calls that `eco_apply_closure_eval` reached (one per stage of an
//          over-application), so `gen` is at most `sat`, and the dump also prints `sat - gen` as `typed`.
//   fast : calls that compiled code made directly instead, reported by `eco_dispatch_stats_fast`.
//
// An application with too few arguments calls no evaluator and is not counted here. The dump also prints
// the generic-call reason counts kept by `eco_gencall_stats`.
//===----------------------------------------------------------------------===//

namespace {

/**
 * Which count of the dispatch census an event adds to.
 */
enum class DispatchKind { Sat, Generic, Fast };

/**
 * One evaluator's counts in the dispatch census. `fp` is 0 while the slot is free.
 */
struct DispatchStatsEntry {
    std::atomic<uint64_t> fp{0};
    std::atomic<uint64_t> sat{0};
    std::atomic<uint64_t> gen{0};
    std::atomic<uint64_t> fast{0};
};

// The number of slots in the dispatch census table; a power of two, so an index is masked.
constexpr size_t kDispatchStatsSlots = 1 << 16;
// The number of consecutive slots tried for one evaluator before it is counted as overflow.
constexpr size_t kDispatchStatsMaxProbe = 128;

// The dispatch census table, or null while the census is off.
DispatchStatsEntry* g_dispatch_stats_table = nullptr;
// The number of counts that found no slot.
std::atomic<uint64_t> g_dispatch_stats_overflow{0};
// The total of `sat` over all evaluators, overflow included.
std::atomic<uint64_t> g_dispatch_sat_total{0};
// The total of `gen` over all evaluators, overflow included.
std::atomic<uint64_t> g_dispatch_gen_total{0};
// The total of `fast` over all evaluators, overflow included.
std::atomic<uint64_t> g_dispatch_fast_total{0};
// Whether the dispatch census has been printed, so that it is printed once.
std::atomic<bool> g_dispatch_stats_dumped{false};

// The number of generic-call reason counters. A reason is reduced modulo this value.
constexpr int kGencallReasons = 16;
// The number of `eco_gencall_stats` calls per reason.
std::atomic<uint64_t> g_gencall_counts[kGencallReasons] = {};

// Prints the dispatch census and the generic-call reason counts to stderr, rows ordered by `sat`, on its
// first call, as `closureStatsDumpImpl` prints the closure census.
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
        return a.sat > b.sat;
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

// Turns the dispatch census on if ECO_DISPATCH_STATS asks for it, as `closureStatsInit` does for the
// closure census. Returns whether the census is on.
bool dispatchStatsInit() {
    const char* e = std::getenv("ECO_DISPATCH_STATS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return false;
    g_dispatch_stats_table = new (std::nothrow) DispatchStatsEntry[kDispatchStatsSlots]();
    if (!g_dispatch_stats_table) return false;
    std::atexit(dispatchStatsDumpImpl);
    return true;
}

// Returns whether the dispatch census is on, deciding it on the first call.
inline bool dispatchStatsEnabled() {
    static const bool enabled = dispatchStatsInit();
    return enabled;
}

// Counts one event of kind `kind` for the evaluator `evaluator_fp` in the dispatch census, as
// `closureStatsRecord` counts an allocation. Does nothing while the census is off.
//
// It reads no Elm heap object and never allocates from the Elm heap, so it is safe anywhere in the apply
// path; the first call may allocate the table with `new`.
void dispatchStatsRecord(const void* evaluator_fp, DispatchKind kind) {
    if (!dispatchStatsEnabled()) return;
    uint64_t fp = reinterpret_cast<uint64_t>(evaluator_fp);
    if (fp == 0) fp = 1;
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
                if (expected != fp) continue; // another evaluator claimed the slot first
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

// Prints the dispatch census now, as the exit dump would, if the census is on and has not been printed. Not
// declared in a header.
extern "C" void eco_dispatch_stats_dump(void) { dispatchStatsDumpImpl(); }

// Counts, in the dispatch census, one direct call standing in for a call through the evaluator
// `evaluator_fp`. Does nothing while the census is off; never allocates from the Elm heap. Not declared in
// a header: generated code calls it by name.
extern "C" void eco_dispatch_stats_fast(void* evaluator_fp) {
    dispatchStatsRecord(evaluator_fp, DispatchKind::Fast);
}

// Counts one generic call with the reason code `reason` (taken modulo 16), if the dispatch census is on.
// Never allocates from the Elm heap. Not declared in a header: generated code calls it by name.
extern "C" void eco_gencall_stats(int32_t reason) {
    if (!dispatchStatsEnabled()) return;
    g_gencall_counts[static_cast<uint32_t>(reason) & (kGencallReasons - 1)].fetch_add(
        1, std::memory_order_relaxed);
}

// ---- Call census ----------------------------------------------------------
//
// Instrumented generated code keeps one counter per call site, with a table of callee names and call
// kinds, and registers each table with `eco_call_census_register`. The counters are the generated code's;
// this file only prints them at exit, and only when ECO_DISPATCH_STATS is set to anything but empty or `0`.
namespace {

// The number of call kinds. A kind code at or above it is left out of the per-kind totals.
constexpr int kCallCensusKinds = 7;
// The name of each call kind, indexed by its code. The codes are the generated code's, and must match the
// order the code generator numbers them in (its `CallCensusKind`); nothing checks it.
const char* const kCallCensusKindNames[kCallCensusKinds] = {
    "elm", "kernel", "cap", "helper", "runtime", "extern", "indirect"};

/**
 * One registered call census table: `n` sites, each with a count, a callee name and a kind code. The arrays
 * belong to the code that registered them and must stay valid until the dump.
 */
struct CallCensusTable {
    const uint64_t* counts;
    const char* const* names;
    const uint8_t* kinds;
    uint64_t n;
};

// Returns the registered call census tables. Unguarded: registration must happen on one thread at a time.
// Being a function-local static, it exists before any static constructor registers a table.
std::vector<CallCensusTable>& callCensusTables() {
    static std::vector<CallCensusTable> tables;
    return tables;
}

// Whether the call census has been printed, so that it is printed once.
std::atomic<bool> g_call_census_dumped{false};

// Prints the call census to stderr on its first call, if ECO_DISPATCH_STATS is on and a table is
// registered: the totals per kind, then one row per callee name, its counts summed over every table, in
// descending count order with ties by name. Later calls print nothing.
void callCensusDumpImpl() {
    if (g_call_census_dumped.exchange(true)) return;
    const char* e = std::getenv("ECO_DISPATCH_STATS");
    if (!e || !*e || std::strcmp(e, "0") == 0) return;
    const auto& tables = callCensusTables();
    if (tables.empty()) return;

    uint64_t perKind[kCallCensusKinds] = {};
    uint64_t sites = 0;
    // One callee can have sites in several tables, and several sites in one; the row takes the kind of
    // the last site seen.
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

// Registers a call census table of `n` sites: `counts` (`uint64_t[n]`), `names` (`const char*[n]`) and
// `kinds` (`uint8_t[n]`), and the exit dump with the first table. Not declared in a header: instrumented
// generated code calls it by name.
//
// The arrays are kept, not copied, and must stay valid until the process exits. Not synchronised: calls
// must not overlap one another or the dump.
extern "C" void eco_call_census_register(const void* counts, const void* names,
                                         const void* kinds, uint64_t n) {
    auto& tables = callCensusTables();
    if (tables.empty()) std::atexit(callCensusDumpImpl);
    tables.push_back({static_cast<const uint64_t*>(counts),
                      static_cast<const char* const*>(names),
                      static_cast<const uint8_t*>(kinds), n});
}

// Prints the call census now, as the exit dump would, if it has not been printed. Not declared in a header.
extern "C" void eco_call_census_dump(void) { callCensusDumpImpl(); }

//===----------------------------------------------------------------------===//
// Kernel evaluator descriptors
//
// The descriptors `ecoDescForKernelEvaluator` interns are `calloc`ed and never freed, and the collector
// never sees them.
//===----------------------------------------------------------------------===//

namespace {

/**
 * The interning key of a kernel descriptor: the evaluator, its stage arity and its result kind.
 */
struct KernelDescKey {
    Elm::EvalFunction fn;
    unsigned arity;
    unsigned char rk;
    // Returns whether all three members are equal.
    bool operator==(const KernelDescKey& o) const {
        return fn == o.fn && arity == o.arity && rk == o.rk;
    }
};

/**
 * The hash of a `KernelDescKey`.
 */
struct KernelDescKeyHash {
    // Returns a hash of `k` combining all three of its members.
    size_t operator()(const KernelDescKey& k) const {
        return std::hash<const void*>()(reinterpret_cast<const void*>(k.fn)) * 31
             + k.arity * 7 + k.rk;
    }
};

// Guards `g_kernel_descs`.
std::mutex g_kernel_desc_mutex;
// The interned kernel descriptors.
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

    // sat[] gets stage_arity + 1 entries, so that an entry indexed by any remaining count is in bounds, but
    // only when stage_arity <= SAT_MAX_ARITY; above that it has none, on the premise that generated code
    // reads sat[] only for a closure of at most SAT_MAX_ARITY.
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
    g_kernel_descs.emplace(key, desc);
    return desc;
}

}  // namespace Elm

// Returns the byte size of a closure with `slots` value slots followed by the extension kind words a
// capacity of `max` needs, `extWords(max, CLOSURE_HDR_SLOTS)` (HEAP_078).
static inline size_t closureBytesFor(uint32_t slots, uint32_t max) {
    return sizeof(Closure)
         + (static_cast<size_t>(slots) + extWords(max, CLOSURE_HDR_SLOTS)) * sizeof(Unboxable);
}
// Prints a message naming `who` and aborts if `max` exceeds `CLOSURE_MAX_ARITY`.
static inline void closureArityCheck(uint32_t max, const char* who) {
    if (max > CLOSURE_MAX_ARITY) {
        std::fprintf(stderr, "[eco] FATAL: %s: closure arity %u exceeds %u\n",
                     who, max, CLOSURE_MAX_ARITY);
        std::abort();
    }
}
// Writes the extension kind words of the closure `c`, whose capacity is `max`, after its first `slots` value
// slots: copied from `ext`, or zeros when `ext` is null. Every one must be written, since a fresh object's
// payload is not zeroed (HEAP_077).
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
    // initHeaderForTag derives header.size from the bytes: n + K.
    size_t size = closureBytesFor(num_captures, num_captures);

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

extern "C" HPtr eco_alloc_closure_fn(void* fn, uint32_t num_captures,
                                     uint8_t result_kind) {
    const EvaluatorDesc* desc = ecoDescForKernelEvaluator(
        reinterpret_cast<EvalFunction>(fn), num_captures, result_kind);
    return eco_alloc_closure_k(const_cast<EvaluatorDesc*>(desc), num_captures,
                               result_kind);
}

// One closure can serve every evaluation because a closure that captures nothing is never written:
// `eco_pap_extend_l` copies rather than extending in place (HEAP_033).
extern "C" HPtr eco_intern_closure0(void* func_ptr, uint32_t arity,
                                    uint64_t packed) {
    assert(arity <= CLOSURE_HDR_SLOTS && "eco_intern_closure0: arity > CLOSURE_HDR_SLOTS");
    return internLiteral(func_ptr, [&]() -> HPtr {
        closureStatsRecord(func_ptr, /*isExtend=*/false);
        size_t size = sizeof(Header) + 8 + sizeof(const EvaluatorDesc*)
                    + static_cast<size_t>(arity) * sizeof(Unboxable);
        void* obj = allocInternObject(Tag_Closure, size);
        if (!obj) return HPtr::fromBits(0);
        Closure* closure = static_cast<Closure*>(obj);
        // The packed word sits at byte offset 8, after the header.
        std::memcpy(reinterpret_cast<char*>(obj) + 8, &packed,
                    sizeof(uint64_t));
        closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(func_ptr);
        // The collector reads only the first n_values slots, none here, but the allocation does not zero
        // the payload; zeroing it keeps every word of the object defined for anything that walks it whole.
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
    static_cast<ElmChar*>(obj)->value = static_cast<u32>(value);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_allocate(uint64_t size, uint32_t tag) {
    void* obj = eco_alloc_with_roots(tag, size, nullptr, 0, 0);
    return ptrToHPointer(obj);
}

//===----------------------------------------------------------------------===//
// Fast/Slow Allocation Split
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_alloc_custom_fast(uint32_t ctor_id, uint32_t field_count) {
    assert(field_count > 0 &&
           "0-field custom allocation forbidden (HEAP_044): embed a null-cons constant");
    if (field_count > CUSTOM_MAX_FIELDS) ecoFatalWideObject("eco_alloc_custom_fast", field_count);
    size_t size = wideByteSize(Tag_Custom, field_count);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    initWideHeader(getHeader(obj), Tag_Custom, field_count);
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_custom_slow(uint32_t ctor_id, uint32_t field_count) {
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

    // The caller's statepoint relocates the caller's copies of head and tail, not these by-value
    // parameters, so they are rooted here for the allocation.
    uint64_t roots[2] = { head, tail.toBits() };
    uint64_t mask = (head_kind != 0) ? 0x2 : 0x3;

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 2, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Cons);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
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

    // Rooted for the reason eco_alloc_cons_slow gives.
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

    // Rooted for the reason eco_alloc_cons_slow gives.
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

    initWideHeader(getHeader(obj), Tag_Record, field_count);
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
    elmChar->value = static_cast<u32>(value);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char_slow(uint32_t value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmChar), Tag_Char);
    if (!obj) return HPtr::fromBits(0);

    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u32>(value);

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
    // Each sibling gets room for its full capacity, not only its captures.
    size_t totalBytes = 0;
    for (uint64_t i = 0; i < numSiblings; ++i) {
        closureArityCheck(arities[i], "eco_alloc_closure_group_l");
        assert(extOffsets[i + 1] - extOffsets[i] == extWords(arities[i], CLOSURE_HDR_SLOTS) &&
               "eco_alloc_closure_group_l: ext word count != extWords(arity)");
        totalBytes += closureBytesFor(arities[i], arities[i]);
    }

    void* region = eco_gc_alloc_region_fast(totalBytes);
    if (!region) {
        region = eco_gc_alloc_region_slow(totalBytes);
    }

    // Every sibling's HPointer must be known before the edges between siblings can be written, so the
    // objects are built first and the edges second.
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
        closure->result_kind = resultKinds[i] & 0x3;
        closure->unboxed = hdrKinds[i];
        closure->evaluator = reinterpret_cast<const EvaluatorDesc*>(evaluators[i]);
        writeClosureExtWords(closure, arity, arity, extKinds + extOffsets[i]);
        closureStatsRecord(evaluators[i], /*isExtend=*/false);

        const uint32_t capStart = captureOffsets[i];
        const uint32_t capEnd = captureOffsets[i + 1];
        for (uint32_t k = capStart, slot = 0; k < capEnd; ++k, ++slot) {
            closure->values[slot].i = static_cast<i64>(captures[k]);
        }

        outClosures[i] = ptrToHPointer(obj).toBits();
        cursor += perSibling;
    }

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
    elmChar->value = static_cast<u32>(value);
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
// Stale-pointer validator
//===----------------------------------------------------------------------===//

extern "C" void eco_validate_nursery_hptr_bits(uint64_t bits) {
    alloc::validateNurseryHPtrBits(bits);
}

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

extern "C" void eco_store_field(HPtr obj_hptr, uint32_t index, HPtr value) {
    alloc::validateNurseryHPtrBits(value.toBits());
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

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
                cons->tail = hpFromBits(value_bits);
            }
            break;
        }
        case Tag_Closure: {
            // The collector traces a closure's first n_values slots only, and this store does not change
            // n_values, so the value it writes is never traced. Raising n_values to index + 1 would not
            // help either: any unwritten slot below `index` would then be traced. closureCapture appends at
            // n_values instead.
            assert(false && "eco_store_field on a Closure: use closureCapture");
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = static_cast<i64>(value_bits);
            break;
        }
        default:
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

// The largest parameter count whose all-boxed layout `getAllBoxedLayout` takes from the static table.
constexpr unsigned kStaticBoxedLayouts = 64;
// The number of result kinds, `PK_Boxed` to `PK_Char`.
constexpr unsigned kNumResultKinds = 4;

// Builds, at compile time, the all-boxed layouts for every result kind and every parameter count from 0
// to `kStaticBoxedLayouts`, indexed `[result kind][count]`.
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
// The static table of all-boxed layouts that `buildAllBoxedLayouts` builds.
constexpr auto kAllBoxedLayoutsHolder = buildAllBoxedLayouts();

// Guards `g_wide_boxed_layouts`.
std::mutex g_wide_boxed_layout_mutex;
// The all-boxed layouts of more than `kStaticBoxedLayouts` parameters, keyed `(K << 16) | n`, each a zeroed
// `4 + n`-byte buffer. Entries are never removed, so a returned layout stays valid.
std::unordered_map<uint32_t, std::unique_ptr<unsigned char[]>> g_wide_boxed_layouts;

} // anonymous namespace

namespace Elm {
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

// Writes the arguments for calling the closure `closure_bits` with the `num_newargs` arguments in
// `new_args` into `combined_args`: its captured values, then the arguments converted from the kinds
// `layout` gives them (all boxed when null) to the kinds of their slots. Returns the closure's address.
//
// The arguments must exactly fill the closure (asserted), and `combined_args` must hold `max_values`
// entries. Boxing an argument allocates and may collect, so the caller must root `closure_bits`,
// `combined_args` and the boxed entries of `new_args` first; the closure is resolved again after each
// boxing, so the returned address is current. `max_values_out` receives the capacity and `kinds_out` a
// copy of the closure's kinds.
inline Closure* spliceArgsForSaturatedCall(uint64_t& closure_bits_inout,
                                            uint64_t* new_args,
                                            uint32_t num_newargs,
                                            const EvalParamLayout* layout,
                                            void** combined_args,
                                            uint32_t& max_values_out,
                                            ClosureKinds& kinds_out);

// Calls the closure `closure_bits`, whose evaluator returns kind `K`, with its captured values and the
// `num_args` arguments in `typed_args` (kinds from `args_layout`), and writes the result, converted to
// `desired_kind`, to `result_slot` as `eco_apply_closure_eval` does. May collect.
//
// The arguments must exactly fill the closure. This function roots its own copy of `closure_bits` and the
// argument array it builds; the caller must root the boxed entries of `typed_args`.
void invokeSaturatedTyped(uint64_t closure_bits,
                          int64_t* typed_args,
                          uint32_t num_args,
                          const EvalParamLayout* args_layout,
                          uint8_t K,
                          uint8_t desired_kind,
                          void* result_slot);

// Writes the value of the boxed Int, Float or Char `boxed` to `result_slot` as the type `desired_kind`
// (1 to 3) names. `boxed` must be a heap object (asserted) of the kind `desired_kind` names; that is not
// checked, the value is read from the word after the header.
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
            uint32_t c;
            memcpy(&c, base, sizeof(c));
            *static_cast<uint32_t*>(result_slot) = c;
            break;
        }
        default:
            assert(false && "deliverPrimitiveFromBoxed: unreachable desired_kind");
            __builtin_unreachable();
    }
}

} // anonymous namespace

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
        switch (desired_kind) {
            case 0: *static_cast<HPtr*>(result_slot) = HPtr::fromBits(0); break;
            case 1: *static_cast<int64_t*>(result_slot) = 0; break;
            case 2: *static_cast<double*>(result_slot) = 0.0; break;
            case 3: *static_cast<uint32_t*>(result_slot) = 0; break;
        }
        return;
    }

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;
    uint32_t max_values = closure->max_values;
    assert(max_values <= CLOSURE_MAX_ARITY && "max_values exceeds the 11-bit field cap");
    uint32_t remaining = max_values - n_values;

    // The closure's own result kind, not the layout's: a layout's result kind comes from the call site's
    // static type, which for a curried closure can name a later stage's result rather than this one's.
    uint8_t K = closure->result_kind;
    assert(K <= 3 && "eco_apply_closure_eval: closure result_kind out of range");

    if (num_args == 0) {
        assert(desired_kind == 0 &&
               "eco_apply_closure_eval: no-op apply requires PK_Boxed desired_kind");
        *static_cast<HPtr*>(result_slot) = closure_hptr;
        return;
    }

    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    if (num_args > 0 && args_layout) {
        pushRootsByKinds(reinterpret_cast<uint64_t*>(typed_args), num_args,
                         [&](uint32_t i) { return args_layout->kinds[i]; });
    }

#if ECO_HEAP_VALIDATE
    // Resolving each boxed argument runs the resolve-time stale-pointer check, which catches a caller that
    // held an argument unrooted across an allocation.
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
        // Counted as `gen` here; invokeSaturatedTyped counts the `sat`.
        dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                            DispatchKind::Generic);
        invokeSaturatedTyped(closure_bits, typed_args, num_args, args_layout,
                             K, desired_kind, result_slot);
        ecoRootRelease(saved_range);
        return;
    }

    // Over-applied: this stage counts as `gen` here and as `sat` inside eco_closure_call_saturated, and the
    // recursive call counts the later stages. The intermediate result is wanted boxed, since it must be a
    // closure; only the last stage delivers `desired_kind`.
    dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                        DispatchKind::Generic);
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
    // Not read by the recursive call, which takes the result kind from the closure; set to match it.
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

// Returns the argument word `raw`, held as kind `callerKind`, converted to the slot kind `slotKind`
// (REP_CLOSURE_002): unchanged when the kinds match, read from its ElmInt, ElmFloat or ElmChar when a boxed
// argument goes to a primitive slot, and boxed when a primitive goes to a boxed slot.
//
// Boxing allocates and may collect, so the caller must root everything it holds. Two different primitive
// kinds are passed through unchanged.
inline uint64_t convertArgToSlotKind(uint64_t raw, uint32_t callerKind, uint32_t slotKind) {
    if (callerKind == slotKind) return raw;
    if (callerKind == 0) {
        void* hp_ptr = hpointerToPtr(raw);
        assert(hp_ptr && "eco_pap_extend_l: cannot un-box null/embedded HPointer");
        const char* base = reinterpret_cast<const char*>(hp_ptr) + sizeof(Header);
        switch (slotKind) {
            case 1: { int64_t v; memcpy(&v, base, sizeof(v)); return static_cast<uint64_t>(v); }
            case 2: { double f; memcpy(&f, base, sizeof(f)); uint64_t r; memcpy(&r, &f, sizeof(r)); return r; }
            case 3: { u32 c; memcpy(&c, base, sizeof(c)); return static_cast<uint64_t>(c); }
            default: assert(false && "unreachable slotKind"); __builtin_unreachable();
        }
    }
    if (slotKind == 0) {
        switch (callerKind) {
            case 1: return eco_alloc_int(static_cast<int64_t>(raw)).toBits();
            case 2: { double f; memcpy(&f, &raw, sizeof(f)); return eco_alloc_float(f).toBits(); }
            case 3: return eco_alloc_char(static_cast<uint32_t>(raw & 0xFFFFFFFFu)).toBits();
            default: assert(false && "unreachable callerKind"); __builtin_unreachable();
        }
    }
    // Two different primitive kinds: no conversion is defined, and the compiler is relied on not to emit one.
    return raw;
}

} // anonymous namespace

// Each argument is converted before the closure is allocated: a boxing collection would otherwise move a
// half-built closure that nothing roots.
extern "C" HPtr eco_pap_extend_l(HPtr closure_hptr, uint64_t* args, uint32_t num_newargs,
                                 const EvalParamLayout* caller_layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    Closure* old = static_cast<Closure*>(hpointerToPtr(closure_bits));
    if (!old) return HPtr::fromBits(0);

    // A copy of the kinds, which stays valid when a boxing collection moves the closure.
    ClosureKinds ks;
    snapshotClosureKinds(old, ks);
    const uint32_t old_n = old->n_values;
    const uint32_t max = old->max_values;
    const uint32_t new_n = old_n + num_newargs;
    const uint8_t rk = old->result_kind;
#if ECO_HEAP_VALIDATE
    // ecoDescForKernelEvaluator sizes sat[] from stage_arity, which must therefore be the capacity.
    assert((!old->evaluator || old->evaluator->stage_arity == max) &&
           "eco_pap_extend_l: max_values != evaluator->stage_arity");
#endif
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
    // The caller's args are rooted by the caller's kinds, the converted ones by the slot kinds; a slot not
    // yet converted is 0, which the scan skips.
    pushRootsByKinds(args, num_newargs, callerKind);
    pushRootsByKinds(conv, num_newargs,
                     [&](uint32_t i) { return closureKindAt(ks, old_n + i); });
    for (uint32_t i = 0; i < num_newargs; ++i)
        conv[i] = convertArgToSlotKind(args[i], callerKind(i), closureKindAt(ks, old_n + i));

    const uint32_t K = ks.k;
    const size_t size = sizeof(Closure) + (static_cast<size_t>(new_n) + K) * sizeof(Unboxable);
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

    // A collection in the boxing or in allocateSlow may have moved the old closure.
    old = static_cast<Closure*>(hpointerToPtr(closure_bits));
    Closure* nc = static_cast<Closure*>(obj);
    nc->n_values = new_n;
    nc->max_values = max;
    nc->result_kind = rk;
    nc->unboxed = ks.hdr;
    nc->evaluator = old->evaluator;
    for (uint32_t i = 0; i < old_n; i++) nc->values[i] = old->values[i];
    for (uint32_t i = 0; i < num_newargs; i++)
        nc->values[old_n + i].i = static_cast<i64>(conv[i]);
    // Every ext word is written, zeros included, since the payload is not zeroed (HEAP_077).
    u64* ext = reinterpret_cast<u64*>(&nc->values[new_n]);
    for (uint32_t j = 0; j < K; ++j) ext[j] = ks.ext[j];
    closureStatsRecord(reinterpret_cast<const void*>(nc->evaluator), /*isExtend=*/true);

    ecoRootRelease(saved_range);
    return ptrToHPointer(obj);
}

namespace {

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

    // A copy of the kinds, which stays valid when a boxing collection moves the closure.
    ClosureKinds& ks = kinds_out;
    snapshotClosureKinds(closure, ks);

    for (uint32_t i = 0; i < n_values; ++i) {
        combined_args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }

    // The conversions are convertArgToSlotKind's, written out here.
    for (uint32_t i = 0; i < num_newargs; ++i) {
        uint32_t slot = n_values + i;
        uint64_t closureKind = closureKindAt(ks, slot);
        uint64_t callerKind = layout ? (layout->kinds[i] & 0x3ULL) : 0ULL;
        uint64_t raw = new_args[i];
        if (closureKind == callerKind) {
        } else if (callerKind == 0 && closureKind != 0) {
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
                    u32 c;
                    memcpy(&c, base, sizeof(u32));
                    raw = static_cast<uint64_t>(c);
                    break;
                }
                default:
                    assert(false && "unreachable closureKind");
                    __builtin_unreachable();
            }
        } else if (callerKind != 0 && closureKind == 0) {
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
                    raw = eco_alloc_char(static_cast<uint32_t>(raw & 0xFFFFFFFFu)).toBits();
                    break;
                default:
                    assert(false && "unreachable callerKind");
                    __builtin_unreachable();
            }
            // The boxing may have collected and moved the closure.
            closure = static_cast<Closure*>(hpointerToPtr(closure_bits_inout));
            snapshotClosureKinds(closure, ks);
        } else {
            // Two different primitive kinds: passed through, as convertArgToSlotKind does.
        }
        combined_args[slot] = reinterpret_cast<void*>(raw);
    }

#if ECO_HEAP_VALIDATE
    // Resolving each boxed entry runs the resolve-time stale-pointer check, which catches an entry left
    // stale by a collection during the boxing above.
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

extern "C" void eco_closure_call_saturated_eval(
    HPtr closure_hptr, uint64_t* new_args, uint32_t num_newargs,
    const EvalParamLayout* layout, void* result_slot, uint8_t desired_kind) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) {
        switch (desired_kind) {
            case 0: *static_cast<HPtr*>(result_slot) = HPtr::fromBits(0); break;
            case 1: *static_cast<int64_t*>(result_slot) = 0; break;
            case 2: *static_cast<double*>(result_slot) = 0.0; break;
            case 3: *static_cast<uint32_t*>(result_slot) = 0; break;
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

    // The result kind comes from the closure, so a caller with a null layout still calls a
    // primitive-result evaluator correctly.
    Closure* hdr_closure = static_cast<Closure*>(closure_ptr);
    uint8_t K = hdr_closure->result_kind;
    if (K != 0) {
        EcoRootMark saved_range = ecoRootMark();
        ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
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

    // The argument array: on the stack up to 16 entries, alloca up to 256 (2 KiB), the heap above.
    void* stack_args[16];
    std::unique_ptr<void*[]> heap_args;
    void** combined_args = stack_args;
    if (max_values > 256) {
        heap_args.reset(new void*[max_values]);
        combined_args = heap_args.get();
    } else if (max_values > 16) {
        combined_args = static_cast<void**>(alloca(max_values * sizeof(void*)));
    }

    // Zeroed so that the root scan, which reads every boxed entry, sees 0 in those not yet written.
    memset(combined_args, 0, max_values * sizeof(void*));

    EcoRootMark saved_range = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&closure_bits));
    {
        ClosureKinds ks;
        snapshotClosureKinds(closure, ks);
        pushRootsByKinds(reinterpret_cast<uint64_t*>(combined_args), max_values,
                         [&](uint32_t i) { return closureKindAt(ks, i); });
    }
    // The splice may box an argument, and that collection must update the boxed arguments not yet copied.
    if (num_newargs > 0 && layout) {
        pushRootsByKinds(new_args, num_newargs,
                         [&](uint32_t i) { return layout->kinds[i]; });
    }

    uint32_t out_max_values = 0;
    ClosureKinds out_kinds;
    closure = spliceArgsForSaturatedCall(closure_bits, new_args, num_newargs,
                                         layout, combined_args,
                                         out_max_values, out_kinds);

    // The one evaluator call outside invokeSaturatedTyped, so it counts its own `sat`.
    dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                        DispatchKind::Sat);
    void* result = closure->evaluator->generic(combined_args);

    ecoRootRelease(saved_range);
    return HPtr::fromBits(reinterpret_cast<uint64_t>(result));
}

namespace {

void invokeSaturatedTyped(uint64_t closure_bits,
                          int64_t* typed_args,
                          uint32_t num_args,
                          const EvalParamLayout* args_layout,
                          uint8_t K,
                          uint8_t desired_kind,
                          void* result_slot) {
    Closure* closure = static_cast<Closure*>(hpointerToPtr(closure_bits));
    assert(closure && "invokeSaturatedTyped: null closure");
    // Counted before the splice: a collection moves the closure but not its evaluator.
    dispatchStatsRecord(reinterpret_cast<const void*>(closure->evaluator),
                        DispatchKind::Sat);
    uint32_t max_values = closure->max_values;

    // Sized as in eco_closure_call_saturated.
    void* stack_args[16];
    std::unique_ptr<void*[]> heap_args;
    void** combined_args = stack_args;
    if (max_values > 256) {
        heap_args.reset(new void*[max_values]);
        combined_args = heap_args.get();
    } else if (max_values > 16) {
        combined_args = static_cast<void**>(alloca(max_values * sizeof(void*)));
    }
    memset(combined_args, 0, max_values * sizeof(void*));

    // closure_bits is this function's own copy, which the caller's root does not cover.
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

    // The evaluator's return type is the one K names; calling it through any other type is undefined.
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
        case 3: {  // PK_Char (i32 code point)
            using FnT = uint32_t (*)(void**);
            uint32_t r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 3) {
                *static_cast<uint32_t*>(result_slot) = r;
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
    void* message = hpointerToPtr(message_val.toBits());

    fprintf(stderr, "Elm runtime error: ");
    if (message && alloc::isString(message)) {
        size_t len = static_cast<Header*>(message)->size;
        for (size_t i = 0; i < len; i++) {
            u16 cu = Elm::StringOps::charAt(message, static_cast<i64>(i));
            char c = (cu < 128) ? static_cast<char>(cu) : '?';
            fputc(c, stderr);
        }
    }
    fputc('\n', stderr);

    // exit, not abort: a SIGABRT handler, such as the one LLVM installs, would add its own report.
    std::exit(1);
}

//===----------------------------------------------------------------------===//
// The value printer
//
// Both printers follow Elm's `_Debug_toAnsiString` (elm/core 1.0.5, ansi off): `[a,b]` and `(a,b)` with no
// space after the comma, records as `{ a = 1, b = 2 }`, a constructor argument in parentheses when it
// contains a space and does not start with `{ ( [ < "`, Floats as JavaScript prints numbers, and Strings
// and Chars with only `\ \n \t \r \v \0` and the quote escaped.
//
// Two printers render a value. The untyped one, `print_value`, works from the heap representation alone.
// The typed one, `print_typed_value`, also reads the type graph registered by `eco_register_type_graph`,
// which gives constructor and field names and the element types of containers, and prints elm/core's
// Dict, Set and Array as `Dict.fromList [...]`, `Set.fromList [...]` and `Array.fromList [...]`. `depth`
// counts nesting, and both print `...` instead of a value nested more than kMaxPrintDepth deep.
//===----------------------------------------------------------------------===//

// Prints the boxed value `val`, nested `depth` deep, with the untyped printer.
static void print_value(uint64_t val, int depth);

// The nesting depth beyond which both printers print `...` instead of a value (Elm has no limit; this
// bounds the C++ recursion).
static constexpr int kMaxPrintDepth = 1000;

// Runs `print`, which writes one constructor argument, and writes its text as Elm's `_Debug_toAnsiString`
// does: in parentheses when it contains a space and does not start with `{`, `(`, `[`, `<` or `"`.
template <typename F>
static void print_ctor_arg(F print) {
    std::ostringstream buf;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &buf;
    print();
    tl_output_stream = prev;
    std::string str = buf.str();
    char c0 = str.empty() ? '\0' : str[0];
    bool parenless = c0 == '{' || c0 == '(' || c0 == '[' || c0 == '<' || c0 == '"' ||
                     str.find(' ') == std::string::npos;
    if (!parenless) output_char('(');
    if (tl_output_stream) {
        *tl_output_stream << str;
    } else {
        fwrite(str.data(), 1, str.size(), stderr);
    }
    if (!parenless) output_char(')');
}

// Writes the code point `c` in UTF-8; a surrogate or a value above 0x10FFFF is written as U+FFFD.
static void output_utf8(u32 c) {
    if ((c >= 0xD800 && c <= 0xDFFF) || c > 0x10FFFF) c = 0xFFFD;
    char buf[5];
    if (c < 0x80) {
        buf[0] = static_cast<char>(c);
        buf[1] = '\0';
    } else if (c < 0x800) {
        buf[0] = static_cast<char>(0xC0 | (c >> 6));
        buf[1] = static_cast<char>(0x80 | (c & 0x3F));
        buf[2] = '\0';
    } else if (c < 0x10000) {
        buf[0] = static_cast<char>(0xE0 | (c >> 12));
        buf[1] = static_cast<char>(0x80 | ((c >> 6) & 0x3F));
        buf[2] = static_cast<char>(0x80 | (c & 0x3F));
        buf[3] = '\0';
    } else {
        buf[0] = static_cast<char>(0xF0 | (c >> 18));
        buf[1] = static_cast<char>(0x80 | ((c >> 12) & 0x3F));
        buf[2] = static_cast<char>(0x80 | ((c >> 6) & 0x3F));
        buf[3] = static_cast<char>(0x80 | (c & 0x3F));
        buf[4] = '\0';
    }
    if (c == 0) {
        output_char('\0');
    } else {
        output_text(buf);
    }
}

// Writes the code point `c` as Elm's `_Debug_addSlashes` leaves it inside a literal quoted by `quote`
// (`"` for a String, `'` for a Char): `\`, newline, tab, carriage return, vertical tab, NUL and `quote`
// escaped with a backslash, every other code point as itself in UTF-8.
static void print_escaped_cp(u32 c, char quote) {
    switch (c) {
    case '\\': output_text("\\\\"); return;
    case '\n': output_text("\\n"); return;
    case '\t': output_text("\\t"); return;
    case '\r': output_text("\\r"); return;
    case '\v': output_text("\\v"); return;
    case 0: output_text("\\0"); return;
    default: break;
    }
    if (c == static_cast<u32>(quote)) {
        output_char('\\');
        output_char(quote);
        return;
    }
    output_utf8(c);
}

// Calls `f` with each code point of the String at `str` (any String form): a surrogate pair is combined,
// a lone surrogate is passed as it is.
template <typename F>
static void for_each_code_point(void* str, F f) {
    size_t len = static_cast<Header*>(str)->size;
    for (size_t i = 0; i < len; i++) {
        u32 c = Elm::StringOps::charAt(str, static_cast<i64>(i));
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            u32 lo = Elm::StringOps::charAt(str, static_cast<i64>(i + 1));
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
                i++;
            }
        }
        f(c);
    }
}

// Prints the String at `str`, any String form, without quotes or escapes, in UTF-8 (a lone surrogate as
// U+FFFD). A null `str` prints nothing.
static void print_string_content(void* str) {
    if (!str) return;
    for_each_code_point(str, [](u32 c) { output_utf8(c); });
}

// Prints the String at `str` in double quotes as Elm's Debug.toString does (`_Debug_addSlashes`): `\`,
// newline, tab, carriage return, vertical tab, NUL and `"` escaped, everything else raw in UTF-8. A null
// `str` prints `""`.
static void print_string(void* str) {
    output_char('"');
    if (str) {
        for_each_code_point(str, [](u32 c) { print_escaped_cp(c, '"'); });
    }
    output_char('"');
}

// Prints the code point `c` as it appears inside a Char literal (`_Debug_addSlashes` with `'` quoting).
static void print_char_cp(u32 c) {
    print_escaped_cp(c, '\'');
}

// Prints the Char word `c` between single quotes: its code point, or every code point of an encoded
// case-mapping result (KERN_008), so that `Char.toUpper 'ß'` prints as `'SS'`.
static void print_char(u32 c) {
    output_char('\'');
    if (Elm::CharValue::isEncoded(c)) {
        const Elm::CaseMap::Entry& e = Elm::CaseMap::entry(c);
        for (u32 i = 0; i < e.len; i++) print_char_cp(e.units[i]);
    } else {
        print_char_cp(c);
    }
    output_char('\'');
}

// Returns the primitive kind a nonzero slot kind stands for (1 Int, 2 Float, 3 Char); any other value gives
// Int. For an unboxed slot whose type in the type graph is not a primitive.
static Elm::EcoPrimKind primKindOfSlotKind(uint32_t slotKind) {
    switch (slotKind) {
    case 2: return Elm::EcoPrimKind::Float;
    case 3: return Elm::EcoPrimKind::Char;
    default: return Elm::EcoPrimKind::Int;
    }
}

// Prints the raw slot word `bits` as a value of the primitive kind `kind`. A Bool is read from bit 0, which
// serves both an unboxed 0 or 1 and a boxed Bool constant. A String is never unboxed, so it is an
// assertion failure, and prints `<unboxed-string-bug>` in a build without assertions.
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
        print_char(static_cast<u32>(bits));
        break;
    case Elm::EcoPrimKind::Bool:
        output_text((bits & 1) ? "True" : "False");
        break;
    case Elm::EcoPrimKind::String:
        assert(false && "String cannot be unboxed");
        output_text("<unboxed-string-bug>");
        break;
    case Elm::EcoPrimKind::Unit:
        output_text("()");
        break;
    }
}

// Prints `val` and returns true if it is an embedded constant; otherwise prints nothing and returns false.
//
// Without a type there is no telling which value the Empty constant stands for (Nil, Nothing, Unit, the
// empty record or String), so it prints `<empty>`; a nullary constructor prints as `<ctor n>` with its
// index, and a Bool as `True` or `False`.
static bool print_if_constant(uint64_t val) {
    if (!isConstantBits(val)) {
        return false;
    }
    if (isNullConsBits(val)) {
        output_format("<ctor %u>", nullConsTagBits(val));
    } else if (isEmptyBits(val)) {
        output_text("<empty>");
    } else {
        output_text(boolValueBits(val) ? "True" : "False");
    }
    return true;
}

// Returns whether `val` is the Empty constant, which ends a list. Unused.
static bool is_nil(uint64_t val) {
    return isEmptyBits(val);
}

// Returns whether the Custom `custom` has the shape of a list cell built as a Custom: constructor tag 1,
// two fields, the second boxed. Any Custom of that shape passes, whatever its type.
static inline bool is_list_cons(const Custom* custom) {
    return custom->ctor == 1 &&
           custom->header.size == 2 &&
           fieldKind(custom->unboxed, 1) == 0;
}

// Prints the list `val` as `[a,b,c]` (no space after the comma, as Elm prints it), its nodes being cons
// cells, chunk views or list-shaped Customs. A node of another kind, or a constant other than Empty as a tail, is printed as a marker in angle brackets, which ends
// the list.
static void print_list(uint64_t val, int depth) {
    output_char('[');

    bool first = true;
    uint64_t current = val;
    int count = 0;
    const int MAX_LIST_ITEMS = 0x7fffffff; // no cap: Elm prints every element

    while (count < MAX_LIST_ITEMS) {
        if (isConstantBits(current)) {
            if (!isEmptyBits(current)) {
                if (!first) output_char(',');
                output_text("<invalid_list_tail>");
            }
            break;
        }

        void* ptr = hpointerToPtr(current);
        if (!ptr) {
            if (!first) output_char(',');
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        if (header->tag == Tag_Custom) {
            Custom* custom = static_cast<Custom*>(ptr);
            if (!is_list_cons(custom)) {
                if (!first) output_char(',');
                output_text("<non_cons_custom>");
                break;
            }

            if (!first) {
                output_char(',');
            }
            first = false;

            switch (fieldKind(custom->unboxed, 0)) {
                case 1: output_format("%lld", (long long)custom->values[0].i); break;
                case 2: print_float(custom->values[0].f); break;
                case 3: print_char(custom->values[0].c); break;
                default: {
                    uint64_t head_val = static_cast<uint64_t>(custom->values[0].i);
                    print_value(head_val, depth + 1);
                    break;
                }
            }

            current = static_cast<uint64_t>(custom->values[1].i);
        } else if (header->tag == Tag_Cons) {
            Cons* cons = static_cast<Cons*>(ptr);

            if (!first) {
                output_char(',');
            }
            first = false;

            switch (tupleFieldKind(header->unboxed, 0)) {
                case 1: output_format("%lld", (long long)cons->head.i); break;
                case 2: print_float(cons->head.f); break;
                case 3: print_char(cons->head.c); break;
                default: {
                    uint64_t head_val = hpBits(cons->head.p);
                    print_value(head_val, depth + 1);
                    break;
                }
            }

            current = hpBits(cons->tail);
        } else if (header->tag == Tag_ConsChunk) {
            // The view's whole run, then the node after it.
            ConsChunk* cv = static_cast<ConsChunk*>(ptr);
            ListBacking* lb = static_cast<ListBacking*>(hpointerToPtr(hpBits(cv->backing)));
            u32 cap = lb->header.size;
            u32 run = cap - cv->offset;
            u32 k = (cv->len < run) ? cv->len : run;
            uint32_t kind = static_cast<uint32_t>(header->unboxed & 0x3);
            for (u32 i = 0; i < k && count < MAX_LIST_ITEMS; i++, count++) {
                if (!first) output_char(',');
                first = false;
                const Unboxable& v = lb->elems[cv->offset + i];
                switch (kind) {
                    case 1: output_format("%lld", (long long)v.i); break;
                    case 2: print_float(v.f); break;
                    case 3: print_char(v.c); break;
                    default: print_value(hpBits(v.p), depth + 1); break;
                }
            }
            current = hpBits(cv->next);
            continue; // count has been advanced per element
        } else {
            if (!first) output_char(',');
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

// Prints the slot `v` of slot kind `kind`: an Int, a Float, a Char, or for kind 0 the boxed value
// one level deeper than `depth`.
static void print_unboxable_slot(const Unboxable& v, uint32_t kind, int depth) {
    switch (kind) {
        case 1: output_format("%lld", (long long)v.i); break;
        case 2: print_float(v.f); break;
        case 3: print_char(v.c); break;
        default: print_value(static_cast<uint64_t>(v.i), depth + 1); break;
    }
}

// Prints the 2-tuple `tuple` as `(a,b)`.
static void print_tuple2(Tuple2* tuple, int depth) {
    output_char('(');
    print_unboxable_slot(tuple->a, tupleFieldKind(tuple->header.unboxed, 0), depth);
    output_char(',');
    print_unboxable_slot(tuple->b, tupleFieldKind(tuple->header.unboxed, 1), depth);
    output_char(')');
}

// Prints the 3-tuple `tuple` as `(a,b,c)`.
static void print_tuple3(Tuple3* tuple, int depth) {
    output_char('(');
    print_unboxable_slot(tuple->a, tupleFieldKind(tuple->header.unboxed, 0), depth);
    output_char(',');
    print_unboxable_slot(tuple->b, tupleFieldKind(tuple->header.unboxed, 1), depth);
    output_char(',');
    print_unboxable_slot(tuple->c, tupleFieldKind(tuple->header.unboxed, 2), depth);
    output_char(')');
}

// Prints the Custom `custom` as `Ctor<tag>` followed by its fields separated by spaces, each field in
// parentheses by Elm's rule (`print_ctor_arg`), and a field word of 0 as `<null>`.
static void print_custom(Custom* custom, int depth) {
    uint32_t ctor = custom->ctor;
    uint32_t size = custom->header.size;

    output_format("Ctor%u", ctor);

    for (uint32_t i = 0; i < size; i++) {
        output_char(' ');
        uint32_t k = customSlotKind(custom, i);
        uint64_t val = static_cast<uint64_t>(custom->values[i].i);
        print_ctor_arg([&] {
            if (k != 0) {
                print_unboxable_slot(custom->values[i], k, depth);
            } else if (val == 0) {
                output_text("<null>");
            } else {
                print_value(val, depth + 1);
            }
        });
    }
}

// Prints the Record `record` as `{ f0 = ..., f1 = ... }`; without a type there are no field names.
static void print_record(Record* record, int depth) {
    uint32_t size = record->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        output_format("f%u = ", i);

        uint32_t k = recordSlotKind(record, i);
        if (k != 0) {
            print_unboxable_slot(record->values[i], k, depth);
        } else {
            print_value(static_cast<uint64_t>(record->values[i].i), depth + 1);
        }
    }
    output_text(" }");
}

// Prints the DynRecord `dynrec` as `print_record` prints a Record, every field as boxed.
static void print_dynrecord(DynRecord* dynrec, int depth) {
    uint32_t size = dynrec->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        output_format("f%u = ", i);

        uint64_t val = hpBits(dynrec->values[i]);
        print_value(val, depth + 1);
    }
    output_text(" }");
}

// Prints the Array `array` as `Array.fromList [...]`, its elements read by the array's uniform kind.
static void print_array(ElmArray* array, int depth) {
    output_text("Array.fromList [");
    uint32_t kind = array->header.unboxed & 0x3;
    for (uint32_t i = 0; i < array->length; i++) {
        if (i > 0) output_char(',');

        if (kind != 0) {
            print_unboxable_slot(array->elements[i], kind, depth);
        } else {
            print_value(static_cast<uint64_t>(array->elements[i].i), depth + 1);
        }
    }
    output_char(']');
}

static void print_value(uint64_t val, int depth) {
    if (depth > kMaxPrintDepth) {
        output_text("...");
        return;
    }

    if (print_if_constant(val)) {
        return;
    }

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
            print_list(val, depth);
            break;
        }

        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(ptr);
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
            // All three forms keep the byte count in header.size.
            output_format("<%u bytes>", header->size);
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

extern "C" void eco_dbg_print_int(int64_t value) {
    output_format("[eco.dbg] %lld\n", (long long)value);
}

extern "C" void eco_dbg_print_float(double value) {
    output_text("[eco.dbg] ");
    print_float(value);
    output_text("\n");
}

extern "C" void eco_dbg_print_char(int32_t value) {
    output_text("[eco.dbg] ");
    print_char(static_cast<u32>(value));
    output_text("\n");
}

// The type graph the typed printer reads, or null until `eco_register_type_graph` sets it. Shared by every
// thread, unguarded.
static const Elm::EcoTypeGraph* g_type_graph = nullptr;

extern "C" void eco_register_type_graph(const void* graph) {
    g_type_graph = static_cast<const Elm::EcoTypeGraph*>(graph);
}

// Prints the boxed value `value` of type `type_id`, nested `depth` deep, with the typed printer.
//
// `type_id` must index the registered type graph (asserted); in a build without assertions an invalid one,
// or a missing graph, falls back to the untyped printer. Embedded constants are named from the type: the
// Bool, String and Unit constants of a primitive type, `{}` for a record type, and a nullary constructor
// of a custom type by its name, the Empty constant taking the type's first nullary constructor. A
// function prints as `<function>`, and a type variable through the untyped printer. A Custom whose
// constructor or field count the type does not list, or a non-Custom of a custom type, prints as
// `<internals>`, as do values of a custom type with no constructors. An unboxed field whose type is not a
// primitive is an assertion failure.
static void print_typed_value(uint64_t value, uint32_t type_id, int depth);

// Prints the boxed value `value` as a `Debug.log` label: a String without quotes, anything else with the
// untyped printer, and an embedded constant as `<null>`.
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

// Returns whether a type graph is registered and `type_id` is a String type in it.
static bool isStringType(uint32_t type_id) {
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        return false;
    }
    const Elm::EcoTypeInfo* info = &g_type_graph->types[type_id];
    return info->kind == Elm::EcoTypeKind::Primitive &&
           info->data.primitive.prim_kind == Elm::EcoPrimKind::String;
}

extern "C" void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args) {
    if (num_args == 2 && isStringType(type_ids[0])) {
        print_label(values[0]);
        output_text(": ");
        print_typed_value(values[1], type_ids[1], 0);
        output_text("\n");
        return;
    }

    for (uint32_t i = 0; i < num_args; ++i) {
        print_typed_value(values[i], type_ids[i], 0);
        output_text("\n");
    }
}

// Prints the slot word `bits` of slot kind `slotKind` (0 boxed, 1 Int, 2 Float, 3 Char) whose declared
// type is `type_id`: an unboxed slot as the primitive its type names (or its slot kind says, when the type
// is not a primitive), a boxed one with the typed printer one level deeper than `depth`.
static void print_typed_slot(uint64_t bits, uint32_t slotKind, uint32_t type_id, int depth) {
    if (slotKind != 0) {
        const Elm::EcoTypeInfo* t = &g_type_graph->types[type_id];
        if (t->kind == Elm::EcoTypeKind::Primitive) {
            printPrimitive(bits, t->data.primitive.prim_kind);
        } else {
            printPrimitive(bits, primKindOfSlotKind(slotKind));
        }
    } else {
        print_typed_value(bits, type_id, depth + 1);
    }
}

// Returns the constructor of the custom type `t` whose id is `ctor_id`, or null.
static const Elm::EcoCtorInfo* find_ctor(const Elm::EcoTypeInfo* t, uint32_t ctor_id) {
    for (uint32_t ci = 0; ci < t->data.custom.ctor_count; ++ci) {
        const Elm::EcoCtorInfo* c = &g_type_graph->ctors[t->data.custom.first_ctor + ci];
        if (c->ctor_id == ctor_id) return c;
    }
    return nullptr;
}

// The elm/core containers Elm's Debug.toString recognises by constructor name and prints as
// `Dict.fromList`, `Set.fromList` and `Array.fromList`.
enum class BuiltinContainer { None, Dict, Set, Array };

// Returns which builtin container the custom type `t` is, by its constructor names.
static BuiltinContainer builtin_container_of(const Elm::EcoTypeInfo* t) {
    if (!g_type_graph->ctors || !g_type_graph->strings) return BuiltinContainer::None;
    for (uint32_t ci = 0; ci < t->data.custom.ctor_count; ++ci) {
        const Elm::EcoCtorInfo* c = &g_type_graph->ctors[t->data.custom.first_ctor + ci];
        if (c->name_index >= g_type_graph->string_count) continue;
        const char* name = g_type_graph->strings[c->name_index];
        if (std::strcmp(name, "RBNode_elm_builtin") == 0 || std::strcmp(name, "RBEmpty_elm_builtin") == 0)
            return BuiltinContainer::Dict;
        if (std::strcmp(name, "Set_elm_builtin") == 0) return BuiltinContainer::Set;
        if (std::strcmp(name, "Array_elm_builtin") == 0) return BuiltinContainer::Array;
    }
    return BuiltinContainer::None;
}

// Prints the entries of the Dict `node` of type `dict_type_id` in key order (an in-order walk of its
// RBNode_elm_builtin color key value left right nodes), each as `(k,v)`, or only `k` when `keysOnly`,
// separated by commas; `first` says whether nothing has been printed yet.
static void print_dict_entries(uint64_t node, uint32_t dict_type_id, int depth, bool keysOnly, bool& first) {
    if (depth > kMaxPrintDepth || isConstantBits(node)) return;
    void* ptr = hpointerToPtr(node);
    if (!ptr || static_cast<Header*>(ptr)->tag != Tag_Custom) return;
    Custom* c = static_cast<Custom*>(ptr);
    const Elm::EcoCtorInfo* ci = find_ctor(&g_type_graph->types[dict_type_id], c->ctor);
    if (!ci || ci->field_count != 5 || c->header.size != 5) return;
    if (customSlotKind(c, 3) != 0 || customSlotKind(c, 4) != 0) return; // subtrees are boxed
    const Elm::EcoFieldInfo* f = &g_type_graph->fields[ci->first_field];
    print_dict_entries(static_cast<uint64_t>(c->values[3].i), f[3].type_id, depth + 1, keysOnly, first);
    if (!first) output_char(',');
    first = false;
    if (keysOnly) {
        print_typed_slot(static_cast<uint64_t>(c->values[1].i), customSlotKind(c, 1), f[1].type_id, depth);
    } else {
        output_char('(');
        print_typed_slot(static_cast<uint64_t>(c->values[1].i), customSlotKind(c, 1), f[1].type_id, depth);
        output_char(',');
        print_typed_slot(static_cast<uint64_t>(c->values[2].i), customSlotKind(c, 2), f[2].type_id, depth);
        output_char(')');
    }
    print_dict_entries(static_cast<uint64_t>(c->values[4].i), f[4].type_id, depth + 1, keysOnly, first);
}

// The type id meaning "no type": an Array whose element type the type graph does not give.
static constexpr uint32_t kNoElemType = 0xFFFFFFFFu;

// Prints the elements of the JsArray `arr`, separated by commas: with the typed printer as type `elem_type_id`
// when it is a type id (not `kNoElemType`), else with the untyped printer.
static void print_jsarray_elements(uint64_t arr, uint32_t elem_type_id, int depth, bool& first) {
    if (isConstantBits(arr)) return;
    void* ptr = hpointerToPtr(arr);
    if (!ptr || static_cast<Header*>(ptr)->tag != Tag_Array) return;
    ElmArray* a = static_cast<ElmArray*>(ptr);
    uint32_t kind = a->header.unboxed & 0x3;
    bool typed = elem_type_id < g_type_graph->type_count;
    for (uint32_t i = 0; i < a->length; i++) {
        if (!first) output_char(',');
        first = false;
        if (typed) {
            print_typed_slot(static_cast<uint64_t>(a->elements[i].i), kind, elem_type_id, depth);
        } else if (kind != 0) {
            print_unboxable_slot(a->elements[i], kind, depth);
        } else {
            print_value(static_cast<uint64_t>(a->elements[i].i), depth + 1);
        }
    }
}

// Prints the elements of an elm/core Array tree `tree` (a JsArray of `Node`s: SubTree, ctor 0, holding a
// tree, or Leaf, ctor 1, holding a JsArray of elements of type `elem_type_id`) in order, separated by commas.
static void print_array_tree(uint64_t tree, uint32_t elem_type_id, int depth, bool& first) {
    if (depth > kMaxPrintDepth || isConstantBits(tree)) return;
    void* ptr = hpointerToPtr(tree);
    if (!ptr || static_cast<Header*>(ptr)->tag != Tag_Array) return;
    ElmArray* a = static_cast<ElmArray*>(ptr);
    if ((a->header.unboxed & 0x3) != 0) return; // a tree holds boxed Nodes
    for (uint32_t i = 0; i < a->length; i++) {
        uint64_t nodeBits = static_cast<uint64_t>(a->elements[i].i);
        void* np = hpointerToPtr(nodeBits);
        if (isConstantBits(nodeBits) || !np || static_cast<Header*>(np)->tag != Tag_Custom) continue;
        Custom* node = static_cast<Custom*>(np);
        if (node->header.size != 1 || customSlotKind(node, 0) != 0) continue;
        uint64_t inner = static_cast<uint64_t>(node->values[0].i);
        if (node->ctor == 0) {
            print_array_tree(inner, elem_type_id, depth + 1, first);
        } else {
            print_jsarray_elements(inner, elem_type_id, depth + 1, first);
        }
    }
}

// Returns the element type id of the Array `c` of type `array_type_id`, or `kNoElemType`. elm/core declares
// `type JsArray a = JsArray a`, so the one field of the JsArray type's one constructor has the element type;
// the type of Array_elm_builtin's fourth field (its tail) is that JsArray.
static uint32_t array_elem_type_id(const Custom* c, uint32_t array_type_id) {
    const Elm::EcoCtorInfo* ci = find_ctor(&g_type_graph->types[array_type_id], c->ctor);
    if (!ci || ci->field_count != 4) return kNoElemType;
    uint32_t tail_type_id = g_type_graph->fields[ci->first_field + 3].type_id;
    if (tail_type_id >= g_type_graph->type_count) return kNoElemType;
    const Elm::EcoTypeInfo* tail = &g_type_graph->types[tail_type_id];
    if (tail->kind != Elm::EcoTypeKind::Custom || tail->data.custom.ctor_count != 1) return kNoElemType;
    const Elm::EcoCtorInfo* jsCtor = &g_type_graph->ctors[tail->data.custom.first_ctor];
    if (jsCtor->field_count != 1) return kNoElemType;
    return g_type_graph->fields[jsCtor->first_field].type_id;
}

// Prints `value`, of the builtin container type `which` with type id `type_id`, as Elm does:
// `Dict.fromList [(k,v),...]`, `Set.fromList [k,...]` or `Array.fromList [x,...]`. A value whose shape
// is not the container's prints as `<internals>`.
static void print_builtin_container(uint64_t value, uint32_t type_id, BuiltinContainer which, int depth) {
    bool first = true;
    switch (which) {
    case BuiltinContainer::Dict:
        output_text("Dict.fromList [");
        print_dict_entries(value, type_id, depth, false, first);
        output_char(']');
        return;
    case BuiltinContainer::Set: {
        void* ptr = isConstantBits(value) ? nullptr : hpointerToPtr(value);
        const Elm::EcoCtorInfo* ci = nullptr;
        Custom* c = nullptr;
        if (ptr && static_cast<Header*>(ptr)->tag == Tag_Custom) {
            c = static_cast<Custom*>(ptr);
            ci = find_ctor(&g_type_graph->types[type_id], c->ctor);
        }
        if (!ci || ci->field_count != 1 || c->header.size != 1 || customSlotKind(c, 0) != 0) {
            output_text("<internals>");
            return;
        }
        output_text("Set.fromList [");
        print_dict_entries(static_cast<uint64_t>(c->values[0].i),
                           g_type_graph->fields[ci->first_field].type_id, depth + 1, true, first);
        output_char(']');
        return;
    }
    case BuiltinContainer::Array: {
        void* ptr = isConstantBits(value) ? nullptr : hpointerToPtr(value);
        if (!ptr || static_cast<Header*>(ptr)->tag != Tag_Custom ||
            static_cast<Custom*>(ptr)->header.size != 4) {
            output_text("<internals>");
            return;
        }
        Custom* c = static_cast<Custom*>(ptr);
        uint32_t elem_type_id = array_elem_type_id(c, type_id);
        output_text("Array.fromList [");
        print_array_tree(static_cast<uint64_t>(c->values[2].i), elem_type_id, depth + 1, first);
        print_jsarray_elements(static_cast<uint64_t>(c->values[3].i), elem_type_id, depth + 1, first);
        output_char(']');
        return;
    }
    case BuiltinContainer::None:
        break;
    }
}

static void print_typed_value(uint64_t value, uint32_t type_id, int depth) {
    if (depth > kMaxPrintDepth) {
        output_text("...");
        return;
    }

    assert(g_type_graph && "Type graph not initialized");
    assert(g_type_graph->types && "Type graph has no types array");
    assert(type_id < g_type_graph->type_count && "Invalid type_id");
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        print_value(value, depth);
        return;
    }

    const Elm::EcoTypeInfo* typeInfo = &g_type_graph->types[type_id];

    switch (typeInfo->kind) {
    case Elm::EcoTypeKind::Primitive: {
        // A boxed primitive is a heap object, or a constant: a Bool, or the Empty constant as "" or ().
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
        uint32_t elem_type_id = typeInfo->data.list.elem_type_id;

        assert(elem_type_id < g_type_graph->type_count && "Invalid elem_type_id in List type graph");

        output_char('[');
        bool first = true;
        uint64_t current = value;
        int count = 0;
        const int MAX_LIST_ITEMS = 0x7fffffff; // no cap: Elm prints every element

        while (count < MAX_LIST_ITEMS) {
            // The only constant a list's tail can be is Empty, which is Nil here.
            if (isConstantBits(current)) {
                break;
            }

            void* ptr = hpointerToPtr(current);
            if (!ptr) break;

            Header* header = static_cast<Header*>(ptr);

            uint64_t head_val;
            uint64_t tail_val;
            // 2-bit slot kind of the head (0 boxed, 1 Int, 2 Float, 3 Char).
            uint32_t head_kind = 0;

            if (header->tag == Tag_Cons) {
                Cons* cons = static_cast<Cons*>(ptr);
                head_val = static_cast<uint64_t>(cons->head.i);
                head_kind = tupleFieldKind(cons->header.unboxed, 0);
                tail_val = hpBits(cons->tail);
            } else if (header->tag == Tag_ConsChunk) {
                // The rest of a view's run has no node of its own, so the whole run is printed here and
                // the walk goes on at the node after it.
                ConsChunk* cv = static_cast<ConsChunk*>(ptr);
                ListBacking* lb =
                    static_cast<ListBacking*>(hpointerToPtr(hpBits(cv->backing)));
                u32 cap = lb->header.size;
                u32 run = cap - cv->offset;
                u32 k = (cv->len < run) ? cv->len : run;
                uint32_t ubKind = header->unboxed & 0x3;
                bool ub = ubKind != 0;
                for (u32 i = 0; i < k && count < MAX_LIST_ITEMS; i++, count++) {
                    if (!first) output_char(',');
                    first = false;
                    uint64_t hv =
                        static_cast<uint64_t>(lb->elems[cv->offset + i].i);
                    if (ub) {
                        const Elm::EcoTypeInfo* elemType =
                            &g_type_graph->types[elem_type_id];
                        if (elemType->kind == Elm::EcoTypeKind::Primitive) {
                            printPrimitive(hv, elemType->data.primitive.prim_kind);
                        } else {
                            printPrimitive(hv, primKindOfSlotKind(ubKind));
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
                head_kind = fieldKind(custom->unboxed, 0);
                tail_val = static_cast<uint64_t>(custom->values[1].i);
            } else {
                break;
            }

            if (!first) output_char(',');
            first = false;

            if (head_kind != 0) {
                const Elm::EcoTypeInfo* elemType = &g_type_graph->types[elem_type_id];
                if (elemType->kind == Elm::EcoTypeKind::Primitive) {
                    printPrimitive(head_val, elemType->data.primitive.prim_kind);
                } else if (elemType->kind == Elm::EcoTypeKind::Polymorphic) {
                    // An element type left as a type variable: the cell's slot kind says what the head is.
                    printPrimitive(head_val, primKindOfSlotKind(head_kind));
                } else {
                    assert(false && "List head is unboxed but element type is not primitive");
                    output_format("<unboxed-non-prim:0x%llx>", (unsigned long long)head_val);
                }
            } else {
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

        assert(g_type_graph->fields && "Type graph has no fields array");
        assert(first_field + arity <= g_type_graph->field_count && "Tuple field indices out of bounds");

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
            output_char(',');
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
            output_char(',');
            // Field b
            if (tupleFieldKind(unboxed, 1) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_char(',');
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
            assert(false && "Tuple tag mismatch - value doesn't match type");
            output_text("<tuple-mismatch>");
        }
        break;
    }

    case Elm::EcoTypeKind::Record: {
        uint32_t first_field = typeInfo->data.record.first_field;
        uint32_t field_count = typeInfo->data.record.field_count;

        // The only constant of a record type is the empty record.
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

            if (g_type_graph->fields && first_field + i < g_type_graph->field_count) {
                const Elm::EcoFieldInfo* field = &g_type_graph->fields[first_field + i];

                if (g_type_graph->strings && field->name_index < g_type_graph->string_count) {
                    output_text(g_type_graph->strings[field->name_index]);
                } else {
                    output_format("f%u", i);
                }
                output_text(" = ");

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

        // A value built by kernel code need not have the shape its declared type describes, so a mismatch
        // prints `<internals>` rather than asserting.
        if (ctor_count == 0) {
            void* bp = isConstantBits(value) ? nullptr : hpointerToPtr(value);
            uint32_t btag = bp ? static_cast<Header*>(bp)->tag : 0;
            if (bp && (btag == Tag_ByteBuffer || btag == Tag_LargeByteHeader || btag == Tag_ByteBufferSlice)) {
                // Bytes, a kernel type: Elm prints `<N bytes>`.
                output_format("<%u bytes>", static_cast<Header*>(bp)->size);
            } else {
                output_text("<internals>");
            }
            break;
        }

        BuiltinContainer builtin = builtin_container_of(typeInfo);
        if (builtin != BuiltinContainer::None) {
            print_builtin_container(value, type_id, builtin, depth);
            break;
        }

        // A constant of a custom type is a nullary constructor. A null-cons word carries the constructor's
        // id (HEAP_044); the Empty constant carries none, so it is named as the first nullary constructor.
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
        if (header->tag != Tag_Custom) {
            output_text("<internals>");
            break;
        }

        Custom* custom = static_cast<Custom*>(ptr);
        uint32_t ctor_id = custom->ctor;
        uint32_t size = custom->header.size;

        assert(g_type_graph->ctors && "Type graph has no ctors array");

        // A constructor id need not be its index among the type's constructors, so they are searched.
        const Elm::EcoCtorInfo* ctor_info = nullptr;
        for (uint32_t ci = 0; ci < ctor_count; ++ci) {
            if (g_type_graph->ctors[first_ctor + ci].ctor_id == ctor_id) {
                ctor_info = &g_type_graph->ctors[first_ctor + ci];
                break;
            }
        }
        if (ctor_info == nullptr || ctor_info->field_count != size) {
            output_text("<internals>");
            break;
        }

        assert(g_type_graph->strings && "Type graph has no strings array");
        assert(ctor_info->name_index < g_type_graph->string_count &&
               "Constructor name_index out of bounds");

        output_text(g_type_graph->strings[ctor_info->name_index]);

        if (size > 0) {
            assert(g_type_graph->fields && "Type graph has no fields array");
            assert(ctor_info->first_field + size <= g_type_graph->field_count &&
                   "Field indices out of bounds");

            for (uint32_t i = 0; i < size; i++) {
                output_char(' ');

                uint64_t field_val = static_cast<uint64_t>(custom->values[i].i);
                bool is_unboxed = customSlotKind(custom, i) != 0;

                uint32_t field_type_id = g_type_graph->fields[ctor_info->first_field + i].type_id;

                assert(field_type_id < g_type_graph->type_count &&
                       "Invalid field type_id in Custom type graph");

                print_ctor_arg([&] {
                    if (is_unboxed) {
                        const Elm::EcoTypeInfo* ft = &g_type_graph->types[field_type_id];
                        assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                               "Custom field is unboxed but type is not primitive");
                        printPrimitive(field_val, ft->data.primitive.prim_kind);
                    } else {
                        print_typed_value(field_val, field_type_id, depth + 1);
                    }
                });
            }
        }
        break;
    }

    case Elm::EcoTypeKind::Function:
        output_text("<function>");
        break;

    case Elm::EcoTypeKind::Polymorphic:
        // A value of a type variable is boxed, so its heap tag says what it is.
        print_value(value, depth);
        break;
    }
}

extern "C" void eco_output_text(const char* text) {
    output_text(text);
}

extern "C" void eco_print_value(HPtr value) {
    print_value(value.toBits(), 0);
}

extern "C" void eco_print_elm_value(HPtr value) {
    uint64_t value_bits = value.toBits();
    if (print_if_constant(value_bits)) {
        return;
    }

    void* ptr = hpointerToPtr(value_bits);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    if (header->tag == Tag_Custom) {
        Custom* custom = static_cast<Custom*>(ptr);
        if (custom->ctor == 0 && custom->header.size == 1) {
            uint32_t k = static_cast<uint32_t>(fieldKind(custom->unboxed, 0));
            if (k != 0) {
                print_unboxable_slot(custom->values[0], k, 0);
            } else {
                uint64_t inner = static_cast<uint64_t>(custom->values[0].i);
                if (inner < 0x10000) {
                    output_format("%lld", (long long)inner);
                } else if (!print_if_constant(inner)) {
                    eco_print_elm_value(HPtr::fromBits(inner));
                }
            }
            return;
        }
    }

    print_value(value_bits, 0);
}

extern "C" HPtr eco_value_to_string(HPtr value) {
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    print_value(value.toBits(), 0);

    tl_output_stream = prev;

    // Allocated only after printing, which reads `value`: the allocation may move it.
    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    return HPtr::fromHPointer(strPtr);
}

extern "C" HPtr eco_value_to_string_typed(HPtr value, int64_t type_id) {
    uint64_t value_bits = value.toBits();
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    if (type_id >= 0 && g_type_graph && g_type_graph->types &&
        static_cast<uint32_t>(type_id) < g_type_graph->type_count) {
        print_typed_value(value_bits, static_cast<uint32_t>(type_id), 0);
    } else {
        print_value(value_bits, 0);
    }

    tl_output_stream = prev;

    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    return HPtr::fromHPointer(strPtr);
}

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

extern "C" void eco_safepoint() {
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

extern "C" uint32_t eco_get_tag(HPtr val) {
    // A 0 word is an uninitialised field or a stale reference; reading it as an object would return a
    // made-up tag.
    assert(val.bits != 0 && "eco_get_tag: null HPointer");
    HPointer hp = val.toHPointer();
    // The null-cons test must come first: the last line reads any other non-Empty constant as a Bool.
    if (isConstantBits(val.bits)) {
        if (isNullConsBits(val.bits)) {
            return nullConsTagBits(val.bits);
        }
        if (isEmptyBits(val.bits)) {
            return CONSTANT_TAG;
        }
        return static_cast<uint32_t>(boolValueBits(val.bits));
    }

    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Cons:
        case Tag_ConsChunk:
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

// Writes the first element of the list node `obj` to `out` and its slot kind to `kind`, and returns true,
// if `obj` is a cons cell or chunk view; otherwise returns false and writes nothing. Never allocates.
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

    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;

    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return 0;

    if (kind != 0) {
        return head.i;
    } else {
        void* headObj = Allocator::instance().resolve(head.p);
        if (!headObj) return 0;
        return static_cast<ElmInt*>(headObj)->value;
    }
}

extern "C" double eco_cons_head_f64(HPtr cons) {
    HPointer hp = cons.toHPointer();

    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0.0;

    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return 0.0;

    if (kind != 0) {
        return head.f;
    } else {
        void* headObj = Allocator::instance().resolve(head.p);
        if (!headObj) return 0.0;
        return static_cast<ElmFloat*>(headObj)->value;
    }
}

extern "C" uint32_t eco_cons_head_char(HPtr cons) {
    HPointer hp = cons.toHPointer();

    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;

    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return 0;

    if (kind != 0) {
        return head.c;
    } else {
        void* headObj = Allocator::instance().resolve(head.p);
        if (!headObj) return 0;
        return static_cast<uint32_t>(static_cast<ElmChar*>(headObj)->value);
    }
}

// Returns the raw word of the first element of the list node `list`, a cons cell or chunk view: an
// HPointer or an unboxed value, which the caller must know from the element's type. Returns 0 for a node of
// another kind. Never allocates. `list` must not be an embedded constant. Not declared in a header:
// generated code calls it by name.
extern "C" HPtr eco_list_head_hybrid(HPtr list) {
    void* obj = Allocator::instance().resolve(list.toHPointer());
    if (!obj) return HPtr::fromBits(0);
    Unboxable head;
    uint32_t kind;
    if (!listFirstElem(obj, head, kind)) return HPtr::fromBits(0);
    return HPtr::fromBits(static_cast<uint64_t>(head.i));
}

// Returns the tail of the non-empty list `list`, as `alloc::listTailOf` does: for a chunk view whose run has
// more than one element left it allocates a new view, and may collect. Not declared in a header: generated
// code calls it by name.
extern "C" HPtr eco_list_tail_hybrid(HPtr list) {
    HPointer tail = alloc::listTailOf(list.toHPointer());
    return HPtr::fromBits(hpBits(tail));
}

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
// List scratch stack
//
// The stack lives outside the heap, so it can grow while the list it will become is not yet built; its
// boxed entries are kept current by a root scanner rather than by being heap objects.
//===----------------------------------------------------------------------===//

namespace {

/**
 * One thread's list scratch stack: entry i is `bits[i]`, of slot kind `kinds[i]`.
 */
struct ListScratch {
    std::vector<uint64_t> bits;
    std::vector<u8> kinds;
    bool registered = false;  // Whether a root scanner has been registered for this stack.
    uint64_t generation = 0;  // The `Allocator::heapGeneration` it was registered under.
};

// Returns the calling thread's scratch stack, first registering its root scanner with the calling thread's
// root set if none is registered under the current heap generation, and then emptying it.
//
// A heap reset destroys the root set and its scanners but not this thread-local stack, so without the
// generation check entries pushed after a reset would never be kept current.
ListScratch& listScratchRegistered() {
    static thread_local ListScratch s;
    const uint64_t gen = Allocator::instance().heapGeneration();
    if (!s.registered || s.generation != gen) {
        s.registered = true;
        s.generation = gen;
        s.bits.clear();
        s.kinds.clear();
        s.bits.reserve(1024);
        s.kinds.reserve(1024);
        ListScratch* sp = &s;  // the lambda captures the address, valid for the thread's life
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

// Returns the calling thread's scratch stack without checking its registration, which `eco_scratch_mark`
// does at the start of every accumulation. The first call on a thread registers it.
ListScratch& listScratch() {
    static thread_local ListScratch* s = &listScratchRegistered();
    return *s;
}

}  // namespace

extern "C" int64_t eco_scratch_mark(void) {
    return static_cast<int64_t>(listScratchRegistered().bits.size());
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

extern "C" void eco_scratch_abandon(int64_t mark) {
    ListScratch& s = listScratch();
    size_t m = static_cast<size_t>(mark);
    if (m <= s.bits.size()) {
        s.bits.resize(m);
        s.kinds.resize(m);
    }
}

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
        // The chain is allocated, and the scanner kept the entries current through that, so they are read
        // only now.
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

    // Each cons may collect; the scanner keeps the entries current and `acc` is rooted, so each entry is
    // read after the previous collection.
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

extern "C" uint32_t eco_tuple2_get0_char(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get0_char: null resolve");
    return static_cast<uint32_t>(static_cast<Tuple2*>(obj)->a.c);
}

extern "C" uint32_t eco_tuple2_get1_char(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple2_get1_char: null resolve");
    return static_cast<uint32_t>(static_cast<Tuple2*>(obj)->b.c);
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

extern "C" uint32_t eco_tuple3_get0_char(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get0_char: null resolve");
    return static_cast<uint32_t>(static_cast<Tuple3*>(obj)->a.c);
}

extern "C" uint32_t eco_tuple3_get1_char(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get1_char: null resolve");
    return static_cast<uint32_t>(static_cast<Tuple3*>(obj)->b.c);
}

extern "C" uint32_t eco_tuple3_get2_char(HPtr tup) {
    void* obj = Allocator::instance().resolve(tup.toHPointer());
    assert(obj != nullptr && "eco_tuple3_get2_char: null resolve");
    return static_cast<uint32_t>(static_cast<Tuple3*>(obj)->c.c);
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

extern "C" uint32_t eco_record_get_char(HPtr rec, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(rec.toHPointer());
    assert(obj != nullptr && "eco_record_get_char: null resolve");
    return static_cast<uint32_t>(static_cast<Record*>(obj)->values[field_index].c);
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

extern "C" uint32_t eco_custom_get_char(HPtr val, uint32_t field_index) {
    void* obj = Allocator::instance().resolve(val.toHPointer());
    assert(obj != nullptr && "eco_custom_get_char: null resolve");
    return static_cast<uint32_t>(static_cast<Custom*>(obj)->values[field_index].c);
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

extern "C" uint32_t eco_array_get_char(HPtr arr, int64_t index) {
    void* obj = Allocator::instance().resolve(arr.toHPointer());
    assert(obj != nullptr && "eco_array_get_char: null resolve");
    return static_cast<uint32_t>(static_cast<ElmArray*>(obj)->elements[index].c);
}

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

extern "C" int64_t eco_int_pow(int64_t base, int64_t exp) {
    if (exp < 0) {
        return 0;
    }
    if (exp == 0) {
        return 1;
    }

    // Exponentiation by squaring.
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

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(reinterpret_cast<HPointer*>(&array_bits), 1, 1);

    void* srcPtr = hpointerToPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;

    HPointer resultHp = alloc::allocArray(len);
    // The allocation may have moved the source; the root updated array_bits.
    srcPtr = hpointerToPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);

    rs.restoreStackRangePoint(saved);

    void* dstPtr = Allocator::instance().resolve(resultHp);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    dst->header.unboxed = src->header.unboxed;
    dst->length = len;
    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }

#if ECO_HEAP_VALIDATE
    // Only a boxed array's elements are checked: an Int element can look like a nursery address.
    if ((dst->header.unboxed & 0x3) == 0) {
        for (uint32_t i = 0; i < len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromHPointer(resultHp);
}
