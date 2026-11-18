//===- EcoSplit.cpp - Partition in MLIR, translate and lower in parallel --===//
//
// The split has to agree with the partition-worker mode of `runEcoBackend`
// about one case. An exported `$cap` that nothing takes the address of is
// called only by direct calls whose types match. Every partition holding a
// copy of it sees the same body after the same expansions, so the `$cap`
// prepass marks it for inlining in all of them or in none. Such a function is
// therefore exported *late*: its owner exports it only if it survives the
// prepass. If it was deleted, every importer must have inlined its copies too,
// and `lowerMlirSplit` checks that after the workers join.
//
//===----------------------------------------------------------------------===//
#include "EcoSplit.h"
#include "LoweringStats.h"

#include "Passes/EcoCapHoistCore.h"
#include "Passes/EcoSymbolGraph.h"
#include "Passes/EcoParallel.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"
#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/ADT/Sequence.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"

#include <algorithm>
#include <atomic>
#include <fstream>
#include <functional>
#include <chrono>
#include <cstdlib>
#include <queue>
#include <string>
#include <thread>
#include <vector>

using namespace mlir;

namespace eco {

namespace {

// Returns whether environment variable `n` is exactly `0`.
bool envZero(const char *n) {
    const char *e = ::getenv(n);
    return e && e[0] == '0' && e[1] == '\0';
}
// Returns whether environment variable `n` is set, not empty and not `0`.
bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

// Returns the `$cap` prepass's instruction threshold, from
// `ECO_CAP_INLINE_MAX_INSTS` or 64 by default. At 0 no import copies are made.
// It repeats `runCapInlinePrepass`'s reading of the variable; the two must
// change together.
unsigned capInlineMaxInsts() {
    if (const char *e = ::getenv("ECO_CAP_INLINE_MAX_INSTS"))
        return (unsigned)strtoul(e, nullptr, 10);
    return 64;
}

// Returns plan 08 option P's op cap, from `ECO_SPLIT_IMPORT_LEAF_MAX_OPS`, or
// 128 by default; 0 turns leaf import copies off. With a cap K above 0, a
// function stamped `gc-leaf-function` with at most K MLIR ops is also
// import-copied into every partition that reaches it by direct calls, as
// `EcoSplit.h` describes.
unsigned importLeafMaxOps() {
    static const unsigned k = [] {
        if (const char *e = ::getenv("ECO_SPLIT_IMPORT_LEAF_MAX_OPS"))
            return (unsigned)strtoul(e, nullptr, 10);
        return 128u;
    }();
    return k;
}

// Returns the inline threshold stamped on solo callees (plan 08 §2d), from
// `ECO_SPLIT_SOLO_INLINE_THRESHOLD`, or 15225 by default (LLVM's default
// threshold of 225 plus its 15,000 bonus for the last call to a local
// function); 0 turns the stamp off.
unsigned soloInlineThreshold() {
    static const unsigned t = [] {
        if (const char *e = ::getenv("ECO_SPLIT_SOLO_INLINE_THRESHOLD"))
            return (unsigned)strtoul(e, nullptr, 10);
        return 15225u;
    }();
    return t;
}

// Appends the passthrough entry `key`=`value` to `op`.
void addPassthroughValue(Operation *op, StringRef key, StringRef value) {
    Builder b(op->getContext());
    SmallVector<Attribute> pt;
    if (auto a = op->getAttrOfType<ArrayAttr>("passthrough"))
        pt.append(a.begin(), a.end());
    pt.push_back(b.getArrayAttr({b.getStringAttr(key), b.getStringAttr(value)}));
    op->setAttr("passthrough", b.getArrayAttr(pt));
}

// Returns whether `op` carries the passthrough `gc-leaf-function`.
bool isGcLeafOp(Operation *op) {
    if (auto pt = op->getAttrOfType<ArrayAttr>("passthrough"))
        for (Attribute a : pt)
            if (auto s = dyn_cast<StringAttr>(a);
                s && s.getValue() == "gc-leaf-function")
                return true;
    return false;
}

// Returns the `eco-cap-*` entries of `op`'s `passthrough` attribute as one
// string, sorted, so that two ops' facts can be compared for equality.
std::string capFacts(Operation *op) {
    std::vector<std::string> facts;
    if (auto pt = op->getAttrOfType<ArrayAttr>("passthrough"))
        for (Attribute a : pt) {
            if (auto s = dyn_cast<StringAttr>(a)) {
                if (s.getValue().starts_with("eco-cap-"))
                    facts.push_back(s.getValue().str());
            } else if (auto kv = dyn_cast<ArrayAttr>(a)) {
                if (kv.size() == 2)
                    if (auto k = dyn_cast<StringAttr>(kv[0]))
                        if (k.getValue().starts_with("eco-cap-"))
                            if (auto v = dyn_cast<StringAttr>(kv[1]))
                                facts.push_back(k.getValue().str() + "=" +
                                                v.getValue().str());
            }
        }
    std::sort(facts.begin(), facts.end());
    std::string out;
    for (auto &f : facts)
        out += f + ";";
    return out;
}

// Removes every valueless entry `key` from `op`'s `passthrough` attribute.
void dropPassthrough(Operation *op, StringRef key) {
    auto pt = op->getAttrOfType<ArrayAttr>("passthrough");
    if (!pt)
        return;
    SmallVector<Attribute> keep;
    for (Attribute a : pt)
        if (!(isa<StringAttr>(a) && cast<StringAttr>(a).getValue() == key))
            keep.push_back(a);
    op->setAttr("passthrough", ArrayAttr::get(op->getContext(), keep));
}

// The clock the split's timings use.
using Clock = std::chrono::steady_clock;
// Returns the seconds elapsed since `t`.
double secs(Clock::time_point t) {
    return std::chrono::duration<double>(Clock::now() - t).count();
}

/**
 * The partitions of a module, with what each must export; each vector has
 * one entry per partition.
 */
struct SplitPlan {
    std::vector<OwningOpRef<ModuleOp>> mods;
    // Owned functions another partition declares or copies, other than those
    // in `exportsLate`.
    std::vector<std::vector<std::string>> exports;
    // Owned functions to export only if they survive the owner's prepass.
    std::vector<std::vector<std::string>> exportsLate;
};

// Builds `N` partitions of `src`, as `EcoSplit.h`'s file comment describes,
// making `$cap` import copies only when `imports` is set, and leaf import
// copies of at most `leafMaxOps` ops only when it is above 0. When
// `soloThreshold` is above 0, every definition of a solo callee in the
// partitions, owned or copied, gets `function-inline-threshold` set to it.
// `N` must be at least 1.
// `src` is not changed. Returns an error if a declaration or copy fails the
// fact check. With `ECO_MLIR_SPLIT_STATS` set to a value other than empty or
// `0`, prints a summary of the split to stderr.
llvm::Expected<SplitPlan> buildPartitions(ModuleOp src, unsigned N, bool imports,
                                          unsigned leafMaxOps,
                                          unsigned soloThreshold) {
    auto T0 = Clock::now();
    MLIRContext *ctx = src.getContext();
    symgraph::Graph g = symgraph::build(src, /*keepUnusedAddressOf=*/true);
    const size_t n = g.nodes.size();

    // Op counts of the defined functions (the LPT cost).
    std::vector<uint32_t> defFns;
    for (uint32_t i = 0; i < n; ++i)
        if (g.nodes[i].isFunc && g.nodes[i].isDef)
            defFns.push_back(i);
    std::vector<uint64_t> cost(n, 0);
    eco::forEachChunk(ctx, defFns.size(), [&](size_t lo, size_t hi) {
        for (size_t k = lo; k < hi; ++k) {
            uint32_t i = defFns[k];
            uint64_t c = 1;
            g.nodes[i].op->walk([&](Operation *) { ++c; });
            cost[i] = c;
        }
    });

    // Ownership: LPT over functions (cost desc, then name), deterministic.
    std::vector<int> owner(n, -1);
    {
        std::vector<uint32_t> order = defFns;
        std::sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) {
            if (cost[a] != cost[b])
                return cost[a] > cost[b];
            return g.nodes[a].name.getValue() < g.nodes[b].name.getValue();
        });
        using Load = std::pair<uint64_t, unsigned>;
        std::priority_queue<Load, std::vector<Load>, std::greater<Load>> heap;
        for (unsigned p = 0; p < N; ++p)
            heap.push({0, p});
        for (uint32_t f : order) {
            Load l = heap.top();
            heap.pop();
            owner[f] = (int)l.second;
            heap.push({l.first + cost[f], l.second});
        }
    }
    // Globals: the owner of their first already-placed referrer in module
    // order, else 0.
    for (uint32_t i = 0; i < n; ++i) {
        if (owner[i] < 0)
            continue;
        for (uint32_t e = g.outBegin[i]; e < g.outBegin[i + 1]; ++e) {
            uint32_t t = g.outTarget[e];
            if (g.nodes[t].isGlobal && g.nodes[t].isDef && owner[t] < 0)
                owner[t] = owner[i];
        }
    }
    for (uint32_t i = 0; i < n; ++i)
        if (g.nodes[i].isDef && owner[i] < 0)
            owner[i] = 0;

