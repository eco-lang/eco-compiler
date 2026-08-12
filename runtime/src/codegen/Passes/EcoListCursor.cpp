//===- EcoListCursor.cpp - Mixed-spine (node, idx) cursors for while walks ===//
//
// Chunked lists (plans/chunked-list-representation.md §6 L1.3, final item):
// compiled scf.while loops that WALK a list carry the spine as a single
// value, so stepping through a chunk view materializes a successor view per
// element (eco_list_tail_hybrid — an allocation plus a statepointed call
// where cells pay a pure load). This pass rewrites such loops to carry a
// (node, idx) pair instead:
//
//   element  -> __eco_list_cur*_inline(node, idx)   pure loads
//   step     -> __eco_list_step_{node,idx}_inline   pure loads, no allocation
//   emptiness -> unchanged get_tag on the node (positions are normalized:
//                idx > 0 only inside a chunk with idx < run)
//
// The markers are expanded into cell-fast/chunk inline diamonds in
// EcoBackend (expandListCursorMarkers) before RS4GC, so the cell edge stays
// exactly today's inline loads and NOTHING here is statepointed. If the
// remaining list escapes the loop (the while result is used), ONE call to
// eco_list_pos_view materializes the position as a real list value — one
// allocation per loop exit instead of one per element stepped.
//
// Runs AFTER EcoToLLVMPass (list projections are already marker calls;
// EcoGCPrepare has already run, so no rooting machinery attaches to the new
// per-step ops) and BEFORE the SCF tail conversions. The pass is a no-op
// unless the module declares __eco_list_tail_inline, which only
// chunk-compiled modules contain — flag-off output is untouched.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "../Passes.h"

#include <cstdlib>
#include <map>
#include <string>

using namespace mlir;

