//===- EcoPAPSimplify.cpp - PAP optimization pass -------------------------===//
//
// This pass optimizes partial application patterns in the ECO dialect:
// - Converts saturated papCreate+papExtend to direct calls (P1)
// - Elides multi-use papCreates whose every use is a saturated typed
//   papExtend, rewriting each use to a direct call (P4, plan H4.1)
// - Fuses papExtend chains (P2)
// - Enables DCE of unused closures (P3 - via canonical DCE)
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

using namespace mlir;
using namespace eco;

namespace {

//===----------------------------------------------------------------------===//
// Pattern P1: Saturated papCreate + papExtend -> direct eco.call
//===----------------------------------------------------------------------===//
//
// Match:
//   %c = eco.papCreate @f(%captured...) { arity = A, num_captured = C }
//   %r = eco.papExtend %c(%newArgs...) { remaining_arity = K }
// Where K == newArgs.size() (saturated) AND %c has single use
//
// Rewrite to:
//   %r = eco.call @f(%captured..., %newArgs...)
//
/// Check if a function uses the args-array calling convention.
/// Returns true if the function signature is: (ptr) -> i64 or (ptr) -> ptr
/// These functions are meant to be called through the closure evaluator, not directly.
static bool usesArgsArrayConvention(Operation *funcOp) {
    if (auto llvmFunc = dyn_cast<LLVM::LLVMFuncOp>(funcOp)) {
        auto funcType = llvmFunc.getFunctionType();
        // Must have exactly one parameter
        if (funcType.getNumParams() != 1)
            return false;
        // Parameter must be a pointer
        if (!isa<LLVM::LLVMPointerType>(funcType.getParamType(0)))
            return false;
        // Return type must be i64 or ptr
        auto retType = funcType.getReturnType();
        if (auto intTy = dyn_cast<IntegerType>(retType))
            return intTy.getWidth() == 64;
        return isa<LLVM::LLVMPointerType>(retType);
    }
    return false;
}

struct SaturatedPapToCallPattern : public OpRewritePattern<PapExtendOp> {
    const mlir::SymbolTable &symTable;
    SaturatedPapToCallPattern(MLIRContext *ctx, const mlir::SymbolTable &symTable)
        : OpRewritePattern(ctx), symTable(symTable) {}

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        // Skip generic-mode papExtend (no remaining_arity) — saturation unknown at compile time
        auto remainingArityAttr = extendOp.getRemainingArityAttr();
        if (!remainingArityAttr)
            return failure();

        // Front-end GC root hints are appended after the real new-args
        // (the trailing `eco.gc_roots_count` operands of `$newargs`).
        // Strip them when measuring saturation and when forwarding to the
        // direct call; the new eco.call gets its own GC root hints via the
        // GCRootCarrier interface.
        unsigned rootCount = extendOp.getGCRoots().size();
        auto allNewargs = extendOp.getNewargs();
        unsigned realNewargCount = allNewargs.size() - rootCount;
        auto newargs = allNewargs.take_front(realNewargCount);
        auto rootHints = allNewargs.drop_front(realNewargCount);

        // Check saturation: remaining_arity == real newargs count
        int64_t remainingArity = remainingArityAttr.getInt();
        if (static_cast<int64_t>(newargs.size()) != remainingArity)
            return failure();  // Not saturated

        // Find defining papCreate
        auto createOp = extendOp.getClosure().getDefiningOp<PapCreateOp>();
        if (!createOp)
            return failure();  // Closure not from papCreate

        // Check single use - safe to inline
        if (!extendOp.getClosure().hasOneUse())
            return failure();  // Closure used elsewhere

        // Do NOT optimize away self-capturing closures. The papCreate stores
        // a placeholder (Unit) for the self-reference slot, which gets
        // backpatched at runtime with the closure's own HPointer. Inlining
        // the captures as direct call args would pass the unpatched Unit
        // placeholder, breaking recursion.
        if (createOp->hasAttr("self_capture_indices"))
            return failure();

        // For two-clone closures, the direct call targets $cap (whose params
        // are captures + params) rather than $clo (Closure* + params).
        auto fastEvalAttr = createOp->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator");
        FlatSymbolRefAttr calleeAttr = fastEvalAttr ? fastEvalAttr : createOp.getFunctionAttr();

