//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"

#include "LoweringStats.h"
#include "Passes/EcoPtrIntVerify.h" // for addEcoGCPipeline
#include "Passes/EcoSlotCastBarriers.h" // REP_LLVM_002: barrier switch <-> gcfree-guard coupling

#include "mlir/ExecutionEngine/OptUtils.h" // for makeOptimizingTransformer

#include <algorithm>

#include "llvm/IR/Function.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Host.h"   // getDefaultTargetTriple
#include "llvm/TargetParser/Triple.h"
#include "llvm/Transforms/IPO/Internalize.h"
#include "llvm/Transforms/IPO/GlobalDCE.h"
#include "llvm/Transforms/IPO/SCCP.h"           // IPSCCPPass
#include "llvm/Transforms/IPO/GlobalOpt.h"      // GlobalOptPass
#include "llvm/Transforms/IPO/FunctionAttrs.h"  // Post/ReversePostOrderFunctionAttrsPass
#include "llvm/Transforms/IPO/AlwaysInliner.h"  // AlwaysInlinerPass
#include "llvm/Analysis/CGSCCPassManager.h"     // createModuleToPostOrderCGSCCPassAdaptor
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/Passes/OptimizationLevel.h"
#include "llvm/Transforms/Utils/SplitModule.h"
#include "llvm/Transforms/Utils/Local.h"        // callsGCLeafFunction (GCFREE)
#include "llvm/Analysis/TargetLibraryInfo.h"    // TargetLibraryInfo (GCFREE)
#include "llvm/IR/Statepoint.h"                 // GCStatepointInst (GCFREE)
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include <cstdlib>  // getenv/strtoul (E1.3 threshold override)
#include <fstream>  // ECO_CAP_INLINE_LIST delta-debug hook
#include <set>
#include <string>
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalIFunc.h"
#include "llvm/IR/GlobalValue.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h" // SplitBlockAndInsertIfThen
#include "../allocator/Heap.hpp"                   // TAG_BITS, Elm::Tag_Forward

#include <cstdint>

#include <atomic>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

using namespace llvm;

