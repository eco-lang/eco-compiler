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

    /// Verify one closure-binding site against its callee signature:
    ///   - num_captured must not exceed the callee's parameter count
    ///   - per-slot capture types must match the callee's first
    ///     num_captured parameter types (non-sibling slots only; sibling
    ///     cross-edge slots do not appear as SSA operands).
    /// Returns true on success; emits a diagnostic on the given op and
    /// returns false on mismatch. `context` disambiguates which op kind
    /// is being checked in the error message.
    static bool checkCalleeShape(
            Operation *op,
            ModuleOp module,
            StringRef context,
            FlatSymbolRefAttr funcSym,
            int64_t numCaptured,
            ArrayRef<Type> capturedTypes) {
        auto funcOp = module.lookupSymbol<func::FuncOp>(funcSym.getValue());
        if (!funcOp)
            return true; // External/undeclared — UndefinedFunction pass handles this

        auto funcType = funcOp.getFunctionType();
        auto paramTypes = funcType.getInputs();

        if (static_cast<int64_t>(paramTypes.size()) < numCaptured) {
            op->emitError()
                << "CGEN_CLOSURE_003: " << context << " num_captured ("
                << numCaptured << ") exceeds target function '"
                << funcSym.getValue() << "' parameter count ("
                << paramTypes.size() << ")";
            return false;
        }

        for (size_t i = 0; i < capturedTypes.size(); ++i) {
            Type actualTy = capturedTypes[i];
            Type expectedTy = paramTypes[i];
            if (actualTy != expectedTy) {
                op->emitError()
                    << "CGEN_CLOSURE_003: " << context << " captured operand " << i
                    << " has type " << actualTy
                    << " but target function '" << funcSym.getValue()
                    << "' expects " << expectedTy << " at parameter " << i;
                return false;
            }
        }
        return true;
    }

    void runOnOperation() override {
#ifndef ECO_LOWERING_VALIDATION
        return;
#else
        ModuleOp module = getOperation();
        bool hasErrors = false;

        // === Phase 1: Validate eco.papCreate ops ===
        module.walk([&](PapCreateOp createOp) {
            // For two-clone closures, validate against $cap (which has
            // captures as individual typed params) rather than $clo (which
            // has Closure* as first param).
            auto fastEvalAttr = createOp->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator");
            auto funcSym = fastEvalAttr ? fastEvalAttr : createOp.getFunctionAttr();

            auto captured = createOp.getCaptured();
            SmallVector<Type> capturedTypes;
            capturedTypes.reserve(captured.size());
            for (Value v : captured) capturedTypes.push_back(v.getType());

            if (!checkCalleeShape(createOp, module, "eco.papCreate", funcSym,
                                  createOp.getNumCaptured(), capturedTypes))
                hasErrors = true;
        });

        // === Phase 1b: Validate eco.papCreateGroup ops ===
        // Cross-edge consumer slots are NOT captured operands (they are
        // filled in by the runtime). Only the non-sibling captures appear
        // on the op; those occupy the leading slots of each sibling's
        // capture prefix. Check them against the callee's first
        // capture_counts[i] parameters.
        module.walk([&](PapCreateGroupOp groupOp) {
            auto functions = groupOp.getFunctions();
            auto fastEvals = groupOp.getFastEvaluators();
            auto captureCounts = groupOp.getCaptureCounts();
            ValueRange operands = groupOp.getOperands();
            size_t cursor = 0;
            for (unsigned i = 0; i < functions.size(); ++i) {
                auto funcSym = cast<FlatSymbolRefAttr>(fastEvals[i]);
                int64_t cc = cast<IntegerAttr>(captureCounts[i]).getInt();
                SmallVector<Type> capturedTypes;
                capturedTypes.reserve(cc);
                for (int64_t j = 0; j < cc; ++j)
                    capturedTypes.push_back(operands[cursor + j].getType());
                // num_captured (for callee-shape check) is the count of
                // non-sibling captures. Sibling cross-edge slots occupy
                // higher indices in the callee's param list and are
                // validated only structurally (the op verifier checks
                // num_captured == capture_counts[i] + cross-edge
                // in-degree, and the callee's arity bounds).
                if (!checkCalleeShape(groupOp, module,
                                      "eco.papCreateGroup sibling",
                                      funcSym, cc, capturedTypes))
                    hasErrors = true;
                cursor += cc;
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
#endif
    }
};

} // namespace

std::unique_ptr<Pass> eco::createCheckEcoClosureCapturesPass() {
    return std::make_unique<CheckEcoClosureCapturesPass>();
}