    auto isCap = [&](uint32_t i) {
        return g.nodes[i].isFunc && g.nodes[i].isDef &&
               g.nodes[i].name.getValue().ends_with("$cap");
    };

    // Solo callees (plan 08 §2d): GC-free functions other than `main` with
    // exactly one direct call site in the module, no address taken and no
    // reference from a non-symbol operation. In the whole module LLVM inlines
    // such a callee at almost any size, because it is local and the call is
    // its last use; in a partition it is often exported, which loses that
    // bonus, so its definitions get an explicit inline threshold instead.
    std::vector<char> solo(n, 0);
    if (soloThreshold > 0) {
        std::vector<int> caller(n, -1);
        std::vector<char> bad(n, 0);
        for (uint32_t t : g.extraRoots)
            bad[t] = 1;
        for (uint32_t i = 0; i < n; ++i)
            for (uint32_t e = g.outBegin[i]; e < g.outBegin[i + 1]; ++e) {
                uint32_t t = g.outTarget[e];
                if (symgraph::takesAddress(g.outKind[e]) || t == i ||
                    caller[t] >= 0 || !g.nodes[i].isFunc ||
                    !g.nodes[i].isDef)
                    bad[t] = 1;
                else
                    caller[t] = (int)i;
            }
        std::vector<uint32_t> cand;
        for (uint32_t t = 0; t < n; ++t)
            if (!bad[t] && caller[t] >= 0 && g.nodes[t].isFunc &&
                g.nodes[t].isDef && isGcLeafOp(g.nodes[t].op) &&
                g.nodes[t].name.getValue() != "main")
                cand.push_back(t);
        // One call site, not just one calling function.
        eco::forEachChunk(ctx, cand.size(), [&](size_t lo, size_t hi) {
            for (size_t k = lo; k < hi; ++k) {
                uint32_t t = cand[k];
                unsigned sites = 0;
                g.nodes[caller[t]].op->walk([&](LLVM::CallOp c) {
                    if (auto cal = c.getCalleeAttr())
                        if (cal.getAttr() == g.nodes[t].name)
                            ++sites;
                });
                solo[t] = sites == 1;
            }
        });
    }

