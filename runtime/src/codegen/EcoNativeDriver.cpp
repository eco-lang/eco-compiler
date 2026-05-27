//===- EcoNativeDriver.cpp - MLIR-to-ELF library implementation ----------===//
//
// Shared lowering pipeline used by both eco-boot-native (CLI) and the unified
// `eco` binary (via Eco_Kernel_NativeDriver_lowerAndLink kernel intrinsic).
//
// Originally lived inside eco-boot.cpp; extracted into a library so the same
// pipeline can be invoked in-process from the Elm-compiled compiler without
// spawning a child process.
//
//===----------------------------------------------------------------------===//

#include "EcoNativeDriver.h"
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

#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/FileSystem.h"
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
#include "LoweringStats.h"
#include "Passes.h"

#include "eco/EcoBootConfig.h"

namespace eco {
void linkEcoGCStrategy();
} // namespace eco

namespace {

// Pull EcoGC strategy linker side-effect in. Same trick eco-boot.cpp uses —
// instantiating the static here keeps the symbol live in the library.
struct EcoGCStrategyLibLinker {
    EcoGCStrategyLibLinker() { eco::linkEcoGCStrategy(); }
} ecoGCStrategyLibLinker;

using namespace mlir;

OwningOpRef<ModuleOp> loadMLIRFromSourceMgr(MLIRContext &context,
                                             llvm::SourceMgr &sourceMgr) {
    auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
    if (!module)
        llvm::errs() << "Error: Failed to parse MLIR\n";
    return module;
}

int runPipeline(ModuleOp module, eco::LoweringStats *stats) {
    PassManager pm(module->getName());

    // Skip applyPassManagerCLOptions — the library is invoked outside any
    // CLI-options-aware context (e.g. from the unified `eco` kernel
    // intrinsic). The call would fail with "no CL options registered" if
    // we tried it, and it's only relevant for pass-manager debug flags
    // anyway.

    if (stats)
        pm.addInstrumentation(stats->makePassInstrumentation());

    eco::EcoPipelineOptions pipeOpts;
    eco::buildEcoToLLVMPipeline(pm, pipeOpts);

    if (failed(pm.run(module)))
        return 1;

    return 0;
}

std::unique_ptr<llvm::Module>
translateToLLVMIR(ModuleOp module, llvm::LLVMContext &llvmContext) {
    registerBuiltinDialectTranslation(*module->getContext());
    registerLLVMDialectTranslation(*module->getContext());

    auto llvmModule = translateModuleToLLVMIR(module, llvmContext);
    if (!llvmModule) {
        llvm::errs() << "Error: Failed to translate MLIR to LLVM IR\n";
        return nullptr;
    }

    // The Elm `main` (a Platform.worker value) is invoked by the C++ entry
    // wrapper (`eco_entry.cpp`); rename it so it doesn't collide with the
    // wrapper's literal `main()`.
    if (auto *mainFn = llvmModule->getFunction("main"))
        mainFn->setName("eco_main");

    return llvmModule;
}

std::unique_ptr<llvm::TargetMachine>
createTargetMachine(llvm::Module &module, unsigned optLevel) {
    auto triple = llvm::sys::getDefaultTargetTriple();
    module.setTargetTriple(llvm::Triple(triple));

    std::string error;
    const auto *target = llvm::TargetRegistry::lookupTarget(triple, error);
    if (!target) {
        llvm::errs() << "Error: Could not find target: " << error << "\n";
        return nullptr;
    }

    auto cpu = llvm::sys::getHostCPUName();
    llvm::SubtargetFeatures features;
    auto hostFeatures = llvm::sys::getHostCPUFeatures();
    for (auto &f : hostFeatures)
        features.AddFeature(f.first(), f.second);

    llvm::TargetOptions targetOpts;

    auto codeGenOpt =
        static_cast<llvm::CodeGenOptLevel>(std::min(optLevel, 3u));

    auto *tm = target->createTargetMachine(
        llvm::Triple(triple), cpu, features.getString(), targetOpts,
        llvm::Reloc::PIC_, llvm::CodeModel::Small, codeGenOpt);

    if (!tm) {
        llvm::errs() << "Error: Could not create TargetMachine\n";
        return nullptr;
    }

    module.setDataLayout(tm->createDataLayout());
    return std::unique_ptr<llvm::TargetMachine>(tm);
}

int pipelineFromMlirModule(OwningOpRef<ModuleOp> module,
                           const std::string &outputPath,
                           const eco::EcoNativeOptions &opts) {
    if (failed(verify(*module))) {
        llvm::errs() << "Error: Module verification failed\n";
        return 1;
    }

    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "MLIR lowering pipeline");
        if (runPipeline(*module, opts.stats) != 0)
            return 1;
    }

    llvm::LLVMContext llvmContext;
    std::unique_ptr<llvm::Module> llvmModule;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "MLIR -> LLVM IR translation");
        llvmModule = translateToLLVMIR(*module, llvmContext);
        if (!llvmModule)
            return 1;
    }

    std::unique_ptr<llvm::TargetMachine> tm;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "TargetMachine init");
        tm = createTargetMachine(*llvmModule, opts.optLevel);
        if (!tm)
            return 1;
    }

    // Emit to a temp object file, then link.
    llvm::SmallString<256> tempObjPath;
    if (auto ec = llvm::sys::fs::createTemporaryFile("eco-driver", "o",
                                                     tempObjPath)) {
        llvm::errs() << "Error: Could not create temp object file: "
                     << ec.message() << "\n";
        return 1;
    }
    std::string objFile(tempObjPath);

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
        if (auto err = eco::runEcoBackend(*llvmModule, job)) {
            llvm::errs() << "Error: backend pipeline failed: " << err << "\n";
            llvm::sys::fs::remove(objFile);
            return 1;
        }
    }

    int rc;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "Link (system ld)");
        rc = eco::linkExecutable(objFile, outputPath, opts);
    }

    llvm::sys::fs::remove(objFile);
    return rc;
}

} // namespace