namespace eco {

namespace {

// RAII sub-phase timing scope that is a no-op when `stats` is null.
struct MaybeScope {
    MaybeScope(eco::LoweringStats *stats, llvm::StringRef name) {
        if (stats)
            scope.emplace(*stats, name);
    }
    std::optional<eco::LoweringStats::Scope> scope;
};

// GC-free function propagation (plans/gc-free-function-propagation.md).
//
// ECO_GCFREE_LEAF: unset/"0" = off (default); "c" = census only (analysis
// runs, nothing is stamped, the module is byte-identical to a flag-off
// run); "1" (any other value) = stamp gc-leaf-function on provably GC-free
// generated functions so RS4GC skips statepointing calls to them.
//
// Lowering-affecting in stamp mode: census/A-B workflows must rebuild via
// the delete-outputs discipline (ninja is env-blind, tier2-opt.md Phase 1).
//
// Defined HERE (not next to propagateGcFreeLeafAttrs, ~:1419) because the
// stamp-mode structural assert lives in runRS4GCAndMaybeFramePointers
// (~:651), ~750 lines earlier than that function.
enum class GcFreeMode { Off, Census, Stamp };

GcFreeMode gcFreeLeafMode() {
    static const GcFreeMode mode = [] {
        const char *e = ::getenv("ECO_GCFREE_LEAF");
        if (!e || !*e || (e[0] == '0' && e[1] == '\0'))
            return GcFreeMode::Off;
        if (e[0] == 'c' && e[1] == '\0')
            return GcFreeMode::Census;
        return GcFreeMode::Stamp;
    }();
    return mode;
}

void dumpIRTo(const Module &m, const std::string &path, const char *tag) {
    std::error_code ec;
    raw_fd_ostream out(path, ec);
    if (!ec) {
        out << m;
        errs() << "[" << tag << "] Dumped " << tag << " IR to " << path
               << "\n";
    } else {
        errs() << "[" << tag << "] Error: could not open " << path << ": "
               << ec.message() << "\n";
    }
}

Error emitObjectFile(Module &m, TargetMachine &tm, const std::string &path) {
    std::error_code ec;
    raw_fd_ostream dest(path, ec, sys::fs::OF_None);
    if (ec)
        return createStringError(ec,
            "Could not open object file output '" + path + "': " +
            ec.message());

    legacy::PassManager emitPM;
    if (tm.addPassesToEmitFile(emitPM, dest, nullptr,
                                CodeGenFileType::ObjectFile))
        return createStringError(std::errc::not_supported,
            "Target machine can't emit object files");

    emitPM.run(m);
    dest.flush();
    return Error::success();
}

// Map the codegen opt level to a PassBuilder OptimizationLevel. The
// simplification pipelines assert O0 is invalid, so anything <1 maps to O2
// (parallel-opt is only reached when optLevel != None).
OptimizationLevel toOptLevel(CodeGenOptLevel lvl) {
    switch (lvl) {
    case CodeGenOptLevel::Less:
        return OptimizationLevel::O1;
    case CodeGenOptLevel::Aggressive:
        return OptimizationLevel::O3;
    case CodeGenOptLevel::Default:
    default:
        return OptimizationLevel::O2;
    }
}

// Cheap whole-module interprocedural passes worth keeping even when the CGSCC
// inliner is disabled: IPSCCP (constant propagation across calls — especially
// valuable on monomorphized specializations), GlobalOpt, function-attrs
// inference, and GlobalDCE. These are O(module) and capture the cross-module
// facts the parallel per-partition pipeline can then exploit locally. Runs
// once, serially, before the split. GC-safe: strictly fewer transforms than
// today's whole-module -O2, all after RS4GC (design doc §5/§6.3).
void runCheapModuleIPO(Module &m) {
    PassBuilder PB;
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    // M4 (measured): the function-attrs pair — PostOrderFunctionAttrs (~0.90s)
    // + ReversePostOrderFunctionAttrs (~0.008s) — was dropped from this serial
    // prologue. Effect: cheap-IPO -~1.06s, wall -~1s, exe +~0.28%, produced
    // functional output byte-identical. Cross-module function attrs are
    // re-derived by the per-partition -O2 in --parallel-opt=cgu and by the
    // whole-module -O2 in =none (cheap-IPO does not run there), so only
    // throwaway --parallel-opt=dev binaries lose them — an acceptable dev-tier
    // trade. Kept: IPSCCP (~2.0s — constant propagation on monomorphized code,
    // the dominant and load-bearing pass), GlobalOpt (~0.87s — unused-global
    // elimination / fn merging), and GlobalDCE (~0.20s — strips the dead code
    // IPSCCP/GlobalOpt create, before the whole-module serialize every worker
    // re-parses; the driver-side internalize+DCE is for a different, exe-only
    // reachability pass, so this is not redundant on the split path).
    ModulePassManager MPM;
    MPM.addPass(IPSCCPPass());
    MPM.addPass(GlobalOptPass());
    MPM.addPass(GlobalDCEPass());
    MPM.run(m, MAM);
}

// No-inline per-partition pipeline (Dev tier): honour explicit `alwaysinline`
// attrs, then run the standard per-function simplification pipeline
// (InstCombine / SROA / GVN / SimplifyCFG / LICM / vectorizers …) with NO CGSCC
// inliner. That fused inliner+simplification is the bulk of an -O2 pipeline's
// wall-clock; dropping the inliner makes the rest embarrassingly parallel.
Error runNoInlineFunctionPipeline(Module &m, TargetMachine *tm,
                                  CodeGenOptLevel optLevel, bool devOptO1) {
    PassBuilder PB(tm);
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    MPM.addPass(AlwaysInlinerPass());
    MPM.addPass(createModuleToFunctionPassAdaptor(
        PB.buildFunctionSimplificationPipeline(
            devOptO1 ? OptimizationLevel::O1 : toOptLevel(optLevel),
            ThinOrFullLTOPhase::None)));
    MPM.run(m, MAM);
    return Error::success();
}

// Optimize one partition module in place according to the parallel-opt tier.
// Dev  = no-inline function pipeline (fast, lower quality).
// Cgu  = full -O2 per partition (keeps intra-partition CGSCC inlining).
Error optimizePartitionModule(Module &m, TargetMachine *tm, ParallelOpt mode,
                              CodeGenOptLevel optLevel, bool devOptO1) {
    if (mode == ParallelOpt::Cgu) {
        auto opt = mlir::makeOptimizingTransformer(
            static_cast<unsigned>(optLevel), /*sizeLevel=*/0, tm);
        return opt(&m);
    }
    return runNoInlineFunctionPipeline(m, tm, optLevel, devOptO1);
}

// Split the (already RS4GC'd + optimized) module into N partitions and emit
// each to its own object file on its own thread. Object emission (ISel /
// MC / codegen) is the single largest phase of the AOT backend and is
// per-function work, so splitting it across cores is a near-linear win.
//
// When `perPartitionMode != None`, each partition is additionally OPTIMIZED in
// its worker thread (before emission) — this is how the opt stage itself is
// parallelized (the whole-module -O2 is skipped upstream and replaced with a
// cheap IPO prologue + this per-partition optimization).
//
// Correctness notes:
//   - PreserveLocals=false: llvm::SplitModule EXTERNALIZES (single definition,
//     unique name) any local global referenced across partitions rather than
//     duplicating it, so GC-root globals (eco.global cells, the type graph and
//     its private satellite arrays) keep exactly one definition — no
//     premature-reclamation landmine.
//   - Each partition is round-tripped through bitcode into its OWN LLVMContext
//     (LLVMContext is not thread-safe) and gets its OWN TargetMachine
//     (MCContext / AsmPrinter state is not shareable across threads).
//   - RS4GC ran once on the whole module BEFORE the split, so statepoints and
//     the frame-pointer attr are already in place and are preserved losslessly
//     through bitcode. Each partition emits a .llvm_stackmaps blob for its own
//     functions; the linker concatenates them and StackMap::parse reads all
//     blobs (multi-blob loop).
Error emitObjectFilesSplit(Module &m, unsigned numPartitions,
                           const std::vector<std::string> &paths,
                           CodeGenOptLevel optLevel,
                           ParallelOpt perPartitionMode,
                           unsigned devEmitCG, bool devOptO1,
                           eco::LoweringStats *stats,
                           const RS4GCOptions *partitionRS4GC) {
    if (paths.size() != numPartitions)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplit: paths count != numPartitions");

    // Serialize each partition to bitcode in the parent context and DISPATCH
    // its worker immediately — the remaining partitions' clone+serialize then
    // overlaps with already-running workers instead of gating all of them.
    // (SplitModule hands sub-modules over one at a time on this thread;
    // LLVMContext is not thread-safe, hence the bitcode hand-off.)
    std::vector<SmallString<0>> bitcodes(numPartitions);
    std::atomic<unsigned> nextFail{0};
    std::vector<std::string> errs(numPartitions);
    std::vector<std::thread> threads;
    threads.reserve(numPartitions);

    auto worker = [&, optLevel, perPartitionMode, devEmitCG, devOptO1](unsigned i) {
        LLVMContext ctx;
        auto buf = MemoryBuffer::getMemBuffer(
            StringRef(bitcodes[i].data(), bitcodes[i].size()),
            "eco-partition", /*RequiresNullTerminator=*/false);
        auto modOr = parseBitcodeFile(buf->getMemBufferRef(), ctx);
        if (!modOr) {
            errs[i] = "parseBitcodeFile failed for partition " +
                      std::to_string(i);
            nextFail++;
            return;
        }
        std::unique_ptr<Module> mod = std::move(*modOr);
        // Dev tier may emit at a cheaper CodeGen level than optLevel; this TM
        // also feeds runNoInlineFunctionPipeline's PassBuilder TTI (acceptable).
        unsigned emitLevel = static_cast<unsigned>(optLevel);
        if (perPartitionMode == ParallelOpt::Dev && devEmitCG != ~0u)
            emitLevel = devEmitCG;
        auto tm = createEcoTargetMachine(*mod, emitLevel);
        if (!tm) {
            errs[i] = "createEcoTargetMachine failed for partition " +
                      std::to_string(i);
            nextFail++;
            return;
        }
        // Per-partition RS4GC (+ frame pointers): when the caller skipped the
        // whole-module RS4GC (parallel-opt modes), each worker statepoints its
        // own partition here — RS4GC is per-function and consults only callee
        // DECLARATION attrs (gc-leaf-function), which CloneModule preserved,
        // so partition-local RS4GC is semantically identical to whole-module
        // (design doc finding: per-partition RS4GC confirmed safe). It runs
        // BEFORE opt, preserving the RS4GC-before-optimization GC invariant
        // per partition.
        if (partitionRS4GC) {
            MaybeScope s(stats, "  partition RS4GC (sum over workers)");
            runRS4GCAndMaybeFramePointers(*mod, *partitionRS4GC);
        }
        // Parallel opt: optimize this partition on its own thread before
        // emission (the whole-module -O2 was skipped upstream).
        if (perPartitionMode != ParallelOpt::None) {
            MaybeScope s(stats, "  partition opt (sum over workers)");
            if (auto err = optimizePartitionModule(
                    *mod, tm.get(), perPartitionMode, optLevel, devOptO1)) {
                errs[i] = "partition opt failed for partition " +
                          std::to_string(i) + ": " +
                          toString(std::move(err));
                nextFail++;
                return;
            }
        }
        MaybeScope s(stats, "  partition emit (sum over workers)");
        if (auto err = emitObjectFile(*mod, *tm, paths[i])) {
            errs[i] = "emitObjectFile failed for partition " +
                      std::to_string(i) + ": " + toString(std::move(err));
            nextFail++;
            return;
        }
    };

    unsigned idx = 0;
    {
        MaybeScope s(stats, "  split + bitcode serialize (serial)");
        SplitModule(
            m, numPartitions,
            [&](std::unique_ptr<Module> mp) {
                if (idx < numPartitions) {
                    {
                        raw_svector_ostream os(bitcodes[idx]);
                        WriteBitcodeToFile(*mp, os);
                    }
                    // Free the partition clone before dispatching; the worker
                    // re-materializes from bitcode in its own context.
                    mp.reset();
                    threads.emplace_back(worker, idx);
                }
                ++idx;
            },
            /*PreserveLocals=*/false);
    }

    unsigned produced = std::min(idx, numPartitions);
    if (produced == 0)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplit: SplitModule produced no partitions");

    {
        MaybeScope s(stats, "  parallel opt+emit drain (post-split wait)");
        for (auto &t : threads)
            t.join();
    }

    // Any unused partition slots (produced < numPartitions) get an empty
    // object so the linker still finds every expected path. In practice
    // SplitModule always produces exactly numPartitions parts, but guard it.
    for (unsigned i = produced; i < numPartitions; ++i) {
        LLVMContext ctx;
        Module empty("eco-empty-partition", ctx);
        empty.setTargetTriple(m.getTargetTriple());
        empty.setDataLayout(m.getDataLayout());
        auto tm = createEcoTargetMachine(empty,
                                         static_cast<unsigned>(optLevel));
        if (tm)
            if (auto err = emitObjectFile(empty, *tm, paths[i]))
                consumeError(std::move(err));
    }

    if (nextFail.load() != 0) {
        for (auto &e : errs)
            if (!e.empty())
                return createStringError(std::errc::io_error, "%s", e.c_str());
    }
    return Error::success();
}

// Stable, reproducible partition assignment for a symbol name: FNV-1a % N.
// Must be a pure function of the name so every worker computes the SAME owner
// independently (exactly-once cover). Deliberately NOT llvm::hash_value, which
// is per-process-seeded and would break reproducible builds.
unsigned partitionOfName(StringRef name, unsigned n) {
    uint64_t h = 1469598103934665603ULL; // FNV offset basis
    for (unsigned char c : name)
        h = (h ^ c) * 1099511628211ULL;  // FNV prime
    return static_cast<unsigned>(h % n);
}

// Externalize every module-local symbol to a single ExternalLinkage +
// HiddenVisibility definition — replicates llvm::SplitModule's
// PreserveLocals=false behaviour so cross-partition references resolve at link
// time when each partition keeps only its own definitions. (eco's module has
// no aliases/comdats/ifuncs and no unnamed globals, so this is the whole job;
// the defensive name/alias/ifunc handling mirrors SplitModule for safety.)
void externalizeAllLocals(Module &m) {
    auto ext = [](GlobalValue &GV) {
        if (GV.hasLocalLinkage()) {
            // setVisibility(Hidden) requires non-local linkage, so promote first.
            GV.setLinkage(GlobalValue::ExternalLinkage);
            GV.setVisibility(GlobalValue::HiddenVisibility);
        }
        if (!GV.hasName())
            GV.setName("__eco_lazysplit"); // symbol table auto-uniquifies
    };
    for (Function &F : m.functions())
        ext(F);
    for (GlobalVariable &G : m.globals())
        ext(G);
    for (GlobalAlias &A : m.aliases())
        ext(A);
    for (GlobalIFunc &I : m.ifuncs())
        ext(I);
}

// Lazy per-worker module extraction — the ThinLTO-importer pattern. Instead of
// llvm::SplitModule (N x CloneModule + N bitcode writes, all serial on the
// parent), externalize + serialize the WHOLE module once, then each worker
// lazy-loads the shared read-only bitcode into its own LLVMContext and
// materializes ONLY the ~1/N functions it owns (deleteBody() strips the rest to
// declarations without deserializing their bodies). Functionally equivalent to
// emitObjectFilesSplit; collapses the ~N-clone serial cost to one serialization.
Error emitObjectFilesSplitLazy(Module &m, unsigned numPartitions,
                               const std::vector<std::string> &paths,
                               CodeGenOptLevel optLevel,
                               ParallelOpt perPartitionMode,
                               unsigned devEmitCG, bool devOptO1,
                               eco::LoweringStats *stats,
                               const RS4GCOptions *partitionRS4GC) {
    if (paths.size() != numPartitions)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplitLazy: paths count != numPartitions");

    // Externalize once, then serialize the whole module once (the only serial
    // per-partition cost SplitModule paid — N clones + N writes — is gone).
    SmallString<0> wholeBitcode;
    {
        MaybeScope s(stats, "  externalize + serialize once (serial)");
        externalizeAllLocals(m);
        raw_svector_ostream os(wholeBitcode);
        WriteBitcodeToFile(m, os);
    }
    // Shared, read-only view of the bitcode; MUST outlive every worker (their
    // lazy modules read function bodies out of it on materialize()). It does:
    // wholeBitcode is joined-on below before this scope exits.
    StringRef bcData(wholeBitcode.data(), wholeBitcode.size());

    std::atomic<unsigned> nextFail{0};
    std::vector<std::string> errs(numPartitions);
    std::vector<std::thread> threads;
    threads.reserve(numPartitions);

    for (unsigned i = 0; i < numPartitions; ++i) {
        threads.emplace_back([&, i, optLevel, perPartitionMode, devEmitCG, devOptO1] {
            LLVMContext ctx;
            auto buf = MemoryBuffer::getMemBuffer(
                bcData, "eco-whole", /*RequiresNullTerminator=*/false);
            auto modOr = getLazyBitcodeModule(buf->getMemBufferRef(), ctx,
                                              /*ShouldLazyLoadMetadata=*/false,
                                              /*IsImporting=*/false);
            if (!modOr) {
                errs[i] = "getLazyBitcodeModule failed for partition " +
                          std::to_string(i) + ": " +
                          toString(modOr.takeError());
                nextFail++;
                return;
            }
            std::unique_ptr<Module> mod = std::move(*modOr);

            // Extract this partition: materialize the functions we own, strip
            // the rest to external declarations WITHOUT loading their bodies.
            {
                MaybeScope s(stats, "  lazy extract (sum over workers)");
                for (Function &F : mod->functions()) {
                    if (F.isDeclaration())
                        continue; // already an extern (runtime) decl
                    if (partitionOfName(F.getName(), numPartitions) == i) {
                        if (F.isMaterializable())
                            if (auto e = F.materialize()) {
                                errs[i] = "materialize failed p" +
                                          std::to_string(i) + ": " +
                                          toString(std::move(e));
                                nextFail++;
                                return;
                            }
                    } else {
                        // Strips to `external` decl; body was never read, so
                        // this only clears the (empty) BB list + materializable
                        // bit + sets external linkage.
                        F.deleteBody();
                        F.setComdat(nullptr);
                    }
                }
                // Globals: initializers are eager in a lazy module, so each
                // worker holds them all — strip the ones it doesn't own to a
                // single external declaration (owner keeps the definition).
                for (GlobalVariable &G : mod->globals()) {
                    if (G.isDeclaration())
                        continue;
                    if (partitionOfName(G.getName(), numPartitions) != i) {
                        G.setInitializer(nullptr);
                        G.setLinkage(GlobalValue::ExternalLinkage);
                        G.setComdat(nullptr);
                    }
                }
                // Detach the materializer; nothing left to materialize (owned
                // done, non-owned marked non-materializable by deleteBody), so
                // this is cheap and readies the module for passes + codegen.
                if (auto e = mod->materializeAll()) {
                    errs[i] = "materializeAll failed p" + std::to_string(i) +
                              ": " + toString(std::move(e));
                    nextFail++;
                    return;
                }
            }

            // Dev tier may emit at a cheaper CodeGen level than optLevel; this
            // TM also feeds the dev IR pipeline's PassBuilder TTI (acceptable).
            unsigned emitLevel = static_cast<unsigned>(optLevel);
            if (perPartitionMode == ParallelOpt::Dev && devEmitCG != ~0u)
                emitLevel = devEmitCG;
            auto tm = createEcoTargetMachine(*mod, emitLevel);
            if (!tm) {
                errs[i] = "createEcoTargetMachine failed for partition " +
                          std::to_string(i);
                nextFail++;
                return;
            }
            if (partitionRS4GC) {
                MaybeScope s(stats, "  partition RS4GC (sum over workers)");
                runRS4GCAndMaybeFramePointers(*mod, *partitionRS4GC);
            }
            if (perPartitionMode != ParallelOpt::None) {
                MaybeScope s(stats, "  partition opt (sum over workers)");
                if (auto err = optimizePartitionModule(
                        *mod, tm.get(), perPartitionMode, optLevel, devOptO1)) {
                    errs[i] = "partition opt failed for partition " +
                              std::to_string(i) + ": " +
                              toString(std::move(err));
                    nextFail++;
                    return;
                }
            }
            MaybeScope s(stats, "  partition emit (sum over workers)");
            if (auto err = emitObjectFile(*mod, *tm, paths[i])) {
                errs[i] = "emitObjectFile failed for partition " +
                          std::to_string(i) + ": " + toString(std::move(err));
                nextFail++;
                return;
            }
        });
    }

    {
        MaybeScope s(stats, "  parallel opt+emit drain (post-serialize wait)");
        for (auto &t : threads)
            t.join();
    }

    if (nextFail.load() != 0) {
        for (auto &e : errs)
            if (!e.empty())
                return createStringError(std::errc::io_error, "%s", e.c_str());
    }
    return Error::success();
}

// Decide how many object-emission partitions to use. This is the split policy
// that used to live inline in eco-boot.cpp; hoisting it here means every driver
// (eco-boot, the unified `eco` native driver, ecoc) gets the same partitioned
// codegen for free. `request`: 0 = auto, 1 = off, N = explicit. `eligible` is
// true only for plain executable output. See
// design_docs/backend-parallel-optimization.md §8.1.
unsigned choosePartitionCount(const Module &m, unsigned request, bool eligible) {
    if (!eligible || request == 1)
        return 1;
    unsigned numDefinedFns = 0;
    for (const Function &F : m)
        if (!F.isDeclaration())
            ++numDefinedFns;
    // Only split modules with enough functions to amortize the per-partition
    // bitcode-serialize + thread + link overhead.
    constexpr unsigned kMinFnsToSplit = 4000;
    if (numDefinedFns < kMinFnsToSplit)
        return 1;
    unsigned cores = std::max(1u, std::thread::hardware_concurrency());
    // Auto uses all cores. The old min(cores,16) cap existed because
    // llvm::SplitModule's serial split + N bitcode serializations grew with N
    // and ate the emission gain past ~16. The lazy-split path (Phase 5)
    // serializes the module ONCE (N-independent, ~1.3 s regardless of N), so
    // partition-emit parallelism now scales cleanly to the core count: a 24-core
    // self-host sweep showed backend time still dropping at N=24 (dev 12.4->10.1 s
    // from N=16, no plateau). See backendstats-runs.txt (N-partition sweep).
    unsigned want = (request == 0) ? cores : request;
    // ~1 partition per 2000 functions, at least 2 once we've decided to split.
    unsigned bySize = std::max(2u, numDefinedFns / 2000u);
    return std::min(want, bySize);
}

} // namespace

std::unique_ptr<TargetMachine> createEcoTargetMachine(Module &module,
                                                      unsigned optLevel) {
    auto triple = sys::getDefaultTargetTriple();
    module.setTargetTriple(Triple(triple));

    std::string error;
    const Target *target = TargetRegistry::lookupTarget(triple, error);
    if (!target) {
        errs() << "Error: Could not find target: " << error << "\n";
        return nullptr;
    }

    TargetOptions targetOpts;
    // Emit each function/data global into its own section so a later
    // `--gc-sections` link can trim dead code at section granularity. Harmless
    // for shared-lib output. (The .llvm_stackmaps section must be KEPT
    // explicitly at link time — see linkExecutable — since nothing relocates
    // into it.)
    targetOpts.FunctionSections = true;
    targetOpts.DataSections = true;
    auto codeGenOpt = static_cast<CodeGenOptLevel>(std::min(optLevel, 3u));

    // Pin CPU/features (kEcoTargetCPU) — no host detection. Host detection
    // baked the build machine's AVX-512 into emitted binaries, which then
    // SIGILL'd on x86-64-v3 CPUs.
    TargetMachine *tm = target->createTargetMachine(
        Triple(triple), kEcoTargetCPU, kEcoTargetFeatures, targetOpts,
        Reloc::PIC_, CodeModel::Small, codeGenOpt);
    if (!tm) {
        errs() << "Error: Could not create TargetMachine\n";
        return nullptr;
    }

    module.setDataLayout(tm->createDataLayout());
    return std::unique_ptr<TargetMachine>(tm);
}

void runRS4GCAndMaybeFramePointers(Module &m, const RS4GCOptions &opts) {
    if (!opts.preDumpPath.empty())
        dumpIRTo(m, opts.preDumpPath, "pre-rs4gc");

    // RS4GC pipeline: inserts gc.statepoint/gc.relocate for all
    // GC-triggering calls in functions with gc "eco-gc".
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PassBuilder PB;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    addEcoGCPipeline(MPM);
    MPM.run(m, MAM);

    if (!opts.postDumpPath.empty())
        dumpIRTo(m, opts.postDumpPath, "rs4gc");

    // GCFREE self-check (plans/gc-free-function-propagation.md §2.6): a
    // stamped function that RS4GC still statepointed means the fixpoint was
    // unsound — a wrongly-stamped function that allocates leaves unrelocated
    // stale pointers in its callers. RS4GC processes a function on hasGC()
    // alone (a callee's own gc-leaf attr does NOT stop it), so this scan is
    // a real check, not a vacuous one. Placed after the post-RS4GC dump so a
    // failing build still leaves the IR on disk. Stamp mode only.
    if (gcFreeLeafMode() == GcFreeMode::Stamp) {
        for (Function &f : m) {
            if (f.isDeclaration() || !f.hasFnAttribute("gc-leaf-function"))
                continue;
            for (BasicBlock &bb : f)
                for (Instruction &i : bb)
                    if (auto *cb = dyn_cast<CallBase>(&i))
                        if (isa<GCStatepointInst>(cb))
                            report_fatal_error(
                                Twine("[gcfree] stamped function contains a "
                                      "statepoint after RS4GC: ") +
                                f.getName());
        }
    }

    // Frame pointers for GC root discovery. Blanket mode (default):
    // frame-pointer=all on every defined function. ECO_FP_LEAF: only on
    // functions that can hold GC-relevant frame state — ones containing a
    // statepoint (their stackmap records are read mid-walk) or a stack-range
    // registration (shadow-root prologue AND the rooted arg/capture-array
    // sites in EcoToLLVMClosures.cpp; the over-stamp is deliberate — do NOT
    // tighten this to an entry-block-only scan). Statepoint-free functions
    // can never be on the stack during a GC walk (all their calls are
    // gc-leaf, so no GC can begin beneath them), and the walker is CFI-driven
    // anyway (ThreadLocalHeap.cpp collectStackRootsFromStackMap +
    // StackUnwind.cpp), so they may release rbp as an allocatable register.
    // plans/gc-free-function-propagation.md §3.
    if (opts.addFramePointerAttr) {
        static const bool fpLeaf = [] {
            const char *e = ::getenv("ECO_FP_LEAF");
            return e && *e && !(e[0] == '0' && e[1] == '\0');
        }();
        unsigned numStamped = 0, numLeaf = 0;
        for (Function &F : m) {
            if (F.isDeclaration())
                continue;
            bool needsFP = !fpLeaf;
            if (!needsFP) {
                for (BasicBlock &bb : F) {
                    for (Instruction &i : bb) {
                        auto *cb = dyn_cast<CallBase>(&i);
                        if (!cb)
                            continue;
                        if (isa<GCStatepointInst>(cb)) {
                            needsFP = true;
                            break;
                        }
                        if (Function *cf = cb->getCalledFunction();
                            cf && cf->getName() == "eco_gc_push_stack_range") {
                            needsFP = true;
                            break;
                        }
                    }
                    if (needsFP)
                        break;
                }
            }
            if (needsFP) {
                F.addFnAttr("frame-pointer", "all");
                ++numStamped;
            } else {
                ++numLeaf;
            }
        }
        if (fpLeaf) {
            // Single write: worker flavours run this concurrently and
            // llvm::errs() is unbuffered — chained << would interleave.
            std::string line;
            raw_string_ostream os(line);
            os << "[gcfree-fp] frame-pointer=all on " << numStamped
               << " statepointed, omitted on " << numLeaf
               << " statepoint-free functions\n";
            llvm::errs() << os.str();
        }
    }
}

void internalizeAndDCEForExecutable(Module &m) {
    // Preserve exactly the two symbols the C entry lib (eco_entry.cpp) resolves
    // by name: the program entry and the GC-root/type-graph initializer. Every
    // other generated symbol (Elm top-level functions, __eco_type_graph,
    // __eco_root_module, string globals, ...) is reached only internally from
    // these two or their call graph, so internalizing them is safe and lets
    // GlobalDCE drop the unreachable remainder.
    auto mustPreserve = [](const GlobalValue &GV) {
        StringRef n = GV.getName();
        return n == "eco_main" || n == "__eco_init_globals";
    };
    internalizeModule(m, mustPreserve);

    // Drop now-unreachable internal functions/globals before RS4GC + opt +
    // codegen process them.
    PassBuilder PB;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    ModulePassManager MPM;
    MPM.addPass(GlobalDCEPass());
    MPM.run(m, MAM);
}

// Plan P2 (--inline-deref). Expand each `__eco_resolve_fwd` marker call into an
// inline forwarding-check diamond:
//
//     %hdr   = load i32, ptr addrspace(1) %h, align 8   ; object header word
//     %tag   = and i32 %hdr, TAG_MASK
//     %isfwd = icmp eq i32 %tag, Tag_Forward
//     br i1 %isfwd, label %fwd, label %cont, !prof !unlikely   ; predicted cont
//   fwd:
//     %r = call ptr addrspace(1) @eco_follow_forward(ptr addrspace(1) %h) [gc-leaf]
//     br label %cont
//   cont:
//     %base = phi [ %h, %head ], [ %r, %fwd ]   ; replaces the marker result
//
// Runs on the whole module at the very start of runEcoBackend — i.e. before ANY
// RewriteStatepointsForGC pass (whole-module serial, deferred, or per-partition)
// and before module splitting — so RS4GC sees the fully-expanded diamond and
// tracks %base / the field pointers derived from it as ordinary GC pointers.
// The header load stays in addrspace(1); no ptrtoint is introduced. Callee
// eco_follow_forward is gc-leaf so RS4GC inserts no statepoint around the cold
// call. Idempotent / cheap when there are no markers (flag off).
static void expandInlineDerefs(Module &m) {
    Function *marker = m.getFunction("__eco_resolve_fwd");
    if (!marker || marker->use_empty())
        return;

    LLVMContext &ctx = m.getContext();
    Type *i32Ty = Type::getInt32Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t tagMask = (1ULL << TAG_BITS) - 1;

    FunctionCallee followCallee = m.getOrInsertFunction(
        "eco_follow_forward", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(followCallee.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    MDBuilder mdb(ctx);
    // Forwarding is rare (only during an old-gen compaction window): weight the
    // taken (fwd) edge far below the fall-through so the cold call is laid out
    // out of line.
    MDNode *unlikely = mdb.createBranchWeights(/*fwd=*/1, /*cont=*/1u << 20);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *h = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        LoadInst *hdr = b.CreateAlignedLoad(i32Ty, h, Align(8), "eco.hdr");
        Value *tag = b.CreateAnd(hdr, tagMask);
        Value *isfwd = b.CreateICmpEQ(
            tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Forward), "eco.isfwd");

        // Split ci's block at ci; insert an if(isfwd) then-block. thenTerm is the
        // unconditional branch terminating the new then-block.
        Instruction *thenTerm = SplitBlockAndInsertIfThen(
            isfwd, ci, /*Unreachable=*/false, unlikely);
        BasicBlock *thenBB = thenTerm->getParent();
        BasicBlock *headBB = thenBB->getSinglePredecessor();

        IRBuilder<> tb(thenTerm);
        CallInst *fwd = tb.CreateCall(followCallee, {h}, "eco.fwd");

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(as1, 2, "eco.base");
        phi->addIncoming(h, headBB);
        phi->addIncoming(fwd, thenBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }
}

// Inline nursery allocation (plans/inline-nursery-allocation.md, HEAP_034).
// Expand each `__eco_alloc_inline(SIZE)` marker call into the bump-pointer
// fast/slow diamond:
//
//     %state = call ptr @eco_bump_state()          ; memory(none) gc-leaf
//     %top   = load ptr addrspace(1), ptr %state   ; bump.ptr at +0
//     %end   = load ptr addrspace(1), ptr %state+8 ; bump.end at +8 (clamped)
//     %new   = gep i8, %top, SIZE
//     %miss  = icmp ugt %new, %end
//     br %miss, slow, fast                          ; !prof slow=1 fast=1<<20
//   slow:  %r = call ptr addrspace(1) @eco_alloc_inline_slow(SIZE)  ; statepointed
//   fast:  store %new, %state                       ; publish the bump
//   cont:  %obj = phi [ %top, fast ], [ %r, slow ]
//
// The single compare preserves ALL GC-trigger semantics: NurserySpace's
// bump.end is pre-clamped to min(block end, proactive-GC threshold trip)
// (computeAllocEndForBlock), so both block exhaustion and threshold trips
// miss into the statepointed slow call (block advance, then minor GC).
//
// Address-space discipline: the bump slots are loaded/stored as
// `ptr addrspace(1)` directly (the HPointer word IS the raw address, plan
// D1), so this expansion introduces NO ptrtoint/inttoptr — out of
// REP_LLVM_001(b)'s provenance rules and fold-immune (REP_LLVM_002) by
// construction, exactly like expandInlineDerefs.
//
// RS4GC-liveness fact (HEAP_034(d)): no bump-derived as1 value is live
// across the slow call — `%end`/`%miss` die at the branch, `%new` dies at
// the fast-edge store, and `%top`'s only post-branch use is the merge phi's
// fast-edge incoming. The phi result is a legitimate fresh base pointer on
// both edges; the header + field stores the lowering emitted after the
// marker land in the merge block, so a GC can never observe a
// partially-initialized object (no safepoint between the phi and the
// stores).
//
// Runs with the other marker expansions at the top of runEcoBackend —
// before the `$cap` inline prepass, before partition splitting, and before
// every RS4GC flavour. Idempotent / cheap when there are no markers
// (ECO_INLINE_ALLOC=0 emits none).
static void expandInlineAllocs(Module &m) {
    Function *marker = m.getFunction("__eco_alloc_inline");
    if (!marker || marker->use_empty())
        return;

    LLVMContext &ctx = m.getContext();
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *i8Ty = Type::getInt8Ty(ctx);
    PointerType *as0 = PointerType::get(ctx, 0);
    PointerType *as1 = PointerType::get(ctx, 1);

    // eco_bump_state() -> ptr: address of the calling thread's {ptr as1 at
    // +0, end as1 at +8}. memory(none): the ADDRESS is thread-stable (set
    // once at initThread), so LLVM may CSE repeated calls per function and
    // LICM them out of allocation loops; the CONTENTS change across block
    // advance / minor GC but are re-loaded per allocation, never cached
    // across a diamond. speculatable: executing it early is harmless (the
    // runtime is initialized before any compiled code runs).
    FunctionCallee bumpStateCallee = m.getOrInsertFunction(
        "eco_bump_state", FunctionType::get(as0, {}, /*isVarArg=*/false));
    if (auto *bs = dyn_cast<Function>(bumpStateCallee.getCallee())) {
        bs->setDoesNotAccessMemory();
        bs->setDoesNotThrow();
        bs->setWillReturn();
        bs->setSpeculatable();
        bs->addFnAttr("gc-leaf-function");
    }

    // eco_alloc_inline_slow(i64) -> ptr addrspace(1). Deliberately NOT
    // gc-leaf: this is the ONE statepoint of an inline-allocated construct
    // (it may run a minor GC); field values live across it are relocated by
    // RS4GC as ordinary SSA values (no hand-rooting anywhere).
    FunctionCallee slowCallee = m.getOrInsertFunction(
        "eco_alloc_inline_slow",
        FunctionType::get(as1, {i64Ty}, /*isVarArg=*/false));
    if (auto *sf = dyn_cast<Function>(slowCallee.getCallee()))
        sf->setDoesNotThrow();

    MDBuilder mdb(ctx);
    // The slow edge fires once per nursery block (thousands of allocations)
    // plus once per minor GC — weight it far below the fall-through.
    MDNode *unlikely = mdb.createBranchWeights(/*slow=*/1, /*fast=*/1u << 20);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        auto *sizeC = dyn_cast<ConstantInt>(ci->getArgOperand(0));
        if (!sizeC || sizeC->getZExtValue() == 0 ||
            (sizeC->getZExtValue() & 7) != 0 || sizeC->getZExtValue() > 4096)
            report_fatal_error("expandInlineAllocs: __eco_alloc_inline size "
                               "must be a constant, 8-aligned, in (0, 4096]");

        IRBuilder<> b(ci);
        Value *state = b.CreateCall(bumpStateCallee, {}, "eco.bump.state");
        Value *top = b.CreateAlignedLoad(as1, state, Align(8), "eco.bump.top");
        Value *endp = b.CreateGEP(i8Ty, state, {b.getInt64(8)}, "eco.bump.endp");
        Value *end = b.CreateAlignedLoad(as1, endp, Align(8), "eco.bump.end");
        // Plain (non-inbounds) GEP: when the block is nearly full the bumped
        // address may exceed the block end before the compare rejects it.
        Value *newTop = b.CreateGEP(i8Ty, top,
                                    {b.getInt64(sizeC->getSExtValue())},
                                    "eco.bump.new");
        Value *miss = b.CreateICmpUGT(newTop, end, "eco.bump.miss");

        Instruction *thenTerm = nullptr;  // slow (cold)
        Instruction *elseTerm = nullptr;  // fast
        SplitBlockAndInsertIfThenElse(miss, ci, &thenTerm, &elseTerm, unlikely);

        IRBuilder<> tb(thenTerm);
        CallInst *slowObj = tb.CreateCall(slowCallee, {sizeC}, "eco.alloc.slow");

        IRBuilder<> eb(elseTerm);
        eb.CreateAlignedStore(newTop, state, Align(8));

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(as1, 2, "eco.alloc.obj");
        phi->addIncoming(top, elseTerm->getParent());
        phi->addIncoming(slowObj, thenTerm->getParent());

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandInlineAllocs: surviving __eco_alloc_inline use");
    marker->eraseFromParent();
}

// P2.5 R1b (plans/allocator-resolve-inlining.md). Expand each
// `__eco_get_tag_inline` marker call into the open-coded eco_get_tag
// semantics (replicated EXACTLY from RuntimeExports.cpp):
//
//   embedded constant (ptr_ind set) -> Bool -> its i1 value; "empty" ->
//     CONSTANT_TAG (0xFFFD);
//   heap object -> Tag_Custom -> ctor (low 16 bits of the word at +8;
//     the upper bits are the unboxed bitmap — load i16, never i32);
//     Tag_Cons -> 1; anything else -> 0.
//
// The marker exists because eco.get_tag sits INSIDE single-block scf regions
// (loopified tail recursion — the hot Dict/Set case loops), where the MLIR
// lowering cannot create blocks; here at the LLVM level block structure is
// free. The heap arm resolves via a `__eco_resolve_fwd` marker call, so this
// MUST run BEFORE expandInlineDerefs (which then expands those) — and, like
// it, before the `$cap` prepass and every RS4GC flavour. The transient
// ptrtoint feeds only a same-block bit-test chain (REP_LLVM_001(c)/(d)); it
// has no foldable inttoptr partner because every slot decode is barriered or
// typed (REP_LLVM_002 §7.6). Idempotent / cheap when there are no markers.
// Chunked-list projections (plans/chunked-list-representation.md §6).
// Expand `__eco_list_head_inline` / `__eco_list_tail_inline` markers into a
// cell-fast / chunk-slow diamond:
//
//   base = __eco_resolve_fwd(v); tag = header(base) & mask;
//   tag == Tag_Cons ?  load the cell slot (head +8 / tail +16) through the
//                      __eco_slot_to_hptr barrier (REP_LLVM_002)
//                   :  call the chunk-aware runtime helper (head is gc-leaf;
//                      tail MAY ALLOCATE a successor view and is deliberately
//                      NOT gc-leaf, so RS4GC statepoints it like any
//                      allocating call — the HEAP_034 slow-edge pattern).
//
// Cells dominate spines (~99.8% measured on the flag-on self-compile), so
// the fast edge carries branch weights. Markers exist for the same reason as
// __eco_get_tag_inline: the projections sit inside single-block scf regions.
// MUST run before expandInlineDerefs (emits __eco_resolve_fwd) and before
// every RS4GC flavour. Only chunk-compiled modules contain these markers.
static void expandListProjMarker(Module &m, const char *markerName,
                                 uint64_t slotOffset, const char *slowName,
                                 bool slowIsGcLeaf) {
    Function *marker = m.getFunction(markerName);
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t tagMask = (1ULL << TAG_BITS) - 1;

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    FunctionCallee slotBarrier = m.getOrInsertFunction(
        eco::kSlotToHPtrSym, FunctionType::get(as1, {i64Ty}, /*isVarArg=*/false));
    if (auto *bf = dyn_cast<Function>(slotBarrier.getCallee()))
        bf->addFnAttr("gc-leaf-function");

    FunctionCallee slowCallee = m.getOrInsertFunction(
        slowName, FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (slowIsGcLeaf)
        if (auto *sf = dyn_cast<Function>(slowCallee.getCallee()))
            sf->addFnAttr("gc-leaf-function");

    MDBuilder mdb(ctx);
    MDNode *cellLikely = mdb.createBranchWeights(/*cell=*/1u << 20, /*chunk=*/1);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *v = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        CallInst *base = b.CreateCall(fwdMarker, {v}, "eco.listbase");
        Value *hdr = b.CreateAlignedLoad(i32Ty, base, Align(8), "eco.listhdr");
        Value *tag = b.CreateAnd(hdr, tagMask, "eco.listtag");
        Value *isCell = b.CreateICmpEQ(
            tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons),
            "eco.iscell");

        Instruction *cellTerm = nullptr, *chunkTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isCell, ci, &cellTerm, &chunkTerm,
                                      cellLikely);

        IRBuilder<> fb(cellTerm);
        Value *slotPtr = fb.CreateGEP(
            i8Ty, base, ConstantInt::get(i64Ty, (uint64_t)slotOffset),
            "eco.slotp");
        Value *slotWord =
            fb.CreateAlignedLoad(i64Ty, slotPtr, Align(8), "eco.slotw");
        CallInst *fastVal =
            fb.CreateCall(slotBarrier, {slotWord}, "eco.fastproj");
        BasicBlock *cellBB = cellTerm->getParent();

        IRBuilder<> sb(chunkTerm);
        CallInst *slowVal = sb.CreateCall(slowCallee, {v}, "eco.slowproj");
        BasicBlock *chunkBB = chunkTerm->getParent();

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        PHINode *phi = pb.CreatePHI(as1, 2, "eco.listproj");
        phi->addIncoming(fastVal, cellBB);
        phi->addIncoming(slowVal, chunkBB);

        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandListProjMarker: surviving marker use");
    marker->eraseFromParent();
}

// Expand the mixed-spine CURSOR markers (EcoListCursor pass):
//
//   __eco_list_cur_inline(node, idx)       element at position, !eco.value
//   __eco_list_cur_{i64,f64,i16}_inline    unboxed element variants
//   __eco_list_step_node_inline(node, idx) next node (cell tail / same chunk
//                                          while the run lasts / chunk next)
//   __eco_list_step_idx_inline(node, idx)  next index (0 on node change)
//
// Every edge is a pure load — stepping THROUGH a chunk allocates nothing
// (the whole point: it replaces the per-element eco_list_tail_hybrid view
// materialization). All markers are gc-leaf shaped and fully expanded here,
// before every RS4GC flavour. Positions are normalized: idx > 0 only inside
// a chunk with idx < run, so the cell edges may assume idx == 0.
static void expandListCursorMarker(Module &m, const char *markerName,
                                   int variant /*0=value,1=i64,2=f64,3=i16,
                                                 4=stepNode,5=stepIdx*/) {
    Function *marker = m.getFunction(markerName);
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i8Ty = Type::getInt8Ty(ctx);
    Type *i16Ty = Type::getInt16Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *f64Ty = Type::getDoubleTy(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);
    const uint64_t tagMask = (1ULL << TAG_BITS) - 1;

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");
    FunctionCallee slotBarrier = m.getOrInsertFunction(
        eco::kSlotToHPtrSym, FunctionType::get(as1, {i64Ty}, false));
    if (auto *bf = dyn_cast<Function>(slotBarrier.getCallee()))
        bf->addFnAttr("gc-leaf-function");

    MDBuilder mdb(ctx);
    MDNode *cellLikely = mdb.createBranchWeights(1u << 20, 1);

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *node = ci->getArgOperand(0);
        Value *idx = ci->getArgOperand(1);
        IRBuilder<> b(ci);
        CallInst *base = b.CreateCall(fwdMarker, {node}, "eco.curbase");
        Value *hdr = b.CreateAlignedLoad(i32Ty, base, Align(8), "eco.curhdr");
        Value *tag = b.CreateAnd(hdr, tagMask, "eco.curtag");
        Value *isCell = b.CreateICmpEQ(
            tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons),
            "eco.curiscell");

