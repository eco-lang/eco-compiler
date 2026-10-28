//===- LoweringStats.cpp - Wall-clock phase and MLIR pass timing ----------===//
#include "LoweringStats.h"

#include <atomic>

#include "mlir/Pass/Pass.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/FormatVariadic.h"
#include "llvm/Support/Threading.h"

#include <algorithm>
#include <cstdlib>
#if defined(_WIN32)
#include <io.h>
#else
#include <unistd.h>
#endif
#include "mlir/IR/BuiltinOps.h"
#include <unordered_map>
#include <vector>

using namespace mlir;

namespace eco {

namespace {
/// The instant timeline seconds are measured from: when this file's static
/// variables are initialised.
const LoweringStats::Clock::time_point kProcessEpoch = LoweringStats::Clock::now();
/// Returns whether `ECO_LOWERING_TIMELINE` was set when first asked.
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
                                     (unsigned long)llvm::get_threadid(), begin ? "+" : "-",
                                     name.trim())
                           .str();
    // One write(2) per line, so lines from concurrent threads normally don't interleave.
#if defined(_WIN32)
    ::_write(2, line.data(), static_cast<unsigned>(line.size()));
#else
    ::write(2, line.data(), line.size());
#endif
}

namespace {
/// The identifier the next `LoweringStats` takes. It starts at 1 because 0 is
/// what a thread's cache holds before it has cached anything.
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

/// Returns `d` with two decimals in microseconds (written "µs") below 1 ms, in
/// milliseconds below 1 s, and otherwise in seconds, padded on the left to
/// `width` display columns.
std::string formatDuration(LoweringStats::Duration d, int width) {
    using namespace std::chrono;
    double us = duration<double, std::micro>(d).count();
    const char *unit;
    double value;
    // "µ" is two bytes in UTF-8 but one column wide; padding counts columns.
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
    std::string body = llvm::formatv("{0:f2} {1}", value, unit).str();
    int visibleWidth = static_cast<int>(body.size()) - extraBytes;
    if (visibleWidth < width)
        body.insert(body.begin(), width - visibleWidth, ' ');
    return body;
}

/// One line of a printed table.
struct Row {
    /// Points into the `StringMap` passed to `printSection`; valid only during
    /// that call.
    llvm::StringRef name;
    LoweringStats::Duration total;
    uint64_t count;
};

/// Writes `table` to `os` under `title`, sorted by descending time, with a
/// percentage of `denom` per row (of the table's own sum when `denom` is zero)
/// and a closing total. Names longer than 44 bytes are cut short. Writes
/// nothing for an empty table.
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

    LoweringStats::Duration baseline = denom.count() > 0 ? denom : sum;

    // llvm::format takes only scalars and pointers, so strings are padded here.
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

    // The lock keeps new shards from being registered, but does not stop a
    // thread writing into an existing one; hence the rule in the header.
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

/// The instrumentation `LoweringStats::makePassInstrumentation` returns.
class StatsPassInstrumentation : public PassInstrumentation {
public:
    /// Creates an instrumentation recording into `stats`, which it keeps a
    /// reference to.
    explicit StatsPassInstrumentation(LoweringStats &stats) : stats_(stats) {}

    void runBeforePass(Pass *pass, Operation *op) override {
        // Each concurrent run uses its own pass instance, so a per-thread map
        // keyed by Pass* never sees two overlapping runs of one instance.
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
        finalize(pass);
    }

private:
    /// Start times of the passes currently running on one thread.
    using StartMap = std::unordered_map<Pass *, LoweringStats::Clock::time_point>;

    /// Returns the calling thread's start-time map, shared by every instance
    /// of this class on that thread.
    static StartMap &startTimes() {
        thread_local StartMap m;
        return m;
    }

    /// Records the time since `pass` started on this thread, if it did.
    void finalize(Pass *pass) {
        auto &m = startTimes();
        auto it = m.find(pass);
        if (it == m.end())
            return;
        auto duration = LoweringStats::Clock::now() - it->second;
        m.erase(it);
        stats_.recordPass(pass->getName(), duration);
    }

    LoweringStats &stats_; ///< Must outlive this instrumentation.
};

} // namespace

std::unique_ptr<PassInstrumentation>
LoweringStats::makePassInstrumentation() {
    return std::make_unique<StatsPassInstrumentation>(*this);
}

} // namespace eco
