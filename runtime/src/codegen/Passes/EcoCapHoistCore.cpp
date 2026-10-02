//===- EcoCapHoistCore.cpp - IR-neutral capacity-hoisting core ------------===//
//
// See EcoCapHoistCore.h.
//
//===----------------------------------------------------------------------===//
#include "EcoCapHoistCore.h"

#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringExtras.h"

#include <algorithm>
#include <cstdlib>

namespace eco {

GcFreeMode gcFreeLeafMode() {
    static const GcFreeMode mode = [] {
        const char *e = ::getenv("ECO_GCFREE_LEAF");
        if (!e || !*e)
            return GcFreeMode::Stamp; // default-ON since 2026-08-09
        if (e[0] == '0' && e[1] == '\0')
            return GcFreeMode::Off;
        if (e[0] == 'c' && e[1] == '\0')
            return GcFreeMode::Census;
        return GcFreeMode::Stamp;
    }();
    return mode;
}

CapHoistMode capHoistMode() {
    static const CapHoistMode mode = [] {
        const char *e = ::getenv("ECO_ALLOC_HOIST");
        if (!e || !*e)
            return CapHoistMode::On; // default-ON since 2026-08-09
        if (e[0] == '0' && e[1] == '\0')
            return CapHoistMode::Off;
        if (e[0] == 'c' && e[1] == '\0')
            return CapHoistMode::Census;
        return CapHoistMode::On;
    }();
    return mode;
}

// Default 512 (~20 Cons cells) — far below the 512 KiB nursery block and the
// 8 KiB large-object threshold. Clamped to [8, 4096] (4096 = the HEAP_034
// per-marker hard bound) then rounded DOWN to a multiple of 8, since every
// budget is an 8-multiple.
unsigned capHoistMaxBytes() {
    static const unsigned k = [] {
        unsigned v = 512;
        if (const char *e = ::getenv("ECO_ALLOC_HOIST_MAX_BYTES"))
            v = (unsigned)strtoul(e, nullptr, 10);
        if (v < 8)
            v = 8;
        if (v > 4096)
            v = 4096;
        return v & ~7u;
    }();
    return k;
}

// M2 can be switched off independently of M1 for A/B attribution:
// ECO_ALLOC_HOIST_M2=0 leaves every own marker with its HEAP_034 diamond and
// instruments only calls into covered functions.
bool capHoistFoldOwnMarkers() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_ALLOC_HOIST_M2");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

bool valueEqGcLeafEnv() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_VALUE_EQ_GCLEAF");
        return e && e[0] == '1' && e[1] == '\0';
    }();
    return on;
}

