//===- eco-boot.cpp - Eco native compiler driver --------------------------===//
//
// eco-boot is the command-line compiler that turns one Elm program into a
// native program.
//
// The input is a `.elm` file, a `.mlir` file, or a `.o` file (re-link only),
// and the output, chosen by `--emit` and the output path, is an executable,
// a shared library (an output path ending in `.so` or `.node`), an object
// file, LLVM IR text, or, for `.elm` input, MLIR text. A run goes through
// these steps, stopping after the one that produces the requested output:
//
//   1. For `.elm` input, the Elm frontend, a Node.js script named by
//      `--frontend`, writes the program as MLIR in the Eco dialect.
//   2. The MLIR is parsed and lowered to the LLVM dialect by the pipeline
//      `eco::buildEcoToLLVMPipeline` builds.
//   3. The module is translated to LLVM IR and lowered to object code by
//      `eco::runEcoBackend`, or, when `eco::mlirSplitPartitionCount` allows,
//      split in MLIR and translated and lowered one partition per thread by
//      `eco::lowerMlirSplit`.
//   4. The object files are linked with the runtime and kernel libraries by
//      `eco::linkExecutable`, or, for object output split into partitions,
//      joined into one object by a relocatable link (`-r`) with the system
//      linker that `EcoBootConfig.h` names.
//
// A `.o` input goes straight to step 4, so an object built earlier can be
// re-linked against rebuilt runtime and kernel libraries without lowering it
// again.
//
// Two ideas shape `main`. An executable, or an object built with
// `--internalize-keep`, is closed-world: nothing outside the output refers to
// it except through a few named root symbols. That is known from the command
// line alone, before the MLIR pipeline runs, so the pipeline can erase what
// the roots cannot reach and the backend can be told the same answer. And the
// MLIR state is the largest thing in memory, so it lives in a nested scope
// that ends as soon as translation to LLVM IR is done.
//
// Each phase is timed into an `eco::LoweringStats`, printed to stderr at the
// end unless `--lowering-stats=false` is given.
//
// Usage: eco-boot <input.elm|input.mlir|input.o> [options]
//
//===----------------------------------------------------------------------===//

#include <cassert>
#include <cstring>
#include <algorithm>
#include <thread>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Extensions/AllExtensions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/LLVMIR/Transforms/InlinerInterfaceImpl.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVMPass.h"
#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"

#include "mlir/ExecutionEngine/OptUtils.h"

#include "mlir/IR/AsmState.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/OwningOpRef.h"
#include "mlir/IR/Verifier.h"

#include "mlir/Parser/Parser.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassManager.h"

#include "mlir/Support/FileUtilities.h"

#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "mlir/Transforms/Passes.h"

#include "llvm/ADT/ScopeExit.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/Support/SourceMgr.h"

#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/TargetParser/SubtargetFeature.h"

#include "EcoDialect.h"
#include "EcoOps.h"
#include "Passes.h"
#include "EcoBackend.h"
#include "EcoPipeline.h"
#include "EcoSplit.h"
#include "LoweringStats.h"

#include "llvm/Analysis/TargetLibraryInfo.h"

// Does nothing; calling it keeps the "eco-gc" GC strategy registration from
// being dropped when it comes from a static library.
namespace eco { void linkEcoGCStrategy(); }
// A static object whose constructor calls `eco::linkEcoGCStrategy`, so that
// the object file holding the "eco-gc" strategy registration is linked in.
static struct EcoGCStrategyLinker {
    // Calls `eco::linkEcoGCStrategy`.
    EcoGCStrategyLinker() { eco::linkEcoGCStrategy(); }
} ecoGCStrategyLinker;

// Generated by CMake. Gives the deployment paths, including
// `eco::config::systemLinker`.
#include "eco/EcoBootConfig.h"
#include "Passes/EcoSymbolGraph.h"
#include <cstdio>
#if !defined(_WIN32)
#include <unistd.h>
#endif
#include "llvm/IR/PassTimingInfo.h"
#if defined(__GLIBC__)
#include <malloc.h>
#endif

using namespace mlir;

namespace cl = llvm::cl;

//===----------------------------------------------------------------------===//
// Command Line Options
//===----------------------------------------------------------------------===//

static cl::opt<std::string> inputFilename(
    cl::Positional,
    cl::desc("<input .elm, .mlir, or .o file>"),
    cl::Required);

static cl::opt<std::string> outputFilename(
    "o",
    cl::desc("Output path (default: a.out for exe, <input>.o for obj)"),
    cl::value_desc("filename"),
    cl::init(""));

namespace {
/**
 * The kind of output `--emit` asks for.
 */
enum Action {
    EmitExe,
    EmitObj,
    EmitLLVM,
    EmitMLIR
};
} // namespace

// The kind of output. Its `exe` help says ELF, but the executable format is
// the host's. An output path ending in `.o` makes `exe` produce an object,
// and one ending in `.so` or `.node` makes it produce a shared library.
static cl::opt<enum Action> emitAction(
    "emit",
    cl::desc("Select the kind of output desired"),
    cl::values(
        clEnumValN(EmitExe, "exe", "Emit linked ELF executable (default)"),
        clEnumValN(EmitObj, "obj", "Emit object file only"),
        clEnumValN(EmitLLVM, "llvm", "Emit LLVM IR"),
        clEnumValN(EmitMLIR, "mlir", "Emit MLIR (frontend only)")),
    cl::init(EmitExe));

static cl::opt<unsigned> optLevel(
    "O",
    cl::desc("Optimization level (0-3)"),
    cl::value_desc("level"),
    cl::init(2));

