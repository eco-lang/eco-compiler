//===- EcoNativeDriver.cpp - MLIR-to-native library implementation -------===//
//
// `pipelineFromMlirModule` takes one of two routes once the Eco pipeline has
// run. When the output may be split and `mlirSplitPartitionCount` asks for
// more than one partition, the MLIR module is handed to `lowerMlirSplit`,
// which partitions, translates and lowers it on worker threads. Otherwise the
// whole module is translated to LLVM IR here, the MLIR operations are freed,
// and `runEcoBackend` lowers the LLVM module, splitting it itself if its own
// policy says so. Unless the output is a `.o` file, the result is then
// passed to `linkExecutable`.
//
// Most of this file is `linkExecutable`: a link line built argument by
// argument for each platform and, on Linux, for each link profile.
//
//===----------------------------------------------------------------------===//

#include "EcoNativeDriver.h"
#include <cstdlib>
#include <cstring>
#include <optional>
#include "EcoNativeAPI.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Extensions/AllExtensions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

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

#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/FileUtilities.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/TargetParser/SubtargetFeature.h"

#include "EcoBackend.h"
#include "EcoDialect.h"
#include "EcoPipeline.h"
#include "EcoSplit.h"
#include "LoweringStats.h"
#include "Passes.h"
#include "Passes/EcoSymbolGraph.h"

#include "eco/EcoBootConfig.h"

#include <deque>
#include <string_view>

namespace eco {
void linkEcoGCStrategy();
} // namespace eco