    // Per-partition membership: 1 = owned, 2 = import copy, 3 = declaration.
    std::vector<std::vector<uint8_t>> role(N, std::vector<uint8_t>(n, 0));
    for (uint32_t i = 0; i < n; ++i)
        if (owner[i] >= 0)
            role[owner[i]][i] = 1;

    // Small GC-free functions, the leaf import candidates (plan 08 P). A leaf
    // `$cap` is a `$cap` import, never a leaf one.
    auto isSmallLeaf = [&](uint32_t i) {
        return leafMaxOps > 0 && g.nodes[i].isFunc && g.nodes[i].isDef &&
               !isCap(i) && cost[i] <= leafMaxOps &&
               isGcLeafOp(g.nodes[i].op);
    };

    // Imports: the closure over direct-call edges into `$cap` bodies owned
    // elsewhere (AlwaysInliner inlines recursively), only when the prepass
    // will run, and into small leaf functions (the -O2 inliner is recursive
    // too) when `leafMaxOps` is above 0.
    std::vector<uint64_t> importCount(N, 0), leafImportCount(N, 0);
    if (imports || leafMaxOps > 0) {
        parallelForEach(ctx, llvm::seq<unsigned>(0, N), [&](unsigned p) {
            std::vector<uint32_t> work;
            auto visit = [&](uint32_t src) {
                for (uint32_t e = g.outBegin[src]; e < g.outBegin[src + 1];
                     ++e) {
                    uint32_t t = g.outTarget[e];
                    if ((g.outKind[e] & symgraph::Call) && role[p][t] == 0 &&
                        ((imports && isCap(t)) || isSmallLeaf(t))) {
                        role[p][t] = 2;
                        work.push_back(t);
                    }
                }
            };
            for (uint32_t i = 0; i < n; ++i)
                if (role[p][i] == 1)
                    visit(i);
            while (!work.empty()) {
                uint32_t t = work.back();
                work.pop_back();
                ++(isCap(t) ? importCount : leafImportCount)[p];
                visit(t);
            }
        });
    }

