//===- UndefinedFunction.cpp - Validate no undefined function references ===//
//
// This pass validates that all functions referenced by eco.call operations are
// defined or declared in the module. This enforces invariant CGEN_011: no
// undefined function symbols may escape MLIR codegen.
//
// If any undefined functions are found, the pass fails with error messages
// listing the undefined functions and their call sites.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include <set>
#include <string>
#include <vector>

using namespace mlir;
using namespace ::eco;

namespace {

struct UndefinedFunctionPass
    : public PassWrapper<UndefinedFunctionPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(UndefinedFunctionPass)

    StringRef getArgument() const override { return "eco-undefined-function"; }

    StringRef getDescription() const override {
        return "Validate all called functions are defined or declared (CGEN_011)";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();

        // Step 1: Collect all defined/declared function names in the module.
        std::set<std::string> definedFunctions;
        module.walk([&](func::FuncOp funcOp) {
            definedFunctions.insert(funcOp.getSymName().str());
        });

        // Step 2: Find all eco.call ops referencing undefined functions.
        struct UndefinedCall {
            std::string name;
            Location loc;
        };
        std::vector<UndefinedCall> undefinedCalls;
        std::set<std::string> reportedFunctions; // Avoid duplicate reports

        module.walk([&](CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr)
                return; // Indirect call, skip.

            std::string calleeName = calleeAttr.getValue().str();
            if (definedFunctions.find(calleeName) == definedFunctions.end()) {
                // Only report each function once, but track all locations
                if (reportedFunctions.find(calleeName) == reportedFunctions.end()) {
                    undefinedCalls.push_back({calleeName, callOp.getLoc()});
                    reportedFunctions.insert(calleeName);
                }
            }
        });

        // Step 3: Fail if any undefined functions found.
        if (!undefinedCalls.empty()) {
            for (const auto &call : undefinedCalls) {
                emitError(call.loc) << "undefined function: " << call.name
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