        Instruction *cellTerm = nullptr, *chunkTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isCell, ci, &cellTerm, &chunkTerm,
                                      cellLikely);

        // Cell edge.
        IRBuilder<> fb(cellTerm);
        Value *cellVal = nullptr;
        if (variant <= 3) {
            Value *p = fb.CreateGEP(i8Ty, base,
                                    ConstantInt::get(i64Ty, 8), "eco.curhp");
            Value *w = fb.CreateAlignedLoad(i64Ty, p, Align(8), "eco.curhw");
            if (variant == 0)
                cellVal = fb.CreateCall(slotBarrier, {w});
            else if (variant == 1)
                cellVal = w;
            else if (variant == 2)
                cellVal = fb.CreateBitCast(w, f64Ty);
            else
                cellVal = fb.CreateTrunc(w, i16Ty);
        } else if (variant == 4) {
            Value *p = fb.CreateGEP(i8Ty, base,
                                    ConstantInt::get(i64Ty, 16), "eco.curtp");
            Value *w = fb.CreateAlignedLoad(i64Ty, p, Align(8), "eco.curtw");
            cellVal = fb.CreateCall(slotBarrier, {w});
        } else {
            cellVal = ConstantInt::get(i64Ty, 0);
        }
        BasicBlock *cellBB = cellTerm->getParent();

        // Chunk edge: shared field loads.
        IRBuilder<> sb(chunkTerm);
        Value *offP = sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 16));
        Value *off = sb.CreateZExt(
            sb.CreateAlignedLoad(i32Ty, offP, Align(8), "eco.curoff"), i64Ty);
        Value *chunkVal = nullptr;
        if (variant <= 3) {
            Value *bwP = sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 8));
            Value *bw = sb.CreateAlignedLoad(i64Ty, bwP, Align(8));
            Value *bp = sb.CreateCall(slotBarrier, {bw});
            Value *braw = sb.CreateCall(fwdMarker, {bp});
            Value *pos = sb.CreateAdd(off, idx, "eco.curpos");
            Value *byteOff = sb.CreateAdd(
                ConstantInt::get(i64Ty, 16),
                sb.CreateShl(pos, ConstantInt::get(i64Ty, 3)));
            Value *ep = sb.CreateGEP(i8Ty, braw, byteOff, "eco.curep");
            Value *w = sb.CreateAlignedLoad(i64Ty, ep, Align(8), "eco.curew");
            if (variant == 0)
                chunkVal = sb.CreateCall(slotBarrier, {w});
            else if (variant == 1)
                chunkVal = w;
            else if (variant == 2)
                chunkVal = sb.CreateBitCast(w, f64Ty);
            else
                chunkVal = sb.CreateTrunc(w, i16Ty);
        } else {
            Value *lenP =
                sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 20));
            Value *len = sb.CreateZExt(
                sb.CreateAlignedLoad(i32Ty, lenP, Align(4), "eco.curlen"),
                i64Ty);
            Value *bwP = sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 8));
            Value *bw = sb.CreateAlignedLoad(i64Ty, bwP, Align(8));
            Value *bp = sb.CreateCall(slotBarrier, {bw});
            Value *braw = sb.CreateCall(fwdMarker, {bp});
            Value *capP =
                sb.CreateGEP(i8Ty, braw, ConstantInt::get(i64Ty, 4));
            Value *cap = sb.CreateZExt(
                sb.CreateAlignedLoad(i32Ty, capP, Align(4), "eco.curcap"),
                i64Ty);
            Value *avail = sb.CreateSub(cap, off);
            Value *run = sb.CreateSelect(sb.CreateICmpULT(len, avail), len,
                                         avail, "eco.currun");
            Value *idx1 = sb.CreateAdd(idx, ConstantInt::get(i64Ty, 1));
            Value *inRun = sb.CreateICmpULT(idx1, run, "eco.curinrun");
            if (variant == 4) {
                Value *nxP =
                    sb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 24));
                Value *nxW = sb.CreateAlignedLoad(i64Ty, nxP, Align(8));
                Value *nx = sb.CreateCall(slotBarrier, {nxW});
                chunkVal = sb.CreateSelect(inRun, node, nx, "eco.stepnode");
            } else {
                chunkVal = sb.CreateSelect(inRun, idx1,
                                           ConstantInt::get(i64Ty, 0),
                                           "eco.stepidx");
            }
        }
        BasicBlock *chunkBB = chunkTerm->getParent();

        IRBuilder<> pb(&*ci->getParent()->getFirstInsertionPt());
        Type *resTy = variant == 0 || variant == 4
                          ? (Type *)as1
                          : variant == 1 || variant == 5
                                ? i64Ty
                                : variant == 2 ? f64Ty : (Type *)i16Ty;
        PHINode *phi = pb.CreatePHI(resTy, 2, "eco.cur");
        phi->addIncoming(cellVal, cellBB);
        phi->addIncoming(chunkVal, chunkBB);
        ci->replaceAllUsesWith(phi);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandListCursorMarker: surviving marker use");
    marker->eraseFromParent();
}

