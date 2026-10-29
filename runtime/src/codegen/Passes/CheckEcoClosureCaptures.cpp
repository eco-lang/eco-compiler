//===- CheckEcoClosureCaptures.cpp - Verify closure capture integrity -----===//
//
// A closure whose captures do not match the leading parameters of the function it names hands that function
// values of the wrong type, so this pass checks invariant CGEN_CLOSURE_003 on the MLIR and fails on a violation.
//
// A closure is built by `eco.papCreate`, or, for a group of mutually referring closures, by
// `eco.papCreateGroup`. The function such an op names takes the captured values as its leading parameters, so
// the pass makes three checks:
//
// 1. For each `eco.papCreate`, `num_captured` is no larger than the named function's parameter count, and each
//    captured operand's type equals the type of the parameter at the same position.
// 2. For each `eco.papCreateGroup`, the same check is made per sibling against its `fast_evaluators` entry,
//    using only that sibling's `capture_counts[i]` operands. A capture of another sibling of the group (a
//    cross edge) is not an operand of the op, so it is not checked here.
// 3. For each `func.func` whose name contains `_lambda_`, no operand of an op in its body is a value defined,
//    or a block argument owned, outside that function.
//
// A closure op naming a symbol that is not a `func.func` in the module is accepted without a check. The whole check is
// compiled only when `ECO_LOWERING_VALIDATION` is defined; otherwise the pass does nothing.
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

/**
 * The closure-capture check, as a module pass named `eco-check-closure-captures`.
 */
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

    // Returns whether captures of types `capturedTypes`, with a count of `numCaptured`, fit the leading
    // parameters of the function `funcSym` names in `module`.
    //
    // They fit when `numCaptured` is at most the parameter count and `capturedTypes[i]` equals parameter `i`'s
    // type for every `i`. On a mismatch it emits one error on `op`, naming `context` as the kind of op, and
    // returns false. It returns true without checking when `module` has no `func.func` of that name. The two
    // counts are not compared with each other: `capturedTypes` must be no longer than the parameter list,
    // which holds when its size equals `numCaptured`.
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

    // Checks every closure op and every lambda function in the module, reporting each violation as an error
    // and failing the pass if there was any. Does nothing unless `ECO_LOWERING_VALIDATION` is defined.
    void runOnOperation() override {
#ifndef ECO_LOWERING_VALIDATION
        return;
#else
        ModuleOp module = getOperation();
        bool hasErrors = false;

        module.walk([&](PapCreateOp createOp) {
            // `function` names the evaluator (`$cap` for a capturing
            // closure), which takes the captures as individual typed params.
            auto funcSym = createOp.getFunctionAttr();

            auto captured = createOp.getCaptured();
            SmallVector<Type> capturedTypes;
            capturedTypes.reserve(captured.size());
            for (Value v : captured) capturedTypes.push_back(v.getType());

            if (!checkCalleeShape(createOp, module, "eco.papCreate", funcSym,
                                  createOp.getNumCaptured(), capturedTypes))
                hasErrors = true;
        });

        // A group's operands are each sibling's non-sibling captures in turn, `capture_counts[i]` of them,
        // and they occupy the leading parameters of that sibling's function.
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
                // Cross-edge captures follow at higher parameter indices and are not checked here; the op
                // verifier checks their count.
                if (!checkCalleeShape(groupOp, module,
                                      "eco.papCreateGroup sibling",
                                      funcSym, cc, capturedTypes))
                    hasErrors = true;
                cursor += cc;
            }
        });

        module.walk([&](func::FuncOp funcOp) {
            StringRef funcName = funcOp.getSymName();
            if (!funcName.contains("_lambda_"))
                return;

            funcOp.walk([&](Operation *op) {
                for (Value operand : op->getOperands()) {
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
