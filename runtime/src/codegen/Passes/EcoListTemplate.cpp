//===- EcoListTemplate.cpp - Cons-accumulation loops to scratch chunks ----===//
//
// Building an Elm list one prepend at a time allocates one cons cell per
// element. This pass rewrites list builders of that kind, in programs compiled
// for chunked lists, so that they push each element onto the runtime's list
// scratch stack and build the whole list with one call at the end, which can
// produce a dense chunk instead of a chain of cells.
//
// The list scratch stack is a runtime stack of pending list elements. Its
// calls (`eco_scratch_mark`, `eco_scratch_push_boxed`,
// `eco_scratch_push_scalar`, `eco_scratch_finish`, `eco_scratch_finish_fwd`)
// are declared in `allocator/RuntimeExports`, which states what each builds.
// A builder takes a mark, pushes elements, and finishes with the mark. What
// matters here is the order: `eco_scratch_finish` puts the entries in front
// of its tail argument in reverse push order, and `eco_scratch_finish_fwd`
// puts them in front of its rest argument in push order. Boxed entries are GC
// roots, so code between pushes may allocate. A builder nested inside another
// is balanced if its own mark and finish both run between two of the outer
// builder's pushes.
//
// An element kind is the 2-bit code for a list head used throughout: 0 boxed
// (`!eco.value`), 1 Int (`i64`), 2 Float (`f64`), 3 Char (`i32`). A scalar is
// pushed as a 64-bit pattern together with its kind. A prepend is either
// `eco.construct.list` or a direct `eco.call` of `Elm_Kernel_List_cons` or
// its `_Int`, `_Float` and `_Char` variants; both carry the head as operand 0
// and the tail as operand 1.
//
// The pass does nothing unless some `func.func` in the module has the
// `eco.list_chunks` attribute. When one does, it considers every function in
// the module. It has three rewrites, called Phase 1 to 3 in the code, and runs
// them in the order 3, 1, 2:
//
// - Phase 3 replaces each `eco.list.map` with a loop that walks the input,
//   calls the callback on each element, pushes the result, and ends with
//   `eco_scratch_finish_fwd`. When `ECO_LIST_MAP_EXPAND` is exactly `0` it
//   emits a loop that reverses the input and conses the results instead.
// - Phase 1 rewrites `scf.while` loops that have a cons-accumulator: an
//   iteration argument that every path through the loop body either passes
//   on unchanged or extends with prepends, possibly through the results of
//   `scf.if`, `scf.index_switch` or `eco.case`. Each prepend becomes a push
//   at the same place, the accumulator is passed on unchanged, and
//   `eco_scratch_finish` after the loop builds the list in front of the
//   loop's initial value. Pushes run in the order the prepends ran and finish
//   reverses them, so the result is the list the loop would have built.
// - Phase 2 rewrites unwind-cons recursion: a function whose returned value
//   is a chain of prepends around a call to itself. Each prepend becomes a
//   push placed before the recursion, the function returns what lies under
//   the prepends unchanged, and every call from another function is wrapped
//   in a mark and an `eco_scratch_finish_fwd`.
//
// Phase 3 runs first because its forward loop contains no prepends, so Phase
// 1 finds nothing to rewrite in it. The loop emitted under
// `ECO_LIST_MAP_EXPAND=0` does accumulate with `eco.construct.list` in an
// `scf.while`, and Phase 1 may rewrite it.
//
// The pass declares the runtime functions its rewrites call as private kernel
// functions. Two read-only scans run in parallel through `eco::forEachChunk`;
// every rewrite runs on the calling thread. When `ECO_LIST_TEMPLATE_DEBUG` is
// set to any value, the pass prints to stderr how many candidates each phase
// rewrote and why the others were rejected.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/Dominance.h"
#include "mlir/IR/BuiltinOps.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"
#include "EcoParallel.h"
#include "EcoSymbolGraph.h"

#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/StringSwitch.h"
#include <cstdlib>
#include <map>
#include <string>

using namespace mlir;
using namespace ::eco;