static void expandListCursorMarkers(Module &m) {
    expandListCursorMarker(m, "__eco_list_cur_inline", 0);
    expandListCursorMarker(m, "__eco_list_cur_i64_inline", 1);
    expandListCursorMarker(m, "__eco_list_cur_f64_inline", 2);
    expandListCursorMarker(m, "__eco_list_cur_i16_inline", 3);
    expandListCursorMarker(m, "__eco_list_step_node_inline", 4);
    expandListCursorMarker(m, "__eco_list_step_idx_inline", 5);
}

static void expandListProjMarkers(Module &m) {
    expandListProjMarker(m, "__eco_list_head_inline", /*slotOffset=*/8,
                         "eco_list_head_hybrid", /*slowIsGcLeaf=*/true);
    expandListProjMarker(m, "__eco_list_tail_inline", /*slotOffset=*/16,
                         "eco_list_tail_hybrid", /*slowIsGcLeaf=*/false);
}

static void expandGetTagMarkers(Module &m) {
    Function *marker = m.getFunction("__eco_get_tag_inline");
    if (!marker || marker->use_empty()) {
        if (marker) marker->eraseFromParent();
        return;
    }

    LLVMContext &ctx = m.getContext();
    Type *i16Ty = Type::getInt16Ty(ctx);
    Type *i32Ty = Type::getInt32Ty(ctx);
    Type *i64Ty = Type::getInt64Ty(ctx);
    Type *i8Ty = Type::getInt8Ty(ctx);
    PointerType *as1 = PointerType::get(ctx, 1);

    FunctionCallee fwdMarker = m.getOrInsertFunction(
        "__eco_resolve_fwd", FunctionType::get(as1, {as1}, /*isVarArg=*/false));
    if (auto *ff = dyn_cast<Function>(fwdMarker.getCallee()))
        ff->addFnAttr("gc-leaf-function");

    SmallVector<CallInst *, 64> calls;
    for (User *u : marker->users())
        if (auto *ci = dyn_cast<CallInst>(u))
            calls.push_back(ci);

    for (CallInst *ci : calls) {
        Value *v = ci->getArgOperand(0);
        IRBuilder<> b(ci);
        Value *bits = b.CreatePtrToInt(v, i64Ty, "eco.tagbits");
        // ALL direct users of the ptrtoint stay in THIS block —
        // EcoPtrIntVerify's bit-test acceptance is same-BB only
        // (REP_LLVM_001(d)); downstream blocks consume only the derived
        // i64s (constField), never the ptrtoint result itself.
        Value *ptrInd = b.CreateAnd(b.CreateLShr(bits, 2), 1);
        Value *constField = b.CreateAnd(bits, 3, "eco.constfield");
        Value *isConst =
            b.CreateICmpNE(ptrInd, ConstantInt::get(i64Ty, 0), "eco.isconst");

        Instruction *embTerm = nullptr, *heapTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isConst, ci, &embTerm, &heapTerm);
        BasicBlock *contBB = ci->getParent();

        // Embedded constant: Bool -> i1 value; empty -> CONSTANT_TAG.
        IRBuilder<> tb(embTerm);
        Value *isTrue = tb.CreateICmpEQ(constField, ConstantInt::get(i64Ty, 1));
        Value *isFalse = tb.CreateICmpEQ(constField, ConstantInt::get(i64Ty, 0));
        Value *isBool = tb.CreateOr(isTrue, isFalse);
        Value *embTag = tb.CreateSelect(
            isBool, tb.CreateZExt(isTrue, i32Ty),
            ConstantInt::get(i32Ty, (uint64_t)CONSTANT_TAG), "eco.embtag");
        BasicBlock *embBB = embTerm->getParent();

        // Heap: resolve (marker), load header, mask tag, discriminate.
        IRBuilder<> hb(heapTerm);
        CallInst *base = hb.CreateCall(fwdMarker, {v}, "eco.tagbase");
        Value *hdr = hb.CreateAlignedLoad(i32Ty, base, Align(8), "eco.taghdr");
        Value *tag = hb.CreateAnd(hdr, (1u << TAG_BITS) - 1, "eco.tag");
        Value *isCustom =
            hb.CreateICmpEQ(tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Custom));
        Instruction *custTerm = nullptr, *otherTerm = nullptr;
        SplitBlockAndInsertIfThenElse(isCustom, heapTerm, &custTerm, &otherTerm);
        BasicBlock *heapJoinBB = heapTerm->getParent();

        IRBuilder<> cb(custTerm);
        Value *ctorPtr =
            cb.CreateGEP(i8Ty, base, ConstantInt::get(i64Ty, 8), "eco.ctorp");
        Value *ctor = cb.CreateZExt(
            cb.CreateAlignedLoad(i16Ty, ctorPtr, Align(8), "eco.ctor"), i32Ty);
        BasicBlock *custBB = custTerm->getParent();

        IRBuilder<> ob(otherTerm);
        Value *isCons =
            ob.CreateICmpEQ(tag, ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_Cons));
        // Chunked-list modules: a Tag_ConsChunk view is also the list Cons
        // constructor (ctor 1) for case dispatch. The extra compare is
        // emitted ONLY when the module enables chunk production (detected
        // via the injected eco_enable_list_chunks call), so non-chunk
        // binaries keep today's diamond byte-for-byte.
        {
            Function *chunksEnable = m.getFunction("eco_enable_list_chunks");
            if (chunksEnable && !chunksEnable->use_empty()) {
                Value *isChunk = ob.CreateICmpEQ(
                    tag,
                    ConstantInt::get(i32Ty, (uint64_t)Elm::Tag_ConsChunk));
                isCons = ob.CreateOr(isCons, isChunk, "eco.isconslike");
            }
        }
        Value *consOrZero = ob.CreateSelect(isCons, ConstantInt::get(i32Ty, 1),
                                            ConstantInt::get(i32Ty, 0));
        BasicBlock *otherBB = otherTerm->getParent();

        IRBuilder<> jb(&*heapJoinBB->getFirstInsertionPt());
        PHINode *heapTag = jb.CreatePHI(i32Ty, 2, "eco.heaptag");
        heapTag->addIncoming(ctor, custBB);
        heapTag->addIncoming(consOrZero, otherBB);

        IRBuilder<> pb(&*contBB->getFirstInsertionPt());
        PHINode *result = pb.CreatePHI(i32Ty, 2, "eco.gettag");
        result->addIncoming(embTag, embBB);
        result->addIncoming(heapTag, heapJoinBB);

        ci->replaceAllUsesWith(result);
        ci->eraseFromParent();
    }

    if (!marker->use_empty())
        report_fatal_error("expandGetTagMarkers: surviving __eco_get_tag_inline use");
    marker->eraseFromParent();
}

