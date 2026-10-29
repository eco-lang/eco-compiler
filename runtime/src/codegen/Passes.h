//===- Passes.h - Eco dialect lowering passes -----------------------------===//
//
// Every pass that lowers the Eco dialect to the LLVM dialect is created through a factory declared here, so code that
// builds a pipeline needs none of the pass implementations. The declarations are grouped by stage: Eco->Eco rewrites,
// lowering to scf, GC preparation, lowering to the LLVM dialect, and whole-module passes on the LLVM dialect. A
// pass's comment states the ordering it depends on; the pipeline builder is what fixes the order.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PASSES_H
#define ECO_PASSES_H

#include <memory>
#include <string>
#include <vector>

namespace mlir {
class Pass;
class TypeConverter;
class MLIRContext;
} // namespace mlir

namespace eco {

//===----------------------------------------------------------------------===//
// Pass Declarations
//===----------------------------------------------------------------------===//

// ========== Stage 1: Eco -> Eco transformations ==========

// Creates a pass that fails on any reference-counting op (eco.incref, eco.decref, eco.decref_shallow, eco.free,
// eco.reset, eco.reset_ref), emitting an error at each one. It removes nothing: tracing GC mode has no use for these
// ops, so their presence is an error.
std::unique_ptr<mlir::Pass> createRCEliminationPass();

// Creates a pass that fails if a direct eco.call names a function the module neither defines nor declares
// (invariant CGEN_011). It checks names only, not signatures, and inserts no declarations.
std::unique_ptr<mlir::Pass> createUndefinedFunctionPass();

// Creates a pass that checks closure capture integrity (CGEN_CLOSURE_003) and fails on a violation:
// 1. each eco.papCreate's num_captured and captured operand types fit the target function's signature;
// 2. a lambda func.func (a name containing `_lambda_`) uses no SSA value defined in another function.
std::unique_ptr<mlir::Pass> createCheckEcoClosureCapturesPass();

// Creates a pass that simplifies partial applications: a saturated papCreate + papExtend becomes a direct call, a
// papCreate whose every use is a saturated papExtend is replaced by direct calls, and papExtend chains are fused.
// Closures left unused are removed by dead-code elimination.
std::unique_ptr<mlir::Pass> createEcoPAPSimplifyPass();

// Creates a pass that rewrites `compare` followed by a case on its Order result into direct comparisons feeding
// nested Bool cases, so the Order value is never built. It may insert the `Elm_Kernel_Utils_cmp3` declaration, so it
// must run before the pass from createUndefinedFunctionPass.
std::unique_ptr<mlir::Pass> createEcoCompareCaseRewritePass();

// ========== Stage 2: Eco -> Standard MLIR (scf) ==========
// Eligible eco.case/eco.joinpoint become scf ops. No cf is produced here: cf
// first appears in Stage 3 (EcoToLLVM's control-flow patterns, and the scf->cf
// step of EcoTailConversions).

// Creates a pass that labels joinpoints for SCF lowering. It changes no control flow: it adds the unit attribute
// `scf_candidate` to each eco.joinpoint that loops back to itself, has a single exit, and whose continuation starts
// with a jump to it.
std::unique_ptr<mlir::Pass> createJoinpointNormalizationPass();

// Creates a pass that lowers eligible eco.case ops to scf.if or scf.index_switch, and `scf_candidate` eco.joinpoint
// ops to scf.while. Ops it cannot lower are left for the control-flow patterns of the pass from createEcoToLLVMPass.
std::unique_ptr<mlir::Pass> createEcoControlFlowToSCFPass();

// Creates a pass that rewrites scf.while loops that accumulate a list with cons into chunk builds on the scratch
// stack. It needs the scf form, so it runs after the pass from createEcoControlFlowToSCFPass. It does nothing unless
// some function carries the `eco.list_chunks` attribute.
std::unique_ptr<mlir::Pass> createEcoListTemplatePass();

// Creates a pass that rewrites list-walking scf.while loops to step a non-allocating (node, index) cursor. It runs on
// LLVM-dialect bodies after the pass from createEcoToLLVMPass and before the one from createEcoTailConversionsPass.
// It does nothing unless the module declares `__eco_list_tail_inline`.
std::unique_ptr<mlir::Pass> createEcoListCursorPass();

// Creates a module pass that folds each eco.project.* of a dominating eco.construct.* to the constructed field
// operand, and each eco.get_tag of an eco.construct.custom to the constant constructor tag. Functions are folded in
// parallel chunks. It must run before the pass from createEcoGCPreparePass. Setting `ECO_MLIR_FOLD=0` makes this
// pass do nothing; it does not stop the ops' own fold hooks.
std::unique_ptr<mlir::Pass> createEcoFoldProjectPass();

// ========== Stage 2.5: GC Preparation (before LLVM lowering) ==========

// Creates a pass that copies `eco.gc_leaf` from a kernel func.func declaration (one also marked `is_kernel`) onto
// each direct, non-musttail eco.call of it, as the call-local unit attribute `eco.callee_gc_leaf`. The attribute
// records that the callee cannot run a GC; the pass from createBFToLLVMPass reads it. The pass stamps nothing when
// `ECO_KERNEL_GCLEAF=0` or `ECO_GCLEAF_MARK=0`. It must run after every pass that can add a kernel declaration or
// a kernel call site, and before the pass from createEcoGCPreparePass.
std::unique_ptr<mlir::Pass> createEcoMarkGCLeafCallsPass();

// Creates a pass that groups runs of adjacent allocations, marking the first with `eco.gc_group_size` and the rest
// with `eco.gc_group_member`; any call, PAP op or terminator ends a run. It also strips the `eco.cse_safe` purity
// attribute from every eco.call, so no pass after it may merge or erase calls on purity. It computes no GC roots:
// roots, statepoints and stack maps come from LLVM's RS4GC (CGEN_077(b)). It must run after all Eco->Eco
// transformations and control-flow lowering, and before the pass from createEcoToLLVMPass.
std::unique_ptr<mlir::Pass> createEcoGCPreparePass();

// Creates a pass that fails if any eco.call still carries `eco.cse_safe`, which the pass from
// createEcoGCPreparePass strips. It checks nothing about liveness despite its name, and does nothing unless built
// with ECO_LOWERING_VALIDATION.
std::unique_ptr<mlir::Pass> createEcoGCLivenessAuditPass();

// ========== Stage 3: Eco -> LLVM Dialect ==========

// Creates the pass that lowers the Eco dialect to the LLVM dialect, including eco.case and eco.joinpoint ops left
// by the pass from createEcoControlFlowToSCFPass.
std::unique_ptr<mlir::Pass> createEcoToLLVMPass();

// Creates a pass that inserts a call to `eco_validate_nursery_hptr_bits` in front of each LLVM store tagged
// `eco.boxed_slot` (the boxed-field stores of eco.array.set and fresh-object construct lowering). A store of a stale
// nursery HPointer from compiled Elm then fails at the store, not at a later read. It runs after the pass from
// createEcoToLLVMPass, and does nothing unless built with ECO_LOWERING_VALIDATION.
std::unique_ptr<mlir::Pass> createEcoBoxedStoreVerifyPass();

// ========== BF (ByteFusion) Dialect Lowering ==========

// Creates the pass that lowers the BF dialect to the LLVM dialect. A bf.cursor becomes an LLVM struct of two
// pointers, and bf.alloc, bf.cursor.init and bf.write.* become runtime helper calls and inline LLVM ops. A cursor
// live across an op that may run a GC is first re-derived from its buffer.
std::unique_ptr<mlir::Pass> createBFToLLVMPass();

// ========== Tail Conversions (post-EcoToLLVM) ==========

// Creates a module pass that converts each LLVM-dialect function from scf to cf, then arith and cf to LLVM, working
// on chunks of functions in parallel, and then reconciles unrealized casts. cf.assert is not converted and stays
// illegal: Eco never emits it.
std::unique_ptr<mlir::Pass> createEcoTailConversionsPass();

// Creates a pass that plans capacity hoisting on LLVM-dialect MLIR (CGEN_074), stamping each function's plan as
// `eco-cap-*` passthrough attributes plus the `eco-cap-plan` module flag. Only local, non-address-taken
// functions are eligible. With `closedWorld`, every non-root definition counts as local, because it will be
// internalized; otherwise only Internal and Private ones do.
// `roots` names the externally visible entry points, by their MLIR names.
std::unique_ptr<mlir::Pass>
createEcoCapHoistPlanPass(bool closedWorld, std::vector<std::string> roots);

// Creates a pass that stamps the passthrough "gc-leaf-function" on every LLVM-dialect definition it can prove cannot
// reach a GC once the backend has expanded its markers (CGEN_072), and records the `eco-gcfree-plan` module flag. It
// reads `eco-cap-covered`, so it runs after the pass from createEcoCapHoistPlanPass. It must be the last pass that
// changes LLVM-dialect bodies: a later rewrite could make a stamp false.
std::unique_ptr<mlir::Pass> createEcoGcFreePropagationPass();

// Creates a pass for closed-world output (CGEN_081) that erases every symbol op not reachable from `roots` or from a
// non-symbol top-level op, gives every reached non-root definition with External linkage Internal linkage, and records
// the `eco-reach` module flag. It changes nothing when `roots` is empty or none of the named roots exists.
std::unique_ptr<mlir::Pass>
createEcoReachabilityPass(std::vector<std::string> roots);

//===----------------------------------------------------------------------===//
// Type Converter
//===----------------------------------------------------------------------===//

// Creates the type converter from Eco types to LLVM types. `!eco.value` becomes `ptr addrspace(1)`, the GC-managed
// HPointer (REP_ABI_001, REP_SSA_001). `ctx` must outlive the converter.
std::unique_ptr<mlir::TypeConverter> createEcoToLLVMTypeConverter(mlir::MLIRContext *ctx);

//===----------------------------------------------------------------------===//
// Pass Registration
//===----------------------------------------------------------------------===//

// Registers the pass from createEcoToLLVMPass with MLIR's pass registry, under the name `eco-to-llvm`. No other
// pass declared here is registered.
void registerEcoPasses();

} // namespace eco

#endif // ECO_PASSES_H
