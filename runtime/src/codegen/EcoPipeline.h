//===- EcoPipeline.h - Shared Eco lowering pipeline -----------------------===//
//
// The MLIR passes that lower Eco to the LLVM dialect depend on one another's
// output, so they must run in one fixed order, and this component is the one
// place that order is written down. Every driver that lowers Eco builds its
// pass manager from the functions here.
//
// The lowering is three nested pipelines, each a strict prefix of the next:
//
//   - `buildEcoToEcoPipeline` (Stage 1) rewrites and checks Eco ops in place.
//   - `buildEcoToOptPipeline` adds Stage 2, which turns Eco control flow into
//     the `scf` dialect, and then the M4 slot.
//   - `buildEcoToLLVMPipeline` adds Stage 2.5, GC preparation, and Stage 3,
//     which lowers everything to the LLVM dialect and plans for the backend.
//
// The M4 slot is the window after Stage 2 and before GC preparation where
// optional optimisations that rely on the `eco.cse_safe` purity attribute run.
// GC preparation strips that attribute, so nothing after the slot may rely on it.
//
// Three ordering rules hold the order together:
//
//   - A pass that consumes `eco.cse_safe` runs no later than the M4 slot.
//   - `EcoCompareCaseRewrite`, which can add a call to and a declaration of
//     the kernel `Elm_Kernel_Utils_cmp3`, runs before `UndefinedFunction`,
//     which checks that declaration, and both run before
//     `EcoMarkGCLeafCalls`, which copies each callee's cannot-collect fact
//     onto its call sites.
//   - `EcoGcFreePropagation` is the last pass that changes llvm-dialect
//     function bodies, because a later change could invalidate the GC-free
//     stamps it writes.
//
// Some passes are added only in builds compiled with `ECO_LOWERING_VALIDATION`,
// and some are switched by environment variables; each builder names them.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PIPELINE_H
#define ECO_PIPELINE_H

#include <string>
#include <vector>

namespace mlir {
class PassManager;
class MLIRContext;
class DialectRegistry;
} // namespace mlir

namespace eco {

//===----------------------------------------------------------------------===//
// Pipeline Construction
//===----------------------------------------------------------------------===//

// Adds to `registry` the dialect extensions and interfaces the lowering
// needs: the `func` dialect extensions and the LLVM dialect's inliner
// interface. It registers no dialects; `loadRequiredDialects` loads those.
void registerRequiredDialects(mlir::DialectRegistry &registry);

// Loads into `context` every dialect the lowering's input and output use:
// eco, bf, func, cf, arith, scf and llvm.
void loadRequiredDialects(mlir::MLIRContext &context);

/**
 * The settings a driver passes to the pipeline builders.
 *
 * Every member defaults to off or empty, which is the open-world setting a
 * JIT or a separately linked object needs. Only `buildEcoToLLVMPipeline`
 * reads the members; `buildEcoToOptPipeline` passes them on and
 * `buildEcoToEcoPipeline` ignores them.
 */
struct EcoPipelineOptions {
    // Whether the output is closed-world: an executable, or an object whose
    // consumer refers only to `capRoots`. It is passed to `EcoCapHoistPlan`,
    // which stamps it into the plan, and the backend rejects a plan whose
    // stamp differs from `EcoBackendJob::capClosedWorld`.
    bool capClosedWorld = false;
    // The MLIR symbol names that stay externally visible, such as `main`.
    // They are names as they are in the MLIR module, before any renaming a
    // driver does later.
    std::vector<std::string> capRoots;
    // Whether to add `EcoReachability`, which erases what `capRoots` cannot
    // reach and internalizes reached external definitions other than the
    // roots (CGEN_081). It has effect only when `capRoots` is non-empty, and
    // the environment variable `ECO_REACH_MLIR` set to exactly `0` suppresses
    // it.
    bool reachability = false;
};

// Adds the Stage 1 passes to `pm`, in order: `RCElimination`, which fails
// on any reference-counting op (`eco.incref` and the like);
// `CheckEcoClosureCaptures`, in `ECO_LOWERING_VALIDATION` builds only;
// `EcoPAPSimplify`, which fuses closures and turns saturated partial
// applications into direct calls;
// a full-module verification, in builds with `ECO_HEAP_VALIDATE` or when
// `ECO_VERIFY_AFTER_PAPSIMPLIFY` is set to a non-empty value not starting
// with `0`; `EcoCompareCaseRewrite`, which turns a compare followed by a
// case on its `Order` into direct comparisons; and `UndefinedFunction`,
// which fails on any `eco.call` to a symbol that is neither defined nor
// declared (CGEN_011) and creates nothing.
void buildEcoToEcoPipeline(mlir::PassManager &pm,
                           const EcoPipelineOptions &opts = {});

// Adds the Stage 1 passes, as `buildEcoToEcoPipeline` does, then Stage 2
// and the M4 slot, stopping immediately before GC preparation.
//
// Stage 2 is `JoinpointNormalization`, `EcoControlFlowToSCF` and
// `EcoListTemplate`. The M4 slot is `EcoFoldProject`, unless the
// environment variable `ECO_MLIR_FOLD` is exactly `0`, then a CSE pass over
// each function, only when `ECO_MLIR_CSE` is set to a non-empty value
// other than `0`.
//
// This is the last point at which Eco-level `construct` and `project` ops
// still exist and the M4 folds have already run, so it is the only point
// at which the effect of those folds on Eco ops can be observed.
// `buildEcoToLLVMPipeline` calls this function, so stopping here shows the
// same passes, in the same order, as a full lowering.
void buildEcoToOptPipeline(mlir::PassManager &pm,
                           const EcoPipelineOptions &opts = {});

// Adds the full lowering from Eco to the LLVM dialect: everything
// `buildEcoToOptPipeline` adds, then Stage 2.5 and Stage 3.
//
// Stage 2.5 is `EcoMarkGCLeafCalls`, `EcoGCPrepare` (which strips
// `eco.cse_safe`) and, in `ECO_LOWERING_VALIDATION` builds,
// `EcoGCLivenessAudit`.
//
// Stage 3 is `BFToLLVM`, `EcoToLLVM`, `EcoListCursor`,
// `EcoBoxedStoreVerify` (in `ECO_LOWERING_VALIDATION` builds only),
// `EcoTailConversions`, `EcoReachability` (as `opts.reachability`
// describes), `EcoCapHoistPlan`, and last `EcoGcFreePropagation`.
// `EcoCapHoistPlan` writes the capacity-hoisting plan the backend reads,
// and runs after every pass that adds calls. `EcoReachability` runs before
// it, so the planners see only live functions.
void buildEcoToLLVMPipeline(mlir::PassManager &pm,
                            const EcoPipelineOptions &opts = {});

} // namespace eco

#endif // ECO_PIPELINE_H