// E1.3 (LSS dispatch-value plan §5): force-inline small `$cap` fast-evaluator
// bodies BEFORE any RS4GC. Once a call is statepointed no inliner will touch
// it (the per-partition -O2 runs post-RS4GC), which is exactly why the E1.1
// audit found 9,449 un-inlined direct `$cap` calls despite 55 % of bodies
// being ≤64 B — this pre-statepoint prepass is the ONLY point in the pipeline
// where `$cap` inlining can happen. The order (inline → statepoint) is the
// standard upstream one, so relocation semantics (REP_LLVM_001) are
// unaffected; the merged bodies are statepointed and then optimized normally.
//
// Bodies at or under the instruction threshold get `alwaysinline` (honoured by
// the whole-module AlwaysInlinerPass run here, pre-split — so would-be
// cross-partition pairs inline too); larger bodies get `inlinehint` for any
// later cost-model inliner. `$cap` symbols are address-taken (closure
// evaluator fields), so the bodies survive for indirect dispatch regardless.
// ECO_CAP_INLINE_MAX_INSTS overrides the threshold (0 = hint-only, no
// forcing) for A/B tuning without a rebuild.

// NO signature-coercing direct-call fold here — that was tried and it
// MISCOMPILES (2026-07-20, "Pointer below heap base" at self-compile minor
// GC #52): rebuilding a mismatched `$cap` site with ptrtoint/inttoptr
// coercions and then INLINING it splices the crossings into open code, so an
// i64 derived from `ptrtoint ptr addrspace(1)` becomes live across the
// inlined body's statepoints — a REP_LLVM_001(a) violation by construction.
// Mismatched-view sites (the erased/boxed i64<->ptr classes) therefore stay
// in their AddressOf+indirect form and are simply not inlined (the pre-E1.3
// status quo, sound). Matching-signature sites need no fold at all: MLIR
// translation resolves their called operand to the Function with a matching
// FTy, so `getCalledFunction()` works and the AlwaysInliner below can eat
// them directly. Recovering the mismatched population would require callee
// cloning at the callee's REAL boxedness (AbiCloning-family work), not
// site-side casts.