    // Declarations: everything an owned definition or an import copy names
    // that the partition does not hold. Non-symbol top-level ops go to 0.
    parallelForEach(ctx, llvm::seq<unsigned>(0, N), [&](unsigned p) {
        for (uint32_t i = 0; i < n; ++i) {
            if (role[p][i] != 1 && role[p][i] != 2)
                continue;
            for (uint32_t e = g.outBegin[i]; e < g.outBegin[i + 1]; ++e) {
                uint32_t t = g.outTarget[e];
                if (role[p][t] == 0)
                    role[p][t] = 3;
            }
        }
        if (p == 0)
            for (uint32_t t : g.extraRoots)
                if (role[0][t] == 0)
                    role[0][t] = 3;
    });

    // Exports: owned functions some other partition declares or imports
    // (an un-inlined import copy is dropped back to a declaration).
    std::vector<std::vector<char>> exported(N);
    for (unsigned p = 0; p < N; ++p)
        exported[p].assign(n, 0);
    for (unsigned p = 0; p < N; ++p)
        for (uint32_t i = 0; i < n; ++i)
            if ((role[p][i] == 2 || role[p][i] == 3) && owner[i] >= 0 &&
                g.nodes[i].isFunc)
                exported[owner[i]][i] = 1;

    // A `$cap` with no address-taking in-edge is exported late (file comment).
    std::vector<char> addressTaken(n, 0);
    for (uint32_t i = 0; i < n; ++i)
        for (uint32_t e = g.outBegin[i]; e < g.outBegin[i + 1]; ++e)
            if (symgraph::takesAddress(g.outKind[e]))
                addressTaken[g.outTarget[e]] = 1;
    for (uint32_t t : g.extraTakes)
        addressTaken[t] = 1;

    // The one whole-module expansion gate: a reference to
    // `eco_enable_list_chunks` from any symbol becomes the `eco-list-chunks`
    // module flag in every partition.
    bool listChunks = false;
    {
        int ce = g.lookup(StringAttr::get(ctx, "eco_enable_list_chunks"));
        if (ce >= 0)
            for (uint32_t e = 0; e < g.outTarget.size() && !listChunks; ++e)
                if (g.outTarget[e] == (uint32_t)ce)
                    listChunks = true;
    }

    std::vector<Operation *> nonSymbol;
    for (Operation &op : *src.getBody())
        if (!op.getAttrOfType<StringAttr>(SymbolTable::getSymbolAttrName()))
            nonSymbol.push_back(&op);

    // Test hook: drop `eco-cap-covered` from the declarations / copies
    // of one symbol, or of every symbol with `*`, so that tests can see the
    // fact check fail.
    const char *faultCovered = ::getenv("ECO_SPLIT_FAULT_DROP_COVERED");
    auto faultHits = [&](StringRef name) {
        return faultCovered &&
               (StringRef(faultCovered) == "*" || name == faultCovered);
    };