static cl::opt<std::string> frontendRunner(
    "frontend",
    cl::desc("Path to Node.js runner script (eco-boot-2-runner.js)"),
    cl::value_desc("path"),
    cl::init(""));

static cl::opt<std::string> workDir(
    "workdir",
    cl::desc("Working directory for frontend (auto-detected from elm.json if omitted)"),
    cl::value_desc("path"),
    cl::init(""));

static cl::opt<bool> verbose(
    "verbose",
    cl::desc("Print subcommands being executed"),
    cl::init(false));

static cl::opt<bool> gcSections(
    "gc-sections",
    cl::desc("Link with --gc-sections (+ .llvm_stackmaps KEEP) to strip dead "
             "sections. Binary-size only; opt-in until broadly validated"),
    cl::init(false));

// The requested number of parallel emission partitions, as
// `eco::EcoBackendJob::splitCodegen` defines it. Despite its help, the split
// may be made in MLIR before optimization; see `eco::mlirSplitPartitionCount`.
static cl::opt<unsigned> splitCodegen(
    "split-codegen",
    cl::desc("Parallel object emission: split the optimized module into N "
             "partitions emitted concurrently (executable output only). "
             "0 = auto (cores), 1 = off"),
    cl::init(0));

// The parallel-optimization tier, as `eco::ParallelOpt` defines it.
static cl::opt<eco::ParallelOpt> parallelOpt(
    "parallel-opt",
    cl::desc("Parallelize the LLVM optimization stage across partitions "
             "(executable output only)"),
    cl::values(
        clEnumValN(eco::ParallelOpt::None, "none",
                   "whole-module -O2 then codegen-only split"),
        clEnumValN(eco::ParallelOpt::Dev, "dev",
                   "cheap IPO prologue + no-inline per-partition pipeline "
                   "(fastest compile, lower-quality output)"),
        clEnumValN(eco::ParallelOpt::Cgu, "cgu",
                   "cheap IPO prologue + full -O2 per partition (parallel opt, "
                   "keeps intra-partition inlining; default)")),
    cl::init(eco::ParallelOpt::Cgu));

static cl::opt<unsigned> devEmitCG(
    "dev-emit-cg",
    cl::desc("Dev tier only: override the per-partition object-emission CodeGen "
             "opt level (0=None/FastISel, 1=Less, 2=Default). Default: follow "
             "-O. Only affects --parallel-opt=dev split workers"),
    cl::init(~0u));

static cl::opt<bool> devOptO1(
    "dev-opt-o1",
    cl::desc("Dev tier only: run the no-inline per-partition simplification "
             "pipeline at OptimizationLevel::O1 instead of the -O-derived "
             "level. Off by default"),
    cl::init(false));

static cl::opt<bool> rs4gcAfterOpt(
    "rs4gc-after-opt",
    cl::desc("EXPERIMENTAL: run RewriteStatepointsForGC after the O2 pipeline "
             "instead of before (faster opt, but risks REP_LLVM_001(a)). "
             "Off by default; needs GC-stress validation before default use"),
    cl::init(false));

static cl::opt<std::string> dumpRS4GCIR(
    "dump-rs4gc-ir",
    cl::desc("Dump LLVM IR to file after RS4GC pass (for GC diagnostics)"),
    cl::value_desc("filename"),
    cl::init(""));

static cl::opt<std::string> dumpPreRS4GCIR(
    "dump-pre-rs4gc-ir",
    cl::desc("Dump LLVM IR to file before RS4GC pass (for GC diagnostics)"),
    cl::value_desc("filename"),
    cl::init(""));

static cl::opt<std::string> internalizeKeep(
    "internalize-keep",
    cl::desc("Object output only: internalize every definition except this "
             "comma-separated symbol list, then GlobalDCE (what executable "
             "output does with eco_main,__eco_init_globals). For objects whose "
             "consumer references only these symbols, e.g. bootstrap Stage 9"),
    cl::value_desc("sym1,sym2,..."),
    cl::init(""));

static cl::opt<bool> printStats(
    "lowering-stats",
    cl::desc("Print lowering-pipeline timing breakdown to stderr at exit"),
    cl::init(true));

//===----------------------------------------------------------------------===//
// Frontend Invocation
//===----------------------------------------------------------------------===//

// Returns whether `path` names an Elm source file, by its extension.
static bool isElmFile(llvm::StringRef path) {
    return path.ends_with(".elm");
}

// Returns whether `path` names an MLIR file, by its extension.
static bool isMlirFile(llvm::StringRef path) {
    return path.ends_with(".mlir");
}

// Returns whether `path` names an object file, by its extension.
static bool isObjectFile(llvm::StringRef path) {
    return path.ends_with(".o");
}

// Returns the nearest directory containing `elm.json` among the directories
// named in `startPath`, searching upwards from its directory part, or an empty
// string if there is none.
//
// Only directories written in `startPath` are searched.
static std::string findElmProjectRoot(const std::string &startPath) {
    llvm::SmallString<256> dir(startPath);
    llvm::sys::path::remove_filename(dir); // start from file's parent

    while (!dir.empty()) {
        llvm::SmallString<256> candidate(dir);
        llvm::sys::path::append(candidate, "elm.json");
        if (llvm::sys::fs::exists(candidate))
            return std::string(dir);

        // parent_path returns a StringRef into dir's buffer, so copy it
        // to a temporary before reassigning.
        std::string parent(llvm::sys::path::parent_path(dir));
        if (parent == std::string(dir))
            break; // reached filesystem root
        dir = parent;
    }
    return "";
}

