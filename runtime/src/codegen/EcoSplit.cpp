//===- EcoSplit.cpp - Partition in MLIR, translate and lower in parallel --===//
//
// plans/mlir-split-backend-05-ecosplit.md Part II U1/U2 (CGEN_083).
//
//===----------------------------------------------------------------------===//
#include "EcoSplit.h"
#include "LoweringStats.h"

#include "Passes/EcoCapHoistCore.h"
#include "Passes/EcoSymbolGraph.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Threading.h"
#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/ADT/Sequence.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <queue>
#include <string>
#include <thread>
#include <vector>

using namespace mlir;

namespace eco {

namespace {

bool envZero(const char *n) {
    const char *e = ::getenv(n);
    return e && e[0] == '0' && e[1] == '\0';
}
bool envOn(const char *n) {
    const char *e = ::getenv(n);
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

// The `$cap` prepass threshold (runCapInlinePrepass): 0 disables it.
unsigned capInlineMaxInsts() {
    if (const char *e = ::getenv("ECO_CAP_INLINE_MAX_INSTS"))
        return (unsigned)strtoul(e, nullptr, 10);
    return 64;
}

// The `eco-cap-*` entries of an op's passthrough, canonicalized (01 S6).
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

using Clock = std::chrono::steady_clock;
double secs(Clock::time_point t) {
    return std::chrono::duration<double>(Clock::now() - t).count();
}

struct SplitPlan {
    std::vector<OwningOpRef<ModuleOp>> mods;
    std::vector<std::vector<std::string>> exports;
};

// U1: ownership, imports, exports, clone, S6, census.
llvm::Expected<SplitPlan> buildPartitions(ModuleOp src, unsigned N, bool imports) {
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
    parallelForEach(ctx, defFns, [&](uint32_t i) {
        uint64_t c = 1;
        g.nodes[i].op->walk([&](Operation *) { ++c; });
        cost[i] = c;
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
    // Globals: the owner of their first referrer in module order, else 0.
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

    // Per-partition membership: 1 = owned, 2 = import copy, 3 = declaration.
    std::vector<std::vector<uint8_t>> role(N, std::vector<uint8_t>(n, 0));
    for (uint32_t i = 0; i < n; ++i)
        if (owner[i] >= 0)
            role[owner[i]][i] = 1;

    // Imports: the Call-bit closure into `$cap` bodies owned elsewhere
    // (AlwaysInliner inlines recursively), only when the prepass will run.
    std::vector<uint64_t> importCount(N, 0);
    if (imports) {
        parallelForEach(ctx, llvm::seq<unsigned>(0, N), [&](unsigned p) {
            std::vector<uint32_t> work;
            auto visit = [&](uint32_t src) {
                for (uint32_t e = g.outBegin[src]; e < g.outBegin[src + 1];
                     ++e) {
                    uint32_t t = g.outTarget[e];
                    if ((g.outKind[e] & symgraph::Call) && isCap(t) &&
                        role[p][t] == 0) {
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
                ++importCount[p];
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

    // The one whole-module expansion gate (review R13).
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

    // Test hook (G8): drop `eco-cap-covered` from the declarations / copies
    // of one symbol, or of every symbol with `*`, to prove S6 fires.
    const char *faultCovered = ::getenv("ECO_SPLIT_FAULT_DROP_COVERED");
    auto faultHits = [&](StringRef name) {
        return faultCovered &&
               (StringRef(faultCovered) == "*" || name == faultCovered);
    };

    SplitPlan plan;
    plan.mods.resize(N);
    plan.exports.resize(N);
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
            case 1:
                b.clone(*op);
                break;
            case 2: {
                Operation *c = b.clone(*op);
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
            b.create<LLVM::ModuleFlagsOp>(
                src.getLoc(),
                ArrayAttr::get(ctx, {LLVM::ModuleFlagAttr::get(
                                        ctx, LLVM::ModFlagBehavior::Warning,
                                        StringAttr::get(ctx, "eco-list-chunks"),
                                        StringAttr::get(ctx, "1"))}));
        plan.mods[p] = OwningOpRef<ModuleOp>(m);
        for (uint32_t i = 0; i < n; ++i)
            if (exported[p][i])
                plan.exports[p].push_back(g.nodes[i].name.getValue().str());
    });

    // 01 S6: a declaration or import copy must carry exactly its owner's
    // eco-cap-* facts — a dropped `covered` bit is heap corruption, not a
    // missed optimization. Release-build hard error.
    for (unsigned p = 0; p < N; ++p)
        if (!s6[p].empty())
            return llvm::createStringError(
                std::errc::invalid_argument,
                "EcoSplit: partition %u's declaration or copy of '%s' does "
                "not carry its owner's eco-cap facts (01 S6)",
                p, s6[p].c_str());

    if (envOn("ECO_MLIR_SPLIT_STATS")) {
        uint64_t imin = UINT64_MAX, imax = 0, isum = 0, decls = 0, exps = 0;
        for (unsigned p = 0; p < N; ++p) {
            imin = std::min(imin, importCount[p]);
            imax = std::max(imax, importCount[p]);
            isum += importCount[p];
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
                     << "/" << imax << " exports=" << exps
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
    // Registered ONCE, before any worker translates (review R7).
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
        auto planOr = buildPartitions(module, N, imports);
        if (!planOr)
            return planOr.takeError();
        plan = std::move(*planOr);
    }

    // The source module is no longer needed: destroy its body off the
    // critical path (it was a serial 1.17 s teardown, review R8). The
    // partitions are independent clones; attributes and types are immortal.
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
            job.splitEligible = true; // the parallel tier (review R1)
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