    SplitPlan plan;
    plan.mods.resize(N);
    plan.exports.resize(N);
    plan.exportsLate.resize(N);
    std::vector<std::string> s6(N);
    parallelForEach(ctx, llvm::seq<unsigned>(0, N), [&](unsigned p) {
        OpBuilder b(ctx);
        ModuleOp m = ModuleOp::create(src.getLoc());
        for (NamedAttribute na : src->getAttrs())
            if (na.getName() != SymbolTable::getSymbolAttrName())
                m->setAttr(na.getName(), na.getValue());
        b.setInsertionPointToEnd(m.getBody());
        for (uint32_t i = 0; i < n; ++i) {
            Operation *op = g.nodes[i].op;
            switch (role[p][i]) {
            case 1: {
                Operation *c = b.clone(*op);
                if (solo[i])
                    addPassthroughValue(c, "function-inline-threshold",
                                        std::to_string(soloThreshold));
                break;
            }
            case 2: {
                Operation *c = b.clone(*op);
                if (solo[i])
                    addPassthroughValue(c, "function-inline-threshold",
                                        std::to_string(soloThreshold));
                cast<LLVM::LLVMFuncOp>(c).setLinkage(
                    LLVM::Linkage::AvailableExternally);
                if (faultHits(g.nodes[i].name.getValue()))
                    dropPassthrough(c, caphoist::kAttrCovered);
                if (capFacts(c) != capFacts(op) && s6[p].empty())
                    s6[p] = g.nodes[i].name.getValue().str();
                break;
            }
            case 3: {
                Operation *d = op->cloneWithoutRegions();
                if (auto f = dyn_cast<LLVM::LLVMFuncOp>(d)) {
                    f.setLinkage(LLVM::Linkage::External);
                    f.setVisibility_(LLVM::Visibility::Default);
                    if (faultHits(g.nodes[i].name.getValue()))
                        dropPassthrough(d, caphoist::kAttrCovered);
                    if (capFacts(d) != capFacts(op) && s6[p].empty())
                        s6[p] = g.nodes[i].name.getValue().str();
                } else if (auto gv = dyn_cast<LLVM::GlobalOp>(d)) {
                    gv.removeValueAttr();
                    gv.setLinkage(LLVM::Linkage::External);
                    gv.setVisibility_(LLVM::Visibility::Default);
                }
                m.getBody()->push_back(d);
                break;
            }
            default:
                break;
            }
        }
        bool sawFlags = false;
        for (Operation *op : nonSymbol) {
            if (auto mf = dyn_cast<LLVM::ModuleFlagsOp>(op)) {
                auto c = cast<LLVM::ModuleFlagsOp>(b.clone(*mf));
                if (listChunks && !sawFlags) {
                    SmallVector<Attribute> flags(c.getFlags().begin(),
                                                 c.getFlags().end());
                    flags.push_back(LLVM::ModuleFlagAttr::get(
                        ctx, LLVM::ModFlagBehavior::Warning,
                        StringAttr::get(ctx, "eco-list-chunks"),
                        StringAttr::get(ctx, "1")));
                    c.setFlagsAttr(ArrayAttr::get(ctx, flags));
                }
                sawFlags = true;
            } else if (p == 0) {
                b.clone(*op);
            }
        }
        if (listChunks && !sawFlags)
            LLVM::ModuleFlagsOp::create(b,
                src.getLoc(),
                ArrayAttr::get(ctx, {LLVM::ModuleFlagAttr::get(
                                        ctx, LLVM::ModFlagBehavior::Warning,
                                        StringAttr::get(ctx, "eco-list-chunks"),
                                        StringAttr::get(ctx, "1"))}));
        plan.mods[p] = OwningOpRef<ModuleOp>(m);
        for (uint32_t i = 0; i < n; ++i)
            if (exported[p][i]) {
                if (isCap(i) && !addressTaken[i])
                    plan.exportsLate[p].push_back(
                        g.nodes[i].name.getValue().str());
                else
                    plan.exports[p].push_back(g.nodes[i].name.getValue().str());
            }
    });

    // The fact check is an error in every build type, not an assertion.
    for (unsigned p = 0; p < N; ++p)
        if (!s6[p].empty())
            return llvm::createStringError(
                std::errc::invalid_argument,
                "EcoSplit: partition %u's declaration or copy of '%s' does "
                "not carry its owner's eco-cap facts (01 S6)",
                p, s6[p].c_str());

    // Plan 08 S0/S1 census: with `ECO_MLIR_SPLIT_OWNERS` set to a path, writes
    // one line per defined function: name, owner, op count, `leaf` when it
    // carries `gc-leaf-function` (else `gc`), and the partitions holding an
    // import copy of it.
    if (const char *path = ::getenv("ECO_MLIR_SPLIT_OWNERS"); path && *path) {
        std::ofstream os(path);
        for (uint32_t i : defFns) {
            bool leaf = isGcLeafOp(g.nodes[i].op);
            os << g.nodes[i].name.getValue().str() << ' ' << owner[i] << ' '
               << cost[i] << ' ' << (leaf ? "leaf" : "gc") << ' ';
            bool any = false;
            for (unsigned p = 0; p < N; ++p)
                if (role[p][i] == 2) {
                    os << (any ? "," : "") << p;
                    any = true;
                }
            os << (any ? "\n" : "-\n");
        }
    }

