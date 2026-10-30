// See RuntimeSymbolMapTest.hpp.

#include "RuntimeSymbolMapTest.hpp"

#include "../allocator/TestHelpers.hpp"
#include "../../runtime/src/codegen/EcoPipeline.h"
#include "../../runtime/src/codegen/Passes/EcoToLLVMInternal.h"
#include "../../runtime/src/codegen/RuntimeSymbols.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"

#include <set>
#include <string>

namespace {

// Every function EcoRuntime declares, other than the `__eco_*` markers the backend expands before code
// runs and the `llvm.*` intrinsics, must be in the JIT's symbol map. The markers include
// `__eco_alloc_inline`, which RuntimeSymbols.h leaves unmapped on purpose.
void testEveryRuntimeDeclIsMapped() {
    mlir::MLIRContext ctx;
    eco::loadRequiredDialects(ctx);
    ctx.loadDialect<mlir::LLVM::LLVMDialect>();
    mlir::OpBuilder builder(&ctx);
    mlir::ModuleOp module = mlir::ModuleOp::create(builder.getUnknownLoc());
    {
        eco::detail::EcoRuntime runtime(module);
        runtime.materializeAllRuntimeDecls(builder);
    }

    std::set<std::string> mapped;
    for (const std::string& n : eco::runtimeSymbolNames()) mapped.insert(n);

    size_t declared = 0;
    std::string missing;
    for (mlir::LLVM::LLVMFuncOp f : module.getOps<mlir::LLVM::LLVMFuncOp>()) {
        std::string name = f.getName().str();
        if (name.rfind("__eco_", 0) == 0 || name.rfind("llvm.", 0) == 0) continue;
        ++declared;
        if (!mapped.count(name)) missing += (missing.empty() ? "" : ", ") + name;
    }
    module.erase();
    TEST_ASSERT(declared > 100);   // the declarations were really materialized
    if (!missing.empty()) TEST_FAIL("runtime declarations missing from the JIT symbol map: " + missing);
}

}  // namespace

void registerRuntimeSymbolMapTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("RuntimeSymbolMap: every runtime declaration is in the JIT symbol map",
                                testEveryRuntimeDeclIsMapped));
}