namespace {

/**
 * A static object whose constructor calls `linkEcoGCStrategy`, so that a
 * binary linking this library also links the translation unit that defines
 * the Eco GC strategy.
 */
struct EcoGCStrategyLibLinker {
    EcoGCStrategyLibLinker() { eco::linkEcoGCStrategy(); }
} ecoGCStrategyLibLinker;

using namespace mlir;

// Parses the buffer in `sourceMgr` as an MLIR module in `context`, or prints
// an error and returns null.
OwningOpRef<ModuleOp> loadMLIRFromSourceMgr(MLIRContext &context,
                                             llvm::SourceMgr &sourceMgr) {
    auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
    if (!module)
        llvm::errs() << "Error: Failed to parse MLIR\n";
    return module;
}

// Runs the Eco-to-LLVM-dialect pass pipeline on `module` in place, and
// returns 0 on success or 1 on failure. `capClosedWorld` makes the pipeline
// treat the module as a closed world rooted at `main` and
// `__eco_init_globals`, and asks for MLIR reachability.
int runPipeline(ModuleOp module, eco::LoweringStats *stats,
                bool capClosedWorld) {
    PassManager pm(module->getName());

    // applyPassManagerCLOptions is not called: the pass-manager command-line
    // options are not registered in every program that links this library.

#ifndef ECO_LOWERING_VALIDATION
    // Release: skip the after-each-pass full-module verifier (O(module) per
    // pass; the parser already verified the input). Validation builds keep it.
    pm.enableVerifier(false);
#endif

    if (stats)
        pm.addInstrumentation(stats->makePassInstrumentation());

    // Capacity hoisting and reachability are rooted at
    // the two symbols the standalone entry point calls. capClosedWorld must
    // equal EcoBackendJob::capClosedWorld in pipelineFromMlirModule.
    eco::EcoPipelineOptions pipeOpts;
    pipeOpts.capClosedWorld = capClosedWorld;
    if (capClosedWorld)
        pipeOpts.capRoots = {"main", "__eco_init_globals"};
    pipeOpts.reachability = capClosedWorld;
    eco::buildEcoToLLVMPipeline(pm, pipeOpts);

    if (failed(pm.run(module)))
        return 1;

    return 0;
}

// Translates `module` to an LLVM module in `llvmContext` and renames its
// `main` to `eco_main`, or prints an error and returns null.
std::unique_ptr<llvm::Module>
translateToLLVMIR(ModuleOp module, llvm::LLVMContext &llvmContext) {
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    // Release: skip the whole-module LLVM verifier on the translation output
    // (its cost grows with the module; the MLIR pipeline already validated
    // the input). Validation builds keep it.
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

    // Rename the module's `main` to `eco_main`, for every output kind, so it
    // does not collide with a C `main()` linked in beside it.
    if (auto *mainFn = llvmModule->getFunction("main"))
        mainFn->setName("eco_main");

    return llvmModule;
}

// Returns whether `path` ends with `suffix`, compared case-sensitively. The
// output kind is chosen with it: `.o`, `.so` and `.node`.
bool pathEndsWith(const std::string &path, const char *suffix) {
    size_t n = std::strlen(suffix);
    return path.size() >= n &&
           path.compare(path.size() - n, n, suffix) == 0;
}

// Lowers the parsed `module` and links it at `outputPath`, as
// `compileMlirFileToExecutable` describes, and returns 0 or 1. Takes
// ownership of `module` and frees it before returning; its MLIRContext must
// outlive the call.
int pipelineFromMlirModule(OwningOpRef<ModuleOp> module,
                           const std::string &outputPath,
                           const eco::EcoNativeOptions &opts) {
#ifdef ECO_LOWERING_VALIDATION
    // Redundant in release: the module was already verified when parsed
    // (compileMlirFileToExecutable / compileMlirBytesToExecutable). Kept in
    // validation builds only.
    if (failed(verify(*module))) {
        llvm::errs() << "Error: Module verification failed\n";
        return 1;
    }
#endif

    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "MLIR lowering pipeline");
        const bool capClosedWorld = !pathEndsWith(outputPath, ".o") &&
                                    !pathEndsWith(outputPath, ".so") &&
                                    !pathEndsWith(outputPath, ".node");
        if (runPipeline(*module, opts.stats, capClosedWorld) != 0)
            return 1;
    }

    // EcoSplit: partition in MLIR and translate and lower every
    // partition in parallel. Only executables are split-eligible.
    {
        const bool objOnly = pathEndsWith(outputPath, ".o");
        const bool shared = pathEndsWith(outputPath, ".so") ||
                            pathEndsWith(outputPath, ".node");
        eco::EcoBackendJob job;
        job.kind = eco::BackendKind::EmitObjectFile;
        job.optLevel = opts.optLevel > 0
                           ? static_cast<llvm::CodeGenOptLevel>(
                                 std::min(opts.optLevel, 3u))
                           : llvm::CodeGenOptLevel::None;
        job.needsFramePointerAttr = true;
        job.preRS4GCDumpPath = opts.preRS4GCDumpPath;
        job.postRS4GCDumpPath = opts.postRS4GCDumpPath;
        job.splitCodegen = opts.splitCodegen;
        job.splitEligible = !objOnly && !shared;
        job.capClosedWorld = !objOnly && !shared;
        job.parallelOpt = opts.parallelOpt == 1   ? eco::ParallelOpt::Dev
                          : opts.parallelOpt == 2 ? eco::ParallelOpt::Cgu
                                                  : eco::ParallelOpt::None;
        job.stats = opts.stats;
        job.devEmitCodeGenLevel = opts.devEmitCodeGenLevel;
        job.devOptO1 = opts.devOptO1;
        const unsigned parts =
            job.splitEligible ? eco::mlirSplitPartitionCount(*module, job) : 1;
        if (parts > 1) {
            llvm::SmallString<256> tempObjPath;
            if (auto ec = llvm::sys::fs::createTemporaryFile(
                    "eco-driver", "o", tempObjPath)) {
                llvm::errs() << "Error: Could not create temp object file: "
                             << ec.message() << "\n";
                return 1;
            }
            job.objectFilePath = std::string(tempObjPath);
            eco::EcoBackendResult backendResult;
            {
                std::unique_ptr<eco::LoweringStats::Scope> scope;
                if (opts.stats)
                    scope = std::make_unique<eco::LoweringStats::Scope>(
                        *opts.stats,
                        "LLVM backend (EcoSplit: translate + lower per "
                        "partition)");
                if (auto err = eco::lowerMlirSplit(*module, job, parts,
                                                   &backendResult)) {
                    llvm::errs() << "Error: backend pipeline failed: "
                                 << llvm::toString(std::move(err)) << "\n";
                    llvm::sys::fs::remove(job.objectFilePath);
                    return 1;
                }
            }
            module = nullptr;
            int rc;
            {
                std::unique_ptr<eco::LoweringStats::Scope> scope;
                if (opts.stats)
                    scope = std::make_unique<eco::LoweringStats::Scope>(
                        *opts.stats, "Link (system ld)");
                rc = eco::linkExecutable(backendResult.objectFiles, outputPath,
                                         opts, shared);
            }
            llvm::sys::fs::remove(job.objectFilePath);
            for (auto &f : backendResult.ownedTempFiles)
                llvm::sys::fs::remove(f);
            return rc;
        }
    }

    llvm::LLVMContext llvmContext;
    std::unique_ptr<llvm::Module> llvmModule;
    // Under ECO_REACH_VALIDATE, the MLIR address-taken set, checked against
    // the LLVM module once reachability is finished.
    llvm::StringMap<bool> reachTaken;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "MLIR -> LLVM IR translation");
        if (const char *e = ::getenv("ECO_REACH_VALIDATE"); e && *e && *e != '0')
            reachTaken = eco::symgraph::addressTakenByName(*module);
        llvmModule = translateToLLVMIR(*module, llvmContext);
        if (!llvmModule)
            return 1;
    }

    // Nothing below reads MLIR, so the module's operations, most of the MLIR
    // memory, are freed before the backend runs. The MLIRContext and the
    // source buffer belong to the caller and stay alive until it returns.
    module = nullptr;

    const bool emitObjOnly = pathEndsWith(outputPath, ".o");
    const bool sharedLib = pathEndsWith(outputPath, ".so") ||
                           pathEndsWith(outputPath, ".node");

    // Bake the root module name into the program as `__eco_root_module`.
    // The N-API addon declares it as a weak extern and uses it to name the
    // `Elm.<RootModule>` export; without it the addon falls back to "Main".
    // Shared libraries only: an executable never reads it, and MLIR
    // reachability cannot see a global created here.
    if (!opts.rootModule.empty() && sharedLib) {
        auto *init = llvm::ConstantDataArray::getString(
            llvmContext, opts.rootModule, /*AddNull=*/true);
        auto *strGV = new llvm::GlobalVariable(
            *llvmModule, init->getType(), /*isConstant=*/true,
            llvm::GlobalValue::PrivateLinkage, init, "__eco_root_module_str");
        new llvm::GlobalVariable(
            *llvmModule, llvm::PointerType::get(llvmContext, 0),
            /*isConstant=*/true, llvm::GlobalValue::ExternalLinkage, strGV,
            "__eco_root_module");
    }

    std::unique_ptr<llvm::TargetMachine> tm;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "TargetMachine init");
        tm = eco::createEcoTargetMachine(*llvmModule, opts.optLevel);
        if (!tm)
            return 1;
    }

    // Executable output only: drop what main and the global initializer cannot
    // reach. When MLIR reachability already did it,
    // finishReachability only clears what translation left behind; otherwise
    // internalizeAndDCEForExecutable does it on the LLVM module. Object files
    // and shared libraries keep every symbol, as other code links against
    // them.
    if (!emitObjOnly && !sharedLib && eco::hasReachabilityStamp(*llvmModule)) {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "Reachability finish (serial)");
        if (auto err = eco::finishReachability(
                *llvmModule, {"eco_main", "__eco_init_globals"})) {
            llvm::errs() << "Error: " << llvm::toString(std::move(err)) << "\n";
            return 1;
        }
        if (!reachTaken.empty())
            if (auto err = eco::checkAddressTaken(*llvmModule, reachTaken)) {
                llvm::errs() << "Error: " << llvm::toString(std::move(err))
                             << "\n";
                return 1;
            }
    } else if (!emitObjOnly && !sharedLib) {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "Internalize + GlobalDCE");
        eco::internalizeAndDCEForExecutable(*llvmModule);
    }

    // Emit to a temp object file, then link — except for object-only
    // output, where the backend writes the object straight to the target.
    std::string objFile;
    if (emitObjOnly) {
        objFile = outputPath;
    } else {
        llvm::SmallString<256> tempObjPath;
        if (auto ec = llvm::sys::fs::createTemporaryFile("eco-driver", "o",
                                                         tempObjPath)) {
            llvm::errs() << "Error: Could not create temp object file: "
                         << ec.message() << "\n";
            return 1;
        }
        objFile = std::string(tempObjPath);
    }

    // The backend decides the partition count; the job only says whether the
    // output is eligible and what was requested.
    eco::EcoBackendResult backendResult;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats,
                "LLVM backend (RS4GC + opt + object emission)");
        llvm::errs() << "[eco-native::pipeline] runEcoBackend begin\n";
        eco::EcoBackendJob job;
        job.kind = eco::BackendKind::EmitObjectFile;
        job.tm = tm.get();
        job.optLevel = opts.optLevel > 0
                           ? static_cast<llvm::CodeGenOptLevel>(
                                 std::min(opts.optLevel, 3u))
                           : llvm::CodeGenOptLevel::None;
        job.needsFramePointerAttr = true;
        job.preRS4GCDumpPath = opts.preRS4GCDumpPath;
        job.postRS4GCDumpPath = opts.postRS4GCDumpPath;
        job.objectFilePath = objFile;
        job.splitCodegen = opts.splitCodegen;
        job.splitEligible = !emitObjOnly && !sharedLib;
        job.capClosedWorld = !emitObjOnly && !sharedLib;
        job.parallelOpt = opts.parallelOpt == 1   ? eco::ParallelOpt::Dev
                          : opts.parallelOpt == 2 ? eco::ParallelOpt::Cgu
                                                  : eco::ParallelOpt::None;
        job.stats = opts.stats;
        job.devEmitCodeGenLevel = opts.devEmitCodeGenLevel;
        job.devOptO1 = opts.devOptO1;
        if (auto err = eco::runEcoBackend(*llvmModule, job, &backendResult)) {
            llvm::errs() << "Error: backend pipeline failed: " << llvm::toString(std::move(err)) << "\n";
            llvm::sys::fs::remove(objFile);
            return 1;
        }
    }

    if (emitObjOnly)
        return 0;

    int rc;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "Link (system ld)");
        rc = eco::linkExecutable(backendResult.objectFiles, outputPath, opts,
                                 sharedLib);
    }

    llvm::sys::fs::remove(objFile);
    for (auto &f : backendResult.ownedTempFiles)
        llvm::sys::fs::remove(f);
    return rc;
}

} // namespace

