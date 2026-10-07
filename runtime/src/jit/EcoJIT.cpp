//===- EcoJIT.cpp - JIT execution engine with stack map support -----------===//
//
// Custom JIT execution engine for Eco, derived from MLIR's ExecutionEngine.
// Adds JITEventListener to extract __LLVM_StackMaps from JIT'd object code.
//
// Original: mlir/lib/ExecutionEngine/ExecutionEngine.cpp
// License:  Apache License v2.0 with LLVM Exceptions (SPDX: Apache-2.0)
//
//===----------------------------------------------------------------------===//

#include <cstdio>   // TEMP(diag)
#include <cstdlib>  // TEMP(diag)
#include "EcoJIT.h"

#include <cstring>

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/ExecutionEngine/JITEventListener.h"
#include "llvm/ExecutionEngine/Orc/CompileUtils.h"
#include "llvm/ExecutionEngine/Orc/ExecutionUtils.h"
#include "llvm/ExecutionEngine/Orc/IRCompileLayer.h"
#include "llvm/ExecutionEngine/Orc/IRTransformLayer.h"
#include "llvm/ExecutionEngine/Orc/JITTargetMachineBuilder.h"
#include "llvm/ExecutionEngine/Orc/RTDyldObjectLinkingLayer.h"
#if defined(__APPLE__)
#include "llvm/ExecutionEngine/Orc/TargetProcess/UnwindInfoManager.h"
#endif
#include "llvm/IR/IRBuilder.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Support/Error.h"
#include "llvm/TargetParser/Host.h"

using namespace llvm;
using namespace llvm::orc;

// Declared at file scope — not inside namespace eco or the anonymous
// namespace below — so these resolve against the C entry points exported
// by LLVM libunwind (libgcc-compatible). Nested extern "C" inside a class
// would create class members; inside a namespace it would still be C linkage
// but clutters the lookup path.
#if !defined(_WIN32)
extern "C" void __register_frame(void *);
extern "C" void __deregister_frame(void *);
// TEMP(diag) (plans/ci-all-platforms-green.md issue 8)
struct dwarf_eh_bases;
extern "C" const void *_Unwind_Find_FDE(const void *pc, struct dwarf_eh_bases *);
#endif

