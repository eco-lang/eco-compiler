//===- SpikeCensus.cpp - De-risking census for the MLIR split plans -------===//
//
// plans/mlir-split-backend-00-spikes.md: I1 (symbol graph), SP1 (parallel
// partition translation), SP2 (cap-hoist Phases A-C emulated on MLIR), SP3
// (gc-free fixpoint emulated on MLIR), SP4 (reachability census).
//
// Diagnostic only. Runs when ECO_SPIKE_DIR is set; writes TSV files there and
// prints [spike] lines. The input module is never modified (SP1 builds
// separate partition modules from clones).
//
// The LLVM rules emulated here live in EcoBackend.cpp (applyCapacityHoisting
// Phases A-C, propagateGcFreeLeafAttrs). Differences between this emulation
// and the LLVM oracles (ECO_CAPHOIST_FULL_DUMP, ECO_GCFREE_LEAF_DUMP) are the
// spike's findings, not bugs to hide.
//
//===----------------------------------------------------------------------===//
#include "SpikeCensus.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"
#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/raw_ostream.h"

#if !defined(_WIN32)
#include <sys/resource.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <queue>
#include <string>
#include <vector>

using namespace mlir;

namespace {

using Clock = std::chrono::steady_clock;
double secs(Clock::time_point a) {
    return std::chrono::duration<double>(Clock::now() - a).count();
}
long maxRssMB() {
#if defined(_WIN32)
    return 0;   // not measured on Windows (no getrusage)
#else
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss / 1024;
#endif
}

bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

// ---- marker table (spike draft; the plans' "may-GC table") --------------
// hoistView: how applyCapacityHoisting's Phase A sees a call to this callee
//            on LLVM IR (after the pre-hoisting expansions).
// finalView: what RS4GC / gc-free propagation see after every expansion.
enum class Leaf { FromDecl, Leaf, NotLeaf, Marker };
struct MarkerRow {
    Leaf hoist;
    Leaf final;
};
bool isCursorMarker(StringRef c) {
    return c.starts_with("__eco_list_cur") ||
           c == "__eco_list_step_node_inline" ||
           c == "__eco_list_step_idx_inline" || c == "eco_list_pos_view";
}
bool isScratchHelper(StringRef c) {
    return c == "eco_scratch_mark" || c == "eco_scratch_push_boxed" ||
           c == "eco_scratch_push_scalar";
}
bool isTliName(StringRef c) {
    static const char *names[] = {
        "memcpy", "memmove", "memset", "memcmp", "malloc", "free", "strlen",
        "log",    "exp",     "pow",    "sqrt",   "floor",  "ceil", "fmod",
        "sin",    "cos",     "tan",    "atan",   "atan2",  "asin", "acos",
        "log2",   "log10",   "trunc",  "round",  "fabs",   "ldexp"};
    for (const char *n : names)
        if (c == n)
            return true;
    return false;
}
bool isHeadroomBreaker(StringRef c) {
    return c == "eco_gc_alloc_region_fast" ||
           (c.starts_with("eco_alloc_") && c.ends_with("_fast"));
}

bool hasGcLeafPassthrough(Operation *op) {
    auto pt = op->getAttrOfType<ArrayAttr>("passthrough");
    if (!pt)
        return false;
    for (Attribute a : pt)
        if (auto s = dyn_cast<StringAttr>(a))
            if (s.getValue() == "gc-leaf-function")
                return true;
    return false;
}

struct Node {
    Operation *op = nullptr;
    StringRef name;
    bool isFunc = false, defined = false, interposable = false;
    int64_t opCount = 0;
    // graph
    std::vector<int> refs;      // every symbol this op references (dedup)
    std::vector<int> addrRefs;  // references that take the address
    // Phase A (hoisting view)
    uint64_t ownBytes = 0;
    bool top = false;
    int reason = 0; // 0 none, 1 loop, 2 cycle, 3 budget, 4 other
    bool selfEdge = false;
    std::vector<std::pair<int, bool>> callees; // defined callee, inLoop
    uint64_t budget = 0;
    // gc view (final IR)
    bool gcSeedPoison = false;
    bool hasMarker = false;
    std::vector<int> gcCallees; // defined callees (direct after translation)
    // counters
    unsigned nListTail = 0, nSat = 0, nValueEq = 0, nCursor = 0, nScratch = 0,
             nTliOnly = 0, nMarkersUnreach = 0, nCallsUnreach = 0,
             nUnreachBlocks = 0, nAddrUnused = 0, nAddrCallMatch = 0,
             nAddrCallMismatch = 0, nAddrCallMismatchLeaf = 0;
    std::vector<std::pair<std::string, std::string>> attrRefs;
};

struct Census {
    ModuleOp module;
    MLIRContext *ctx;
    std::vector<Node> nodes;
    llvm::DenseMap<StringAttr, int> index;
    std::vector<Operation *> nonSymbolTops;
    std::vector<std::vector<int>> nonSymbolRefs;
    bool utilsEqualLeaf = false;
    bool valueEqGcLeafEnv = false;
    uint64_t K = 512; // EcoBackend.cpp capHoistMaxBytes() default

