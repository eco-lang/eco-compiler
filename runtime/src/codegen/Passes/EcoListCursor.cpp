//===- EcoListCursor.cpp - Mixed-spine (node, idx) cursors for while walks ===//
//
// Walking a chunked list one element at a time allocates, and this pass removes that allocation from compiled
// loops.
//
// A chunked list mixes two kinds of spine node: ordinary cons cells, and chunks, which hold a run of elements in
// one object. As a single list value, a position inside a chunk can only be a chunk view, so taking the tail of a
// chunk with `__eco_list_tail_inline` makes a new view for every element (through `eco_list_tail_hybrid`). This
// pass rewrites an `scf.while` loop that walks a list so that it carries a cursor instead: a pair (node, idx) of
// the spine node and an i64 index into it. The loop's list argument becomes the node, and one i64 loop argument is
// added for each walked list, starting at 0.
//
// - An element read (`__eco_list_head_inline` or `eco_cons_head_{i64,f64,char}`) on the walked argument becomes the
//   matching `__eco_list_cur*_inline(node, idx)` marker.
// - Each tail call in the step tree (defined below) becomes a `__eco_list_step_node_inline` /
//   `__eco_list_step_idx_inline` pair.
// - A tag test (`__eco_get_tag_inline` or `eco_get_tag`) on the node is left unchanged. That this still tests
//   emptiness rests on the markers keeping positions normalized, as `expandListCursorMarker` in EcoBackend.cpp
//   states: idx is non-zero only inside a chunk, before the end of its run.
// - Where the loop's result for a walked list is used, one `eco_list_pos_view(node, idx)` call after the loop
//   turns the final position back into a list value. That function allocates a view only when idx is non-zero.
//
// The markers are not functions. EcoBackend's `expandListCursorMarkers` expands them before RS4GC into loads and
// gc-leaf helper calls, so stepping allocates nothing and adds no statepoint.
//
// A loop is rewritten only for the walks the analysis accepts, and the analysis is most of this file. A walk is a
// loop argument of type `ptr addrspace(1)` that the condition forwards at its own position and that the yield
// steps along a step tree. The step tree is the expression the yield passes at that position: its leaves are the
// argument itself (no step on that path) or a `__eco_list_tail_inline` call on it whose result has one use, and its
// interior nodes are results of `scf.if` / `scf.index_switch`, each with one use, whose every region yields a valid
// subtree at the same result index. Every other use of the argument, in either region, must be an element read, a
// tag test, the condition operand, or a leaf of the tree. A loop in which two walks share a step-tree operation is
// left unchanged, because rebuilding that operation once per walk would leave the first walk's index value
// dangling.
//
// It runs after the pass from `createEcoToLLVMPass`, whose output it reads as marker calls, and before the one
// from `createEcoTailConversionsPass`, which lowers `scf`. It does nothing unless the module declares
// `__eco_list_tail_inline`. With `ECO_LIST_CURSOR_DEBUG` set to any value it prints counts of loops seen, rewritten
// and rejected for most reasons, and a histogram of the operations behind rejected uses, to stderr.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "../Passes.h"
#include "../EcoOps.h"  // eco::getEcoCharType (Char = i32)
#include "EcoParallel.h"

#include <cstdlib>
#include <map>
#include <string>

using namespace mlir;