// The GC-call-free guard is CONDITIONAL as of E1.3 v3 (REP_LLVM_002,
// plans/fold-proof-boxed-slot-crossings.md): with slot-cast barriers ON
// (ECO_SLOT_CAST_BARRIERS default), every boxed-slot i64<->ptr<1> crossing
// is an opaque gc-leaf barrier call this pass's AlwaysInliner cannot fold,
// so BOTH annihilation classes below are structurally impossible and
// GC-bearing bodies inline soundly — the guard is lifted. It is FORCED back
// on when barriers are disabled (ECO_SLOT_CAST_BARRIERS=0 would otherwise
// reconstruct the miscompiles) and available for A/B via
// ECO_CAP_INLINE_GCFREE_ONLY=1. The two bisected, IR-verified miscompile
// classes that used to force it unconditionally (both now fold-proof):
//
// 1. Capture-load annihilation (Terminal_Main_lambda_15194$cap): unpack
//    sites loaded boxed slots as i64+inttoptr; the body's boundary ptrtoint
//    folded with it during inlining (ptrtoint(inttoptr(x)) -> x) — raw i64s
//    crossed the inlined body's statepoints invisible to RS4GC. FIXED at the
//    source: the three unpack sites (ProjectClosureOpLowering,
//    emitFastClosureCall, getOrCreateWrapper) now emit TYPED
//    ptr addrspace(1) loads (E1.3 v2 — keep; sound and prerequisite).
//
// 2. INTERIOR boundary annihilation (Terminal_Main_lambda_14615$cap): the
//    SAME fold fires on every other boxed-slot idiom pair INSIDE an inlined
//    body — e.g. a tuple-projection (load i64 + inttoptr) feeding an
//    args-slot store (ptrtoint + store) across a direct call: the tracked
//    hop folds away, the raw i64 state pointer crosses the statepoint, and
//    a stale pointer lands in the GC-registered args buffer ("Invalid tag
//    value" at evacuate). Standalone bodies never fold (nothing simplifies
//    pre-RS4GC); InlineFunction's SimplifyInstruction does. FIXED by v3:
//    every boxed-slot crossing is now emitted as an opaque gc-leaf barrier
//    (EcoToLLVMInternal.h slot* helpers, REP_LLVM_002) that the inliner
//    cannot fold; StripEcoCastBarriers restores the bare casts strictly
//    post-RS4GC (addEcoGCPipeline placement).
//
// With no statepoint inside the body there is nothing to be live across, so
// the GC-call-free class is sound regardless of folding — which is why it
// remains the forced fallback when barriers are disabled.
static bool bodyIsGCCallFree(const Function &f) {
    for (const BasicBlock &bb : f)
        for (const Instruction &i : bb)
            if (auto *cb = dyn_cast<CallBase>(&i)) {
                const Function *cf = cb->getCalledFunction();
                if (!cf)
                    return false; // indirect: assume it can GC
                if (cf->isIntrinsic())
                    continue;
                if (cf->hasFnAttribute("gc-leaf-function"))
                    continue;
                return false;
            }
    return true;
}

