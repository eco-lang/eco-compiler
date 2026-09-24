// l3-corunner — a synthetic "collector thread" for the threaded-gc-00
// interference experiment (plans/threaded-gc-00-measure-and-fix.md Step 12).
//
// Models design C's concurrent promoter (design_docs/parallel-gc.md §7.4):
// every period it chases `--objs` records through ONE random cyclic
// permutation (every step is a dependent load, like GC pointer chasing) and
// memcpy's each 40-byte record to a bump destination, then sleeps for the
// rest of the period. Run it pinned to another core beside a self-compile and
// compare the compiler's "True mutator" time with and without it.
//
// Build: g++ -O2 -std=c++17 -o build/l3-corunner benchmarks/l3-corunner.cpp
//
// Options:
//   --src-mb N      source arena size in MiB (default 512)
//   --dst-mb N      destination arena size in MiB (default 64)
//   --period-ms N   period length (default 59: mean mutator epoch between minors)
//   --objs N        records copied per period (default 350000: one minor's promotions)
//   --duty D        1.0 = never sleep (upper bound); otherwise sleep out the period
//   --spin 1        control arm: busy-loop on registers only, touching NO memory
//                   (separates a power-state/uncore-frequency effect from cache
//                   and memory interference)

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Record {
    uint64_t next;       // index of the next record in the permutation
    uint64_t payload[4]; // 32 B of payload -> 40 B records
};
static_assert(sizeof(Record) == 40, "record size models a 2-field Custom + header");

double argD(int argc, char** argv, const char* name, double dflt) {
    for (int i = 1; i + 1 < argc; ++i)
        if (std::strcmp(argv[i], name) == 0) return std::atof(argv[i + 1]);
    return dflt;
}

}  // namespace

int main(int argc, char** argv) {
    const size_t src_mb = static_cast<size_t>(argD(argc, argv, "--src-mb", 512));
    const size_t dst_mb = static_cast<size_t>(argD(argc, argv, "--dst-mb", 64));
    const double period_ms = argD(argc, argv, "--period-ms", 59);
    const size_t objs = static_cast<size_t>(argD(argc, argv, "--objs", 350000));
    const double duty = argD(argc, argv, "--duty", 0.0);
    if (argD(argc, argv, "--spin", 0.0) != 0.0) {
        volatile uint64_t x = 1;
        std::fprintf(stderr, "[l3-corunner] spin mode: no memory traffic\n");
        for (;;) {
            uint64_t v = x;
            for (int i = 0; i < 1000000; ++i) v = v * 6364136223846793005ull + 1442695040888963407ull;
            x = v;
        }
    }

    const size_t n = (src_mb << 20) / sizeof(Record);
    std::vector<Record> src(n);
    {
        // One random cycle over all records (Sattolo's algorithm).
        std::vector<uint64_t> perm(n);
        for (size_t i = 0; i < n; ++i) perm[i] = i;
        std::mt19937_64 rng(12345);
        for (size_t i = n - 1; i > 0; --i) {
            std::uniform_int_distribution<size_t> d(0, i - 1);
            std::swap(perm[i], perm[d(rng)]);
        }
        for (size_t i = 0; i < n; ++i) {
            src[perm[i]].next = perm[(i + 1) % n];
            for (auto& w : src[perm[i]].payload) w = i;
        }
    }
    const size_t dn = (dst_mb << 20) / sizeof(Record);
    std::vector<Record> dst(dn);

    using clock = std::chrono::steady_clock;
    const auto period = std::chrono::duration<double, std::milli>(period_ms);
    uint64_t cur = 0;
    size_t d = 0;
    uint64_t sink = 0;
    auto report_at = clock::now() + std::chrono::seconds(10);
    double busy_ns = 0, total_ns = 0, copied = 0;

    for (;;) {
        const auto t0 = clock::now();
        for (size_t k = 0; k < objs; ++k) {
            const Record& r = src[cur];
            std::memcpy(&dst[d], &r, sizeof(Record));
            if (++d == dn) d = 0;
            cur = r.next;
            sink += r.payload[0];
        }
        const auto t1 = clock::now();
        const double busy = std::chrono::duration<double, std::nano>(t1 - t0).count();
        busy_ns += busy;
        copied += static_cast<double>(objs);
        if (duty < 1.0) {
            const auto end = t0 + std::chrono::duration_cast<clock::duration>(period);
            if (t1 < end) std::this_thread::sleep_until(end);
        }
        const auto t2 = clock::now();
        total_ns += std::chrono::duration<double, std::nano>(t2 - t0).count();
        if (t2 >= report_at) {
            std::fprintf(stderr, "[l3-corunner] %.1f ns/object, busy fraction %.2f (sink %llu)\n",
                         busy_ns / copied, busy_ns / total_ns,
                         static_cast<unsigned long long>(sink & 0xff));
            busy_ns = total_ns = copied = 0;
            report_at = t2 + std::chrono::seconds(10);
        }
    }
}
