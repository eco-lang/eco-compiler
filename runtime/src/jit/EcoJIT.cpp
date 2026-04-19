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

// Declared at file scope — not inside namespace eco or the anonymous
// namespace below — so these resolve against the C entry points exported
// by LLVM libunwind (libgcc-compatible). Nested extern "C" inside a class
// would create class members; inside a namespace it would still be C linkage
// but clutters the lookup path.
extern "C" void __register_frame(void *);
extern "C" void __deregister_frame(void *);

namespace {

// EcoSectionMemoryManager overrides EH-frame registration so that we hand
// LLVM libunwind the whole .eh_frame block at once, matching its section-style
// API. (a) The stock SectionMemoryManager inherits RTDyldMemoryManager's
// registerEHFrames, which walks the block and calls __register_frame once per
// FDE. LLVM libunwind treats each such call as a malformed section and rejects
// it with "bad fde: FDE is really a CIE", so JIT frames were never registered
// — breaking libunwind-based GC stack walks of JIT code. (b) Passing the
// section base address once gives libunwind a well-formed CIE+FDEs chain, as
// it already expects for dlopen'd sections. (c) ORC's RTDyldObjectLinkingLayer
// guarantees that each (Addr, Size) handed to registerEHFrames is handed back
// via deregisterEHFrames on teardown; we record them in the base class's
// EHFrames vector and replay them in order.
class EcoSectionMemoryManager : public llvm::SectionMemoryManager {
public:
    void registerEHFrames(uint8_t *Addr, uint64_t /*LoadAddr*/,
                          size_t Size) override {
        if (!Addr || Size == 0)
            return;
        __register_frame(Addr);
        EHFrames.push_back({Addr, Size});
    }

    void deregisterEHFrames() override {
        for (auto &F : EHFrames)
            __deregister_frame(F.Addr);
        EHFrames.clear();
    }
};

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