namespace {

#if defined(_WIN32)
// On Win64 the JIT'd code is COFF, not ELF, so there is no .eh_frame to
// register — JIT'd functions are unwound via .pdata / .xdata sections and
// LLVM's RTDyld COFF support registers those with RtlAddFunctionTable
// internally (the same primitive verified by E-W2 / experiments/win-jit-smoke).
// We retain the SectionMemoryManager subclass for symmetry with the POSIX
// build, and override the EH-frame hooks to no-ops.
class EcoSectionMemoryManager : public llvm::SectionMemoryManager {
public:
    void registerEHFrames(uint8_t* /*Addr*/, uint64_t /*LoadAddr*/,
                          size_t /*Size*/) override {}
    void deregisterEHFrames() override {}
};
#else
// EcoSectionMemoryManager overrides EH-frame registration for JIT objects.
// LLVM libunwind's __register_frame takes a single FDE pointer (see
// /opt/llvm-mlir/include/unwind.h: "The FDE must use pc-rel addressing to
// point to its function"); a .eh_frame section begins with a CIE, so passing
// the section base produces "bad fde: FDE is really a CIE" and registers
// zero FDEs. We walk the section and call __register_frame per FDE, skipping
// CIEs. ORC's RTDyldObjectLinkingLayer guarantees the same (Addr, Size) comes
// back via deregisterEHFrames on teardown, so we replay the walk in reverse.
class EcoSectionMemoryManager : public llvm::SectionMemoryManager {
public:
    void registerEHFrames(uint8_t *Addr, uint64_t LoadAddr,
                          size_t Size) override {
        if (!Addr || Size == 0)
            return;
        // LLVM libunwind's __register_frame expects a single FDE pointer, not
        // a section base (per /opt/llvm-mlir/include/unwind.h: "The FDE must
        // use pc-rel addressing to point to its function"). Walk the section
        // and pass each FDE individually; skip CIE records (cie_pointer == 0).
        uint8_t *P = Addr;
        uint8_t *End = Addr + Size;
        uint64_t codeLo = UINT64_MAX, codeHi = 0;
        size_t fdes = 0;
        while (P < End) {
            uint32_t length;
            memcpy(&length, P, 4);
            if (length == 0)
                break; // terminator
            size_t fullLen = 4 + length;
            if (length == 0xffffffff) {
                uint64_t extLen;
                memcpy(&extLen, P + 4, 8);
                fullLen = 4 + 8 + extLen;
            }
            uint32_t ciePointer;
            memcpy(&ciePointer, P + 4, 4);
            if (ciePointer != 0) {
                __register_frame(P);
                uint64_t lo = 0, hi = 0;
                fdeCodeRange(P, ciePointer, lo, hi);
                codeLo = std::min(codeLo, lo);
                codeHi = std::max(codeHi, hi);
                if (fdes < 4 && std::getenv("ECO_TEST_STACKWALK_DIAG"))  // TEMP(diag)
                    std::fprintf(stderr, "[diag-ehframe] FDE %p -> code [%#llx, %#llx)\n",
                                 static_cast<void*>(P), (unsigned long long)lo,
                                 (unsigned long long)hi);
                ++fdes;
            }
            P += fullLen;
        }
#if defined(__APPLE__)
        // macOS: the system libunwind does not find FDEs passed to __register_frame for JIT code
        // (_Unwind_Find_FDE returns null, unw_step stops at the first JIT frame), so the GC's
        // stack walk never reached JIT frames and their roots went stale. Also register the whole
        // section for the code range it covers through libunwind's find-dynamic-unwind-sections
        // hook, as ORC's JITLink does on Darwin (llvm::orc::UnwindInfoManager).
        bool viaHook = false;
        if (codeLo < codeHi && llvm::orc::UnwindInfoManager::TryEnable()) {
            const llvm::orc::ExecutorAddrRange code{llvm::orc::ExecutorAddr(codeLo),
                                                    llvm::orc::ExecutorAddr(codeHi)};
            if (auto err = llvm::orc::UnwindInfoManager::registerSections(
                    {code}, llvm::orc::ExecutorAddr(codeLo),
                    llvm::orc::ExecutorAddrRange(llvm::orc::ExecutorAddr::fromPtr(Addr),
                                                 llvm::orc::ExecutorAddrDiff(Size)),
                    llvm::orc::ExecutorAddrRange())) {
                llvm::errs() << "[eco-jit] unwind-section registration failed: "
                             << llvm::toString(std::move(err)) << "\n";
            } else {
                HookRanges.push_back(code);
                viaHook = true;
            }
        }
#else
        const bool viaHook = false;
#endif
        // TEMP(diag) (plans/ci-all-platforms-green.md issue 8): is JIT unwind info registered?
        if (std::getenv("ECO_TEST_STACKWALK_DIAG"))
            std::fprintf(stderr, "[diag-ehframe] registerEHFrames: section %p, load addr %#llx, "
                         "%zu bytes, %zu FDEs, code [%#llx, %#llx), dynamic-sections hook %s\n",
                         static_cast<void*>(Addr), (unsigned long long)LoadAddr, Size, fdes,
                         (unsigned long long)codeLo, (unsigned long long)codeHi,
                         viaHook ? "registered" : "not used");
        EHFrames.push_back({Addr, Size});
    }

    void deregisterEHFrames() override {
#if defined(__APPLE__)
        if (!HookRanges.empty()) {
            if (auto err = llvm::orc::UnwindInfoManager::deregisterSections(HookRanges))
                llvm::consumeError(std::move(err));
            HookRanges.clear();
        }
#endif
        for (auto &F : EHFrames) {
            uint8_t *P = F.Addr;
            uint8_t *End = F.Addr + F.Size;
            while (P < End) {
                uint32_t length;
                memcpy(&length, P, 4);
                if (length == 0) break;
                size_t fullLen = 4 + length;
                if (length == 0xffffffff) {
                    uint64_t extLen;
                    memcpy(&extLen, P + 4, 8);
                    fullLen = 4 + 8 + extLen;
                }
                uint32_t ciePointer;
                memcpy(&ciePointer, P + 4, 4);
                if (ciePointer != 0)
                    __deregister_frame(P);
                P += fullLen;
            }
        }
        EHFrames.clear();
    }

private:
#if defined(__APPLE__)
    std::vector<llvm::orc::ExecutorAddrRange> HookRanges;
#endif

    static uint64_t uleb(const uint8_t*& p) {
        uint64_t v = 0;
        for (int sh = 0;; sh += 7) {
            const uint8_t b = *p++;
            v |= uint64_t(b & 0x7f) << sh;
            if (!(b & 0x80)) break;
        }
        return v;
    }

