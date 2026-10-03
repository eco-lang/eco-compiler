//===- LoweringStats.cpp - Phase/pass timing for eco-boot-native ----------===//
#include "LoweringStats.h"

#include <atomic>

#include "mlir/Pass/Pass.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/FormatVariadic.h"

#include <algorithm>
#include <cstdlib>
#include <unistd.h>
#include "mlir/IR/BuiltinOps.h"
#include <unordered_map>
#include <vector>

using namespace mlir;

namespace eco {

namespace {
const LoweringStats::Clock::time_point kProcessEpoch = LoweringStats::Clock::now();
bool timelineEnabled() {
    static const bool on = ::getenv("ECO_LOWERING_TIMELINE") != nullptr;
    return on;
}
} // namespace

void LoweringStats::timelineMark(llvm::StringRef name, bool begin) {
    if (!timelineEnabled())
        return;
    double t = std::chrono::duration<double>(Clock::now() - kProcessEpoch).count();
    std::string line = llvm::formatv("[timeline] {0:F3} {1} {2}{3}\n", t,
                                     (unsigned long)::gettid(), begin ? "+" : "-",
                                     name.trim())
                           .str();
    ::write(2, line.data(), line.size());
}

namespace {
std::atomic<uint64_t> gNextStatsGen{1};
} // namespace

LoweringStats::LoweringStats() : gen_(gNextStatsGen++) {}

LoweringStats::Shard &LoweringStats::localShard() {
    // One cached shard per thread, keyed on the owning object's generation
    // (an address could be reused by a later LoweringStats; a gen cannot).
    thread_local uint64_t cachedGen = 0;
    thread_local Shard *cached = nullptr;
    if (cachedGen == gen_)
        return *cached;
    std::lock_guard<std::mutex> lock(mu_);
    shards_.push_back(std::make_unique<Shard>());
    cached = shards_.back().get();
    cachedGen = gen_;
    return *cached;
}

void LoweringStats::record(llvm::StringRef name, Duration duration) {
    auto &e = localShard().phases[name];
    e.total += duration;
    e.count += 1;
}

void LoweringStats::recordPass(llvm::StringRef name, Duration duration) {
    auto &e = localShard().passes[name];
    e.total += duration;
    e.count += 1;
}

namespace {

/// Pick a unit that keeps the displayed magnitude in [1, 1000) where possible:
///   < 1 ms    -> microseconds ("us")
///   < 1 s     -> milliseconds ("ms")
///   >= 1 s    -> seconds ("s")
/// The zero case falls through to "us" so dashes don't appear for never-run
/// passes.
std::string formatDuration(LoweringStats::Duration d, int width) {
    using namespace std::chrono;
    double us = duration<double, std::micro>(d).count();
    const char *unit;
    double value;
    // `extraBytes` accounts for unit strings whose UTF-8 byte length exceeds
    // their displayed column width (µ is 2 bytes, 1 column). Without this the
    // padding step would over-count and shift the µs rows left by one column.
    int extraBytes = 0;
    if (us < 1000.0) {
        value = us;
        unit = "\xC2\xB5s"; // "µs"
        extraBytes = 1;
    } else if (us < 1'000'000.0) {
        value = us / 1000.0;
        unit = "ms";
    } else {
        value = us / 1'000'000.0;
        unit = "s";
    }
    // Right-aligned in `width` columns, e.g. " 12.34 ms" or " 1.23 s".
    std::string body = llvm::formatv("{0:f2} {1}", value, unit).str();
    int visibleWidth = static_cast<int>(body.size()) - extraBytes;
    if (visibleWidth < width)
        body.insert(body.begin(), width - visibleWidth, ' ');
    return body;
}

struct Row {
    llvm::StringRef name;
    LoweringStats::Duration total;
    uint64_t count;
};

void printSection(llvm::raw_ostream &os, llvm::StringRef title,
                  const llvm::StringMap<LoweringStats::Entry> &table,
                  LoweringStats::Duration denom) {
    if (table.empty())
        return;

    std::vector<Row> rows;
    rows.reserve(table.size());
    LoweringStats::Duration sum{};
    for (const auto &kv : table) {
        rows.push_back({kv.getKey(), kv.getValue().total, kv.getValue().count});
        sum += kv.getValue().total;
    }
    llvm::sort(rows, [](const Row &a, const Row &b) {
        return a.total > b.total;
    });

    // Use the section sum as the "100%" baseline when no external denom is
    // supplied — keeps per-section percentages readable on their own.
    LoweringStats::Duration baseline = denom.count() > 0 ? denom : sum;

    // llvm::format only accepts scalar/pointer args, so column headers go
    // through padString(); numeric/percent cells use printf-style formatters.
    auto padString = [](llvm::StringRef s, size_t width) {
        std::string out = s.str();
        if (out.size() < width)
            out.append(width - out.size(), ' ');
        return out;
    };

    constexpr int kTimeWidth = 12;

    os << "\n" << title << "\n";
    os << "  " << padString("name", 44)
       << padString("time", kTimeWidth)
       << padString(" %", 8)
       << padString("calls", 8) << "\n";
    os << "  " << std::string(72, '-') << "\n";
    for (const auto &r : rows) {
        double pct = baseline.count() > 0
                         ? 100.0 * static_cast<double>(r.total.count()) /
                               static_cast<double>(baseline.count())
                         : 0.0;
        std::string nm = r.name.str();
        if (nm.size() > 44)
            nm = nm.substr(0, 41) + "...";
        os << "  " << padString(nm, 44)
           << formatDuration(r.total, kTimeWidth)
           << llvm::format("%7.1f%%", pct)
           << llvm::format("%8llu",
                           static_cast<unsigned long long>(r.count))
           << "\n";
    }
    os << "  " << std::string(72, '-') << "\n";
    os << "  " << padString("total", 44)
       << formatDuration(sum, kTimeWidth) << "\n";
}

} // namespace

void LoweringStats::print(llvm::raw_ostream &os) const {
    std::lock_guard<std::mutex> lock(mu_);

    // Merge the per-thread shards. Totals and counts are sums, so the merge
    // order cannot change a printed number. Requires every recording thread
    // to have finished (the banner prints at exit, after the EcoSplit join).
    llvm::StringMap<Entry> phases_, passes_;
    for (const auto &sh : shards_) {
        for (const auto &kv : sh->phases) {
            auto &e = phases_[kv.getKey()];
            e.total += kv.getValue().total;
            e.count += kv.getValue().count;
        }
        for (const auto &kv : sh->passes) {
            auto &e = passes_[kv.getKey()];
            e.total += kv.getValue().total;
            e.count += kv.getValue().count;
        }
    }

    // Sum top-level phases — used as the denominator for both tables so the
    // per-MLIR-pass percentages are comparable to the phase totals.
    Duration phaseSum{};
    for (const auto &kv : phases_)
        phaseSum += kv.getValue().total;

    os << "\n=== eco-boot-native lowering stats ===\n";
    printSection(os, "Phases (wall clock):", phases_, phaseSum);
    printSection(os, "MLIR passes (wall clock, may overlap with phases):",
                 passes_, phaseSum);
    os << "\n";
}

namespace {

class StatsPassInstrumentation : public PassInstrumentation {
public:
    explicit StatsPassInstrumentation(LoweringStats &stats) : stats_(stats) {}