bool gcFreeMlirEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_GCFREE_MLIR");
        return !(e && e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

bool gcFreeValidateEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_GCFREE_VALIDATE");
        return e && *e && !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

namespace gcfree {

std::string encodeStamp(const Stamp &s) {
    return std::string("v1;veq=") + (s.valueEqLeaf ? "1" : "0") +
           ";cov=" + (s.covered ? "1" : "0");
}

std::optional<Stamp> parseStamp(llvm::StringRef s) {
    llvm::SmallVector<llvm::StringRef, 4> parts;
    s.split(parts, ';');
    if (parts.empty() || parts[0] != "v1")
        return std::nullopt;
    Stamp st;
    bool haveVeq = false, haveCov = false;
    for (llvm::StringRef part : llvm::ArrayRef(parts).drop_front()) {
        auto [k, v] = part.split('=');
        if (v != "0" && v != "1")
            return std::nullopt;
        if (k == "veq") {
            st.valueEqLeaf = v == "1";
            haveVeq = true;
        } else if (k == "cov") {
            st.covered = v == "1";
            haveCov = true;
        } else {
            return std::nullopt;
        }
    }
    if (!haveVeq || !haveCov)
        return std::nullopt;
    return st;
}

} // namespace gcfree

namespace caphoist {

void solve(std::vector<Node> &nodes, uint64_t K) {
    const size_t n = nodes.size();

    // Non-eligible callee: leaf-equivalent only when it allocates nothing
    // (CGEN_072 will stamp it GC-free). NEVER propagate a nonzero budget
    // through one — it keeps its own checked diamonds and its slow edge would
    // void the caller's guarantee.
    auto contributionOf = [&](uint32_t g, bool &isTop) -> uint64_t {
        const Node &gi = nodes[g];
        if (gi.top) {
            isTop = true;
            return 0;
        }
        if (gi.eligible)
            return gi.budget;
        if (gi.budget == 0)
            return 0;
        isTop = true;
        return 0;
    };

    // Iterative Tarjan. SCCs are emitted in reverse topological order of the
    // condensation, i.e. callees before callers — exactly the order
    // accumulation needs. Boolean optimism does NOT transfer to budgets: an
    // allocating cycle has unbounded aggregate demand.
    std::vector<unsigned> tIdx(n, 0), tLow(n, 0);
    std::vector<char> visited(n, 0), onStack(n, 0);
    std::vector<uint32_t> sccStack;
    unsigned nextIndex = 0;
    struct Frame {
        uint32_t f;
        unsigned childIdx;
    };

    for (uint32_t root = 0; root < n; ++root) {
        if (visited[root])
            continue;
        std::vector<Frame> work;
        tIdx[root] = tLow[root] = nextIndex++;
        onStack[root] = visited[root] = 1;
        sccStack.push_back(root);
        work.push_back({root, 0});

        while (!work.empty()) {
            const uint32_t f = work.back().f;
            const unsigned ci = work.back().childIdx;
            const Node &fi = nodes[f];
            if (ci < fi.callees.size()) {
                work.back().childIdx = ci + 1; // write back BEFORE any push
                const uint32_t g = fi.callees[ci].first;
                if (!visited[g]) {
                    tIdx[g] = tLow[g] = nextIndex++;
                    onStack[g] = visited[g] = 1;
                    sccStack.push_back(g);
                    work.push_back({g, 0});
                } else if (onStack[g]) {
                    tLow[f] = std::min(tLow[f], tIdx[g]);
                }
                continue;
            }
            work.pop_back();
            if (!work.empty()) {
                const uint32_t p = work.back().f;
                tLow[p] = std::min(tLow[p], tLow[f]);
            }
            if (tLow[f] != tIdx[f])
                continue;

            // Pop one SCC and resolve every member's budget.
            llvm::SmallVector<uint32_t, 4> scc;
            for (;;) {
                const uint32_t w = sccStack.back();
                sccStack.pop_back();
                onStack[w] = 0;
                scc.push_back(w);
                if (w == f)
                    break;
            }
            const bool isCycle = scc.size() > 1 || nodes[scc[0]].selfEdge;

            if (isCycle) {
                // Any allocation reachable from the cycle makes aggregate
                // demand unbounded. A pure zero-byte cycle stays 0.
                bool anyDemand = false;
                llvm::DenseSet<uint32_t> members(scc.begin(), scc.end());
                for (uint32_t w : scc) {
                    const Node &wi = nodes[w];
                    if (wi.top || wi.ownBytes > 0) {
                        anyDemand = true;
                        break;
                    }
                    for (const auto &e : wi.callees) {
                        if (members.count(e.first))
                            continue; // intra-SCC
                        bool t = false;
                        if (contributionOf(e.first, t) > 0 || t) {
                            anyDemand = true;
                            break;
                        }
                    }
                    if (anyDemand)
                        break;
                }
                for (uint32_t w : scc) {
                    Node &wi = nodes[w];
                    if (anyDemand) {
                        wi.top = true;
                        if (wi.reason == Reason::None)
                            wi.reason = Reason::Cycle;
                    } else {
                        wi.budget = 0;
                    }
                }
                continue;
            }

            Node &si = nodes[scc[0]];
            if (si.top)
                continue;
            uint64_t total = si.ownBytes;
            bool isTop = false;
            for (const auto &e : si.callees) {
                bool t = false;
                const uint64_t c = contributionOf(e.first, t);
                if (t) {
                    isTop = true;
                    break;
                }
                // An in-loop call edge repeats unboundedly; only harmless
                // when it contributes nothing.
                if (e.second && c > 0) {
                    isTop = true;
                    break;
                }
                total += c;
                if (total > K)
                    break;
            }
            if (isTop) {
                si.top = true;
                if (si.reason == Reason::None)
                    si.reason = Reason::Other;
            } else if (total > K) {
                si.top = true;
                if (si.reason == Reason::None)
                    si.reason = Reason::Budget;
            } else {
                si.budget = total;
            }
        }
    }

    // Phase C: covered = finite, nonzero, and every caller is instrumentable.
    for (Node &nd : nodes)
        nd.covered = !nd.top && nd.budget > 0 && nd.eligible;
}

std::string encodePlanStamp(const PlanStamp &s) {
    return "v1;K=" + std::to_string(s.K) + ";m2=" + (s.m2 ? "1" : "0") +
           ";cw=" + (s.closedWorld ? "1" : "0") +
           ";veq=" + (s.valueEqLeaf ? "1" : "0");
}

std::optional<PlanStamp> parsePlanStamp(llvm::StringRef s) {
    llvm::SmallVector<llvm::StringRef, 4> parts;
    s.split(parts, ';');
    if (parts.empty() || parts[0] != "v1")
        return std::nullopt;
    PlanStamp p;
    bool haveK = false, haveM2 = false, haveCw = false, haveVeq = false;
    for (llvm::StringRef part : llvm::ArrayRef(parts).drop_front()) {
        auto [k, v] = part.split('=');
        if (k == "K") {
            if (v.getAsInteger(10, p.K))
                return std::nullopt;
            haveK = true;
        } else if (k == "m2") {
            p.m2 = v == "1";
            haveM2 = true;
        } else if (k == "cw") {
            p.closedWorld = v == "1";
            haveCw = true;
        } else if (k == "veq") {
            p.valueEqLeaf = v == "1";
            haveVeq = true;
        } else {
            return std::nullopt;
        }
    }
    if (!haveK || !haveM2 || !haveCw || !haveVeq)
        return std::nullopt;
    return p;
}

} // namespace caphoist
} // namespace eco