        // Look up the target function to verify it has a compatible signature.
        // Skip transformation if the function uses the args-array calling convention
        // (i.e., llvm.func with (ptr) -> i64), as those are meant for closure calls.
        auto targetFunc = symTable.lookup(calleeAttr.getValue());
        if (!targetFunc)
            return failure();  // Function not found - let later passes handle it

        // Skip if target uses args-array convention (not compatible with direct calls)
        if (usesArgsArrayConvention(targetFunc))
            return failure();

        // Build combined operand list: captured + real newargs + GC root hints
        // (roots appended at the tail, GCRootCarrier interface keys off
        // `eco.gc_roots_count`).
        SmallVector<Value> allOperands;
        allOperands.append(createOp.getCaptured().begin(),
                          createOp.getCaptured().end());
        allOperands.append(newargs.begin(), newargs.end());
        // Also bring along the papCreate's own GC root hints so liveness at
        // the new direct call is no worse than at the original papExtend.
        ValueRange createRoots = createOp.getGCRoots();
        for (Value r : createRoots) allOperands.push_back(r);
        for (Value r : rootHints) allOperands.push_back(r);
        unsigned newRootCount = createRoots.size() + rootHints.size();

        // CGEN_056: saturated papExtend result type == callee's func.func return type
        // (enforced by Elm codegen, verified by PapExtendSaturatedResultType test)
        Type resultType = extendOp.getResult().getType();

        auto callOp = rewriter.create<CallOp>(
            extendOp.getLoc(),
            TypeRange{resultType},
            allOperands,
            calleeAttr,
            nullptr,   // musttail
            nullptr);  // remaining_arity
        if (newRootCount > 0) {
            callOp->setAttr("eco.gc_roots_count",
                rewriter.getI64IntegerAttr(static_cast<int64_t>(newRootCount)));
        }

        rewriter.replaceOp(extendOp, callOp.getResults());
        // papCreate will be DCE'd since it now has no uses
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern P4: multi-use papCreate elision (HOF-elimination plan H4.1)
//===----------------------------------------------------------------------===//
//
// Generalizes P1 from "single use" to "every use qualifies". Match a
// papCreate whose EVERY use is the closure operand (#0) of a saturated
// typed-mode papExtend; rewrite each such papExtend to a direct call with
// the papCreate's capture operands forwarded (P1's per-use rewrite), then
// erase the papCreate. This is the population P1 cannot touch: closures
// applied more than once (both branches of a case, loop bodies) — the
// front-end inliner (H1/H2.5) deliberately leaves multi-use closures alone
// because collapsing them there would duplicate code; here each use becomes
// a direct call with no duplication and the allocation disappears.
//
// The DECISION content is unchanged and stays front-end: which target is
// callable directly comes from the papCreate's own attributes
// (`_fast_evaluator` for two-clone closures, else `function`), exactly as
// P1 consumes them. Any other use — the closure stored as a newarg of some
// papExtend, captured by another papCreate, passed to a call, kept as a GC
// root hint — disqualifies the whole papCreate (escape).
//
struct MultiUsePapElisionPattern : public OpRewritePattern<PapCreateOp> {
    const mlir::SymbolTable &symTable;
    MultiUsePapElisionPattern(MLIRContext *ctx, const mlir::SymbolTable &symTable)
        : OpRewritePattern(ctx), symTable(symTable) {}

