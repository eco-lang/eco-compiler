#pragma once

// threaded-gc-04 (plans/threaded-gc-04-frozen-published-heap.md): the P1
// census. P1 / HEAP_SNAPSHOT_001: no runtime or kernel code writes a field or
// header of a heap object after the object has survived a GC, unless it
// carries builder == 1.
//
// Compiled only when P1_CENSUS_COMPILED (a -DECO_P1_CENSUS=ON census build, or
// any ECO_HEAP_VALIDATE build). Production and stats builds compile none of
// it: every entry point below is an empty inline there.
//
// Three detectors:
//   N  nursery survivors  (NurserySpace::censusRecord/censusCheck, phase 0's)
//   O  old-gen promoted objects: a sampled table of {addr, size, hash},
//      recorded after the drain of the minor that promotes them, pruned to
//      marked objects at every mark end, verified at every major start,
//      every ECO_P1_CENSUS_EVERY minors and at exit
//   W  write sites: the mutating heap helpers report every write; a write
//      into an aged (age >= 1) or non-nursery non-builder object is keyed by
//      the caller's return address
//
// Runtime mode ECO_P1_CENSUS: 0 off, 1 count (report only), 2 abort on the
// first violation (the tripwire). Default: 2 in validate builds, 1 in census
// builds. ECO_SURVIVOR_WRITE_CENSUS=1 is an alias for mode 1.

#include <cstddef>
#include <cstdint>
#include <vector>

#ifndef ENABLE_P1_CENSUS
#define ENABLE_P1_CENSUS 0
#endif
#ifndef ECO_HEAP_VALIDATE
#define ECO_HEAP_VALIDATE 0
#endif
#define P1_CENSUS_COMPILED (ENABLE_P1_CENSUS || ECO_HEAP_VALIDATE)

namespace Elm {
class OldGenSpace;

namespace p1 {

#if P1_CENSUS_COMPILED

// 0 off, 1 count, 2 abort. Read once from the environment (see above).
int mode();
// Test override: 0/1/2, or -1 to return to the environment value.
void setModeForTesting(int m);
// Old-gen table sampling (ECO_P1_CENSUS_SAMPLE, power of two, default 16)
// and the periodic verify interval (ECO_P1_CENSUS_EVERY, default 64 minors).
uint32_t sample();
uint32_t every();
void setSampleForTesting(uint32_t s);   // 0 = back to the environment value

// Hash of an object's words with the header's GC-owned bits (color, age,
// builder) masked to zero. Shared by detectors N and O.
uint64_t hashObject(const char* obj, size_t size);
// Per-word signature: byte i = hash of word i (first 8 words), used to
// report the first differing word without keeping a byte copy.
uint64_t wordSignature(const char* obj, size_t size);

// ---- Detector O ----
// After the drain of a minor GC: record a sample of this cycle's promotions.
void recordPromoted(const OldGenSpace* og, const std::vector<void*>& promoted);
// Mark end (OldGenSpace::finalizeMetaAfterMark, BEFORE any sweep clears bits):
// drop entries whose object is not marked.
void onMarkEnd(const OldGenSpace& og);
// Re-hash every entry of `og`'s table. `where` names the call site.
void verifyOldGen(const OldGenSpace& og, const char* where);
// Minor-GC start: verify every ECO_P1_CENSUS_EVERY minors and print a summary.
void onMinorStart(const OldGenSpace& og, uint64_t minor_count);
// Old-gen compaction is about to move objects: drop the table.
void invalidate(const OldGenSpace& og);
// The heap is being destroyed: verify, then drop its table.
void forget(const OldGenSpace& og);

// ---- Detector W ----
// Called by every mutating heap helper with the object it is about to write.
// Out of line and noinline: __builtin_return_address(0) inside it is the
// helper's call site (the kernel function the inline helper was expanded in).
void noteWrite(void* obj, const char* helper);

// ---- Reporting ----
// The summary + tables to stderr. try_lock only: safe to call from the
// signal-path stats print (prints "busy" if the census lock is held).
void reportNow();

// ---- Test access ----
struct Counts {
    uint64_t o_recorded, o_checked, o_mismatched, o_dropped, o_invalidations, o_entries;
    uint64_t w_calls, w_violations;
};
Counts countsForTesting();
uint64_t oHitsForTesting(int tag, uint32_t sub, uint16_t word);
uint64_t wViolationsForTesting(const char* helper);
void resetForTesting();

#else  // !P1_CENSUS_COMPILED

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
// Detector N's report (NurserySpace.cpp); reportNow() prints it too.
void nurseryCensusReport(bool from_signal);
// CR-032 (HEAP_075): detector N's mutex, held across fork() by the census layer
// (P1Census.cpp) next to the census mutex; the child re-creates it.
void nurseryCensusForkPrepare();
void nurseryCensusForkParent();
void nurseryCensusForkChild();
#endif

} // namespace Elm
