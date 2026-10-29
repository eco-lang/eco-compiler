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
// added for each walked list, starting at 0, and one for each escape slot (below).
//
// - An element read (`__eco_list_head_inline` or `eco_cons_head_{i64,f64,char}`) on the walked argument becomes the
//   matching `__eco_list_cur*_inline(node, idx)` marker.
// - Each tail call in the step tree (defined below) becomes a `__eco_list_step_node_inline` /
//   `__eco_list_step_idx_inline` pair.
// - A tag test (`__eco_get_tag_inline` or `eco_get_tag`) on the node is left unchanged. That this still tests
//   emptiness rests on the markers keeping positions normalized, as `expandListCursorMarker` in EcoBackend.cpp
//   states: idx is non-zero only inside a chunk, before the end of its run.
// - Where the loop's result for a walked list is used, one `eco_list_pos_view(node, idx)` call after the loop
//   turns the final position back into a list value. That function allocates a view only when idx is non-zero,
//   so it can collect: it is not gc-leaf, and the gc-free and capacity-hoisting planners treat it as a GC point.
// - A walked argument may also be yielded into an escape slot: another pointer argument that only carries a
//   value out of the loop. This is how the front end returns the rest of a list (`dropWhile`), since its
//   tail-call loops return through a separate result argument. The escape slot carries an index too: the
//   walked argument yields its own index, any other value yields 0, and the slot's result, if used, gets an
//   `eco_list_pos_view` after the loop. A walk the slot ends at therefore costs one view, not one per element.
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
// tag test, the condition operand, a leaf of the tree, or a leaf of an escape tree.
//
// An escape slot is a pointer argument that is not a walk, whose before-region argument is used only by the
// condition at its own position, and whose after-region argument is used only as a leaf of its escape tree. Its
// escape tree is the expression the yield passes at its position, read through `scf.if` / `scf.index_switch` results
// with one use in the after region whose regions are single blocks ending in `scf.yield`; anything else is a leaf.
// A slot is rewritten only when an accepted walk is one of its leaves.
//
// Step trees and escape trees may run through the same `scf.if` / `scf.index_switch`, through different results.
// The rewrite rebuilds each such operation once, with one added i64 result for each of its results that a tree uses.
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
#include <functional>
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
    SmallPtrSet<Operation *, 8> treeOps;
    // The escape candidates (indices into `analyze`'s candidate list) that have this argument as a leaf.
    SmallVector<unsigned, 2> escapeSlots;
    // Whether the step tree has at least one tail call. A walk with none never steps and is not rewritten.
    bool anyStep = false;
};

/**
 * One escape slot of a loop, as the file comment defines it: a pointer argument that carries a value, possibly a
 * walked position, out of the loop.
 *
 * The pointers refer into the loop being analysed and are used only until that loop has been rewritten.
 */