    LogicalResult matchAndRewrite(PapCreateOp createOp,
                                  PatternRewriter &rewriter) const override {
        Value pap = createOp.getResult();

        // Single-use is P1's territory (cheaper, extend-rooted); dead creates
        // are the greedy driver's DCE territory.
        if (pap.use_empty() || pap.hasOneUse())
            return failure();

        // Same non-negotiables as P1: self-capturing closures get their
        // self slot backpatched at runtime — forwarding captures would pass
        // the unpatched Unit placeholder.
        if (createOp->hasAttr("self_capture_indices"))
            return failure();

        // For two-clone closures the direct call targets $cap (captures +
        // params); otherwise the referenced function itself.
        auto fastEvalAttr = createOp->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator");
        FlatSymbolRefAttr calleeAttr = fastEvalAttr ? fastEvalAttr : createOp.getFunctionAttr();

        auto targetFunc = symTable.lookup(calleeAttr.getValue());
        if (!targetFunc)
            return failure();
        if (usesArgsArrayConvention(targetFunc))
            return failure();

        // Every use must be the closure operand (#0) of a saturated
        // typed-mode papExtend. Collect the extends (deduped: one closure
        // use per extend by construction — any second use of %pap on the
        // same op would be a newarg/root-hint use with operand index != 0,
        // which disqualifies below).
        SmallVector<PapExtendOp> extends;
        for (OpOperand &use : pap.getUses()) {
            auto ext = dyn_cast<PapExtendOp>(use.getOwner());
            if (!ext)
                return failure();
            if (use.getOperandNumber() != 0)
                return failure();  // %pap escapes as a newarg or root hint
            auto remainingArityAttr = ext.getRemainingArityAttr();
            if (!remainingArityAttr)
                return failure();  // generic mode: saturation unknown
            unsigned rootCount = ext.getGCRoots().size();
            auto allNewargs = ext.getNewargs();
            unsigned realNewargCount = allNewargs.size() - rootCount;
            if (static_cast<int64_t>(realNewargCount) != remainingArityAttr.getInt())
                return failure();  // not saturated
            extends.push_back(ext);
        }

        // Rewrite every use to a direct call (P1's operand construction,
        // applied per use). The papCreate's own GC root hints ride along on
        // each call; duplicates across calls are harmless (EcoGCPrepare
        // dedupes during liveness unioning).
        for (PapExtendOp ext : extends) {
            unsigned rootCount = ext.getGCRoots().size();
            auto allNewargs = ext.getNewargs();
            unsigned realNewargCount = allNewargs.size() - rootCount;
            auto newargs = allNewargs.take_front(realNewargCount);
            auto rootHints = allNewargs.drop_front(realNewargCount);

            SmallVector<Value> allOperands;
            allOperands.append(createOp.getCaptured().begin(),
                               createOp.getCaptured().end());
            allOperands.append(newargs.begin(), newargs.end());
            ValueRange createRoots = createOp.getGCRoots();
            for (Value r : createRoots) allOperands.push_back(r);
            for (Value r : rootHints) allOperands.push_back(r);
            unsigned newRootCount = createRoots.size() + rootHints.size();

            // CGEN_056: saturated papExtend result type == callee return type.
            Type resultType = ext.getResult().getType();

            rewriter.setInsertionPoint(ext);
            auto callOp = rewriter.create<CallOp>(
                ext.getLoc(),
                TypeRange{resultType},
                allOperands,
                calleeAttr,
                nullptr,   // musttail
                nullptr);  // remaining_arity
            if (newRootCount > 0) {
                callOp->setAttr("eco.gc_roots_count",
                    rewriter.getI64IntegerAttr(static_cast<int64_t>(newRootCount)));
            }
            rewriter.replaceOp(ext, callOp.getResults());
        }

        rewriter.eraseOp(createOp);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern P2: papExtend chain fusion
//===----------------------------------------------------------------------===//
//
// Match:
//   %c1 = eco.papExtend %c0(%a...) { remaining_arity = K1 } (NOT saturated)
//   %c2 = eco.papExtend %c1(%b...) { remaining_arity = K2 }
// Where %c1 has single use
//
// Rewrite to:
//   %c2 = eco.papExtend %c0(%a..., %b...) { remaining_arity = K1 }
//
struct FusePapExtendChainPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        // Find defining papExtend (chain case)
        auto prevExtend = extendOp.getClosure().getDefiningOp<PapExtendOp>();
        if (!prevExtend)
            return failure();  // Not a chain

        // Check single use of intermediate closure
        if (!extendOp.getClosure().hasOneUse())
            return failure();

        // Typed×typed chains fuse to a typed extend (the original P2).
        // Chains with a GENERIC link (no remaining_arity) fuse to a GENERIC
        // extend: the runtime's multi-arg generic apply chains through
        // mid-chain saturation (it applies until the closure saturates,
        // calls, and continues with the result — the compiler's own
        // emission of `f a s1` as ONE 2-arg generic extend depends on
        // exactly this), so `extend(extend(c, xs), ys)` and
        // `extend(c, xs ++ ys)` are observationally identical while the
        // fused form allocates ONE intermediate PAP instead of two. This is
        // the dominant flag-on (H6.2 arity-raise) allocation shape and
        // exists flag-off as well.
        auto prevRemainingAttr = prevExtend.getRemainingArityAttr();
        auto curRemainingAttr = extendOp.getRemainingArityAttr();
        bool bothTyped = static_cast<bool>(prevRemainingAttr) && static_cast<bool>(curRemainingAttr);

        // Split off the trailing GC root hints from each papExtend's newargs
        // — they are not real call arguments and must not be folded into the
        // fused newarg list (which would corrupt remaining_arity / bitmaps).
        unsigned prevRootCount = prevExtend.getGCRoots().size();
        unsigned curRootCount = extendOp.getGCRoots().size();
        auto prevAllNewargs = prevExtend.getNewargs();
        auto curAllNewargs = extendOp.getNewargs();
        auto prevRealNewargs = prevAllNewargs.take_front(prevAllNewargs.size() - prevRootCount);
        auto curRealNewargs = curAllNewargs.take_front(curAllNewargs.size() - curRootCount);
        auto prevRootHints = prevAllNewargs.drop_front(prevRealNewargs.size());
        auto curRootHints = curAllNewargs.drop_front(curRealNewargs.size());

        // A TYPED prev that saturates would have called already — leave it
        // to P1 (typed case) and never fold a call boundary into a typed
        // fusion. A generic prev's saturation is unknown at compile time,
        // which is fine: the chaining argument above covers it.
        if (prevRemainingAttr) {
            int64_t prevRemaining = prevRemainingAttr.getInt();
            if (static_cast<int64_t>(prevRealNewargs.size()) >= prevRemaining)
                return failure();
        }

        // Build fused real newargs: prev.realNewargs + this.realNewargs
        SmallVector<Value> fusedNewargs;
        fusedNewargs.append(prevRealNewargs.begin(), prevRealNewargs.end());
        fusedNewargs.append(curRealNewargs.begin(), curRealNewargs.end());

        // Compute 2-bit-per-slot bitmap from SSA types (source-of-truth approach).
        // Kind: 0=boxed (!eco.value), 1=Int (i64), 2=Float (f64), 3=Char (i16).
        uint64_t fusedBitmap = 0;
        for (size_t i = 0; i < fusedNewargs.size(); ++i) {
            Type ty = fusedNewargs[i].getType();
            uint64_t kind = 0;
            if (ty.isInteger(64)) kind = 1;
            else if (ty.isF64()) kind = 2;
            else if (ty.isInteger(16)) kind = 3;
            fusedBitmap |= (kind << (2 * i));
        }

        // Append GC root hints from BOTH chained extends after the fused
        // real newargs. The new papExtend's eco.gc_roots_count covers the
        // union; duplicates are harmless (MLIR allows them and EcoGCPrepare
        // will dedupe via DenseSet during liveness unioning).
        SmallVector<Value> allOperands;
        allOperands.append(fusedNewargs.begin(), fusedNewargs.end());
        for (Value r : prevRootHints) allOperands.push_back(r);
        for (Value r : curRootHints) allOperands.push_back(r);
        unsigned fusedRootCount = prevRootCount + curRootCount;

        // Get result type from current extendOp
        Type resultType = extendOp.getResult().getType();

        // Create the fused papExtend. Typed×typed keeps the original typed
        // form (remaining_arity from the first extend + typed attribute
        // propagation); any generic link produces a GENERIC fused extend:
        // no remaining_arity, no typed closure claims (the intermediate's
        // identity is a runtime value), segmentation_unknown call kind, and
        // the CURRENT extend's _result_kind (the final result's ABI claim).
        // PapExtendOp build signature: (result, closure, newargs, remaining_arity, newargs_unboxed_bitmap,
        //                               _closure_kind, _dispatch_mode, _fast_evaluator)
        auto fusedOp = rewriter.create<PapExtendOp>(
            extendOp.getLoc(),
            resultType,                             // Result type
            prevExtend.getClosure(),                // Original closure (skip intermediate)
            allOperands,                            // Fused real newargs + appended GC root hints
            bothTyped ? prevRemainingAttr : IntegerAttr(),
            fusedBitmap,                            // Computed bitmap
            bothTyped ? prevExtend->getAttr("_closure_kind") : Attribute(),
            bothTyped ? prevExtend->getAttrOfType<StringAttr>("_dispatch_mode") : StringAttr(),
            bothTyped ? prevExtend->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator") : FlatSymbolRefAttr());

        if (bothTyped) {
            // Propagate _call_kind from the first extend
            if (auto callKindAttr = prevExtend->getAttrOfType<StringAttr>("_call_kind")) {
                fusedOp->setAttr("_call_kind", callKindAttr);
            }
        } else {
            fusedOp->setAttr("_call_kind", rewriter.getStringAttr("segmentation_unknown"));
            if (auto resultKindAttr = extendOp->getAttr("_result_kind")) {
                fusedOp->setAttr("_result_kind", resultKindAttr);
            }
        }
        if (fusedRootCount > 0) {
            fusedOp->setAttr("eco.gc_roots_count",
                rewriter.getI64IntegerAttr(static_cast<int64_t>(fusedRootCount)));
        }

        rewriter.replaceOp(extendOp, fusedOp.getResult());
        // Erase the orphaned intermediate explicitly: papExtend has no
        // purity trait (a saturating extend calls code), so the driver's
        // DCE can NEVER remove it — left in place it executes at runtime
        // as an allocate-and-discard PAP and keeps the papCreate
        // multi-use, blocking P1/P4 on the fused extend. Safe: typed
        // prevs are proven non-saturating (pure allocation); a generic
        // prev's possible mid-chain call is SUBSUMED by the fused generic
        // extend (same callee, same argument order), not skipped.
        rewriter.eraseOp(prevExtend);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pattern P5: dead non-saturating papExtend removal
//===----------------------------------------------------------------------===//
//
// Match:
//   %r = eco.papExtend %c(%args...) { remaining_arity = K }   (K > args, %r unused)
//
// Erase it. A strictly non-saturating typed extend is a pure PAP
// allocation — if the result is unused the allocation is pure waste that
// no other DCE can remove (papExtend carries no purity trait because the
// SATURATING form calls arbitrary code). Generic-mode extends (no
// remaining_arity) may saturate at runtime and are never touched.
//
struct DeadPapExtendPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        if (!extendOp.getResult().use_empty())
            return failure();

        auto remainingArityAttr = extendOp.getRemainingArityAttr();
        if (!remainingArityAttr)
            return failure();  // Generic mode: may saturate (and call) at runtime

        // Real newargs exclude the trailing GC root hints (same accounting
        // as P1/P2).
        unsigned rootCount = extendOp.getGCRoots().size();
        int64_t realNewargCount =
            static_cast<int64_t>(extendOp.getNewargs().size()) - rootCount;
        if (realNewargCount >= remainingArityAttr.getInt())
            return failure();  // Saturating (or over): calls code — never erase

        rewriter.eraseOp(extendOp);
        return success();
    }
};

//===----------------------------------------------------------------------===//
// Pass definition
//===----------------------------------------------------------------------===//

struct EcoPAPSimplifyPass
    : public PassWrapper<EcoPAPSimplifyPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoPAPSimplifyPass)

