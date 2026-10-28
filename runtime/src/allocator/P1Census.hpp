#pragma once

// A checker for the rule that a heap object, once it has survived a garbage
// collection, is never written again unless it is still a builder
// (HEAP_SNAPSHOT_001). The collector has no write barrier and the concurrent
// mark relies on survivors not changing, so a runtime or kernel function that
// writes a survivor in place corrupts the snapshot silently. This census is
// how such writes are found.
//
// A builder is an object whose header `builder` bit is set: it is still under
// construction and may be written. The header bits the collector owns (color,
// age and builder) change legitimately on survivors, so every comparison here
// ignores them.
//
// The census has three detectors. Detectors O and W are in this component;
// detector N, which hashes nursery survivors, is in `NurserySpace`, and only
// its report and fork hooks are declared here.
//
// - Detector O watches promoted objects. It records a hash of a sample of the
//   objects each minor collection or tenure job promotes into an old
//   generation, drops entries whose object is unmarked at a mark end, and
//   re-hashes the rest when asked:
//   at major or mark-cycle start, every `every()` minor collections, when the
//   heap is destroyed and at exit. A changed hash is a write after promotion.
// - Detector W watches write sites. Some mutating heap helpers (`arrayPush`,
//   `arrayPushKind`, `closureCapture`, `listChainFill`) call `noteWrite` with
//   each object they are about to write; writes through other paths are seen
//   only by detector O. A write into a non-builder that
//   is outside the nursery and the young large-object space, or inside them
//   with age 1 or more, is a violation, counted by helper name and the
//   helper's caller.
//
// The census is compiled only when `P1_CENSUS_COMPILED` is true, that is in a
// build with `ENABLE_P1_CENSUS` (the CMake option `ECO_P1_CENSUS`) or
// `ECO_HEAP_VALIDATE`. Otherwise only `mode`, which returns 0, and the hooks
// (`recordPromoted` ... `reportNow`) exist, as inline functions that do
// nothing, and the rest of this header is absent.
//
// At run time the environment variable `ECO_P1_CENSUS` picks the mode: 0 is
// off, 1 counts violations and reports them, and 2 aborts the process at the
// first violation it sees. When it is unset or empty, `ECO_SURVIVOR_WRITE_CENSUS=1`
// selects 1; otherwise the default is 2 in a build with `ECO_HEAP_VALIDATE` and
// 1 in a census-only build. Any other value of `ECO_P1_CENSUS` aborts.
//
// All census state is process-wide, guarded by one mutex, and never freed, so
// it outlives every heap and the report printed at exit. That mutex is the
// census layer of `gc::registerForkLayer` (`gc::kForkCensus`): it and detector
// N's mutex are held across `fork()`, and in the child they are re-created and
// the exit report is suppressed.

#include <cstddef>
#include <cstdint>
#include <vector>

#ifndef ENABLE_P1_CENSUS
#define ENABLE_P1_CENSUS 0
#endif
#ifndef ECO_HEAP_VALIDATE
#define ECO_HEAP_VALIDATE 0
#endif
/// Whether the census is compiled into this build: true when either
/// `ENABLE_P1_CENSUS` or `ECO_HEAP_VALIDATE` is nonzero.
#define P1_CENSUS_COMPILED (ENABLE_P1_CENSUS || ECO_HEAP_VALIDATE)

