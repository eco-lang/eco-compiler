//===- EcoJIT.cpp - JIT execution engine with stack map support -----------===//
//
// Custom JIT execution engine for Eco, derived from MLIR's ExecutionEngine.
// Adds JITEventListener to extract __LLVM_StackMaps from JIT'd object code.
//
// Original: mlir/lib/ExecutionEngine/ExecutionEngine.cpp
// License:  Apache License v2.0 with LLVM Exceptions (SPDX: Apache-2.0)
//
//===----------------------------------------------------------------------===//

#include "EcoJIT.h"

#include <mutex>
#include <unordered_map>
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
#include "llvm/IR/IRBuilder.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Support/Error.h"
#include "llvm/TargetParser/Host.h"

using namespace llvm;
using namespace llvm::orc;

// The unwinder's entry points for adding and removing one FDE, declared at
// file scope so that they name the C functions and not members of a namespace.
#if !defined(_WIN32)
extern "C" void __register_frame(void *);
extern "C" void __deregister_frame(void *);
#endif

namespace {

#if defined(_WIN32)
// The memory manager for JIT objects on Windows, which registers no
// `.eh_frame`. JIT code there is COFF, unwound through its `.pdata` and
// `.xdata` sections, and this relies on RuntimeDyld registering those itself.
class EcoSectionMemoryManager : public llvm::SectionMemoryManager {
public:
    void registerEHFrames(uint8_t* /*Addr*/, uint64_t /*LoadAddr*/,
                          size_t /*Size*/) override {}
    void deregisterEHFrames() override {}
};
#else
#if defined(__APPLE__)
// RuntimeDyldMachO::registerEHFrames moves every FDE's pc_begin by -DeltaForText (processFDE: the
// change in distance between __text and __eh_frame from object file to memory). That is right for
// objects whose __eh_frame pc_begin carries no relocation (x86-64 MachO), but on arm64 MachO the
// pc_begin is relocated to the final address first, so the move shifts every FDE's range off its
// function: libunwind then finds no unwind info for JIT code, the GC's stack walk stops at the
// first JIT frame, and no JIT stack root is ever updated. recordEhFrameDelta (NotifyLoaded, after
// placement and before registerEHFrames) recomputes the delta per __eh_frame load address, and
// registerEHFrames adds it back.

// Guards `g_ehFrameDelta`, which load notifications and EH-frame registration
// both touch.
std::mutex g_ehFrameDeltaMu;
// The delta to add back to each FDE's pc_begin, keyed by the load address of
// the `__eh_frame` section it applies to. An entry is removed when used.
std::unordered_map<uint64_t, int64_t> g_ehFrameDelta;

// Records, for the `__eh_frame` section of `Obj`, how far the distance from
// `__text` to `__eh_frame` changed between the object file and memory. Does
// nothing unless both sections exist and `__eh_frame` has a load address.
void recordEhFrameDelta(const llvm::object::ObjectFile &Obj,
                        const llvm::RuntimeDyld::LoadedObjectInfo &Info) {
    bool haveText = false, haveEH = false;
    int64_t textObj = 0, ehObj = 0, textLoad = 0, ehLoad = 0;
    for (const llvm::object::SectionRef &Sec : Obj.sections()) {
        auto Name = Sec.getName();
        if (!Name) {
            llvm::consumeError(Name.takeError());
            continue;
        }
        if (*Name == "__text") {
            textObj = static_cast<int64_t>(Sec.getAddress());
            textLoad = static_cast<int64_t>(Info.getSectionLoadAddress(Sec));
            haveText = true;
        } else if (*Name == "__eh_frame") {
            ehObj = static_cast<int64_t>(Sec.getAddress());
            ehLoad = static_cast<int64_t>(Info.getSectionLoadAddress(Sec));
            haveEH = true;
        }
    }
    if (!haveText || !haveEH || ehLoad == 0)
        return;
    std::lock_guard<std::mutex> Lock(g_ehFrameDeltaMu);
    g_ehFrameDelta[static_cast<uint64_t>(ehLoad)] = (textObj - ehObj) - (textLoad - ehLoad);
}

// Returns and forgets the delta recorded for the `__eh_frame` loaded at
// `ehLoad`, or 0 if none was recorded.
int64_t takeEhFrameDelta(uint64_t ehLoad) {
    std::lock_guard<std::mutex> Lock(g_ehFrameDeltaMu);
    auto It = g_ehFrameDelta.find(ehLoad);
    if (It == g_ehFrameDelta.end())
        return 0;
    const int64_t Delta = It->second;
    g_ehFrameDelta.erase(It);
    return Delta;
}

// Adds `Delta` to the 8-byte pc_begin field of every FDE in the `Size` bytes
// of `.eh_frame` at `Addr`. Stops at a zero length or an extended (64-bit)
// length.
void undoProcessFdeShift(uint8_t *Addr, size_t Size, int64_t Delta) {
    for (uint8_t *P = Addr; P + 8 <= Addr + Size;) {
        uint32_t Length;
        memcpy(&Length, P, 4);
        if (Length == 0 || Length == 0xffffffff)
            break;
        uint32_t CiePointer;
        memcpy(&CiePointer, P + 4, 4);
        if (CiePointer != 0 && P + 16 <= Addr + Size) {
            uint64_t PcBegin;
            memcpy(&PcBegin, P + 8, 8);
            PcBegin += static_cast<uint64_t>(Delta);
            memcpy(P + 8, &PcBegin, 8);
        }
        P += 4 + static_cast<size_t>(Length);
    }
}
#endif

// The memory manager for JIT objects on POSIX hosts, which registers each
// FDE of an object's `.eh_frame` with the unwinder.
//
// LLVM libunwind's `__register_frame` takes a pointer to one FDE. A
// `.eh_frame` section begins with a CIE, so passing the section base
// registers nothing. `registerEHFrames` therefore walks the section, calling
// `__register_frame` for each record whose CIE pointer is non-zero, and
// keeps the section's address and size. `deregisterEHFrames` walks every
// kept section again, in the same forward order, calling
// `__deregister_frame` for the same records.
class EcoSectionMemoryManager : public llvm::SectionMemoryManager {
public:
    void registerEHFrames(uint8_t *Addr, uint64_t LoadAddr,
                          size_t Size) override {
        if (!Addr || Size == 0)
            return;
#if defined(__APPLE__)
        if (const int64_t Delta = takeEhFrameDelta(LoadAddr))
            undoProcessFdeShift(Addr, Size, Delta);
#else
        (void)LoadAddr;
#endif
        uint8_t *P = Addr;
        uint8_t *End = Addr + Size;
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
            if (ciePointer != 0)
                __register_frame(P);
            P += fullLen;
        }
        EHFrames.push_back({Addr, Size});
    }