namespace eco {

void initializeLLVMNativeTarget() {
    static bool inited = false;
    if (inited)
        return;
    inited = true;
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();
    llvm::InitializeNativeTargetAsmParser();
}

int compileMlirFileToExecutable(const std::string &mlirPath,
                                const std::string &outputPath,
                                const EcoNativeOptions &opts) {
    initializeLLVMNativeTarget();

    DialectRegistry registry;
    eco::registerRequiredDialects(registry);

    MLIRContext context(registry);
#if defined(_WIN32)
    // Win64: avoid MLIRContext's default worker thread pool — its parked
    // threads deadlock /MT CRT teardown at process exit.
    context.disableMultithreading();
#endif
    eco::loadRequiredDialects(context);
    context.allowUnregisteredDialects();

    std::string errorMessage;
    auto inputFile = openInputFile(mlirPath, &errorMessage);
    if (!inputFile) {
        llvm::errs() << "Error: " << errorMessage << "\n";
        return 1;
    }

    llvm::SourceMgr sourceMgr;
    sourceMgr.AddNewSourceBuffer(std::move(inputFile), llvm::SMLoc());

    OwningOpRef<ModuleOp> module;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "MLIR parse + verify");
        module = loadMLIRFromSourceMgr(context, sourceMgr);
        if (!module)
            return 1;
    }

    return pipelineFromMlirModule(std::move(module), outputPath, opts);
}

int compileMlirBytesToExecutable(const char *mlirBytes, size_t mlirLen,
                                  const std::string &outputPath,
                                  const EcoNativeOptions &opts) {
    initializeLLVMNativeTarget();

    DialectRegistry registry;
    eco::registerRequiredDialects(registry);

    MLIRContext context(registry);
#if defined(_WIN32)
    // Win64: avoid MLIRContext's default worker thread pool — its parked
    // threads deadlock /MT CRT teardown at process exit.
    context.disableMultithreading();
#endif
    eco::loadRequiredDialects(context);
    context.allowUnregisteredDialects();

    auto buffer = llvm::MemoryBuffer::getMemBuffer(
        llvm::StringRef(mlirBytes, mlirLen), "<in-memory MLIR>",
        /*RequiresNullTerminator=*/false);

    llvm::SourceMgr sourceMgr;
    sourceMgr.AddNewSourceBuffer(std::move(buffer), llvm::SMLoc());

    OwningOpRef<ModuleOp> module;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "MLIR parse + verify");
        module = loadMLIRFromSourceMgr(context, sourceMgr);
        if (!module)
            return 1;
    }

    return pipelineFromMlirModule(std::move(module), outputPath, opts);
}

#if defined(__APPLE__)
// Runs `/usr/bin/xcrun` with `xcrunArgs` and returns its standard output with
// trailing whitespace trimmed, or "" if it fails. Its standard error is
// discarded. /usr/bin/xcrun ships with macOS itself; it fails when neither
// Xcode nor the Command Line Tools is installed.
static std::string runXcrun(llvm::ArrayRef<llvm::StringRef> xcrunArgs) {
    llvm::SmallString<128> outPath;
    if (llvm::sys::fs::createTemporaryFile("eco-xcrun", "txt", outPath))
        return "";
    llvm::FileRemover removeOut(outPath);

    llvm::SmallVector<llvm::StringRef> args{"/usr/bin/xcrun"};
    args.append(xcrunArgs.begin(), xcrunArgs.end());
    // Empty redirect = /dev/null: keep xcrun's own diagnostics off the
    // user's terminal; linkExecutableDarwin prints a clearer one.
    std::optional<llvm::StringRef> redirects[] = {llvm::StringRef(""),
                                                   llvm::StringRef(outPath),
                                                   llvm::StringRef("")};
    int rc = llvm::sys::ExecuteAndWait(args[0], args, /*env=*/std::nullopt,
                                       redirects);
    if (rc != 0)
        return "";
    auto buf = llvm::MemoryBuffer::getFile(outPath);
    if (!buf)
        return "";
    return (*buf)->getBuffer().rtrim().str();
}

/**
 * The Apple link driver and SDK path, found at link time rather than at
 * configure time, so that an installed bundle works with whatever Xcode or
 * Command Line Tools the machine has. An empty field means it was not found.
 */
struct DarwinToolchain {
    std::string clang;
    std::string sdkRoot;
};

// Returns the Darwin toolchain, looked up through xcrun on the first call
// and reused for the life of the process. A non-empty `$SDKROOT` overrides
// the SDK path, as it does for Apple's own tools.
static const DarwinToolchain &darwinToolchain() {
    static const DarwinToolchain tc = [] {
        DarwinToolchain t;
        t.clang = runXcrun({"--sdk", "macosx", "-f", "clang"});
        const char *sdkEnv = std::getenv("SDKROOT");
        if (sdkEnv && *sdkEnv)
            t.sdkRoot = sdkEnv;
        else
            t.sdkRoot = runXcrun({"--sdk", "macosx", "--show-sdk-path"});
        return t;
    }();
    return tc;
}