    void runBeforePass(Pass *pass, Operation *op) override {
        // Each pass-instance is invoked sequentially per op within a single
        // PassManager run, so a per-thread map keyed by Pass* is sufficient
        // even when MLIR parallelises nested pipelines across ops.
        startTimes()[pass] = LoweringStats::Clock::now();
        if (isa<ModuleOp>(op))
            LoweringStats::timelineMark(pass->getName(), /*begin=*/true);
    }

    void runAfterPass(Pass *pass, Operation *op) override {
        finalize(pass);
        if (isa<ModuleOp>(op))
            LoweringStats::timelineMark(pass->getName(), /*begin=*/false);
    }

    void runAfterPassFailed(Pass *pass, Operation *op) override {
        // Still credit the time so the stats reflect work actually done before
        // the failure, even though the overall compilation will abort.
        finalize(pass);
    }

private:
    using StartMap = std::unordered_map<Pass *, LoweringStats::Clock::time_point>;

    static StartMap &startTimes() {
        thread_local StartMap m;
        return m;
    }

    void finalize(Pass *pass) {
        auto &m = startTimes();
        auto it = m.find(pass);
        if (it == m.end())
            return;
        auto duration = LoweringStats::Clock::now() - it->second;
        m.erase(it);
        stats_.recordPass(pass->getName(), duration);
    }

    LoweringStats &stats_;
};

} // namespace

std::unique_ptr<PassInstrumentation>
LoweringStats::makePassInstrumentation() {
    return std::make_unique<StatsPassInstrumentation>(*this);
}

} // namespace eco