    // The code range [lo, hi) an FDE describes, decoded as libunwind reads it: the pointer
    // encoding comes from the CIE's 'R' augmentation (pc-relative on ELF and MachO).
    static void fdeCodeRange(const uint8_t* fde, uint32_t ciePointer, uint64_t& lo,
                             uint64_t& hi) {
        const uint8_t* p = fde + 4 - ciePointer + 8;   // the CIE, past its length and id
        const uint8_t version = *p++;
        const char* aug = reinterpret_cast<const char*>(p);
        p += std::strlen(aug) + 1;
        uleb(p);                                       // code alignment
        uleb(p);                                       // data alignment (an sleb: same length)
        if (version == 1) ++p; else uleb(p);           // return-address register
        uint8_t enc = 0;                               // DW_EH_PE_absptr
        if (aug[0] == 'z') {
            uleb(p);
            for (const char* a = aug + 1; *a; ++a) {
                if (*a == 'R') { enc = *p++; break; }
                if (*a == 'P') { const uint8_t pe = *p++; p += (pe & 0x0f) == 0x0b ? 4 : 8; }
                else if (*a == 'L') ++p;
            }
        }
        const uint8_t* f = fde + 8;
        auto read = [&](bool pcrel) -> uint64_t {
            const uint8_t* at = f;
            int64_t v = 0;
            switch (enc & 0x0f) {
                case 0x0b: { int32_t x; std::memcpy(&x, f, 4); v = x; f += 4; break; }
                case 0x03: { uint32_t x; std::memcpy(&x, f, 4); v = x; f += 4; break; }
                default:   { int64_t x; std::memcpy(&x, f, 8); v = x; f += 8; break; }
            }
            return pcrel && (enc & 0x70) == 0x10 ? uint64_t(reinterpret_cast<uintptr_t>(at) + v)
                                                 : uint64_t(v);
        };
        lo = read(true);
        hi = lo + read(false);
    }
};
#endif

} // anonymous namespace

namespace eco {

//===----------------------------------------------------------------------===//
// StackMapListener - extracts __LLVM_StackMaps from loaded objects
//===----------------------------------------------------------------------===//

// Reads the post-relocation bytes of a section out of its loaded memory,
// preferring them over the file-contents view returned by
// SectionRef::getContents(). RuntimeDyld applies relocations to loaded
// memory, not to the file bytes — critically for .llvm_stackmaps, which
// contains 64-bit function_address fields that are unrelocated (zero) in
// the file but correct at the load address after linking.
static std::vector<uint8_t>
readLoadedSectionBytes(const object::SectionRef &Section,
                       const RuntimeDyld::LoadedObjectInfo &L) {
    std::vector<uint8_t> out;
    uint64_t loadAddr = L.getSectionLoadAddress(Section);
    if (loadAddr != 0) {
        const uint8_t *ptr = reinterpret_cast<const uint8_t *>(loadAddr);
        out.assign(ptr, ptr + Section.getSize());
        return out;
    }
    // Fallback: use the file bytes.
    auto contentsOrErr = Section.getContents();
    if (contentsOrErr) {
        StringRef c = *contentsOrErr;
        out.assign(c.begin(), c.end());
    } else {
        consumeError(contentsOrErr.takeError());
    }
    return out;
}

class EcoJIT::StackMapListener : public JITEventListener {
public:
    explicit StackMapListener(StackMapData &smData)
        : smData_(smData) {}

