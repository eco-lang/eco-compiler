//===- EcoPipeline.cpp - Shared Eco lowering pipeline ---------------------===//
//
// Implementation of the shared pipeline construction API used by both ecoc
// and EcoRunner.
//
//===----------------------------------------------------------------------===//

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

#include "mlir/Pass/PassManager.h"
#include "mlir/Transforms/Passes.h"

#include "EcoDialect.h"
#include "BF/BFDialect.h"

using namespace mlir;

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
    // Stage 1: Eco -> Eco transformations.
    // TODO: Add construct lowering pass.
    // pm.addPass(eco::createConstructLoweringPass());
    pm.addPass(eco::createRCEliminationPass());

#ifdef ECO_LOWERING_VALIDATION
    // Verify closure capture integrity (CGEN_CLOSURE_003):
    // papCreate consistency + no cross-function SSA refs in lambda bodies.
    // Must run early, before PAP simplification may rewrite closure ops.
    pm.addPass(eco::createCheckEcoClosureCapturesPass());
#endif

    // PAP simplification: fuse closures, convert saturated PAPs to direct calls
    pm.addPass(eco::createEcoPAPSimplifyPass());

    // compare + case-on-Order -> direct comparisons (deletes the Order
    // round-trip). After PAPSimplify so closure-mediated compares are already
    // direct calls; before UndefinedFunction, which validates the
    // Elm_Kernel_Utils_cmp3 declaration this pass may insert.
    pm.addPass(eco::createEcoCompareCaseRewritePass());

    // Generate external declarations for undefined functions (kernel functions, etc.)
    pm.addPass(eco::createUndefinedFunctionPass());
}

// Kernel-opt-10 kill switches.
static bool envSwitch(const char *name, bool defaultOn) {
    const char *e = ::getenv(name);
    if (!e || !*e)
        return defaultOn;
    return !(e[0] == '0' && e[1] == '\0');
}
// KEPT-DARK — and the reason is now CORRECTNESS, not performance. The 2026-08-13
// default-on attempt failed three Float container-equality E2E tests: CSE merges
// two structurally identical NaN-containing constructs into ONE object, and the
// equality kernel's pointer-fast-path (same as official Elm's `x === y`
// shortcut) then answers True where the NaN-aware structural walk answers
// False. Object identity IS observable in Elm — via NaN — so "dedup of an
// allocation is semantics-preserving" is false, for constructs, for eco.box of
// f64, and for eco.cse_safe kernel calls returning Float-containing containers
// (List_reverse). Sound enablement needs Allocate-on-result effects on the
// allocating pure ops (erasable-if-dead, never merged) plus a
// no-Float-reachable-in-result axis in KernelFacts. See benchmarks/kernel-opt.md
// Runs Q/R and test/elm/src/ContainerEquality*FloatTest.elm.
static bool ecoMlirCseEnabled() { return envSwitch("ECO_MLIR_CSE", false); }
static bool ecoFoldProjectEnabled() { return envSwitch("ECO_MLIR_FOLD", true); } // DEFAULT-ON since 2026-08-13 (Run Q)