    int lookup(StringAttr s) const {
        auto it = index.find(s);
        return it == index.end() ? -1 : it->second;
    }
    int lookup(StringRef s) const {
        return lookup(StringAttr::get(ctx, s));
    }

    // Hoisting-view leafness of a call to symbol `c` (declaration side).
    bool hoistLeaf(StringRef c, int idx) const {
        if (c == "__eco_list_tail_inline")
            return false; // expands to eco_list_tail_hybrid (not leaf)
        if (c == "__eco_value_eq")
            return valueEqGcLeafEnv || utilsEqualLeaf;
        if (isCursorMarker(c) || isScratchHelper(c))
            return true; // expand leaf-only / stamped backend-side
        if (idx >= 0 && hasGcLeafPassthrough(nodes[idx].op))
            return true;
        if (idx >= 0 && !nodes[idx].defined && isTliName(c))
            return true; // TLI arm of callsGCLeafFunction
        return false;
    }
    // Final-view (RS4GC) leafness for a declaration callee.
    bool finalLeafDecl(StringRef c, int idx) const {
        if (c == "__eco_list_tail_inline")
            return false;
        if (c == "__eco_sat_begin" || c == "__eco_sat_end")
            return false; // expansion adds an indirect fast call
        if (c == "__eco_value_eq")
            return valueEqGcLeafEnv || utilsEqualLeaf;
        if (isCursorMarker(c) || isScratchHelper(c))
            return true;
        if (idx >= 0 && hasGcLeafPassthrough(nodes[idx].op))
            return true;
        if (idx >= 0 && isTliName(c))
            return true;
        return false;
    }
};

// Entry-rooted SCC walk over the function's CFG: blocks in a cycle.
void blockCycles(Region &body, llvm::DenseSet<Block *> &inCycle,
                 llvm::DenseSet<Block *> &reachable) {
    if (body.empty())
        return;
    llvm::DenseMap<Block *, unsigned> idx, low;
    llvm::DenseSet<Block *> onStack;
    std::vector<Block *> stack;
    unsigned next = 0;
    struct Fr {
        Block *b;
        unsigned i;
    };
    std::vector<Fr> work;
    Block *entry = &body.front();
    idx[entry] = low[entry] = next++;
    onStack.insert(entry);
    stack.push_back(entry);
    reachable.insert(entry);
    work.push_back({entry, 0});
    while (!work.empty()) {
        Block *b = work.back().b;
        unsigned i = work.back().i;
        if (i < b->getNumSuccessors()) {
            work.back().i = i + 1;
            Block *s = b->getSuccessor(i);
            if (!idx.count(s)) {
                idx[s] = low[s] = next++;
                onStack.insert(s);
                stack.push_back(s);
                reachable.insert(s);
                work.push_back({s, 0});
            } else if (onStack.count(s)) {
                low[b] = std::min(low[b], idx[s]);
            }
            continue;
        }
        work.pop_back();
        if (!work.empty())
            low[work.back().b] = std::min(low[work.back().b], low[b]);
        if (low[b] != idx[b])
            continue;
        std::vector<Block *> scc;
        for (;;) {
            Block *w = stack.back();
            stack.pop_back();
            onStack.erase(w);
            scc.push_back(w);
            if (w == b)
                break;
        }
        bool cyc = scc.size() > 1;
        if (!cyc)
            for (Block *s : scc[0]->getSuccessors())
                if (s == scc[0])
                    cyc = true;
        if (cyc)
            for (Block *w : scc)
                inCycle.insert(w);
    }
}

// Every symbol reference made by `op` (own attributes + nested uses).
void collectRefs(Census &C, Operation *op, std::vector<int> &out) {
    llvm::DenseSet<int> seen;
    auto add = [&](StringAttr s) {
        int i = C.lookup(s);
        if (i >= 0 && seen.insert(i).second)
            out.push_back(i);
    };
    op->getAttrDictionary().walk(
        [&](SymbolRefAttr r) { add(r.getRootReference()); });
    if (auto uses = SymbolTable::getSymbolUses(op))
        for (const SymbolTable::SymbolUse &u : *uses)
            add(u.getSymbolRef().getRootReference());
}

void analyzeFunction(Census &C, int self) {
    Node &n = C.nodes[self];
    auto fn = cast<LLVM::LLVMFuncOp>(n.op);
    Region &body = fn.getBody();
    llvm::DenseSet<Block *> inCycle, reachable;
    blockCycles(body, inCycle, reachable);
    for (Block &b : body)
        if (!reachable.count(&b))
            ++n.nUnreachBlocks;

    llvm::DenseSet<int> seenCallee;
    auto setTop = [&](int r) {
        n.top = true;
        if (n.reason == 0)
            n.reason = r;
    };

    fn.walk([&](Operation *op) {
        ++n.opCount;
        Block *blk = op->getBlock();
        // Ops nested in regions inside the body (none expected at the llvm
        // level) are attributed to their top-level block.
        while (blk && blk->getParent() != &body)
            blk = blk->getParentOp() ? blk->getParentOp()->getBlock() : nullptr;
        const bool inLoop = blk && inCycle.count(blk);
        const bool unreach = blk && !reachable.count(blk);

        if (auto ao = dyn_cast<LLVM::AddressOfOp>(op)) {
            if (ao->use_empty())
                ++n.nAddrUnused;
            int g = C.lookup(ao.getGlobalNameAttr().getAttr());
            if (g < 0)
                return;
            bool taken = false;
            for (OpOperand &use : ao->getUses()) {
                auto call = dyn_cast<LLVM::CallOp>(use.getOwner());
                if (!call || call.getCallee() || use.getOperandNumber() != 0) {
                    taken = true;
                    continue;
                }
                auto gf = dyn_cast<LLVM::LLVMFuncOp>(C.nodes[g].op);
                if (!gf || call.getCalleeFunctionType() != gf.getFunctionType())
                    taken = true; // hasAddressTaken: FTy mismatch = taken
            }
            if (taken)
                n.addrRefs.push_back(g);
            return;
        }
        auto call = dyn_cast<LLVM::CallOp>(op);
        if (!call)
            return;
        if (unreach)
            ++n.nCallsUnreach;

        // Resolve the callee as LLVM's getCalledFunction() would.
        StringRef cname;
        int ci = -1;
        bool direct = false, mismatched = false;
        if (auto c = call.getCallee()) {
            cname = *c;
            ci = C.lookup(cname);
            direct = true;
        } else if (auto ao = call->getOperand(0)
                                 .getDefiningOp<LLVM::AddressOfOp>()) {
            cname = ao.getGlobalName();
            ci = C.lookup(cname);
            auto gf = ci >= 0 ? dyn_cast<LLVM::LLVMFuncOp>(C.nodes[ci].op)
                              : LLVM::LLVMFuncOp();
            if (gf && call.getCalleeFunctionType() == gf.getFunctionType()) {
                direct = true;
                ++n.nAddrCallMatch;
            } else {
                mismatched = true;
                ++n.nAddrCallMismatch;
            }
        }

        // ---- Phase A, hoisting view --------------------------------------
        if (direct && cname == "__eco_alloc_inline") {
            n.hasMarker = true;
            if (unreach)
                ++n.nMarkersUnreach;
            uint64_t sz = 0;
            if (auto cst = call->getOperand(0)
                               .getDefiningOp<LLVM::ConstantOp>())
                if (auto ia = dyn_cast<IntegerAttr>(cst.getValue()))
                    sz = ia.getValue().getZExtValue();
            if (inLoop)
                setTop(1);
            else
                n.ownBytes += sz;
            return; // gc view: decided after coverage (see below)
        }
        if (cname == "__eco_list_tail_inline")
            ++n.nListTail;
        if (cname == "__eco_sat_begin" || cname == "__eco_sat_end")
            ++n.nSat;
        if (cname == "__eco_value_eq")
            ++n.nValueEq;
        if (isCursorMarker(cname))
            ++n.nCursor;
        if (isScratchHelper(cname))
            ++n.nScratch;

        if (direct && isHeadroomBreaker(cname)) {
            setTop(4);
        } else if (direct && C.hoistLeaf(cname, ci)) {
            if (ci >= 0 && !C.nodes[ci].defined &&
                !hasGcLeafPassthrough(C.nodes[ci].op) && isTliName(cname))
                ++n.nTliOnly;
        } else if (mismatched && ci >= 0 &&
                   hasGcLeafPassthrough(C.nodes[ci].op)) {
            ++n.nAddrCallMismatchLeaf; // callsGCLeafFunction reads the
                                       // called operand's attrs
        } else if (direct && ci >= 0 && C.nodes[ci].defined &&
                   !C.nodes[ci].interposable) {
            n.callees.push_back({ci, inLoop});
            if (ci == self)
                n.selfEdge = true;
        } else {
            setTop(4);
        }

        // ---- gc view (final IR) ----------------------------------------
        if (direct && ci >= 0 && C.nodes[ci].defined &&
            !C.nodes[ci].interposable) {
            if (seenCallee.insert(ci).second)
                n.gcCallees.push_back(ci);
        } else if (direct && C.finalLeafDecl(cname, ci)) {
            // leaf
        } else if (mismatched && ci >= 0 && !C.nodes[ci].defined &&
                   hasGcLeafPassthrough(C.nodes[ci].op)) {
            // leaf through the called operand's attributes
        } else {
            n.gcSeedPoison = true;
        }
    });

    // Attribute references that are not callee / global_name.
    fn.walk([&](Operation *op) {
        for (NamedAttribute na : op->getAttrs()) {
            StringRef an = na.getName().getValue();
            if ((isa<LLVM::CallOp>(op) && an == "callee") ||
                (isa<LLVM::AddressOfOp>(op) && an == "global_name"))
                continue;
            bool any = false;
            na.getValue().walk([&](SymbolRefAttr) { any = true; });
            if (any)
                n.attrRefs.push_back(
                    {op->getName().getStringRef().str(), an.str()});
        }
    });
}

void writeLine(std::ofstream &o, const std::string &s) { o << s << "\n"; }

} // namespace