namespace Elm {
class OldGenSpace;

namespace p1 {

#if P1_CENSUS_COMPILED

/// Returns the census mode: 0 off, 1 count, 2 abort, as the file comment
/// describes. The environment is read once, the first time the census is
/// used, and a value set by `setModeForTesting` takes precedence.
int mode();
/// Overrides the mode with `m` (0, 1 or 2), or returns to the environment's
/// mode when `m` is negative. Takes no lock.
void setModeForTesting(int m);
/// Returns the sampling rate of detector O: one promoted object in `sample()`
/// is recorded, chosen by a hash of its address. It comes from
/// `ECO_P1_CENSUS_SAMPLE`, a power of two from 1 to 65536 (default 16), unless
/// `setSampleForTesting` overrides it.
uint32_t sample();
/// Returns how many minor collections pass between periodic verifications by
/// `onMinorStart`, from `ECO_P1_CENSUS_EVERY` (at least 1, default 64).
uint32_t every();
/// Overrides the sampling rate with `s`, or returns to the environment's rate
/// when `s` is 0. Takes no lock.
void setSampleForTesting(uint32_t s);

/// Returns a hash of the `size / 8` whole words at `obj`, with the header's
/// collector-owned bits (color, age, builder) treated as zero, so that, barring
/// collisions, only a write to the object's contents or the rest of its header
/// changes it.
uint64_t hashObject(const char* obj, size_t size);
/// Returns a signature whose byte `i` is a hash of word `i` of `obj`, for the
/// first eight words, or all of them if fewer, with the same header bits ignored. Comparing two
/// signatures names the first word that changed; a changed word goes unseen
/// when its byte collides.
uint64_t wordSignature(const char* obj, size_t size);

// Detector O
/// Records, in the table of old generation `og`, the hash of each sampled
/// object in `promoted`, which must hold the addresses of objects just
/// promoted into `og` with their contents final. Builders and objects of size
/// 0 or over `UINT32_MAX` are skipped. `og` is used only as a key. Does nothing
/// in mode 0.
void recordPromoted(const OldGenSpace* og, const std::vector<void*>& promoted);
/// Drops from `og`'s table every entry whose object is not marked. Must be
/// called after a mark has finished and before any sweep clears mark bits or
/// frees objects, since an unmarked entry's memory may then be reused.
void onMarkEnd(const OldGenSpace& og);
/// Re-hashes every entry of `og`'s table and counts each mismatch. In mode 2
/// a mismatch prints a violation naming `where` and aborts; in mode 1 the
/// entry takes its new hash, so one write is counted once.
void verifyOldGen(const OldGenSpace& og, const char* where);
/// Verifies `og`'s table, as `verifyOldGen` does, when `minor_count` is a
/// nonzero multiple of `every()`, and then in mode 1 prints a one-line summary
/// to stderr.
void onMinorStart(const OldGenSpace& og, uint64_t minor_count);
/// Empties `og`'s table without verifying it. Must be called before objects
/// in `og` move, since the entries name objects by address.
void invalidate(const OldGenSpace& og);
/// Verifies `og`'s table and then removes it. Must be called before `og` is
/// destroyed.
void forget(const OldGenSpace& og);

// Detector W
/// Reports that the helper named `helper` is about to write into the object
/// at `obj`, and counts a violation if `obj` is not a builder and is either
/// aged (age 1 or more) in the nursery or the young large-object space, or
/// anywhere else. In mode 2 a violation prints the write site and aborts.
///
/// The site is this function's return address, so it is the code that called
/// `noteWrite`; when the helper is inlined, that is the function it was
/// expanded in. A young large object is recognised only through the calling
/// thread's heap, so a call from a thread with no heap judges every
/// non-nursery object a violation. `helper` is kept as a key and must outlive
/// the census, which in practice means a string literal. Does nothing for a
/// null `obj` or in mode 0.
void noteWrite(void* obj, const char* helper);

// Reporting
/// Prints the census summary and its violation tables to stderr, then
/// detector N's report. It only tries the census lock, and when the lock is
/// held prints a line saying the report was skipped, so it does not wait on a
/// thread holding the census lock. Does nothing in mode 0.
void reportNow();

// Test access
/// A snapshot of the census counters. `o_entries` is the number of entries in
/// all tables at the time; `w_calls` counts every `noteWrite` that got past
/// the null and mode checks, violation or not; builder writes are counted
/// without the lock, so the count is approximate.
struct Counts {
    uint64_t o_recorded, o_checked, o_mismatched, o_dropped, o_invalidations, o_entries;
    uint64_t w_calls, w_violations;
};
/// Returns the current counters.
Counts countsForTesting();
/// Returns how many detector O mismatches were counted for objects with
/// header tag `tag`, sub-key `sub` and first differing word `word`. The
/// sub-key is a Custom's constructor, a per-evaluator id for a Closure, and 0
/// otherwise; `word` is `0xFFFF` when the signature showed no differing word.
uint64_t oHitsForTesting(int tag, uint32_t sub, uint16_t word);
/// Returns how many detector W violations were counted for helpers whose name
/// equals `helper`, compared as strings, across all write sites.
uint64_t wViolationsForTesting(const char* helper);
/// Empties every table and zeroes every counter. The mode and sampling
/// settings are kept.
void resetForTesting();

#else  // !P1_CENSUS_COMPILED

// Without the census, the functions below do nothing and `mode` returns 0.
inline int mode() { return 0; }
inline void recordPromoted(const OldGenSpace*, const std::vector<void*>&) {}
inline void onMarkEnd(const OldGenSpace&) {}
inline void verifyOldGen(const OldGenSpace&, const char*) {}
inline void onMinorStart(const OldGenSpace&, uint64_t) {}
inline void invalidate(const OldGenSpace&) {}
inline void forget(const OldGenSpace&) {}
inline void noteWrite(void*, const char*) {}
inline void reportNow() {}

#endif

} // namespace p1

#if P1_CENSUS_COMPILED
/// Prints detector N's report. When `from_signal` is true it only tries
/// detector N's lock, and prints nothing if the lock is held; otherwise it
/// waits for the lock. Defined in `NurserySpace`; `p1::reportNow` calls it
/// with `from_signal` true.
void nurseryCensusReport(bool from_signal);
/// Locks detector N's mutex before `fork()`. The census fork layer calls it
/// after locking the census mutex.
void nurseryCensusForkPrepare();
/// Unlocks detector N's mutex in the parent after `fork()`.
void nurseryCensusForkParent();
/// Re-creates detector N's mutex, unlocked, in the child after `fork()`.
void nurseryCensusForkChild();
#endif

} // namespace Elm