// GC-free function propagation (plans/gc-free-function-propagation.md):
// stamp gc-leaf-function on generated functions that provably cannot GC.
// Runs once per module at the pre-RS4GC choke point; every RS4GC flavour
// then skips statepointing direct calls to stamped functions.
//
// Poison = any call RS4GC would statepoint whose callee is not a defined
// function in this module; poison propagates callee->caller to a fixed
// point (an optimistic worklist: a cycle of poison-free functions stays
// GC-free, which is correct — mutual recursion without allocation cannot
// GC). The leaf predicate is llvm::callsGCLeafFunction, i.e. literally the
// one RS4GC consults per call site, so the analysis cannot disagree with
// the pass about what a leaf call is.
//
// At this point in the pipeline allocation is visible ONLY as calls: the
// inline-alloc diamond's slow edge (eco_alloc_inline_slow, deliberately
// not gc-leaf), eco_gc_alloc_region_slow, the boxed eco_alloc_* family,
// and kernel externs. There is no write barrier and no safepoint poll.
static void propagateGcFreeLeafAttrs(Module &m, GcFreeMode mode) {
    TargetLibraryInfoImpl TLII(m.getTargetTriple());
    TargetLibraryInfo TLI(TLII);

    // Reverse call edges among defined functions, plus the poison seeds.
    DenseMap<const Function *, SmallPtrSet<Function *, 8>> callers;
    SmallVector<Function *, 128> worklist;
    DenseSet<const Function *> poisoned;

    unsigned numDefined = 0;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        ++numDefined;
        bool poison = f.isInterposable(); // analyzed body may not be linked
        for (BasicBlock &bb : f) {
            if (poison)
                break;
            for (Instruction &i : bb) {
                if (isa<LandingPadInst>(i)) { // EH: defensive, should not occur
                    poison = true;
                    break;
                }
                auto *cb = dyn_cast<CallBase>(&i);
                if (!cb)
                    continue;
                if (!isa<CallInst>(cb)) { // invoke/callbr: defensive
                    poison = true;
                    break;
                }
                if (llvm::callsGCLeafFunction(cb, TLI))
                    continue; // RS4GC's own per-call-site predicate
                Function *callee = cb->getCalledFunction();
                if (callee && !callee->isDeclaration() &&
                    !callee->isInterposable()) {
                    callers[callee].insert(&f); // resolved by the fixpoint
                    continue;
                }
                poison = true; // indirect call, or non-gc-leaf declaration
                break;
            }
        }
        if (poison) {
            poisoned.insert(&f);
            worklist.push_back(&f);
        }
    }

    while (!worklist.empty()) {
        Function *g = worklist.pop_back_val();
        auto it = callers.find(g);
        if (it == callers.end())
            continue;
        for (Function *caller : it->second)
            if (poisoned.insert(caller).second)
                worklist.push_back(caller);
    }

    // Census. numSites = direct call sites that will lose their statepoint;
    // counted BEFORE stamping, while callsGCLeafFunction still says false
    // for calls to the about-to-be-stamped callees.
    unsigned numFree = 0, numSites = 0;
    SmallVector<Function *, 64> freeFns;
    for (Function &f : m) {
        if (f.isDeclaration())
            continue;
        if (!poisoned.count(&f)) {
            ++numFree;
            freeFns.push_back(&f);
        }
        for (BasicBlock &bb : f)
            for (Instruction &i : bb)
                if (auto *cb = dyn_cast<CallBase>(&i))
                    if (Function *callee = cb->getCalledFunction())
                        if (!callee->isDeclaration() &&
                            !poisoned.count(callee) &&
                            !llvm::callsGCLeafFunction(cb, TLI))
                            ++numSites;
    }

    if (const char *dump = ::getenv("ECO_GCFREE_LEAF_DUMP")) {
        std::ofstream out(dump);
        for (Function *f : freeFns)
            out << f->getName().str() << "\n";
    }

    if (mode == GcFreeMode::Stamp)
        for (Function *f : freeFns)
            f->addFnAttr("gc-leaf-function");

    llvm::errs() << "[gcfree] " << numFree << "/" << numDefined
                 << " functions GC-free, " << numSites
                 << " direct call sites de-statepointed (mode="
                 << (mode == GcFreeMode::Stamp ? "stamp" : "census") << ")\n";
}

static void runCapInlinePrepass(Module &m) {
    unsigned maxInsts = 64;
    if (const char *e = ::getenv("ECO_CAP_INLINE_MAX_INSTS"))
        maxInsts = (unsigned)strtoul(e, nullptr, 10);

    // Delta-debug hook: ECO_CAP_INLINE_LIST=<file> marks EXACTLY the named
    // functions (one symbol per line), ignoring the threshold. Diagnostic
    // only — lets a crashing marked set be bisected to the guilty body.
    std::set<std::string> onlyList;
    bool useList = false;
    if (const char *lf = ::getenv("ECO_CAP_INLINE_LIST")) {
        useList = true;
        std::ifstream in(lf);
        std::string line;
        while (std::getline(in, line))
            if (!line.empty())
                onlyList.insert(line);
    }

    bool any = false;
    for (Function &f : m) {
        if (f.isDeclaration() || !f.getName().ends_with("$cap"))
            continue;
        if (f.hasFnAttribute(Attribute::NoInline))
            continue;
        // No InlineHint arm: nothing pre-RS4GC consumes a hint, and any attr
        // surviving into the post-RS4GC worker pipelines invites the
        // E1.4-forbidden inlining — attrs are strictly pass-local here.
        // REP_LLVM_002 coupling: the GC-call-free restriction applies only
        // for A/B (ECO_CAP_INLINE_GCFREE_ONLY=1) or FORCED when slot-cast
        // barriers are off — barriers-off + GC-bearing inlining is the
        // known-unsound combination (both bisected miscompiles). The old
        // ECO_CAP_INLINE_NO_GCFREE_GUARD escape is deleted: there is no
        // sound configuration it could enable that the default doesn't.
        static const bool gcfreeOnly =
            (::getenv("ECO_CAP_INLINE_GCFREE_ONLY") != nullptr) ||
            !slotCastBarriersEnabled();
        if (useList ? onlyList.count(f.getName().str()) != 0
                    : (maxInsts && f.getInstructionCount() <= maxInsts &&
                       (!gcfreeOnly || bodyIsGCCallFree(f)))) {
            f.addFnAttr(Attribute::AlwaysInline);
            any = true;
            static const bool dbg =
                (::getenv("ECO_CAP_INLINE_DEBUG") != nullptr);
            if (dbg)
                llvm::errs() << "[cap-inline] " << f.getName() << " insts="
                             << f.getInstructionCount() << "\n";
        }
    }
    if (!any)
        return;

    PassBuilder PB;
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    MPM.addPass(AlwaysInlinerPass());
    MPM.run(m, MAM);

    // STRIP the inline attrs now that the pre-RS4GC inline pass has consumed
    // them. Leaving them on would arm the POST-RS4GC per-partition pipelines
    // (Dev's explicit AlwaysInlinerPass, Cgu's -O2 inliner) on `$cap` bodies
    // that are statepointed by then — the E1.4-forbidden post-RS4GC inlining
    // that breaks relocation semantics. The attrs exist only for this pass.
    for (Function &f : m) {
        if (f.isDeclaration() || !f.getName().ends_with("$cap"))
            continue;
        f.removeFnAttr(Attribute::AlwaysInline);
    }
}