    void notifyObjectLoaded(ObjectKey K, const object::ObjectFile &Obj,
                            const RuntimeDyld::LoadedObjectInfo &L) override {
        for (const auto &Section : Obj.sections()) {
            auto nameOrErr = Section.getName();
            if (!nameOrErr)
                continue;

            StringRef name = *nameOrErr;

            // ELF uses ".llvm_stackmaps", MachO uses "__llvm_stackmaps".
            // We read from the loaded section memory so that the 64-bit
            // function_address fields (emitted as relocations against each
            // JIT'd function) are their post-relocation absolute addresses.
            if (name == ".llvm_stackmaps" || name == "__llvm_stackmaps") {
                smData_.bytes = readLoadedSectionBytes(Section, L);
            }

            // .eh_frame registration lives in
            // EcoSectionMemoryManager::registerEHFrames (file-scope above),
            // not here — see the commentary on that class for rationale.
        }
    }

private:
    StackMapData &smData_;
};

//===----------------------------------------------------------------------===//
// Packed function wrappers (from MLIR ExecutionEngine)
//===----------------------------------------------------------------------===//

static std::string makePackedFunctionName(StringRef name) {
    return "_mlir_" + name.str();
}

/// For each non-declaration, non-local function, create a wrapper:
///   void _mlir_funcName(void** args)
/// that unpacks arguments from the void** array and calls the real function.
static void packFunctionArguments(Module *module) {
    auto &ctx = module->getContext();
    IRBuilder<> builder(ctx);
    DenseSet<Function *> interfaceFunctions;

    for (auto &func : module->getFunctionList()) {
        if (func.isDeclaration() || func.hasLocalLinkage())
            continue;
        if (interfaceFunctions.count(&func))
            continue;

        auto *newType = FunctionType::get(
            builder.getVoidTy(), builder.getPtrTy(), /*isVarArg=*/false);
        auto newName = makePackedFunctionName(func.getName());
        auto funcCst = module->getOrInsertFunction(newName, newType);
        auto *interfaceFunc = cast<Function>(funcCst.getCallee());
        interfaceFunctions.insert(interfaceFunc);

        auto *bb = BasicBlock::Create(ctx);
        bb->insertInto(interfaceFunc);
        builder.SetInsertPoint(bb);
        Value *argList = interfaceFunc->arg_begin();

        SmallVector<Value *, 8> args;
        args.reserve(size(func.args()));
        for (auto [index, arg] : enumerate(func.args())) {
            Value *argIndex = Constant::getIntegerValue(
                builder.getInt64Ty(), APInt(64, index));
            Value *argPtrPtr = builder.CreateGEP(
                builder.getPtrTy(), argList, argIndex);
            Value *argPtr = builder.CreateLoad(builder.getPtrTy(), argPtrPtr);
            Value *load = builder.CreateLoad(arg.getType(), argPtr);
            args.push_back(load);
        }

        Value *result = builder.CreateCall(&func, args);

        if (!result->getType()->isVoidTy()) {
            Value *retIndex = Constant::getIntegerValue(
                builder.getInt64Ty(), APInt(64, size(func.args())));
            Value *retPtrPtr = builder.CreateGEP(
                builder.getPtrTy(), argList, retIndex);
            Value *retPtr = builder.CreateLoad(builder.getPtrTy(), retPtrPtr);
            builder.CreateStore(result, retPtr);
        }

        builder.CreateRetVoid();
    }
}

//===----------------------------------------------------------------------===//
// EcoJIT implementation
//===----------------------------------------------------------------------===//

static Error makeStringError(const Twine &message) {
    return make_error<StringError>(message.str(), inconvertibleErrorCode());
}

EcoJIT::EcoJIT() = default;

EcoJIT::~EcoJIT() {
    if (jit_) {
        consumeError(jit_->deinitialize(jit_->getMainJITDylib()));
        // Destroy JIT before the listener to avoid dangling references
        jit_.reset();
    }
    stackMapListener_.reset();
}

Expected<std::unique_ptr<EcoJIT>>
EcoJIT::create(mlir::Operation *m, const EcoJITOptions &options) {
    auto engine = std::unique_ptr<EcoJIT>(new EcoJIT());

    // Create stack map listener (.eh_frame is handled by RTDyldMemoryManager)
    engine->stackMapListener_ =
        std::make_unique<StackMapListener>(engine->stackMapData_);

    // Translate MLIR to LLVM IR
    std::unique_ptr<LLVMContext> ctx(new LLVMContext);
    auto llvmModule = mlir::translateModuleToLLVMIR(m, *ctx);
    if (!llvmModule)
        return makeStringError("could not convert to LLVM IR");

    // Create target machine
    auto tmBuilderOrError = JITTargetMachineBuilder::detectHost();
    if (!tmBuilderOrError)
        return tmBuilderOrError.takeError();

#if defined(__APPLE__)
    // The GC finds stack roots by unwinding through JIT frames (libunwind +
    // stack maps), which needs every JIT function's unwind info registered.
    // MachO describes most functions with compact unwind, which RuntimeDyld
    // never registers; only __eh_frame reaches registerEHFrames above. Emit a
    // DWARF FDE for every function so the walk does not stop at the first JIT
    // frame (it did: 0 stack roots found, so deep recursions kept stale
    // pointers across minor GCs).
    tmBuilderOrError->getOptions().MCOptions.EmitDwarfUnwind =
        llvm::EmitDwarfUnwindType::Always;
#endif

    auto tmOrError = tmBuilderOrError->createTargetMachine();
    if (!tmOrError)
        return tmOrError.takeError();

    auto tm = std::move(tmOrError.get());
    setupTargetTripleAndDataLayout(llvmModule.get(), tm.get());
    packFunctionArguments(llvmModule.get());

    auto dataLayout = llvmModule->getDataLayout();

    // Object linking layer creator — installs our custom memory manager so
    // JIT .eh_frame is registered section-style, and registers our stack map
    // listener.
    auto objectLinkingLayerCreator =
        [&engine](ExecutionSession &session) {
            auto objectLayer = std::make_unique<RTDyldObjectLinkingLayer>(
                session, [](const MemoryBuffer &) {
                    return std::make_unique<EcoSectionMemoryManager>();
                });

            // Register our stack map extraction listener
            objectLayer->registerJITEventListener(
                *engine->stackMapListener_);

            return objectLayer;
        };

    // Compile function creator
    auto compileFunctionCreator =
        [&options, &tm](JITTargetMachineBuilder jtmb)
            -> Expected<std::unique_ptr<IRCompileLayer::IRCompiler>> {
            if (options.jitCodeGenOptLevel)
                jtmb.setCodeGenOptLevel(*options.jitCodeGenOptLevel);
            return std::make_unique<TMOwningSimpleCompiler>(std::move(tm));
        };

    // Build the LLJIT
    auto jit = cantFail(LLJITBuilder()
                            .setCompileFunctionCreator(compileFunctionCreator)
                            .setObjectLinkingLayerCreator(objectLinkingLayerCreator)
                            .setDataLayout(dataLayout)
                            .create());

    // Apply transformer (statepoint conversion + optimization)
    ThreadSafeModule tsm(std::move(llvmModule), std::move(ctx));
    if (options.transformer)
        cantFail(tsm.withModuleDo(
            [&](Module &module) { return options.transformer(&module); }));
    cantFail(jit->addIRModule(std::move(tsm)));
    engine->jit_ = std::move(jit);

    // Resolve symbols from the current process
    JITDylib &mainJD = engine->jit_->getMainJITDylib();
    mainJD.addGenerator(
        cantFail(DynamicLibrarySearchGenerator::GetForCurrentProcess(
            dataLayout.getGlobalPrefix())));

    return std::move(engine);
}

void EcoJIT::setupTargetTripleAndDataLayout(Module *llvmModule,
                                            TargetMachine *tm) {
    llvmModule->setDataLayout(tm->createDataLayout());
    llvmModule->setTargetTriple(tm->getTargetTriple());
}

Expected<void *> EcoJIT::lookup(StringRef name) const {
    auto expectedSymbol = jit_->lookup(name);
    if (!expectedSymbol) {
        std::string errorMessage;
        raw_string_ostream os(errorMessage);
        handleAllErrors(expectedSymbol.takeError(),
                        [&os](ErrorInfoBase &ei) { ei.log(os); });
        return makeStringError(errorMessage);
    }
    if (void *fptr = expectedSymbol->toPtr<void *>()) {
#if !defined(_WIN32)
        // TEMP(diag) (plans/ci-all-platforms-green.md issue 8): can libunwind find this JIT
        // function's FDE?
        alignas(16) char diagBases[64] = {};  // dwarf_eh_bases: three pointers
        if (std::getenv("ECO_TEST_STACKWALK_DIAG"))
            std::fprintf(stderr, "[diag-ehframe] lookup %s at %p: _Unwind_Find_FDE -> %p\n",
                         name.str().c_str(), fptr,
                         _Unwind_Find_FDE(static_cast<char*>(fptr) + 4,
                                          reinterpret_cast<dwarf_eh_bases*>(diagBases)));
#endif
        return fptr;
    }
    return makeStringError("looked up function is null");
}

Expected<void (*)(void **)> EcoJIT::lookupPacked(StringRef name) const {
    auto result = lookup(makePackedFunctionName(name));
    if (!result)
        return result.takeError();
    return reinterpret_cast<void (*)(void **)>(result.get());
}

void EcoJIT::initialize() {
    if (isInitialized_)
        return;
    cantFail(jit_->initialize(jit_->getMainJITDylib()));
    isInitialized_ = true;
}

Error EcoJIT::invokePacked(StringRef name, MutableArrayRef<void *> args) {
    initialize();
    auto expectedFPtr = lookupPacked(name);
    if (!expectedFPtr)
        return expectedFPtr.takeError();
    auto fptr = *expectedFPtr;
    (*fptr)(args.data());
    return Error::success();
}

void EcoJIT::registerSymbols(
    function_ref<SymbolMap(MangleAndInterner)> symbolMap) {
    auto &mainJD = jit_->getMainJITDylib();
    cantFail(mainJD.define(
        absoluteSymbols(symbolMap(MangleAndInterner(
            mainJD.getExecutionSession(), jit_->getDataLayout())))));
}

} // namespace eco
