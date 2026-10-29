//===- LoweringStats.h - Wall-clock phase and MLIR pass timing ------------===//
//
// A compiler driver needs to know where its compile time goes, and this
// component measures it: it adds up wall-clock time under names and prints the
// totals as a table.
//
// Time is recorded at two granularities, kept in two separate tables. A
// *phase* is any span of work a caller chooses to name, timed with a `Scope`
// or reported with `record`. An *MLIR pass* is one run of a pass, timed by the
// `mlir::PassInstrumentation` that `makePassInstrumentation` builds. A name
// recorded more than once accumulates: its time is the sum and its count is
// the number of recordings. Phases and passes may overlap in time, so neither
// table's total is a partition of the other.
//
// Recording is meant to happen on many threads at once. Each thread adds into
// its own shard of the tables without taking a lock. The lock is taken when a
// thread records into a `LoweringStats` other than the one it last recorded
// into, which registers a new shard, and by `print`, which merges the shards by
// summing. Summing does not depend on order, so the printed numbers do not
// depend on how the work was scheduled. The price is that `print` must not run
// while any thread may still be recording.
//
// Separately, setting the environment variable `ECO_LOWERING_TIMELINE` makes
// every phase timed by a `Scope` and every run of a pass on a module also
// write a begin and an end line to stderr, so that external CPU-usage samples
// can be lined up with them. A pass run that fails writes only its begin line.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_LOWERING_STATS_H
#define ECO_LOWERING_STATS_H

#include "mlir/Pass/PassInstrumentation.h"

#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/raw_ostream.h"

#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace eco {

/**
 * A set of accumulated wall-clock timings for named phases and MLIR passes.
 *
 * An object is created empty and cannot be copied or moved. A new object
 * starts empty even at the address of a destroyed one.
 */
class LoweringStats {
public:
    // Writes the line `[timeline] <seconds> <thread id> +<name>` (or `-<name>`
    // when `begin` is false) to stderr, if the environment variable
    // `ECO_LOWERING_TIMELINE` is set to any value; otherwise does nothing.
    //
    // The seconds are measured from the static initialisation of this
    // component, and `name` is written with surrounding whitespace trimmed.
    // Each line is written with a single `write` call, so that lines from
    // concurrent threads are normally not interleaved. The environment is read
    // once per process.
    static void timelineMark(llvm::StringRef name, bool begin);

    // The monotonic clock all timings are taken on.
    using Clock = std::chrono::steady_clock;
    // A span of time on `Clock`.
    using Duration = Clock::duration;

    // Adds `duration` to the phase named `name` and counts one more recording
    // of it. May be called from several threads at once, but not while
    // `print` runs.
    void record(llvm::StringRef name, Duration duration);

    /**
     * A timed phase, running from construction until destruction.
     *
     * The destructor records the elapsed time as one phase recording under the
     * name given at construction. Both ends are also timeline marks (see
     * `timelineMark`). A `Scope` keeps a reference to its `LoweringStats`,
     * which must outlive it. It cannot be copied.
     */
    class Scope {
    public:
        // Starts timing a phase named `name` in `stats`. `name` is copied.
        Scope(LoweringStats &stats, llvm::StringRef name)
            : stats_(stats), name_(name.str()), start_(Clock::now()) {
            timelineMark(name_, /*begin=*/true);
        }
        ~Scope() {
            stats_.record(name_, Clock::now() - start_);
            timelineMark(name_, /*begin=*/false);
        }

        Scope(const Scope &) = delete;
        Scope &operator=(const Scope &) = delete;

    private:
        LoweringStats &stats_;
        std::string name_;
        Clock::time_point start_;
    };

    // Writes the merged totals to `os` as two tables, phases and then MLIR
    // passes, each sorted by descending time, with a count and a percentage
    // per name. Both tables take their percentages against the sum of all
    // phases, or against their own sum if no phase time was recorded. A table
    // with no entries is left out.
    //
    // Must not be called while any thread may still be recording into this
    // object.
    void print(llvm::raw_ostream &os) const;

    // Returns an instrumentation that, installed on a pass manager, records
    // the wall-clock time of every pass run into the MLIR pass table under the
    // pass's name, including runs that fail. A pass run on a `ModuleOp` also
    // writes a begin timeline mark, and an end mark unless the run fails.
    //
    // The instrumentation keeps a reference to this object, which must
    // outlive it.
    std::unique_ptr<mlir::PassInstrumentation> makePassInstrumentation();

    /**
     * The accumulated time and number of recordings for one name.
     */
    struct Entry {
        Duration total{};
        uint64_t count = 0;
    };

    // Adds `duration` to the MLIR pass named `name` and counts one more
    // recording of it. The same thread rules apply as for `record`.
    void recordPass(llvm::StringRef name, Duration duration);

    // Creates an object with no recordings.
    LoweringStats();

private:
    /**
     * The part of both tables written by one thread. Only that thread writes
     * it; it is owned here, so it outlives the thread.
     */
    struct Shard {
        llvm::StringMap<Entry> phases;
        llvm::StringMap<Entry> passes;
    };
    // Returns the calling thread's shard of this object, creating and
    // registering one on the thread's first call since it last used another
    // `LoweringStats`. The reference lasts as long as this object.
    Shard &localShard();

    // Guards `shards_`. Mutable so that the `const` `print` can take it.
    mutable std::mutex mu_;
    std::vector<std::unique_ptr<Shard>> shards_;
    // Identifier unique to this object within the process; each thread's
    // cached shard pointer is valid only while its cached identifier matches.
    const uint64_t gen_;
};

} // namespace eco

#endif // ECO_LOWERING_STATS_H