void buildEcoToLLVMPipeline(PassManager &pm, const EcoPipelineOptions &opts) {
    // Stage 1: Eco -> Eco transformations.
    buildEcoToEcoPipeline(pm, opts);

    // Stage 2: Eco -> Standard MLIR (func/cf/arith).
    pm.addPass(eco::createJoinpointNormalizationPass());
    pm.addPass(eco::createEcoControlFlowToSCFPass());
    // Chunked-list Tier-B templates: rewrite cons-accumulation loops to
    // scratch-stack chunk builds. Runs after SCF conversion (needs
    // scf.while / scf.if) and before EcoGCPrepare (the inserted runtime
    // calls take part in normal root/safepoint analysis). No-op without
    // the eco.list_chunks function attribute.
    pm.addPass(eco::createEcoListTemplatePass());
    // M4/4b (measured): the func-level canonicalizer here was removed. Effect:
    // MLIR phase -~0.5s, exe +~0.28%, produced functional output byte-identical.
    // Safe because (1) LLVM's downstream pipeline re-canonicalizes anyway, and
    // (2) fewer pre-GC folds can only make EcoGCPrepare's liveness MORE
    // conservative (more live values => over-rooting, which is GC-SAFE — the
    // unsafe direction is under-rooting). Validated by the full E2E + self-host
    // byte-identity gate. Re-add createCanonicalizerPass() here if any GC or
    // codegen regression appears.
    // pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

    // Kernel-opt-10 (M4 slot). Two func-nested passes, so they merge into ONE
    // parallel sweep over the ~64k functions. They MUST stay before
    // EcoGCPrepare: that pass appends root operands to carrier ops, after
    // which "structurally identical" ops differ by root set and CSE would
    // either miss every merge or merge ops with different root sets. Running
    // here is GC-safe by the M4 argument above — fewer/earlier pure ops can
    // only make liveness MORE conservative, and over-rooting is the safe
    // direction.
    //
    // kernel-opt-12 ordering rule, reproduced verbatim as that plan requires:
    // purity consumers MAY run anywhere in buildEcoToEcoPipeline or in
    // buildEcoToLLVMPipeline up to and including THIS slot, and nowhere
    // after it — `eco.cse_safe` is stripped by EcoGCPrepare precisely here.
    if (ecoFoldProjectEnabled())
        pm.addNestedPass<func::FuncOp>(eco::createEcoFoldProjectPass());
    if (ecoMlirCseEnabled())
        pm.addNestedPass<func::FuncOp>(createCSEPass());

    // Stage 2.5: GC preparation (root sets, allocation grouping, safepoint rewrite).
    // Publish the per-callee cannot-GC fact as a call-local attr first: by here
    // every kernel decl exists and every kernel call site is final (both
    // EcoCompareCaseRewrite, which can mint Elm_Kernel_Utils_cmp3, and
    // UndefinedFunction ran inside buildEcoToEcoPipeline above).
    pm.addPass(eco::createEcoMarkGCLeafCallsPass());
    pm.addPass(eco::createEcoGCPreparePass());
#ifdef ECO_LOWERING_VALIDATION
    pm.addNestedPass<func::FuncOp>(eco::createEcoGCLivenessAuditPass());
#endif

    // Stage 3: Eco -> LLVM Dialect.
    pm.addPass(eco::createBFToLLVMPass());
    pm.addPass(eco::createEcoToLLVMPass());
    // Mixed-spine cursors: rewrite list-walking scf.while loops to
    // (node, idx) stepping. Must run after EcoToLLVM (projections are
    // marker calls; EcoGCPrepare is done, so nothing statepoints the new
    // per-step ops) and before the SCF tail conversions. No-op flag-off.
    pm.addPass(eco::createEcoListCursorPass());
#ifdef ECO_LOWERING_VALIDATION
    // Insert stale-HPointer barriers in front of direct boxed-slot stores
    // emitted by EcoToLLVM (currently only eco.array.set). Must run after
    // EcoToLLVM (which attaches the eco.boxed_slot marker) and before any
    // pass that might re-canonicalise or drop unknown attributes on
    // LLVM::StoreOp; running it immediately after the lowering keeps the
    // window minimal.
    pm.addPass(eco::createEcoBoxedStoreVerifyPass());
#endif
    // Tail conversions: scf->cf and arith->llvm are any-op-anchored upstream
    // passes, so nest them on llvm.func — adjacent nested passes merge into
    // one parallel sweep across the ~64k functions. cf->llvm stays module-
    // anchored (stock pass) pending investigation of the fused custom
    // conversion (see Passes/EcoTailConversions.cpp).
    pm.addNestedPass<LLVM::LLVMFuncOp>(createSCFToControlFlowPass());
    pm.addNestedPass<LLVM::LLVMFuncOp>(createArithToLLVMConversionPass());
    pm.addPass(createConvertControlFlowToLLVMPass());
    pm.addPass(createReconcileUnrealizedCastsPass());
}

} // namespace eco