// Runs the Elm frontend to compile `elmFile` into MLIR written to
// `mlirOutput`, and returns 0 on success or 1 on failure, with the reason on
// stderr.
//
// The frontend runs as `node <--frontend> make --output=<mlirOutput>
// <elmFile>`, with both paths made absolute, in the Elm project directory:
// `--workdir` if given, or else the one `findElmProjectRoot` finds. The call
// changes the process's working directory for the duration of the child and
// then changes it back. It returns 1 if `--frontend` is unset or `node` is
// not on the path.
static int compileElmToMlir(const std::string &elmFile,
                             const std::string &mlirOutput) {
    if (frontendRunner.empty()) {
        llvm::errs() << "Error: --frontend=<path> is required for .elm input\n";
        return 1;
    }

    auto nodeOrErr = llvm::sys::findProgramByName("node");
    if (!nodeOrErr) {
        llvm::errs() << "Error: 'node' not found in PATH\n";
        return 1;
    }

    // Determine the Elm project directory (must contain elm.json).
    std::string projectDir = workDir;
    if (projectDir.empty())
        projectDir = findElmProjectRoot(elmFile);
    if (projectDir.empty()) {
        llvm::errs() << "Error: Could not find elm.json for '" << elmFile
                     << "'. Use --workdir=<dir> to specify the project root.\n";
        return 1;
    }

    // Make elmFile and mlirOutput absolute before changing cwd.
    llvm::SmallString<256> absElm(elmFile);
    llvm::sys::fs::make_absolute(absElm);
    llvm::SmallString<256> absOutput(mlirOutput);
    llvm::sys::fs::make_absolute(absOutput);

    std::string outputArg = "--output=" + std::string(absOutput);

    llvm::SmallVector<llvm::StringRef> args;
    args.push_back(*nodeOrErr);
    args.push_back(frontendRunner);
    args.push_back("make");
    args.push_back(outputArg);
    args.push_back(llvm::StringRef(absElm));

    if (verbose) {
        llvm::errs() << "[eco-boot] frontend (cwd=" << projectDir << "):";
        for (auto &a : args)
            llvm::errs() << " " << a;
        llvm::errs() << "\n";
    }

    // Save current directory, cd to project root, invoke frontend, restore.
    llvm::SmallString<256> savedCwd;
    llvm::sys::fs::current_path(savedCwd);
    if (auto ec = llvm::sys::fs::set_current_path(projectDir)) {
        llvm::errs() << "Error: Could not change to directory '"
                     << projectDir << "': " << ec.message() << "\n";
        return 1;
    }

    std::string errMsg;
    int rc = llvm::sys::ExecuteAndWait(
        *nodeOrErr, args, /*env=*/std::nullopt,
        /*redirects=*/{}, /*secondsToWait=*/0, /*memoryLimit=*/0, &errMsg);

    // Restore original working directory.
    llvm::sys::fs::set_current_path(savedCwd);

    if (rc != 0) {
        llvm::errs() << "Error: frontend compilation failed";
        if (!errMsg.empty())
            llvm::errs() << ": " << errMsg;
        llvm::errs() << "\n";
        return 1;
    }
    return 0;
}

//===----------------------------------------------------------------------===//
// MLIR Loading and Pipeline
//===----------------------------------------------------------------------===//

// Parses the buffer in `sourceMgr` as an MLIR module in `context`, and
// returns it, or null after a message on stderr if parsing fails.
static OwningOpRef<ModuleOp> loadMLIR(MLIRContext &context,
                                       llvm::SourceMgr &sourceMgr) {
    auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
    if (!module)
        llvm::errs() << "Error: Failed to parse MLIR file\n";
    return module;
}

// Lowers `module` in place from the Eco dialect to the LLVM dialect with the
// pipeline `eco::buildEcoToLLVMPipeline` builds from `pipeOpts`, and returns
// 0 on success or 1 on failure.
//
// The MLIR pass-manager command-line options apply, and each pass is timed
// into `stats`. Unless the build defines `ECO_LOWERING_VALIDATION`, the
// module is not verified after each pass.
static int runPipeline(ModuleOp module, eco::LoweringStats &stats,
                       const eco::EcoPipelineOptions &pipeOpts) {
    PassManager pm(module->getName());

    if (failed(applyPassManagerCLOptions(pm)))
        return 1;

#ifndef ECO_LOWERING_VALIDATION
    // Each verification walks the whole module, and the parser has already
    // verified the input. Validation builds keep it, to find a pass that
    // emits invalid IR.
    pm.enableVerifier(false);
#endif

    // Installed before any pass is added, so every pass is timed.
    pm.addInstrumentation(stats.makePassInstrumentation());

    eco::buildEcoToLLVMPipeline(pm, pipeOpts);

    if (failed(pm.run(module)))
        return 1;

    return 0;
}

//===----------------------------------------------------------------------===//
// LLVM IR Translation
//===----------------------------------------------------------------------===//

// Translates the LLVM-dialect `module` into an LLVM module in `llvmContext`,
// with the function `main` renamed `eco_main`, and returns it, or null after
// a message on stderr if translation fails.
//
// The result does not refer to `module` or its context. Unless the build
// defines `ECO_LOWERING_VALIDATION`, the result is not verified.
static std::unique_ptr<llvm::Module> translateToLLVMIR(
    ModuleOp module, llvm::LLVMContext &llvmContext) {
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    // Skipped for the same reason as the verifier in `runPipeline`.
#ifdef ECO_LOWERING_VALIDATION
    constexpr bool kDisableLLVMVerify = false;
#else
    constexpr bool kDisableLLVMVerify = true;
#endif
    auto llvmModule = translateModuleToLLVMIR(
        module, llvmContext, "LLVMDialectModule", kDisableLLVMVerify);
    if (!llvmModule) {
        llvm::errs() << "Error: Failed to translate MLIR to LLVM IR\n";
        return nullptr;
    }

    if (auto *mainFn = llvmModule->getFunction("main")) {
        mainFn->setName("eco_main");
    }

    return llvmModule;
}