namespace {

// The tail-projection marker. A call to it is a step, and its declaration in a module is what turns the pass on.
constexpr const char *kTailMarker = "__eco_list_tail_inline";
// The boxed head-projection marker, an element read that becomes `__eco_list_cur_inline`.
constexpr const char *kHeadMarker = "__eco_list_head_inline";
// The marker that returns the node of the position after (node, idx).
constexpr const char *kStepNode = "__eco_list_step_node_inline";
// The marker that returns the index of the position after (node, idx).
constexpr const char *kStepIdx = "__eco_list_step_idx_inline";
// The runtime function that returns the list value at position (node, idx), allocating when idx is non-zero.
constexpr const char *kPosView = "eco_list_pos_view";

// Returns the cursor-read marker that replaces a head read through `callee`, or null if `callee` is not a head
// read. The returned string is a literal.
const char *curMarkerFor(StringRef callee) {
    if (callee == kHeadMarker) return "__eco_list_cur_inline";
    if (callee == "eco_cons_head_i64") return "__eco_list_cur_i64_inline";
    if (callee == "eco_cons_head_f64") return "__eco_list_cur_f64_inline";
    if (callee == "eco_cons_head_char") return "__eco_list_cur_char_inline";
    return nullptr;
}

// Returns whether `callee` reads a value's tag; such a read of a walked argument is left unchanged.
bool isGetTagCallee(StringRef callee) {
    return callee == "__eco_get_tag_inline" || callee == "eco_get_tag";
}

/**
 * One walk the analysis accepted in a loop: a list argument of the `scf.while`, with the operations on it that
 * the rewrite replaces.
 *
 * The pointers refer into the loop being analysed and are used only until that loop has been rewritten.
 */
struct WalkArg {
    unsigned pos;                              // Position of the argument among the loop's inits.
    SmallVector<LLVM::CallOp, 4> tailCalls;    // Leaf tail calls of the step tree.
    SmallVector<LLVM::CallOp, 4> headCalls;    // Element reads, in either region.
    // The yield operands at which the step tree's leaf is the argument itself.
    SmallPtrSet<OpOperand *, 8> identSlots;
    // Every operation on the step tree: tail calls and interior `scf.if` / `scf.index_switch`.
    //
    // The one-use test in `walkStep` is per result, so one `scf.if` can feed two walks through two of its results
    // and pass for both. `rebuildStep` would then rebuild it once per walk, and the second rebuild erases the op
    // whose new index result the first walk has already recorded as a plain `Value`, which no replacement of uses
    // repairs. `runOnOperation` compares these sets to skip such loops.
    SmallPtrSet<Operation *, 8> treeOps;
    // Whether the step tree has at least one tail call. A walk with none never steps and is not rewritten.
    bool anyStep = false;
};

/**
 * The module pass that rewrites list-walking `scf.while` loops to carry (node, idx) cursors, as the file comment
 * describes.
 *
 * The counters and lists below are statistics for `ECO_LIST_CURSOR_DEBUG`. They are not reset between runs, so a
 * pass object run twice reports totals.
 */
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

    // Returns the `llvm.func` named `name` in `m`, first declaring it at the end of the module with result `res`
    // and arguments `args` if there is none. An existing function is returned whatever its type.
    //
    // A declaration made here has no attributes, so it is not marked `gc-leaf-function`.
    LLVM::LLVMFuncOp ensureFn(ModuleOp m, StringRef name, Type res,
                              ArrayRef<Type> args) {
        if (auto f = m.lookupSymbol<LLVM::LLVMFuncOp>(name))
            return f;
        OpBuilder b(m.getContext());
        b.setInsertionPointToEnd(m.getBody());
        auto ft = LLVM::LLVMFunctionType::get(res, args);
        return b.create<LLVM::LLVMFuncOp>(m.getLoc(), name, ft);
    }

