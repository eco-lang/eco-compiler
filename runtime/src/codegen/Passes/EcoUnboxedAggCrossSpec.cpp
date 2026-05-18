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

#include "mlir/Dialect/Func/IR/FuncOps.h"
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

/// True if `t` is one of the unboxable primitive types (i64/f64/i16/i1).
static bool isPrimitiveElement(Type t) {
    return t.isInteger(64) || t.isF64() || t.isInteger(16) || t.isInteger(1);
}

/// True iff `shape` is an aggregate whose elements are all primitives.
/// Phase 3.1 #4 only promotes result aggregates that pass this check —
/// aggregate results carrying `!eco.value` elements stay boxed in 3.1
/// (deferred to 3.2 along with the sret/multi-return ABI question).
static bool isAllPrimitiveAggregate(const LogicalShape &shape) {
    if (!shape.isAggregate()) return false;
    for (Type t : shape.elementTys) {
        if (!isPrimitiveElement(t)) return false;
    }
    return true;
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

/// True iff every `func.return` in `func` has the operand at position
/// `i` produced by an `eco.construct.tuple2/3/record/custom`. Phase 3.1 #4
/// limits result-side promotion to this case so the worker body can
/// rewrite construct→make without needing to materialise an aggregate
/// out of thin air.
static bool resultPositionFedByConstruct(func::FuncOp func, unsigned i) {
    bool sawAnyReturn = false;
    bool ok = true;
    func.walk([&](func::ReturnOp r) {
        sawAnyReturn = true;
        if (i >= r.getNumOperands()) { ok = false; return; }
        Value v = r.getOperand(i);
        Operation *def = v.getDefiningOp();
        if (!def) { ok = false; return; }
        if (!isa<eco::Tuple2ConstructOp,
                 eco::Tuple3ConstructOp,
                 eco::RecordConstructOp,
                 eco::CustomConstructOp>(def))
            ok = false;
    });
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
///     a box/unbox round-trip).
/// Anything else (safepoint, papCreate, scf.while, return, non-self
/// non-eligible calls, etc.) blocks specialisation.
static bool allUsesAreProjectionsOrCallsToEligible(
        BlockArgument arg,
        StringRef selfName,
        const llvm::DenseSet<StringRef> &eligibleCallees) {
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
        // Otherwise, accept calls whose callee is known eligible.
        if (auto fc = dyn_cast<func::CallOp>(user)) {
            if (eligibleCallees.contains(fc.getCallee())) continue;
        }
        if (auto ec = dyn_cast<eco::CallOp>(user)) {
            auto callee = ec.getCalleeAttr();
            if (callee && eligibleCallees.contains(callee.getValue()))
                continue;
        }
        return false;
    }
    return true;
}

/// Build the worker function signature from the param + result shapes.
/// Phase 3.1 #4: aggregate-shaped results that survive the result-side
/// eligibility filter are rewritten to the matching aggregate MLIR type
/// (e.g. `!eco.value` → `!eco.tuple2<i64, i64>`). Result shapes already
/// demoted to Boxed by the caller stay at the original result type.
static FunctionType buildWorkerType(MLIRContext *ctx,
                                    ArrayRef<LogicalShape> paramShapes,
                                    ArrayRef<LogicalShape> resultShapes,
                                    ArrayRef<Type> originalResults) {
    SmallVector<Type, 8> inputs;
    inputs.reserve(paramShapes.size());
    for (const auto &s : paramShapes) inputs.push_back(s.asWorkerType(ctx));

    SmallVector<Type, 4> outputs;
    outputs.reserve(originalResults.size());
    for (unsigned i = 0; i < originalResults.size(); ++i) {
        if (i < resultShapes.size() && resultShapes[i].isAggregate())
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
struct CalleeRedirect {
    StringRef workerName;
    SmallVector<LogicalShape, 4> paramShapes;
    SmallVector<Type, 4> workerResultTypes;
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
    for (unsigned i = 0; i < paramShapes.size(); ++i) {
        BlockArgument arg = entry.getArgument(i);
        Type newTy = workerType.getInput(i);
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
    for (Type t : workerType.getResults())
        selfRedirect.workerResultTypes.push_back(t);

    for (auto &[callOp, name] : redirectedCalls) {
        const CalleeRedirect &redirect = (name == origName)
                                             ? selfRedirect
                                             : redirects.lookup(name);
        OpBuilder b(callOp);
        SmallVector<Value, 4> operands(callOp->getOperands().begin(),
                                       callOp->getOperands().end());
        bridgeOperands(callOp->getLoc(), b, redirect, operands);
        auto fc = b.create<func::CallOp>(callOp->getLoc(),
                                          redirect.workerName,
                                          redirect.workerResultTypes,
                                          operands);
        callOp->replaceAllUsesWith(fc.getResults());
        callOp->erase();
    }

    // Result-side rewriting: for each result position promoted to an
    // aggregate worker type, rewrite the feeding construct op into the
    // matching make.* and let the return operand's SSA type follow.
    bool anyResultPromoted = false;
    for (const auto &s : resultShapes) {
        if (s.isAggregate()) { anyResultPromoted = true; break; }
    }
    if (anyResultPromoted) {
        SmallVector<func::ReturnOp, 4> returns;
        worker.walk([&](func::ReturnOp r) { returns.push_back(r); });
        for (func::ReturnOp ret : returns) {
            for (unsigned i = 0; i < resultShapes.size() &&
                                 i < ret.getNumOperands(); ++i) {
                if (!resultShapes[i].isAggregate()) continue;
                Value operand = ret.getOperand(i);
                Operation *def = operand.getDefiningOp();
                if (!def) continue;
                if (!isa<eco::Tuple2ConstructOp, eco::Tuple3ConstructOp,
                         eco::RecordConstructOp, eco::CustomConstructOp>(def))
                    continue;
                OpBuilder b(def);
                rewriteConstructToMake(b, def);
            }
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
static void replaceBodyWithWrapper(OpBuilder &builder, func::FuncOp original,
                                   func::FuncOp worker,
                                   ArrayRef<LogicalShape> paramShapes,
                                   ArrayRef<LogicalShape> resultShapes,
                                   ArrayRef<int64_t> customTagPerResult) {
    Region &body = original.getBody();
    body.getBlocks().clear();
    Block *entry = builder.createBlock(&body);
    for (Type t : original.getFunctionType().getInputs())
        entry->addArgument(t, original.getLoc());

    builder.setInsertionPointToStart(entry);

    SmallVector<Value, 8> workerArgs;
    workerArgs.reserve(entry->getNumArguments());
    for (unsigned i = 0; i < entry->getNumArguments(); ++i) {
        Value boxed = entry->getArgument(i);
        if (!paramShapes[i].isAggregate()) {
            workerArgs.push_back(boxed);
            continue;
        }
        Type aggTy = worker.getFunctionType().getInput(i);
        auto unboxed = builder.create<eco::FromHeapOp>(
            original.getLoc(), aggTy, boxed);
        workerArgs.push_back(unboxed.getResult());
    }

    auto callOp = builder.create<func::CallOp>(
        original.getLoc(), worker, workerArgs);

    // Box each aggregate-shaped worker result via `eco.to_heap`,
    // populating the heap-layout attributes (tag for Custom, bitmap
    // for record/custom). GC roots are left to EcoGCPrepare, which
    // walks live_roots through the GCRootCarrier interface.
    SmallVector<Value, 4> returnValues;
    returnValues.reserve(callOp.getNumResults());
    for (unsigned i = 0; i < callOp.getNumResults(); ++i) {
        Value v = callOp.getResult(i);
        const LogicalShape &rs = i < resultShapes.size()
                                     ? resultShapes[i]
                                     : LogicalShape{};
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
            original.getLoc(),
            boxedTy,
            v,
            /*live_roots=*/ValueRange{},
            /*unboxed_bitmap=*/builder.getI64IntegerAttr(bitmap),
            /*tag=*/builder.getI64IntegerAttr(tag),
            /*head_kind=*/builder.getI64IntegerAttr(0),
            /*head_unboxed=*/builder.getBoolAttr(false));
        returnValues.push_back(toHeap.getResult());
    }

    builder.create<func::ReturnOp>(original.getLoc(), returnValues);
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

    /// Reachable-from-self check for SCC > 1 disqualification.
    /// Returns true iff there is a non-trivial cycle (length > 1)
    /// through `funcName` in the call graph induced by `successors`.
    /// Self-edges (length-1 cycles, i.e. direct recursion) are
    /// allowed and DO NOT count — the existing self-redirect logic
    /// handles them just fine.
    static bool isInNonTrivialSCC(
            StringRef funcName,
            const llvm::DenseMap<StringRef,
                                 llvm::SmallVector<StringRef, 4>> &successors) {
        llvm::SmallPtrSet<StringRef::const_iterator, 8> visitedKeys;
        llvm::SmallVector<StringRef, 8> stack;
        // Seed the DFS with `funcName`'s non-self successors so a
        // self-edge alone doesn't trigger the cycle.
        auto it = successors.find(funcName);
        if (it == successors.end()) return false;
        for (StringRef succ : it->second) {
            if (succ == funcName) continue;
            stack.push_back(succ);
        }
        llvm::SmallDenseSet<StringRef, 16> visited;
        while (!stack.empty()) {
            StringRef cur = stack.pop_back_val();
            if (cur == funcName) return true; // reached the start
            if (!visited.insert(cur).second) continue;
            auto succIt = successors.find(cur);
            if (succIt == successors.end()) continue;
            for (StringRef s : succIt->second) stack.push_back(s);
        }
        return false;
    }

    void runOnOperation() override {
        ModuleOp module = getOperation();
        SymbolTable symTable(module);
        OpBuilder builder(module.getContext());

        struct Candidate {
            func::FuncOp func;
            SmallVector<LogicalShape, 4> paramShapes;
            SmallVector<LogicalShape, 4> resultShapes;
            /// For each result position promoted to a Custom aggregate,
            /// the constructor tag harvested from the feeding construct
            /// op. Non-Custom positions and non-promoted positions get
            /// a sentinel zero.
            SmallVector<int64_t, 4> resultCustomTags;
            /// True once the fixpoint analysis settled on this function
            /// as cross-spec-eligible. Until then the per-param use
            /// check may have rejected it because aggregate flows pointed
            /// to candidates not yet known eligible.
            bool eligible = false;
            /// Allocated worker symbol (filled in during the apply phase).
            std::string workerName;
        };

        // Step 1: scan every func.func and collect candidate metadata.
        // We do the result-side filter here (it doesn't depend on
        // any callee analysis) but defer the per-param use check to
        // the fixpoint loop.
        llvm::DenseMap<StringRef, Candidate> candidates;
        llvm::DenseMap<StringRef, llvm::SmallVector<StringRef, 4>> successors;
        module.walk([&](func::FuncOp func) {
            if (func.isExternal()) return;
            if (func->hasAttr(kUnboxedWorkerAttr)) return;
            SmallVector<LogicalShape, 4> paramShapes;
            SmallVector<LogicalShape, 4> resultShapes;
            if (!readLogicalShapes(func, paramShapes, resultShapes)) return;

            // Per-result eligibility filter (Phase 3.1 #4): only promote
            // aggregate results when every element is primitive AND every
            // return op's operand at this position is produced by an
            // eco.construct.* op. Otherwise demote to Boxed.
            SmallVector<int64_t, 4> resultCustomTags(resultShapes.size(), 0);
            for (unsigned i = 0; i < resultShapes.size(); ++i) {
                if (!resultShapes[i].isAggregate()) continue;
                if (!isAllPrimitiveAggregate(resultShapes[i]) ||
                    !resultPositionFedByConstruct(func, i)) {
                    resultShapes[i].kind = LogicalShape::Boxed;
                    resultShapes[i].elementTys.clear();
                    continue;
                }
                if (resultShapes[i].kind == LogicalShape::Custom) {
                    func.walk([&](func::ReturnOp r) {
                        if (resultCustomTags[i] != 0 || i >= r.getNumOperands())
                            return;
                        if (auto cus = dyn_cast_or_null<eco::CustomConstructOp>(
                                r.getOperand(i).getDefiningOp()))
                            resultCustomTags[i] = cus.getTag();
                    });
                }
            }

            bool anyAggregateOnEitherSide =
                hasAggregateShape(paramShapes) || hasAggregateShape(resultShapes);
            if (!anyAggregateOnEitherSide) return;

            Candidate cand;
            cand.func = func;
            cand.paramShapes = std::move(paramShapes);
            cand.resultShapes = std::move(resultShapes);
            cand.resultCustomTags = std::move(resultCustomTags);
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
        // remains eligible (its handling is built into cloneAsWorker).
        llvm::DenseSet<StringRef> sccDisqualified;
        for (auto &kv : candidates) {
            if (isInNonTrivialSCC(kv.first, successors))
                sccDisqualified.insert(kv.first);
        }

        // Step 3: fixpoint over per-param use checks. A candidate is
        // eligible iff every aggregate param's uses are projections,
        // self-recursive calls, or calls to a callee already in the
        // eligible set. Iterate until no new function becomes eligible.
        llvm::DenseSet<StringRef> eligibleNames;
        bool changed = true;
        while (changed) {
            changed = false;
            for (auto &kv : candidates) {
                StringRef name = kv.first;
                Candidate &cand = kv.second;
                if (cand.eligible) continue;
                if (sccDisqualified.contains(name)) continue;

                // Run the per-param use check with the current
                // eligible set as the allowed callees.
                Block &entry = cand.func.getBody().front();
                SmallVector<LogicalShape, 4> testShapes = cand.paramShapes;
                bool anyAggregatePromoted = false;
                for (unsigned i = 0; i < testShapes.size(); ++i) {
                    if (!testShapes[i].isAggregate()) continue;
                    if (allUsesAreProjectionsOrCallsToEligible(
                            entry.getArgument(i), name, eligibleNames)) {
                        anyAggregatePromoted = true;
                    } else {
                        testShapes[i].kind = LogicalShape::Boxed;
                        testShapes[i].elementTys.clear();
                    }
                }
                bool anyResultPromoted = hasAggregateShape(cand.resultShapes);
                if (!anyAggregatePromoted && !anyResultPromoted) {
                    // Function has nothing to specialize — skip permanently.
                    continue;
                }
                cand.paramShapes = std::move(testShapes);
                cand.eligible = true;
                eligibleNames.insert(name);
                changed = true;
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
            FunctionType wt = buildWorkerType(
                module.getContext(), kv.second.paramShapes,
                kv.second.resultShapes,
                kv.second.func.getFunctionType().getResults());
            for (Type t : wt.getResults()) r.workerResultTypes.push_back(t);
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
                cand.func.getFunctionType().getResults());
            func::FuncOp worker = cloneAsWorker(
                builder, cand.func, cand.workerName, workerTy,
                cand.paramShapes, cand.resultShapes, redirects);
            symTable.insert(worker);
            replaceBodyWithWrapper(builder, cand.func, worker,
                                   cand.paramShapes, cand.resultShapes,
                                   cand.resultCustomTags);
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoUnboxedAggCrossSpecPass() {
    return std::make_unique<EcoUnboxedAggCrossSpecPass>();
}
