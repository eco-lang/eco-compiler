//===- EcoFlattenAggBoundary.cpp - Flatten aggregate func boundaries -----===//
//
// Phase 3.1 #3 pre-lowering pass. Rewrites func.func boundaries so no
// aggregate type (`!eco.tuple2/3`, `!eco.record`, `!eco.custom`) appears
// in any `function_type` after this pass runs.
//
// For each func with aggregate-typed params/results in its signature
// (typically the workers cloned by EcoUnboxedAggCrossSpec):
//
//   - Each aggregate parameter is expanded into N scalar parameters
//     (one per element). At the entry block, an `eco.make.*` op
//     materialises the original aggregate SSA value from the new
//     scalar block args; every use of the old aggregate-typed block
//     arg becomes a use of the make op's result. SROA will then fold
//     the make/project chain inside the body to direct scalar reads.
//
//   - Each aggregate result is expanded into N scalar results. Every
//     `func.return` decomposes the aggregate return operand via
//     `eco.project.*` and emits the scalar fields directly.
//
//   - Every `func.call` that targets a flattened function is rewritten
//     symmetrically: aggregate operands are decomposed via project.*
//     immediately before the call, and aggregate-typed call results
//     are materialised via make.* immediately after.
//
// After this pass, the LLVM dialect's `func.func` signatures use only
// scalar / pointer types. RS4GC's FCA-unimplemented assertion (which
// trips on pass-by-value structs containing `ptr addrspace(1)`) is
// avoided structurally — the only struct values left after the pass
// live inside function bodies, where SROA can scalarise them.
//
// This pass lifts the all-primitive-elements guard that
// EcoUnboxedAggCrossSpec used to enforce. After flatten runs, aggregate
// params/results carrying `!eco.value` fields are perfectly safe.
//
// Custom aggregates carry a structural `tag` attribute on
// `eco.make.custom` (per Q-B). The flatten pass reads the tag from the
// function's `eco.logical_param_types` / `eco.logical_result_types`
// attributes ("custom:Tag:N:...") so make.custom can be reconstructed
// faithfully.
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"

using namespace mlir;

namespace {

constexpr llvm::StringLiteral kLogicalParamTypesAttr = "eco.logical_param_types";
constexpr llvm::StringLiteral kLogicalResultTypesAttr = "eco.logical_result_types";
constexpr llvm::StringLiteral kFlattenedBoundaryAttr = "eco.flattened_boundary";

/// Element types and (for Custom) tag carried alongside an aggregate
/// slot during the flatten rewrite. Tuple2/3 and Record carry only
/// element types; Custom carries the tag attribute parsed from the
/// function's logical-types DSL string.
struct AggSlot {
    enum Kind { None, Tuple2, Tuple3, Record, Custom };
    Kind kind = None;
    /// Element types in declared order. Empty for None.
    SmallVector<Type, 4> elementTys;
    /// Custom constructor tag; zero for other kinds.
    int64_t customTag = 0;

