//===- UndefinedFunction.cpp - Validate no undefined function references ===//
//
// A direct `eco.call` names its callee by symbol, and a name that the module
// neither defines nor declares would reach LLVM as an undefined symbol. This
// pass is the check for that: invariant CGEN_011 says no such name may leave
// MLIR codegen.
//
// A function counts as defined or declared only if it is a `func.func` directly
// in the module body. A `func.func` inside a nested op, and an `llvm.func` at
// any level, do not count. Every `eco.call` in the module, at any depth, is
// checked. An `eco.call` with no `callee` attribute is an indirect call through
// a closure and is skipped, and no other op that names a function is looked
// at.
//
// The check is on names only. Whether a call matches the callee's signature is
// checked by `CallOp::verifySymbolUses`, not here, and the pass adds no
// declarations.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallVector.h"

using namespace mlir;
using namespace ::eco;

namespace {

/// The module pass that reports direct `eco.call` callees missing from the
/// module.
struct UndefinedFunctionPass
    : public PassWrapper<UndefinedFunctionPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(UndefinedFunctionPass)

    StringRef getArgument() const override { return "eco-undefined-function"; }

    StringRef getDescription() const override {
        return "Validate all called functions are defined or declared (CGEN_011)";
    }

    /// Emits one error per callee name that is not a top-level `func.func`,
    /// at the first call to it, and fails the pass if there was any. The module
    /// is not changed.
    void runOnOperation() override {
        ModuleOp module = getOperation();

        // Only the module body's own ops are scanned, not a recursive walk.
        // Names are uniqued StringAttrs, so the set compares them by pointer.
        llvm::DenseSet<StringAttr> definedFunctions;
        for (auto funcOp : module.getBody()->getOps<func::FuncOp>())
            definedFunctions.insert(funcOp.getSymNameAttr());

        // A missing callee and the location of the first call to it found.
        struct UndefinedCall {
            StringAttr name;
            Location loc;
        };
        llvm::SmallVector<UndefinedCall, 4> undefinedCalls;
        llvm::DenseSet<StringAttr> reportedFunctions;

        module.walk([&](CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr)
                return;

            StringAttr calleeName = calleeAttr.getAttr();
            if (!definedFunctions.contains(calleeName)) {
                // Each missing name is reported once, at the first call the
                // walk reaches; later calls to it are not recorded.
                if (reportedFunctions.insert(calleeName).second)
                    undefinedCalls.push_back({calleeName, callOp.getLoc()});
            }
        });

        if (!undefinedCalls.empty()) {
            for (const auto &call : undefinedCalls) {
                emitError(call.loc) << "undefined function: " << call.name.getValue()
                    << " (CGEN_011 violation: MLIR codegen must generate all "
                    << "function declarations before this pass)";
            }
            signalPassFailure();
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createUndefinedFunctionPass() {
    return std::make_unique<UndefinedFunctionPass>();
}