Error runEcoBackend(Module &m, const EcoBackendJob &job,
                    EcoBackendResult *result) {
    // P2.5 R1b: expand get_tag markers FIRST (their heap arms emit
    // __eco_resolve_fwd calls the next expansion consumes).
    expandGetTagMarkers(m);
    // Chunked-list projection markers (must precede expandInlineDerefs —
    // both this and get_tag emit __eco_resolve_fwd calls it then expands).
    expandListProjMarkers(m);
    // Mixed-spine cursor markers (EcoListCursor): same discipline.
    expandListCursorMarkers(m);
    // Scratch-stack helpers (chunked-list Tier-B templates): mark and the
    // pushes never GC-allocate, so exempt them from RS4GC statepointing.
    // eco_scratch_finish allocates and must statepoint normally.
    for (const char *leaf : {"eco_scratch_mark", "eco_scratch_push_boxed",
                             "eco_scratch_push_scalar"}) {
        if (Function *lf = m.getFunction(leaf))
            lf->addFnAttr("gc-leaf-function");
    }
    // Plan P2: expand inline-deref markers before RS4GC / partition splitting.
    expandInlineDerefs(m);
    // Inline nursery allocation (HEAP_034): expand bump-diamond markers.
    // Before the $cap prepass so marker-bearing bodies are correctly
    // classified (the expanded diamond's slow call makes them non-GC-free
    // for bodyIsGCCallFree in the barriers-off fallback config).
    expandInlineAllocs(m);

    // E1.3: `$cap` inline prepass — must precede EVERY RS4GC flavour (serial,
    // deferred, and per-partition; all are downstream of this point). Skipped
    // at -O0 only.
    if (job.optLevel != CodeGenOptLevel::None) {
        MaybeScope s(job.stats, "  $cap inline prepass (serial)");
        runCapInlinePrepass(m);
    }

    // GC-free function propagation (plans/gc-free-function-propagation.md):
    // must run at THIS choke point — post-marker-expansion + post-$cap-
    // prepass (allocation is visible as non-gc-leaf calls), pre-partition
    // (attrs then ride CloneModule / lazy deleteBody to every RS4GC
    // flavour: serial, deferred, workers, single-partition inline).
    if (gcFreeLeafMode() != GcFreeMode::Off) {
        MaybeScope s(job.stats, "  gc-free leaf propagation (serial)");
        propagateGcFreeLeafAttrs(m, gcFreeLeafMode());
    }

    RS4GCOptions rs4gcOpts;
    rs4gcOpts.preDumpPath = job.preRS4GCDumpPath;
    rs4gcOpts.postDumpPath = job.postRS4GCDumpPath;
    rs4gcOpts.addFramePointerAttr = job.needsFramePointerAttr;

    // EXPERIMENTAL: defer RS4GC to run AFTER opt (EmitObjectFile only). The
    // upfront call is skipped and re-issued below, post-optimization. The
    // bundled SROA/FoldExtractValue cleanup + frame-pointer injection travel
    // with it automatically (they live inside runRS4GCAndMaybeFramePointers).
    // Never combined with parallel-opt: the per-partition workers would then
    // optimize statepoint-free IR with no per-partition RS4GC to follow — GC
    // would break. Parallel-opt forces RS4GC-before (design doc §5).
    const bool deferRS4GC =
        job.rs4gcAfterOpt && job.kind == BackendKind::EmitObjectFile &&
        job.parallelOpt == ParallelOpt::None;

    // Parallel-opt modes move RS4GC + frame-pointer injection INTO the
    // per-partition workers: RS4GC is per-function (consults only callee
    // declaration attrs, preserved by the partition split), so statepointing
    // each partition in parallel is semantically identical to the whole-module
    // run — and the cheap-IPO prologue + split then operate on statepoint-free
    // IR (smaller, faster to serialize). Each worker runs RS4GC BEFORE its
    // optimization, preserving the GC ordering invariant per partition.
    // Diagnostic RS4GC IR dumps force the whole-module path so --dump-*-rs4gc-ir
    // keeps meaning "the module", not "one partition".
    const bool parallelOptEnabled =
        job.kind == BackendKind::EmitObjectFile &&
        job.parallelOpt != ParallelOpt::None &&
        job.optLevel != CodeGenOptLevel::None && job.splitEligible;
    const bool wantRS4GCDumps =
        !job.preRS4GCDumpPath.empty() || !job.postRS4GCDumpPath.empty();
    const bool rs4gcInWorkers = parallelOptEnabled && !wantRS4GCDumps;

    if (!deferRS4GC && !rs4gcInWorkers) {
        MaybeScope s(job.stats, "  RS4GC + frame-pointers (serial)");
        runRS4GCAndMaybeFramePointers(m, rs4gcOpts);
    }

    switch (job.kind) {
    case BackendKind::DumpLLVMText:
        // RS4GC + FP only. Caller owns opt + IR printing so it can pick a
        // TM-aware vs TM-agnostic optimisation pipeline for its use case.
        return Error::success();

    case BackendKind::EmitObjectFile: {
        if (parallelOptEnabled) {
            // Replace the whole-module -O2 with a cheap whole-module IPO
            // prologue; the heavy per-function work moves into the parallel
            // per-partition workers below (design doc §6.2/§6.3).
            MaybeScope s(job.stats, "  cheap-IPO prologue (serial)");
            runCheapModuleIPO(m);
        } else if (job.optLevel != CodeGenOptLevel::None && job.tm) {
            MaybeScope s(job.stats, "  whole-module opt (serial)");
            auto optPipeline = mlir::makeOptimizingTransformer(
                static_cast<unsigned>(job.optLevel), /*sizeLevel=*/0, job.tm);
            if (auto err = optPipeline(&m))
                return err;
        }
        // Deferred RS4GC runs here — after opt, before object emission.
        if (deferRS4GC)
            runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

        // Decide the partition count here (shared policy — see
        // choosePartitionCount / design_docs/backend-parallel-optimization.md
        // §8.1) rather than in each driver.
        unsigned numParts =
            choosePartitionCount(m, job.splitCodegen, job.splitEligible);
        // When parallel-opt is enabled the per-partition workers optimize;
        // otherwise they only emit (whole-module opt already ran above).
        const ParallelOpt perPart =
            parallelOptEnabled ? job.parallelOpt : ParallelOpt::None;

        // Parallel emission: split the optimized module and emit N objects
        // across threads. The backend owns the extra temp part files; the
        // driver links `result->objectFiles` and removes
        // `result->ownedTempFiles`. See emitObjectFilesSplit.
        if (numParts > 1) {
            if (job.objectFilePath.empty())
                return createStringError(std::errc::invalid_argument,
                    "EmitObjectFile split requires a base objectFilePath");
            std::vector<std::string> paths;
            std::vector<std::string> owned;
            paths.reserve(numParts);
            // Reuse the caller's objectFilePath as partition 0; mint the rest.
            paths.push_back(job.objectFilePath);
            for (unsigned i = 1; i < numParts; ++i) {
                SmallString<256> p;
                if (auto ec = sys::fs::createTemporaryFile("eco-part", "o", p)) {
                    for (auto &f : owned)
                        sys::fs::remove(f);
                    return createStringError(ec,
                        "Could not create temp object file for partition");
                }
                paths.emplace_back(p.str());
                owned.emplace_back(p.str());
            }
            // Lazy split's per-worker strip handles functions + globals only;
            // aliases/ifuncs would be duplicated across partitions. eco's
            // codegen never emits them, but fall back to SplitModule if any
            // appear so the lazy path is always safe to enable.
            const bool canLazy =
                job.lazySplit && m.aliases().empty() && m.ifuncs().empty();
            auto splitFn =
                canLazy ? emitObjectFilesSplitLazy : emitObjectFilesSplit;
            if (auto err = splitFn(
                    m, numParts, paths, job.optLevel, perPart,
                    job.devEmitCodeGenLevel, job.devOptO1, job.stats,
                    rs4gcInWorkers ? &rs4gcOpts : nullptr)) {
                for (auto &f : owned)
                    sys::fs::remove(f);
                return err;
            }
            if (result) {
                result->objectFiles = std::move(paths);
                result->ownedTempFiles = std::move(owned);
            }
            return Error::success();
        }

        // Single-object emission. If parallel-opt is enabled but the policy
        // chose a single partition (small module / split off), run the
        // per-partition pipeline here inline — the whole-module -O2 was
        // skipped (and RS4GC too when rs4gcInWorkers).
        if (rs4gcInWorkers)
            runRS4GCAndMaybeFramePointers(m, rs4gcOpts);
        if (perPart != ParallelOpt::None) {
            if (auto err = optimizePartitionModule(
                    m, job.tm, perPart, job.optLevel, job.devOptO1))
                return err;
        }
        if (!job.objectFilePath.empty()) {
            if (!job.tm)
                return createStringError(std::errc::invalid_argument,
                    "EmitObjectFile requires a TargetMachine");
            if (auto err = emitObjectFile(m, *job.tm, job.objectFilePath))
                return err;
        }
        if (result)
            result->objectFiles = {job.objectFilePath};
        return Error::success();
    }

    case BackendKind::JITInvokePacked: {
        // JIT path: always run makeOptimizingTransformer (level 0 is a no-op-ish
        // pipeline; matches the pre-Phase-4 behaviour of ecoc::runJIT and
        // EcoRunner::executeJIT). `tm` is typically nullptr — the JIT picks
        // up the real TargetMachine through EcoJIT::create, and the lambda
        // runs after DL is already on the module.
        //
        // The "invalid optimization/size level 288/0" cantFail abort that used
        // to strike here flakily (previously observed on Windows, then on the
        // Linux fork-per-test runner) was NOT an MLIR OptUtils static-state
        // bug: it was a dangling reference. EcoJITOptions::transformer was a
        // non-owning llvm::function_ref bound to a temporary lambda; by the
        // time EcoJIT::create invoked it, the temporary was gone, so job was
        // built by a dead lambda and job.optLevel read stack garbage (288).
        // Fixed by making transformer an owning std::function (EcoJIT.h). The
        // Windows skip below is now redundant but retained conservatively
        // pending a Windows test run.
#if defined(_WIN32)
        return Error::success();
#else
        auto optPipeline = mlir::makeOptimizingTransformer(
            static_cast<unsigned>(job.optLevel), /*sizeLevel=*/0, job.tm);
        if (auto err = optPipeline(&m))
            return err;
        return Error::success();
#endif
    }
    }

    llvm_unreachable("Unknown BackendKind");
}

} // namespace eco