// Links `objectFiles` into a Mach-O executable at `outputPath` with clang as
// the link driver, and returns 0 or 1. A shared library is refused.
//
// clang is used because it knows the crt and SDK details. ld64 is much more
// integrated than ld.bfd/lld for Mach-O — Apple ships no crt objects (the
// dynamic loader does startup), and libSystem/libc++/libcurl/libz are
// SDK .tbd stubs that the SDK path locates. ld64 also ad-hoc-signs arm64
// outputs automatically, so no codesign step is needed.
//
// Stackmaps: ld64 keeps unreferenced sections by default and -dead_strip is
// never passed, so the __LLVM_STACKMAPS,__llvm_stackmaps section survives.
static int linkExecutableDarwin(const std::vector<std::string> &objectFiles,
                                const std::string &outputPath,
                                const EcoNativeOptions &opts,
                                bool sharedLib) {
    using eco::config::resolveFile;

    if (sharedLib) {
        llvm::errs()
            << "Error: Darwin shared-library output is not yet supported.\n";
        return 1;
    }

    std::deque<std::string> resolvedStrings;
    auto push = [&](std::string s) -> llvm::StringRef {
        resolvedStrings.emplace_back(std::move(s));
        return resolvedStrings.back();
    };

    const DarwinToolchain &tc = darwinToolchain();
    if (tc.clang.empty() || tc.sdkRoot.empty()) {
        llvm::errs()
            << "Error: building a macOS executable needs the Xcode Command "
               "Line Tools (the linker and the macOS SDK), and xcrun could "
               "not find them. Install them with:\n"
               "    xcode-select --install\n";
        return 1;
    }

    llvm::SmallVector<llvm::StringRef> args;
    args.push_back(tc.clang);

    // SDK + arch. -isysroot tells clang where to find libSystem/libc++/
    // libcurl/libz .tbd stubs; -arch is set explicitly so the link is
    // robust under Rosetta / cross-arch scenarios. The minimum macOS version
    // matches the one stamped into the objects (createEcoTargetMachine) and
    // into the runtime archives (CMAKE_OSX_DEPLOYMENT_TARGET).
    args.push_back("-isysroot");
    args.push_back(tc.sdkRoot);
    args.push_back("-arch");
    args.push_back(eco::config::darwinArch);
    args.push_back(push(std::string("-mmacosx-version-min=") +
                        eco::config::darwinMacosMin));

    args.push_back("-o");
    args.push_back(outputPath);
    for (const auto &o : objectFiles)
        args.push_back(o);

    // ld64 pulls an archive member only when an already-loaded object refers
    // to one of its defined symbols. main() in eco_entry.cpp has no such
    // referrer (the .o is the user's program), so -force_load is required.
    // Similarly EcoKernel_Utils carries the Order LT/EQ/GT singletons that
    // user code may reference indirectly through Basics.compare.
    auto forceLoad = [&](const eco::config::RuntimeFile &f) {
        args.push_back(
            push(std::string("-Wl,-force_load,") + resolveFile(f)));
    };

    forceLoad(eco::config::entryLib);
    args.push_back(push(resolveFile(eco::config::runtimeLib)));

    for (const auto &lib : eco::config::elmKernelLibs()) {
        bool isUtils =
            std::string_view(lib.basename) == "libElmKernel_Utils.a";
        if (isUtils) {
            forceLoad(lib);
        } else {
            args.push_back(push(resolveFile(lib)));
        }
    }
    for (const auto &lib : eco::config::ecoKernelLibs()) {
        args.push_back(push(resolveFile(lib)));
    }
    for (const auto &lib : eco::config::ecoSystemLibs()) {
        args.push_back(push(resolveFile(lib)));
    }

    // libzip + OpenSSL (libssl, libcrypto) — not in the macOS SDK. libzip
    // is vendored statically via FetchContent. OpenSSL is brew's openssl@3
    // keg statics: required because (a) the vendored libzip's configure pulls in
    // zip_crypto_openssl.c on a brew-equipped host even with
    // ENABLE_OPENSSL=OFF (auto-detect fallback), and (b) Http.cpp's
    // SHA1-hashing of downloaded zips uses <openssl/sha.h>.
    //
    // Order matters: libzip first (drags in EVP_* refs), then libssl,
    // then libcrypto (the EVP_* symbols live in libcrypto).
    args.push_back(push(resolveFile(eco::config::darwinLibzipA)));
    args.push_back(push(resolveFile(eco::config::darwinLibsslA)));
    args.push_back(push(resolveFile(eco::config::darwinLibcryptoA)));

    // System libs from the SDK. Clang's driver always links libSystem
    // (libc / pthread / libm / dlsym all live there); we just need to
    // ask explicitly for the higher-level pieces.
    args.push_back("-lc++");
    args.push_back("-lcurl");
    args.push_back("-lz");

    if (opts.verbose) {
        llvm::errs() << "[eco-native] link (Darwin, clang driver):";
        for (auto &a : args)
            llvm::errs() << " " << a;
        llvm::errs() << "\n";
    }

    std::string errMsg;
    int rc = llvm::sys::ExecuteAndWait(tc.clang, args,
                                       /*env=*/std::nullopt,
                                       /*redirects=*/{},
                                       /*secondsToWait=*/0,
                                       /*memoryLimit=*/0, &errMsg);
    if (rc != 0) {
        llvm::errs() << "Error: Darwin link (clang driver) failed (rc=" << rc
                     << ")";
        if (!errMsg.empty())
            llvm::errs() << ": " << errMsg;
        llvm::errs() << "\n";
        return 1;
    }
    if (opts.verbose)
        llvm::errs() << "[eco-native] linked Mach-O executable: " << outputPath
                     << "\n";
    return 0;
}
#endif // __APPLE__

