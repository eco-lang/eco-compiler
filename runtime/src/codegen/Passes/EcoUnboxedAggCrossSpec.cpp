//===- EcoUnboxedAggCrossSpec.cpp - Phase 3 cross-function specialize -----===//
//
// Module-level pass that lifts the unboxing opportunity from intra-function
// (Phase 1/2) to cross-function. For each `func.func @f` whose
// `eco.logical_param_types` / `eco.logical_result_types` attributes mark
// at least one small aggregate parameter or result (tuple2 / tuple3 /
// record), it:
//
//   1. Clones the function as `@f$unboxed` with rewritten signature
//      (each eligible aggregate param/result becomes the matching
//      `!eco.tuple2<...>` / `!eco.tuple3<...>` / `!eco.record<...>`).
//   2. Replaces `@f`'s original body with a thin wrapper that:
//        - calls `eco.from_heap` on each aggregate parameter
//        - delegates to `@f$unboxed`
//        - calls `eco.to_heap` on the aggregate result
//        - returns the boxed result, preserving the original ABI.
//
// v1 scope:
//   - Tuples (2/3) and records only — customs and lists are encoded as
//     "value" by the front-end (CGEN_065) and skipped here.
//   - One-level unboxing: aggregate elements stay as their ABI types
//     (typically `!eco.value` for boxed, `i64`/`f64`/`i16` for primitives).
//   - **Parameter aggregates only**: the worker rewrites aggregate-shaped
//     parameters into aggregate types but leaves results in their original
//     boxed form. Aggregate-shaped result rewriting requires unboxing a
//     `!eco.value` produced by the body, which only makes sense once
//     Step 4 rewrites construct ops in the body. For v1, an aggregate-
//     shaped result simply gets no signature change.
//   - The worker body's `eco.project.*` ops automatically lower from the
//     value-aggregate path (Phase 0 plumbing) once the entry-block arg
//     is retyped to the aggregate type — no bridging op needed inside
//     the worker.
//   - No call-site rewriting yet (Step 4 — callers continue to call the
//     wrapper). The wrapper introduces an indirection but keeps the ABI
//     intact.
//
// Eligibility for v1:
//   - `eco.logical_param_types` is present.
//   - At least one parameter entry encodes a tuple2 / tuple3 / record.
//   - The function has a body (non-extern, non-kernel-decl).
//
//===----------------------------------------------------------------------===//

#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../EcoTypes.h"
#include "../Passes.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/StringRef.h"

using namespace mlir;

namespace {

constexpr llvm::StringLiteral kLogicalParamTypesAttr = "eco.logical_param_types";
constexpr llvm::StringLiteral kLogicalResultTypesAttr = "eco.logical_result_types";
constexpr llvm::StringLiteral kUnboxedWorkerAttr = "eco.unboxed_worker";
constexpr llvm::StringLiteral kUnboxedWorkerSuffix = "$unboxed";

/// A parsed logical type. Encodes whether the parameter or result is a
/// non-aggregate ABI value or a value-level aggregate that the cross-spec
/// pass can lift into a worker signature.
struct LogicalShape {
    enum Kind { Boxed, Primitive, Tuple2, Tuple3, Record, Custom, Cons };
    Kind kind = Boxed;
    /// For Primitive: the MLIR primitive type (i64/f64/i16/i1).
    /// For aggregates: empty.
    Type primitiveTy;
    /// For aggregates: the element types (in declared order).
    SmallVector<Type, 8> elementTys;
    /// For Custom: the constructor tag (op attribute is structural per
    /// Q-B). Unused for other kinds.
    int64_t customTag = 0;

    /// Phase 3.1 #2 promotes Custom to a real cross-spec target. Cons
    /// stays Boxed (Q4: AggKind::None) until a real use case appears.
    bool isAggregate() const {
        return kind == Tuple2 || kind == Tuple3 || kind == Record ||
               kind == Custom;
    }

    /// True if the parser recognised this shape as an aggregate-shaped
    /// entry (tuple/record/custom/cons). Cross-spec uses this to detect
    /// "logical info available but not eligible yet" (vs "no info at
    /// all" via the Boxed default), purely for future-phase telemetry.
    bool isParsedAggregateShape() const {
        return kind == Tuple2 || kind == Tuple3 || kind == Record ||
               kind == Custom || kind == Cons;
    }

