//===- LoweringStats.h - Phase/pass timing for eco-boot-native ------------===//
//
// Lightweight timing harness used by eco-boot-native to attribute wall-clock
// time across the compilation pipeline. There are two granularities:
//
//   - Top-level phases (frontend, MLIR parse, MLIR lowering, LLVM translation,
//     RS4GC, LLVM opt, object emit, link) — recorded via Scope RAII helpers in
//     eco-boot.cpp.
//   - Individual MLIR passes — recorded via the PassInstrumentation hook
//     installed on the lowering PassManager.
//
// Aggregated results are printed as a sorted table on shutdown.
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

class LoweringStats {
public:
    /// ECO_LOWERING_TIMELINE=1: print "[timeline] <sec> <tid> +|-<name>" to
    /// stderr at every scope / module-level MLIR pass boundary, seconds since
    /// process start, so CPU-usage samples can be mapped onto phases.
    /// No-op (one cached getenv) when unset.
    static void timelineMark(llvm::StringRef name, bool begin);

    using Clock = std::chrono::steady_clock;
    using Duration = Clock::duration;

    /// Add `duration` to the bucket for `name`. The same name may be recorded
    /// multiple times — durations accumulate and the call count is tracked.
    void record(llvm::StringRef name, Duration duration);

    /// RAII helper: starts the clock on construction, records on destruction.
    /// Used for top-level phases in eco-boot.cpp.
    class Scope {
    public:
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

    /// Print a two-section table: top-level phases first, then MLIR passes,
    /// each sorted by descending elapsed time.
    void print(llvm::raw_ostream &os) const;

    /// Build a PassInstrumentation that records each MLIR pass into this
    /// stats object via recordPass(). Install via
    /// `pm.addInstrumentation(stats.makePassInstrumentation())`.
    std::unique_ptr<mlir::PassInstrumentation> makePassInstrumentation();

    struct Entry {
        Duration total{};
        uint64_t count = 0;
    };

    /// Append to the per-MLIR-pass table. Public so the (anonymous-namespace)
    /// PassInstrumentation hook in LoweringStats.cpp can call it without
    /// needing a friend declaration that wouldn't match the unnamed type.
    void recordPass(llvm::StringRef name, Duration duration);

    LoweringStats();

private:
    /// Plan 07 P1: per-thread commutative shards. record()/recordPass() add
    /// into the calling thread's shard without a lock; print() merges every
    /// shard by summing (order-independent). The shards are owned here, so a
    /// shard outlives its thread (EcoSplit workers exit before the banner).
    struct Shard {
        llvm::StringMap<Entry> phases;
        llvm::StringMap<Entry> passes;
    };
    Shard &localShard();

    mutable std::mutex mu_;  // guards shards_ (registration + print)
    std::vector<std::unique_ptr<Shard>> shards_;
    const uint64_t gen_;     // unique per object: thread caches key on it
};

} // namespace eco

#endif // ECO_LOWERING_STATS_H