#if defined(_WIN32)
// Links `objectFiles` into a PE executable at `outputPath` with clang-cl
// driving lld-link, and returns 0 or 1. A shared library is refused. The
// linker's output is captured in a temporary file and then copied to
// standard error.
//
// clang-cl is used so that it finds the VS Build Tools and the Windows SDK.
// The library set: the static MSVC CRT (/MT), the project libraries, the
// vendored libcurl (schannel TLS), libzip and zlib, and the Windows SDK
// import libraries. No OpenSSL.
static int linkExecutableWindows(const std::vector<std::string>& objectFiles,
                                 const std::string& outputPath,
                                 const eco::EcoNativeOptions& opts,
                                 bool sharedLib) {
    using eco::config::resolveFile;

    if (sharedLib) {
        llvm::errs()
            << "Error: Windows shared-library output is not yet supported.\n";
        return 1;
    }

    std::deque<std::string> resolvedStrings;
    auto push = [&](std::string s) -> llvm::StringRef {
        resolvedStrings.emplace_back(std::move(s));
        return resolvedStrings.back();
    };

    // ExecuteAndWait needs an absolute path, which findProgramByName gives.
    llvm::ErrorOr<std::string> clangCl = llvm::sys::findProgramByName("clang-cl");
    if (!clangCl) {
        llvm::errs()
            << "Error: clang-cl not found on PATH. The Windows AOT link "
               "shells out to it for VS Build Tools + Windows SDK discovery; "
               "install VS Build Tools 2022 or LLVM 20+ and ensure clang-cl "
               "is in PATH.\n";
        return 1;
    }
    llvm::SmallVector<llvm::StringRef> args;
    args.push_back(*clangCl);
    args.push_back("/nologo");
    args.push_back("/MT");              // Link the static MSVC CRT.
    args.push_back("/EHsc");
    args.push_back(push(std::string("/Fe:") + outputPath));
    for (const auto &o : objectFiles)
        args.push_back(o);

    // /link separates clang-cl driver args (above) from linker args
    // (below). Every arg after this point is forwarded to lld-link
    // verbatim — including /WHOLEARCHIVE: which is a linker flag only.
    args.push_back("/link");
    args.push_back("/SUBSYSTEM:CONSOLE");
    // /INCREMENTAL:NO is critical: with incremental linking, lld-link emits
    // a 5-byte e9-jmp thunk table at the start of .text for address-taken
    // functions, and the stackmap section's recorded fnAddresses then point
    // at the thunk slot instead of the real function entry. The whole
    // stackmap-driven GC root scan would mis-locate every frame.
    args.push_back("/INCREMENTAL:NO");

    // /WHOLEARCHIVE:<lib> is the MSVC-side equivalent of `-Wl,--whole-archive`
    // / `-Wl,-force_load,...` — pulls every member regardless of whether an
    // already-loaded object references one of its defined symbols. Same
    // targets as the POSIX and Darwin profiles.
    auto wholeArchive = [&](const eco::config::RuntimeFile &f) {
        args.push_back(push(std::string("/WHOLEARCHIVE:") + resolveFile(f)));
    };
    wholeArchive(eco::config::entryLib);
    args.push_back(push(resolveFile(eco::config::runtimeLib)));

    for (const auto &lib : eco::config::elmKernelLibs()) {
        bool isUtils =
            std::string_view(lib.basename) == "libElmKernel_Utils.a";
        if (isUtils) {
            wholeArchive(lib);
        } else {
            args.push_back(push(resolveFile(lib)));
        }
    }
    for (const auto &lib : eco::config::ecoKernelLibs()) {
        args.push_back(push(resolveFile(lib)));
    }
    for (const auto &lib : eco::config::ecoSystemLibs()) {
        args.push_back(push(resolveFile(lib)));
    }

    // Vendored statics — libcurl (with schannel TLS), libzip (archive
    // extraction), zlib (curl + libzip dep). Their absolute paths are
    // baked into EcoBootConfig.h's windows* RuntimeFile entries.
    args.push_back(push(resolveFile(eco::config::windowsLibcurlA)));
    args.push_back(push(resolveFile(eco::config::windowsLibzipA)));
    args.push_back(push(resolveFile(eco::config::windowsZlibA)));

    // Windows SDK import libs. kernel32 is implicit but listed for symmetry;
    // ws2_32 / crypt32 / bcrypt / secur32 are pulled by curl's schannel TLS
    // backend and our BCrypt SHA-1 wrapper (Http.cpp). user32 is needed by
    // some MLIR/LLVM diagnostic paths under verbose modes.
    args.push_back("kernel32.lib");
    args.push_back("user32.lib");
    args.push_back("ws2_32.lib");
    args.push_back("crypt32.lib");
    args.push_back("bcrypt.lib");
    args.push_back("secur32.lib");
    args.push_back("advapi32.lib");

    if (opts.verbose) {
        llvm::errs() << "[eco-native] link (Windows, clang-cl + lld-link):";
        for (auto &a : args)
            llvm::errs() << " " << a;
        llvm::errs() << "\n";
    }

    std::string errMsg;
    // With default redirects the link child inherits this process's stdout
    // and stderr. When those are a build tool's pipe, a link descendant can
    // keep an inherited copy of the handle open after this process exits, so
    // the build tool never sees end of file and hangs. Redirect the link
    // child's stdin to null and stdout+stderr to a temp file: the link subtree
    // then inherits the file handle, never the build pipe. The captured output
    // is dumped afterwards so linker diagnostics still reach the log.
    llvm::SmallString<256> linkLog;
    bool haveLog =
        !llvm::sys::fs::createTemporaryFile("eco-link", "log", linkLog);
    if (opts.verbose) {
        llvm::errs() << "[eco-native] link child stdio -> "
                     << (haveLog ? linkLog.str()
                                 : llvm::StringRef("(temp-file failed; inheriting pipe)"))
                     << "\n";
    }
    std::optional<llvm::StringRef> redirects[3] = {
        llvm::StringRef(""),  // stdin  <- /dev/null (linker reads no stdin)
        haveLog ? std::optional<llvm::StringRef>(llvm::StringRef(linkLog))
                : std::nullopt,  // stdout -> temp file (NOT the inherited pipe)
        haveLog ? std::optional<llvm::StringRef>(llvm::StringRef(linkLog))
                : std::nullopt,  // stderr -> same temp file
    };
    int rc = llvm::sys::ExecuteAndWait(*clangCl, args,
                                       /*env=*/std::nullopt,
                                       /*redirects=*/redirects,
                                       /*secondsToWait=*/0,
                                       /*memoryLimit=*/0, &errMsg);
    if (haveLog) {
        if (auto buf = llvm::MemoryBuffer::getFile(linkLog)) {
            llvm::StringRef captured = (*buf)->getBuffer();
            if (!captured.empty())
                llvm::errs() << captured;
        }
        llvm::sys::fs::remove(linkLog);
    }
    if (rc != 0) {
        llvm::errs() << "Error: Windows link (clang-cl/lld-link) failed (rc="
                     << rc << ")";
        if (!errMsg.empty())
            llvm::errs() << ": " << errMsg;
        llvm::errs() << "\n";
        return 1;
    }
    if (opts.verbose)
        llvm::errs() << "[eco-native] linked PE executable: " << outputPath
                     << "\n";
    return 0;
}
#endif

int linkExecutable(const std::string &objectFile,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib) {
    return linkExecutable(std::vector<std::string>{objectFile}, outputPath,
                          opts, sharedLib);
}

