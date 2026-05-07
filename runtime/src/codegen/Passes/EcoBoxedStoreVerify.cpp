//===- EcoBoxedStoreVerify.cpp - Boxed-slot direct-store stale-HPointer barrier ===//
//
// Walks LLVM dialect StoreOps marked with the `eco.boxed_slot` UnitAttr
// (attached during eco.array.set lowering for the only direct LLVM store
// of a boxed value emitted from compiled Elm) and inserts a call to
// `eco_validate_nursery_hptr_bits(value)` immediately before each store.
//
// The runtime validator routes the bits through Allocator::resolve, which
// classifies any HPointer landing in the just-evacuated from-space (poisoned
// to 0xDD by NurserySpace::poisonOldFromSpaceUsedRegion) as stale and aborts
// with debugAssertValidNurseryPointer diagnostics. Because the call is
// inserted at the IR site of the store, the trip backtrace names the
// compiled-Elm function that wrote the bad pointer — localising the WRITE,
// where the previously-installed read-side detector and runtime-helper
// hooks only saw the read of an already-corrupted slot.
//
// Gated by ECO_LOWERING_VALIDATION (the usual compile-time switch for
// verification-only passes; matches EcoPtrIntVerify and the GC liveness
// audit). With the flag off the pass is a no-op.
//
// Pipeline placement: any time after EcoToLLVM has produced LLVM dialect
// (the marker attribute is attached there); the pass is wired in
// EcoPipeline.cpp immediately after createEcoToLLVMPass.
//
//===----------------------------------------------------------------------===//

#include "../Passes.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;

namespace {

struct EcoBoxedStoreVerifyPass
    : public PassWrapper<EcoBoxedStoreVerifyPass, OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoBoxedStoreVerifyPass)

    StringRef getArgument() const override {
        return "eco-boxed-store-verify";
    }
    StringRef getDescription() const override {
        return "Insert eco_validate_nursery_hptr_bits before LLVM StoreOps "
               "marked with eco.boxed_slot (debug-only barrier on direct "
               "compiled-Elm boxed-slot stores)";
    }

    void runOnOperation() override {
#ifndef ECO_LOWERING_VALIDATION
        return;
#else
        ModuleOp module = getOperation();
        MLIRContext *ctx = module.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);
        StringRef fnName = "eco_validate_nursery_hptr_bits";

        // Collect tagged stores first; we mutate the IR by inserting calls,
        // so walking and editing in one pass is fragile.
        SmallVector<LLVM::StoreOp> targets;
        module.walk([&](LLVM::StoreOp store) {
            if (store->hasAttr("eco.boxed_slot"))
                targets.push_back(store);
        });

        if (targets.empty())
            return;

        // Look up or declare the validator function symbol once.
        auto validatorFn = module.lookupSymbol<LLVM::LLVMFuncOp>(fnName);
        if (!validatorFn) {
            OpBuilder builder(module.getBodyRegion());
            builder.setInsertionPointToStart(module.getBody());
            auto fnTy = LLVM::LLVMFunctionType::get(voidTy, {i64Ty});
            validatorFn = builder.create<LLVM::LLVMFuncOp>(
                module.getLoc(), fnName, fnTy);
        }

        for (auto store : targets) {
            Value value = store.getValue();
            // The marker is only attached when the stored value is the i64
            // representation of an HPointer (post-heapStoreValueToI64). Skip
            // anything else defensively — the only way it could differ would
            // be a future lowering change that mis-tags the store.
            if (!value.getType().isInteger(64))
                continue;

            OpBuilder builder(store);
            builder.create<LLVM::CallOp>(store.getLoc(), validatorFn,
                                         ValueRange{value});
        }
#endif
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoBoxedStoreVerifyPass() {
    return std::make_unique<EcoBoxedStoreVerifyPass>();
}
