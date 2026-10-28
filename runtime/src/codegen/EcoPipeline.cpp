//===- EcoPipeline.cpp - Shared Eco lowering pipeline ---------------------===//

#include "EcoPipeline.h"
#include "Passes.h"

#include <cstdlib>

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Extensions/AllExtensions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/LLVMIR/Transforms/InlinerInterfaceImpl.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"

#include "mlir/IR/Verifier.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Transforms/Passes.h"

#include "EcoDialect.h"
#include "BF/BFDialect.h"

using namespace mlir;

namespace {
/// A pass that verifies the whole module and fails if verification fails.
///
/// It is added right after `EcoPAPSimplify`, so that a driver that turns off
/// MLIR's verification after each pass still checks the closure rewrites
/// that pass makes.
struct VerifyAfterPAPSimplifyPass
    : public PassWrapper<VerifyAfterPAPSimplifyPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(VerifyAfterPAPSimplifyPass)
    StringRef getArgument() const final { return "eco-verify-after-pap-simplify"; }
    StringRef getDescription() const final {
        return "Verify the module after EcoPAPSimplify";
    }
    void runOnOperation() override {
        if (failed(mlir::verify(getOperation())))
            signalPassFailure();
    }
};

/// Returns whether to add `VerifyAfterPAPSimplifyPass`: always in builds with
/// `ECO_HEAP_VALIDATE`, and otherwise when `ECO_VERIFY_AFTER_PAPSIMPLIFY` is
/// set to a non-empty value whose first character is not `0`.
bool verifyAfterPAPSimplifyEnabled() {
#if ECO_HEAP_VALIDATE
    return true;
#else
    const char *e = ::getenv("ECO_VERIFY_AFTER_PAPSIMPLIFY");
    return e && *e && *e != '0';
#endif
}
} // namespace

