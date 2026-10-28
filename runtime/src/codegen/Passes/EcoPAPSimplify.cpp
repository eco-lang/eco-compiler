//===- EcoPAPSimplify.cpp - PAP optimization pass -------------------------===//
//
// A partial application that is built only to be applied straight away costs a heap allocation for nothing, and
// this pass removes such allocations from the eco dialect before it is lowered.
//
// A closure is made by `eco.papCreate`, which names an evaluator function, its `arity` and the values it captures.
// `eco.papExtend` applies a closure to further arguments, its newargs. An extend is in typed mode when it carries
// `remaining_arity`, the number of arguments the closure still needs; it is saturated when it supplies exactly that
// many, and then it calls the evaluator instead of building a new closure. An extend without `remaining_arity` is in
// generic mode: whether it saturates is decided at run time from the closure, so it may call code. The evaluator a
// `papCreate` names takes the captures first and then the parameters (for a capturing closure this is its `$cap`
// clone), which is what lets a saturated application be written as an ordinary call.
//
// Five rewrite patterns follow from those facts:
// - `SaturatedPapToCallPattern` turns a single-use create applied by a saturated typed extend into `eco.call`.
// - `MultiUsePapElisionPattern` does the same for a create with several uses, all of them saturated typed extends.
// - `FusePapExtendChainPattern` merges an extend of an extend into one extend.
// - `FuseCreateIntoExtendPattern` merges a non-saturating typed extend of a create into one create.
// - `DeadPapExtendPattern` erases an unused, non-saturating typed extend.
// `papCreate` is `Pure`, so a create left with no uses is removed by the rewrite driver; `papExtend` is not, because a
// saturating extend calls code, so the patterns erase the extends they make dead themselves.
//
// No pattern touches a create with `self_capture_indices`. Such a closure captures itself: the create stores a
// placeholder (Unit) in the self slot, which is overwritten with the closure's own pointer after allocation, so
// forwarding its captures elsewhere would pass the placeholder. The two fusion patterns recompute `slot_kinds` for
// the closure op they build from its operands' SSA types, and keep it within the closure size limits of
// `PapCreateOp::verify` and `PapExtendOp::verify`, since nothing guarantees the verifier runs after this pass.
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

/// The largest number of values one closure op may carry, equal to `Elm::CLOSURE_MAX_ARITY` (HEAP_078).
///
/// A fused extend may have at most this many newargs, and a fused create at most one fewer captures.
constexpr size_t kClosureMaxArity = 2047;

/// Returns the `slot_kinds` entry for each of `vals`, from its SSA type: 1 for `i64` (Int), 2 for `f64` (Float),
/// 3 for `i32` (Char), and 0 (boxed) for anything else, `i1` included.
static SmallVector<int8_t> slotKindsOf(ValueRange vals) {
    SmallVector<int8_t> kinds;
    kinds.reserve(vals.size());
    for (Value v : vals) {
        Type ty = v.getType();
        kinds.push_back(ty.isInteger(64) ? 1 : ty.isF64() ? 2 : eco::isEcoCharType(ty) ? 3 : 0);
    }
    return kinds;
}

/// Returns whether `funcOp` is an `llvm.func` taking one pointer and returning `i64` or a pointer.
///
/// Such a function takes its arguments as one array, so the patterns that make direct calls leave a closure whose
/// evaluator looks like this alone. A `func.func` never matches.
static bool usesArgsArrayConvention(Operation *funcOp) {
    if (auto llvmFunc = dyn_cast<LLVM::LLVMFuncOp>(funcOp)) {
        auto funcType = llvmFunc.getFunctionType();
        if (funcType.getNumParams() != 1)
            return false;
        if (!isa<LLVM::LLVMPointerType>(funcType.getParamType(0)))
            return false;
        auto retType = funcType.getReturnType();
        if (auto intTy = dyn_cast<IntegerType>(retType))
            return intTy.getWidth() == 64;
        return isa<LLVM::LLVMPointerType>(retType);
    }
    return false;
}

/// A rewrite of a saturated typed extend of a single-use create into a direct call.
///
///   %c = eco.papCreate @f(%captured...)
///   %r = eco.papExtend %c(%newargs...) { remaining_arity = K }   // K == |newargs|
/// becomes
///   %r = eco.call @f(%captured..., %newargs...)
///
/// The call's result type is the extend's, which CGEN_056 makes equal to the evaluator's return type. It does not
/// fire for a self-capturing create, an evaluator missing from `symTable`, or an args-array evaluator. The create,
/// left unused, is removed by the driver.
struct SaturatedPapToCallPattern : public OpRewritePattern<PapExtendOp> {
    const mlir::SymbolTable &symTable; ///< The module's symbol table, which must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `symTable`.
    SaturatedPapToCallPattern(MLIRContext *ctx, const mlir::SymbolTable &symTable)
        : OpRewritePattern(ctx), symTable(symTable) {}

