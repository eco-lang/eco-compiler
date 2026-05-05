//===- LoweringStats.cpp - Phase/pass timing for eco-boot-native ----------===//
#include "LoweringStats.h"

#include "mlir/Pass/Pass.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/FormatVariadic.h"

#include <algorithm>
#include <unordered_map>
#include <vector>

using namespace mlir;

namespace eco {

void LoweringStats::record(llvm::StringRef name, Duration duration) {
    std::lock_guard<std::mutex> lock(mu_);
    auto &e = phases_[name];
    e.total += duration;
    e.count += 1;
}

void LoweringStats::recordPass(llvm::StringRef name, Duration duration) {
    std::lock_guard<std::mutex> lock(mu_);
    auto &e = passes_[name];
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
    }

    void runAfterPass(Pass *pass, Operation *op) override {
        finalize(pass);
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