namespace {

constexpr const char *kTailMarker = "__eco_list_tail_inline";
constexpr const char *kHeadMarker = "__eco_list_head_inline";
constexpr const char *kStepNode = "__eco_list_step_node_inline";
constexpr const char *kStepIdx = "__eco_list_step_idx_inline";
constexpr const char *kPosView = "eco_list_pos_view";

/// Maps a head-projection callee to its cursor-read marker, or null.
const char *curMarkerFor(StringRef callee) {
    if (callee == kHeadMarker) return "__eco_list_cur_inline";
    if (callee == "eco_cons_head_i64") return "__eco_list_cur_i64_inline";
    if (callee == "eco_cons_head_f64") return "__eco_list_cur_f64_inline";
    if (callee == "eco_cons_head_i16") return "__eco_list_cur_i16_inline";
    return nullptr;
}

bool isGetTagCallee(StringRef callee) {
    return callee == "__eco_get_tag_inline" || callee == "eco_get_tag";
}

struct WalkArg {
    unsigned pos;                              // iter-arg position
    SmallVector<LLVM::CallOp, 4> tailCalls;    // per-arm steps
    SmallVector<LLVM::CallOp, 4> headCalls;    // element reads (both regions)
    // Operand slots through which the walked arg may legitimately appear on
    // the step tree (identity yields).
    SmallPtrSet<OpOperand *, 8> identSlots;
    // Every op on the step tree (tail calls + interior scf.if/index_switch).
    // Used by analyze to reject loops where two walk positions SHARE an
    // interior op: walkStep's hasOneUse test is per RESULT, so one scf.if
    // feeding two positions through different results validates for both --
    // and rebuildStep would then rebuild it twice, the second rebuild erasing
    // the first rebuild's op while the first walk's saved idx Value (a plain
    // copy, not a use, so RAUW never repairs it) dangles into the yield
    // rebuild. Shared trees could not arise before kernel-opt-10: it takes a
    // dedup pass (M4 CSE) merging two step scf.ifs made structurally
    // identical by the projection folder.
    SmallPtrSet<Operation *, 8> treeOps;
    bool anyStep = false;
};

struct EcoListCursorPass
    : public PassWrapper<EcoListCursorPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoListCursorPass)

    StringRef getArgument() const override { return "eco-list-cursor"; }
    StringRef getDescription() const override {
        return "Rewrite list-walking scf.while loops to non-allocating "
               "(node, idx) cursors (chunked lists)";
    }

    void getDependentDialects(DialectRegistry &registry) const override {
        registry.insert<arith::ArithDialect, LLVM::LLVMDialect,
                        scf::SCFDialect>();
    }

    LLVM::LLVMFuncOp ensureFn(ModuleOp m, StringRef name, Type res,
                              ArrayRef<Type> args) {
        if (auto f = m.lookupSymbol<LLVM::LLVMFuncOp>(name))
            return f;
        OpBuilder b(m.getContext());
        b.setInsertionPointToEnd(m.getBody());
        auto ft = LLVM::LLVMFunctionType::get(res, args);
        return b.create<LLVM::LLVMFuncOp>(m.getLoc(), name, ft);
    }

    void runOnOperation() override {
        ModuleOp m = getOperation();
        if (!m.lookupSymbol<LLVM::LLVMFuncOp>(kTailMarker))
            return;

        bool debug = std::getenv("ECO_LIST_CURSOR_DEBUG") != nullptr;
        unsigned whiles = 0, rewritten = 0;
        dbg = debug;

        SmallVector<scf::WhileOp, 32> loops;
        m.walk([&](scf::WhileOp w) { loops.push_back(w); });

        for (scf::WhileOp w : loops) {
            whiles++;
            SmallVector<WalkArg, 2> walks;
            analyze(w, walks);
            // Disjointness: if any two walks share a step-tree op, skip the
            // whole loop (conservative -- it stays un-rewritten and correct).
            // See the treeOps comment on WalkArg for why sharing is fatal.
            bool shared = false;
            for (unsigned i = 0; i + 1 < walks.size() && !shared; ++i)
                for (unsigned j = i + 1; j < walks.size() && !shared; ++j)
                    for (Operation *op : walks[i].treeOps)
                        if (walks[j].treeOps.count(op)) {
                            shared = true;
                            break;
                        }
            if (shared) {
                cSharedTree++;
                continue;
            }
            if (!walks.empty()) {
                rewrite(m, w, walks);
                rewritten++;
            }
        }
        if (debug) {
            fprintf(stderr,
                    "[eco-list-cursor] whiles=%u rewritten=%u ptrArgs=%u "
                    "condFwd=%u badUse=%u noStep=%u treeFail=%u\n",
                    whiles, rewritten, cPtrArgs, cCondFwd, cBadUse, cNoStep,
                    cTreeFail);
            std::map<std::string, unsigned> hist;
            for (Operation *op : badUseOps)
                hist[op->getName().getStringRef().str()]++;
            for (auto &kv : hist)
                fprintf(stderr, "[eco-list-cursor] bad-use %-28s %u\n",
                        kv.first.c_str(), kv.second);
        }
    }

    bool dbg = false;
    unsigned cPtrArgs = 0, cCondFwd = 0, cBadUse = 0, cNoStep = 0,
             cTreeFail = 0, cSharedTree = 0;
    SmallVector<Operation *, 16> badUseOps;
    std::map<std::string, unsigned> badCallees;

    /// Validates the step tree hanging off the while-yield at position p:
    /// leaves are the walked arg itself (identity — no step this path) or a
    /// __eco_list_tail_inline call on it; interior nodes are single-use
    /// scf.if / scf.index_switch results whose every region yields a valid
    /// subtree at the same index. Records identity slots and tail calls.
    bool walkStep(Value v, Value argP, OpOperand &slot, WalkArg &wa) {
        if (v == argP) {
            wa.identSlots.insert(&slot);
            return true;
        }
        Operation *def = v.getDefiningOp();
        if (!def)
            return false;
        if (auto call = dyn_cast<LLVM::CallOp>(def)) {
            if (call.getCallee() && *call.getCallee() == kTailMarker &&
                call.getArgOperands().size() == 1 &&
                call.getArgOperands()[0] == argP &&
                call.getResult().hasOneUse()) {
                wa.tailCalls.push_back(call);
                wa.treeOps.insert(call);
                wa.anyStep = true;
                return true;
            }
            return false;
        }
        if (isa<scf::IfOp, scf::IndexSwitchOp>(def)) {
            if (!v.hasOneUse())
                return false;
            wa.treeOps.insert(def);
            unsigned idx = cast<OpResult>(v).getResultNumber();
            for (Region &r : def->getRegions()) {
                if (!r.hasOneBlock())
                    return false;
                Operation *term = r.front().getTerminator();
                if (!isa<scf::YieldOp>(term) ||
                    term->getNumOperands() <= idx)
                    return false;
                if (!walkStep(term->getOperand(idx), argP,
                              term->getOpOperand(idx), wa))
                    return false;
            }
            return true;
        }
        return false;
    }

    void analyze(scf::WhileOp w, SmallVectorImpl<WalkArg> &walks) {
        auto condOp = w.getConditionOp();
        auto yieldOp = w.getYieldOp();
        unsigned n = w.getInits().size();

        for (unsigned p = 0; p < n; ++p) {
            Type t = w.getInits()[p].getType();
            auto pt = dyn_cast<LLVM::LLVMPointerType>(t);
            if (!pt || pt.getAddressSpace() != 1)
                continue;
            cPtrArgs++;

            Value beforeArg = w.getBefore().getArgument(p);
            Value afterArg = w.getAfterArguments()[p];
            if (condOp.getArgs()[p] != beforeArg) {
                cCondFwd++;
                continue;
            }

            WalkArg wa;
            wa.pos = p;

            // Step tree from the yield at p.
            if (!walkStep(yieldOp->getOperand(p), afterArg,
                          yieldOp->getOpOperand(p), wa)) {
                cTreeFail++;
                continue;
            }
            if (!wa.anyStep) {
                cNoStep++;
                continue;
            }

            // Every remaining use of the walked arg must be a projection,
            // the condition forward, a recorded identity slot, or one of
            // the recorded tail calls.
            bool ok = true;
            auto classify = [&](Value arg) {
                for (OpOperand &u : arg.getUses()) {
                    if (!ok)
                        return;
                    Operation *own = u.getOwner();
                    if (own == condOp.getOperation()) {
                        if (u.getOperandNumber() != p + 1)
                            ok = false;
                        continue;
                    }
                    if (wa.identSlots.count(&u))
                        continue;
                    auto call = dyn_cast<LLVM::CallOp>(own);
                    if (call && llvm::is_contained(wa.tailCalls, call))
                        continue;
                    if (!call || !call.getCallee() ||
                        u.getOperandNumber() != 0 ||
                        call.getArgOperands().size() != 1) {
                        if (dbg) badUseOps.push_back(own);
                        ok = false;
                        return;
                    }
                    StringRef callee = *call.getCallee();
                    if (isGetTagCallee(callee))
                        continue;
                    if (curMarkerFor(callee)) {
                        wa.headCalls.push_back(call);
                        continue;
                    }
                    if (dbg) badUseOps.push_back(own);
                    ok = false;
                    return;
                }
            };
            classify(beforeArg);
            if (ok)
                classify(afterArg);
            if (!ok) {
                cBadUse++;
                continue;
            }
            walks.push_back(wa);
        }
    }

    /// Rebuilds the step tree hanging off `v` so that every path also
    /// produces the NEXT index: tail calls become step_node/step_idx pairs,
    /// identity leaves keep curIdx, and scf.if / index_switch interior nodes
    /// gain one extra i64 result. Returns {newNodeValue, idxValue}.
    std::pair<Value, Value> rebuildStep(Value v, Value argP, Value curIdx,
                                        OpBuilder &topB) {
        MLIRContext *ctx = v.getContext();
        auto as1 = LLVM::LLVMPointerType::get(ctx, 1);
        Type i64 = IntegerType::get(ctx, 64);
        if (v == argP)
            return {argP, curIdx};
        Operation *def = v.getDefiningOp();
        if (auto call = dyn_cast<LLVM::CallOp>(def)) {
            OpBuilder b(call);
            auto sn = b.create<LLVM::CallOp>(
                call.getLoc(), TypeRange{as1},
                SymbolRefAttr::get(ctx, kStepNode), ValueRange{argP, curIdx});
            auto si = b.create<LLVM::CallOp>(
                call.getLoc(), TypeRange{i64},
                SymbolRefAttr::get(ctx, kStepIdx), ValueRange{argP, curIdx});
            // The enclosing yield still references the old call until its
            // own rebuild; retarget uses before erasing.
            call->getResult(0).replaceAllUsesWith(sn->getResult(0));
            call->erase();
            return {sn->getResult(0), si->getResult(0)};
        }
        // Interior scf.if / scf.index_switch: extend with an i64 result.
        unsigned rIdx = cast<OpResult>(v).getResultNumber();
        SmallVector<Type> newTys(def->getResultTypes().begin(),
                                 def->getResultTypes().end());
        newTys.push_back(i64);
        OpBuilder b(def);
        Operation *nd = nullptr;
        if (auto ifOp = dyn_cast<scf::IfOp>(def)) {
            auto ni = b.create<scf::IfOp>(ifOp.getLoc(), newTys,
                                          ifOp.getCondition(),
                                          /*withElseRegion=*/true);
            ni.getThenRegion().takeBody(ifOp.getThenRegion());
            ni.getElseRegion().takeBody(ifOp.getElseRegion());
            nd = ni;
        } else {
            auto sw = cast<scf::IndexSwitchOp>(def);
            auto ns = b.create<scf::IndexSwitchOp>(
                sw.getLoc(), newTys, sw.getArg(), sw.getCases(),
                sw.getCases().size());
            ns.getDefaultRegion().takeBody(sw.getDefaultRegion());
            for (unsigned i = 0; i < sw.getCases().size(); ++i)
                ns.getCaseRegions()[i].takeBody(sw.getCaseRegions()[i]);
            nd = ns;
        }
        for (Region &r : nd->getRegions()) {
            auto term = cast<scf::YieldOp>(r.front().getTerminator());
            auto sub = rebuildStep(term->getOperand(rIdx), argP, curIdx,
                                   topB);
            SmallVector<Value> ops(term->getOperands().begin(),
                                   term->getOperands().end());
            ops[rIdx] = sub.first;
            ops.push_back(sub.second);
            OpBuilder yb(term);
            yb.create<scf::YieldOp>(term.getLoc(), ops);
            term.erase();
        }
        for (unsigned i = 0; i < def->getNumResults(); ++i)
            def->getResult(i).replaceAllUsesWith(nd->getResult(i));
        def->erase();
        return {nd->getResult(rIdx), nd->getResult(newTys.size() - 1)};
    }

    void rewrite(ModuleOp m, scf::WhileOp w, ArrayRef<WalkArg> walks) {
        MLIRContext *ctx = m.getContext();
        Location loc = w.getLoc();
        OpBuilder b(w);
        Type i64 = b.getI64Type();
        auto as1 = LLVM::LLVMPointerType::get(ctx, 1);

        ensureFn(m, kStepNode, as1, {as1, i64});
        ensureFn(m, kStepIdx, i64, {as1, i64});
        ensureFn(m, "__eco_list_cur_inline", as1, {as1, i64});
        ensureFn(m, "__eco_list_cur_i64_inline", i64, {as1, i64});
        ensureFn(m, "__eco_list_cur_f64_inline", b.getF64Type(), {as1, i64});
        ensureFn(m, "__eco_list_cur_i16_inline", b.getIntegerType(16),
                 {as1, i64});
        ensureFn(m, kPosView, as1, {as1, i64});

        unsigned n = w.getInits().size();
        unsigned k = walks.size();

        Value c0 = b.create<arith::ConstantOp>(loc, b.getI64IntegerAttr(0));
        SmallVector<Value> inits(w.getInits().begin(), w.getInits().end());
        SmallVector<Type> resTys(w.getResultTypes().begin(),
                                 w.getResultTypes().end());
        for (unsigned i = 0; i < k; ++i) {
            inits.push_back(c0);
            resTys.push_back(i64);
        }

        auto nw = b.create<scf::WhileOp>(loc, resTys, inits);
        nw.getBefore().takeBody(w.getBefore());
        nw.getAfter().takeBody(w.getAfter());
        SmallVector<Value, 2> beforeIdx, afterIdx;
        for (unsigned i = 0; i < k; ++i) {
            beforeIdx.push_back(
                nw.getBefore().front().addArgument(i64, loc));
            afterIdx.push_back(nw.getAfter().front().addArgument(i64, loc));
        }

        auto condOp = nw.getConditionOp();
        {
            OpBuilder cb(condOp);
            SmallVector<Value> args(condOp.getArgs().begin(),
                                    condOp.getArgs().end());
            for (unsigned i = 0; i < k; ++i)
                args.push_back(beforeIdx[i]);
            cb.create<scf::ConditionOp>(condOp.getLoc(),
                                        condOp.getCondition(), args);
            condOp.erase();
        }

        // Head reads first (they reference the PRE-step position).
        for (unsigned i = 0; i < k; ++i) {
            const WalkArg &wa = walks[i];
            Value beforeArg = nw.getBefore().getArgument(wa.pos);
            Value afterArg = nw.getAfterArguments()[wa.pos];
            for (LLVM::CallOp hc : wa.headCalls) {
                bool inAfter =
                    nw.getAfter().isAncestor(hc->getParentRegion()) ||
                    hc->getParentRegion() == &nw.getAfter();
                Value node = inAfter ? afterArg : beforeArg;
                Value idx = inAfter ? afterIdx[i] : beforeIdx[i];
                OpBuilder hb(hc);
                auto cur = hb.create<LLVM::CallOp>(
                    hc.getLoc(), TypeRange{hc->getResult(0).getType()},
                    SymbolRefAttr::get(ctx, curMarkerFor(*hc.getCallee())),
                    ValueRange{node, idx});
                hc->getResult(0).replaceAllUsesWith(cur->getResult(0));
                hc->erase();
            }
        }

        // Step trees: rebuild the yield with per-position idx results. Keep
        // the OLD yield's operands current while rebuilding — replacing an
        // interior scf.if remaps its other results' uses in the old yield,
        // so the operand snapshot must be taken only afterwards.
        auto yieldOp = nw.getYieldOp();
        SmallVector<Value> idxYields;
        for (unsigned i = 0; i < k; ++i) {
            const WalkArg &wa = walks[i];
            Value afterArg = nw.getAfterArguments()[wa.pos];
            auto pr = rebuildStep(yieldOp->getOperand(wa.pos), afterArg,
                                  afterIdx[i], b);
            yieldOp->setOperand(wa.pos, pr.first);
            idxYields.push_back(pr.second);
        }
        SmallVector<Value> yields(yieldOp.getOperands().begin(),
                                  yieldOp.getOperands().end());
        for (Value v : idxYields)
            yields.push_back(v);
        {
            OpBuilder yb(yieldOp);
            yb.create<scf::YieldOp>(yieldOp.getLoc(), yields);
            yieldOp.erase();
        }

        OpBuilder rb(w);
        rb.setInsertionPointAfter(nw);
        for (unsigned p = 0; p < n; ++p) {
            Value oldRes = w.getResult(p);
            Value newRes = nw.getResult(p);
            int walkIdx = -1;
            for (unsigned i = 0; i < k; ++i)
                if (walks[i].pos == p)
                    walkIdx = static_cast<int>(i);
            if (walkIdx >= 0 && !oldRes.use_empty()) {
                auto pv = rb.create<LLVM::CallOp>(
                    loc, TypeRange{as1}, SymbolRefAttr::get(ctx, kPosView),
                    ValueRange{newRes, nw.getResult(n + walkIdx)});
                oldRes.replaceAllUsesWith(pv->getResult(0));
            } else {
                oldRes.replaceAllUsesWith(newRes);
            }
        }
        w.erase();
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoListCursorPass() {
    return std::make_unique<EcoListCursorPass>();
}