struct EscapeSlot {
    unsigned pos;                              // Position of the argument among the loop's inits.
    SmallPtrSet<OpOperand *, 8> leaves;        // The yield operands that are leaves of the escape tree.
    SmallPtrSet<Operation *, 8> interior;      // The tree's interior `scf.if` / `scf.index_switch` operations.
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
            SmallVector<EscapeSlot, 2> escapes;
            analyze(w, walks, escapes);
            if (!walks.empty()) {
                rewrite(m, w, walks, escapes);
                rewritten++;
            }
        }
        if (debug) {
            fprintf(stderr,
                    "[eco-list-cursor] whiles=%u rewritten=%u ptrArgs=%u "
                    "condFwd=%u badUse=%u noStep=%u treeFail=%u\n",
                    whiles, rewritten, cPtrArgs, cCondFwd, cBadUse, cNoStep,
                    cTreeFail);
            fprintf(stderr, "[eco-list-cursor] escapes=%u posViews=%u\n", cEscapes, cPosViews);
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
             cTreeFail = 0, cEscapes = 0, cPosViews = 0;
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

    // Records in `es` the escape tree below `v`, the value passed at `slot`, as the file comment defines it: a
    // result of an `scf.if` / `scf.index_switch` in `after` that has one use and whose regions are single blocks
    // ending in an `scf.yield` is an interior node, and anything else is a leaf.
    void walkEscape(Value v, OpOperand &slot, Region &after, EscapeSlot &es) {
        Operation *def = v.getDefiningOp();
        if (def && isa<scf::IfOp, scf::IndexSwitchOp>(def) && v.hasOneUse() &&
            after.isAncestor(def->getParentRegion())) {
            unsigned idx = cast<OpResult>(v).getResultNumber();
            bool shaped = llvm::all_of(def->getRegions(), [&](Region &r) {
                return r.hasOneBlock() && isa<scf::YieldOp>(r.front().getTerminator()) &&
                       r.front().getTerminator()->getNumOperands() > idx;
            });
            if (shaped) {
                es.interior.insert(def);
                for (Region &r : def->getRegions()) {
                    Operation *term = r.front().getTerminator();
                    walkEscape(term->getOperand(idx), term->getOpOperand(idx), after, es);
                }
                return;
            }
        }
        es.leaves.insert(&slot);
    }

    // Appends to `walks` each list argument of `w` that can be walked with a cursor, and to `escapes` each escape
    // slot that one of them ends at, both in argument order, and adds to the debug counters.
    void analyze(scf::WhileOp w, SmallVectorImpl<WalkArg> &walks, SmallVectorImpl<EscapeSlot> &escapes) {
        auto condOp = w.getConditionOp();
        auto yieldOp = w.getYieldOp();
        unsigned n = w.getInits().size();

        // The escape candidates, and the candidate each of their leaves belongs to.
        SmallVector<EscapeSlot, 2> cands;
        DenseMap<OpOperand *, unsigned> escapeLeafOf;
        for (unsigned q = 0; q < n; ++q) {
            auto pt = dyn_cast<LLVM::LLVMPointerType>(w.getInits()[q].getType());
            if (!pt || pt.getAddressSpace() != 1)
                continue;
            Value beforeArg = w.getBefore().getArgument(q);
            Value afterArg = w.getAfterArguments()[q];
            if (condOp.getArgs()[q] != beforeArg || !beforeArg.hasOneUse())
                continue;
            EscapeSlot es;
            es.pos = q;
            walkEscape(yieldOp->getOperand(q), yieldOp->getOpOperand(q), w.getAfter(), es);
            bool onlyLeaves = llvm::all_of(afterArg.getUses(), [&](OpOperand &u) {
                return es.leaves.count(&u) != 0;
            });
            if (!onlyLeaves)
                continue;
            for (OpOperand *leaf : es.leaves)
                escapeLeafOf[leaf] = cands.size();
            cands.push_back(std::move(es));
        }

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

            // Every other use, in either region, must be the condition operand, a leaf of the step tree, a leaf of
            // an escape tree, a tag test or an element read.
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
                    if (auto it = escapeLeafOf.find(&u); it != escapeLeafOf.end()) {
                        wa.escapeSlots.push_back(it->second);
                        continue;
                    }
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

        // The escape slots some accepted walk ends at, in argument order.
        SmallVector<bool, 4> active(cands.size(), false);
        for (const WalkArg &wa : walks)
            for (unsigned c : wa.escapeSlots)
                active[c] = true;
        for (unsigned c = 0; c < cands.size(); ++c)
            if (active[c]) {
                escapes.push_back(std::move(cands[c]));
                cEscapes++;
            }
    }

    // Replaces `w` with a loop that carries one i64 index per walk in `walks` and per escape slot in `escapes`, all
    // starting at 0, and rewrites each walk's element reads, step tree and escape-tree leaves to use them. A used
    // result at a carried position is replaced by an `eco_list_pos_view` call after the loop. `w` is erased.
    void rewrite(ModuleOp m, scf::WhileOp w, ArrayRef<WalkArg> walks,
                 ArrayRef<EscapeSlot> escapes) {
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
        // The carried positions, walks first: index argument i belongs to position carried[i].
        SmallVector<unsigned, 4> carried;
        for (const WalkArg &wa : walks)
            carried.push_back(wa.pos);
        for (const EscapeSlot &es : escapes)
            carried.push_back(es.pos);
        unsigned k = carried.size();

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
        SmallVector<Value, 4> beforeIdx, afterIdx;
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
        for (unsigned i = 0; i < walks.size(); ++i) {
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

        // The index of a carried position's after-region argument; the tail calls; the trees' interior ops.
        DenseMap<Value, Value> argIdx;
        for (unsigned i = 0; i < k; ++i)
            argIdx[nw.getAfterArguments()[carried[i]]] = afterIdx[i];
        SmallPtrSet<Operation *, 16> tails, interior;
        for (const WalkArg &wa : walks) {
            for (LLVM::CallOp tc : wa.tailCalls)
                tails.insert(tc);
            for (Operation *op : wa.treeOps)
                if (!isa<LLVM::CallOp>(op))
                    interior.insert(op);
        }
        for (const EscapeSlot &es : escapes)
            interior.insert(es.interior.begin(), es.interior.end());

        // Which results of each interior op a tree runs through: each needs an index result beside it.
        auto yieldOp = nw.getYieldOp();
        DenseMap<Operation *, SmallVector<unsigned, 2>> needed;
        std::function<void(Value)> collect = [&](Value v) {
            Operation *def = v.getDefiningOp();
            if (!def || !interior.count(def))
                return;
            unsigned r = cast<OpResult>(v).getResultNumber();
            auto &rs = needed[def];
            if (llvm::is_contained(rs, r))
                return;
            rs.push_back(r);
            for (Region &reg : def->getRegions())
                collect(reg.front().getTerminator()->getOperand(r));
        };
        for (unsigned pos : carried)
            collect(yieldOp->getOperand(pos));

        // Inner ops before the ops whose regions yield their results.
        SmallVector<Operation *, 8> order;
        SmallPtrSet<Operation *, 8> seen;
        std::function<void(Operation *)> post = [&](Operation *op) {
            if (!seen.insert(op).second)
                return;
            for (unsigned r : needed.find(op)->second)
                for (Region &reg : op->getRegions()) {
                    Operation *d = reg.front().getTerminator()->getOperand(r).getDefiningOp();
                    if (d && needed.count(d))
                        post(d);
                }
            order.push_back(op);
        };
        for (unsigned pos : carried)
            if (Operation *d = yieldOp->getOperand(pos).getDefiningOp(); d && needed.count(d))
                post(d);

        // Returns the (node, index) that replace `o`, an operand of the terminator `term` on a tree: a carried
        // argument gives its own index, a tail call becomes a step pair, a rebuilt op's result gives the index
        // result beside it, and anything else is a list value at index 0.
        DenseMap<std::pair<Operation *, unsigned>, Value> idxOf;
        auto resolve = [&](Value o, Operation *term) -> std::pair<Value, Value> {
            if (Value idx = argIdx.lookup(o))
                return {o, idx};
            Operation *def = o.getDefiningOp();
            if (def && tails.count(def)) {
                auto call = cast<LLVM::CallOp>(def);
                Value node = call.getArgOperands()[0];
                Value cur = argIdx.lookup(node);
                OpBuilder cb(call);
                auto sn = cb.create<LLVM::CallOp>(
                    call.getLoc(), TypeRange{as1},
                    SymbolRefAttr::get(ctx, kStepNode), ValueRange{node, cur});
                auto si = cb.create<LLVM::CallOp>(
                    call.getLoc(), TypeRange{i64},
                    SymbolRefAttr::get(ctx, kStepIdx), ValueRange{node, cur});
                call->getResult(0).replaceAllUsesWith(sn->getResult(0));
                tails.erase(def);
                call->erase();
                return {sn->getResult(0), si->getResult(0)};
            }
            if (def)
                if (auto it = idxOf.find({def, cast<OpResult>(o).getResultNumber()}); it != idxOf.end())
                    return {o, it->second};
            OpBuilder zb(term);
            return {o, zb.create<arith::ConstantOp>(term->getLoc(), zb.getI64IntegerAttr(0))};
        };

        // Each interior op is replaced once, by a copy with one more i64 result per needed result.
        for (Operation *def : order) {
            SmallVector<unsigned, 2> rs = needed.find(def)->second;
            llvm::sort(rs);
            unsigned oldN = def->getNumResults();
            SmallVector<Type> newTys(def->getResultTypes().begin(),
                                     def->getResultTypes().end());
            newTys.append(rs.size(), i64);
            OpBuilder ob(def);
            Operation *nd = nullptr;
            if (auto ifOp = dyn_cast<scf::IfOp>(def)) {
                auto ni = ob.create<scf::IfOp>(ifOp.getLoc(), newTys,
                                               ifOp.getCondition(),
                                               /*withElseRegion=*/true);
                ni.getThenRegion().takeBody(ifOp.getThenRegion());
                ni.getElseRegion().takeBody(ifOp.getElseRegion());
                nd = ni;
            } else {
                auto sw = cast<scf::IndexSwitchOp>(def);
                auto ns = ob.create<scf::IndexSwitchOp>(
                    sw.getLoc(), newTys, sw.getArg(), sw.getCases(),
                    sw.getCases().size());
                ns.getDefaultRegion().takeBody(sw.getDefaultRegion());
                for (unsigned i = 0; i < sw.getCases().size(); ++i)
                    ns.getCaseRegions()[i].takeBody(sw.getCaseRegions()[i]);
                nd = ns;
            }
            for (Region &r : nd->getRegions()) {
                auto term = cast<scf::YieldOp>(r.front().getTerminator());
                SmallVector<Value> ops(term->getOperands().begin(),
                                       term->getOperands().end());
                for (unsigned rr : rs) {
                    auto pr = resolve(ops[rr], term);
                    ops[rr] = pr.first;
                    ops.push_back(pr.second);
                }
                OpBuilder yb(term);
                yb.create<scf::YieldOp>(term.getLoc(), ops);
                term.erase();
            }
            for (unsigned i = 0; i < oldN; ++i)
                def->getResult(i).replaceAllUsesWith(nd->getResult(i));
            for (unsigned j = 0; j < rs.size(); ++j)
                idxOf[{nd, rs[j]}] = nd->getResult(oldN + j);
            def->erase();
        }

        SmallVector<Value> yields(yieldOp.getOperands().begin(),
                                  yieldOp.getOperands().end());
        for (unsigned i = 0; i < k; ++i) {
            auto pr = resolve(yields[carried[i]], yieldOp);
            yields[carried[i]] = pr.first;
            yields.push_back(pr.second);
        }
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
            auto it = llvm::find(carried, p);
            if (it != carried.end() && !oldRes.use_empty()) {
                Value idx = nw.getResult(n + static_cast<unsigned>(it - carried.begin()));
                auto pv = rb.create<LLVM::CallOp>(
                    loc, TypeRange{as1}, SymbolRefAttr::get(ctx, kPosView),
                    ValueRange{newRes, idx});
                oldRes.replaceAllUsesWith(pv->getResult(0));
                cPosViews++;
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