    bool isAggregate() const { return kind != None; }
    unsigned arity() const { return elementTys.size(); }
};

/// Map a single-character element kind from the logical-types DSL onto
/// its MLIR primitive type. Anything we don't recognise falls back to
/// `!eco.value` so the flattened param stays GC-safe.
static Type kindCharToType(char c, MLIRContext *ctx) {
    switch (c) {
    case 'i':
        return IntegerType::get(ctx, 64);
    case 'f':
        return Float64Type::get(ctx);
    case 'c':
        return IntegerType::get(ctx, 16);
    case 'v':
    default:
        return eco::ValueType::get(ctx);
    }
}

/// Try to parse a single logical-types entry into an AggSlot. Returns
/// AggSlot{None} for primitive / boxed / Cons / unknown entries (Cons
/// is deliberately not flattened in 3.1 per Q4 — its boundary type is
/// always `!eco.value` after cross-spec demotes it).
static AggSlot parseAggSlot(StringRef s, MLIRContext *ctx) {
    AggSlot out;
    if (s.empty() || s == "value") return out;
    if (s == "i64" || s == "f64" || s == "i16" || s == "i1") return out;

    SmallVector<StringRef, 8> parts;
    s.split(parts, ':');
    if (parts.empty()) return out;
    StringRef tag = parts[0];

    if (tag == "tuple2" && parts.size() == 3) {
        out.kind = AggSlot::Tuple2;
        out.elementTys.push_back(kindCharToType(parts[1][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[2][0], ctx));
        return out;
    }
    if (tag == "tuple3" && parts.size() == 4) {
        out.kind = AggSlot::Tuple3;
        out.elementTys.push_back(kindCharToType(parts[1][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[2][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[3][0], ctx));
        return out;
    }
    if (tag == "record" && parts.size() >= 2) {
        unsigned n = 0;
        if (parts[1].getAsInteger(10, n)) return out;
        if (parts.size() != 2 + n) return out;
        out.kind = AggSlot::Record;
        for (unsigned i = 0; i < n; ++i)
            out.elementTys.push_back(kindCharToType(parts[2 + i][0], ctx));
        return out;
    }
    if (tag == "custom" && parts.size() >= 3) {
        int64_t customTag = 0;
        unsigned n = 0;
        if (parts[1].getAsInteger(10, customTag)) return out;
        if (parts[2].getAsInteger(10, n)) return out;
        if (parts.size() != 3 + n) return out;
        out.kind = AggSlot::Custom;
        out.customTag = customTag;
        for (unsigned i = 0; i < n; ++i)
            out.elementTys.push_back(kindCharToType(parts[3 + i][0], ctx));
        return out;
    }
    return out;
}

/// Read the function's logical-types attrs and return an AggSlot per
/// param/result. Slots are AggSlot{None} when the entry is primitive /
/// boxed / unrecognised. Returns false only if both attributes are
/// entirely absent — that case is signalled by the caller as "no
/// flatten work to do" rather than as a parse failure.
static bool readAggSlots(func::FuncOp func,
                         SmallVectorImpl<AggSlot> &paramSlots,
                         SmallVectorImpl<AggSlot> &resultSlots) {
    auto paramAttr = func->getAttrOfType<ArrayAttr>(kLogicalParamTypesAttr);
    auto resultAttr = func->getAttrOfType<ArrayAttr>(kLogicalResultTypesAttr);
    if (!paramAttr && !resultAttr) return false;
    MLIRContext *ctx = func.getContext();

    paramSlots.clear();
    if (paramAttr) {
        for (Attribute a : paramAttr) {
            auto sa = dyn_cast<StringAttr>(a);
            paramSlots.push_back(sa ? parseAggSlot(sa.getValue(), ctx)
                                    : AggSlot{});
        }
    }
    resultSlots.clear();
    if (resultAttr) {
        for (Attribute a : resultAttr) {
            auto sa = dyn_cast<StringAttr>(a);
            resultSlots.push_back(sa ? parseAggSlot(sa.getValue(), ctx)
                                     : AggSlot{});
        }
    }
    return true;
}

/// True if `t` is one of the value-aggregate MLIR types this pass knows
/// how to flatten. Cons and ClosureEnv are intentionally excluded: in
/// Phase 3.1 Cons stays boxed (Q4) and ClosureEnv is Phase 4 scope.
static bool isFlattenableAggregateType(Type t) {
    return isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
               eco::CustomType>(t);
}

/// Materialise an `eco.make.*` op that builds an aggregate of the
/// given `slot` shape from `fieldValues`. Inserts at the builder's
/// current position.
static Value buildMakeOp(OpBuilder &builder, Location loc,
                         const AggSlot &slot, ValueRange fieldValues) {
    MLIRContext *ctx = builder.getContext();
    switch (slot.kind) {
    case AggSlot::Tuple2: {
        Type resTy = eco::Tuple2Type::get(ctx, slot.elementTys[0],
                                          slot.elementTys[1]);
        return builder.create<eco::Tuple2MakeOp>(
            loc, resTy, fieldValues[0], fieldValues[1]);
    }
    case AggSlot::Tuple3: {
        Type resTy = eco::Tuple3Type::get(ctx, slot.elementTys[0],
                                          slot.elementTys[1],
                                          slot.elementTys[2]);
        return builder.create<eco::Tuple3MakeOp>(
            loc, resTy, fieldValues[0], fieldValues[1], fieldValues[2]);
    }
    case AggSlot::Record: {
        Type resTy = eco::RecordType::get(ctx, slot.elementTys);
        return builder.create<eco::RecordMakeOp>(loc, resTy, fieldValues);
    }
    case AggSlot::Custom: {
        Type resTy = eco::CustomType::get(ctx, slot.elementTys);
        auto tagAttr = builder.getI64IntegerAttr(slot.customTag);
        return builder.create<eco::CustomMakeOp>(
            loc, resTy, fieldValues, tagAttr, /*constructor=*/StringAttr());
    }
    case AggSlot::None:
        break;
    }
    llvm_unreachable("buildMakeOp called on non-aggregate slot");
}

/// Decompose an aggregate SSA value into its fields by emitting one
/// `eco.project.*` op per element. The projections become operands of
/// the surrounding call/return op. SROA folds them with the producing
/// make.* op when both sit in the same function.
static void buildProjectFields(OpBuilder &builder, Location loc,
                               const AggSlot &slot, Value aggValue,
                               SmallVectorImpl<Value> &out) {
    for (unsigned i = 0; i < slot.arity(); ++i) {
        Type elemTy = slot.elementTys[i];
        auto idxAttr = builder.getI64IntegerAttr(static_cast<int64_t>(i));
        switch (slot.kind) {
        case AggSlot::Tuple2:
            out.push_back(builder.create<eco::Tuple2ProjectOp>(
                loc, elemTy, aggValue, idxAttr));
            break;
        case AggSlot::Tuple3:
            out.push_back(builder.create<eco::Tuple3ProjectOp>(
                loc, elemTy, aggValue, idxAttr));
            break;
        case AggSlot::Record:
            out.push_back(builder.create<eco::RecordProjectOp>(
                loc, elemTy, aggValue, idxAttr));
            break;
        case AggSlot::Custom:
            out.push_back(builder.create<eco::CustomProjectOp>(
                loc, elemTy, aggValue, idxAttr));
            break;
        case AggSlot::None:
            llvm_unreachable("buildProjectFields called on non-aggregate slot");
        }
    }
}

/// True iff `func`'s function_type already contains any aggregate-
/// flavoured type that this pass would flatten.
static bool signatureHasAggregate(func::FuncOp func) {
    for (Type t : func.getFunctionType().getInputs())
        if (isFlattenableAggregateType(t)) return true;
    for (Type t : func.getFunctionType().getResults())
        if (isFlattenableAggregateType(t)) return true;
    return false;
}

/// Sync an AggSlot with the MLIR type at the same boundary position.
/// If the function's logical-types attr disagrees with the actual MLIR
/// type (e.g. attr says "value" but the signature carries an aggregate
/// type because cross-spec promoted it), prefer the MLIR type — it's
/// what the verifier accepts. Custom tag falls back to 0 in that case.
static AggSlot reconcileWithType(const AggSlot &fromAttr, Type mlirTy) {
    if (!isFlattenableAggregateType(mlirTy)) return AggSlot{};
    if (fromAttr.isAggregate()) {
        // Trust attr if the kind & element types line up; otherwise
        // rebuild from the MLIR type.
        if (auto tup2 = dyn_cast<eco::Tuple2Type>(mlirTy);
            tup2 && fromAttr.kind == AggSlot::Tuple2 &&
            fromAttr.elementTys.size() == 2)
            return fromAttr;
        if (auto tup3 = dyn_cast<eco::Tuple3Type>(mlirTy);
            tup3 && fromAttr.kind == AggSlot::Tuple3 &&
            fromAttr.elementTys.size() == 3)
            return fromAttr;
        if (auto rec = dyn_cast<eco::RecordType>(mlirTy);
            rec && fromAttr.kind == AggSlot::Record &&
            fromAttr.elementTys.size() == rec.getFields().size())
            return fromAttr;
        if (auto cus = dyn_cast<eco::CustomType>(mlirTy);
            cus && fromAttr.kind == AggSlot::Custom &&
            fromAttr.elementTys.size() == cus.getFields().size())
            return fromAttr;
    }

    // Fall back: derive from the MLIR type alone.
    AggSlot out;
    if (auto tup2 = dyn_cast<eco::Tuple2Type>(mlirTy)) {
        out.kind = AggSlot::Tuple2;
        out.elementTys.push_back(tup2.getFirst());
        out.elementTys.push_back(tup2.getSecond());
    } else if (auto tup3 = dyn_cast<eco::Tuple3Type>(mlirTy)) {
        out.kind = AggSlot::Tuple3;
        out.elementTys.push_back(tup3.getFirst());
        out.elementTys.push_back(tup3.getSecond());
        out.elementTys.push_back(tup3.getThird());
    } else if (auto rec = dyn_cast<eco::RecordType>(mlirTy)) {
        out.kind = AggSlot::Record;
        for (Type t : rec.getFields()) out.elementTys.push_back(t);
    } else if (auto cus = dyn_cast<eco::CustomType>(mlirTy)) {
        out.kind = AggSlot::Custom;
        out.customTag = fromAttr.customTag;
        for (Type t : cus.getFields()) out.elementTys.push_back(t);
    }
    return out;
}

/// Build the flattened input / result type lists and a per-old-index
/// mapping `firstNewIdx` (so `firstNewIdx[k]` is the offset of the
/// k-th old slot's first scalar in the flattened list, and the next
/// entry's `firstNewIdx[k+1] - firstNewIdx[k]` gives its width — with
/// a sentinel entry at the end equal to the new list length).
struct FlatLayout {
    SmallVector<Type, 8> newInputs;
    SmallVector<Type, 4> newResults;
    SmallVector<unsigned, 8> firstNewInputIdx;
    SmallVector<unsigned, 4> firstNewResultIdx;
    SmallVector<AggSlot, 8> paramSlots;
    SmallVector<AggSlot, 4> resultSlots;
};

static FlatLayout buildLayout(func::FuncOp func) {
    FlatLayout out;
    FunctionType ft = func.getFunctionType();

    SmallVector<AggSlot, 8> paramSlots;
    SmallVector<AggSlot, 4> resultSlots;
    readAggSlots(func, paramSlots, resultSlots);

    // Pad slot vectors to the actual signature size so reconcile sees
    // a valid entry even when attrs are absent or under-populated.
    paramSlots.resize(ft.getNumInputs());
    resultSlots.resize(ft.getNumResults());

    for (unsigned i = 0; i < ft.getNumInputs(); ++i) {
        out.firstNewInputIdx.push_back(out.newInputs.size());
        AggSlot slot = reconcileWithType(paramSlots[i], ft.getInput(i));
        out.paramSlots.push_back(slot);
        if (slot.isAggregate())
            for (Type t : slot.elementTys) out.newInputs.push_back(t);
        else
            out.newInputs.push_back(ft.getInput(i));
    }
    out.firstNewInputIdx.push_back(out.newInputs.size());

    for (unsigned i = 0; i < ft.getNumResults(); ++i) {
        out.firstNewResultIdx.push_back(out.newResults.size());
        AggSlot slot = reconcileWithType(resultSlots[i], ft.getResult(i));
        out.resultSlots.push_back(slot);
        if (slot.isAggregate())
            for (Type t : slot.elementTys) out.newResults.push_back(t);
        else
            out.newResults.push_back(ft.getResult(i));
    }
    out.firstNewResultIdx.push_back(out.newResults.size());

    return out;
}

/// Replace the entry block's aggregate params with `arity` scalar
/// params each, and materialise the original aggregate values via
/// `eco.make.*` so existing uses still type-check. The flattened
/// parameter list is `layout.newInputs` in order.
static void rewriteEntryBlock(func::FuncOp func, const FlatLayout &layout) {
    Block &entry = func.getBody().front();
    Location loc = func.getLoc();
    MLIRContext *ctx = func.getContext();

    // Snapshot the current block args before we mutate the list.
    SmallVector<Value, 8> oldArgs;
    oldArgs.reserve(entry.getNumArguments());
    for (BlockArgument a : entry.getArguments()) oldArgs.push_back(a);

    // Append the flattened scalar args after the current ones, then
    // rewire and erase old args. This avoids juggling index shifts in
    // the middle of the list.
    SmallVector<BlockArgument, 8> newArgs;
    newArgs.reserve(layout.newInputs.size());
    for (Type t : layout.newInputs)
        newArgs.push_back(entry.addArgument(t, loc));

    OpBuilder builder(ctx);
    builder.setInsertionPointToStart(&entry);

    for (unsigned oldIdx = 0; oldIdx < layout.paramSlots.size(); ++oldIdx) {
        const AggSlot &slot = layout.paramSlots[oldIdx];
        unsigned first = layout.firstNewInputIdx[oldIdx];
        if (slot.isAggregate()) {
            SmallVector<Value, 4> fields;
            for (unsigned k = 0; k < slot.arity(); ++k)
                fields.push_back(newArgs[first + k]);
            Value rebuilt = buildMakeOp(builder, loc, slot, fields);
            oldArgs[oldIdx].replaceAllUsesWith(rebuilt);
        } else {
            // Non-aggregate: just forward the corresponding new arg.
            oldArgs[oldIdx].replaceAllUsesWith(newArgs[first]);
        }
    }

    // Erase the old block args. They're at indices 0..oldArgs.size()-1.
    BitVector toErase(entry.getNumArguments(), false);
    for (unsigned i = 0; i < oldArgs.size(); ++i) toErase.set(i);
    entry.eraseArguments(toErase);
}

/// For each `func.return` terminator in the function, decompose any
/// aggregate operand into its scalar fields via `eco.project.*` so the
/// flattened return type list lines up. Non-aggregate operands pass
/// through unchanged.
static void rewriteReturns(func::FuncOp func, const FlatLayout &layout) {
    SmallVector<func::ReturnOp, 4> returns;
    func.walk([&](func::ReturnOp r) { returns.push_back(r); });
    for (func::ReturnOp ret : returns) {
        OpBuilder builder(ret);
        SmallVector<Value, 8> newOperands;
        newOperands.reserve(layout.newResults.size());
        for (unsigned i = 0; i < layout.resultSlots.size(); ++i) {
            const AggSlot &slot = layout.resultSlots[i];
            Value v = ret.getOperand(i);
            if (slot.isAggregate()) {
                SmallVector<Value, 4> fields;
                buildProjectFields(builder, ret.getLoc(), slot, v, fields);
                for (Value f : fields) newOperands.push_back(f);
            } else {
                newOperands.push_back(v);
            }
        }
        ret->setOperands(newOperands);
    }
}

/// Rewrite a single `func.call @target(...)` whose target was just
/// flattened. Decomposes each aggregate operand via `eco.project.*`
/// immediately before the call, and re-materialises each aggregate
/// result via `eco.make.*` immediately after.
static void rewriteCallSite(func::CallOp call, const FlatLayout &layout) {
    OpBuilder builder(call);
    Location loc = call.getLoc();

    SmallVector<Value, 8> newOperands;
    newOperands.reserve(layout.newInputs.size());
    for (unsigned i = 0; i < layout.paramSlots.size(); ++i) {
        const AggSlot &slot = layout.paramSlots[i];
        Value v = call.getOperand(i);
        if (slot.isAggregate()) {
            SmallVector<Value, 4> fields;
            buildProjectFields(builder, loc, slot, v, fields);
            for (Value f : fields) newOperands.push_back(f);
        } else {
            newOperands.push_back(v);
        }
    }

    // Snapshot original aggregate-result uses before replacement.
    SmallVector<SmallVector<OpOperand *, 4>, 4> oldResultUses;
    oldResultUses.reserve(layout.resultSlots.size());
    for (unsigned i = 0; i < layout.resultSlots.size(); ++i) {
        SmallVector<OpOperand *, 4> uses;
        for (OpOperand &u : call.getResult(i).getUses()) uses.push_back(&u);
        oldResultUses.push_back(std::move(uses));
    }

    auto newCall = builder.create<func::CallOp>(
        loc, call.getCallee(), layout.newResults, newOperands);

    // Stitch the flattened results back into aggregates so existing
    // consumers continue to see the original aggregate SSA values.
    builder.setInsertionPointAfter(newCall);
    for (unsigned i = 0; i < layout.resultSlots.size(); ++i) {
        const AggSlot &slot = layout.resultSlots[i];
        unsigned first = layout.firstNewResultIdx[i];
        if (slot.isAggregate()) {
            SmallVector<Value, 4> fields;
            for (unsigned k = 0; k < slot.arity(); ++k)
                fields.push_back(newCall.getResult(first + k));
            Value rebuilt = buildMakeOp(builder, loc, slot, fields);
            for (OpOperand *u : oldResultUses[i]) u->set(rebuilt);
        } else {
            for (OpOperand *u : oldResultUses[i])
                u->set(newCall.getResult(first));
        }
    }

    call.erase();
}

struct EcoFlattenAggBoundaryPass
    : public PassWrapper<EcoFlattenAggBoundaryPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoFlattenAggBoundaryPass)

    StringRef getArgument() const override {
        return "eco-flatten-agg-boundary";
    }
    StringRef getDescription() const override {
        return "Phase 3.1 #3: flatten aggregate-typed func.func boundaries "
               "(params/results) into scalar lists with eco.make.* / "
               "eco.project.* shims at the entry and at call sites.";
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();

        // Step 1: identify targets — funcs with aggregate-typed sig.
        // Walk into a stable list before mutating any of them.
        SmallVector<func::FuncOp, 16> targets;
        module.walk([&](func::FuncOp f) {
            if (f.isExternal()) return;
            if (!signatureHasAggregate(f)) return;
            targets.push_back(f);
        });

        // Step 2: compute layouts and rewrite each target's body.
        // Stash the layouts so call-site rewriting can reuse them.
        llvm::DenseMap<StringRef, FlatLayout> layouts;
        for (func::FuncOp f : targets) {
            FlatLayout layout = buildLayout(f);
            rewriteEntryBlock(f, layout);
            rewriteReturns(f, layout);
            f.setFunctionType(FunctionType::get(
                f.getContext(), layout.newInputs, layout.newResults));
            f->setAttr(kFlattenedBoundaryAttr,
                       UnitAttr::get(f.getContext()));
            layouts[f.getName()] = std::move(layout);
        }

        // Step 3: rewrite all call sites whose callee was flattened.
        SmallVector<func::CallOp, 16> callsToRewrite;
        module.walk([&](func::CallOp call) {
            if (layouts.count(call.getCallee()))
                callsToRewrite.push_back(call);
        });
        for (func::CallOp call : callsToRewrite)
            rewriteCallSite(call, layouts[call.getCallee()]);
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoFlattenAggBoundaryPass() {
    return std::make_unique<EcoFlattenAggBoundaryPass>();
}
