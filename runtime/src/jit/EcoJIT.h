//===- EcoJIT.h - JIT execution engine with stack map support -------------===//
//
// Custom JIT execution engine for Eco, derived from MLIR's ExecutionEngine.
// Adds JITEventListener support to extract __LLVM_StackMaps from JIT'd code.
//
// Original: mlir/lib/ExecutionEngine/ExecutionEngine.cpp
// License:  Apache License v2.0 with LLVM Exceptions (SPDX: Apache-2.0)
//
//===----------------------------------------------------------------------===//

#ifndef ECO_JIT_H
#define ECO_JIT_H

#include "llvm/ExecutionEngine/ObjectCache.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"
#include "llvm/ExecutionEngine/SectionMemoryManager.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Support/Error.h"

#include <functional>
#include <memory>
#include <optional>
#include <vector>

namespace mlir {
class Operation;
}

namespace eco {

//===----------------------------------------------------------------------===//
// Stack Map Data
//===----------------------------------------------------------------------===//

/// Holds raw stack map bytes extracted from JIT'd objects.
/// The data is copied from the __LLVM_StackMaps section of each loaded object.
struct StackMapData {
    std::vector<uint8_t> bytes;

    const uint8_t *data() const { return bytes.data(); }
    size_t size() const { return bytes.size(); }
    bool empty() const { return bytes.empty(); }
};

//===----------------------------------------------------------------------===//
// EcoJIT Options
//===----------------------------------------------------------------------===//

struct EcoJITOptions {
    /// If provided, called on the LLVM module after MLIR→LLVM IR translation.
    /// Used for statepoint conversion and optimization.
    llvm::function_ref<llvm::Error(llvm::Module *)> transformer = {};

    /// Optimization level for code generation.
    std::optional<llvm::CodeGenOptLevel> jitCodeGenOptLevel;
};

//===----------------------------------------------------------------------===//
// EcoJIT
//===----------------------------------------------------------------------===//

/// JIT execution engine for Eco with stack map extraction.
///
/// Based on MLIR's ExecutionEngine but exposes JIT internals needed for
/// GC root discovery. Specifically, registers a JITEventListener that
/// captures the __LLVM_StackMaps section from compiled objects.
class EcoJIT {
public:
    ~EcoJIT();

    /// Creates a JIT engine from an MLIR module (must be in LLVM dialect).
    static llvm::Expected<std::unique_ptr<EcoJIT>>
    create(mlir::Operation *op, const EcoJITOptions &options = {});

    /// Look up a symbol by name. Returns its address.
    llvm::Expected<void *> lookup(llvm::StringRef name) const;

    /// Look up a packed-argument wrapper function.
    llvm::Expected<void (*)(void **)> lookupPacked(llvm::StringRef name) const;

    /// Invoke a function via its packed wrapper.
    llvm::Error invokePacked(llvm::StringRef name,
                             llvm::MutableArrayRef<void *> args = {});

    /// Register symbols (e.g., runtime function addresses).
    void registerSymbols(
        llvm::function_ref<llvm::orc::SymbolMap(llvm::orc::MangleAndInterner)>
            symbolMap);

    /// Set target triple and data layout on an LLVM module.
    static void setupTargetTripleAndDataLayout(llvm::Module *llvmModule,
                                               llvm::TargetMachine *tm);

    /// Access the extracted stack map data.
    /// Valid after the first symbol lookup triggers compilation.
    const StackMapData &getStackMapData() const { return stackMapData_; }

private:
    EcoJIT();

    void initialize();

    /// Underlying LLJIT (owned).
    std::unique_ptr<llvm::orc::LLJIT> jit_;

    /// Stack map data extracted from JIT'd objects.
    StackMapData stackMapData_;

    /// JIT event listener for stack map extraction (raw pointer, registered
    /// with the object layer which does not take ownership).
    class StackMapListener;
    std::unique_ptr<StackMapListener> stackMapListener_;

    bool isInitialized_ = false;
};

} // namespace eco

#endif // ECO_JIT_H