    if (envOn("ECO_MLIR_SPLIT_STATS")) {
        uint64_t imin = UINT64_MAX, imax = 0, isum = 0, decls = 0, exps = 0,
                 lsum = 0, lmax0 = 0;
        for (unsigned p = 0; p < N; ++p) {
            imin = std::min(imin, importCount[p]);
            imax = std::max(imax, importCount[p]);
            isum += importCount[p];
            lsum += leafImportCount[p];
            lmax0 = std::max(lmax0, leafImportCount[p]);
            exps += plan.exports[p].size();
            for (uint32_t i = 0; i < n; ++i)
                decls += role[p][i] == 3;
        }
        std::vector<uint64_t> load(N, 0);
        for (uint32_t i : defFns)
            load[owner[i]] += cost[i];
        uint64_t lmin = *std::min_element(load.begin(), load.end());
        uint64_t lmax = *std::max_element(load.begin(), load.end());
        llvm::errs() << "[mlir-split] N=" << N << " defined=" << defFns.size()
                     << " imports(min/avg/max)=" << imin << "/" << isum / N
                     << "/" << imax << " leafImports(avg/max)=" << lsum / N
                     << "/" << lmax0 << " solo="
                     << std::count(solo.begin(), solo.end(), 1)
                     << " exports=" << exps
                     << " decls=" << decls << " ops(min/max)=" << lmin << "/"
                     << lmax << " chunks=" << listChunks
                     << " build=" << secs(T0) << "s\n";
    }
    return std::move(plan);
}

} // namespace

unsigned mlirSplitPartitionCount(ModuleOp module, const EcoBackendJob &job) {
    if (envZero("ECO_MLIR_SPLIT"))
        return 1;
    if (job.kind != BackendKind::EmitObjectFile || job.rs4gcAfterOpt ||
        job.optLevel == llvm::CodeGenOptLevel::None ||
        (job.parallelOpt != ParallelOpt::Cgu &&
         job.parallelOpt != ParallelOpt::Dev) ||
        !module.getContext()->isMultithreadingEnabled())
        return 1;
    unsigned defined = 0;
    for (auto f : module.getOps<LLVM::LLVMFuncOp>())
        defined += !f.isExternal();
    return choosePartitionCountForCount(defined, job.splitCodegen,
                                        job.splitEligible);
}