namespace eco {

void registerRequiredDialects(DialectRegistry &registry) {
    func::registerAllExtensions(registry);
    LLVM::registerInlinerInterface(registry);
}

void loadRequiredDialects(MLIRContext &context) {
    context.getOrLoadDialect<eco::EcoDialect>();
    context.getOrLoadDialect<bf::BFDialect>();
    context.getOrLoadDialect<func::FuncDialect>();
    context.getOrLoadDialect<cf::ControlFlowDialect>();
    context.getOrLoadDialect<arith::ArithDialect>();
    context.getOrLoadDialect<scf::SCFDialect>();
    context.getOrLoadDialect<LLVM::LLVMDialect>();
}

void buildEcoToEcoPipeline(PassManager &pm, const EcoPipelineOptions &opts) {
    pm.addPass(eco::createRCEliminationPass());

#ifdef ECO_LOWERING_VALIDATION
    // Checks closure captures (CGEN_CLOSURE_003). It must see the closure ops
    // before EcoPAPSimplify rewrites them.
    pm.addPass(eco::createCheckEcoClosureCapturesPass());
#endif

    pm.addPass(eco::createEcoPAPSimplifyPass());
    if (verifyAfterPAPSimplifyEnabled())
        pm.addPass(std::make_unique<VerifyAfterPAPSimplifyPass>());

    // After EcoPAPSimplify, so compares made through closures are already
    // direct calls; before UndefinedFunction, which checks the
    // Elm_Kernel_Utils_cmp3 declaration this pass may insert.
    pm.addPass(eco::createEcoCompareCaseRewritePass());

    pm.addPass(eco::createUndefinedFunctionPass());
}

/// Returns the setting of the environment switch `name`: `defaultOn` when the
/// variable is unset or empty, off when it is exactly `0`, and on for any
/// other value.
static bool envSwitch(const char *name, bool defaultOn) {
    const char *e = ::getenv(name);
    if (!e || !*e)
        return defaultOn;
    return !(e[0] == '0' && e[1] == '\0');
}
/// Returns whether to run CSE in the M4 slot: only when `ECO_MLIR_CSE` is set
/// to a non-empty value other than `0`.
///
/// CSE is off by default because it is unsound here. Elm can observe whether
/// two values are one object: CSE may merge two identical constructs holding
/// a NaN into one object, and the equality kernel answers True for the same
/// object without comparing contents, where comparing the two separate
/// objects answers False, since NaN is not equal to itself. The same holds
/// for `eco.box` of a float and for `eco.cse_safe` kernel calls that return
/// containers holding floats.
static bool ecoMlirCseEnabled() { return envSwitch("ECO_MLIR_CSE", false); }
/// Returns whether to run `EcoFoldProject`; on unless `ECO_MLIR_FOLD` is `0`.
static bool ecoFoldProjectEnabled() { return envSwitch("ECO_MLIR_FOLD", true); }

void buildEcoToOptPipeline(PassManager &pm, const EcoPipelineOptions &opts) {
    buildEcoToEcoPipeline(pm, opts);

    // Stage 2. Only scf is produced here; cf appears in Stage 3.
    pm.addPass(eco::createJoinpointNormalizationPass());
    pm.addPass(eco::createEcoControlFlowToSCFPass());
    // After SCF conversion, because it matches scf.while and scf.if, and
    // before EcoGCPrepare, so the runtime calls it inserts are grouped with
    // the other allocations.
    pm.addPass(eco::createEcoListTemplatePass());

    // The M4 slot. No canonicalizer runs between Stage 2 and the slot: LLVM
    // canonicalizes again later, and GC roots are found by RS4GC in the
    // backend, not here.
    //
    // Passes that rely on eco.cse_safe may run anywhere before this point and
    // in this slot, and nowhere after it, because EcoGCPrepare strips the
    // attribute. EcoFoldProject is a module pass that folds functions in
    // parallel chunks itself.
    if (ecoFoldProjectEnabled())
        pm.addPass(eco::createEcoFoldProjectPass());
    if (ecoMlirCseEnabled())
        pm.addNestedPass<func::FuncOp>(createCSEPass());
}

void buildEcoToLLVMPipeline(PassManager &pm, const EcoPipelineOptions &opts) {
    buildEcoToOptPipeline(pm, opts);

    // Stage 2.5. EcoMarkGCLeafCalls comes after EcoCompareCaseRewrite (Stage
    // 1), which can add calls to Elm_Kernel_Utils_cmp3, so those calls are
    // marked too.
    pm.addPass(eco::createEcoMarkGCLeafCallsPass());
    pm.addPass(eco::createEcoGCPreparePass());
#ifdef ECO_LOWERING_VALIDATION
    pm.addNestedPass<func::FuncOp>(eco::createEcoGCLivenessAuditPass());
#endif

    // Stage 3.
    pm.addPass(eco::createBFToLLVMPass());
    pm.addPass(eco::createEcoToLLVMPass());
    // After EcoToLLVM, which has turned list projections into marker calls,
    // and after EcoGCPrepare, so the per-step ops it adds are not grouped
    // with allocations; before the SCF tail conversions, because it rewrites
    // scf.while loops.
    pm.addPass(eco::createEcoListCursorPass());
#ifdef ECO_LOWERING_VALIDATION
    // Reads the eco.boxed_slot attribute EcoToLLVM puts on boxed-slot
    // stores, so it runs before any pass that might drop unknown attributes
    // from those stores.
    pm.addPass(eco::createEcoBoxedStoreVerifyPass());
#endif
    // One module pass converts scf to cf, then arith and cf to llvm, and
    // reconciles unrealized casts, per function in parallel chunks.
    pm.addPass(eco::createEcoTailConversionsPass());
    // Erasing dead functions before the planners does not change their
    // answers for live functions, since nothing live refers to a dead symbol.
    if (opts.reachability && !opts.capRoots.empty()) {
        const char *e = ::getenv("ECO_REACH_MLIR");
        if (!(e && e[0] == '0' && e[1] == '\0'))
            pm.addPass(eco::createEcoReachabilityPass(opts.capRoots));
    }
    // Capacity hoisting plan (CGEN_074), stamped as eco-cap-* passthrough
    // attributes and the eco-cap-plan module flag for the backend. After
    // every pass that adds calls, so it sees them all.
    pm.addPass(eco::createEcoCapHoistPlanPass(opts.capClosedWorld,
                                              opts.capRoots));
    // GC-free leaf stamps (CGEN_072); reads eco-cap-covered. It must stay
    // the last pass that changes llvm-dialect bodies: a later rewrite could
    // invalidate a stamp.
    pm.addPass(eco::createEcoGcFreePropagationPass());
}

} // namespace eco