    StringRef getArgument() const override { return "eco-pap-simplify"; }

    StringRef getDescription() const override {
        return "Optimize PAP patterns: saturated->call, chain fusion";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        // Build symbol table once for O(1) lookups in patterns
        mlir::SymbolTable symTable(module);

        RewritePatternSet patterns(ctx);
        patterns.add<SaturatedPapToCallPattern>(ctx, symTable);
        patterns.add<FusePapExtendChainPattern>(ctx);
        patterns.add<MultiUsePapElisionPattern>(ctx, symTable);
        patterns.add<DeadPapExtendPattern>(ctx);
        FrozenRewritePatternSet frozen(std::move(patterns));

        // P1/P2 root on eco.papExtend and P4 on eco.papCreate, so seed the
        // driver with ONLY those ops instead of every op in the module (the
        // whole-module greedy driver spent ~1s/self-host-build
        // folding+DCE-probing ~12MB of ops that can never match). The seeded
        // driver still follows the rewrite cascade: P2-fused papExtends are
        // newly created ops (re-tried for saturation), and
        // papCreate/papExtend producers of replaced ops get enqueued and
        // DCE'd exactly as the module driver did.
        SmallVector<Operation *> seeds;
        module.walk([&](PapExtendOp op) { seeds.push_back(op); });
        module.walk([&](PapCreateOp op) { seeds.push_back(op); });
        if (seeds.empty())
            return;

        if (failed(applyOpPatternsGreedily(seeds, frozen)))
            signalPassFailure();
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoPAPSimplifyPass() {
    return std::make_unique<EcoPAPSimplifyPass>();
}