    /// Rewrites `extendOp` into a call when it matches, and fails otherwise.
    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        auto remainingArityAttr = extendOp.getRemainingArityAttr();
        if (!remainingArityAttr)
            return failure();

        auto newargs = extendOp.getNewargs();

        int64_t remainingArity = remainingArityAttr.getInt();
        if (static_cast<int64_t>(newargs.size()) != remainingArity)
            return failure();  // Not saturated

        auto createOp = extendOp.getClosure().getDefiningOp<PapCreateOp>();
        if (!createOp)
            return failure();  // Closure not from papCreate

        if (!extendOp.getClosure().hasOneUse())
            return failure();  // Closure used elsewhere

        if (createOp->hasAttr("self_capture_indices"))
            return failure();

        FlatSymbolRefAttr calleeAttr = createOp.getFunctionAttr();

        auto targetFunc = symTable.lookup(calleeAttr.getValue());
        if (!targetFunc)
            return failure();  // Function not found - let later passes handle it

        if (usesArgsArrayConvention(targetFunc))
            return failure();

        SmallVector<Value> allOperands;
        allOperands.append(createOp.getCaptured().begin(),
                          createOp.getCaptured().end());
        allOperands.append(newargs.begin(), newargs.end());

        Type resultType = extendOp.getResult().getType();

        auto callOp = rewriter.create<CallOp>(
            extendOp.getLoc(),
            TypeRange{resultType},
            allOperands,
            calleeAttr,
            nullptr,   // musttail
            nullptr);  // remaining_arity

        rewriter.replaceOp(extendOp, callOp.getResults());
        return success();
    }
};

/// A rewrite of a create with several uses, every one of them as the closure of a saturated typed extend, into one
/// direct call per use.
///
/// Each extend is rewritten as `SaturatedPapToCallPattern` rewrites one, and the create is erased. A create with
/// zero or one use is left to the driver and to `SaturatedPapToCallPattern`. Any other use (the create passed as a
/// newarg, captured, or given to a call) means the closure escapes, and nothing is rewritten. The same exclusions as
/// `SaturatedPapToCallPattern` apply.
struct MultiUsePapElisionPattern : public OpRewritePattern<PapCreateOp> {
    const mlir::SymbolTable &symTable; ///< The module's symbol table, which must outlive the pattern.
    /// Creates the pattern, which keeps a reference to `symTable`.
    MultiUsePapElisionPattern(MLIRContext *ctx, const mlir::SymbolTable &symTable)
        : OpRewritePattern(ctx), symTable(symTable) {}

    /// Rewrites every use of `createOp` into a call and erases it when it matches, and fails, changing nothing,
    /// otherwise.
    LogicalResult matchAndRewrite(PapCreateOp createOp,
                                  PatternRewriter &rewriter) const override {
        Value pap = createOp.getResult();

        if (pap.use_empty() || pap.hasOneUse())
            return failure();

        if (createOp->hasAttr("self_capture_indices"))
            return failure();

        FlatSymbolRefAttr calleeAttr = createOp.getFunctionAttr();

        auto targetFunc = symTable.lookup(calleeAttr.getValue());
        if (!targetFunc)
            return failure();
        if (usesArgsArrayConvention(targetFunc))
            return failure();

        // Every use is checked before anything is rewritten. An extend appears here at most once: a second use of
        // %pap on the same op would be a newarg, with operand number other than 0, which fails.
        SmallVector<PapExtendOp> extends;
        for (OpOperand &use : pap.getUses()) {
            auto ext = dyn_cast<PapExtendOp>(use.getOwner());
            if (!ext)
                return failure();
            if (use.getOperandNumber() != 0)
                return failure();  // %pap escapes as a newarg
            auto remainingArityAttr = ext.getRemainingArityAttr();
            if (!remainingArityAttr)
                return failure();  // generic mode: saturation unknown
            if (static_cast<int64_t>(ext.getNewargs().size()) != remainingArityAttr.getInt())
                return failure();  // not saturated
            extends.push_back(ext);
        }

        for (PapExtendOp ext : extends) {
            auto newargs = ext.getNewargs();

            SmallVector<Value> allOperands;
            allOperands.append(createOp.getCaptured().begin(),
                               createOp.getCaptured().end());
            allOperands.append(newargs.begin(), newargs.end());

            Type resultType = ext.getResult().getType();

            rewriter.setInsertionPoint(ext);
            auto callOp = rewriter.create<CallOp>(
                ext.getLoc(),
                TypeRange{resultType},
                allOperands,
                calleeAttr,
                nullptr,   // musttail
                nullptr);  // remaining_arity
            rewriter.replaceOp(ext, callOp.getResults());
        }

        rewriter.eraseOp(createOp);
        return success();
    }
};

