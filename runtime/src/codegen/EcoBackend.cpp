//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"

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
#include "llvm/IR/LLVMContext.h"
#include "llvm/Support/MemoryBuffer.h"

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

using namespace llvm;

namespace eco {

namespace {

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

    ModulePassManager MPM;
    MPM.addPass(IPSCCPPass());
    MPM.addPass(GlobalOptPass());
    MPM.addPass(
        createModuleToPostOrderCGSCCPassAdaptor(PostOrderFunctionAttrsPass()));
    MPM.addPass(ReversePostOrderFunctionAttrsPass());
    MPM.addPass(GlobalDCEPass());
    MPM.run(m, MAM);
}

// No-inline per-partition pipeline (Dev tier): honour explicit `alwaysinline`
// attrs, then run the standard per-function simplification pipeline
// (InstCombine / SROA / GVN / SimplifyCFG / LICM / vectorizers …) with NO CGSCC
// inliner. That fused inliner+simplification is the bulk of an -O2 pipeline's
// wall-clock; dropping the inliner makes the rest embarrassingly parallel.
Error runNoInlineFunctionPipeline(Module &m, TargetMachine *tm,
                                  CodeGenOptLevel optLevel) {
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
        PB.buildFunctionSimplificationPipeline(toOptLevel(optLevel),
                                               ThinOrFullLTOPhase::None)));
    MPM.run(m, MAM);
    return Error::success();
}

// Optimize one partition module in place according to the parallel-opt tier.
// Dev  = no-inline function pipeline (fast, lower quality).
// Cgu  = full -O2 per partition (keeps intra-partition CGSCC inlining).
Error optimizePartitionModule(Module &m, TargetMachine *tm, ParallelOpt mode,
                              CodeGenOptLevel optLevel) {
    if (mode == ParallelOpt::Cgu) {
        auto opt = mlir::makeOptimizingTransformer(
            static_cast<unsigned>(optLevel), /*sizeLevel=*/0, tm);
        return opt(&m);
    }
    return runNoInlineFunctionPipeline(m, tm, optLevel);
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
                           ParallelOpt perPartitionMode) {
    if (paths.size() != numPartitions)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplit: paths count != numPartitions");

    // Serialize each partition to bitcode in the parent context
    // (single-threaded — SplitModule hands sub-modules over one at a time).
    std::vector<SmallString<0>> bitcodes(numPartitions);
    unsigned idx = 0;
    SplitModule(
        m, numPartitions,
        [&](std::unique_ptr<Module> mp) {
            if (idx < numPartitions) {
                raw_svector_ostream os(bitcodes[idx]);
                WriteBitcodeToFile(*mp, os);
            }
            ++idx;
        },
        /*PreserveLocals=*/false);

    unsigned produced = idx;
    if (produced == 0)
        return createStringError(std::errc::invalid_argument,
            "emitObjectFilesSplit: SplitModule produced no partitions");

    // Emit partitions concurrently: fresh context + TargetMachine per thread.
    std::atomic<unsigned> nextFail{0};
    std::vector<std::string> errs(produced);
    std::vector<std::thread> threads;
    threads.reserve(produced);
    for (unsigned i = 0; i < produced; ++i) {
        threads.emplace_back([&, i] {
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
            auto tm = createEcoTargetMachine(*mod,
                                             static_cast<unsigned>(optLevel));
            if (!tm) {
                errs[i] = "createEcoTargetMachine failed for partition " +
                          std::to_string(i);
                nextFail++;
                return;
            }
            // Parallel opt: optimize this partition on its own thread before
            // emission (the whole-module -O2 was skipped upstream).
            if (perPartitionMode != ParallelOpt::None) {
                if (auto err = optimizePartitionModule(
                        *mod, tm.get(), perPartitionMode, optLevel)) {
                    errs[i] = "partition opt failed for partition " +
                              std::to_string(i) + ": " +
                              toString(std::move(err));
                    nextFail++;
                    return;
                }
            }
            if (auto err = emitObjectFile(*mod, *tm, paths[i])) {
                errs[i] = "emitObjectFile failed for partition " +
                          std::to_string(i) + ": " + toString(std::move(err));
                nextFail++;
                return;
            }
        });
    }
    for (auto &t : threads)
        t.join();

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
    // Auto caps at 16: beyond that the serial split + per-partition
    // bitcode-serialize overhead outweighs the extra emission parallelism.
    unsigned want = (request == 0) ? std::min(cores, 16u) : request;
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

Error runEcoBackend(Module &m, const EcoBackendJob &job,
                    EcoBackendResult *result) {
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
    if (!deferRS4GC)
        runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

    switch (job.kind) {
    case BackendKind::DumpLLVMText:
        // RS4GC + FP only. Caller owns opt + IR printing so it can pick a
        // TM-aware vs TM-agnostic optimisation pipeline for its use case.
        return Error::success();

    case BackendKind::EmitObjectFile: {
        // Parallel-opt is honoured only for optimized, split-eligible exe
        // output; otherwise fall back to today's whole-module -O2.
        const bool parallelOptEnabled =
            job.parallelOpt != ParallelOpt::None &&
            job.optLevel != CodeGenOptLevel::None && job.splitEligible;

        if (parallelOptEnabled) {
            // Replace the whole-module -O2 with a cheap whole-module IPO
            // prologue; the heavy per-function work moves into the parallel
            // per-partition workers below (design doc §6.2/§6.3).
            runCheapModuleIPO(m);
        } else if (job.optLevel != CodeGenOptLevel::None && job.tm) {
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
            if (auto err = emitObjectFilesSplit(m, numParts, paths,
                                                job.optLevel, perPart)) {
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
        // per-partition pipeline here inline — the whole-module -O2 was skipped.
        if (perPart != ParallelOpt::None) {
            if (auto err =
                    optimizePartitionModule(m, job.tm, perPart, job.optLevel))
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
        // Windows v1: mlir::makeOptimizingTransformer asserts
        // "invalid optimization/size level X/0" after the FIRST successful
        // JIT execution in the test runner — the speed level it receives is
        // garbage on the second invocation despite `job.optLevel` being None.
        // Symptom is consistent across runs; root cause looks like a static
        // state issue inside MLIR's OptUtils on lld-link + /MT. The runner
        // tests don't depend on JIT opt, so skip the transformer on Windows
        // until the LLVM-side issue is isolated and either patched upstream
        // or worked around here. RS4GC + frame pointers already ran in
        // runRS4GCAndMaybeFramePointers() above, so correctness is unaffected.
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