void eco::runSpikeCensus(ModuleOp module, llvm::StringRef outDir) {
    Census C;
    C.module = module;
    C.ctx = module.getContext();
    C.valueEqGcLeafEnv = envOn("ECO_VALUE_EQ_GCLEAF");
    if (const char *e = ::getenv("ECO_ALLOC_HOIST_MAX_BYTES"))
        C.K = std::strtoull(e, nullptr, 10);
    C.K = std::max<uint64_t>(8, std::min<uint64_t>(4096, C.K)) & ~uint64_t(7);
    std::string dir = outDir.str();
    auto T0 = Clock::now();
    long rss0 = maxRssMB();

    // ---- nodes -------------------------------------------------------------
    for (Operation &op : *module.getBody()) {
        auto nameAttr = op.getAttrOfType<StringAttr>(SymbolTable::getSymbolAttrName());
        if (!nameAttr) {
            C.nonSymbolTops.push_back(&op);
            continue;
        }
        Node n;
        n.op = &op;
        n.name = nameAttr.getValue();
        if (auto f = dyn_cast<LLVM::LLVMFuncOp>(op)) {
            n.isFunc = true;
            n.defined = !f.isExternal();
            auto l = f.getLinkage();
            n.interposable = l == LLVM::Linkage::Weak ||
                             l == LLVM::Linkage::Linkonce ||
                             l == LLVM::Linkage::ExternWeak ||
                             l == LLVM::Linkage::Common;
        } else if (auto g = dyn_cast<LLVM::GlobalOp>(op)) {
            n.defined = !g.getInitializerRegion().empty() || g.getValueAttr();
        }
        C.index[nameAttr] = (int)C.nodes.size();
        C.nodes.push_back(std::move(n));
    }
    {
        int ue = C.lookup("Elm_Kernel_Utils_equal");
        C.utilsEqualLeaf = ue >= 0 && hasGcLeafPassthrough(C.nodes[ue].op);
    }

    // ---- per-node analysis, in parallel -------------------------------------
    auto Tc = Clock::now();
    std::vector<int> all(C.nodes.size());
    for (size_t i = 0; i < all.size(); ++i)
        all[i] = (int)i;
    parallelForEach(C.ctx, all, [&](int i) {
        Node &n = C.nodes[i];
        collectRefs(C, n.op, n.refs);
        if (n.isFunc && n.defined) {
            analyzeFunction(C, i);
        } else if (!n.isFunc) {
            // global initializer: every addressof takes the address
            n.op->walk([&](LLVM::AddressOfOp ao) {
                int g = C.lookup(ao.getGlobalNameAttr().getAttr());
                if (g >= 0)
                    n.addrRefs.push_back(g);
            });
        }
    });
    for (Operation *op : C.nonSymbolTops) {
        C.nonSymbolRefs.emplace_back();
        collectRefs(C, op, C.nonSymbolRefs.back());
    }
    double tCollect = secs(Tc);

    // ---- SP4: reachability BFS ------------------------------------------------
    auto Tb = Clock::now();
    std::vector<char> reached(C.nodes.size(), 0);
    std::vector<int> q;
    auto push = [&](int i) {
        if (i >= 0 && !reached[i]) {
            reached[i] = 1;
            q.push_back(i);
        }
    };
    push(C.lookup("main"));
    push(C.lookup("__eco_init_globals"));
    for (auto &v : C.nonSymbolRefs)
        for (int i : v)
            push(i);
    for (size_t h = 0; h < q.size(); ++h)
        for (int r : C.nodes[q[h]].refs)
            push(r);
    double tBfs = secs(Tb);

    // addr-taken: all referrers vs reached referrers only (GlobalDCE view)
    std::vector<char> addrAll(C.nodes.size(), 0), addrLive(C.nodes.size(), 0);
    for (size_t i = 0; i < C.nodes.size(); ++i)
        for (int g : C.nodes[i].addrRefs) {
            addrAll[g] = 1;
            if (reached[i])
                addrLive[g] = 1;
        }
    for (auto &v : C.nonSymbolRefs)
        for (int g : v)
            addrAll[g] = addrLive[g] = 1; // conservative

    // ---- SP2: Phase B (same rules as EcoBackend.cpp) -------------------------
    auto Tp = Clock::now();
    const int mainIdx = C.lookup("main"), initIdx = C.lookup("__eco_init_globals");
    std::vector<char> eligible(C.nodes.size(), 0);
    for (size_t i = 0; i < C.nodes.size(); ++i) {
        Node &n = C.nodes[i];
        if (!n.isFunc || !n.defined)
            continue;
        bool local = (int)i != mainIdx && (int)i != initIdx;
        eligible[i] = !n.interposable && !addrLive[i] && local;
    }
    auto contributionOf = [&](int g, bool &isTop) -> uint64_t {
        Node &gi = C.nodes[g];
        if (gi.top) {
            isTop = true;
            return 0;
        }
        if (eligible[g])
            return gi.budget;
        if (gi.budget == 0)
            return 0;
        isTop = true;
        return 0;
    };
    {
        std::vector<unsigned> tIdx(C.nodes.size(), 0), tLow(C.nodes.size(), 0);
        std::vector<char> visited(C.nodes.size(), 0), onStack(C.nodes.size(), 0);
        std::vector<int> sccStack;
        unsigned next = 0;
        struct Fr {
            int f;
            unsigned ci;
        };
        for (size_t root = 0; root < C.nodes.size(); ++root) {
            if (!C.nodes[root].isFunc || !C.nodes[root].defined || visited[root])
                continue;
            std::vector<Fr> work;
            tIdx[root] = tLow[root] = next++;
            visited[root] = onStack[root] = 1;
            sccStack.push_back((int)root);
            work.push_back({(int)root, 0});
            while (!work.empty()) {
                int f = work.back().f;
                unsigned ci = work.back().ci;
                Node &fi = C.nodes[f];
                if (ci < fi.callees.size()) {
                    work.back().ci = ci + 1;
                    int g = fi.callees[ci].first;
                    if (!visited[g]) {
                        tIdx[g] = tLow[g] = next++;
                        visited[g] = onStack[g] = 1;
                        sccStack.push_back(g);
                        work.push_back({g, 0});
                    } else if (onStack[g]) {
                        tLow[f] = std::min(tLow[f], tIdx[g]);
                    }
                    continue;
                }
                work.pop_back();
                if (!work.empty())
                    tLow[work.back().f] = std::min(tLow[work.back().f], tLow[f]);
                if (tLow[f] != tIdx[f])
                    continue;
                std::vector<int> scc;
                for (;;) {
                    int w = sccStack.back();
                    sccStack.pop_back();
                    onStack[w] = 0;
                    scc.push_back(w);
                    if (w == f)
                        break;
                }
                bool isCycle = scc.size() > 1 || C.nodes[scc[0]].selfEdge;
                if (isCycle) {
                    bool anyDemand = false;
                    llvm::DenseSet<int> members(scc.begin(), scc.end());
                    for (int w : scc) {
                        Node &wi = C.nodes[w];
                        if (wi.top || wi.ownBytes > 0) {
                            anyDemand = true;
                            break;
                        }
                        for (auto &e : wi.callees) {
                            if (members.count(e.first))
                                continue;
                            bool t = false;
                            if (contributionOf(e.first, t) > 0 || t) {
                                anyDemand = true;
                                break;
                            }
                        }
                        if (anyDemand)
                            break;
                    }
                    for (int w : scc) {
                        Node &wi = C.nodes[w];
                        if (anyDemand) {
                            wi.top = true;
                            if (wi.reason == 0)
                                wi.reason = 2;
                        } else {
                            wi.budget = 0;
                        }
                    }
                    continue;
                }
                Node &si = C.nodes[scc[0]];
                if (si.top)
                    continue;
                uint64_t total = si.ownBytes;
                bool isTop = false;
                for (auto &e : si.callees) {
                    bool t = false;
                    uint64_t c = contributionOf(e.first, t);
                    if (t) {
                        isTop = true;
                        break;
                    }
                    if (e.second && c > 0) {
                        isTop = true;
                        break;
                    }
                    total += c;
                    if (total > C.K)
                        break;
                }
                if (isTop) {
                    si.top = true;
                    if (si.reason == 0)
                        si.reason = 4;
                } else if (total > C.K) {
                    si.top = true;
                    if (si.reason == 0)
                        si.reason = 3;
                } else {
                    si.budget = total;
                }
            }
        }
    }
    std::vector<char> covered(C.nodes.size(), 0);
    unsigned nCovered = 0;
    for (size_t i = 0; i < C.nodes.size(); ++i) {
        Node &n = C.nodes[i];
        if (n.isFunc && n.defined && !n.top && n.budget > 0 && eligible[i]) {
            covered[i] = 1;
            ++nCovered;
        }
    }
    double tPlan = secs(Tp);

    // ---- SP3: gc-free fixpoint (final view) ----------------------------------
    auto Tg = Clock::now();
    std::vector<char> poisoned(C.nodes.size(), 0);
    std::vector<std::vector<int>> callers(C.nodes.size());
    std::vector<int> wl;
    for (size_t i = 0; i < C.nodes.size(); ++i) {
        Node &n = C.nodes[i];
        if (!n.isFunc || !n.defined)
            continue;
        bool p = n.gcSeedPoison || n.interposable;
        if (n.hasMarker && !covered[i])
            p = true; // checked diamond slow path, or an ensure for its run
        for (int c : n.gcCallees) {
            callers[c].push_back((int)i);
            if (covered[c] && !covered[i])
                p = true; // a non-covered caller holds an ensure
        }
        if (p) {
            poisoned[i] = 1;
            wl.push_back((int)i);
        }
    }
    while (!wl.empty()) {
        int c = wl.back();
        wl.pop_back();
        for (int caller : callers[c])
            if (!poisoned[caller]) {
                poisoned[caller] = 1;
                wl.push_back(caller);
            }
    }
    double tGc = secs(Tg);

    // ---- dumps -------------------------------------------------------------------
    {
        std::ofstream o(dir + "/mlir-funcs.tsv");
        o << "name\tdefined\treached\ttop\treason\tbudget\townBytes\teligible"
             "\taddrAll\taddrLive\tcovered\tgcfree\topCount\tunreachBlocks"
             "\tnListTail\tnSat\tnValueEq\tnCursor\tnScratch\tnAddrCallMatch"
             "\tnAddrCallMismatch\n";
        static const char *rs[] = {"none", "loop", "cycle", "budget", "other"};
        for (size_t i = 0; i < C.nodes.size(); ++i) {
            Node &n = C.nodes[i];
            if (!n.isFunc)
                continue;
            o << n.name.str() << "\t" << n.defined << "\t" << (int)reached[i]
              << "\t" << n.top << "\t" << rs[n.reason] << "\t" << n.budget
              << "\t" << n.ownBytes << "\t" << (int)eligible[i] << "\t"
              << (int)addrAll[i] << "\t" << (int)addrLive[i] << "\t"
              << (int)covered[i] << "\t"
              << (n.defined ? (int)!poisoned[i] : -1) << "\t" << n.opCount
              << "\t" << n.nUnreachBlocks << "\t" << n.nListTail << "\t"
              << n.nSat << "\t" << n.nValueEq << "\t" << n.nCursor << "\t"
              << n.nScratch << "\t" << n.nAddrCallMatch << "\t"
              << n.nAddrCallMismatch << "\n";
        }
    }
    {
        std::ofstream o(dir + "/mlir-symbols.tsv");
        o << "name\tkind\tdefined\treached\n";
        for (size_t i = 0; i < C.nodes.size(); ++i) {
            Node &n = C.nodes[i];
            o << n.name.str() << "\t" << (n.isFunc ? "func" : "global") << "\t"
              << n.defined << "\t" << (int)reached[i] << "\n";
        }
    }
    {
        std::ofstream o(dir + "/mlir-edges.tsv"); // caller \t callee (defined)
        for (size_t i = 0; i < C.nodes.size(); ++i)
            for (int c : C.nodes[i].gcCallees)
                o << C.nodes[i].name.str() << "\t" << C.nodes[c].name.str()
                  << "\n";
    }
    std::map<std::pair<std::string, std::string>, unsigned> attrRefCount;
    uint64_t sum[16] = {0};
    for (Node &n : C.nodes) {
        for (auto &p : n.attrRefs)
            ++attrRefCount[p];
        sum[0] += n.nListTail;
        sum[1] += n.nSat;
        sum[2] += n.nValueEq;
        sum[3] += n.nCursor;
        sum[4] += n.nScratch;
        sum[5] += n.nTliOnly;
        sum[6] += n.nMarkersUnreach;
        sum[7] += n.nCallsUnreach;
        sum[8] += n.nUnreachBlocks;
        sum[9] += n.nAddrUnused;
        sum[10] += n.nAddrCallMatch;
        sum[11] += n.nAddrCallMismatch;
        sum[12] += n.nAddrCallMismatchLeaf;
    }
    {
        std::ofstream o(dir + "/mlir-attrrefs.tsv");
        for (auto &kv : attrRefCount)
            o << kv.first.first << "\t" << kv.first.second << "\t" << kv.second
              << "\n";
    }
    unsigned nDefFn = 0, nReachedFn = 0, nGcFree = 0;
    for (size_t i = 0; i < C.nodes.size(); ++i)
        if (C.nodes[i].isFunc && C.nodes[i].defined) {
            ++nDefFn;
            nReachedFn += reached[i];
            nGcFree += !poisoned[i];
        }
    llvm::errs() << "[spike] census nodes=" << C.nodes.size()
                 << " defined_fns=" << nDefFn << " reached_fns=" << nReachedFn
                 << " covered=" << nCovered << " gcfree=" << nGcFree
                 << " utils_equal_leaf=" << C.utilsEqualLeaf << "\n";
    llvm::errs() << "[spike] counts list_tail=" << sum[0] << " sat=" << sum[1]
                 << " value_eq=" << sum[2] << " cursor=" << sum[3]
                 << " scratch=" << sum[4] << " tli_only=" << sum[5]
                 << " markers_unreach=" << sum[6] << " calls_unreach=" << sum[7]
                 << " unreach_blocks=" << sum[8] << " addr_unused=" << sum[9]
                 << " addrcall_match=" << sum[10]
                 << " addrcall_mismatch=" << sum[11]
                 << " addrcall_mismatch_leaf=" << sum[12]
                 << " attrref_kinds=" << attrRefCount.size() << "\n";
    llvm::errs() << "[spike] time collect=" << tCollect << " bfs=" << tBfs
                 << " plan=" << tPlan << " gc=" << tGc
                 << " total=" << secs(T0) << " rss_peak_mb=" << maxRssMB()
                 << " (before " << rss0 << ")\n";

    // ---- SP1: partitions (LPT by op count), $cap/cross-partition counts ------
    const unsigned N = 24;
    std::vector<int> part(C.nodes.size(), -1);
    {
        std::vector<int> fns;
        for (size_t i = 0; i < C.nodes.size(); ++i)
            if (C.nodes[i].isFunc && C.nodes[i].defined)
                fns.push_back((int)i);
        std::sort(fns.begin(), fns.end(), [&](int a, int b) {
            if (C.nodes[a].opCount != C.nodes[b].opCount)
                return C.nodes[a].opCount > C.nodes[b].opCount;
            return C.nodes[a].name < C.nodes[b].name;
        });
        using L = std::pair<int64_t, unsigned>;
        std::priority_queue<L, std::vector<L>, std::greater<L>> heap;
        for (unsigned p = 0; p < N; ++p)
            heap.push({0, p});
        for (int f : fns) {
            L l = heap.top();
            heap.pop();
            part[f] = (int)l.second;
            heap.push({l.first + C.nodes[f].opCount + 1, l.second});
        }
        // globals: partition of their first referrer (else 0)
        for (size_t i = 0; i < C.nodes.size(); ++i)
            for (int r : C.nodes[i].refs)
                if (!C.nodes[r].isFunc && part[r] < 0 && part[i] >= 0)
                    part[r] = part[i];
        for (size_t i = 0; i < C.nodes.size(); ++i)
            if (part[i] < 0 && C.nodes[i].defined)
                part[i] = 0;
    }
    {
        // 01-M5: directly called $cap functions per partition (copy cost)
        std::vector<llvm::DenseSet<int>> capImports(N);
        unsigned capDefined = 0, capCovered = 0, capCalled = 0;
        unsigned maxDepth = 0;
        for (size_t i = 0; i < C.nodes.size(); ++i) {
            Node &n = C.nodes[i];
            if (n.isFunc && n.defined && n.name.ends_with("$cap")) {
                ++capDefined;
                capCovered += covered[i];
            }
        }
        llvm::DenseSet<int> calledCaps;
        for (size_t i = 0; i < C.nodes.size(); ++i)
            for (int c : C.nodes[i].gcCallees)
                if (C.nodes[c].name.ends_with("$cap")) {
                    calledCaps.insert(c);
                    if (part[c] != part[i] && part[i] >= 0)
                        capImports[part[i]].insert(c);
                }
        capCalled = calledCaps.size();
        // nested $cap -> $cap depth (DFS with memo)
        std::vector<int> depth(C.nodes.size(), -1);
        std::function<int(int, int)> dfs = [&](int f, int d) -> int {
            if (d > 64)
                return 64;
            if (depth[f] >= 0)
                return depth[f];
            depth[f] = 0;
            int best = 0;
            for (int c : C.nodes[f].gcCallees)
                if (C.nodes[c].name.ends_with("$cap"))
                    best = std::max(best, 1 + dfs(c, d + 1));
            depth[f] = best;
            return best;
        };
        for (int c : calledCaps)
            maxDepth = std::max<unsigned>(maxDepth, dfs(c, 0));
        size_t impMin = SIZE_MAX, impMax = 0, impSum = 0;
        for (auto &s : capImports) {
            impMin = std::min<size_t>(impMin, s.size());
            impMax = std::max<size_t>(impMax, s.size());
            impSum += s.size();
        }
        // 02-M4: gc-free functions with a caller / callee in another partition
        unsigned gcCrossCaller = 0, gcCrossCallee = 0, crossEdges = 0,
                 totalEdges = 0;
        for (size_t i = 0; i < C.nodes.size(); ++i) {
            Node &n = C.nodes[i];
            if (!n.isFunc || !n.defined)
                continue;
            bool anyCrossCallee = false;
            for (int c : n.gcCallees) {
                ++totalEdges;
                if (part[c] != part[i]) {
                    ++crossEdges;
                    anyCrossCallee = true;
                }
            }
            if (!poisoned[i]) {
                gcCrossCallee += anyCrossCallee;
                for (int cl : callers[i])
                    if (part[cl] != part[i]) {
                        ++gcCrossCaller;
                        break;
                    }
            }
        }
        llvm::errs() << "[spike] cap defined=" << capDefined
                     << " covered=" << capCovered
                     << " directly_called=" << capCalled
                     << " imports_per_partition(min/avg/max)=" << impMin << "/"
                     << impSum / N << "/" << impMax
                     << " max_nested_depth=" << maxDepth << "\n";
        llvm::errs() << "[spike] partitions N=" << N
                     << " call_edges=" << totalEdges
                     << " cross_partition_edges=" << crossEdges
                     << " gcfree_with_cross_caller=" << gcCrossCaller
                     << " gcfree_with_cross_callee=" << gcCrossCallee << "\n";
    }

    if (!envOn("ECO_SPIKE_PARTITION_TRANSLATE"))
        return;

    // ---- SP1: build partition modules in parallel, translate in parallel ----
    registerBuiltinDialectTranslation(*C.ctx);
    registerLLVMDialectTranslation(*C.ctx);
    const bool stampAttrs = envOn("ECO_SPIKE_STAMP_ATTRS"); // 01-M8
    long rssA = maxRssMB();
    auto Tbuild = Clock::now();
    std::vector<std::vector<int>> owned(N);
    for (size_t i = 0; i < C.nodes.size(); ++i)
        if (part[i] >= 0 && C.nodes[i].defined)
            owned[part[i]].push_back((int)i);
    std::vector<OwningOpRef<ModuleOp>> mods(N);
    std::vector<unsigned> idxs(N);
    for (unsigned p = 0; p < N; ++p)
        idxs[p] = p;
    std::atomic<unsigned> buildFail{0};
    parallelForEach(C.ctx, idxs, [&](unsigned p) {
        OpBuilder b(C.ctx);
        auto m = ModuleOp::create(b.getUnknownLoc());
        for (NamedAttribute na : module->getAttrs())
            if (na.getName() != SymbolTable::getSymbolAttrName())
                m->setAttr(na.getName(), na.getValue());
        b.setInsertionPointToEnd(m.getBody());
        llvm::DenseSet<int> ownedSet(owned[p].begin(), owned[p].end());
        llvm::DenseSet<int> needDecl;
        std::vector<Operation *> nonSym;
        if (p == 0)
            for (Operation *op : C.nonSymbolTops)
                nonSym.push_back(op);
        for (int i : owned[p])
            for (int r : C.nodes[i].refs)
                if (!ownedSet.count(r))
                    needDecl.insert(r);
        if (p == 0)
            for (auto &v : C.nonSymbolRefs)
                for (int r : v)
                    if (!ownedSet.count(r))
                        needDecl.insert(r);
        // declarations first, in module order (deterministic)
        std::vector<int> decls(needDecl.begin(), needDecl.end());
        std::sort(decls.begin(), decls.end());
        for (int r : decls) {
            Operation *src = C.nodes[r].op;
            Operation *d = src->cloneWithoutRegions();
            if (auto f = dyn_cast<LLVM::LLVMFuncOp>(d)) {
                f.setLinkage(LLVM::Linkage::External);
            } else if (auto g = dyn_cast<LLVM::GlobalOp>(d)) {
                g.removeValueAttr();
                g.setLinkage(LLVM::Linkage::External);
            }
            m.getBody()->push_back(d);
        }
        for (int i : owned[p]) {
            Operation *c = b.clone(*C.nodes[i].op);
            if (auto f = dyn_cast<LLVM::LLVMFuncOp>(c)) {
                if (f.getLinkage() == LLVM::Linkage::Internal ||
                    f.getLinkage() == LLVM::Linkage::Private)
                    f.setLinkage(LLVM::Linkage::External);
                if (stampAttrs) {
                    SmallVector<Attribute> pt;
                    if (auto old = f->getAttrOfType<ArrayAttr>("passthrough"))
                        pt.append(old.begin(), old.end());
                    pt.push_back(ArrayAttr::get(
                        C.ctx, {StringAttr::get(C.ctx, "eco-cap-budget"),
                                StringAttr::get(C.ctx, std::to_string(
                                                           C.nodes[i].budget))}));
                    f->setAttr("passthrough", ArrayAttr::get(C.ctx, pt));
                }
            } else if (auto g = dyn_cast<LLVM::GlobalOp>(c)) {
                if (g.getLinkage() == LLVM::Linkage::Internal ||
                    g.getLinkage() == LLVM::Linkage::Private)
                    g.setLinkage(LLVM::Linkage::External);
            }
        }
        for (Operation *op : nonSym)
            b.clone(*op);
        mods[p] = OwningOpRef<ModuleOp>(m);
    });
    double tBuild = secs(Tbuild);
    long rssB = maxRssMB();

    auto Ttr = Clock::now();
    std::vector<std::unique_ptr<llvm::LLVMContext>> lctx(N);
    std::vector<std::unique_ptr<llvm::Module>> lmods(N);
    std::vector<double> tEach(N, 0);
    std::atomic<unsigned> trFail{0}, verifyFail{0};
    parallelForEach(C.ctx, idxs, [&](unsigned p) {
        auto t = Clock::now();
        lctx[p] = std::make_unique<llvm::LLVMContext>();
        lmods[p] = translateModuleToLLVMIR(*mods[p], *lctx[p], "part",
                                           /*disableVerification=*/true);
        if (!lmods[p]) {
            ++trFail;
            return;
        }
        if (llvm::verifyModule(*lmods[p], &llvm::errs()))
            ++verifyFail;
        tEach[p] = secs(t);
    });
    double tTr = secs(Ttr);
    long rssC = maxRssMB();

    // counts vs the single module; block-count check (01-M4: does translation
    // keep unreachable blocks?)
    unsigned defFns = 0, globals = 0, blockMismatch = 0, blockChecked = 0;
    for (unsigned p = 0; p < N; ++p) {
        if (!lmods[p])
            continue;
        for (llvm::Function &f : *lmods[p]) {
            if (f.isDeclaration())
                continue;
            ++defFns;
            int src = C.lookup(f.getName());
            if (src >= 0 && blockChecked < 200000) {
                ++blockChecked;
                auto mf = cast<LLVM::LLVMFuncOp>(C.nodes[src].op);
                if (mf.getBody().getBlocks().size() != f.size())
                    ++blockMismatch;
            }
        }
        for (llvm::GlobalVariable &g : lmods[p]->globals())
            if (!g.isDeclaration())
                ++globals;
    }
    double tMax = 0;
    for (double t : tEach)
        tMax = std::max(tMax, t);
    llvm::errs() << "[spike] partition-translate N=" << N
                 << " build=" << tBuild << "s translate_wall=" << tTr
                 << "s slowest_partition=" << tMax << "s translate_fail="
                 << trFail.load() << " verify_fail=" << verifyFail.load()
                 << " defined_fns=" << defFns << " (single=" << nDefFn << ")"
                 << " defined_globals=" << globals
                 << " block_count_mismatch=" << blockMismatch << "/"
                 << blockChecked << " stamp_attrs=" << stampAttrs
                 << " rss_mb before=" << rssA << " after_build=" << rssB
                 << " after_translate=" << rssC << "\n";
}
