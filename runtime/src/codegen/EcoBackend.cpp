//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"

#include "LoweringStats.h"
#include "Passes/EcoPtrIntVerify.h" // for addEcoGCPipeline

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
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/Bitcode/BitcodeReader.h"
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

    // Force frame pointers so libunwind can walk JIT/AOT frames for GC root
    // discovery.
    if (opts.addFramePointerAttr) {
        for (Function &F : m) {
            if (!F.isDeclaration())
                F.addFnAttr("frame-pointer", "all");
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

Error runEcoBackend(Module &m, const EcoBackendJob &job,
                    EcoBackendResult *result) {
    // Plan P2: expand inline-deref markers before RS4GC / partition splitting.
    expandInlineDerefs(m);

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