//===----------------------------------------------------------------------===//
// Output Kind and Linking
//===----------------------------------------------------------------------===//

#include "EcoNativeDriver.h"

// Returns whether `outputPath` asks for a shared library, which it does by
// ending in `.so` or `.node`.
static bool outputIsSharedLib(const std::string &outputPath) {
    auto endsWith = [&](const char *suffix) {
        size_t n = std::strlen(suffix);
        return outputPath.size() >= n &&
               outputPath.compare(outputPath.size() - n, n, suffix) == 0;
    };
    return endsWith(".so") || endsWith(".node");
}

// These three functions decide, from the command line alone, whether the
// output is closed-world and which MLIR symbols stay visible, so that the MLIR
// pipeline can be told before it runs. `main` decides the output kind again
// in the MLIR-split branch (`objOnly`, `isExe`) and after translation
// (`emitObjOnly`, `isExecutable`); all must agree.

// Returns whether the output is a single object file: `--emit=obj`, or
// `output` ending in `.o`.
static bool capOutputObjOnly(const std::string &output) {
    return emitAction == EmitObj ||
           (output.size() >= 2 &&
            output.compare(output.size() - 2, 2, ".o") == 0);
}
// Returns whether the output for `output` is closed-world: an executable, or
// an object with a non-empty `--internalize-keep`. Shared libraries,
// `--emit=llvm` and `--emit=mlir` are not.
static bool capClosedWorld(const std::string &output) {
    if (emitAction != EmitExe && emitAction != EmitObj)
        return false; // --emit=llvm / mlir: no internalization
    const bool objOnly = capOutputObjOnly(output);
    if (!objOnly)
        return !outputIsSharedLib(output); // executable
    return !internalizeKeep.empty();
}
// Returns the MLIR pipeline options for `output`. For closed-world output
// they turn on reachability, with the roots `main` and `__eco_init_globals`
// for an executable, or the `--internalize-keep` names for an object, where
// `eco_main` is given as `main`, its name in MLIR. Otherwise they are the
// defaults.
static eco::EcoPipelineOptions capPipelineOptions(const std::string &output) {
    eco::EcoPipelineOptions o;
    o.capClosedWorld = capClosedWorld(output);
    if (!o.capClosedWorld)
        return o;
    o.reachability = true;
    if (!capOutputObjOnly(output)) {
        o.capRoots = {"main", "__eco_init_globals"};
    } else {
        llvm::SmallVector<llvm::StringRef> parts;
        llvm::StringRef(internalizeKeep).split(parts, ',', -1, false);
        for (llvm::StringRef k : parts) {
            k = k.trim();
            o.capRoots.push_back(k == "eco_main" ? "main" : k.str());
        }
    }
    return o;
}

// Links `objectFile` into `outputPath` with `eco::linkExecutable`, as a
// shared library when `outputIsSharedLib` says so, under `--verbose` and
// `--gc-sections`. Returns 0 on success and 1 on failure.
static int linkExecutable(const std::string &objectFile,
                          const std::string &outputPath) {
    eco::EcoNativeOptions opts;
    opts.verbose = verbose;
    opts.gcSections = gcSections;
    return eco::linkExecutable(objectFile, outputPath, opts,
                               outputIsSharedLib(outputPath));
}

// Links `objectFiles` into `outputPath`, as the single-object overload does.
static int linkExecutable(const std::vector<std::string> &objectFiles,
                          const std::string &outputPath) {
    eco::EcoNativeOptions opts;
    opts.verbose = verbose;
    opts.gcSections = gcSections;
    return eco::linkExecutable(objectFiles, outputPath, opts,
                               outputIsSharedLib(outputPath));
}

//===----------------------------------------------------------------------===//
// Output Path Logic
//===----------------------------------------------------------------------===//

// Returns the output path: `-o` if given, and otherwise `a.out` for
// `--emit=exe`, the input with its extension replaced by `.o` or `.ll` for
// `--emit=obj` or `--emit=llvm`, and `-`, meaning stdout, for `--emit=mlir`.
static std::string getOutputPath() {
    if (!outputFilename.empty())
        return outputFilename;

    switch (emitAction) {
    case EmitExe:
        return "a.out";
    case EmitObj: {
        llvm::SmallString<256> path(inputFilename.getValue());
        llvm::sys::path::replace_extension(path, ".o");
        return std::string(path);
    }
    case EmitLLVM: {
        llvm::SmallString<256> path(inputFilename.getValue());
        llvm::sys::path::replace_extension(path, ".ll");
        return std::string(path);
    }
    case EmitMLIR:
        return "-"; // stdout
    }
    return "a.out";
}

//===----------------------------------------------------------------------===//
// Main
//===----------------------------------------------------------------------===//

// Whether partition objects can be joined into the one requested object with
// a relocatable link (`systemLinker -r`). COFF linkers have no `-r`, so on
// Windows object output is not split-eligible; executables still are, since
// the final link takes every partition object.
#if defined(_WIN32)
static constexpr bool kCanRelinkObjects = false;
#else
static constexpr bool kCanRelinkObjects = true;
#endif