/// A rewrite of an extend whose closure is a single-use extend into one extend with both sets of newargs.
///
///   %c1 = eco.papExtend %c0(%a...)
///   %c2 = eco.papExtend %c1(%b...)
/// becomes
///   %c2 = eco.papExtend %c0(%a..., %b...)
///
/// When both extends are typed, the fused extend is typed, with the first one's `remaining_arity`,
/// `_fast_evaluator` and `_call_kind`; it does not fire if the first one saturates. When either is generic, the fused
/// extend is generic, with no `remaining_arity` or `_fast_evaluator`, `_call_kind` `segmentation_unknown`, and the
/// second extend's `_result_kind`. That rests on the runtime's generic apply continuing through saturation: it calls
/// the closure once it has enough arguments and applies the rest to the result, so one extend with `%a ++ %b`
/// behaves as the two in sequence. `_gencall_reason` is taken from the second extend, else the first, else set to
/// 10 for a generic fusion. It does not fire when the fused newargs would exceed `kClosureMaxArity`.
struct FusePapExtendChainPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    /// Replaces `extendOp` and the extend that produced its closure with one fused extend when it matches, and fails
    /// otherwise.
    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        auto prevExtend = extendOp.getClosure().getDefiningOp<PapExtendOp>();
        if (!prevExtend)
            return failure();  // Not a chain

        if (!extendOp.getClosure().hasOneUse())
            return failure();

        auto prevRemainingAttr = prevExtend.getRemainingArityAttr();
        auto curRemainingAttr = extendOp.getRemainingArityAttr();
        bool bothTyped = static_cast<bool>(prevRemainingAttr) && static_cast<bool>(curRemainingAttr);

        auto prevNewargs = prevExtend.getNewargs();
        auto curNewargs = extendOp.getNewargs();

        // A typed first extend that saturates is a call, and a typed fusion must not fold a call away. A generic
        // first extend may saturate too, but the fused extend is then generic and makes the same call.
        if (prevRemainingAttr) {
            int64_t prevRemaining = prevRemainingAttr.getInt();
            if (static_cast<int64_t>(prevNewargs.size()) >= prevRemaining)
                return failure();
        }

        SmallVector<Value> fusedNewargs;
        fusedNewargs.append(prevNewargs.begin(), prevNewargs.end());
        fusedNewargs.append(curNewargs.begin(), curNewargs.end());

        if (fusedNewargs.size() > kClosureMaxArity)
            return failure();

        SmallVector<int8_t> fusedKinds = slotKindsOf(fusedNewargs);

        Type resultType = extendOp.getResult().getType();

        // Builder arguments: result, closure, newargs, remaining_arity, slot_kinds, _fast_evaluator, _call_kind.
        auto fusedOp = rewriter.create<PapExtendOp>(
            extendOp.getLoc(),
            resultType,                             // Result type
            prevExtend.getClosure(),                // Original closure (skip intermediate)
            fusedNewargs,                           // Fused newargs
            bothTyped ? prevRemainingAttr : IntegerAttr(),
            rewriter.getDenseI8ArrayAttr(fusedKinds),
            bothTyped ? prevExtend.get_fastEvaluatorAttr() : FlatSymbolRefAttr(),
            bothTyped ? prevExtend.get_callKindAttr()
                      : rewriter.getStringAttr("segmentation_unknown"));

        if (!bothTyped) {
            if (auto resultKindAttr = extendOp->getAttr("_result_kind")) {
                fusedOp->setAttr("_result_kind", resultKindAttr);
            }
        }
        if (auto reasonAttr = extendOp->getAttr("_gencall_reason"))
            fusedOp->setAttr("_gencall_reason", reasonAttr);
        else if (auto prevReason = prevExtend->getAttr("_gencall_reason"))
            fusedOp->setAttr("_gencall_reason", prevReason);
        else if (!bothTyped)
            fusedOp->setAttr("_gencall_reason", rewriter.getI64IntegerAttr(10));

        rewriter.replaceOp(extendOp, fusedOp.getResult());
        // The first extend is now unused, but it is not Pure, so the driver would leave it to run as a discarded
        // allocation and keep a create it extends multi-use. Erasing it loses nothing: a typed one was checked not to
        // saturate, and a generic one's possible call is made by the fused extend, with the same arguments in order.
        rewriter.eraseOp(prevExtend);
        return success();
    }
};