namespace eco {

void initializeLLVMNativeTarget() {
    // LLVM's Initialize* functions are idempotent — register once per process.
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

int linkExecutable(const std::string &objectFile,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts) {
    // Phase 3: invoke the system linker (ld.bfd) directly rather than the
    // clang++ driver. Eliminates the clang++ runtime dependency; the linker
    // path + crt files + libgcc + dynamic linker were all discovered at
    // CMake configure time and baked into EcoBootConfig.h.
    //
    // The arg layout mirrors what clang++ would have emitted, distilled to
    // just what we need for a PIE ELF binary:
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

    auto linkerPath = std::string(eco::config::systemLinker);

    std::string entryLib = eco::config::entryLib;
    std::string runtimeLib = eco::config::runtimeLib;
    auto elmKernelLibs = eco::config::elmKernelLibs();
    auto ecoKernelLibs = eco::config::ecoKernelLibs();
    auto kernelSysLibs = eco::config::kernelSystemLibs();
    auto libSearchDirs = eco::config::librarySearchDirs();

    llvm::SmallVector<llvm::StringRef> args;
    args.push_back(linkerPath);
    args.push_back("--eh-frame-hdr");

    // Stage B.5 musl-static vs Stage A.5 glibc-dynamic-PIE. Under
    // ecoStaticMusl the binary is fully static (no PT_INTERP, no shared
    // deps), so we drop `-pie` + `-dynamic-linker` and pass `-static`
    // instead. The rest of the layout (start-group / archives / crt
    // epilogue) is identical across profiles.
    if (eco::config::ecoStaticMusl) {
        args.push_back("-static");
    } else {
        args.push_back("-pie");
        args.push_back("-dynamic-linker");
        args.push_back(eco::config::dynamicLinker);
    }

    args.push_back("-o");
    args.push_back(outputPath);

    // Library search dirs so -lc / -lm / -lstdc++ etc. resolve. We add the
    // multilib dirs from `clang -print-search-dirs` plus the gcc libdir
    // (which holds crtbeginS.o, libgcc.a, libstdc++.so). Under
    // ecoStaticMusl every dep is passed as an absolute .a path, so the
    // search dirs only matter for `-lc` (musl libc), but emitting them is
    // harmless and keeps the two profiles parallel.
    for (const auto &d : libSearchDirs) {
        if (d.empty())
            continue;
        args.push_back("-L");
        args.push_back(d);
    }
    args.push_back("-L");
    args.push_back(eco::config::gccLibDir);

    // crt prefix.
    //   - glibc/Stage A.5: Scrt1.o (PIE startup) + crti.o + crtbeginS.o
    //     (frame-info ctor table for the shared/PIE variant).
    //   - musl/Stage B.5:  crt1.o  (static startup) + crti.o + crtbegin.o
    //     (non-PIE frame-info ctor table).
    if (eco::config::ecoStaticMusl) {
        args.push_back(eco::config::crt1ObjStatic);
        args.push_back(eco::config::crtiObj);
        args.push_back(eco::config::crtbeginObjStatic);
    } else {
        args.push_back(eco::config::crt1Obj);
        args.push_back(eco::config::crtiObj);
        args.push_back(eco::config::crtbeginObj);
    }

    // The user's compiled .o.
    args.push_back(objectFile);

    // Project static archives, wrapped in --start-group so cyclic deps
    // between EffectRegistry / Time / Http effect managers and the
    // Scheduler / Platform helpers resolve.
    args.push_back("--start-group");

    if (!entryLib.empty())
        args.push_back(entryLib);
    if (!runtimeLib.empty())
        args.push_back(runtimeLib);

    // ElmKernel_Utils wrapped in --whole-archive so UtilsExports.o always
    // links even when no Elm code references its C-linkage exports — same
    // reason as the clang++ path (the Order LT/EQ/GT singletons live there).
    for (const auto &lib : elmKernelLibs) {
        bool isUtils = lib.find("libElmKernel_Utils.") != std::string::npos;
        if (isUtils)
            args.push_back("--whole-archive");
        args.push_back(lib);
        if (isUtils)
            args.push_back("--no-whole-archive");
    }

    for (const auto &lib : ecoKernelLibs)
        args.push_back(lib);

    args.push_back("--end-group");

    // System libc. Stage A.5 (glibc) needs the pthread/m/c trio shared;
    // Stage B.5 (musl) folds pthread and m into libc, so -lc on its own is
    // sufficient. Under -static + -nodefaultlibs-style explicit listing,
    // emitting empty libpthread/libm stubs from Alpine would be harmless
    // but redundant — drop them for clarity.
    if (eco::config::ecoStaticMusl) {
        args.push_back("-lc");
    } else {
        args.push_back("-lpthread");
        args.push_back("-lm");
        args.push_back("-lc");
    }

    if (eco::config::ecoStatic) {
        // Stage A.5 / B.5: feed absolute paths to the static archives baked
        // at configure time, in place of the bare -l flags the linker would
        // otherwise resolve to .so. See plans/static-link-eco-binary.md.
        // libz is required by both vendored libzip and libcurl (HTTP
        // Content-Encoding: gzip), so it comes last to resolve forward refs.
        if (eco::config::ecoStaticMusl) {
            // Stage B.5: libc++ + libc++abi instead of libstdc++. Order
            // matters: libc++ references symbols in libc++abi (the cxxabi
            // half of the libc++ runtime), so libc++abi must come after.
            args.push_back(eco::config::libcxxStaticA);
            args.push_back(eco::config::libcxxabiStaticA);
        } else {
            args.push_back(eco::config::libstdcxxStaticA);
        }
        args.push_back(eco::config::libcurlStaticA);
        args.push_back(eco::config::libsslStaticA);
        args.push_back(eco::config::libcryptoStaticA);
        args.push_back(eco::config::libzipStaticA);
        args.push_back(eco::config::libzStaticA);
        // kernelSysLibs() is empty under ECO_STATIC (the vendored libzip
        // is wired in directly above), but skip it defensively.
    } else {
        args.push_back("-lstdc++");
        args.push_back("-lcurl");
        args.push_back("-lssl");
        args.push_back("-lcrypto");
        for (const auto &lib : kernelSysLibs)
            args.push_back(lib);
        args.push_back("-lzip");
    }

    // Compiler builtins (`__udivti3`, integer-overflow soft-floats, etc.) +
    // unwinder. Three profiles:
    //   - Stage B.5 (musl/static): compiler-rt builtins.a. No libgcc, no
    //     libgcc_s, no --allow-multiple-definition workaround — Q4 RESOLVED
    //     in compiler-rt + libunwind's favour (clean, no symbol overlap).
    //   - Stage A.5 (glibc/static): libgcc.a + --allow-multiple-definition
    //     (the LLVM libunwind / libgcc_eh `_Unwind_*` overlap workaround).
    //   - Default (glibc/dynamic): `-lgcc_s libgcc.a -lgcc_s` dance for the
    //     cyclic libgcc.a / libgcc_s.so dependency.
    if (eco::config::ecoStaticMusl) {
        args.push_back(eco::config::compilerRtBuiltinsA);
    } else if (eco::config::ecoStatic) {
        args.push_back(eco::config::libgccA);
        args.push_back("--allow-multiple-definition");
    } else {
        args.push_back("-lgcc_s");
        args.push_back(eco::config::libgccA);
        args.push_back("-lgcc_s");
    }

    // LLVM libunwind. Under ECO_STATIC, unwindLib is libunwind.a (the
    // Stage-A change to LLVMLibunwind.cmake selects the .a). Otherwise
    // it's libunwind.so loaded via the rpath added below.
    args.push_back(eco::config::unwindLib);

    // crt epilogue: crtend.o (musl non-PIE) vs crtendS.o (glibc PIE).
    if (eco::config::ecoStaticMusl) {
        args.push_back(eco::config::crtendObjStatic);
    } else {
        args.push_back(eco::config::crtendObj);
    }
    args.push_back(eco::config::crtnObj);

    if (!eco::config::ecoStatic) {
        // rpath so the produced AOT binary finds libunwind.so at runtime
        // without LD_LIBRARY_PATH. Not needed for the .a path.
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

    return 0;
}

} // namespace eco

//===----------------------------------------------------------------------===//
// C ABI implementation
//===----------------------------------------------------------------------===//

extern "C" int eco_native_lower_and_link(const char *mlirPath,
                                          const char *outputPath) {
    eco::EcoNativeOptions opts;
    return eco::compileMlirFileToExecutable(mlirPath, outputPath, opts);
}

extern "C" int eco_native_lower_and_link_bytes(const char *mlirBytes,
                                                size_t mlirLen,
                                                const char *outputPath) {
    eco::EcoNativeOptions opts;
    return eco::compileMlirBytesToExecutable(mlirBytes, mlirLen, outputPath,
                                              opts);
}