// Flushes the output streams and, unless LLVM's timing or statistics reports
// are on (POSIX only), ends the process with exit status `rc` without running
// static destructors or freeing what is still allocated.
//
// On Windows it never returns: it calls `TerminateProcess`, which skips the
// DLL detach and static-destructor sweep that can stall when a process
// linked with all of LLVM and MLIR exits normally. On POSIX it calls `_exit`,
// skipping the destruction of the LLVM module and the rest, unless
// `-time-passes` or LLVM statistics are on, whose reports are printed by
// static destructors; then it returns and the caller exits normally.
//
// Every output must be written and every temporary file removed before the
// call.
static void ecoBootFinalExit(int rc) {
#if defined(_WIN32)
    llvm::outs().flush();
    llvm::errs().flush();
    ::TerminateProcess(::GetCurrentProcess(), static_cast<UINT>(rc));
    // TerminateProcess is asynchronous. If it returns, wait here for the
    // process to end rather than fall through to the CRT teardown.
    for (;;) { ::Sleep(1000); }
#else
    if (!llvm::TimePassesIsEnabled && !llvm::AreStatisticsEnabled()) {
        llvm::outs().flush();
        llvm::errs().flush();
        std::fflush(nullptr);
        ::_exit(rc);
    }
#endif
}

// Compiles the input named on the command line into the output `--emit` and
// the output path ask for, as the file comment describes, and returns the
// process exit status: 0 on success, and nonzero on failure, with the reason
// on stderr.
//
// Once the backend has written objects for an executable, a shared library
// or an object file, the run ends through `ecoBootFinalExit`. Temporary MLIR
// and object files are removed on success and on most failures.
//
// `--emit=mlir` stops after the frontend only for `.elm` input. For `.mlir`
// input it runs the whole pipeline and writes to the output path, which
// defaults to `-`.
int main(int argc, char **argv) {
#if defined(__GLIBC__)
    // glibc malloc settings, for this process only, to reduce contention on
    // the kernel's memory-map lock while many threads allocate: the heap top
    // grows 64 MiB at a time, blocks up to 32 MiB come from the arenas rather
    // than from separate mappings, and free memory at the top is returned to
    // the system only above 1 GiB.
    mallopt(M_TOP_PAD, 64 << 20);
    mallopt(M_MMAP_THRESHOLD, 32 << 20);
    mallopt(M_TRIM_THRESHOLD, 1 << 30);
#endif
    llvm::InitLLVM initLLVM(argc, argv);

    // Initialize LLVM native target for object emission.
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();
    llvm::InitializeNativeTargetAsmParser();

    registerAsmPrinterCLOptions();
    registerMLIRContextCLOptions();
    registerPassManagerCLOptions();

    cl::ParseCommandLineOptions(argc, argv,
        "Eco native compiler\n\n"
        "Compiles Elm source files or MLIR to native x86-64 Linux executables.\n");

    std::string output = getOutputPath();

    eco::LoweringStats stats;

    // An object file input is only linked.
    if (isObjectFile(inputFilename)) {
        if (emitAction != EmitExe) {
            llvm::errs()
                << "Error: when input is an object file, --emit must be 'exe' "
                << "(default); the MLIR/LLVM pipeline does not run for .o "
                << "input.\n";
            return 1;
        }
        int rc;
        {
            eco::LoweringStats::Scope scope(stats, "Link (clang++ driver)");
            rc = linkExecutable(inputFilename, output);
        }
        if (printStats) {
            stats.print(llvm::errs());
        }
        return rc;
    }

    // Get MLIR input (either directly or via frontend compilation)
    std::string mlirFile;
    std::string tempMlirFile;
    // Removes the front end's temporary MLIR on every return, error returns included. Removing a file
    // that is already gone is harmless, so the explicit removals below stay.
    auto removeTempMlir = llvm::make_scope_exit([&] {
        if (!tempMlirFile.empty())
            llvm::sys::fs::remove(tempMlirFile);
    });

    if (isMlirFile(inputFilename)) {
        // `--emit=mlir` asks for the front end's output, which an MLIR input already is. Without this,
        // the input would fall through to the executable path and be linked into a file named `-`.
        if (emitAction == EmitMLIR) {
            llvm::errs() << "Error: --emit=mlir needs an .elm input; " << inputFilename
                         << " is already MLIR (ecoc --emit=mlir prints it as text)\n";
            return 1;
        }
        mlirFile = inputFilename;
    } else if (isElmFile(inputFilename)) {
        if (emitAction == EmitMLIR) {
            std::string mlirOutput = (output == "-") ? "/dev/stdout" : output;
            int rc;
            {
                eco::LoweringStats::Scope scope(stats, "frontend (Elm -> MLIR)");
                rc = compileElmToMlir(inputFilename, mlirOutput);
            }
            if (printStats) {
                stats.print(llvm::errs());
            }
            return rc;
        }

        llvm::SmallString<256> tempPath;
        if (auto ec = llvm::sys::fs::createTemporaryFile(
                "eco-boot", "mlir", tempPath)) {
            llvm::errs() << "Error: Could not create temp file: "
                         << ec.message() << "\n";
            return 1;
        }
        tempMlirFile = std::string(tempPath);
        mlirFile = tempMlirFile;

        {
            eco::LoweringStats::Scope scope(stats, "frontend (Elm -> MLIR)");
            if (compileElmToMlir(inputFilename, mlirFile) != 0) {
                llvm::sys::fs::remove(tempMlirFile);
                return 1;
            }
        }
    } else {
        llvm::errs()
            << "Error: Input file must be .elm, .mlir, or .o (re-link only)\n";
        return 1;
    }

    // The MLIRContext, the input buffer (owned by `sourceMgr`) and the module
    // live in the nested block opened here, which ends right after
    // translation, so that they are freed before the LLVM backend runs.
    // `llvmContext` and `llvmModule` are declared outside it to outlive it;
    // `llvmContext` comes first so that the module is destroyed before its
    // context.
    llvm::LLVMContext llvmContext;
    llvm::StringMap<bool> reachTaken;
    std::unique_ptr<llvm::Module> llvmModule;
    {
    DialectRegistry registry;
    eco::registerRequiredDialects(registry);

    MLIRContext context(registry);
#if defined(_WIN32)
    // Windows lowers MLIR on one thread, so the context's thread pool is
    // torn down. As a consequence `eco::mlirSplitPartitionCount` returns 1
    // and the module is never split in MLIR there.
    context.disableMultithreading();
#endif
    eco::loadRequiredDialects(context);
    context.allowUnregisteredDialects();

    std::string errorMessage;
    auto inputFile = openInputFile(mlirFile, &errorMessage);
    if (!inputFile) {
        llvm::errs() << "Error: " << errorMessage << "\n";
        if (!tempMlirFile.empty())
            llvm::sys::fs::remove(tempMlirFile);
        return 1;
    }

    llvm::SourceMgr sourceMgr;
    sourceMgr.AddNewSourceBuffer(std::move(inputFile), llvm::SMLoc());

    OwningOpRef<ModuleOp> module;
    {
        eco::LoweringStats::Scope scope(stats, "MLIR parse + verify");
        module = loadMLIR(context, sourceMgr);
        if (!module) {
            if (!tempMlirFile.empty())
                llvm::sys::fs::remove(tempMlirFile);
            return 1;
        }

#ifdef ECO_LOWERING_VALIDATION
        // parseSourceFile has already verified the module; validation builds
        // check again.
        if (failed(verify(*module))) {
            llvm::errs() << "Error: Module verification failed\n";
            if (!tempMlirFile.empty())
                llvm::sys::fs::remove(tempMlirFile);
            return 1;
        }
#endif
    }

    {
        eco::LoweringStats::Scope scope(stats, "MLIR lowering pipeline");
        if (runPipeline(*module, stats, capPipelineOptions(output)) != 0) {
            if (!tempMlirFile.empty())
                llvm::sys::fs::remove(tempMlirFile);
            return 1;
        }
    }
    // ECO_DUMP_LOWERED_MLIR=<file> writes the module as the MLIR pipeline
    // left it, before any split, so that two pipelines' output can be compared.
    if (const char *dump = ::getenv("ECO_DUMP_LOWERED_MLIR"); dump && *dump) {
        std::error_code ec;
        llvm::raw_fd_ostream out(dump, ec, llvm::sys::fs::OF_None);
        if (ec) {
            llvm::errs() << "Error: cannot write " << dump << ": "
                         << ec.message() << "\n";
            return 1;
        }
        module->print(out);
    }

    // When `eco::mlirSplitPartitionCount` gives more than one partition, the
    // module is split in MLIR and each partition is translated and lowered on
    // its own thread, and the run ends in this branch. The module's contents
    // must not be used after `lowerMlirSplit`.
    if (emitAction == EmitExe || emitAction == EmitObj) {
        const bool objOnly = capOutputObjOnly(output);
        const bool isExe = !objOnly && !outputIsSharedLib(output);
        eco::EcoBackendJob job;
        job.kind = eco::BackendKind::EmitObjectFile;
        job.optLevel = optLevel > 0
            ? static_cast<llvm::CodeGenOptLevel>(std::min(optLevel.getValue(), 3u))
            : llvm::CodeGenOptLevel::None;
        job.needsFramePointerAttr = true;
        job.preRS4GCDumpPath = dumpPreRS4GCIR;
        job.postRS4GCDumpPath = dumpRS4GCIR;
        job.rs4gcAfterOpt = rs4gcAfterOpt;
        job.splitCodegen = splitCodegen;
        job.splitEligible = isExe || (objOnly && kCanRelinkObjects);
        job.capClosedWorld = capClosedWorld(output);
        job.parallelOpt = parallelOpt;
        job.stats = &stats;
        job.devEmitCodeGenLevel = devEmitCG;
        job.devOptO1 = devOptO1;
        const unsigned parts = eco::mlirSplitPartitionCount(*module, job);
        if (parts > 1) {
            std::string objFile;
            std::string tempObjFile;
            if (objOnly) {
                objFile = output;
                job.objectFilePath = objFile + ".part0.o";
            } else {
                llvm::SmallString<256> tempPath;
                if (auto ec = llvm::sys::fs::createTemporaryFile(
                        "eco-boot", "o", tempPath)) {
                    llvm::errs() << "Error: Could not create temp file: "
                                 << ec.message() << "\n";
                    return 1;
                }
                tempObjFile = std::string(tempPath);
                objFile = tempObjFile;
                job.objectFilePath = objFile;
            }
            eco::EcoBackendResult backendResult;
            {
                eco::LoweringStats::Scope scope(
                    stats, "LLVM backend (EcoSplit: translate + lower per "
                           "partition)");
                if (auto err = eco::lowerMlirSplit(*module, job, parts,
                                                   &backendResult)) {
                    llvm::errs() << "Error: backend pipeline failed: "
                                 << llvm::toString(std::move(err)) << "\n";
                    if (!tempObjFile.empty())
                        llvm::sys::fs::remove(tempObjFile);
                    if (!tempMlirFile.empty())
                        llvm::sys::fs::remove(tempMlirFile);
                    return 1;
                }
            }
            if (!tempMlirFile.empty())
                llvm::sys::fs::remove(tempMlirFile);
            int rc = 0;
            if (objOnly) {
                eco::LoweringStats::Scope scope(stats,
                                                "Relocatable link (ld -r)");
                std::string linker = eco::config::systemLinker;
                llvm::SmallVector<llvm::StringRef> args = {linker, "-r", "-o",
                                                           objFile};
                for (const std::string &f : backendResult.objectFiles)
                    args.push_back(f);
                std::string errMsg;
                rc = llvm::sys::ExecuteAndWait(linker, args, std::nullopt, {},
                                               0, 0, &errMsg);
                if (rc != 0)
                    llvm::errs() << "Error: relocatable link failed (rc=" << rc
                                 << "): " << errMsg << "\n";
                for (const std::string &f : backendResult.objectFiles)
                    llvm::sys::fs::remove(f);
            } else {
                eco::LoweringStats::Scope scope(stats, "Link (clang++ driver)");
                rc = linkExecutable(backendResult.objectFiles, output);
                if (!tempObjFile.empty())
                    llvm::sys::fs::remove(tempObjFile);
            }
            for (auto &f : backendResult.ownedTempFiles)
                llvm::sys::fs::remove(f);
            if (printStats)
                stats.print(llvm::errs());
            eco::printOptPassTimes(llvm::errs());
            ecoBootFinalExit(rc);
            return rc;
        }
    }

    {
        eco::LoweringStats::Scope scope(stats, "MLIR -> LLVM IR translation");
        // Recorded for `eco::checkAddressTaken`, which compares it with
        // LLVM's answer after reachability is finished below.
        if (const char *e = ::getenv("ECO_REACH_VALIDATE"); e && *e && *e != '0')
            reachTaken = eco::symgraph::addressTakenByName(*module);
        llvmModule = translateToLLVMIR(*module, llvmContext);
        if (!llvmModule) {
            if (!tempMlirFile.empty())
                llvm::sys::fs::remove(tempMlirFile);
            return 1;
        }
    }
    } // The MLIR state is destroyed here.

    // Creating the target machine also sets the module's data layout, which
    // must be in place before RS4GC runs.
    std::unique_ptr<llvm::TargetMachine> tm;
    {
        eco::LoweringStats::Scope scope(stats, "TargetMachine init");
        tm = eco::createEcoTargetMachine(*llvmModule, optLevel.getValue());
        if (!tm)
            return 1;
    }

    if (!tempMlirFile.empty())
        llvm::sys::fs::remove(tempMlirFile);

    // LLVM IR output: RS4GC, then, at -O above 0, the standard optimization
    // pipeline, then the module printed as text.
    if (emitAction == EmitLLVM) {
        {
            eco::LoweringStats::Scope scope(stats, "LLVM RS4GC pipeline");
            eco::EcoBackendJob job;
            job.kind = eco::BackendKind::DumpLLVMText;
            job.tm = tm.get();
            job.needsFramePointerAttr = true;
            job.preRS4GCDumpPath = dumpPreRS4GCIR;
            job.postRS4GCDumpPath = dumpRS4GCIR;
            if (auto err = eco::runEcoBackend(*llvmModule, job)) {
                llvm::errs() << "Error: RS4GC failed: " << llvm::toString(std::move(err)) << "\n";
                return 1;
            }
        }
        if (optLevel > 0) {
            eco::LoweringStats::Scope scope(stats, "LLVM optimization (-O>0)");
            // Clamped to 3 as on the executable path; makeOptimizingTransformer rejects a higher level.
            auto optPipeline = makeOptimizingTransformer(
                std::min(optLevel.getValue(), 3u), /*sizeLevel=*/0, /*targetMachine=*/tm.get());
            if (auto err = optPipeline(llvmModule.get())) {
                llvm::errs() << "Error: LLVM optimization failed: " << llvm::toString(std::move(err)) << "\n";
                return 1;
            }
        }
        {
            eco::LoweringStats::Scope scope(stats, "Emit LLVM IR");
            if (output == "-") {
                llvm::outs() << *llvmModule << "\n";
            } else {
                std::error_code ec;
                llvm::raw_fd_ostream out(output, ec, llvm::sys::fs::OF_None);
                if (ec) {
                    llvm::errs() << "Error: Could not open output file: "
                                 << ec.message() << "\n";
                    return 1;
                }
                out << *llvmModule << "\n";
            }
        }
        if (printStats) {
            stats.print(llvm::errs());
        }
        return 0;
    }

    // Object, executable and shared-library output: `runEcoBackend` writes
    // the objects, and the executable or library is then linked.
    std::string objFile;
    std::string tempObjFile;
    // Removed on every return, as the temporary MLIR is.
    auto removeTempObj = llvm::make_scope_exit([&] {
        if (!tempObjFile.empty())
            llvm::sys::fs::remove(tempObjFile);
    });
    // `-o foo.o` with the default --emit=exe is object-only output too.
    bool emitObjOnly =
        (emitAction == EmitObj) ||
        (output.size() >= 2 &&
         output.compare(output.size() - 2, 2, ".o") == 0);
    if (emitObjOnly) {
        objFile = output;
    } else {
        llvm::SmallString<256> tempPath;
        if (auto ec = llvm::sys::fs::createTemporaryFile(
                "eco-boot", "o", tempPath)) {
            llvm::errs() << "Error: Could not create temp file: "
                         << ec.message() << "\n";
            return 1;
        }
        tempObjFile = std::string(tempPath);
        objFile = tempObjFile;
    }

    const bool isExecutable = !emitObjOnly && !outputIsSharedLib(output);

    // Closed-world output keeps only its roots visible and drops what they
    // cannot reach, before the backend runs: through `finishReachability` if
    // MLIR reachability already did the work, and otherwise by internalizing
    // here. Shared libraries and other object output keep every symbol.
    if ((isExecutable || (emitObjOnly && !internalizeKeep.empty())) &&
        eco::hasReachabilityStamp(*llvmModule)) {
        eco::LoweringStats::Scope scope(stats, "Reachability finish (serial)");
        std::vector<std::string> keep = {"eco_main", "__eco_init_globals"};
        if (!isExecutable) {
            keep.clear();
            llvm::SmallVector<llvm::StringRef> parts;
            llvm::StringRef(internalizeKeep).split(parts, ',', -1, false);
            for (llvm::StringRef k : parts)
                keep.push_back(k.trim().str());
        }
        if (auto err = eco::finishReachability(*llvmModule, keep)) {
            llvm::errs() << "Error: " << llvm::toString(std::move(err)) << "\n";
            return 1;
        }
        if (!reachTaken.empty())
            if (auto err = eco::checkAddressTaken(*llvmModule, reachTaken)) {
                llvm::errs() << "Error: " << llvm::toString(std::move(err))
                             << "\n";
                return 1;
            }
    } else if (isExecutable) {
        eco::LoweringStats::Scope scope(stats, "Internalize + GlobalDCE");
        eco::internalizeAndDCEForExecutable(*llvmModule);
    } else if (emitObjOnly && !internalizeKeep.empty()) {
        // `--internalize-keep` promises that nothing else is referenced.
        eco::LoweringStats::Scope scope(stats, "Internalize + GlobalDCE");
        llvm::SmallVector<llvm::StringRef> parts;
        llvm::StringRef(internalizeKeep).split(parts, ',', -1, false);
        std::vector<std::string> keep;
        for (llvm::StringRef k : parts)
            keep.push_back(k.trim().str());
        eco::internalizeAndDCE(*llvmModule, keep);
    }

    // Object output is written under a separate name, then renamed, or, when
    // split, joined by a relocatable link below.
    std::string objPartsBase;
    if (emitObjOnly) {
        objPartsBase = objFile + ".part0.o";
    }

    // `runEcoBackend` decides whether to split and into how many partitions,
    // and lists the objects it wrote in `backendResult`.
    eco::EcoBackendResult backendResult;
    {
        eco::LoweringStats::Scope scope(stats,
            "LLVM backend (RS4GC + opt + object emission)");
        eco::EcoBackendJob job;
        job.kind = eco::BackendKind::EmitObjectFile;
        job.tm = tm.get();
        job.optLevel = optLevel > 0
            ? static_cast<llvm::CodeGenOptLevel>(std::min(optLevel.getValue(), 3u))
            : llvm::CodeGenOptLevel::None;
        job.needsFramePointerAttr = true;
        job.preRS4GCDumpPath = dumpPreRS4GCIR;
        job.postRS4GCDumpPath = dumpRS4GCIR;
        job.rs4gcAfterOpt = rs4gcAfterOpt;
        job.splitCodegen = splitCodegen;
        job.splitEligible = isExecutable || (emitObjOnly && kCanRelinkObjects);
        job.capClosedWorld = capClosedWorld(output);
        job.parallelOpt = parallelOpt;
        job.stats = &stats;
        job.devEmitCodeGenLevel = devEmitCG;
        job.devOptO1 = devOptO1;
        job.objectFilePath = emitObjOnly ? objPartsBase : objFile;
        if (auto err = eco::runEcoBackend(*llvmModule, job, &backendResult)) {
            llvm::errs() << "Error: backend pipeline failed: " << llvm::toString(std::move(err)) << "\n";
            if (!tempObjFile.empty())
                llvm::sys::fs::remove(tempObjFile);
            for (auto &f : backendResult.ownedTempFiles)
                llvm::sys::fs::remove(f);
            return 1;
        }
    }

    if (verbose)
        llvm::errs() << "[eco-boot] emitted object file(s): "
                     << (backendResult.objectFiles.size() > 1
                             ? std::to_string(backendResult.objectFiles.size()) +
                                   " partitions"
                             : objFile)
                     << "\n";

    if (emitObjOnly) {
        int rc = 0;
        if (backendResult.objectFiles.size() == 1) {
            if (auto ec = llvm::sys::fs::rename(backendResult.objectFiles[0],
                                                objFile)) {
                llvm::errs() << "Error: could not move object to '" << objFile
                             << "': " << ec.message() << "\n";
                rc = 1;
            }
        } else {
            eco::LoweringStats::Scope scope(stats, "Relocatable link (ld -r)");
            std::string linker = eco::config::systemLinker;
            llvm::SmallVector<llvm::StringRef> args = {linker, "-r", "-o",
                                                       objFile};
            for (const std::string &f : backendResult.objectFiles)
                args.push_back(f);
            std::string errMsg;
            rc = llvm::sys::ExecuteAndWait(linker, args, std::nullopt, {}, 0,
                                           0, &errMsg);
            if (rc != 0)
                llvm::errs() << "Error: relocatable link failed (rc=" << rc
                             << "): " << errMsg << "\n";
            for (const std::string &f : backendResult.objectFiles)
                llvm::sys::fs::remove(f);
        }
        for (auto &f : backendResult.ownedTempFiles)
            llvm::sys::fs::remove(f);
        if (printStats) {
            stats.print(llvm::errs());
        }
        ecoBootFinalExit(rc);
        return rc;
    }

    int rc;
    {
        eco::LoweringStats::Scope scope(stats, "Link (clang++ driver)");
        rc = linkExecutable(backendResult.objectFiles, output);
    }

    if (!tempObjFile.empty())
        llvm::sys::fs::remove(tempObjFile);
    for (auto &f : backendResult.ownedTempFiles)
        llvm::sys::fs::remove(f);

    if (printStats) {
        stats.print(llvm::errs());
    }
    eco::printOptPassTimes(llvm::errs());

    ecoBootFinalExit(rc);
    return rc;
}
