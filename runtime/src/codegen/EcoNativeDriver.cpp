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
#include <cstring>
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

#include <deque>
#include <string_view>

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

// The target CPU/feature pin and TargetMachine factory live in EcoBackend.h
// (createEcoTargetMachine / kEcoTargetCPU), shared with eco-boot.cpp.

// Output mode selected from the target path's extension:
//   *.o          → emit the relocatable object only (no link)
//   *.so, *.node → link a shared library (embed entry, no main())
//   otherwise    → link a PIE executable (standalone entry)
// See plans/native-ports-and-embedding.md (Phase 3/4).
bool pathEndsWith(const std::string &path, const char *suffix) {
    size_t n = std::strlen(suffix);
    return path.size() >= n &&
           path.compare(path.size() - n, n, suffix) == 0;
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

    // Bake the root module name into the program as `__eco_root_module`.
    // The N-API addon declares it as a weak extern and uses it to name the
    // `Elm.<RootModule>` export; without it the addon falls back to "Main".
    if (!opts.rootModule.empty()) {
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

    const bool emitObjOnly = pathEndsWith(outputPath, ".o");
    const bool sharedLib = pathEndsWith(outputPath, ".so") ||
                           pathEndsWith(outputPath, ".node");

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

    if (emitObjOnly)
        return 0;

    int rc;
    {
        std::unique_ptr<eco::LoweringStats::Scope> scope;
        if (opts.stats)
            scope = std::make_unique<eco::LoweringStats::Scope>(
                *opts.stats, "Link (system ld)");
        rc = eco::linkExecutable(objFile, outputPath, opts, sharedLib);
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

#if defined(__APPLE__)
// Darwin AOT link: invoke clang (xcrun-resolved at configure time) as the
// link driver and let it figure out crt/SDK details. ld64 is much more
// integrated than ld.bfd/lld for Mach-O — Apple ships no crt objects (the
// dynamic loader does startup), and libSystem/libc++/libcurl/libz are
// SDK .tbd stubs that the SDK path locates. ld64 also ad-hoc-signs arm64
// outputs automatically, so no codesign step is needed.
//
// Stackmaps: ld64 keeps unreferenced sections by default and we never pass
// -dead_strip — the __LLVM_STACKMAPS,__llvm_stackmaps section survives
// (verified by experiments/mac-statepoint-smoke; see plans/build-on-mac.md
// E-M1 results).
static int linkExecutableDarwin(const std::string &objectFile,
                                const std::string &outputPath,
                                const EcoNativeOptions &opts,
                                bool sharedLib) {
    using eco::config::resolveFile;

    if (sharedLib) {
        // Mach-O .dylib / .node support is out of scope for M4; plumbing it
        // is a follow-up that mirrors the Stage D LinkProfile::HostShared
        // refactor (LinkProfile knob, embed entry, codesign of the dylib).
        llvm::errs()
            << "Error: Darwin shared-library output is not yet supported.\n";
        return 1;
    }

    std::deque<std::string> resolvedStrings;
    auto push = [&](std::string s) -> llvm::StringRef {
        resolvedStrings.emplace_back(std::move(s));
        return resolvedStrings.back();
    };

    llvm::SmallVector<llvm::StringRef> args;
    args.push_back(eco::config::darwinClang);

    // SDK + arch. -isysroot tells clang where to find libSystem/libc++/
    // libcurl/libz .tbd stubs; -arch is set explicitly so the link is
    // robust under Rosetta / cross-arch scenarios.
    args.push_back("-isysroot");
    args.push_back(eco::config::darwinSdkRoot);
    args.push_back("-arch");
    args.push_back(eco::config::darwinArch);

    args.push_back("-o");
    args.push_back(outputPath);
    args.push_back(objectFile);

    // ld64's symbol-extraction semantics are more aggressive than ld.bfd's:
    // archive members get pulled only when an already-loaded object refers
    // to one of their defined symbols. main() in eco_entry.cpp has no such
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

    // libzip + OpenSSL (libssl, libcrypto) — not in the macOS SDK. libzip
    // is vendored statically via FetchContent (see eco-kernel-cpp/
    // CMakeLists.txt). OpenSSL is brew's openssl@3 keg statics: required
    // because (a) the vendored libzip's configure pulls in
    // zip_crypto_openssl.c on a brew-equipped host even with
    // ENABLE_OPENSSL=OFF (auto-detect fallback), and (b) Http.cpp's
    // SHA1-hashing of downloaded zips uses <openssl/sha.h>. Both are
    // tracked in plans/build-on-mac.md as "eliminate via CommonCrypto" —
    // for v1 we link them.
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
    int rc = llvm::sys::ExecuteAndWait(eco::config::darwinClang, args,
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

int linkExecutable(const std::string &objectFile,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib) {
#if defined(__APPLE__)
    // Darwin profile: clang-driver Mach-O link (see linkExecutableDarwin
    // above). The Linux body below is entirely glibc/musl/lld-specific and
    // is dead code on Darwin — keep it gated behind the #else so the
    // generated EcoBootConfig.h's stubbed Linux fields (libgccA = "", crt
    // paths = "", systemLinker = "" on Apple) don't reach the link line.
    return linkExecutableDarwin(objectFile, outputPath, opts, sharedLib);
#else
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

    // resolveFile() picks $ECO_RUNTIME_DIR / bundled / buildPath in that
    // priority; see EcoBootConfig.cpp. Used everywhere a path is needed so
    // both the build-time eco-boot-native and the installed eco binary
    // share one code path.
    using eco::config::resolveFile;

    // Stage D: output link profile. The profile used to be implied by the
    // compile-time bundle flavor (ecoStaticMusl); it is now selected per
    // output kind so the musl bundle can produce BOTH fully-static
    // executables (Stage B.5) and glibc-ABI shared libraries (Stage D)
    // from one binary. See plans/stage-d-hybrid-link-profiles.md.
    enum class LinkProfile {
        MuslStaticExe,     // Stage B.5: -static, musl/libc++/compiler-rt
        HostExe,           // legacy dev/A.5: -pie against host glibc paths
        HostShared,        // legacy dev .so/.node via the host linker
        GlibcBundleShared, // Stage D: -shared against the bundled glibc/ tree
    };
    LinkProfile profile;
    if (sharedLib) {
        if (eco::config::ecoStaticMusl) {
            // A fully-static musl shared object remains a contradiction in
            // terms (no dynamic section, two libcs in one process); what
            // changed in Stage D is that the bundle can now carry a second
            // set of glibc link inputs for exactly this case.
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

    // Stage C: bundle profiles use the bundled static ld.lld from
    // lib/eco-runtime/ (a linker is target-ABI-agnostic, so it serves the
    // Stage D glibc -shared links too). Host profiles use the host linker
    // discovered at CMake configure time.
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

    // Clang-built libc++.a / libc++abi.a embed `#pragma comment(lib)`
    // hints for -lrt and -lpthread (.deplibs sections). With our
    // explicit-absolute-paths link line we emit no -L dirs, so lld can't
    // resolve them — and doesn't need to (musl folds rt/pthread into
    // libc; the Stage D shared profile leaves libc symbols undefined by
    // design). Both bundle profiles skip dependent-library resolution.
    if (bundleProfile) {
        args.push_back("--no-dependent-libraries");
    }

    // Stage B.5 musl-static vs Stage A.5 glibc-dynamic-PIE vs -shared.
    // Under MuslStaticExe the binary is fully static (no PT_INTERP, no
    // shared deps), so we drop `-pie` + `-dynamic-linker` and pass
    // `-static` instead.
    if (sharedLib) {
        args.push_back("-shared");
        // Stage D: the emitted objects carry R_X86_64_64 relocations in
        // the allocatable .llvm_stackmaps section, which lld refuses in
        // position-independent output unless told otherwise (the host
        // shared profile never hits this — ld.bfd emits the same thing
        // with a DT_TEXTREL warning). The embed runtime REQUIRES those
        // relocations applied in memory (eco_embed.cpp parses the loaded
        // section with loadBase=0), so DT_TEXTREL is the correct
        // behavior, not a workaround. Follow-up to remove it tracked in
        // plans/stage-d-hybrid-link-profiles.md.
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
    //   - glibc/Stage A.5: Scrt1.o (PIE startup) + crti.o + crtbeginS.o
    //     (frame-info ctor table for the shared/PIE variant).
    //   - musl/Stage B.5:  crt1.o  (static startup) + crti.o +
    //     clang_rt.crtbegin-x86_64.o (compiler-rt non-PIE init markers).
    //   - shared lib: no startup object (no _start), but crti/crtbeginS
    //     still provide the init/fini scaffolding. Stage D takes them
    //     from the bundle's glibc/crt tree (harvested from the Debian
    //     builder), not from the host.
    if (profile == LinkProfile::MuslStaticExe) {
        args.push_back(push(resolveFile(eco::config::crt1ObjStatic)));
        args.push_back(push(resolveFile(eco::config::crtiObjStatic)));
        args.push_back(push(resolveFile(eco::config::crtbeginObjStatic)));
    } else if (profile == LinkProfile::GlibcBundleShared) {
        args.push_back(push(resolveFile(eco::config::glibcCrtiObj)));
        args.push_back(push(resolveFile(eco::config::glibcCrtbeginObj)));
    } else {
        if (!sharedLib)
            args.push_back(eco::config::crt1Obj);
        args.push_back(eco::config::crtiObj);
        args.push_back(eco::config::crtbeginObj);
    }

    // The user's compiled .o.
    args.push_back(objectFile);

    // Project archive set: the Stage D shared profile links the
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
    const auto ecoKernelFiles = glibcTree ? eco::config::glibcEcoKernelLibs()
                                          : eco::config::ecoKernelLibs();

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

    // libc — under MUSL/static we ship libc.a in the bundle as an
    // absolute path. Under the host profiles we let the linker resolve
    // via -l. Stage D passes NO libc inputs at all: libc/libm/pthread
    // symbols stay undefined (allowed for -shared) and bind at load time
    // from the glibc already in the host process — the same mechanism
    // the napi_* symbols use. C hosts linking a produced .so must add
    // -lm themselves (documented in design_docs/distribution.md).
    if (profile == LinkProfile::MuslStaticExe) {
        args.push_back(push(resolveFile(eco::config::libcStaticA)));
    } else if (hostProfile) {
        args.push_back("-lpthread");
        args.push_back("-lm");
        args.push_back("-lc");
    }

    if (profile == LinkProfile::GlibcBundleShared) {
        // Stage D: glibc-targeting static PIC archives from glibc/.
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
    }

    // Compiler builtins + unwinder. Four profiles:
    //   - Stage B.5 (musl/static): compiler-rt builtins.a, clean overlap
    //     with libunwind (no --allow-multiple-definition).
    //   - Stage D (glibc bundle shared): glibc-built compiler-rt builtins
    //     from glibc/, same clean stack.
    //   - Stage A.5 (glibc/static): libgcc.a + --allow-multiple-definition
    //     (the LLVM libunwind / libgcc_eh `_Unwind_*` overlap workaround).
    //   - Default (glibc/dynamic): `-lgcc_s libgcc.a -lgcc_s` dance for the
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
        // (eco_embed's teardown hook) with nothing to resolve it and fails
        // dlopen with "undefined symbol: atexit" on every glibc host. Its
        // members reference __cxa_atexit (a real dynamic export) and
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
        // local and break the addon (verified). Hiding does two jobs:
        //   1. Non-preemptibility: stops Node's libstdc++/libgcc_s from
        //      interposing our static libc++abi/libunwind (operator
        //      new/delete, __cxa_*, _Unwind_*, plain-std:: typeinfos),
        //      and makes compiler-internal direct-PC32 assumptions hold
        //      (clang's __builtin_cpu_supports emits R_X86_64_PC32 to
        //      __cpu_model expecting a link-local definition — kernel
        //      archives like ElmKernel_Regex carry exactly that).
        //   2. Export hygiene: kernel/runtime/dep symbols stay out of
        //      .dynsym. The user program's own symbols (in the .o, not
        //      an archive) remain exported — trimming them is the D6
        //      follow-up.
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
    // PIE/shared; Stage D takes it from the bundled glibc/crt tree).
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
        // and Stage D links libunwind.a — no rpath either way.
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

    // For .node addons, emit a sibling CommonJS shim (<base>.js) so hosts
    // written against the JS target's `require("./build/elm.js")` resolve
    // to the native addon unaltered (name the output elm.node to match).
    //
    // The shim also turns the raw loader error a glibc-ABI addon produces
    // under musl-libc Node (e.g. Alpine) into a clear message:
    // process.report's header.glibcVersionRuntime is absent exactly on
    // musl builds of Node, a stable documented discriminator. See
    // plans/stage-d-hybrid-link-profiles.md step 6.
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
#endif // __APPLE__
}

} // namespace eco

//===----------------------------------------------------------------------===//
// C ABI implementation
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