/// A rewrite of a non-saturating typed extend of a single-use create into one create that captures the newargs too.
///
///   %c = eco.papCreate @f(%caps...) { arity = A, num_captured = C }
///   %r = eco.papExtend %c(%args...) { remaining_arity = R }   // 0 < |args| < R
/// becomes
///   %r = eco.papCreate @f(%caps..., %args...) { arity = A, num_captured = C + |args| }
///
/// This assumes that the runtime treats a closure's captured values and its applied arguments alike, so the two
/// forms build the same closure, the second with one allocation. The new create is a clone of the old one, keeping
/// its other attributes, with new operands, `num_captured` and `slot_kinds`. It does not fire for a generic extend,
/// a self-capturing create, a result that is not `!eco.value`, or when the fused captures would reach `arity` or
/// exceed `kClosureMaxArity - 1`.
struct FuseCreateIntoExtendPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    /// Replaces `extendOp` and its create with one create when it matches, and fails otherwise.
    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        auto remainingArityAttr = extendOp.getRemainingArityAttr();
        if (!remainingArityAttr)
            return failure();  // Generic-mode: runtime saturation unknown

        auto newargs = extendOp.getNewargs();

        if (newargs.empty())
            return failure();  // Nothing to fuse

        int64_t remaining = remainingArityAttr.getInt();
        if (static_cast<int64_t>(newargs.size()) >= remaining)
            return failure();

        auto createOp = extendOp.getClosure().getDefiningOp<PapCreateOp>();
        if (!createOp)
            return failure();
        if (!extendOp.getClosure().hasOneUse())
            return failure();
        if (createOp->hasAttr("self_capture_indices"))
            return failure();

        if (!isa<eco::ValueType>(extendOp.getResult().getType()))
            return failure();

        auto caps = createOp.getCaptured();

        int64_t fusedCaptured =
            static_cast<int64_t>(caps.size()) + static_cast<int64_t>(newargs.size());
        if (fusedCaptured >= static_cast<int64_t>(createOp.getArity()) ||
            fusedCaptured > static_cast<int64_t>(kClosureMaxArity) - 1)
            return failure();  // Verifier limits (strict PAP, 2046 captures)

        SmallVector<Value> allOperands;
        allOperands.append(caps.begin(), caps.end());
        allOperands.append(newargs.begin(), newargs.end());
        SmallVector<int8_t> fusedKinds = slotKindsOf(allOperands);

        rewriter.setInsertionPoint(extendOp);
        Operation *cloned = rewriter.clone(*createOp.getOperation());
        cloned->setOperands(allOperands);
        cloned->setAttr("num_captured", rewriter.getI64IntegerAttr(fusedCaptured));
        cloned->setAttr("slot_kinds", rewriter.getDenseI8ArrayAttr(fusedKinds));

        rewriter.replaceOp(extendOp, cloned->getResult(0));
        rewriter.eraseOp(createOp);
        return success();
    }
};

/// A rewrite that erases a typed extend whose result is unused and which does not saturate.
///
/// Such an extend only allocates a closure, but `papExtend` is not `Pure`, so the driver does not remove it. A
/// generic extend, or one that saturates, may call code and is kept.
struct DeadPapExtendPattern : public OpRewritePattern<PapExtendOp> {
    using OpRewritePattern::OpRewritePattern;

    /// Erases `extendOp` when it matches, and fails otherwise.
    LogicalResult matchAndRewrite(PapExtendOp extendOp,
                                  PatternRewriter &rewriter) const override {
        if (!extendOp.getResult().use_empty())
            return failure();

        auto remainingArityAttr = extendOp.getRemainingArityAttr();
        if (!remainingArityAttr)
            return failure();  // Generic mode: may saturate (and call) at runtime

        if (static_cast<int64_t>(extendOp.getNewargs().size()) >=
            remainingArityAttr.getInt())
            return failure();  // Saturating (or over): calls code — never erase

        rewriter.eraseOp(extendOp);
        return success();
    }
};

/// The module pass `eco-pap-simplify`, which applies the five patterns above greedily.
struct EcoPAPSimplifyPass
    : public PassWrapper<EcoPAPSimplifyPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoPAPSimplifyPass)

    StringRef getArgument() const override { return "eco-pap-simplify"; }

    StringRef getDescription() const override {
        return "Optimize PAP patterns: saturated->call, chain fusion";
    }

    /// Rewrites the module's closure ops with the five patterns, and signals failure if the greedy driver does not
    /// converge.
    void runOnOperation() override {
        ModuleOp module = getOperation();
        MLIRContext *ctx = &getContext();

        mlir::SymbolTable symTable(module);

        RewritePatternSet patterns(ctx);
        patterns.add<SaturatedPapToCallPattern>(ctx, symTable);
        patterns.add<FusePapExtendChainPattern>(ctx);
        patterns.add<FuseCreateIntoExtendPattern>(ctx);
        patterns.add<MultiUsePapElisionPattern>(ctx, symTable);
        patterns.add<DeadPapExtendPattern>(ctx);
        FrozenRewritePatternSet frozen(std::move(patterns));

        // Every pattern is rooted on papExtend or papCreate, so only those ops are given to the driver, not the
        // whole module. The driver still visits the ops a rewrite creates, and the producers of ops it replaces.
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