    // Rewrites every accepted loop in the module, in module order, inner loops before the loops that contain them.
    void runOnOperation() override {
        ModuleOp m = getOperation();
        if (!m.lookupSymbol<LLVM::LLVMFuncOp>(kTailMarker))
            return;

        bool debug = std::getenv("ECO_LIST_CURSOR_DEBUG") != nullptr;
        unsigned whiles = 0, rewritten = 0;
        dbg = debug;
        declsMade = false;

        // Only the search for loops runs in parallel, one chunk of top-level ops at a time; concatenating the
        // per-op lists keeps module order and post-order. Analysis and rewriting are serial.
        SmallVector<Operation *> tops;
        for (Operation &op : *m.getBody())
            if (op.getNumRegions() && !op.getRegion(0).empty())
                tops.push_back(&op);
        std::vector<SmallVector<scf::WhileOp, 0>> perTop(tops.size());
        eco::forEachChunk(&getContext(), tops.size(),
                          [&](size_t lo, size_t hi) {
                              for (size_t i = lo; i < hi; ++i)
                                  tops[i]->walk([&](scf::WhileOp w) {
                                      perTop[i].push_back(w);
                                  });
                          });
        SmallVector<scf::WhileOp, 32> loops;
        for (auto &v : perTop)
            loops.append(v.begin(), v.end());

        for (scf::WhileOp w : loops) {
            whiles++;
            SmallVector<WalkArg, 2> walks;
            analyze(w, walks);
            // A loop whose walks share a step-tree op is left as it is; see `WalkArg::treeOps`.
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

    bool dbg = false;       // Whether `ECO_LIST_CURSOR_DEBUG` is set, so rejected uses are recorded.
    // Whether this run has declared the cursor markers and `eco_list_pos_view`. They are declared once, at the first
    // rewrite, because each symbol lookup scans the module.
    bool declsMade = false;
    unsigned cPtrArgs = 0, cCondFwd = 0, cBadUse = 0, cNoStep = 0,
             cTreeFail = 0, cSharedTree = 0;
    SmallVector<Operation *, 16> badUseOps;   // Owners of rejected uses, recorded only when `dbg` is set.
    std::map<std::string, unsigned> badCallees;   // Never written or read.

    // Returns whether `v`, the value passed at `slot`, is a valid step tree for the walked argument `argP`, as the
    // file comment defines one. Records the tree's leaves and operations in `wa`; on failure `wa` may hold part of
    // the tree.
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

    // Appends to `walks` each list argument of `w` that can be walked with a cursor, in argument order, and
    // adds to the debug counters.
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

            if (!walkStep(yieldOp->getOperand(p), afterArg,
                          yieldOp->getOpOperand(p), wa)) {
                cTreeFail++;
                continue;
            }
            if (!wa.anyStep) {
                cNoStep++;
                continue;
            }

            // Every other use, in either region, must be the condition operand, a leaf of the step tree, a tag
            // test or an element read.
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

    // Rebuilds the step tree `v` of the walked argument `argP` at index `curIdx` so that it also yields the next
    // index, and returns the new tree's node and index values.
    //
    // A tail call becomes a step-node and step-index pair, an identity leaf keeps `curIdx`, and each interior
    // `scf.if` / `scf.index_switch` is replaced by a copy with one more i64 result, its old results' uses moved to
    // the copy. `v` must be a tree `walkStep` accepted. `topB` is not used.
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

    // Replaces `w` with a loop that carries one i64 index per walk in `walks`, starting at 0, and rewrites each
    // walk's element reads and step tree to use it. A used result of a walked argument is replaced by an
    // `eco_list_pos_view` call after the loop. `w` is erased.
    void rewrite(ModuleOp m, scf::WhileOp w, ArrayRef<WalkArg> walks) {
        MLIRContext *ctx = m.getContext();
        Location loc = w.getLoc();
        OpBuilder b(w);
        Type i64 = b.getI64Type();
        auto as1 = LLVM::LLVMPointerType::get(ctx, 1);

        // Once per run: each lookup scans the module, and the declarations sit at its end.
        if (!declsMade) {
            declsMade = true;
            ensureFn(m, kStepNode, as1, {as1, i64});
            ensureFn(m, kStepIdx, i64, {as1, i64});
            ensureFn(m, "__eco_list_cur_inline", as1, {as1, i64});
            ensureFn(m, "__eco_list_cur_i64_inline", i64, {as1, i64});
            ensureFn(m, "__eco_list_cur_f64_inline", b.getF64Type(),
                     {as1, i64});
            ensureFn(m, "__eco_list_cur_char_inline", eco::getEcoCharType(b.getContext()),
                     {as1, i64});
            ensureFn(m, kPosView, as1, {as1, i64});
        }

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

        // Element reads first: they read the position before the step.
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

        // Rebuilding an interior op moves its other results' uses in the old yield, so the yield's operands are
        // copied only after every tree is rebuilt.
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