    /// Materialise the corresponding MLIR type used in the worker
    /// signature: aggregate types for aggregates, primitive types for
    /// primitives, `!eco.value` for everything else (Cons stays boxed
    /// in 3.1 per Q4).
    Type asWorkerType(MLIRContext *ctx) const {
        switch (kind) {
        case Boxed:
        case Cons:
            return eco::ValueType::get(ctx);
        case Primitive:
            return primitiveTy;
        case Tuple2:
            return eco::Tuple2Type::get(ctx, elementTys[0], elementTys[1]);
        case Tuple3:
            return eco::Tuple3Type::get(ctx, elementTys[0], elementTys[1],
                                         elementTys[2]);
        case Record:
            return eco::RecordType::get(ctx, elementTys);
        case Custom:
            return eco::CustomType::get(ctx, elementTys);
        }
        llvm_unreachable("unhandled LogicalShape::Kind");
    }
};

/// How the worker returns each result position:
///   - Direct: the result stays on the LLVM return list. Used for
///     scalars, `!eco.value` results, and aggregate results whose
///     elements are all primitive (LLVM packs them into a struct
///     return; RS4GC accepts it because no field is GC‑managed).
///   - Sret: the result is dropped from the LLVM return list and a
///     leading `!llvm.ptr` outparam carries it. Used for aggregate
///     results containing at least one `!eco.value` element — the
///     only path that avoids RS4GC's FCA‑unimplemented assertion
///     on a struct return containing `ptr addrspace(1)`
///     (REP_AGG_001 amendment, Phase 3.3).
///   - Boxed: the result was demoted by the eligibility analysis
///     and stays as `!eco.value` on both worker and wrapper sides
///     (existing behaviour pre‑3.3).
enum class ResultAbi { Direct, Sret, Boxed };

/// Largest field count that the Direct ABI may emit. LLVM 21's
/// SelectionDAG StatepointLowering walks past the lowered call expecting
/// `CALLSEQ_END`, but for a struct-returning call it finds the chain of
/// `CopyFromReg` nodes (one per struct field) and asserts at
/// `StatepointLowering.cpp:354`. Empirically (Phase A sweep), N=1..3
/// pass; N=4..8 all assert. Wider all-primitive aggregates route through
/// Sret instead so no struct return crosses the statepoint boundary.
static constexpr unsigned kMaxDirectFields = 3;

/// Pick the ABI for a result whose `LogicalShape` was already
/// promoted (`isAggregate()` is true on entry).
///   - Aggregates with any `!eco.value` element → Sret (avoids RS4GC's
///     FCA-unimplemented assertion on a struct return holding gc ptrs).
///   - All-primitive aggregates wider than `kMaxDirectFields` → Sret
///     (avoids SelectionDAG's wide-struct-return crash on the gc.statepoint
///     call).
///   - Otherwise → Direct (LLVM multi-return packing).
static ResultAbi chooseResultAbi(const LogicalShape &shape) {
    if (!shape.isAggregate()) return ResultAbi::Boxed;
    for (Type t : shape.elementTys) {
        if (isa<eco::ValueType>(t)) return ResultAbi::Sret;
    }
    if (shape.elementTys.size() > kMaxDirectFields) return ResultAbi::Sret;
    return ResultAbi::Direct;
}

/// Convert a single-character element kind from the logical-types DSL
/// (`i`/`f`/`c`/`v`) into its MLIR type.
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

/// Parse a logical-types DSL string (per CGEN_065) into a LogicalShape.
/// Returns false on parse error; on failure, `out.kind = Boxed` so the
/// caller can safely treat the result as non-aggregate.
static bool parseLogicalShape(StringRef s, MLIRContext *ctx,
                              LogicalShape &out) {
    out = LogicalShape{};
    if (s.empty() || s == "value") {
        out.kind = LogicalShape::Boxed;
        return true;
    }
    if (s == "i64") {
        out.kind = LogicalShape::Primitive;
        out.primitiveTy = IntegerType::get(ctx, 64);
        return true;
    }
    if (s == "f64") {
        out.kind = LogicalShape::Primitive;
        out.primitiveTy = Float64Type::get(ctx);
        return true;
    }
    if (s == "i16") {
        out.kind = LogicalShape::Primitive;
        out.primitiveTy = IntegerType::get(ctx, 16);
        return true;
    }
    if (s == "i1") {
        out.kind = LogicalShape::Primitive;
        out.primitiveTy = IntegerType::get(ctx, 1);
        return true;
    }
    // Aggregate forms: split on ':'.
    SmallVector<StringRef, 8> parts;
    s.split(parts, ':');
    if (parts.empty()) return false;
    StringRef tag = parts[0];
    if (tag == "tuple2" && parts.size() == 3) {
        out.kind = LogicalShape::Tuple2;
        out.elementTys.push_back(kindCharToType(parts[1][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[2][0], ctx));
        return true;
    }
    if (tag == "tuple3" && parts.size() == 4) {
        out.kind = LogicalShape::Tuple3;
        out.elementTys.push_back(kindCharToType(parts[1][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[2][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[3][0], ctx));
        return true;
    }
    if (tag == "record" && parts.size() >= 2) {
        unsigned n = 0;
        if (parts[1].getAsInteger(10, n)) return false;
        if (parts.size() != 2 + n) return false;
        out.kind = LogicalShape::Record;
        for (unsigned i = 0; i < n; ++i)
            out.elementTys.push_back(kindCharToType(parts[2 + i][0], ctx));
        return true;
    }
    if (tag == "custom" && parts.size() >= 3) {
        // Encoding: "custom:Tag:N:K0:...:KN-1"
        int64_t customTag = 0;
        unsigned n = 0;
        if (parts[1].getAsInteger(10, customTag)) return false;
        if (parts[2].getAsInteger(10, n)) return false;
        if (parts.size() != 3 + n) return false;
        out.kind = LogicalShape::Custom;
        out.customTag = customTag;
        for (unsigned i = 0; i < n; ++i)
            out.elementTys.push_back(kindCharToType(parts[3 + i][0], ctx));
        return true;
    }
    if (tag == "cons" && parts.size() == 3) {
        // Encoding: "cons:Khead:Ktail" — tail is currently always `v`
        // (boxed) since List is recursive, but accept any char so future
        // unboxed-spine extensions don't have to widen the parser.
        out.kind = LogicalShape::Cons;
        out.elementTys.push_back(kindCharToType(parts[1][0], ctx));
        out.elementTys.push_back(kindCharToType(parts[2][0], ctx));
        return true;
    }
    return false;
}

/// Read the `eco.logical_param_types` / `eco.logical_result_types`
/// attributes off `func` and parse them into a per-position LogicalShape.
/// Returns false if either attribute is missing or malformed.
static bool readLogicalShapes(func::FuncOp func,
                              SmallVectorImpl<LogicalShape> &paramShapes,
                              SmallVectorImpl<LogicalShape> &resultShapes) {
    auto paramAttr = func->getAttrOfType<ArrayAttr>(kLogicalParamTypesAttr);
    auto resultAttr = func->getAttrOfType<ArrayAttr>(kLogicalResultTypesAttr);
    if (!paramAttr || !resultAttr) return false;
    MLIRContext *ctx = func.getContext();

    paramShapes.clear();
    for (Attribute a : paramAttr) {
        auto sa = dyn_cast<StringAttr>(a);
        if (!sa) return false;
        LogicalShape shape;
        if (!parseLogicalShape(sa.getValue(), ctx, shape)) return false;
        paramShapes.push_back(shape);
    }
    resultShapes.clear();
    for (Attribute a : resultAttr) {
        auto sa = dyn_cast<StringAttr>(a);
        if (!sa) return false;
        LogicalShape shape;
        if (!parseLogicalShape(sa.getValue(), ctx, shape)) return false;
        resultShapes.push_back(shape);
    }
    return true;
}

/// True if at least one shape is an aggregate eligible for cross-spec.
/// Phase 3.1 #3 lifts the v1 all-primitive guard on parameters: the
/// EcoFlattenAggBoundary pass runs immediately after cross-spec and
/// scalarises every aggregate-typed function boundary, so aggregates
/// carrying `!eco.value` elements no longer trip RewriteStatepointsForGC.
static bool hasAggregateShape(ArrayRef<LogicalShape> shapes) {
    for (const auto &s : shapes) {
        if (s.isAggregate()) return true;
    }
    return false;
}

/// Compute the 2-bit-per-slot `unboxed_bitmap` value (REP_HEAP_002)
/// for the given element types, mirroring the encoding produced by the
/// Elm-side codegen: 0=boxed, 1=Int(i64), 2=Float(f64), 3=Char(i16).
static int64_t computeUnboxedBitmap(ArrayRef<Type> elementTys) {
    int64_t bitmap = 0;
    for (unsigned i = 0; i < elementTys.size(); ++i) {
        Type t = elementTys[i];
        int kind = 0;
        if (t.isInteger(64)) kind = 1;
        else if (t.isF64()) kind = 2;
        else if (t.isInteger(16)) kind = 3;
        // i1 and !eco.value remain 0 (boxed slot).
        bitmap |= (static_cast<int64_t>(kind) << (2 * i));
    }
    return bitmap;
}

/// Cross-spec candidate metadata. Lifted to namespace scope so the
/// result-side eligibility check (which compares against other
/// candidates' shapes) can be a free function rather than a member.
struct Candidate {
    func::FuncOp func;
    /// Shapes as parsed from the attrs, before any per-iteration
    /// demotion. Re-evaluated each fixpoint pass.
    SmallVector<LogicalShape, 4> originalParamShapes;
    SmallVector<LogicalShape, 4> originalResultShapes;
    /// Final shapes once the candidate is committed as eligible.
    /// Read only after `eligible` flips true.
    SmallVector<LogicalShape, 4> paramShapes;
    SmallVector<LogicalShape, 4> resultShapes;
    SmallVector<int64_t, 4> resultCustomTags;
    /// Phase 3.3: per-result ABI decision parallel to `resultShapes`.
    /// `resultAbis[i] = Sret` ⇔ position i carries an `!eco.value`
    /// element and the worker takes a leading `!llvm.ptr` outparam
    /// in its place.
    SmallVector<ResultAbi, 4> resultAbis;
    bool eligible = false;
    std::string workerName;
};

/// Mirror of EcoTypeConverter's element rules: aggregate elements use
/// these LLVM-compatible types when stored to / loaded from an sret
/// slot. `!eco.value` lowers to `!llvm.ptr<addrspace=1>` (REP_LLVM_001).
static Type elementToLLVMTy(Type t, MLIRContext *ctx) {
    if (isa<eco::ValueType>(t))
        return LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
    // Primitives (i64/f64/i16/i1) already live in built-in dialects
    // that LLVM accepts directly.
    return t;
}

/// LLVM struct type matching an aggregate's element types, suitable
/// for use as the pointee of the sret slot. Every `!eco.value` element
/// maps to `!llvm.ptr<addrspace=1>` via `elementToLLVMTy` so the
/// struct contains only LLVM-compatible types.
static LLVM::LLVMStructType sretSlotStructTy(MLIRContext *ctx,
                                              ArrayRef<Type> elementTys) {
    SmallVector<Type, 4> llvmTys;
    llvmTys.reserve(elementTys.size());
    for (Type t : elementTys) llvmTys.push_back(elementToLLVMTy(t, ctx));
    return LLVM::LLVMStructType::getLiteral(ctx, llvmTys);
}

/// True if two aggregate shapes describe the same kind and element
/// types. Used to verify a producer's output shape matches the
/// expected result shape during result-side eligibility checking.
static bool aggregateShapesMatch(const LogicalShape &a,
                                 const LogicalShape &b) {
    if (a.kind != b.kind) return false;
    if (a.elementTys.size() != b.elementTys.size()) return false;
    for (unsigned i = 0; i < a.elementTys.size(); ++i)
        if (a.elementTys[i] != b.elementTys[i]) return false;
    // For Custom, the tag is structural — different tags = different
    // logical types even when fields align.
    if (a.kind == LogicalShape::Custom && a.customTag != b.customTag)
        return false;
    return true;
}

/// True iff the MLIR type `t` exactly matches the aggregate `shape`.
/// Used for `eco.from_heap` producers, which carry their aggregate
/// shape in the MLIR result type rather than via an attribute.
static bool mlirTypeMatchesShape(const LogicalShape &shape, Type t) {
    if (auto tup2 = dyn_cast<eco::Tuple2Type>(t)) {
        if (shape.kind != LogicalShape::Tuple2) return false;
        if (shape.elementTys.size() != 2) return false;
        return tup2.getFirst() == shape.elementTys[0] &&
               tup2.getSecond() == shape.elementTys[1];
    }
    if (auto tup3 = dyn_cast<eco::Tuple3Type>(t)) {
        if (shape.kind != LogicalShape::Tuple3) return false;
        if (shape.elementTys.size() != 3) return false;
        return tup3.getFirst() == shape.elementTys[0] &&
               tup3.getSecond() == shape.elementTys[1] &&
               tup3.getThird() == shape.elementTys[2];
    }
    if (auto rec = dyn_cast<eco::RecordType>(t)) {
        if (shape.kind != LogicalShape::Record) return false;
        if (shape.elementTys.size() != rec.getFields().size()) return false;
        for (unsigned i = 0; i < rec.getFields().size(); ++i)
            if (rec.getFields()[i] != shape.elementTys[i]) return false;
        return true;
    }
    if (auto cus = dyn_cast<eco::CustomType>(t)) {
        if (shape.kind != LogicalShape::Custom) return false;
        if (shape.elementTys.size() != cus.getFields().size()) return false;
        for (unsigned i = 0; i < cus.getFields().size(); ++i)
            if (cus.getFields()[i] != shape.elementTys[i]) return false;
        return true;
    }
    return false;
}

/// True iff every `func.return` in `func` has an aggregate-typed
/// producer at result position `resultPos` matching `expectedShape`.
/// Phase 3.1 relaxes the old construct-only rule (which Commit 4 had
/// in `resultPositionFedByConstruct`) so the call-result-passthrough,
/// param-passthrough, and from_heap cases the plan called out also
/// promote — every accepted producer kind either is or will be
/// aggregate-typed after cross-spec rewriting at that position.
///
/// Accepted producers:
///   - `eco.construct.{tuple2,tuple3,record,custom}` — rewritten to
///     the matching `eco.make.*` by `cloneAsWorker`.
///   - `BlockArgument` at param position p, where `ownParamShapes[p]`
///     is also being promoted to a shape matching `expectedShape` —
///     the entry-block arg gets retyped to the aggregate, so the
///     return operand follows.
///   - `eco.from_heap` whose MLIR result type already matches
///     `expectedShape`.
///   - `func.call` / `eco.call` to a name in `eligibleNames` whose
///     result at the call's result-index has a promoted shape matching
///     `expectedShape` — the call's symbol will be redirected to the
///     callee's `$unboxed` worker, which returns aggregate-typed.
/// Phase 3.4 #1 (commit 1): consolidated, recursion-capable producer
/// acceptance check. Returns true iff `v` is an SSA value whose
/// production matches `expectedShape` and which `cloneAsWorker` knows
/// how to rewrite — either by retyping a make.*/from_heap leaf, by
/// retyping a redirected call, or (commit 2+) by recursing through
/// `arith.select` / `eco.case` join points.
///
/// `depthBudget` bounds the recursive descent through join points;
/// 16 is enough for any realistic Elm pattern (joins rarely nest
/// past 3-4 levels) and protects against pathological inputs.
///
/// Commit 1 of Phase 3.4 keeps the historical leaf set unchanged
/// (block-arg, construct.*, from_heap, eligible/same-SCC call) so
/// behaviour is identical to pre-3.4. Subsequent commits will add
/// the join and loop-carry cases as additional branches here.
static bool isAcceptedAggregateProducer(
        Value v,
        const LogicalShape &expectedShape,
        ArrayRef<LogicalShape> ownParamShapes,
        const llvm::DenseMap<StringRef, Candidate> &candidates,
        const llvm::DenseSet<StringRef> &eligibleNames,
        const llvm::DenseSet<StringRef> *sccCallees,
        const llvm::DenseMap<StringRef, SmallVector<LogicalShape, 4>>
            *sccTentResults,
        unsigned depthBudget = 16) {
    if (depthBudget == 0) return false;

    // Block-arg passthrough: the entry-block arg at `paramIdx` becomes
    // the aggregate type after `cloneAsWorker` retypes it.
    if (auto barg = dyn_cast<BlockArgument>(v)) {
        unsigned paramIdx = barg.getArgNumber();
        if (paramIdx >= ownParamShapes.size()) return false;
        return aggregateShapesMatch(ownParamShapes[paramIdx], expectedShape);
    }

    Operation *def = v.getDefiningOp();
    if (!def) return false;

    // construct.* — rewritten to make.* during cloneAsWorker.
    if (isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp,
            eco::RecordConstructOp, eco::CustomConstructOp>(def)) {
        // For Custom, ensure the construct's tag matches the expected
        // shape (Elm typing guarantees this in practice, but verify
        // defensively).
        if (auto cus = dyn_cast<eco::CustomConstructOp>(def)) {
            if (expectedShape.kind == LogicalShape::Custom &&
                static_cast<int64_t>(cus.getTag()) !=
                    expectedShape.customTag) {
                return false;
            }
        }
        return true;
    }

    // eco.from_heap — already aggregate-typed; verify the shape.
    if (auto fh = dyn_cast<eco::FromHeapOp>(def)) {
        return mlirTypeMatchesShape(expectedShape,
                                     fh.getResult().getType());
    }

    auto matchEligibleCallee = [&](StringRef name, unsigned resultIdx) {
        if (name.empty() || !eligibleNames.contains(name)) return false;
        auto it = candidates.find(name);
        if (it == candidates.end()) return false;
        const auto &calleeResults = it->second.resultShapes;
        if (resultIdx >= calleeResults.size()) return false;
        if (!calleeResults[resultIdx].isAggregate()) return false;
        return aggregateShapesMatch(calleeResults[resultIdx], expectedShape);
    };
    // Phase 3.2 #1: same-SCC tentative-shape match.
    auto matchSameSCCCallee = [&](StringRef name, unsigned resultIdx) {
        if (!sccCallees || !sccCallees->contains(name)) return false;
        if (!sccTentResults) return false;
        auto it = sccTentResults->find(name);
        if (it == sccTentResults->end()) return false;
        if (resultIdx >= it->second.size()) return false;
        const LogicalShape &calleeSlot = it->second[resultIdx];
        return calleeSlot.isAggregate() &&
               aggregateShapesMatch(calleeSlot, expectedShape);
    };

    unsigned resultIdx = cast<OpResult>(v).getResultNumber();
    if (auto fc = dyn_cast<func::CallOp>(def)) {
        if (matchEligibleCallee(fc.getCallee(), resultIdx)) return true;
        if (matchSameSCCCallee(fc.getCallee(), resultIdx)) return true;
    }
    if (auto ec = dyn_cast<eco::CallOp>(def)) {
        if (auto sym = ec.getCalleeAttr()) {
            if (matchEligibleCallee(sym.getValue(), resultIdx)) return true;
            if (matchSameSCCCallee(sym.getValue(), resultIdx)) return true;
        }
    }

    // Phase 3.4 #1: join points. Recurse into both arms / every
    // alternative's matching eco.yield operand; all leaves must
    // themselves be accepted.
    if (auto sel = dyn_cast<arith::SelectOp>(def)) {
        return isAcceptedAggregateProducer(
                   sel.getTrueValue(), expectedShape, ownParamShapes,
                   candidates, eligibleNames, sccCallees, sccTentResults,
                   depthBudget - 1) &&
               isAcceptedAggregateProducer(
                   sel.getFalseValue(), expectedShape, ownParamShapes,
                   candidates, eligibleNames, sccCallees, sccTentResults,
                   depthBudget - 1);
    }
    // Phase 3.4 #1 (eco.case branch): temporarily disabled — see plan
    // §3.4 footnote. The retypeJoinTree rebuild interacts with Stage 7
    // self-compile in a way that surfaces an OOB on a function shape
    // not yet reproduced in a small fixture; keep the dialect widening
    // (Ops.td) in place so subsequent re-enable lands without further
    // dialect churn, but reject eco.case as a result producer for now.
    if (isa<eco::CaseOp>(def)) {
        return false;
    }
    return false;
}

static bool resultPositionHasAggregateProducer(
        func::FuncOp func,
        unsigned resultPos,
        const LogicalShape &expectedShape,
        ArrayRef<LogicalShape> ownParamShapes,
        const llvm::DenseMap<StringRef, Candidate> &candidates,
        const llvm::DenseSet<StringRef> &eligibleNames,
        const llvm::DenseSet<StringRef> *sccCallees = nullptr,
        const llvm::DenseMap<StringRef, SmallVector<LogicalShape, 4>>
            *sccTentResults = nullptr) {
    bool sawAnyReturn = false;
    bool ok = true;
    // Cross-spec runs before `eco.return` is lowered to `func.return`
    // (EcoToLLVMControlFlow), so Elm-generated bodies terminate with
    // `eco.return` rather than `func.return`. Walk both to handle the
    // hand-written codegen fixtures (func.return) and the Elm path
    // (eco.return).
    auto checkOperand = [&](Operation *r, ValueRange operands) {
        sawAnyReturn = true;
        if (resultPos >= operands.size()) { ok = false; return; }
        Value v = operands[resultPos];
        // Phase 3.4 #1: gate the eco.return walk on the result being
        // an all-primitive aggregate. The sret path was already firing
        // pre-3.4 only via func.return (hand-written fixtures); turning
        // it on for Elm bodies surfaces an existing FCA / RS4GC issue
        // with struct-of-`ptr addrspace(1)` values lingering in the
        // wrapper. Until that's fixed, restrict eco.return result-side
        // promotion to Direct-ABI candidates.
        if (isa<eco::ReturnOp>(r)) {
            bool allPrim = true;
            for (Type t : expectedShape.elementTys)
                if (isa<eco::ValueType>(t)) { allPrim = false; break; }
            if (!allPrim) { ok = false; return; }
        }
        if (!isAcceptedAggregateProducer(
                v, expectedShape, ownParamShapes, candidates,
                eligibleNames, sccCallees, sccTentResults))
            ok = false;
    };
    func.walk([&](func::ReturnOp r) { checkOperand(r, r.getOperands()); });
    func.walk([&](eco::ReturnOp r) { checkOperand(r, r.getOperands()); });
    return sawAnyReturn && ok;
}

/// True iff `user` is a self-recursive call to `selfName`. Both
/// `eco.call` and `func.call` are recognised; for `eco.call` the optional
/// `callee` attribute must be present and point to `selfName`.
static bool isSelfRecursiveCall(Operation *user, StringRef selfName) {
    if (auto fc = dyn_cast<func::CallOp>(user))
        return fc.getCallee() == selfName;
    if (auto ec = dyn_cast<eco::CallOp>(user)) {
        auto callee = ec.getCalleeAttr();
        return callee && callee.getValue() == selfName;
    }
    return false;
}

/// True iff every use of `arg` is either:
///   - a known projection op (which accepts both `!eco.value` and
///     aggregate operand kinds, per Phase 0 plumbing), OR
///   - a self-recursive `func.call` / `eco.call` to `selfName`, OR
///   - a `func.call` / `eco.call` to a name in `eligibleCallees`
///     (Phase 3.1 #5: fixpoint propagation lets aggregate flows
///     thread through chains of cross-spec-eligible workers without
///     a box/unbox round-trip), OR
///   - a `func.return` whose operand position has a logical result
///     shape matching the param's own aggregate shape (Phase 3.1
///     extension: block-arg passthrough — the arg flows directly to
///     the return and the function's result shape declares the same
///     aggregate, so promoting both sides keeps the return verifying).
/// Anything else (safepoint, papCreate, scf.while, non-eligible
/// callees, etc.) blocks specialisation.
///
/// Phase 3.2 #1 (SCC-aware mutual recursion) admits an additional
/// case: a `func.call` / `eco.call` to a member of `sccCallees` is
/// accepted iff that member's tentative param shape at the call's
/// operand position matches `paramShape`. Demotion in any member
/// propagates: once the callee's tentative slot falls to Boxed, the
/// caller's matching slot loses its only justification for that use
/// and demotes next iteration. The DAG-fixpoint case passes nullptr
/// for the SCC parameters and gets the original 3.1 behaviour.
static bool allUsesAreProjectionsOrCallsToEligible(
        BlockArgument arg,
        const LogicalShape &paramShape,
        StringRef selfName,
        const llvm::DenseSet<StringRef> &eligibleCallees,
        ArrayRef<LogicalShape> ownResultShapes,
        const llvm::DenseSet<StringRef> *sccCallees = nullptr,
        const llvm::DenseMap<StringRef, SmallVector<LogicalShape, 4>>
            *sccTentParams = nullptr) {
    auto sameSCCMatch = [&](StringRef calleeName, unsigned operandPos) {
        if (!sccCallees || !sccCallees->contains(calleeName)) return false;
        if (!sccTentParams) return false;
        auto it = sccTentParams->find(calleeName);
        if (it == sccTentParams->end()) return false;
        if (operandPos >= it->second.size()) return false;
        const LogicalShape &calleeSlot = it->second[operandPos];
        return calleeSlot.isAggregate() &&
               aggregateShapesMatch(calleeSlot, paramShape);
    };

    for (OpOperand &use : arg.getUses()) {
        Operation *user = use.getOwner();
        if (isa<eco::Tuple2ProjectOp,
                eco::Tuple3ProjectOp,
                eco::RecordProjectOp,
                eco::CustomProjectOp,
                eco::ListHeadOp,
                eco::ListTailOp>(user)) {
            if (use.getOperandNumber() != 0) return false;
            continue;
        }
        if (isSelfRecursiveCall(user, selfName)) continue;
        if (auto fc = dyn_cast<func::CallOp>(user)) {
            if (eligibleCallees.contains(fc.getCallee())) continue;
            if (sameSCCMatch(fc.getCallee(), use.getOperandNumber()))
                continue;
        }
        if (auto ec = dyn_cast<eco::CallOp>(user)) {
            auto callee = ec.getCalleeAttr();
            if (callee && eligibleCallees.contains(callee.getValue()))
                continue;
            if (callee &&
                sameSCCMatch(callee.getValue(), use.getOperandNumber()))
                continue;
        }
        // Passthrough-as-return: accept iff the return-position's
        // logical result shape matches the param shape. The matching
        // result-side check (block-arg producer) will independently
        // accept this same return only if the param is promoted — the
        // two checks converge consistently in the fixpoint.
        //
        // Symmetry with `resultPositionHasAggregateProducer`: for
        // `eco.return` (Elm bodies), the result-side check applies an
        // all-primitive gate that rejects aggregate shapes containing
        // any `!eco.value` element (the FCA/RS4GC sret limitation).
        // The param-side passthrough must apply the same gate — if it
        // didn't, param-side could promote while result-side demoted,
        // committing an asymmetric worker whose body returns an
        // aggregate-typed block-arg into an `!eco.value` result slot.
        if (isa<func::ReturnOp, eco::ReturnOp>(user)) {
            unsigned pos = use.getOperandNumber();
            if (pos < ownResultShapes.size() &&
                ownResultShapes[pos].isAggregate() &&
                aggregateShapesMatch(ownResultShapes[pos], paramShape)) {
                if (isa<eco::ReturnOp>(user)) {
                    bool allPrim = true;
                    for (Type t : ownResultShapes[pos].elementTys)
                        if (isa<eco::ValueType>(t)) {
                            allPrim = false; break;
                        }
                    if (!allPrim) return false;
                }
                continue;
            }
        }
        return false;
    }
    return true;
}

/// Build the worker function signature from the param + result shapes
/// and the per-result ABI decisions.
///
/// Layout:
///   inputs  = [sret-ptr0, sret-ptr1, ..., paramShape[0], paramShape[1], ...]
///   outputs = [orig-or-agg[i] for each i whose resultAbis[i] != Sret]
///
/// Phase 3.1 #4: aggregate-shaped results classified as Direct keep
/// the matching aggregate MLIR type on the LLVM return list (LLVM
/// packs multi-results into a struct — safe when no field is GC-
/// managed). Phase 3.3: results classified as Sret are removed from
/// outputs and replaced by a leading `!llvm.ptr` input, one per Sret
/// position, in source order. Boxed positions keep the original
/// (boxed) result type.
static FunctionType buildWorkerType(MLIRContext *ctx,
                                    ArrayRef<LogicalShape> paramShapes,
                                    ArrayRef<LogicalShape> resultShapes,
                                    ArrayRef<ResultAbi> resultAbis,
                                    ArrayRef<Type> originalResults) {
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    SmallVector<Type, 8> inputs;
    inputs.reserve(paramShapes.size() + resultAbis.size());
    for (unsigned i = 0; i < resultAbis.size(); ++i) {
        if (resultAbis[i] == ResultAbi::Sret) inputs.push_back(ptrTy);
    }
    for (const auto &s : paramShapes) inputs.push_back(s.asWorkerType(ctx));

    SmallVector<Type, 4> outputs;
    outputs.reserve(originalResults.size());
    for (unsigned i = 0; i < originalResults.size(); ++i) {
        ResultAbi abi = i < resultAbis.size() ? resultAbis[i]
                                              : ResultAbi::Boxed;
        if (abi == ResultAbi::Sret) continue;
        if (abi == ResultAbi::Direct &&
            i < resultShapes.size() && resultShapes[i].isAggregate())
            outputs.push_back(resultShapes[i].asWorkerType(ctx));
        else
            outputs.push_back(originalResults[i]);
    }
    return FunctionType::get(ctx, inputs, outputs);
}

/// Allocate an unused worker name based on `baseName`. Tries
/// `baseName$unboxed`, then `baseName$unboxed_0`, `baseName$unboxed_1`, ...
static std::string uniqueWorkerName(SymbolTable &symTable, StringRef baseName) {
    std::string candidate = (baseName + kUnboxedWorkerSuffix).str();
    if (!symTable.lookup(candidate)) return candidate;
    for (unsigned i = 0;; ++i) {
        std::string c = (baseName + kUnboxedWorkerSuffix + "_" +
                         llvm::Twine(i)).str();
        if (!symTable.lookup(c)) return c;
    }
}

/// Emit an `eco.project.*` op of the right kind for `aggTy`, then
/// optionally bridge `!eco.value` field types into `!llvm.ptr` via an
/// `unrealized_conversion_cast` so the field is storable to LLVM
/// memory. Used by the Phase 3.3 sret worker body rewriter.
static Value projectAndConvertField(OpBuilder &builder, Location loc,
                                     Value agg, Type aggTy,
                                     unsigned fieldIdx, Type elemTy) {
    auto idxAttr = builder.getI64IntegerAttr(static_cast<int64_t>(fieldIdx));
    Value projected;
    if (isa<eco::Tuple2Type>(aggTy)) {
        projected = builder.create<eco::Tuple2ProjectOp>(loc, elemTy, agg, idxAttr);
    } else if (isa<eco::Tuple3Type>(aggTy)) {
        projected = builder.create<eco::Tuple3ProjectOp>(loc, elemTy, agg, idxAttr);
    } else if (isa<eco::RecordType>(aggTy)) {
        projected = builder.create<eco::RecordProjectOp>(loc, elemTy, agg, idxAttr);
    } else if (isa<eco::CustomType>(aggTy)) {
        projected = builder.create<eco::CustomProjectOp>(loc, elemTy, agg, idxAttr);
    } else {
        llvm_unreachable("projectAndConvertField: unsupported aggregate type");
    }
    if (isa<eco::ValueType>(elemTy)) {
        Type ptrTy = LLVM::LLVMPointerType::get(
            builder.getContext(), /*addressSpace=*/1);
        return builder.create<UnrealizedConversionCastOp>(loc, ptrTy, projected)
            .getResult(0);
    }
    return projected;
}

/// Emit the per-field GEP+store sequence that writes `agg` into the
/// caller-allocated sret slot pointed to by `slot`. `slotStructTy` is
/// the LLVM struct type matching the aggregate's element layout (one
/// field per aggregate element, with `!eco.value` mapped to
/// `!llvm.ptr<addrspace=1>`). Inserts at the builder's current point.
static void emitSretStore(OpBuilder &builder, Location loc, Value slot,
                           LLVM::LLVMStructType slotStructTy, Value agg,
                           ArrayRef<Type> ecoElementTys) {
    auto *ctx = builder.getContext();
    auto i32Ty = IntegerType::get(ctx, 32);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    Type aggTy = agg.getType();
    for (unsigned k = 0; k < ecoElementTys.size(); ++k) {
        Value field = projectAndConvertField(builder, loc, agg, aggTy, k,
                                              ecoElementTys[k]);
        SmallVector<LLVM::GEPArg, 2> indices{
            LLVM::GEPArg(0), LLVM::GEPArg(static_cast<int32_t>(k))};
        auto fieldPtr = builder.create<LLVM::GEPOp>(
            loc, ptrTy, slotStructTy, slot, indices);
        builder.create<LLVM::StoreOp>(loc, field, fieldPtr);
        (void)i32Ty;
    }
}

/// Emit the per-field GEP+load sequence that reads an aggregate back
/// from a caller-allocated sret slot, producing one SSA value per
/// element. `!llvm.ptr<addrspace=1>` fields are converted back to
/// `!eco.value` via `unrealized_conversion_cast`. Returned values are
/// in element order, ready to feed `eco.make.*`.
static void emitSretLoad(OpBuilder &builder, Location loc, Value slot,
                          LLVM::LLVMStructType slotStructTy,
                          ArrayRef<Type> ecoElementTys,
                          SmallVectorImpl<Value> &fields) {
    auto *ctx = builder.getContext();
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    fields.clear();
    fields.reserve(ecoElementTys.size());
    for (unsigned k = 0; k < ecoElementTys.size(); ++k) {
        SmallVector<LLVM::GEPArg, 2> indices{
            LLVM::GEPArg(0), LLVM::GEPArg(static_cast<int32_t>(k))};
        auto fieldPtr = builder.create<LLVM::GEPOp>(
            loc, ptrTy, slotStructTy, slot, indices);
        Type loadTy = slotStructTy.getBody()[k];
        Value loaded = builder.create<LLVM::LoadOp>(loc, loadTy, fieldPtr);
        if (isa<eco::ValueType>(ecoElementTys[k])) {
            loaded = builder.create<UnrealizedConversionCastOp>(
                loc, ecoElementTys[k], loaded).getResult(0);
        }
        fields.push_back(loaded);
    }
}

/// Phase 3.4 #1: walk a return-reachable join chain top-down and
/// retype intermediate `arith.select` / `eco.case` results in place
/// while rewriting `construct.*` leaves to `make.*`. The chain has
/// already been validated by `isAcceptedAggregateProducer`, so each
/// path bottoms out at an accepted leaf (construct.* / from_heap /
/// eligible-call result / block-arg). Returns the new SSA value at
/// the chain root (which may be the original `v` if it was already
/// aggregate-typed, or a fresh make.* / retyped select / retyped
/// case result).
///
/// Forward declaration so `rewriteConstructToMake` (used inside) can
/// be defined immediately below.
static Value rewriteConstructToMake(OpBuilder &builder, Operation *constructOp);

static Value retypeJoinTree(Value v, Type aggTy) {
    // Already aggregate-typed: block-arg retyped by cloneAsWorker, or
    // call result already aggregate, or from_heap — leave alone.
    if (v.getType() == aggTy) return v;

    Operation *def = v.getDefiningOp();
    if (!def) return v;

    // construct.* → make.*: produce a fresh aggregate-typed value via
    // the existing rewriter, then return it.
    if (isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp,
            eco::RecordConstructOp, eco::CustomConstructOp>(def)) {
        OpBuilder b(def);
        return rewriteConstructToMake(b, def);
    }

    // arith.select: retype both arms recursively, then update the
    // select's operands and bump its result type in place.
    if (auto sel = dyn_cast<arith::SelectOp>(def)) {
        Value newT = retypeJoinTree(sel.getTrueValue(), aggTy);
        Value newF = retypeJoinTree(sel.getFalseValue(), aggTy);
        sel.getTrueValueMutable().assign(newT);
        sel.getFalseValueMutable().assign(newF);
        sel.getResult().setType(aggTy);
        return sel.getResult();
    }

    // eco.case: scalarise the aggregate-typed result by hoisting the
    // per-field projection out of every alternative. Each alternative
    // ends up yielding N scalars (one per aggregate element) instead
    // of one aggregate; we replace the case with a new one whose
    // result list is the N scalar types and build a single
    // `eco.make.*` after it to rebuild the aggregate.
    //
    // The SCF lowering (EcoControlFlowToSCFPass) maps eco.case →
    // scf.if/scf.index_switch and the EcoToLLVM conversion driver
    // can't keep aggregate Eco types consistent across the converted
    // region boundary. Hoisting the decomposition out at this stage
    // sidesteps that interaction — the case carries only LLVM-
    // compatible scalar types from here onward.
    if (auto caseOp = dyn_cast<eco::CaseOp>(def)) {
        // Single-result aggregate-typed case only; multi-result mixed
        // aggregate cases fall through (rare in practice).
        if (caseOp->getNumResults() != 1) return v;
        // Element types come from the aggregate destination type.
        SmallVector<Type, 4> elementTys;
        if (auto t2 = dyn_cast<eco::Tuple2Type>(aggTy)) {
            elementTys.push_back(t2.getFirst());
            elementTys.push_back(t2.getSecond());
        } else if (auto t3 = dyn_cast<eco::Tuple3Type>(aggTy)) {
            elementTys.push_back(t3.getFirst());
            elementTys.push_back(t3.getSecond());
            elementTys.push_back(t3.getThird());
        } else if (auto rec = dyn_cast<eco::RecordType>(aggTy)) {
            for (Type t : rec.getFields()) elementTys.push_back(t);
        } else if (auto cus = dyn_cast<eco::CustomType>(aggTy)) {
            for (Type t : cus.getFields()) elementTys.push_back(t);
        } else {
            return v;
        }

        // For each alternative: retype the yield operand to an
        // aggregate, then decompose into N scalar projections and
        // replace the yield.
        for (Region &alt : caseOp.getAlternatives()) {
            Block &block = alt.front();
            auto yieldOp = cast<eco::YieldOp>(block.getTerminator());
            Value yieldOperand = yieldOp.getValues()[0];
            Value newAggValue = retypeJoinTree(yieldOperand, aggTy);
            OpBuilder b(yieldOp);
            SmallVector<Value, 4> fields;
            for (unsigned k = 0; k < elementTys.size(); ++k) {
                auto idxAttr = b.getI64IntegerAttr(static_cast<int64_t>(k));
                Value f;
                if (isa<eco::Tuple2Type>(aggTy))
                    f = b.create<eco::Tuple2ProjectOp>(
                        yieldOp.getLoc(), elementTys[k], newAggValue, idxAttr);
                else if (isa<eco::Tuple3Type>(aggTy))
                    f = b.create<eco::Tuple3ProjectOp>(
                        yieldOp.getLoc(), elementTys[k], newAggValue, idxAttr);
                else if (isa<eco::RecordType>(aggTy))
                    f = b.create<eco::RecordProjectOp>(
                        yieldOp.getLoc(), elementTys[k], newAggValue, idxAttr);
                else if (isa<eco::CustomType>(aggTy))
                    f = b.create<eco::CustomProjectOp>(
                        yieldOp.getLoc(), elementTys[k], newAggValue, idxAttr);
                else
                    llvm_unreachable("aggTy unreachable");
                fields.push_back(f);
            }
            b.create<eco::YieldOp>(yieldOp.getLoc(), fields);
            yieldOp.erase();
        }

        // Build a new eco.case whose result list is the N scalars.
        OpBuilder b(caseOp);
        OperationState state(caseOp.getLoc(), eco::CaseOp::getOperationName());
        state.addOperands({caseOp.getScrutinee()});
        state.addTypes(elementTys);
        state.addAttribute(caseOp.getTagsAttrName(), caseOp.getTagsAttr());
        state.addAttribute(caseOp.getCaseKindAttrName(),
                           caseOp.getCaseKindAttr());
        if (caseOp.getStringPatternsAttr())
            state.addAttribute(caseOp.getStringPatternsAttrName(),
                               caseOp.getStringPatternsAttr());
        for (Region &alt : caseOp.getAlternatives()) {
            (void)alt;
            state.addRegion();
        }
        Operation *newOp = b.create(state);
        for (unsigned i = 0; i < caseOp.getAlternatives().size(); ++i)
            newOp->getRegion(i).takeBody(caseOp.getAlternatives()[i]);

        // Build the aggregate value outside the case by feeding the
        // scalar results into the matching eco.make.* op.
        OpBuilder afterCase(b.getInsertionBlock(), b.getInsertionPoint());
        Value rebuilt;
        if (isa<eco::Tuple2Type>(aggTy))
            rebuilt = afterCase.create<eco::Tuple2MakeOp>(
                caseOp.getLoc(), aggTy, newOp->getResult(0),
                newOp->getResult(1));
        else if (isa<eco::Tuple3Type>(aggTy))
            rebuilt = afterCase.create<eco::Tuple3MakeOp>(
                caseOp.getLoc(), aggTy, newOp->getResult(0),
                newOp->getResult(1), newOp->getResult(2));
        else if (isa<eco::RecordType>(aggTy))
            rebuilt = afterCase.create<eco::RecordMakeOp>(
                caseOp.getLoc(), aggTy,
                ValueRange(newOp->getResults()));
        else if (auto cusTy = dyn_cast<eco::CustomType>(aggTy))
            rebuilt = afterCase.create<eco::CustomMakeOp>(
                caseOp.getLoc(), aggTy, ValueRange(newOp->getResults()),
                afterCase.getI64IntegerAttr(0),
                /*constructor=*/StringAttr());
        else
            llvm_unreachable("aggTy not handled");

        caseOp->getResult(0).replaceAllUsesWith(rebuilt);
        caseOp.erase();
        return rebuilt;
    }

    // Accepted call result that was already retyped during the redirect
    // pass, or other shape that's already aggregate: nothing to do.
    return v;
}

/// Rewrite a return-feeding `eco.construct.*` op into the matching
/// `eco.make.*` op. Used by Phase 3.1 #4 result-side promotion: when a
/// worker function's result becomes an aggregate type, every construct
/// op producing a return operand at that position must be lifted to
/// its make.* counterpart so the return operand's SSA type lines up
/// with the new worker result type.
///
/// Returns the rewritten make op's result; the original construct op
/// is erased.
static Value rewriteConstructToMake(OpBuilder &builder, Operation *constructOp) {
    MLIRContext *ctx = constructOp->getContext();
    builder.setInsertionPoint(constructOp);

    Value rebuilt;
    if (auto t2 = dyn_cast<eco::Tuple2ConstructOp>(constructOp)) {
        Type aggTy = eco::Tuple2Type::get(
            ctx, t2.getA().getType(), t2.getB().getType());
        rebuilt = builder.create<eco::Tuple2MakeOp>(
            t2.getLoc(), aggTy, t2.getA(), t2.getB());
    } else if (auto t3 = dyn_cast<eco::Tuple3ConstructOp>(constructOp)) {
        Type aggTy = eco::Tuple3Type::get(
            ctx, t3.getA().getType(), t3.getB().getType(),
            t3.getC().getType());
        rebuilt = builder.create<eco::Tuple3MakeOp>(
            t3.getLoc(), aggTy, t3.getA(), t3.getB(), t3.getC());
    } else if (auto rec = dyn_cast<eco::RecordConstructOp>(constructOp)) {
        auto fields = rec.getFields();
        SmallVector<Type, 8> elementTypes;
        elementTypes.reserve(fields.size());
        for (Value f : fields) elementTypes.push_back(f.getType());
        Type aggTy = eco::RecordType::get(ctx, elementTypes);
        rebuilt = builder.create<eco::RecordMakeOp>(
            rec.getLoc(), aggTy, fields);
    } else if (auto cus = dyn_cast<eco::CustomConstructOp>(constructOp)) {
        auto fields = cus.getFields();
        SmallVector<Type, 8> elementTypes;
        elementTypes.reserve(fields.size());
        for (Value f : fields) elementTypes.push_back(f.getType());
        Type aggTy = eco::CustomType::get(ctx, elementTypes);
        rebuilt = builder.create<eco::CustomMakeOp>(
            cus.getLoc(), aggTy, fields,
            builder.getI64IntegerAttr(cus.getTag()),
            cus.getConstructorAttr());
    } else {
        llvm_unreachable("rewriteConstructToMake on unsupported op");
    }
    constructOp->getResult(0).replaceAllUsesWith(rebuilt);
    constructOp->erase();
    return rebuilt;
}

/// Per-callee redirect plan used during worker body rewriting.
/// `workerName` is the symbol of the callee's $unboxed worker; the
/// callee's per-param shapes drive operand bridging (`eco.from_heap`
/// where the operand is still `!eco.value` but the callee's worker
/// expects an aggregate).
///
/// Phase 3.3: `resultAbis[i]` tells the call-site rewriter which of
/// the callee's results come back via Sret slots. Each Sret position
/// in `sretElementTys` carries the slot's element types so the caller
/// can allocate a matching `!llvm.struct<>` slot and load the fields
/// after the call. `directResultTypes` is what the LLVM-level call
/// op returns (the Sret slice has been removed).
struct CalleeRedirect {
    StringRef workerName;
    SmallVector<LogicalShape, 4> paramShapes;
    SmallVector<LogicalShape, 4> resultShapes;
    SmallVector<ResultAbi, 4> resultAbis;
    SmallVector<SmallVector<Type, 4>, 4> sretElementTys;
    /// Result types of the worker call op after Sret outparams are
    /// removed — i.e. what `func::CallOp::getResults()` returns. One
    /// entry per non-Sret result, in source order.
    SmallVector<Type, 4> directResultTypes;
};

/// Clone `original` into a worker named `workerName` with the rewritten
/// `workerType`. Each aggregate-shaped param's entry-block arg type is
/// changed to the aggregate type. The body's `eco.project.*` users
/// automatically lower from the value-aggregate path (Phase 0 plumbing).
///
/// Result-side rewriting (Phase 3.1 #4): for each result position whose
/// worker type is aggregate, walk every `func.return` and rewrite the
/// construct op feeding that operand to the matching `eco.make.*`. The
/// return's SSA operand type then aligns with the worker signature.
///
/// Eligible-callee redirection (Phase 3.1 #5): for each `func.call` /
/// `eco.call` inside the worker body whose callee appears in
/// `redirects`, rewrite to `func.call @callee$unboxed(...)` with each
/// aggregate operand bridged via `eco.from_heap` as needed. Self-
/// recursion is handled as a special case where the callee's redirect
/// is the worker being constructed.
static func::FuncOp cloneAsWorker(OpBuilder &builder, func::FuncOp original,
                                  StringRef workerName, FunctionType workerType,
                                  ArrayRef<LogicalShape> paramShapes,
                                  ArrayRef<LogicalShape> resultShapes,
                                  ArrayRef<ResultAbi> resultAbis,
                                  const llvm::DenseMap<StringRef, CalleeRedirect>
                                      &redirects) {
    builder.setInsertionPointAfter(original);
    auto worker = builder.create<func::FuncOp>(
        original.getLoc(), workerName, workerType);
    worker.setVisibility(SymbolTable::Visibility::Private);
    worker->setAttr(kUnboxedWorkerAttr, builder.getUnitAttr());
    if (auto a = original->getAttrOfType<ArrayAttr>(kLogicalParamTypesAttr))
        worker->setAttr(kLogicalParamTypesAttr, a);
    if (auto a = original->getAttrOfType<ArrayAttr>(kLogicalResultTypesAttr))
        worker->setAttr(kLogicalResultTypesAttr, a);

    IRMapping mapper;
    original.getBody().cloneInto(&worker.getBody(), mapper);

    Block &entry = worker.getBody().front();
    MLIRContext *ctx = original.getContext();
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Phase 3.3: insert leading block args for sret slots, one per
    // Sret-classified result. Each slot is `!llvm.ptr` (addrspace 0;
    // host memory in the caller's frame). After insertion the original
    // param block-args shift right by `numSrets`, so the retype loop
    // below indexes them at `numSrets + i`.
    SmallVector<unsigned, 4> sretResultIndices;
    SmallVector<LLVM::LLVMStructType, 4> sretSlotTys;
    for (unsigned i = 0; i < resultAbis.size(); ++i) {
        if (resultAbis[i] != ResultAbi::Sret) continue;
        sretResultIndices.push_back(i);
        sretSlotTys.push_back(
            sretSlotStructTy(ctx, resultShapes[i].elementTys));
    }
    unsigned numSrets = sretResultIndices.size();
    SmallVector<BlockArgument, 4> sretSlotArgs;
    sretSlotArgs.reserve(numSrets);
    for (unsigned k = 0; k < numSrets; ++k) {
        sretSlotArgs.push_back(
            entry.insertArgument(k, ptrTy, worker.getLoc()));
    }

    for (unsigned i = 0; i < paramShapes.size(); ++i) {
        BlockArgument arg = entry.getArgument(numSrets + i);
        Type newTy = workerType.getInput(numSrets + i);
        if (arg.getType() != newTy) arg.setType(newTy);
    }

    // Rewrite call sites whose callee is an eligible cross-spec target
    // (self or any other function in `redirects`). For each operand at
    // an aggregate position whose value isn't already aggregate-typed,
    // insert `eco.from_heap` to bridge to the worker's signature. Use
    // `func.call` for the redirected site even when the original was
    // `eco.call`, because `eco.call`'s `Eco_AnyValue` operand constraint
    // rejects aggregate-typed values.
    StringRef origName = original.getName();
    auto bridgeOperands = [&](Location loc, OpBuilder &b,
                              const CalleeRedirect &redirect,
                              SmallVectorImpl<Value> &operands) {
        for (unsigned i = 0;
             i < redirect.paramShapes.size() && i < operands.size(); ++i) {
            if (!redirect.paramShapes[i].isAggregate()) continue;
            Type wantedTy =
                redirect.paramShapes[i].asWorkerType(operands[i].getContext());
            if (operands[i].getType() == wantedTy) continue;
            auto bridged = b.create<eco::FromHeapOp>(loc, wantedTy, operands[i]);
            operands[i] = bridged.getResult();
        }
    };

    SmallVector<std::pair<Operation *, StringRef>, 4> redirectedCalls;
    worker.walk([&](Operation *op) {
        StringRef name;
        if (auto fc = dyn_cast<func::CallOp>(op)) {
            name = fc.getCallee();
        } else if (auto ec = dyn_cast<eco::CallOp>(op)) {
            auto callee = ec.getCalleeAttr();
            if (callee) name = callee.getValue();
        }
        if (name.empty()) return;
        // Self-recursive: redirect to the worker we're building.
        // Other: look up in the prepared redirects map.
        if (name == origName) {
            redirectedCalls.push_back({op, name});
        } else if (redirects.contains(name)) {
            redirectedCalls.push_back({op, name});
        }
    });

    // Use a stable representation for the self redirect so we can share
    // the call-site rewrite loop with cross-function redirects.
    CalleeRedirect selfRedirect;
    selfRedirect.workerName = workerName;
    selfRedirect.paramShapes.assign(paramShapes.begin(), paramShapes.end());
    selfRedirect.resultShapes.assign(resultShapes.begin(), resultShapes.end());
    selfRedirect.resultAbis.assign(resultAbis.begin(), resultAbis.end());
    for (unsigned i = 0; i < resultAbis.size(); ++i) {
        if (resultAbis[i] == ResultAbi::Sret) {
            SmallVector<Type, 4> els(resultShapes[i].elementTys.begin(),
                                      resultShapes[i].elementTys.end());
            selfRedirect.sretElementTys.push_back(std::move(els));
        }
    }
    for (Type t : workerType.getResults())
        selfRedirect.directResultTypes.push_back(t);

    auto i64Ty = IntegerType::get(ctx, 64);
    for (auto &[callOp, name] : redirectedCalls) {
        const CalleeRedirect &redirect = (name == origName)
                                             ? selfRedirect
                                             : redirects.lookup(name);
        OpBuilder b(callOp);
        Location callLoc = callOp->getLoc();

        // Phase 3.3: allocate sret slots for each Sret-classified
        // result of the callee. Slots are stack-local to the calling
        // worker. They come first in the new operand list to match the
        // callee's worker signature.
        SmallVector<Value, 4> sretSlotVals;
        SmallVector<unsigned, 4> sretResultIdx;
        unsigned sretCounter = 0;
        for (unsigned i = 0; i < redirect.resultAbis.size(); ++i) {
            if (redirect.resultAbis[i] != ResultAbi::Sret) continue;
            auto slotStructTy =
                sretSlotStructTy(ctx, redirect.resultShapes[i].elementTys);
            auto one = b.create<LLVM::ConstantOp>(
                callLoc, i64Ty, b.getI64IntegerAttr(1));
            auto slot = b.create<LLVM::AllocaOp>(
                callLoc, ptrTy, slotStructTy, one);
            sretSlotVals.push_back(slot.getResult());
            sretResultIdx.push_back(i);
            (void)sretCounter;
        }

        SmallVector<Value, 4> operands;
        operands.reserve(sretSlotVals.size() + callOp->getNumOperands());
        for (Value s : sretSlotVals) operands.push_back(s);
        for (Value o : callOp->getOperands()) operands.push_back(o);

        bridgeOperands(callLoc, b, redirect, operands);
        auto fc = b.create<func::CallOp>(
            callLoc, redirect.workerName, redirect.directResultTypes,
            operands);

        // Replace each original result of `callOp` with either:
        //   - the corresponding new-call direct result (Direct/Boxed), or
        //   - a freshly-rebuilt aggregate loaded from the matching sret
        //     slot (Sret).
        SmallVector<Value, 4> replacements;
        replacements.reserve(callOp->getNumResults());
        unsigned directCursor = 0;
        unsigned sretCursor = 0;
        for (unsigned i = 0; i < callOp->getNumResults(); ++i) {
            ResultAbi abi = i < redirect.resultAbis.size()
                                ? redirect.resultAbis[i]
                                : ResultAbi::Boxed;
            if (abi != ResultAbi::Sret) {
                replacements.push_back(fc.getResult(directCursor++));
                continue;
            }
            const LogicalShape &rs = redirect.resultShapes[i];
            SmallVector<Value, 4> loadedFields;
            auto slotStructTy =
                sretSlotStructTy(ctx, rs.elementTys);
            emitSretLoad(b, callLoc, sretSlotVals[sretCursor],
                         slotStructTy, rs.elementTys, loadedFields);
            ++sretCursor;
            Value rebuilt;
            switch (rs.kind) {
            case LogicalShape::Tuple2:
                rebuilt = b.create<eco::Tuple2MakeOp>(
                    callLoc, rs.asWorkerType(ctx),
                    loadedFields[0], loadedFields[1]);
                break;
            case LogicalShape::Tuple3:
                rebuilt = b.create<eco::Tuple3MakeOp>(
                    callLoc, rs.asWorkerType(ctx),
                    loadedFields[0], loadedFields[1], loadedFields[2]);
                break;
            case LogicalShape::Record:
                rebuilt = b.create<eco::RecordMakeOp>(
                    callLoc, rs.asWorkerType(ctx), loadedFields);
                break;
            case LogicalShape::Custom:
                rebuilt = b.create<eco::CustomMakeOp>(
                    callLoc, rs.asWorkerType(ctx), loadedFields,
                    b.getI64IntegerAttr(rs.customTag),
                    /*constructor=*/StringAttr());
                break;
            default:
                llvm_unreachable("Sret on non-aggregate shape");
            }
            replacements.push_back(rebuilt);
            (void)sretResultIdx;
        }
        callOp->replaceAllUsesWith(replacements);
        callOp->erase();

        // Drop aggregate-typed replacements from any eco.safepoint operand
        // list they now appear in. The safepoint op accepts only
        // !eco.value (Variadic<Eco_Value>); the front-end emitted the
        // original boxed call result as a GC root, and replaceAllUsesWith
        // above silently rewired the use to the new aggregate-typed value.
        // Aggregate SSA values are not heap pointers — LLVM's
        // RewriteStatepointsForGC handles any ptr addrspace(1) fields they
        // contain at the LLVM level, so the eco-level safepoint must not
        // carry them.
        for (Value rep : replacements) {
            if (isa<eco::ValueType>(rep.getType())) continue;
            SmallVector<eco::SafepointOp, 2> sps;
            for (OpOperand &use : rep.getUses()) {
                if (auto sp = dyn_cast<eco::SafepointOp>(use.getOwner()))
                    sps.push_back(sp);
            }
            for (eco::SafepointOp sp : sps) {
                SmallVector<Value, 8> kept;
                for (Value v : sp.getLiveRoots())
                    if (isa<eco::ValueType>(v.getType()))
                        kept.push_back(v);
                sp.getLiveRootsMutable().clear();
                sp.getLiveRootsMutable().append(kept);
            }
        }
    }

    // Result-side rewriting: for each result position promoted to an
    // aggregate worker type, rewrite the feeding construct op into the
    // matching make.* and let the return operand's SSA type follow.
    bool anyResultPromoted = false;
    for (const auto &s : resultShapes) {
        if (s.isAggregate()) { anyResultPromoted = true; break; }
    }
    if (anyResultPromoted) {
        // Worker body was cloned from the original (Elm uses
        // `eco.return`; hand-written codegen fixtures may use
        // `func.return`). Walk both.
        SmallVector<Operation *, 4> returns;
        worker.walk([&](func::ReturnOp r) {
            returns.push_back(r.getOperation());
        });
        worker.walk([&](eco::ReturnOp r) {
            returns.push_back(r.getOperation());
        });
        for (Operation *ret : returns) {
            // First pass (Phase 3.4 #1 extension): walk the join tree
            // top-down from each aggregate-result operand, retyping
            // arith.select / eco.case results and rewriting construct.*
            // leaves to make.*. Straight-line construct→make stays a
            // degenerate single-step case of this walk.
            for (unsigned i = 0; i < resultShapes.size() &&
                                 i < ret->getNumOperands(); ++i) {
                if (!resultShapes[i].isAggregate()) continue;
                Value operand = ret->getOperand(i);
                Type aggTy = resultShapes[i].asWorkerType(
                    operand.getContext());
                Value rewritten = retypeJoinTree(operand, aggTy);
                if (rewritten != operand)
                    ret->getOpOperand(i).assign(rewritten);
            }

            // Phase 3.3 second pass: for each Sret result position,
            // store the aggregate into its slot via per-element GEP +
            // store and drop the operand from the new return list. The
            // stores happen immediately before the (rebuilt) return op
            // — naturally enforcing CGEN_067 (no statepoint between
            // store and return).
            if (numSrets == 0) continue;
            OpBuilder rb(ret);
            unsigned sretCursor = 0;
            SmallVector<Value, 4> newRetOperands;
            newRetOperands.reserve(ret->getNumOperands());
            for (unsigned i = 0; i < ret->getNumOperands(); ++i) {
                bool isSret = sretCursor < sretResultIndices.size() &&
                              sretResultIndices[sretCursor] == i;
                if (!isSret) {
                    newRetOperands.push_back(ret->getOperand(i));
                    continue;
                }
                Value slot = sretSlotArgs[sretCursor];
                LLVM::LLVMStructType slotStructTy = sretSlotTys[sretCursor];
                ArrayRef<Type> ecoEls = resultShapes[i].elementTys;
                emitSretStore(rb, ret->getLoc(), slot, slotStructTy,
                              ret->getOperand(i), ecoEls);
                ++sretCursor;
            }
            // Match the original return op's dialect when rebuilding so
            // we don't accidentally smuggle in a func.return where Elm
            // expected eco.return (the parent func body's terminator
            // expectation).
            if (isa<eco::ReturnOp>(ret))
                rb.create<eco::ReturnOp>(ret->getLoc(), newRetOperands);
            else
                rb.create<func::ReturnOp>(ret->getLoc(), newRetOperands);
            ret->erase();
        }
    }

    return worker;
}

/// Replace `original`'s body with a wrapper that:
///   - calls `eco.from_heap` on each `!eco.value` aggregate param,
///   - delegates to `worker` with the resulting aggregate operands,
///   - calls `eco.to_heap` on each aggregate-shaped worker result
///     (Phase 3.1 #4), populating the heap-layout attributes (tag,
///     unboxed_bitmap) the heap form needs.
///   - returns the (possibly re-boxed) values with the wrapper's
///     original ABI intact.
///
/// `customTagPerResult` carries the Custom constructor tag for each
/// promoted Custom result position; entries for non-Custom positions
/// (or non-promoted positions) are zero and ignored.
///
/// Phase 3.3: when a result position is Sret, the wrapper allocates an
/// `!llvm.struct<>` slot via `llvm.alloca`, prepends the slot pointer
/// to the worker's operand list, then reads the aggregate back from
/// the slot after the call via per-element GEP+load. Phase 3.4 Fix A:
/// the loaded scalar fields go directly into `eco.construct.*` for
/// re-boxing — no intermediate `eco.make.* + eco.to_heap` pair, no
/// register-form FCA in the wrapper. The Direct branch projects each
/// field out of the worker's by-value aggregate return via
/// `eco.project.*` and likewise re-boxes via `eco.construct.*`,
/// keeping the Sret and Direct paths symmetric.
static void replaceBodyWithWrapper(OpBuilder &builder, func::FuncOp original,
                                   func::FuncOp worker,
                                   ArrayRef<LogicalShape> paramShapes,
                                   ArrayRef<LogicalShape> resultShapes,
                                   ArrayRef<ResultAbi> resultAbis,
                                   ArrayRef<int64_t> customTagPerResult) {
    Region &body = original.getBody();
    body.getBlocks().clear();
    Block *entry = builder.createBlock(&body);
    for (Type t : original.getFunctionType().getInputs())
        entry->addArgument(t, original.getLoc());

    builder.setInsertionPointToStart(entry);

    MLIRContext *ctx = builder.getContext();
    Location loc = original.getLoc();
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Phase 3.3: allocate one sret slot per Sret-classified result.
    // Slots come first in the worker's operand list, matching the
    // worker signature emitted by buildWorkerType.
    SmallVector<Value, 4> sretSlots;
    SmallVector<unsigned, 4> sretResultIndices;
    SmallVector<LLVM::LLVMStructType, 4> sretSlotTys;
    for (unsigned i = 0; i < resultAbis.size(); ++i) {
        if (resultAbis[i] != ResultAbi::Sret) continue;
        sretResultIndices.push_back(i);
        auto slotStructTy = sretSlotStructTy(ctx, resultShapes[i].elementTys);
        sretSlotTys.push_back(slotStructTy);
        auto one = builder.create<LLVM::ConstantOp>(
            loc, i64Ty, builder.getI64IntegerAttr(1));
        auto slot = builder.create<LLVM::AllocaOp>(
            loc, ptrTy, slotStructTy, one);
        sretSlots.push_back(slot.getResult());
    }

    SmallVector<Value, 8> workerArgs;
    workerArgs.reserve(sretSlots.size() + entry->getNumArguments());
    for (Value slot : sretSlots) workerArgs.push_back(slot);

    for (unsigned i = 0; i < entry->getNumArguments(); ++i) {
        Value boxed = entry->getArgument(i);
        if (!paramShapes[i].isAggregate()) {
            workerArgs.push_back(boxed);
            continue;
        }
        Type aggTy = worker.getFunctionType().getInput(
            sretSlots.size() + i);
        auto unboxed = builder.create<eco::FromHeapOp>(loc, aggTy, boxed);
        workerArgs.push_back(unboxed.getResult());
    }

    auto callOp = builder.create<func::CallOp>(loc, worker, workerArgs);

    // Walk results in source order, pulling each value from either the
    // call op's direct results or from its sret slot. Direct (and the
    // pre-3.3 aggregate-by-value) path: take callOp.getResult(directCursor++).
    // Sret path: load fields from the matching slot, rebuild aggregate
    // via eco.make.* before re-boxing.
    SmallVector<Value, 4> returnValues;
    returnValues.reserve(resultShapes.size());
    unsigned directCursor = 0;
    unsigned sretCursor = 0;
    for (unsigned i = 0; i < resultShapes.size(); ++i) {
        const LogicalShape &rs = resultShapes[i];
        ResultAbi abi = i < resultAbis.size() ? resultAbis[i]
                                              : ResultAbi::Boxed;

        if (abi == ResultAbi::Sret) {
            // Load fields from the slot, rebuild aggregate, then
            // continue down the boxing path.
            SmallVector<Value, 4> loadedFields;
            emitSretLoad(builder, loc, sretSlots[sretCursor],
                         sretSlotTys[sretCursor], rs.elementTys,
                         loadedFields);
            ++sretCursor;
            Value rebuilt;
            switch (rs.kind) {
            case LogicalShape::Tuple2:
                rebuilt = builder.create<eco::Tuple2MakeOp>(
                    loc, rs.asWorkerType(ctx),
                    loadedFields[0], loadedFields[1]);
                break;
            case LogicalShape::Tuple3:
                rebuilt = builder.create<eco::Tuple3MakeOp>(
                    loc, rs.asWorkerType(ctx),
                    loadedFields[0], loadedFields[1], loadedFields[2]);
                break;
            case LogicalShape::Record:
                rebuilt = builder.create<eco::RecordMakeOp>(
                    loc, rs.asWorkerType(ctx), loadedFields);
                break;
            case LogicalShape::Custom: {
                int64_t tag = i < customTagPerResult.size()
                                  ? customTagPerResult[i] : 0;
                rebuilt = builder.create<eco::CustomMakeOp>(
                    loc, rs.asWorkerType(ctx), loadedFields,
                    builder.getI64IntegerAttr(tag),
                    /*constructor=*/StringAttr());
                break;
            }
            default:
                llvm_unreachable("Sret on non-aggregate shape");
            }
            Type boxedTy = original.getFunctionType().getResult(i);
            int64_t bitmap = computeUnboxedBitmap(rs.elementTys);
            int64_t customTag = (rs.kind == LogicalShape::Custom &&
                                  i < customTagPerResult.size())
                                     ? customTagPerResult[i] : 0;
            auto toHeap = builder.create<eco::ToHeapOp>(
                loc, boxedTy, rebuilt,
                /*live_roots=*/ValueRange{},
                /*unboxed_bitmap=*/builder.getI64IntegerAttr(bitmap),
                /*tag=*/builder.getI64IntegerAttr(customTag),
                /*head_kind=*/builder.getI64IntegerAttr(0),
                /*head_unboxed=*/builder.getBoolAttr(false));
            returnValues.push_back(toHeap.getResult());
            continue;
        }

        // Direct or Boxed path: pull from the call op's results.
        Value v = callOp.getResult(directCursor++);
        if (!rs.isAggregate()) {
            returnValues.push_back(v);
            continue;
        }

        Type boxedTy = original.getFunctionType().getResult(i);
        int64_t bitmap = computeUnboxedBitmap(rs.elementTys);
        int64_t tag = (rs.kind == LogicalShape::Custom &&
                       i < customTagPerResult.size())
                          ? customTagPerResult[i]
                          : 0;
        auto toHeap = builder.create<eco::ToHeapOp>(
            loc,
            boxedTy,
            v,
            /*live_roots=*/ValueRange{},
            /*unboxed_bitmap=*/builder.getI64IntegerAttr(bitmap),
            /*tag=*/builder.getI64IntegerAttr(tag),
            /*head_kind=*/builder.getI64IntegerAttr(0),
            /*head_unboxed=*/builder.getBoolAttr(false));
        returnValues.push_back(toHeap.getResult());
    }

    builder.create<func::ReturnOp>(loc, returnValues);
}

struct EcoUnboxedAggCrossSpecPass
    : public PassWrapper<EcoUnboxedAggCrossSpecPass, OperationPass<ModuleOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoUnboxedAggCrossSpecPass)

    StringRef getArgument() const override {
        return "eco-unboxed-agg-cross-spec";
    }
    StringRef getDescription() const override {
        return "Phase 3 cross-function specialisation: clone funcs with "
               "aggregate-shaped params/results into @f$unboxed workers and "
               "replace the original body with a from_heap/to_heap wrapper";
    }

    /// Classic Tarjan SCC over the call graph induced by `successors`.
    /// Returns a mapping from each function name to its SCC index;
    /// two functions share an index iff they're in the same SCC.
    /// O(V+E) — replaces the earlier O(V·(V+E)) per-function DFS so
    /// modules with many thousands of functions stay practical.
    ///
    /// Iterative implementation (no std::function recursion) so deeply
    /// nested call graphs don't overflow the C stack.
    static llvm::DenseMap<StringRef, unsigned> computeSCCs(
            const llvm::DenseMap<StringRef,
                                 llvm::SmallVector<StringRef, 4>> &successors) {
        struct NodeState { int index = -1, lowlink = -1; bool onStack = false; };
        llvm::DenseMap<StringRef, NodeState> state;
        llvm::SmallVector<StringRef, 32> tarStack;
        llvm::DenseMap<StringRef, unsigned> sccOf;
        int counter = 0;
        unsigned nextSCC = 0;

        // Per-frame work item: which node we're processing and which
        // successor edge we resume at after a recursive descent returns.
        struct Frame { StringRef v; unsigned nextSuccIdx; };

        // Snapshot every reachable node up-front so iteration order is
        // independent of DenseMap implementation details.
        llvm::SmallVector<StringRef, 32> nodes;
        for (auto &kv : successors) nodes.push_back(kv.first);

        for (StringRef root : nodes) {
            if (state[root].index != -1) continue;

            // Begin a fresh DFS rooted at `root`.
            llvm::SmallVector<Frame, 32> workStack;
            workStack.push_back({root, 0});
            state[root].index = state[root].lowlink = counter++;
            tarStack.push_back(root);
            state[root].onStack = true;

            while (!workStack.empty()) {
                Frame &top = workStack.back();
                auto it = successors.find(top.v);
                const auto &succs = (it != successors.end())
                                        ? it->second
                                        : llvm::SmallVector<StringRef, 4>{};

                bool descended = false;
                while (top.nextSuccIdx < succs.size()) {
                    StringRef w = succs[top.nextSuccIdx++];
                    NodeState &ws = state[w];
                    if (ws.index == -1) {
                        // Recurse into w.
                        ws.index = ws.lowlink = counter++;
                        tarStack.push_back(w);
                        ws.onStack = true;
                        workStack.push_back({w, 0});
                        descended = true;
                        break;
                    }
                    if (ws.onStack) {
                        state[top.v].lowlink =
                            std::min(state[top.v].lowlink, ws.index);
                    }
                }
                if (descended) continue;

                // Done with v's successors. Propagate lowlink to caller
                // (if any) and pop a fresh SCC if v is its root.
                StringRef v = top.v;
                NodeState &vs = state[v];
                if (vs.lowlink == vs.index) {
                    StringRef w;
                    do {
                        w = tarStack.pop_back_val();
                        state[w].onStack = false;
                        sccOf[w] = nextSCC;
                    } while (w != v);
                    ++nextSCC;
                }
                workStack.pop_back();
                if (!workStack.empty()) {
                    NodeState &caller = state[workStack.back().v];
                    caller.lowlink = std::min(caller.lowlink, vs.lowlink);
                }
            }
        }
        return sccOf;
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        SymbolTable symTable(module);
        OpBuilder builder(module.getContext());

        // Step 1: scan every func.func and collect candidate metadata.
        // The result-side filter is deferred to the fixpoint loop so
        // call-result-passthrough cases can become eligible as their
        // callees do.
        llvm::DenseMap<StringRef, Candidate> candidates;
        llvm::DenseMap<StringRef, llvm::SmallVector<StringRef, 4>> successors;
        module.walk([&](func::FuncOp func) {
            if (func.isExternal()) return;
            if (func->hasAttr(kUnboxedWorkerAttr)) return;
            SmallVector<LogicalShape, 4> paramShapes;
            SmallVector<LogicalShape, 4> resultShapes;
            if (!readLogicalShapes(func, paramShapes, resultShapes)) return;
            // Skip functions whose `eco.logical_param_types` attribute
            // count doesn't match the MLIR input count. The mismatch
            // arises for Elm-emitted anonymous lambdas with zero Elm-
            // level params: their MLIR signature carries closure-capture
            // context inputs the cross-spec rewrite has no model for.
            // Without this guard `replaceBodyWithWrapper`'s wrapper-arg
            // loop indexes `paramShapes` by [0, entry.numArgs) and OOBs.
            if (paramShapes.size() !=
                func.getFunctionType().getNumInputs()) return;

            // Phase 3.3: classify each aggregate result by ABI. Sret
            // is the path for aggregates with `!eco.value` elements
            // (avoids the FCA-with-gc-pointer return RS4GC rejects).
            // Direct keeps the existing LLVM multi-return path for
            // all-primitive aggregates. Boxed is the demoted fallback.
            //
            // The actual ABI is recorded on `Candidate::resultAbis` at
            // commit time so cloneAsWorker / replaceBodyWithWrapper can
            // light up the matching worker shape (sret outparam, direct
            // return, or boxed passthrough). No pre-emptive demotion
            // is applied here — Sret shapes stay aggregate and reach
            // the body rewriter.

            bool anyAggregateOnEitherSide =
                hasAggregateShape(paramShapes) || hasAggregateShape(resultShapes);
            if (!anyAggregateOnEitherSide) return;

            Candidate cand;
            cand.func = func;
            cand.originalParamShapes = paramShapes;
            cand.originalResultShapes = resultShapes;
            // `paramShapes` / `resultShapes` are populated when the
            // fixpoint commits the candidate as eligible.
            cand.resultCustomTags.assign(resultShapes.size(), 0);
            candidates.try_emplace(func.getName(), std::move(cand));

            // Record outgoing direct-call edges for the SCC check.
            llvm::SmallVector<StringRef, 4> outs;
            llvm::SmallDenseSet<StringRef, 4> seen;
            func.walk([&](Operation *op) {
                StringRef name;
                if (auto fc = dyn_cast<func::CallOp>(op))
                    name = fc.getCallee();
                else if (auto ec = dyn_cast<eco::CallOp>(op))
                    if (auto sym = ec.getCalleeAttr())
                        name = sym.getValue();
                if (!name.empty() && seen.insert(name).second)
                    outs.push_back(name);
            });
            successors[func.getName()] = std::move(outs);
        });

        // Step 2: disqualify any candidate inside an SCC of size > 1.
        // Self-recursion is a single-function SCC with a self-edge and
        // remains eligible (handled inside cloneAsWorker).
        llvm::DenseMap<StringRef, unsigned> sccOf = computeSCCs(successors);
        llvm::DenseMap<unsigned, unsigned> sccSize;
        for (auto &kv : sccOf) sccSize[kv.second]++;
        llvm::DenseSet<StringRef> sccDisqualified;
        for (auto &kv : candidates) {
            auto it = sccOf.find(kv.first);
            if (it != sccOf.end() && sccSize[it->second] > 1)
                sccDisqualified.insert(kv.first);
        }

        // Step 3: fixpoint over per-param AND per-result eligibility.
        // Both sides may grow eligible as more callees enter the set
        // (per-param: callee can be reached via an aggregate flow;
        // per-result: callee's promoted aggregate result can be
        // forwarded as our own return value).
        llvm::DenseSet<StringRef> eligibleNames;
        bool changed = true;
        while (changed) {
            changed = false;
            for (auto &kv : candidates) {
                StringRef name = kv.first;
                Candidate &cand = kv.second;
                if (cand.eligible) continue;
                if (sccDisqualified.contains(name)) continue;

                // Tentative param shapes: re-derive each iteration so
                // we never read a stale demotion from a prior iteration.
                SmallVector<LogicalShape, 4> tentativeParams =
                    cand.originalParamShapes;
                Block &entry = cand.func.getBody().front();
                bool anyAggregatePromoted = false;
                for (unsigned i = 0; i < tentativeParams.size(); ++i) {
                    if (!tentativeParams[i].isAggregate()) continue;
                    if (allUsesAreProjectionsOrCallsToEligible(
                            entry.getArgument(i), tentativeParams[i], name,
                            eligibleNames, cand.originalResultShapes)) {
                        anyAggregatePromoted = true;
                    } else {
                        tentativeParams[i].kind = LogicalShape::Boxed;
                        tentativeParams[i].elementTys.clear();
                    }
                }

                // Tentative result shapes: same re-derivation. The
                // per-result producer check sees the tentative params
                // (for block-arg passthrough) and the current eligible
                // set (for call-result passthrough).
                SmallVector<LogicalShape, 4> tentativeResults =
                    cand.originalResultShapes;
                SmallVector<int64_t, 4> tentativeCustomTags(
                    tentativeResults.size(), 0);
                bool anyResultPromoted = false;
                for (unsigned i = 0; i < tentativeResults.size(); ++i) {
                    if (!tentativeResults[i].isAggregate()) continue;
                    if (!resultPositionHasAggregateProducer(
                            cand.func, i, tentativeResults[i],
                            tentativeParams, candidates, eligibleNames)) {
                        tentativeResults[i].kind = LogicalShape::Boxed;
                        tentativeResults[i].elementTys.clear();
                        continue;
                    }
                    anyResultPromoted = true;
                    if (tentativeResults[i].kind == LogicalShape::Custom) {
                        // Tag is already on the shape (came from the
                        // attr); record it for the wrapper's to_heap.
                        tentativeCustomTags[i] = tentativeResults[i].customTag;
                    }
                }

                if (!anyAggregatePromoted && !anyResultPromoted) continue;
                cand.paramShapes = std::move(tentativeParams);
                cand.resultShapes = std::move(tentativeResults);
                cand.resultCustomTags = std::move(tentativeCustomTags);
                cand.resultAbis.clear();
                cand.resultAbis.reserve(cand.resultShapes.size());
                for (const auto &rs : cand.resultShapes)
                    cand.resultAbis.push_back(chooseResultAbi(rs));
                cand.eligible = true;
                eligibleNames.insert(name);
                changed = true;
            }
        }

        // Step 3b (Phase 3.2 #1): SCC-aware mutual recursion pass.
        // For each SCC of size > 1 that has at least one candidate,
        // run an inner fixpoint over the SCC's candidate members
        // admitting same-SCC calls with tentative-shape matching.
        // Members commit independently once tentative shapes settle.
        llvm::DenseMap<unsigned, llvm::SmallVector<StringRef, 4>> sccMembers;
        for (auto &kv : sccOf) sccMembers[kv.second].push_back(kv.first);
        for (auto &[idx, members] : sccMembers) {
            if (members.size() < 2) continue;

            // Keep only members that are themselves candidates — the
            // rest have nothing to specialise and don't participate.
            llvm::SmallVector<StringRef, 4> sccCandidates;
            for (StringRef m : members)
                if (candidates.count(m) && !candidates[m].eligible)
                    sccCandidates.push_back(m);
            if (sccCandidates.size() < 2) continue;
            llvm::DenseSet<StringRef> sccSet(sccCandidates.begin(),
                                              sccCandidates.end());

            // Initialise per-member tentative shapes from originals.
            llvm::DenseMap<StringRef, SmallVector<LogicalShape, 4>> tentParams;
            llvm::DenseMap<StringRef, SmallVector<LogicalShape, 4>> tentResults;
            for (StringRef m : sccCandidates) {
                tentParams[m] = candidates[m].originalParamShapes;
                tentResults[m] = candidates[m].originalResultShapes;
            }

            // Inner fixpoint — monotonically demote until stable.
            bool sccChanged = true;
            while (sccChanged) {
                sccChanged = false;
                for (StringRef m : sccCandidates) {
                    Candidate &cand = candidates[m];
                    Block &entry = cand.func.getBody().front();

                    auto &mp = tentParams[m];
                    auto &mr = tentResults[m];
                    for (unsigned i = 0; i < mp.size(); ++i) {
                        if (!mp[i].isAggregate()) continue;
                        if (!allUsesAreProjectionsOrCallsToEligible(
                                entry.getArgument(i), mp[i], m,
                                eligibleNames, mr,
                                &sccSet, &tentParams)) {
                            mp[i].kind = LogicalShape::Boxed;
                            mp[i].elementTys.clear();
                            sccChanged = true;
                        }
                    }
                    for (unsigned i = 0; i < mr.size(); ++i) {
                        if (!mr[i].isAggregate()) continue;
                        if (!resultPositionHasAggregateProducer(
                                cand.func, i, mr[i], mp, candidates,
                                eligibleNames, &sccSet, &tentResults)) {
                            mr[i].kind = LogicalShape::Boxed;
                            mr[i].elementTys.clear();
                            sccChanged = true;
                        }
                    }
                }
            }

            // Commit: each member with any surviving aggregate becomes
            // eligible. Custom tags for promoted result positions are
            // already on the tentative shapes (parsed from the attr).
            for (StringRef m : sccCandidates) {
                Candidate &cand = candidates[m];
                const auto &mp = tentParams[m];
                const auto &mr = tentResults[m];
                bool anyAgg = false;
                for (const auto &s : mp)
                    if (s.isAggregate()) { anyAgg = true; break; }
                for (const auto &s : mr)
                    if (s.isAggregate()) { anyAgg = true; break; }
                if (!anyAgg) continue;

                cand.paramShapes.assign(mp.begin(), mp.end());
                cand.resultShapes.assign(mr.begin(), mr.end());
                cand.resultCustomTags.assign(mr.size(), 0);
                for (unsigned i = 0; i < mr.size(); ++i)
                    if (mr[i].kind == LogicalShape::Custom)
                        cand.resultCustomTags[i] = mr[i].customTag;
                cand.resultAbis.clear();
                cand.resultAbis.reserve(cand.resultShapes.size());
                for (const auto &rs : cand.resultShapes)
                    cand.resultAbis.push_back(chooseResultAbi(rs));
                cand.eligible = true;
                eligibleNames.insert(m);
            }
        }

        // Step 4: allocate worker names. Done in a separate pass so
        // cross-references between eligible workers can be resolved.
        llvm::DenseMap<StringRef, CalleeRedirect> redirects;
        for (auto &kv : candidates) {
            if (!kv.second.eligible) continue;
            kv.second.workerName =
                uniqueWorkerName(symTable, kv.second.func.getName());
            CalleeRedirect r;
            r.workerName = kv.second.workerName;
            r.paramShapes = kv.second.paramShapes;
            r.resultShapes = kv.second.resultShapes;
            r.resultAbis = kv.second.resultAbis;
            for (unsigned i = 0; i < kv.second.resultAbis.size(); ++i) {
                if (kv.second.resultAbis[i] == ResultAbi::Sret) {
                    SmallVector<Type, 4> els(
                        kv.second.resultShapes[i].elementTys.begin(),
                        kv.second.resultShapes[i].elementTys.end());
                    r.sretElementTys.push_back(std::move(els));
                }
            }
            FunctionType wt = buildWorkerType(
                module.getContext(), kv.second.paramShapes,
                kv.second.resultShapes, kv.second.resultAbis,
                kv.second.func.getFunctionType().getResults());
            for (Type t : wt.getResults()) r.directResultTypes.push_back(t);
            redirects.try_emplace(kv.first, std::move(r));
        }

        // Step 5: apply the rewrite per eligible candidate. Clone the
        // worker (which uses `redirects` to redirect inter-worker
        // calls), then replace the original body with a wrapper.
        for (auto &kv : candidates) {
            if (!kv.second.eligible) continue;
            Candidate &cand = kv.second;
            FunctionType workerTy = buildWorkerType(
                module.getContext(), cand.paramShapes, cand.resultShapes,
                cand.resultAbis,
                cand.func.getFunctionType().getResults());
            func::FuncOp worker = cloneAsWorker(
                builder, cand.func, cand.workerName, workerTy,
                cand.paramShapes, cand.resultShapes, cand.resultAbis,
                redirects);
            symTable.insert(worker);
            replaceBodyWithWrapper(builder, cand.func, worker,
                                   cand.paramShapes, cand.resultShapes,
                                   cand.resultAbis,
                                   cand.resultCustomTags);
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoUnboxedAggCrossSpecPass() {
    return std::make_unique<EcoUnboxedAggCrossSpecPass>();
}
