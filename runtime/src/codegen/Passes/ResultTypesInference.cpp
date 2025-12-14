//===- ResultTypesInference.cpp - Infer result_types for eco.case ---------===//
//
// This pass analyzes eco.case operations and infers the result_types attribute
// from the eco.return operations inside each alternative. This enables SCF
// lowering patterns to work without requiring explicit result_types annotation.
//
// Algorithm:
// 1. For each eco.case without result_types:
//    a. Collect types from eco.return ops in each alternative
//    b. If all alternatives have consistent types, set result_types
//    c. Skip if alternatives have different types (error case)
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace ::eco;

namespace {

/// Get the return types from a region's eco.return terminator.
/// Returns std::nullopt if the terminator is not eco.return or region is empty.
std::optional<SmallVector<Type>> getReturnTypes(Region &region) {
    if (region.empty())
        return std::nullopt;

    Block &block = region.front();
    if (block.empty())
        return std::nullopt;

    Operation *term = block.getTerminator();
    if (auto ret = dyn_cast<ReturnOp>(term)) {
        SmallVector<Type> types;
        for (Value operand : ret.getOperands()) {
            types.push_back(operand.getType());
        }
        return types;
    }

    return std::nullopt;
}

/// Check if two type vectors are equal.
bool typesEqual(ArrayRef<Type> a, ArrayRef<Type> b) {
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i] != b[i])
            return false;
    }
    return true;
}

struct ResultTypesInferencePass
    : public PassWrapper<ResultTypesInferencePass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(ResultTypesInferencePass)

    StringRef getArgument() const override { return "eco-infer-result-types"; }

    StringRef getDescription() const override {
        return "Infer result_types attribute for eco.case operations";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // Process all eco.case operations
        module.walk([&](CaseOp op) {
            // Skip if already has result_types
            if (op.getCaseResultTypes())
                return;

            auto alts = op.getAlternatives();
            if (alts.empty())
                return;

            // Get types from first alternative
            auto firstTypes = getReturnTypes(alts[0]);
            if (!firstTypes)
                return; // Not a pure-return case

            // Check all other alternatives have the same types
            for (size_t i = 1; i < alts.size(); ++i) {
                auto altTypes = getReturnTypes(alts[i]);
                if (!altTypes)
                    return; // Not all alternatives have eco.return

                if (!typesEqual(*firstTypes, *altTypes))
                    return; // Type mismatch between alternatives
            }

            // All alternatives have consistent types - set result_types
            SmallVector<Attribute> typeAttrs;
            for (Type t : *firstTypes) {
                typeAttrs.push_back(TypeAttr::get(t));
            }

            op->setAttr("result_types", ArrayAttr::get(ctx, typeAttrs));
        });
    }
};

} // namespace

std::unique_ptr<Pass> eco::createResultTypesInferencePass() {
    return std::make_unique<ResultTypesInferencePass>();
}
