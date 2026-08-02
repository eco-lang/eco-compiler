//===- EcoListTemplate.cpp - Cons-accumulation loops to scratch chunks ----===//
//
// Chunked-list Tier-B templates (plans/chunked-list-representation.md §6
// L1.3). Rewrites scf.while loops whose iteration argument is a pure
// cons-ACCUMULATOR — every path through the body either prepends via
// eco.construct.list or passes the accumulator through unchanged (filter
// shapes, conditional prepends through scf.if / scf.index_switch / leftover
// eco.case region yields) — to push each element onto the runtime's
// GC-root-registered list scratch stack instead of allocating a cell per
// iteration. One eco_scratch_finish call after the loop builds the entire
// result as a dense chunk (or cells when small / over-cap / chunks-off; the
// runtime reproduces exactly the cell spine the loop would have built).
//
// The loop BODY is untouched — only the cons op is swapped for a push — so
// LSS-specialized element computations stay inlined (the §9.2 trap this
// design exists to avoid). The accumulator becomes loop-invariant: the init
// value threads through unchanged and exits as the while result, which is
// precisely the `next` tail eco_scratch_finish wants.
//
// Push order equals execution order equals cons order, and finish reverses,
// so multi-cons iterations (unrolled bodies) and conditional prepends are
// handled uniformly: each push sits exactly where its cons sat.
//
// Safety: the scratch entries are GC roots via an external root scanner
// (minor GC phase 1d evacuates them in place), so loop bodies may allocate
// freely between pushes. Nested accumulating loops are balanced by
// mark/finish stack discipline (post-order walk transforms inner loops
// first; an inner loop's finish pops its entries before the outer loop's
// next push).
//
// The pass is a no-op unless some function carries the `eco.list_chunks`
// attribute (stamped on @main for chunk-compiled programs), keeping
// chunks-off output byte-identical.
//
//===----------------------------------------------------------------------===//

#include "mlir/Pass/Pass.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/StringSwitch.h"
#include <cstdlib>
#include <map>
#include <string>

using namespace mlir;
using namespace ::eco;

namespace {

constexpr const char *kMarkFn = "eco_scratch_mark";
constexpr const char *kPushBoxedFn = "eco_scratch_push_boxed";
constexpr const char *kPushScalarFn = "eco_scratch_push_scalar";
constexpr const char *kFinishFn = "eco_scratch_finish";

/// Debug counters (ECO_LIST_TEMPLATE_DEBUG=1): why candidates bailed.
struct BailStats {
    unsigned whiles = 0, valueArgs = 0, beforeFwd = 0, beforeUses = 0,
             chainFail = 0, chainEmpty = 0, baseUses = 0, kinds = 0,
             rewritten = 0;
    // walkChain failure detail
    unsigned wcBlockArg = 0, wcConsUses = 0, wcConsRoots = 0, wcHeadTy = 0,
             wcRegionShape = 0, wcMultiUse = 0, wcOtherOp = 0;
    void dump() {
        fprintf(stderr,
                "[eco-list-template] whiles=%u valueArgs=%u bail{beforeFwd=%u "
                "beforeUses=%u chainFail=%u chainEmpty=%u baseUses=%u "
                "kinds=%u} rewritten=%u\n"
                "[eco-list-template] walkChain{blockArg=%u consUses=%u "
                "consRoots=%u headTy=%u regionShape=%u multiUse=%u "
                "otherOp=%u}\n",
                whiles, valueArgs, beforeFwd, beforeUses, chainFail,
                chainEmpty, baseUses, kinds, rewritten, wcBlockArg,
                wcConsUses, wcConsRoots, wcHeadTy, wcRegionShape, wcMultiUse,
                wcOtherOp);
    }
};

/// One prepend link: either eco.construct.list or a direct call to the
/// Elm_Kernel_List_cons family. Both carry (head, tail) as operands 0/1.
struct ConsLink {
    Operation *op;
    int64_t kind;  // 2-bit element kind (0 boxed, 1 Int, 2 Float, 3 Char)
};

/// Kernel-cons callee -> element kind, or -1 when not a cons call.
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

/// The accumulation chain discovered for one while iter-arg position.
struct Chain {
    SmallVector<ConsLink, 8> conses;
    // The exact operand slots through which the base (after-region block
    // argument) is allowed to be used. After the walk, every use of the
    // base must be one of these.
    SmallPtrSet<OpOperand *, 8> baseUses;
    bool ok = true;
    BailStats *bs = nullptr;
    llvm::SmallVector<Operation *, 4> otherOps;  // debug: chain-breaking ops
};

/// Validates that `v` is `base` extended by zero or more (possibly
/// conditional) eco.construct.list prepends, recording the conses and the
/// expected base-use slots. `slot` is the operand that consumes `v`.
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
        if (c.getLiveRoots().empty())
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
                    (consKind == 3 && ht.isInteger(16));
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
    if (isa<eco::ListConstructOp>(def)) {
        // construct.list carrying live-root hints: leave it alone.
        if (ch.bs) ch.bs->wcConsRoots++;
        ch.ok = false;
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

/// Secondary-slot walk, correlated with the loop's done-flag: joinpoint
/// normalization yields a fresh placeholder constant at the result slot on
/// continue arms (done = false), where the value is never observed — accept
/// anything there. On exit arms (done = true) and when the done shape is
/// unknown, the slot must be identity or a chain rooted at the primary base
/// (a constant on a true-exit arm is a legitimate `-> []` return and must
/// block the rewrite).
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

/// Ensures a private kernel-style declaration exists for `name`.
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
        // Post-order walk: inner loops are transformed before outer ones,
        // which is what keeps nested mark/finish pairs balanced.
        m.walk([&](scf::WhileOp w) {
            bs.whiles++;
            if (tryRewrite(m, w, declsMade, debug ? &bs : nullptr))
                bs.rewritten++;
        });
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

    llvm::SmallVector<Operation *, 16> debugOtherOps;
    llvm::SmallVector<Operation *, 16> debugBaseUseOwners;

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
                else if (h.getType().isInteger(16))
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
};

} // namespace

std::unique_ptr<Pass> eco::createEcoListTemplatePass() {
    return std::make_unique<EcoListTemplatePass>();
}