llvm::Error lowerMlirSplit(ModuleOp module, const EcoBackendJob &base,
                           unsigned N, EcoBackendResult *result) {
    MLIRContext *ctx = module.getContext();
    // Registered once, before any worker translates concurrently.
    registerBuiltinDialectTranslation(*ctx);
    registerLLVMDialectTranslation(*ctx);

    const bool imports =
        base.optLevel != llvm::CodeGenOptLevel::None && capInlineMaxInsts() != 0;

    SplitPlan plan;
    {
        std::unique_ptr<LoweringStats::Scope> s;
        if (base.stats)
            s = std::make_unique<LoweringStats::Scope>(
                *base.stats, "  EcoSplit build (parallel clone)");
        auto planOr = buildPartitions(
            module, N, imports,
            base.parallelOpt == ParallelOpt::Cgu ? importLeafMaxOps() : 0,
            base.parallelOpt == ParallelOpt::Cgu ? soloInlineThreshold() : 0);
        if (!planOr)
            return planOr.takeError();
        plan = std::move(*planOr);
    }

    // The source module is no longer needed: destroy its body off the
    // critical path. The partitions are independent clones; attributes and
    // types live in the shared context.
    std::thread teardown([module]() mutable {
        for (Operation &op : llvm::make_early_inc_range(*module.getBody())) {
            op.dropAllReferences();
            op.erase();
        }
    });

    // Object paths: the caller's for partition 0, temporaries for the rest.
    std::vector<std::string> paths{base.objectFilePath};
    std::vector<std::string> owned;
    for (unsigned i = 1; i < N; ++i) {
        llvm::SmallString<256> p;
        if (auto ec = llvm::sys::fs::createTemporaryFile("eco-part", "o", p)) {
            teardown.join();
            for (auto &f : owned)
                llvm::sys::fs::remove(f);
            return llvm::createStringError(
                ec, "Could not create temp object file for partition");
        }
        paths.emplace_back(p.str());
        owned.emplace_back(p.str());
    }

    std::vector<PartitionWorkerInfo> info(N);
    std::vector<std::string> errs(N);
    std::atomic<unsigned> failures{0};
    std::vector<std::thread> threads;
    threads.reserve(N);
    for (unsigned i = 0; i < N; ++i) {
        info[i].index = i;
        info[i].exports = std::move(plan.exports[i]);
        info[i].exportsLate = std::move(plan.exportsLate[i]);
        threads.emplace_back([&, i] {
            setPartitionIndex((int)i);
            llvm::LLVMContext lctx;
            std::unique_ptr<llvm::Module> lm;
            {
                std::unique_ptr<LoweringStats::Scope> s;
                if (base.stats)
                    s = std::make_unique<LoweringStats::Scope>(
                        *base.stats, "  partition translate (sum over workers)");
#ifdef ECO_LOWERING_VALIDATION
                constexpr bool kDisableLLVMVerify = false;
#else
                constexpr bool kDisableLLVMVerify = true;
#endif
                lm = translateModuleToLLVMIR(*plan.mods[i], lctx,
                                             "eco-part-" + std::to_string(i),
                                             kDisableLLVMVerify);
                plan.mods[i] = nullptr; // free this partition's MLIR now
            }
            if (!lm) {
                errs[i] = "translation failed for partition " +
                          std::to_string(i);
                ++failures;
                return;
            }
            // The C entry wrapper owns `main`.
            if (llvm::Function *mf = lm->getFunction("main"))
                mf->setName("eco_main");
            if (hasReachabilityStamp(*lm))
                if (auto err = finishReachability(*lm, {}, /*partition=*/true)) {
                    errs[i] = llvm::toString(std::move(err));
                    ++failures;
                    return;
                }
            unsigned emitLevel = static_cast<unsigned>(base.optLevel);
            if (base.parallelOpt == ParallelOpt::Dev &&
                base.devEmitCodeGenLevel != ~0u)
                emitLevel = base.devEmitCodeGenLevel;
            auto tm = createEcoTargetMachine(*lm, emitLevel);
            if (!tm) {
                errs[i] = "createEcoTargetMachine failed for partition " +
                          std::to_string(i);
                ++failures;
                return;
            }
            EcoBackendJob job = base;
            job.tm = tm.get();
            job.objectFilePath = paths[i];
            job.splitEligible = true; // keeps the parallel tier
            job.splitCodegen = 1;     // ... but never split again
            job.partition = &info[i];
            EcoBackendResult r;
            if (auto err = runEcoBackend(*lm, job, &r)) {
                errs[i] = "partition " + std::to_string(i) + ": " +
                          llvm::toString(std::move(err));
                ++failures;
                return;
            }
        });
    }
    {
        std::unique_ptr<LoweringStats::Scope> s;
        if (base.stats)
            s = std::make_unique<LoweringStats::Scope>(
                *base.stats, "  parallel lower drain (post-split wait)");
        for (auto &t : threads)
            t.join();
    }
    teardown.join();

    if (failures.load()) {
        for (auto &f : owned)
            llvm::sys::fs::remove(f);
        for (auto &e : errs)
            if (!e.empty())
                return llvm::createStringError(std::errc::io_error, "%s",
                                               e.c_str());
    }
    // An importer that could not fully inline a marked copy of a body its
    // owner deleted would leave an undefined reference at link; name it here
    // instead.
    {
        llvm::StringSet<> deleted;
        for (auto &pi : info)
            for (auto &d : pi.deletedLate)
                deleted.insert(d);
        for (auto &pi : info)
            for (auto &sv : pi.markedSurvivors)
                if (deleted.contains(sv)) {
                    for (auto &f : owned)
                        llvm::sys::fs::remove(f);
                    return llvm::createStringError(
                        std::errc::invalid_argument,
                        "EcoSplit B4: partition %u kept a marked copy of '%s', "
                        "whose owner deleted the body",
                        pi.index, sv.c_str());
                }
    }
    std::vector<GcLeafPartitionReport> reports;
    reports.reserve(N);
    for (auto &pi : info)
        reports.push_back(std::move(pi.gcReport));
    if (auto err = joinPartitionGcLeafReports(reports)) {
        for (auto &f : owned)
            llvm::sys::fs::remove(f);
        return err;
    }
    if (result) {
        result->objectFiles = std::move(paths);
        result->ownedTempFiles = std::move(owned);
    }
    return llvm::Error::success();
}

} // namespace eco
