//===- CheckEcoClosureCaptures.cpp - Verify closure capture integrity -----===//
//
// This pass enforces CGEN_CLOSURE_003 at the MLIR level with two checks:
//
// 1. For each eco.papCreate: verify num_captured and captured operand types
//    are consistent with the referenced function's signature.
//
// 2. For each lambda func.func (name matching *_lambda_*): verify no SSA
//    value used in the body was defined in a different func.func. This catches
//    cross-function SSA leakage from incomplete closure captures.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include <string>

using namespace mlir;
using namespace eco;

namespace {

struct CheckEcoClosureCapturesPass
    : public PassWrapper<CheckEcoClosureCapturesPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(CheckEcoClosureCapturesPass)

    StringRef getArgument() const override {
        return "eco-check-closure-captures";
    }

    StringRef getDescription() const override {
        return "Verify closure capture integrity: papCreate consistency and "
               "no cross-function SSA references (CGEN_CLOSURE_003)";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        bool hasErrors = false;

        // === Phase 1: Validate eco.papCreate ops ===
        module.walk([&](PapCreateOp createOp) {
            int64_t numCaptured = createOp.getNumCaptured();
            auto funcSym = createOp.getFunctionAttr();

            // Resolve the referenced function
            auto funcOp = module.lookupSymbol<func::FuncOp>(funcSym.getValue());
            if (!funcOp)
                return; // External/undeclared — UndefinedFunction pass handles this

            auto funcType = funcOp.getFunctionType();
            auto paramTypes = funcType.getInputs();

            // Check function has at least num_captured parameters
            if (static_cast<int64_t>(paramTypes.size()) < numCaptured) {
                createOp.emitError()
                    << "CGEN_CLOSURE_003: eco.papCreate num_captured ("
                    << numCaptured << ") exceeds target function '"
                    << funcSym.getValue() << "' parameter count ("
                    << paramTypes.size() << ")";
                hasErrors = true;
                return;
            }

            // Check captured operand types match first num_captured params
            auto captured = createOp.getCaptured();
            for (size_t i = 0; i < captured.size(); ++i) {
                Type actualTy = captured[i].getType();
                Type expectedTy = paramTypes[i];
                if (actualTy != expectedTy) {
                    createOp.emitError()
                        << "CGEN_CLOSURE_003: captured operand " << i
                        << " has type " << actualTy
                        << " but target function '" << funcSym.getValue()
                        << "' expects " << expectedTy << " at parameter " << i;
                    hasErrors = true;
                }
            }
        });

        // === Phase 2: Validate lambda func.func SSA integrity ===
        module.walk([&](func::FuncOp funcOp) {
            // Only check lambda functions (naming convention: *_lambda_*)
            StringRef funcName = funcOp.getSymName();
            if (!funcName.contains("_lambda_"))
                return;

            // Walk every operation in the lambda body
            funcOp.walk([&](Operation *op) {
                for (Value operand : op->getOperands()) {
                    // Block arguments: verify the block is within this function
                    if (auto blockArg = dyn_cast<BlockArgument>(operand)) {
                        Operation *parentOp = blockArg.getOwner()->getParentOp();
                        if (!funcOp->isAncestor(parentOp) &&
                            parentOp != funcOp.getOperation()) {
                            op->emitError()
                                << "CGEN_CLOSURE_003: lambda '" << funcName
                                << "' uses block argument from outside function"
                                << " — likely a missing closure capture";
                            hasErrors = true;
                        }
                        continue;
                    }

                    // Op-defined values: check defining op is inside this func
                    Operation *defOp = operand.getDefiningOp();
                    if (defOp &&
                        !funcOp->isAncestor(defOp) &&
                        defOp != funcOp.getOperation()) {
                        auto outerFunc =
                            defOp->getParentOfType<func::FuncOp>();
                        StringRef outerName =
                            outerFunc ? outerFunc.getSymName() : "<unknown>";
                        op->emitError()
                            << "CGEN_CLOSURE_003: lambda '" << funcName
                            << "' uses value defined in '" << outerName
                            << "' — likely a missing closure capture";
                        hasErrors = true;
                    }
                }
            });
        });

        if (hasErrors)
            signalPassFailure();
    }
};

} // namespace

std::unique_ptr<Pass> eco::createCheckEcoClosureCapturesPass() {
    return std::make_unique<CheckEcoClosureCapturesPass>();
}