    void deregisterEHFrames() override {
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
};
#endif

} // anonymous namespace

namespace eco {

//===----------------------------------------------------------------------===//
// StackMapListener - extracts __LLVM_StackMaps from loaded objects
//===----------------------------------------------------------------------===//

// Returns a copy of the bytes of `Section` as they stand in loaded memory,
// after relocation. If the section has no load address, returns its bytes
// from the object file instead, which are unrelocated, or nothing if those
// cannot be read either.
//
// The loaded bytes matter for a stack map section: its 64-bit function
// addresses are relocations, unresolved in the file.
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

// A listener on object loading that copies each loaded object's stack map
// section into a `StackMapData`, replacing what it held. It refers to that
// `StackMapData`, which must outlive it.
class EcoJIT::StackMapListener : public JITEventListener {
public:
    // Creates a listener that writes into `smData`, which it keeps.
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
            if (name == ".llvm_stackmaps" || name == "__llvm_stackmaps") {
                smData_.bytes = readLoadedSectionBytes(Section, L);
            }
        }
    }

private:
    // The engine's `StackMapData`, owned by the engine.
    StackMapData &smData_;
};

//===----------------------------------------------------------------------===//
// Packed function wrappers (from MLIR ExecutionEngine)
//===----------------------------------------------------------------------===//

// Returns the name of the packed wrapper for the function `name`.
static std::string makePackedFunctionName(StringRef name) {
    return "_mlir_" + name.str();
}

// Adds to `module`, for each function it defines without local linkage, a
// wrapper `void _mlir_<name>(void **args)`. The wrapper loads argument `i`
// through `args[i]`, calls the function, and, if it returns a value, stores
// the result through `args[n]`, where `n` is the number of arguments.
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

// Returns an error carrying `message`, with no error code.
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

    engine->stackMapListener_ =
        std::make_unique<StackMapListener>(engine->stackMapData_);

    std::unique_ptr<LLVMContext> ctx(new LLVMContext);
    auto llvmModule = mlir::translateModuleToLLVMIR(m, *ctx);
    if (!llvmModule)
        return makeStringError("could not convert to LLVM IR");

    auto tmBuilderOrError = JITTargetMachineBuilder::detectHost();
    if (!tmBuilderOrError)
        return tmBuilderOrError.takeError();

#if defined(__APPLE__)
    // The GC finds stack roots by unwinding through JIT frames (libunwind + stack maps), which
    // needs every JIT function's unwind info registered. arm64 MachO describes most functions
    // with compact unwind, which RuntimeDyld never registers (only __eh_frame reaches
    // registerEHFrames above), so emit a DWARF FDE for every function.
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

    // Each object gets an `EcoSectionMemoryManager`, which on POSIX hosts
    // registers its `.eh_frame`, and the stack map listener sees every object
    // loaded.
    auto objectLinkingLayerCreator =
        [&engine](ExecutionSession &session) {
            auto objectLayer = std::make_unique<RTDyldObjectLinkingLayer>(
                session, [](const MemoryBuffer &) {
                    return std::make_unique<EcoSectionMemoryManager>();
                });

            objectLayer->registerJITEventListener(
                *engine->stackMapListener_);
#if defined(__APPLE__)
            objectLayer->setNotifyLoaded(
                [](MaterializationResponsibility &, const object::ObjectFile &Obj,
                   const RuntimeDyld::LoadedObjectInfo &Info) {
                    recordEhFrameDelta(Obj, Info);
                });
#endif

            return objectLayer;
        };

    // The compiler uses `tm`, made above, so the optimisation level set on
    // `jtmb` does not reach it.
    auto compileFunctionCreator =
        [&options, &tm](JITTargetMachineBuilder jtmb)
            -> Expected<std::unique_ptr<IRCompileLayer::IRCompiler>> {
            if (options.jitCodeGenOptLevel)
                jtmb.setCodeGenOptLevel(*options.jitCodeGenOptLevel);
            return std::make_unique<TMOwningSimpleCompiler>(std::move(tm));
        };

    auto jit = cantFail(LLJITBuilder()
                            .setCompileFunctionCreator(compileFunctionCreator)
                            .setObjectLinkingLayerCreator(objectLinkingLayerCreator)
                            .setDataLayout(dataLayout)
                            .create());

    ThreadSafeModule tsm(std::move(llvmModule), std::move(ctx));
    if (options.transformer)
        cantFail(tsm.withModuleDo(
            [&](Module &module) { return options.transformer(&module); }));
    cantFail(jit->addIRModule(std::move(tsm)));
    engine->jit_ = std::move(jit);

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
    if (void *fptr = expectedSymbol->toPtr<void *>())
        return fptr;
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
