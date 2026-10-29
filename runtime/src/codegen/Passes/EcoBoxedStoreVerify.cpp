//===- EcoBoxedStoreVerify.cpp - Boxed-slot direct-store stale-HPointer barrier ===//
//
// A validation pass that makes a stale nursery HPointer fail at the compiled-Elm
// store that writes it, rather than at some later read of the corrupted slot.
//
// Some lowerings store a boxed value into a heap slot directly with `llvm.store`,
// and mark that store with the unit attribute `eco.boxed_slot`: the boxed element
// store of `eco.array.set` and the boxed field stores of a freshly allocated
// object. The stored value is then the i64 form of an HPointer.
//
// For each such store of an i64, this pass inserts, just before it, a call
// `eco_validate_nursery_hptr_bits(value)`, declaring that function as
// `void(i64)` if the module does not already have it. Because the call sits at
// the store, a failing check's backtrace names the compiled function that wrote
// the pointer. What the check does is `alloc::validateNurseryHPtrBits`'s
// contract; it does anything only in a runtime built with ECO_HEAP_VALIDATE.
//
// The pass reads an attribute that later passes may drop, so it must run while
// the stores still carry it. The attribute is left on the stores.
//
//===----------------------------------------------------------------------===//

#include "../Passes.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;

namespace {

/**
 * The pass that puts a stale-HPointer check in front of each boxed-slot store.
 *
 * It does nothing unless this file is built with ECO_LOWERING_VALIDATION.
 */
struct EcoBoxedStoreVerifyPass
    : public PassWrapper<EcoBoxedStoreVerifyPass, OperationPass<ModuleOp>> {

    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoBoxedStoreVerifyPass)

    // Returns the pass's command-line name.
    StringRef getArgument() const override {
        return "eco-boxed-store-verify";
    }
    // Returns the pass's one-line help text.
    StringRef getDescription() const override {
        return "Insert eco_validate_nursery_hptr_bits before LLVM StoreOps "
               "marked with eco.boxed_slot (debug-only barrier on direct "
               "compiled-Elm boxed-slot stores)";
    }

    // Inserts the validator call before every tagged store in the module whose
    // value is an i64. A tagged store of any other type gets no call.
    void runOnOperation() override {
#ifndef ECO_LOWERING_VALIDATION
        return;
#else
        ModuleOp module = getOperation();
        MLIRContext *ctx = module.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);
        StringRef fnName = "eco_validate_nursery_hptr_bits";

        // Collected first, because inserting calls during the walk would edit
        // the IR being walked.
        SmallVector<LLVM::StoreOp> targets;
        module.walk([&](LLVM::StoreOp store) {
            if (store->hasAttr("eco.boxed_slot"))
                targets.push_back(store);
        });

        if (targets.empty())
            return;

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
            // The taggers store the i64 from heapStoreValueToI64; anything else
            // would be a mis-tagged store, and is skipped.
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

// Contract on the declaration in Passes.h.
std::unique_ptr<Pass> eco::createEcoBoxedStoreVerifyPass() {
    return std::make_unique<EcoBoxedStoreVerifyPass>();
}