namespace {

/// The runtime function that returns the current scratch-stack mark.
constexpr const char *kMarkFn = "eco_scratch_mark";
/// The runtime function that pushes one boxed element.
constexpr const char *kPushBoxedFn = "eco_scratch_push_boxed";
/// The runtime function that pushes one scalar element as its 64-bit pattern and element kind.
constexpr const char *kPushScalarFn = "eco_scratch_push_scalar";
/// The runtime function that builds the entries above a mark, in reverse push order, in front of a tail.
constexpr const char *kFinishFn = "eco_scratch_finish";
/// The runtime function that builds the entries above a mark, in push order, in front of a rest.
constexpr const char *kFinishFwdFn = "eco_scratch_finish_fwd";
/// The kernel function that reverses a list, used by the `ECO_LIST_MAP_EXPAND=0` form of Phase 3.
constexpr const char *kReverseFn = "Elm_Kernel_List_reverse";

/// Counts of Phase 1 candidates and the reasons they were rejected, printed
/// when `ECO_LIST_TEMPLATE_DEBUG` is set.
struct BailStats {
    unsigned whiles = 0, valueArgs = 0, beforeFwd = 0, beforeUses = 0,
             chainFail = 0, chainEmpty = 0, baseUses = 0, kinds = 0,
             rewritten = 0;
    // Reasons `walkChain` rejected a chain.
    unsigned wcBlockArg = 0, wcConsUses = 0, wcHeadTy = 0,
             wcRegionShape = 0, wcMultiUse = 0, wcOtherOp = 0;
    /// Prints the counts to stderr.
    void dump() {
        fprintf(stderr,
                "[eco-list-template] whiles=%u valueArgs=%u bail{beforeFwd=%u "
                "beforeUses=%u chainFail=%u chainEmpty=%u baseUses=%u "
                "kinds=%u} rewritten=%u\n"
                "[eco-list-template] walkChain{blockArg=%u consUses=%u "
                "headTy=%u regionShape=%u multiUse=%u "
                "otherOp=%u}\n",
                whiles, valueArgs, beforeFwd, beforeUses, chainFail,
                chainEmpty, baseUses, kinds, rewritten, wcBlockArg,
                wcConsUses, wcHeadTy, wcRegionShape, wcMultiUse,
                wcOtherOp);
    }
};

/// Counts of functions Phase 2 considered and the reasons it rejected them,
/// printed when `ECO_LIST_TEMPLATE_DEBUG` is set.
///
/// The pass keeps two: one over every function, and one over functions whose
/// name contains `List_foldrHelper_$_`. Counting has no effect on the output.
struct UnwindBailStats {
    unsigned seen = 0, multiBlock = 0, retShape = 0, walkFail = 0,
             noLinks = 0, noSelfCalls = 0, kindMix = 0, selfEscape = 0,
             domFail = 0, useShape = 0, noOuter = 0, ok = 0;
    /// Prints the counts to stderr, labelled with `what`.
    void tally(const char *what) {
        fprintf(stderr,
                "[eco-list-template] unwind-bail(%s) seen=%u ok=%u "
                "bail{multiBlock=%u retShape=%u walkFail=%u noLinks=%u "
                "noSelfCalls=%u kindMix=%u selfEscape=%u domFail=%u "
                "useShape=%u noOuter=%u}\n",
                what, seen, ok, multiBlock, retShape, walkFail, noLinks,
                noSelfCalls, kindMix, selfEscape, domFail, useShape, noOuter);
    }
};

/// One prepend found in a cons chain, with its element kind.
///
/// `op` points into the IR being rewritten and is valid until the rewrite
/// erases it.
struct ConsLink {
    Operation *op;
    int64_t kind;  // 2-bit element kind (0 boxed, 1 Int, 2 Float, 3 Char)
};

/// Returns the element kind of `op` if it is a direct call of
/// `Elm_Kernel_List_cons` or one of its typed variants with two operands and
/// one result, and -1 otherwise.
int64_t kernelConsKind(Operation *op) {
    auto call = dyn_cast<eco::CallOp>(op);
    if (!call)
        return -1;
    auto callee = call.getCalleeAttr();
    if (!callee || call->getNumOperands() != 2 ||
        call->getNumResults() != 1)
        return -1;
    return llvm::StringSwitch<int64_t>(callee.getValue())
        .Case("Elm_Kernel_List_cons", 0)
        .Case("Elm_Kernel_List_cons_Int", 1)
        .Case("Elm_Kernel_List_cons_Float", 2)
        .Case("Elm_Kernel_List_cons_Char", 3)
        .Default(-1);
}

/// The prepends found for one `scf.while` iteration argument by `walkChain`
/// and `walkChainQ`, and whether the walk accepted it.
struct Chain {
    SmallVector<ConsLink, 8> conses;
    // The exact operand slots through which the base (after-region block
    // argument) is allowed to be used. After the walk, every use of the
    // base must be one of these.
    SmallPtrSet<OpOperand *, 8> baseUses;
    /// False once a walk has rejected the chain; later walks then do nothing.
    bool ok = true;
    /// Where to count rejection reasons, or null when not counting.
    BailStats *bs = nullptr;
    llvm::SmallVector<Operation *, 4> otherOps;  // debug: chain-breaking ops
};

/// Follows `v` back towards `base` and records it in `ch` if `v` is `base`
/// with zero or more prepends in front, of which some may be conditional.
///
/// `slot` is the operand that consumes `v`. Each operand through which `base`
/// is reached is added to `ch.baseUses`, and each prepend to `ch.conses`. The
/// walk passes through a single-use result of `scf.if`, `scf.index_switch` or
/// `eco.case` by following the same result of every region's single-block
/// yield. Any other defining operation, a block argument other than `base`,
/// a prepend whose result has more than one use, or a head whose type does not
/// match its element kind sets `ch.ok` to false. A value equal to `altBase`,
/// when given, is accepted and not recorded.
void walkChain(Value v, Value base, OpOperand &slot, Chain &ch,
               Value altBase = nullptr) {
    if (!ch.ok)
        return;
    if (v == base) {
        ch.baseUses.insert(&slot);
        return;
    }
    // Secondary (result-slot) walks may thread their own placeholder
    // through unchanged on continue iterations.
    if (altBase && v == altBase)
        return;
    Operation *def = v.getDefiningOp();
    if (!def) {
        if (ch.bs) ch.bs->wcBlockArg++;
        ch.ok = false;
        return;
    }
    int64_t consKind = -1;
    if (auto c = dyn_cast<eco::ListConstructOp>(def)) {
        consKind = c.getHeadKind();
    } else {
        consKind = kernelConsKind(def);
    }
    if (consKind >= 0) {
        if (!def->getResult(0).hasOneUse()) {
            if (ch.bs) ch.bs->wcConsUses++;
            ch.ok = false;
            return;
        }
        Type ht = def->getOperand(0).getType();
        bool htOk = (consKind == 0 && isa<eco::ValueType>(ht)) ||
                    (consKind == 1 && ht.isInteger(64)) ||
                    (consKind == 2 && ht.isF64()) ||
                    (consKind == 3 && eco::isEcoCharType(ht));
        if (!htOk) {
            if (ch.bs) ch.bs->wcHeadTy++;
            ch.ok = false;
            return;
        }
        ch.conses.push_back(ConsLink{def, consKind});
        // Both link forms carry (head, tail) as operands 0/1.
        walkChain(def->getOperand(1), base, def->getOpOperand(1), ch,
                  altBase);
        return;
    }
    if (isa<scf::IfOp, scf::IndexSwitchOp, eco::CaseOp>(def)) {
        if (!v.hasOneUse()) {
            if (ch.bs) ch.bs->wcMultiUse++;
            ch.ok = false;
            return;
        }
        unsigned idx = cast<OpResult>(v).getResultNumber();
        for (Region &r : def->getRegions()) {
            if (!r.hasOneBlock()) {
                if (ch.bs) ch.bs->wcRegionShape++;
                ch.ok = false;
                return;
            }
            Operation *term = r.front().getTerminator();
            if (!isa<scf::YieldOp, eco::YieldOp>(term) ||
                term->getNumOperands() <= idx) {
                if (ch.bs) ch.bs->wcRegionShape++;
                ch.ok = false;
                return;
            }
            walkChain(term->getOperand(idx), base, term->getOpOperand(idx),
                      ch, altBase);
            if (!ch.ok)
                return;
        }
        return;
    }
    if (ch.bs) {
        ch.bs->wcOtherOp++;
        ch.otherOps.push_back(def);
    }
    ch.ok = false;
}

/// Walks a secondary result slot of a loop, as `walkChain` does, but taking
/// account of the loop's done flag.
///
/// `vq` is the value yielded in the slot and `vd` the done flag yielded
/// alongside it. Where `vd` is the constant false, the iteration continues and
/// the slot is not read, so any value is accepted; a direct yield of `base`
/// there is still recorded in `ch.baseUses`. Where `vd` is the constant true,
/// or is not known, the slot must be `baseQ` (the slot's own iteration
/// argument) or a chain rooted at `base`. A constant there, such as an empty
/// list returned on exit, rejects the chain. Where `vq` and `vd` are results of
/// the same `scf.if`, `scf.index_switch` or `eco.case`, each region's yields
/// are walked in turn.
void walkChainQ(Value vq, Value vd, Value base, Value baseQ,
                OpOperand &slotQ, Chain &ch) {
    if (!ch.ok)
        return;
    if (auto cst = vd.getDefiningOp<arith::ConstantOp>()) {
        bool isFalse = false, isBool = false;
        if (auto ba = dyn_cast<BoolAttr>(cst.getValue())) {
            isBool = true;
            isFalse = !ba.getValue();
        } else if (auto ia = dyn_cast<IntegerAttr>(cst.getValue())) {
            if (ia.getType().isInteger(1)) {
                isBool = true;
                isFalse = ia.getValue().isZero();
            }
        }
        if (isBool) {
            if (isFalse) {
                // Continue arm: the slot is dead; account a direct base
                // yield so the closure check stays exact.
                if (vq == base)
                    ch.baseUses.insert(&slotQ);
                return;
            }
            walkChain(vq, base, slotQ, ch, baseQ);
            return;
        }
    }
    Operation *dq = vq.getDefiningOp();
    Operation *dd = vd.getDefiningOp();
    if (dq && dq == dd &&
        isa<scf::IfOp, scf::IndexSwitchOp, eco::CaseOp>(dq)) {
        if (!vq.hasOneUse()) {
            ch.ok = false;
            return;
        }
        unsigned qi = cast<OpResult>(vq).getResultNumber();
        unsigned di = cast<OpResult>(vd).getResultNumber();
        for (Region &r : dq->getRegions()) {
            if (!r.hasOneBlock()) {
                ch.ok = false;
                return;
            }
            Operation *term = r.front().getTerminator();
            if (!isa<scf::YieldOp, eco::YieldOp>(term) ||
                term->getNumOperands() <= std::max(qi, di)) {
                ch.ok = false;
                return;
            }
            walkChainQ(term->getOperand(qi), term->getOperand(di), base,
                       baseQ, term->getOpOperand(qi), ch);
            if (!ch.ok)
                return;
        }
        return;
    }
    walkChain(vq, base, slotQ, ch, baseQ);
}

/// Adds a private declaration of `name` with type `ft` to the end of `m`,
/// marked as a kernel function with the given logical parameter and result
/// types, unless `m` already has a function of that name.
void ensureDecl(ModuleOp m, StringRef name, FunctionType ft,
                ArrayRef<StringRef> paramKinds,
                ArrayRef<StringRef> resultKinds) {
    if (m.lookupSymbol<func::FuncOp>(name))
        return;
    OpBuilder b(m.getContext());
    b.setInsertionPointToEnd(m.getBody());
    auto f = b.create<func::FuncOp>(m.getLoc(), name, ft);
    f.setPrivate();
    f->setAttr("is_kernel", b.getBoolAttr(true));
    f->setAttr("eco.logical_param_types", b.getStrArrayAttr(paramKinds));
    f->setAttr("eco.logical_result_types", b.getStrArrayAttr(resultKinds));
}

/// The `eco-list-template` pass: the three rewrites this file describes.
///
/// The data members are the Phase 2 symbol-use index and flags, which
/// `runOnOperation` resets at the start of Phase 2, and the debug lists, which
/// are never cleared.
struct EcoListTemplatePass
    : public PassWrapper<EcoListTemplatePass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoListTemplatePass)

    StringRef getArgument() const override { return "eco-list-template"; }
    StringRef getDescription() const override {
        return "Rewrite cons-accumulation loops to scratch-stack chunk "
               "builds (chunked lists Tier B)";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<arith::ArithDialect, func::FuncDialect,
                        scf::SCFDialect, eco::EcoDialect>();
    }

    void runOnOperation() override {
        ModuleOp m = getOperation();

        bool enabled = false;
        for (auto f : m.getBody()->getOps<func::FuncOp>()) {
            if (f->hasAttr("eco.list_chunks")) {
                enabled = true;
                break;
            }
        }
        if (!enabled)
            return;

        bool declsMade = false;
        BailStats bs;
        bool debug = std::getenv("ECO_LIST_TEMPLATE_DEBUG") != nullptr;

        // Phase 3 runs first: eco.list.map expands into its own loop. The
        // default expansion pushes directly and carries no cons chain, so the
        // while-rewriter below leaves it alone; the ECO_LIST_MAP_EXPAND=0
        // collapse loop may still be rewritten by Phase 1.
        // One parallel pre-scan finds the functions holding an eco.list.map or an
        // scf.while, so the serial phases below walk only those, in module order.
        // A function with a list map is in both lists, since its expansion is a
        // while loop.
        SmallVector<func::FuncOp> withMap, withWhile;
        {
            SmallVector<func::FuncOp> all;
            for (auto f : m.getBody()->getOps<func::FuncOp>())
                if (!f.getBody().empty())
                    all.push_back(f);
            std::vector<uint8_t> flags(all.size(), 0);
            eco::forEachChunk(m.getContext(), all.size(),
                              [&](size_t lo, size_t hi) {
                                  for (size_t i = lo; i < hi; ++i)
                                      all[i].walk([&](Operation *op) {
                                          if (isa<eco::ListMapOp>(op))
                                              flags[i] |= 1;
                                          else if (isa<scf::WhileOp>(op))
                                              flags[i] |= 2;
                                      });
                              });
            for (size_t i = 0; i < all.size(); ++i) {
                if (flags[i] & 1)
                    withMap.push_back(all[i]);
                if (flags[i])
                    withWhile.push_back(all[i]);
            }
        }
        unsigned mapExpanded = expandListMaps(m, withMap, declsMade);
        if (debug)
            fprintf(stderr, "[eco-list-template] mapExpand{expanded=%u}\n",
                    mapExpanded);
        // Post-order walk: inner loops are transformed before outer ones,
        // which is what keeps nested mark/finish pairs balanced.
        for (func::FuncOp f : withWhile)
            f.walk([&](scf::WhileOp w) {
                bs.whiles++;
                if (tryRewrite(m, w, declsMade, debug ? &bs : nullptr))
                    bs.rewritten++;
            });

        // Phase 2: unwind-cons recursion (cons around a self-call result,
        // the foldr/encoder family). Snapshot the function list first --
        // rewrites add call-site wrappers inside other functions.
        SmallVector<func::FuncOp, 64> fns;
        for (auto f : m.getBody()->getOps<func::FuncOp>())
            if (!f.getBody().empty())
                fns.push_back(f);
        unsigned unwindRewritten = 0;
        useIndexBuilt = useIndexFailed = finishFwdMade = false;
        useIndex.clear();
        UnwindBailStats ubAll, ubFoldrHelper;
        for (auto f : fns) {
            bool isFh =
                f.getSymName().contains("List_foldrHelper_$_");
            if (tryRewriteUnwind(m, f, declsMade,
                                 debug ? &ubAll : nullptr,
                                 (debug && isFh) ? &ubFoldrHelper : nullptr))
                unwindRewritten++;
        }
        if (debug) {
            fprintf(stderr, "[eco-list-template] unwind rewritten=%u\n",
                    unwindRewritten);
            ubAll.tally("all");
            ubFoldrHelper.tally("foldrHelper");
        }

        if (debug) {
            bs.dump();
            std::map<std::string, unsigned> hist;
            for (Operation *op : debugOtherOps)
                hist[op->getName().getStringRef().str()]++;
            for (auto &kv : hist)
                fprintf(stderr, "[eco-list-template] breaker %-28s %u\n",
                        kv.first.c_str(), kv.second);
            std::map<std::string, unsigned> bhist;
            for (Operation *op : debugBaseUseOwners)
                bhist[op->getName().getStringRef().str()]++;
            for (auto &kv : bhist)
                fprintf(stderr, "[eco-list-template] base-use %-28s %u\n",
                        kv.first.c_str(), kv.second);
        }
    }

    // The Phase 2 index of symbol uses, built once per run by the first
    // `tryRewriteUnwind` call. `useIndexFailed` is never set to true.
    // `finishFwdMade` records that `eco_scratch_finish_fwd` has been declared.
    bool useIndexBuilt = false, useIndexFailed = false, finishFwdMade = false;
    llvm::DenseMap<StringAttr, SmallVector<Operation *, 2>> useIndex;

    // Operations that ended a chain, and owners of unaccounted base uses, kept
    // for the debug histograms. These are not cleared between runs.
    llvm::SmallVector<Operation *, 16> debugOtherOps;
    llvm::SmallVector<Operation *, 16> debugBaseUseOwners;

    /// Rewrites the first cons-accumulator iteration argument of `w` that
    /// qualifies, and returns whether it rewrote one.
    ///
    /// An `!eco.value` argument qualifies when its before-region argument is used
    /// only to forward it through `scf.condition` in the same position, the value
    /// yielded for it is a chain of prepends rooted at its after-region argument
    /// (see `walkChain`), every prepend has the same element kind, and there is at
    /// least one prepend. A use of the after-region argument that is not part of
    /// the chain is allowed only where it is yielded, possibly through region
    /// results, into another position: a secondary result slot. Such a slot must
    /// itself be forwarded unchanged through `scf.condition`, and is checked with
    /// `walkChainQ` against the loop's single `i1` argument if there is one. Only
    /// one argument per loop is rewritten. `declsMade` records whether the
    /// runtime declarations have been added. Counts go to `bs` when it is not
    /// null.
    bool tryRewrite(ModuleOp m, scf::WhileOp w, bool &declsMade,
                    BailStats *bs) {
        auto condOp = w.getConditionOp();
        auto yieldOp = w.getYieldOp();
        unsigned n = w.getInits().size();

        for (unsigned p = 0; p < n; ++p) {
            if (!isa<eco::ValueType>(w.getInits()[p].getType()))
                continue;
            if (bs) bs->valueArgs++;

            // Before region: the candidate arg must pass through untouched —
            // its single use is the condition's forwarded operand p (operand
            // p + 1 on scf.condition; operand 0 is the i1 condition).
            Value beforeArg = w.getBefore().getArgument(p);
            if (condOp.getArgs()[p] != beforeArg) {
                if (bs) bs->beforeFwd++;
                continue;
            }
            bool beforeOk = true;
            for (OpOperand &u : beforeArg.getUses()) {
                if (u.getOwner() != condOp || u.getOperandNumber() != p + 1) {
                    beforeOk = false;
                    break;
                }
            }
            if (!beforeOk) {
                if (bs) bs->beforeUses++;
                continue;
            }

            // After region: yield operand p must be base extended by conses.
            Value base = w.getAfterArguments()[p];
            Chain ch;
            ch.bs = bs;
            walkChain(yieldOp->getOperand(p), base, yieldOp->getOpOperand(p),
                      ch);
            if (bs)
                for (Operation *op : ch.otherOps)
                    debugOtherOps.push_back(op);
            if (!ch.ok) {
                if (bs) bs->chainFail++;
                continue;
            }

            // Joinpoint-normalized TCO loops carry a done-flag and a RESULT
            // slot: at the exit iteration the accumulated list is yielded
            // into slot q as well (downstream reads result q, not p). Any
            // base use at another yield position nominates q as a secondary
            // slot: every path there must be its own placeholder identity or
            // a chain rooted at the primary base. Post-rewrite both results
            // collapse to threaded inits, and result p (pure base thread) is
            // exactly finish's `next`.
            SmallVector<unsigned, 2> qSlots;
            bool basesOk = true;
            for (OpOperand &u : base.getUses()) {
                if (ch.baseUses.count(&u))
                    continue;
                // Ascend from the use through single-use region results to
                // the top-level yield slot it feeds (region terminators
                // inside the case tree yield the base into the result slot).
                OpOperand *cur = &u;
                int q = -1;
                while (true) {
                    Operation *own = cur->getOwner();
                    if (own == yieldOp.getOperation()) {
                        q = static_cast<int>(cur->getOperandNumber());
                        break;
                    }
                    if (isa<scf::YieldOp, eco::YieldOp>(own)) {
                        Operation *parent = own->getParentOp();
                        if (!isa<scf::IfOp, scf::IndexSwitchOp, eco::CaseOp>(
                                parent))
                            break;
                        unsigned idx = cur->getOperandNumber();
                        if (idx >= parent->getNumResults())
                            break;
                        Value r = parent->getResult(idx);
                        if (!r.hasOneUse())
                            break;
                        cur = &*r.getUses().begin();
                        continue;
                    }
                    break;
                }
                if (q >= 0 && static_cast<unsigned>(q) != p) {
                    if (!llvm::is_contained(qSlots, static_cast<unsigned>(q)))
                        qSlots.push_back(static_cast<unsigned>(q));
                    continue;
                }
                basesOk = false;
                if (bs) debugBaseUseOwners.push_back(u.getOwner());
                break;
            }
            if (!basesOk) {
                if (bs) bs->baseUses++;
                continue;
            }
            for (unsigned q : qSlots) {
                if (!ch.ok)
                    break;
                Value beforeArgQ = w.getBefore().getArgument(q);
                bool qFwd = condOp.getArgs()[q] == beforeArgQ;
                if (qFwd) {
                    for (OpOperand &u : beforeArgQ.getUses()) {
                        if (u.getOwner() != condOp ||
                            u.getOperandNumber() != q + 1) {
                            qFwd = false;
                            break;
                        }
                    }
                }
                if (!qFwd) {
                    ch.ok = false;
                    break;
                }
                // Locate the done flag: the unique i1 iter arg, if any.
                int done = -1;
                for (unsigned i = 0; i < n; ++i) {
                    if (w.getInits()[i].getType().isInteger(1)) {
                        done = (done == -1) ? static_cast<int>(i) : -2;
                    }
                }
                if (done >= 0) {
                    walkChainQ(yieldOp->getOperand(q),
                               yieldOp->getOperand(static_cast<unsigned>(done)),
                               base, w.getAfterArguments()[q],
                               yieldOp->getOpOperand(q), ch);
                } else {
                    walkChain(yieldOp->getOperand(q), base,
                              yieldOp->getOpOperand(q), ch,
                              w.getAfterArguments()[q]);
                }
            }
            if (!ch.ok) {
                if (bs) bs->chainFail++;
                continue;
            }
            if (ch.conses.empty()) {
                if (bs) bs->chainEmpty++;
                continue;
            }
            // Re-verify closure: every base use must now be recorded (the
            // q walks visit the region-terminator slots arm-wise).
            for (OpOperand &u : base.getUses()) {
                if (!ch.baseUses.count(&u)) {
                    basesOk = false;
                    break;
                }
            }
            if (!basesOk) {
                if (bs) bs->baseUses++;
                continue;
            }

            // All conses must agree on the element kind.
            int64_t kind = ch.conses.front().kind;
            bool kindsOk = true;
            for (auto &c : ch.conses) {
                if (c.kind != kind) {
                    kindsOk = false;
                    break;
                }
            }
            if (!kindsOk) {
                if (bs) bs->kinds++;
                continue;
            }

            rewrite(m, w, p, qSlots, ch, kind, declsMade);
            return true;  // one accumulator per while (scratch contiguity)
        }
        return false;
    }

    /// Rewrites argument `p` of `w`, whose prepends `ch` holds, to use the
    /// scratch stack: a mark before the loop, a push in place of each prepend,
    /// and an `eco_scratch_finish` of the loop's result `p` after it with element
    /// kind `kind`. Uses of result `p` and of each secondary slot in `qSlots` are
    /// replaced by the finished list. Declares the runtime functions first unless
    /// `declsMade` is already true.
    void rewrite(ModuleOp m, scf::WhileOp w, unsigned p,
                 ArrayRef<unsigned> qSlots, Chain &ch, int64_t kind,
                 bool &declsMade) {
        MLIRContext *ctx = m.getContext();
        OpBuilder b(w);
        Location loc = w.getLoc();
        Type i64 = b.getI64Type();
        Type value = eco::ValueType::get(ctx);

        if (!declsMade) {
            declsMade = true;
            ensureDecl(m, kMarkFn, FunctionType::get(ctx, {}, {i64}), {},
                       {"i64"});
            ensureDecl(m, kPushBoxedFn, FunctionType::get(ctx, {value}, {}),
                       {"value"}, {});
            ensureDecl(m, kPushScalarFn,
                       FunctionType::get(ctx, {i64, i64}, {}), {"i64", "i64"},
                       {});
            ensureDecl(m, kFinishFn,
                       FunctionType::get(ctx, {i64, value, i64}, {value}),
                       {"i64", "value", "i64"}, {"value"});
        }

        auto mark = b.create<eco::CallOp>(
            loc, TypeRange{i64}, ValueRange{},
            FlatSymbolRefAttr::get(ctx, kMarkFn), nullptr, nullptr);

        for (auto &link : ch.conses) {
            Operation *c = link.op;
            OpBuilder cb(c);
            Location cl = c->getLoc();
            Value h = c->getOperand(0);
            if (isa<eco::ValueType>(h.getType())) {
                cb.create<eco::CallOp>(
                    cl, TypeRange{}, ValueRange{h},
                    FlatSymbolRefAttr::get(ctx, kPushBoxedFn), nullptr,
                    nullptr);
            } else {
                Value bits = h;
                if (h.getType().isF64())
                    bits = cb.create<arith::BitcastOp>(cl, i64, h);
                else if (eco::isEcoCharType(h.getType()))
                    bits = cb.create<arith::ExtUIOp>(cl, i64, h);
                Value kc = cb.create<arith::ConstantOp>(
                    cl, cb.getI64IntegerAttr(kind));
                cb.create<eco::CallOp>(
                    cl, TypeRange{}, ValueRange{bits, kc},
                    FlatSymbolRefAttr::get(ctx, kPushScalarFn), nullptr,
                    nullptr);
            }
            c->getResult(0).replaceAllUsesWith(c->getOperand(1));
            c->erase();
        }

        b.setInsertionPointAfter(w);
        Value res = w.getResult(p);
        Value kc =
            b.create<arith::ConstantOp>(loc, b.getI64IntegerAttr(kind));
        auto fin = b.create<eco::CallOp>(
            loc, TypeRange{value}, ValueRange{mark.getResults()[0], res, kc},
            FlatSymbolRefAttr::get(ctx, kFinishFn), nullptr, nullptr);
        res.replaceAllUsesExcept(fin.getResults()[0], fin);
        // Secondary result slots carried the same accumulated list out of
        // the exit iteration; their post-rewrite value is a placeholder.
        for (unsigned q : qSlots)
            w.getResult(q).replaceAllUsesWith(fin.getResults()[0]);
    }

    //===------------------------------------------------------------------===//
    // Phase 3: eco.list.map expansion.
    //
    // `eco.list.map` applies a callback to every element of a list. The op's
    // presence is the front end's permission to apply the callback first element
    // first; nothing here checks that this is allowed.
    //
    // Shape produced (one op -> one loop):
    //
    //   %m    = call @eco_scratch_mark()
    //   %last = scf.while (%cur = %xs) {
    //             %t = eco.get_tag %cur ; %c = cmpi eq %t, 1   // Cons|ConsChunk
    //             scf.condition(%c) %cur
    //           } do {
    //           ^bb(%cur):
    //             %x    = eco.project.list_head %cur      // typed per in_kind
    //             %y    = <callback>                      // direct or generic
    //             call @eco_scratch_push_{boxed,scalar}(%y[, out_kind])
    //             %next = eco.project.list_tail %cur
    //             scf.yield %next
    //           }
    //   %nil  = eco.constant Empty
    //   %r    = call @eco_scratch_finish_fwd(%m, %nil, out_kind)
    //
    // The loop carries the list as its only argument, forwards it unchanged
    // through scf.condition, and steps it with a tail projection. That is the
    // loop form `EcoListCursor`, later in the pipeline, rewrites to walk a
    // chunked list without allocating a view per element. Because the scratch
    // entries are GC roots, the callback may allocate, and a map nested in the
    // callback balances its own mark and finish. This pass runs before
    // `EcoGCPrepare`, so the list being walked is an ordinary SSA value across
    // the callback call.
    //===------------------------------------------------------------------===//

    /// Returns false when `ECO_LIST_MAP_EXPAND` is exactly `0`, which selects the
    /// order-preserving collapse; any other value, or none, selects the forward
    /// loop.
    static bool mapExpandEnabled() {
        const char *e = ::getenv("ECO_LIST_MAP_EXPAND");
        if (!e || !*e)
            return true;
        return !(e[0] == '0' && e[1] == '\0');
    }

    /// Returns the entry block of `r`, creating it with arguments of types
    /// `argTys` if `r` has no block. `scf::WhileOp`'s builders differ on whether
    /// they create the region blocks, so this asks the region.
    static Block *ensureRegionBlock(OpBuilder &b, Region &r,
                                    ArrayRef<Type> argTys, Location loc) {
        if (!r.empty())
            return &r.front();
        SmallVector<Location, 4> locs(argTys.size(), loc);
        return b.createBlock(&r, r.end(), argTys, locs);
    }

    /// Returns the SSA type of a list head with element kind `kind`: `i64`,
    /// `f64` or `i16` for 1, 2 or 3, and `!eco.value` for any other value
    /// (REP_BOUNDARY_001).
    static Type headTypeForKind(MLIRContext *ctx, int64_t kind) {
        switch (kind) {
            case 1: return IntegerType::get(ctx, 64);
            case 2: return Float64Type::get(ctx);
            case 3: return eco::getEcoCharType(ctx);
            default: return eco::ValueType::get(ctx);
        }
    }

    /// Emits at `b` the push of `y`, a callback result: a boxed push for an
    /// `!eco.value`, and otherwise a scalar push of `y` widened to a 64-bit
    /// pattern (an `f64` bitcast, an `i16` zero-extended) with kind `outKind`.
    void emitPush(OpBuilder &b, Location loc, MLIRContext *ctx, Value y,
                  int64_t outKind) {
        Type i64 = IntegerType::get(ctx, 64);
        if (isa<eco::ValueType>(y.getType())) {
            b.create<eco::CallOp>(loc, TypeRange{}, ValueRange{y},
                                  FlatSymbolRefAttr::get(ctx, kPushBoxedFn),
                                  nullptr, nullptr);
            return;
        }
        Value bits = y;
        if (y.getType().isF64())
            bits = b.create<arith::BitcastOp>(loc, i64, y);
        else if (eco::isEcoCharType(y.getType()))
            bits = b.create<arith::ExtUIOp>(loc, i64, y);
        Value kc = b.create<arith::ConstantOp>(loc, b.getI64IntegerAttr(outKind));
        b.create<eco::CallOp>(loc, TypeRange{}, ValueRange{bits, kc},
                              FlatSymbolRefAttr::get(ctx, kPushScalarFn),
                              nullptr, nullptr);
    }

    /// Emits at `b` the call of `op`'s callback on element `x`, returning a
    /// result of type `resultTy`.
    ///
    /// When `op` names a callee the call is direct, with the captures followed by
    /// `x` and no closure argument; such a call can later be marked gc-leaf when
    /// the callee allocates nothing (CGEN_072). Otherwise it is a saturated call
    /// of the closure value `op.getCallback()` on `x`.
    Value emitCallback(OpBuilder &b, Location loc, MLIRContext *ctx,
                       eco::ListMapOp op, Value x, Type resultTy) {
        if (auto callee = op.getCalleeAttr()) {
            SmallVector<Value, 4> args(op.getCaptures().begin(),
                                       op.getCaptures().end());
            args.push_back(x);
            auto call = b.create<eco::CallOp>(loc, TypeRange{resultTy}, args,
                                              callee, nullptr, nullptr);
            return call.getResults()[0];
        }
        // Generic arm: saturated indirect call through the closure value.
        auto call = b.create<eco::CallOp>(
            loc, TypeRange{resultTy}, ValueRange{op.getCallback(), x},
            /*callee=*/nullptr, /*musttail=*/nullptr,
            /*remaining_arity=*/b.getI64IntegerAttr(1));
        return call.getResults()[0];
    }

    /// Emits at `b` the forward map loop over `input` shown above: each element
    /// is passed to `op`'s callback and the result pushed. The mark and the
    /// finish are emitted by the caller.
    void emitForwardLoop(OpBuilder &b, Location loc, MLIRContext *ctx,
                         eco::ListMapOp op, Value input, Type resultTy) {
        Type value = eco::ValueType::get(ctx);
        Type i32 = IntegerType::get(ctx, 32);

        auto whileOp = b.create<scf::WhileOp>(loc, TypeRange{value},
                                              ValueRange{input});

        // Before region: non-empty test, forwarding the cursor unchanged.
        {
            OpBuilder::InsertionGuard guard(b);
            Block *before =
                ensureRegionBlock(b, whileOp.getBefore(), {value}, loc);
            b.setInsertionPointToEnd(before);
            Value cur = before->getArgument(0);
            Value tag = b.create<eco::GetTagOp>(loc, i32, cur);
            // eco_get_tag gives the list Cons tag 1 for both a cell and a chunk
            // (RuntimeExports.cpp), and the empty list is the Empty constant, whose
            // tag is not 1.
            Value one = b.create<arith::ConstantOp>(loc, b.getI32IntegerAttr(1));
            Value nonEmpty = b.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, tag, one);
            b.create<scf::ConditionOp>(loc, nonEmpty, ValueRange{cur});
        }

        // After region: project, apply, push, step.
        {
            OpBuilder::InsertionGuard guard(b);
            Block *after =
                ensureRegionBlock(b, whileOp.getAfter(), {value}, loc);
            b.setInsertionPointToEnd(after);
            Value cur = after->getArgument(0);
            Type headTy = headTypeForKind(ctx, op.getInKind());
            Value x = b.create<eco::ListHeadOp>(loc, headTy, cur);
            Value y = emitCallback(b, loc, ctx, op, x, resultTy);
            emitPush(b, loc, ctx, y, op.getOutKind());
            Value next = b.create<eco::ListTailOp>(loc, value, cur);
            b.create<scf::YieldOp>(loc, ValueRange{next});
        }
    }

    /// Emits at `b` the `ECO_LIST_MAP_EXPAND=0` form of `op` and returns the
    /// resulting list: `Elm_Kernel_List_reverse` of the input, then a loop that
    /// conses the callback's result for each element of the reversed list onto
    /// an accumulator that starts empty.
    ///
    /// The callback is therefore applied last element first, and the result is
    /// in the input's order. The input is copied once by the reversal.
    Value emitOrderPreservingCollapse(OpBuilder &b, Location loc,
                                      MLIRContext *ctx, eco::ListMapOp op,
                                      Type resultTy) {
        Type value = eco::ValueType::get(ctx);
        Type i32 = IntegerType::get(ctx, 32);
        Type i64 = IntegerType::get(ctx, 64);

        Value reversed =
            b.create<eco::CallOp>(
                 loc, TypeRange{value}, ValueRange{op.getInput()},
                 FlatSymbolRefAttr::get(ctx, kReverseFn), nullptr, nullptr)
                .getResults()[0];

        // Walk the reversed spine, consing each result onto the accumulator.
        // Cons order over a reversed input reproduces the forward result.
        Value nil = b.create<eco::ConstantOp>(loc, value,
                                              eco::ConstantKind::Empty);
        auto whileOp = b.create<scf::WhileOp>(loc, TypeRange{value, value},
                                              ValueRange{reversed, nil});
        {
            OpBuilder::InsertionGuard guard(b);
            Block *before = ensureRegionBlock(b, whileOp.getBefore(),
                                              {value, value}, loc);
            b.setInsertionPointToEnd(before);
            Value cur = before->getArgument(0);
            Value acc = before->getArgument(1);
            Value tag = b.create<eco::GetTagOp>(loc, i32, cur);
            Value one = b.create<arith::ConstantOp>(loc, b.getI32IntegerAttr(1));
            Value nonEmpty = b.create<arith::CmpIOp>(
                loc, arith::CmpIPredicate::eq, tag, one);
            b.create<scf::ConditionOp>(loc, nonEmpty, ValueRange{cur, acc});
        }
        {
            OpBuilder::InsertionGuard guard(b);
            Block *after = ensureRegionBlock(b, whileOp.getAfter(),
                                             {value, value}, loc);
            b.setInsertionPointToEnd(after);
            Value cur = after->getArgument(0);
            Value acc = after->getArgument(1);
            Type headTy = headTypeForKind(ctx, op.getInKind());
            Value x = b.create<eco::ListHeadOp>(loc, headTy, cur);
            Value y = emitCallback(b, loc, ctx, op, x, resultTy);
            Value newAcc = b.create<eco::ListConstructOp>(
                loc, value, y, acc,
                /*head_unboxed=*/!isa<eco::ValueType>(y.getType()),
                /*head_kind=*/op.getOutKind());
            Value next = b.create<eco::ListTailOp>(loc, value, cur);
            b.create<scf::YieldOp>(loc, ValueRange{next, newAcc});
        }
        (void)i64;
        return whileOp.getResult(1);
    }

    /// Expands every `eco.list.map` in the functions `fns` of `m`, declaring the
    /// runtime functions the chosen form needs, and returns how many it
    /// expanded. `declsMade` records whether the shared runtime declarations
    /// have been added.
    unsigned expandListMaps(ModuleOp m, ArrayRef<func::FuncOp> fns,
                            bool &declsMade) {
        SmallVector<eco::ListMapOp, 16> ops;
        for (func::FuncOp f : fns)
            f.walk([&](eco::ListMapOp op) { ops.push_back(op); });
        if (ops.empty())
            return 0;

        MLIRContext *ctx = m.getContext();
        Type i64 = IntegerType::get(ctx, 64);
        Type value = eco::ValueType::get(ctx);
        bool forward = mapExpandEnabled();

        if (forward) {
            if (!declsMade) {
                declsMade = true;
                ensureDecl(m, kMarkFn, FunctionType::get(ctx, {}, {i64}), {},
                           {"i64"});
                ensureDecl(m, kPushBoxedFn,
                           FunctionType::get(ctx, {value}, {}), {"value"}, {});
                ensureDecl(m, kPushScalarFn,
                           FunctionType::get(ctx, {i64, i64}, {}),
                           {"i64", "i64"}, {});
                ensureDecl(m, kFinishFn,
                           FunctionType::get(ctx, {i64, value, i64}, {value}),
                           {"i64", "value", "i64"}, {"value"});
            } else {
                ensureDecl(m, kMarkFn, FunctionType::get(ctx, {}, {i64}), {},
                           {"i64"});
                ensureDecl(m, kPushBoxedFn,
                           FunctionType::get(ctx, {value}, {}), {"value"}, {});
                ensureDecl(m, kPushScalarFn,
                           FunctionType::get(ctx, {i64, i64}, {}),
                           {"i64", "i64"}, {});
            }
            ensureDecl(m, kFinishFwdFn,
                       FunctionType::get(ctx, {i64, value, i64}, {value}),
                       {"i64", "value", "i64"}, {"value"});
        } else {
            ensureDecl(m, kReverseFn, FunctionType::get(ctx, {value}, {value}),
                       {"value"}, {"value"});
        }

        for (eco::ListMapOp op : ops) {
            OpBuilder b(op);
            Location loc = op.getLoc();
            // The callback's result type, the push kind and the finish kind all
            // come from out_kind, so they cannot disagree.
            Type resultTy = headTypeForKind(ctx, op.getOutKind());

            Value replacement;
            if (forward) {
                auto mark = b.create<eco::CallOp>(
                    loc, TypeRange{i64}, ValueRange{},
                    FlatSymbolRefAttr::get(ctx, kMarkFn), nullptr, nullptr);
                emitForwardLoop(b, loc, ctx, op, op.getInput(), resultTy);
                Value nil = b.create<eco::ConstantOp>(loc, value,
                                                      eco::ConstantKind::Empty);
                Value kc = b.create<arith::ConstantOp>(
                    loc, b.getI64IntegerAttr(op.getOutKind()));
                replacement =
                    b.create<eco::CallOp>(
                         loc, TypeRange{value},
                         ValueRange{mark.getResults()[0], nil, kc},
                         FlatSymbolRefAttr::get(ctx, kFinishFwdFn), nullptr,
                         nullptr)
                        .getResults()[0];
            } else {
                replacement =
                    emitOrderPreservingCollapse(b, loc, ctx, op, resultTy);
            }

            op.getResult().replaceAllUsesWith(replacement);
            op.erase();
        }
        return static_cast<unsigned>(ops.size());
    }

    //===------------------------------------------------------------------===//
    // Phase 2: unwind-cons recursion.
    //
    // Shape: a single-block function whose return value is a chain of prepends
    // ending at either a call to the function itself (the recursion) or any
    // other value (the rest). The chain may pass through the results of scf.if,
    // scf.index_switch and eco.case. Rewrite: each prepend becomes a push placed
    // before the operation that leads towards the recursion on its path -- the
    // self-call for prepends at the same level, the region operation for
    // prepends outside a region that recurses inside -- so pushes run in the
    // order of descent. The function then returns the rest unchanged, and every
    // call from another function becomes mark / call / finish_fwd, which builds
    // entry[mark] :: ... :: entry[top-1] :: rest.
    //===------------------------------------------------------------------===//

    /// One prepend in a Phase 2 chain and where its push goes.
    struct UnwindLink {
        Operation *cons;    // eco.construct.list or kernel-cons eco.call
        Operation *pushAt;  // the push precedes this; null until assigned
        int64_t kind;
    };

    /// The prepends and self-calls found in a function's return chain by
    /// `walkUnwind`, and whether it accepted the chain.
    struct UnwindPlan {
        SmallVector<UnwindLink, 16> links;
        SmallVector<Operation *, 4> selfCalls;  // self-calls ending the chain
        bool ok = true;
    };

    /// Sets the push position of each prepend in `run` that has none to before
    /// `barrier`, then empties `run`.
    void setRunBarrier(SmallVectorImpl<Operation *> &run, Operation *barrier,
                       UnwindPlan &plan) {
        for (Operation *c : run) {
            for (auto &l : plan.links) {
                if (l.cons == c && !l.pushAt)
                    l.pushAt = barrier;
            }
        }
        run.clear();
    }

    /// Collects into `plan` the prepends and self-calls of the chain ending in
    /// `v`, inside a function named `selfName`, recursing into region results.
    ///
    /// A self-call ends the chain and must be single-use and not musttail. A
    /// region result ends this level and the walk continues into each region's
    /// yield. A block argument, a call of another function or any other
    /// operation is the rest. Prepends at one level get their push before the
    /// self-call or region operation that ends the level, or, when the level ends
    /// at the rest, before the outermost prepend. Sets `plan.ok` to false on any
    /// shape it cannot handle.
    void walkUnwind(Value v, StringRef selfName, UnwindPlan &plan) {
        SmallVector<Operation *, 8> run;  // outer -> inner cons run
        while (plan.ok) {
            Operation *def = v.getDefiningOp();
            if (!def)
                break;  // block-arg leaf = rest
            int64_t ck = -1;
            if (auto c = dyn_cast<eco::ListConstructOp>(def)) {
                ck = c.getHeadKind();
            } else {
                ck = kernelConsKind(def);
            }
            if (ck >= 0) {
                if (!def->getResult(0).hasOneUse()) {
                    plan.ok = false;
                    return;
                }
                Type ht = def->getOperand(0).getType();
                bool htOk = (ck == 0 && isa<eco::ValueType>(ht)) ||
                            (ck == 1 && ht.isInteger(64)) ||
                            (ck == 2 && ht.isF64()) ||
                            (ck == 3 && eco::isEcoCharType(ht));
                if (!htOk) {
                    plan.ok = false;
                    return;
                }
                run.push_back(def);
                plan.links.push_back(UnwindLink{def, nullptr, ck});
                v = def->getOperand(1);
                continue;
            }
            if (auto call = dyn_cast<eco::CallOp>(def)) {
                auto callee = call.getCalleeAttr();
                if (callee && callee.getValue() == selfName) {
                    bool mt = call.getMusttail() && *call.getMusttail();
                    if (!def->getResult(0).hasOneUse() || mt) {
                        plan.ok = false;
                        return;
                    }
                    plan.selfCalls.push_back(def);
                    setRunBarrier(run, def, plan);
                    return;
                }
                break;  // foreign call result = rest leaf
            }
            if (isa<scf::IfOp, scf::IndexSwitchOp, eco::CaseOp>(def)) {
                if (!v.hasOneUse()) {
                    plan.ok = false;
                    return;
                }
                unsigned idx = cast<OpResult>(v).getResultNumber();
                setRunBarrier(run, def, plan);
                for (Region &r : def->getRegions()) {
                    if (!r.hasOneBlock()) {
                        plan.ok = false;
                        return;
                    }
                    Operation *term = r.front().getTerminator();
                    if (!isa<scf::YieldOp, eco::YieldOp>(term) ||
                        term->getNumOperands() <= idx) {
                        plan.ok = false;
                        return;
                    }
                    walkUnwind(term->getOperand(idx), selfName, plan);
                    if (!plan.ok)
                        return;
                }
                return;
            }
            break;  // any other def = rest leaf
        }
        // Plain leaf: this run's pushes sit at its outermost cons.
        if (plan.ok && !run.empty())
            setRunBarrier(run, run.front(), plan);
    }

    /// Applies the Phase 2 rewrite to `f` if it qualifies, and returns whether
    /// it did.
    ///
    /// `f` qualifies when its body is one block returning one `!eco.value`, the
    /// return chain (see `walkUnwind`) has at least one prepend and one self-call,
    /// every prepend has the same element kind and a push position, every
    /// self-call in the body ends the chain, every prepend's head dominates its
    /// push position, and every use of `f`'s symbol in the module is a direct
    /// `eco.call` of it returning one `!eco.value`, with at least one call from
    /// another function and none of those musttail. A function referenced in
    /// any other way, such as by a closure, is left alone. `declsMade` records
    /// whether the shared runtime declarations have been added. Counts go to
    /// `all` and `fh` when they are not null.
    bool tryRewriteUnwind(ModuleOp m, func::FuncOp f, bool &declsMade,
                          UnwindBailStats *all = nullptr,
                          UnwindBailStats *fh = nullptr) {
        // Bump the same counter in both scopes.
        auto bump = [&](unsigned UnwindBailStats::*slot) {
            if (all)
                all->*slot += 1;
            if (fh)
                fh->*slot += 1;
        };
        bump(&UnwindBailStats::seen);

        if (!llvm::hasSingleElement(f.getBody())) {
            bump(&UnwindBailStats::multiBlock);
            return false;
        }
        Operation *term = f.getBody().front().getTerminator();
        if (!term || term->getNumOperands() != 1 ||
            !isa<eco::ValueType>(term->getOperand(0).getType())) {
            bump(&UnwindBailStats::retShape);
            return false;
        }
        if (!isa<eco::ReturnOp, func::ReturnOp>(term)) {
            bump(&UnwindBailStats::retShape);
            return false;
        }
        StringRef name = f.getSymName();

        UnwindPlan plan;
        walkUnwind(term->getOperand(0), name, plan);
        if (!plan.ok) {
            bump(&UnwindBailStats::walkFail);
            return false;
        }
        if (plan.links.empty()) {
            bump(&UnwindBailStats::noLinks);
            return false;
        }
        if (plan.selfCalls.empty()) {
            bump(&UnwindBailStats::noSelfCalls);
            return false;
        }

        int64_t kind = plan.links.front().kind;
        for (auto &l : plan.links)
            if (l.kind != kind || !l.pushAt) {
                bump(&UnwindBailStats::kindMix);
                return false;
            }

        // Every self-call in the body must be a chain leaf; otherwise a
        // recursive result escapes the accumulation.
        unsigned selfCallsInBody = 0;
        f.walk([&](eco::CallOp c) {
            auto callee = c.getCalleeAttr();
            if (callee && callee.getValue() == name)
                selfCallsInBody++;
        });
        if (selfCallsInBody != plan.selfCalls.size()) {
            bump(&UnwindBailStats::selfEscape);
            return false;
        }

        // Heads must dominate their push sites.
        DominanceInfo dom(f);
        for (auto &l : plan.links) {
            Value h = l.cons->getOperand(0);
            if (Operation *hd = h.getDefiningOp()) {
                if (hd != l.pushAt && !dom.properlyDominates(hd, l.pushAt)) {
                    bump(&UnwindBailStats::domFail);
                    return false;
                }
            }
        }

        // Every module-wide use must be a direct, non-musttail eco.call.
        // One module walk indexes every symbol's uses, reused for every
        // candidate. Phase 2 rewrites only add calls to the scratch
        // declarations and erase prepends, so a candidate's uses do not change
        // after the index is built.
        if (!useIndexBuilt) {
            useIndexBuilt = true;
            // Collected in parallel chunks with symgraph::forEachSymbolRef,
            // merged in module order. Only each symbol's set of users matters
            // below.
            SmallVector<Operation *> tops;
            for (Operation &op : *m.getBody())
                tops.push_back(&op);
            std::vector<std::vector<std::pair<StringAttr, Operation *>>> per(
                tops.size());
            eco::forEachChunk(
                m.getContext(), tops.size(), [&](size_t lo, size_t hi) {
                    for (size_t i = lo; i < hi; ++i)
                        tops[i]->walk([&](Operation *op) {
                            eco::symgraph::forEachSymbolRef(
                                op, [&](SymbolRefAttr r, bool) {
                                    per[i].push_back(
                                        {r.getRootReference(), op});
                                });
                        });
                });
            for (auto &v : per)
                for (auto &[sym, user] : v)
                    useIndex[sym].push_back(user);
        }
        if (useIndexFailed) {
            bump(&UnwindBailStats::useShape);
            return false;
        }
        auto usersIt = useIndex.find(f.getSymNameAttr());
        ArrayRef<Operation *> users;
        if (usersIt != useIndex.end())
            users = usersIt->second;
        SmallVector<eco::CallOp, 8> outerSites;
        for (Operation *user : users) {
            auto call = dyn_cast<eco::CallOp>(user);
            if (!call || !call.getCalleeAttr() ||
                call.getCalleeAttr().getValue() != name) {
                bump(&UnwindBailStats::useShape);
                return false;
            }
            if (call->getParentOfType<func::FuncOp>() == f)
                continue;  // recursion, handled by the chain rewrite
            if (call.getMusttail() && *call.getMusttail()) {
                bump(&UnwindBailStats::useShape);
                return false;
            }
            if (call->getNumResults() != 1 ||
                !isa<eco::ValueType>(call->getResult(0).getType())) {
                bump(&UnwindBailStats::useShape);
                return false;
            }
            outerSites.push_back(call);
        }
        if (outerSites.empty()) {
            bump(&UnwindBailStats::noOuter);
            return false;  // dead or closure-referenced-only function
        }

        MLIRContext *ctx = m.getContext();
        Type i64 = IntegerType::get(ctx, 64);
        Type value = eco::ValueType::get(ctx);
        if (!declsMade) {
            declsMade = true;
            ensureDecl(m, kMarkFn, FunctionType::get(ctx, {}, {i64}), {},
                       {"i64"});
            ensureDecl(m, kPushBoxedFn, FunctionType::get(ctx, {value}, {}),
                       {"value"}, {});
            ensureDecl(m, kPushScalarFn,
                       FunctionType::get(ctx, {i64, i64}, {}), {"i64", "i64"},
                       {});
            ensureDecl(m, kFinishFn,
                       FunctionType::get(ctx, {i64, value, i64}, {value}),
                       {"i64", "value", "i64"}, {"value"});
        }
        // Once per run: ensureDecl's lookup scans the module and the
        // declaration sits at its end.
        if (!finishFwdMade && (finishFwdMade = true))
            ensureDecl(m, kFinishFwdFn,
                       FunctionType::get(ctx, {i64, value, i64}, {value}),
                       {"i64", "value", "i64"}, {"value"});

        // Pushes first (collection order is outer->inner per path, which is
        // descent order at every level), then collapse the conses.
        for (auto &l : plan.links) {
            OpBuilder cb(l.pushAt);
            Location cl = l.cons->getLoc();
            Value h = l.cons->getOperand(0);
            if (isa<eco::ValueType>(h.getType())) {
                cb.create<eco::CallOp>(
                    cl, TypeRange{}, ValueRange{h},
                    FlatSymbolRefAttr::get(ctx, kPushBoxedFn), nullptr,
                    nullptr);
            } else {
                Value bits = h;
                if (h.getType().isF64())
                    bits = cb.create<arith::BitcastOp>(cl, i64, h);
                else if (eco::isEcoCharType(h.getType()))
                    bits = cb.create<arith::ExtUIOp>(cl, i64, h);
                Value kc = cb.create<arith::ConstantOp>(
                    cl, cb.getI64IntegerAttr(kind));
                cb.create<eco::CallOp>(
                    cl, TypeRange{}, ValueRange{bits, kc},
                    FlatSymbolRefAttr::get(ctx, kPushScalarFn), nullptr,
                    nullptr);
            }
        }
        for (auto &l : plan.links) {
            l.cons->getResult(0).replaceAllUsesWith(l.cons->getOperand(1));
            l.cons->erase();
        }

        for (auto call : outerSites) {
            OpBuilder b(call);
            Location loc = call.getLoc();
            auto mark = b.create<eco::CallOp>(
                loc, TypeRange{i64}, ValueRange{},
                FlatSymbolRefAttr::get(ctx, kMarkFn), nullptr, nullptr);
            b.setInsertionPointAfter(call);
            Value kc =
                b.create<arith::ConstantOp>(loc, b.getI64IntegerAttr(kind));
            auto fin = b.create<eco::CallOp>(
                loc, TypeRange{value},
                ValueRange{mark.getResults()[0], call->getResult(0), kc},
                FlatSymbolRefAttr::get(ctx, kFinishFwdFn), nullptr, nullptr);
            call->getResult(0).replaceAllUsesExcept(fin.getResults()[0],
                                                    fin);
        }
        bump(&UnwindBailStats::ok);
        return true;
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoListTemplatePass() {
    return std::make_unique<EcoListTemplatePass>();
}
