//===- UndefinedFunctionStub.cpp - Generate extern decls for undefined fns ===//
//
// This pass finds eco.call operations that reference undefined functions and
// generates external function declarations for them. The actual implementations
// are provided by the runtime (for kernel functions) or will cause a link-time
// error if missing.
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

using namespace mlir;
using namespace ::eco;

namespace {

struct UndefinedFunctionStubPass
    : public PassWrapper<UndefinedFunctionStubPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(UndefinedFunctionStubPass)

    StringRef getArgument() const override { return "eco-undefined-function-stub"; }

    StringRef getDescription() const override {
        return "Generate external declarations for undefined callees";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        auto *ctx = module.getContext();

        // Collect all defined function names in the module.
        std::set<std::string> definedFunctions;
        module.walk([&](func::FuncOp funcOp) {
            definedFunctions.insert(funcOp.getSymName().str());
        });

        // Collect all undefined function names referenced by eco.call ops.
        std::set<std::string> undefinedFunctions;
        module.walk([&](CallOp callOp) {
            auto calleeAttr = callOp.getCalleeAttr();
            if (!calleeAttr)
                return; // Indirect call, skip.

            std::string calleeName = calleeAttr.getValue().str();
            if (definedFunctions.find(calleeName) == definedFunctions.end()) {
                undefinedFunctions.insert(calleeName);
            }
        });

        if (undefinedFunctions.empty())
            return; // No declarations needed.

        // Create external function declarations at the end of the module.
        OpBuilder builder(ctx);
        builder.setInsertionPointToEnd(module.getBody());

        for (const auto &funcName : undefinedFunctions) {
            // Determine the function signature by looking at the first call site.
            // All calls to the same function should have the same signature.
            SmallVector<Type> argTypes;
            Type resultType;
            bool foundCallSite = false;

            module.walk([&](CallOp callOp) {
                if (foundCallSite)
                    return;
                auto calleeAttr = callOp.getCalleeAttr();
                if (!calleeAttr || calleeAttr.getValue().str() != funcName)
                    return;

                // Get argument types from operands.
                for (auto operand : callOp.getOperands()) {
                    argTypes.push_back(operand.getType());
                }

                // Get result type. eco.call returns a single value.
                if (callOp.getNumResults() > 0) {
                    resultType = callOp.getResult(0).getType();
                }

                foundCallSite = true;
            });

            if (!foundCallSite)
                continue;

            // Build function type.
            FunctionType funcType;
            if (resultType) {
                funcType = FunctionType::get(ctx, argTypes, {resultType});
            } else {
                funcType = FunctionType::get(ctx, argTypes, {});
            }

            // Create external function declaration (no body).
            auto funcOp = builder.create<func::FuncOp>(
                builder.getUnknownLoc(),
                funcName,
                funcType);
            funcOp.setVisibility(SymbolTable::Visibility::Private);
            // Note: Not adding an entry block makes this an external declaration.
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createUndefinedFunctionStubPass() {
    return std::make_unique<UndefinedFunctionStubPass>();
}