int linkExecutable(const std::vector<std::string> &objectFiles,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib) {
#if defined(_WIN32)
    return linkExecutableWindows(objectFiles, outputPath, opts, sharedLib);
#elif defined(__APPLE__)
    // Darwin profile: clang-driver Mach-O link (see linkExecutableDarwin
    // above). The Linux body below is entirely glibc/musl/lld-specific and
    // is dead code on Darwin — keep it gated behind the #else so the
    // generated EcoBootConfig.h's stubbed Linux fields (libgccA = "", crt
    // paths = "", systemLinker = "" on Apple) don't reach the link line.
    return linkExecutableDarwin(objectFiles, outputPath, opts, sharedLib);
#else
    // The linker is invoked directly, not through a compiler driver. Every
    // input is either resolved under the runtime directory (the bundle
    // profiles) or was found at configure time and recorded in the
    // generated eco/EcoBootConfig.h (the host profiles).
    //
    // For HostExe the line has the shape a compiler driver would produce:
    //   ld -pie -dynamic-linker=… -o out
    //       Scrt1.o crti.o crtbeginS.o
    //       <objectFile> <project static archives>
    //       (--start-group …kernels…  --end-group)
    //       -lpthread -lm -lstdc++ -lc -lcurl -lssl -lcrypto -lzip
    //       -lgcc_s libgcc.a -lgcc_s
    //       libunwind.so -lc -lgcc_s
    //       crtendS.o crtn.o
    //       -L<lib search dirs> -rpath <libunwind dir>
    //
    // Notes:
    //   - Project .a archives are absolute paths; library search dirs are
    //     only used to resolve the remaining -l flags (libc, libstdc++ etc).
    //   - libgcc.a / -lgcc_s is repeated to satisfy the cyclic unwinder
    //     dependency the way clang's driver normally does.

    // resolveFile() looks in $ECO_RUNTIME_DIR, then the installed bundle,
    // then the build tree, so a build-tree and an installed binary link alike.
    using eco::config::resolveFile;

    /**
     * The set of link inputs and flags for one output, chosen from the
     * output kind and whether this build is the static-musl bundle, so that
     * the musl bundle can produce both fully static executables and
     * glibc-ABI shared libraries.
     */
    enum class LinkProfile {
        MuslStaticExe,     // -static against the bundle's musl, libc++ and compiler-rt.
        HostExe,           // -pie against the host's glibc.
        HostShared,        // -shared with the host linker and libraries.
        GlibcBundleShared, // -shared against the bundle's glibc/ tree.
    };
    LinkProfile profile;
    if (sharedLib) {
        if (eco::config::ecoStaticMusl) {
            // A fully static musl shared object is impossible (no dynamic
            // section, two libcs in one process), so a shared library needs
            // the bundle's second, glibc set of link inputs.
            if (!eco::config::hasGlibcOutputProfile()) {
                llvm::errs()
                    << "Error: this eco bundle lacks the glibc output "
                       "profile (lib/eco-runtime/glibc/), which .so/.node "
                       "outputs require: shared libraries cannot be "
                       "fully-static musl objects\n";
                return 1;
            }
            profile = LinkProfile::GlibcBundleShared;
        } else {
            profile = LinkProfile::HostShared;
        }
    } else {
        profile = eco::config::ecoStaticMusl ? LinkProfile::MuslStaticExe
                                             : LinkProfile::HostExe;
    }
    // Bundle profiles take every input from lib/eco-runtime/; host
    // profiles use the configure-time-discovered host toolchain paths.
    const bool bundleProfile = profile == LinkProfile::MuslStaticExe ||
                               profile == LinkProfile::GlibcBundleShared;
    const bool hostProfile = !bundleProfile;

    // Bundle profiles use the bundled static ld.lld (a linker does not depend
    // on the target libc, so it serves the glibc shared link too). Host
    // profiles use the host linker discovered at CMake configure time.
    std::string linkerPath = bundleProfile
        ? resolveFile(eco::config::bundledLinker)
        : std::string(eco::config::systemLinker);

    // Backing storage for resolved path strings. std::deque guarantees
    // that push_back never invalidates references to existing elements —
    // we need that since the StringRefs in `args` point into this storage.
    std::deque<std::string> resolvedStrings;
    auto push = [&](std::string s) -> llvm::StringRef {
        resolvedStrings.emplace_back(std::move(s));
        return resolvedStrings.back();
    };

    llvm::SmallVector<llvm::StringRef> args;
    args.push_back(linkerPath);
    args.push_back("--eh-frame-hdr");

    // Opt-in dead-section stripping (binary size). --gc-sections would strip
    // the allocatable .llvm_stackmaps section (nothing relocates into it; the
    // runtime finds it by ELF section name), silently zeroing GC stack roots.
    // Guard it with an augmenting linker-script fragment that KEEPs the
    // section. Both ld.bfd and ld.lld honour `INSERT AFTER` (augment, not
    // replace, the default script). Executable output only.
    std::string gcSectionsScript;
    if (opts.gcSections && !sharedLib) {
        llvm::SmallString<256> scriptPath;
        if (!llvm::sys::fs::createTemporaryFile("eco-keep-stackmaps", "ld",
                                                scriptPath)) {
            std::error_code ec;
            llvm::raw_fd_ostream os(scriptPath, ec);
            if (!ec) {
                os << "SECTIONS { .llvm_stackmaps : { KEEP(*(.llvm_stackmaps)) } }"
                      " INSERT AFTER .rodata;\n";
                os.close();
                gcSectionsScript = std::string(scriptPath);
                args.push_back("--gc-sections");
                args.push_back(push("-T"));
                args.push_back(push(gcSectionsScript));
            }
        }
        if (gcSectionsScript.empty())
            llvm::errs() << "Warning: --gc-sections requested but the KEEP "
                            "linker script could not be created; skipping "
                            "(stackmap safety).\n";
    }

    // Clang-built libc++.a / libc++abi.a embed `#pragma comment(lib)`
    // hints for -lrt and -lpthread (.deplibs sections). With our
    // explicit-absolute-paths link line we emit no -L dirs, so lld can't
    // resolve them — and doesn't need to (musl folds rt/pthread into
    // libc; the glibc shared profile leaves libc symbols undefined by
    // design). Both bundle profiles skip dependent-library resolution.
    if (bundleProfile) {
        args.push_back("--no-dependent-libraries");
    }

    // Under MuslStaticExe the binary is fully static (no PT_INTERP, no
    // shared deps), so we drop `-pie` + `-dynamic-linker` and pass
    // `-static` instead.
    if (sharedLib) {
        args.push_back("-shared");
        // The emitted objects carry R_X86_64_64 relocations in
        // the allocatable .llvm_stackmaps section, which lld refuses in
        // position-independent output unless told otherwise (the host
        // shared profile never hits this — ld.bfd emits the same thing
        // with a DT_TEXTREL warning). The embed runtime REQUIRES those
        // relocations applied in memory (eco_embed.cpp parses the loaded
        // section with loadBase=0), so DT_TEXTREL is the correct
        // behavior.
        if (profile == LinkProfile::GlibcBundleShared) {
            args.push_back("-z");
            args.push_back("notext");
        }
    } else if (profile == LinkProfile::MuslStaticExe) {
        args.push_back("-static");
    } else {
        args.push_back("-pie");
        args.push_back("-dynamic-linker");
        args.push_back(eco::config::dynamicLinker);
    }

    args.push_back("-o");
    args.push_back(outputPath);

    // Search dirs are only needed for the host profiles, where -lc /
    // -lm / -lstdc++ resolve dynamically. Bundle profiles pass every dep
    // as an absolute path under runtimeDir() — no -L needed.
    if (hostProfile) {
        auto libSearchDirs = eco::config::librarySearchDirs();
        for (const auto &d : libSearchDirs) {
            if (d.empty())
                continue;
            args.push_back("-L");
            args.push_back(push(d));
        }
        args.push_back("-L");
        args.push_back(eco::config::gccLibDir);
    }

    // crt prefix.
    //   - host glibc: Scrt1.o (PIE startup) + crti.o + crtbeginS.o
    //     (frame-info ctor table for the shared/PIE variant).
    //   - musl static:  crt1.o  (static startup) + crti.o +
    //     clang_rt.crtbegin-x86_64.o (compiler-rt non-PIE init markers).
    //   - shared lib: no startup object (no _start), but crti/crtbeginS
    //     still provide the init/fini scaffolding. GlibcBundleShared takes
    //     them from the bundle's glibc/crt tree, not from the host.
    if (profile == LinkProfile::MuslStaticExe) {
        args.push_back(push(resolveFile(eco::config::crt1ObjStatic)));
        args.push_back(push(resolveFile(eco::config::crtiObjStatic)));
        args.push_back(push(resolveFile(eco::config::crtbeginObjStatic)));
        // mimalloc replaces musl's malloc. As an object ahead of every archive,
        // its malloc/free/... are the definitions the linker takes, so musl's allocator in libc.a is never pulled in.
        args.push_back(push(resolveFile(eco::config::mimallocObjStatic)));
        // LLVM libc's memcpy/memmove/memset/bcmp/memcmp replace musl's the same way.
        args.push_back(push(resolveFile(eco::config::memfuncsObjStatic)));
    } else if (profile == LinkProfile::GlibcBundleShared) {
        args.push_back(push(resolveFile(eco::config::glibcCrtiObj)));
        args.push_back(push(resolveFile(eco::config::glibcCrtbeginObj)));
    } else {
        if (!sharedLib)
            args.push_back(eco::config::crt1Obj);
        args.push_back(eco::config::crtiObj);
        args.push_back(eco::config::crtbeginObj);
    }

    // The program's object files, one per partition when it was split.
    for (const auto &o : objectFiles)
        args.push_back(o);

    // Project archive set: GlibcBundleShared links the
    // glibc-compiled copies from glibc/project/; everything else uses
    // the original (musl or build-tree) set. Same basenames, same
    // structure — only the subdir differs.
    const bool glibcTree = profile == LinkProfile::GlibcBundleShared;
    const eco::config::RuntimeFile &embedLibFile =
        glibcTree ? eco::config::glibcEmbedLib : eco::config::embedLib;
    const eco::config::RuntimeFile &nodeGlueFile =
        glibcTree ? eco::config::glibcNodeGlueLib : eco::config::nodeGlueLib;
    const eco::config::RuntimeFile &runtimeLibFile =
        glibcTree ? eco::config::glibcRuntimeLib : eco::config::runtimeLib;
    const auto elmKernelFiles = glibcTree ? eco::config::glibcElmKernelLibs()
                                          : eco::config::elmKernelLibs();
    // eco/kernel and eco/system archives are linked alike, so they share one
    // list here.
    auto ecoKernelFiles = glibcTree ? eco::config::glibcEcoKernelLibs()
                                    : eco::config::ecoKernelLibs();
    for (const auto &lib : glibcTree ? eco::config::glibcEcoSystemLibs()
                                     : eco::config::ecoSystemLibs())
        ecoKernelFiles.push_back(lib);

    // Project static archives, wrapped in --start-group so cyclic deps
    // between EffectRegistry / Time / Http effect managers and the
    // Scheduler / Platform helpers resolve.
    args.push_back("--start-group");

    // Executables get the standalone main() (eco_entry); library outputs
    // get the host-embedding entry (eco_app_start/stop/join) instead.
    // --whole-archive on the embed lib: hosts resolve eco_app_* at load
    // time and nothing inside the .so otherwise references them.
    if (sharedLib) {
        args.push_back("--whole-archive");
        args.push_back(push(resolveFile(embedLibFile)));
        // .node targets additionally get the N-API glue (whole-archive so
        // napi_register_module_v1 — referenced only by Node's dlopen — is
        // retained and exported).
        if (pathEndsWith(outputPath, ".node")) {
            args.push_back(push(resolveFile(nodeGlueFile)));
        }
        args.push_back("--no-whole-archive");
    } else {
        args.push_back(push(resolveFile(eco::config::entryLib)));
    }
    args.push_back(push(resolveFile(runtimeLibFile)));

    // ElmKernel_Utils wrapped in --whole-archive so UtilsExports.o always
    // links even when no Elm code references its C-linkage exports —
    // the Order LT/EQ/GT singletons live there.
    for (const auto &lib : elmKernelFiles) {
        bool isUtils = std::string_view(lib.basename) == "libElmKernel_Utils.a";
        if (isUtils)
            args.push_back("--whole-archive");
        args.push_back(push(resolveFile(lib)));
        if (isUtils)
            args.push_back("--no-whole-archive");
    }

    for (const auto &lib : ecoKernelFiles)
        args.push_back(push(resolveFile(lib)));

    args.push_back("--end-group");

    // libc: MuslStaticExe links the bundle's libc.a by absolute path. Under
    // the host profiles the linker resolves it via -l.
    // GlibcBundleShared passes no libc inputs: libc/libm/pthread symbols stay
    // undefined (allowed for -shared) and bind at load time from the glibc
    // already in the host process, as the napi_* symbols do. A C host
    // linking a produced .so must add -lm itself.
    if (profile == LinkProfile::MuslStaticExe) {
        args.push_back(push(resolveFile(eco::config::libcStaticA)));
    } else if (hostProfile) {
        args.push_back("-lpthread");
        args.push_back("-lm");
        args.push_back("-lc");
    }

    if (profile == LinkProfile::GlibcBundleShared) {
        // glibc-targeting static PIC archives from glibc/.
        // libc++abi after libc++ (cxxabi half); z last for forward refs
        // from vendored libzip and libcurl.
        args.push_back(push(resolveFile(eco::config::glibcLibcxxA)));
        args.push_back(push(resolveFile(eco::config::glibcLibcxxabiA)));
        args.push_back(push(resolveFile(eco::config::glibcCurlA)));
        args.push_back(push(resolveFile(eco::config::glibcSslA)));
        args.push_back(push(resolveFile(eco::config::glibcCryptoA)));
        args.push_back(push(resolveFile(eco::config::glibcZipA)));
        args.push_back(push(resolveFile(eco::config::glibcZA)));
    } else if (eco::config::ecoStatic) {
        // libz is required by both vendored libzip and libcurl (HTTP
        // Content-Encoding: gzip), so it comes last to resolve forward refs.
        if (eco::config::ecoStaticMusl) {
            // libc++ references symbols in libc++abi (the cxxabi half of
            // the libc++ runtime), so libc++abi must come after.
            args.push_back(push(resolveFile(eco::config::libcxxStaticA)));
            args.push_back(push(resolveFile(eco::config::libcxxabiStaticA)));
        } else {
            args.push_back(push(resolveFile(eco::config::libstdcxxStaticA)));
        }
        args.push_back(push(resolveFile(eco::config::libcurlStaticA)));
        args.push_back(push(resolveFile(eco::config::libsslStaticA)));
        args.push_back(push(resolveFile(eco::config::libcryptoStaticA)));
        args.push_back(push(resolveFile(eco::config::libzipStaticA)));
        args.push_back(push(resolveFile(eco::config::libzStaticA)));
    } else {
        args.push_back("-lstdc++");
        args.push_back("-lcurl");
        args.push_back("-lssl");
        args.push_back("-lcrypto");
        auto kernelSysLibs = eco::config::kernelSystemLibs();
        for (const auto &lib : kernelSysLibs)
            args.push_back(push(lib));
        args.push_back("-lzip");
        // zlib directly, not only through libzip/libcurl: eco/system's Stream
        // codecs call it.
        args.push_back("-lz");
    }

    // Compiler builtins + unwinder. Four profiles:
    //   - MuslStaticExe: compiler-rt builtins.a, clean overlap
    //     with libunwind (no --allow-multiple-definition).
    //   - GlibcBundleShared: glibc-built compiler-rt builtins
    //     from glibc/, same clean stack.
    //   - host glibc, static archives (ecoStatic): libgcc.a + --allow-multiple-definition
    //     (the LLVM libunwind / libgcc_eh `_Unwind_*` overlap workaround).
    //   - host glibc, dynamic: `-lgcc_s libgcc.a -lgcc_s` dance for the
    //     cyclic libgcc.a / libgcc_s.so dependency.
    if (profile == LinkProfile::GlibcBundleShared) {
        args.push_back(push(resolveFile(eco::config::glibcBuiltinsA)));
    } else if (profile == LinkProfile::MuslStaticExe) {
        args.push_back(push(resolveFile(eco::config::compilerRtBuiltinsA)));
    } else if (eco::config::ecoStatic) {
        args.push_back(eco::config::libgccA);
        args.push_back("--allow-multiple-definition");
    } else {
        args.push_back("-lgcc_s");
        args.push_back(eco::config::libgccA);
        args.push_back("-lgcc_s");
    }

    args.push_back(push(resolveFile(
        glibcTree ? eco::config::glibcUnwindA : eco::config::unwindLib)));

    if (profile == LinkProfile::GlibcBundleShared) {
        // glibc's static link glue (atexit, at_quick_exit, pthread_atfork,
        // __stack_chk_fail_local, …). These are NOT dynamic exports of
        // libc.so.6 — they live only in libc_nonshared.a, the static half
        // of glibc's `-lc` GROUP linker script. Since this profile links
        // no libc (other libc symbols bind from the host at load), without
        // this archive a produced .so/.node references `atexit`
        // (eco_embed's teardown hook) with nothing in the link to resolve
        // it. Its members reference __cxa_atexit (a real dynamic export) and
        // __dso_handle (from crtbeginS.o), so it adds no NEEDED entry.
        // Placed after the archives that reference it so the linker pulls
        // the needed members.
        args.push_back(push(resolveFile(eco::config::glibcLibcNonsharedA)));
    }

    if (profile == LinkProfile::GlibcBundleShared) {
        // Hide every statically linked archive EXCEPT the two
        // whole-archived entry libs. Scoped, NOT `ALL`: lld applies
        // --exclude-libs to whole-archived members too, so ALL would
        // demote napi_register_module_v1 and eco_app_* (embed/glue) to
        // local. Hiding does two jobs:
        //   1. Non-preemptibility: stops Node's libstdc++/libgcc_s from
        //      interposing our static libc++abi/libunwind (operator
        //      new/delete, __cxa_*, _Unwind_*, plain-std:: typeinfos),
        //      and makes compiler-internal direct-PC32 assumptions hold
        //      (clang's __builtin_cpu_supports emits R_X86_64_PC32 to
        //      __cpu_model expecting a link-local definition — kernel
        //      archives like ElmKernel_Regex carry exactly that).
        //   2. Export hygiene: kernel/runtime/dep symbols stay out of
        //      .dynsym. The program's own symbols (in the .o, not
        //      an archive) remain exported.
        std::string excludeLibs =
            "--exclude-libs=libc++.a,libc++abi.a,libunwind.a,"
            "libclang_rt.builtins-x86_64.a,libc_nonshared.a,libcurl.a,"
            "libssl.a,libcrypto.a,libzip.a,libz.a";
        excludeLibs += ",";
        excludeLibs += runtimeLibFile.basename;
        for (const auto &lib : elmKernelFiles) {
            excludeLibs += ",";
            excludeLibs += lib.basename;
        }
        for (const auto &lib : ecoKernelFiles) {
            excludeLibs += ",";
            excludeLibs += lib.basename;
        }
        args.push_back(push(std::move(excludeLibs)));
    }

    // crt epilogue: clang_rt.crtend (musl non-PIE) vs crtendS.o (glibc
    // PIE/shared; GlibcBundleShared takes it from the bundled glibc/crt tree).
    if (profile == LinkProfile::MuslStaticExe) {
        args.push_back(push(resolveFile(eco::config::crtendObjStatic)));
        args.push_back(push(resolveFile(eco::config::crtnObjStatic)));
    } else if (profile == LinkProfile::GlibcBundleShared) {
        args.push_back(push(resolveFile(eco::config::glibcCrtendObj)));
        args.push_back(push(resolveFile(eco::config::glibcCrtnObj)));
    } else {
        args.push_back(eco::config::crtendObj);
        args.push_back(eco::config::crtnObj);
    }

    if (!eco::config::ecoStatic) {
        // rpath so the produced AOT binary finds libunwind.so at runtime
        // without LD_LIBRARY_PATH. Not needed for the .a path. Host
        // profiles only: ecoStatic is constexpr-true in the musl bundle,
        // and GlibcBundleShared links libunwind.a.
        args.push_back("-rpath");
        args.push_back(eco::config::unwindLibDir);
    }

    if (opts.verbose) {
        llvm::errs() << "[eco-native] link (direct ld):";
        for (auto &a : args)
            llvm::errs() << " " << a;
        llvm::errs() << "\n";
    }

    std::string errMsg;
    int rc = llvm::sys::ExecuteAndWait(linkerPath, args,
                                       /*env=*/std::nullopt,
                                       /*redirects=*/{},
                                       /*secondsToWait=*/0,
                                       /*memoryLimit=*/0, &errMsg);
    if (!gcSectionsScript.empty())
        llvm::sys::fs::remove(gcSectionsScript);
    if (rc != 0) {
        llvm::errs() << "Error: ld link failed (rc=" << rc << ")";
        if (!errMsg.empty())
            llvm::errs() << ": " << errMsg;
        llvm::errs() << "\n";
        return 1;
    }

    if (opts.verbose)
        llvm::errs() << "[eco-native] linked executable: " << outputPath
                     << "\n";

    // For .node addons, emit a sibling CommonJS shim (<base>.js) that
    // requires the addon, so `require` of the .js path loads it.
    //
    // When loading fails, the shim treats a missing
    // process.report header.glibcVersionRuntime as meaning a musl-libc Node
    // and replaces the loader error with a clearer message. A failure to
    // write the shim is ignored.
    if (pathEndsWith(outputPath, ".node")) {
        llvm::SmallString<256> shimPath(outputPath.c_str());
        llvm::sys::path::replace_extension(shimPath, ".js");
        std::string base = std::string(llvm::sys::path::filename(outputPath));
        std::error_code ec;
        llvm::raw_fd_ostream shim(shimPath, ec);
        if (!ec) {
            shim << "// Generated by eco: loads the native Elm addon.\n"
                 << "try {\n"
                 << "    module.exports = require('./" << base << "');\n"
                 << "} catch (e) {\n"
                 << "    var report = process.report && process.report.getReport\n"
                 << "        ? process.report.getReport() : undefined;\n"
                 << "    if (!(report && report.header && "
                    "report.header.glibcVersionRuntime)) {\n"
                 << "        throw new Error(\"eco .node addons are "
                    "glibc-ABI; musl-libc Node (e.g. Alpine) is not "
                    "supported\", { cause: e });\n"
                 << "    }\n"
                 << "    throw e;\n"
                 << "}\n";
        }
    }

    return 0;
#endif // _WIN32 / __APPLE__ / else
}

} // namespace eco

//===----------------------------------------------------------------------===//
// C ABI implementation: default EcoNativeOptions, plus `rootModule` if given.
//===----------------------------------------------------------------------===//

extern "C" int eco_native_lower_and_link(const char *mlirPath,
                                          const char *outputPath,
                                          const char *rootModule) {
    eco::EcoNativeOptions opts;
    if (rootModule != nullptr)
        opts.rootModule = rootModule;
    return eco::compileMlirFileToExecutable(mlirPath, outputPath, opts);
}

extern "C" int eco_native_lower_and_link_bytes(const char *mlirBytes,
                                                size_t mlirLen,
                                                const char *outputPath) {
    eco::EcoNativeOptions opts;
    return eco::compileMlirBytesToExecutable(mlirBytes, mlirLen, outputPath,
                                              opts);
}
