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
    enum Kind { Boxed, Primitive, Tuple2, Tuple3, Record };
    Kind kind = Boxed;
    /// For Primitive: the MLIR primitive type (i64/f64/i16/i1).
    /// For aggregates: empty.
    Type primitiveTy;
    /// For aggregates: the element types (in declared order).
    SmallVector<Type, 8> elementTys;

    bool isAggregate() const {
        return kind == Tuple2 || kind == Tuple3 || kind == Record;
    }

    /// Materialise the corresponding MLIR type used in the worker
    /// signature: aggregate types for aggregates, primitive types for
    /// primitives, `!eco.value` for everything else.
    Type asWorkerType(MLIRContext *ctx) const {
        switch (kind) {
        case Boxed:
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

/// True if `t` is one of the unboxable primitive types (i64/f64/i16/i1).
static bool isPrimitiveElement(Type t) {
    if (t.isInteger(64) || t.isF64() || t.isInteger(16) || t.isInteger(1))
        return true;
    return false;
}

/// True if at least one shape is an aggregate eligible for cross-spec.
/// v1 additionally requires every element of an aggregate to be a
/// primitive (i64/f64/i16): aggregates carrying `!eco.value` (= ptr
/// addrspace(1)) fields at the function boundary trip LLVM's
/// "FCA unimplemented" assertion in RewriteStatepointsForGC, and SROA
/// (which Phase 2 wires before RS4GC) can scalarise allocas but not
/// pass-by-value struct function parameters. All-primitive aggregates
/// are safe because the struct contains no GC pointers — RS4GC's
/// liveness scan never sees them as live-in GC values.
static bool hasAggregateShape(ArrayRef<LogicalShape> shapes) {
    for (const auto &s : shapes) {
        if (!s.isAggregate()) continue;
        bool allPrim = true;
        for (Type t : s.elementTys) {
            if (!isPrimitiveElement(t)) { allPrim = false; break; }
        }
        if (allPrim) return true;
    }
    return false;
}

/// Demote any aggregate shape whose elements aren't all primitives back
/// to Boxed so the worker signature stays GC-safe (FCA constraint).
static void demoteBoxedElementAggregates(SmallVectorImpl<LogicalShape> &shapes) {
    for (auto &s : shapes) {
        if (!s.isAggregate()) continue;
        for (Type t : s.elementTys) {
            if (!isPrimitiveElement(t)) {
                s.kind = LogicalShape::Boxed;
                s.elementTys.clear();
                break;
            }
        }
    }
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
///   - a self-recursive `func.call` / `eco.call` to `selfName` at any
///     position (so the call's operand at the aggregate position will
///     be rewritten when the callee is renamed to `@selfName$unboxed`).
/// Anything else (safepoint, papCreate, scf.while, return, non-self
/// calls, etc.) blocks specialisation.
static bool allUsesAreProjectionsOrSelfCalls(BlockArgument arg,
                                             StringRef selfName) {
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
        return false;
    }
    return true;
}

/// Build the worker function signature from the param shapes. v1 only
/// rewrites parameters; result types are kept identical to the original
/// function (Step 4 will rewrite results once construct ops in the body
/// are unboxed).
static FunctionType buildWorkerType(MLIRContext *ctx,
                                    ArrayRef<LogicalShape> paramShapes,
                                    ArrayRef<Type> originalResults) {
    SmallVector<Type, 8> inputs;
    inputs.reserve(paramShapes.size());
    for (const auto &s : paramShapes) inputs.push_back(s.asWorkerType(ctx));
    return FunctionType::get(ctx, inputs, originalResults);
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

/// Clone `original` into a worker named `workerName` with the rewritten
/// `workerType`. v1 only rewrites parameters: each aggregate-shaped
/// param's entry-block arg type is changed to the aggregate type. The
/// body's `eco.project.*` users automatically lower from the value-
/// aggregate path (Phase 0 plumbing) — no bridging op is inserted.
///
/// Recursion (Step 4): self-recursive call sites in the cloned body
/// have their callee symbol rewritten from `original.getName()` to
/// `workerName`. This avoids the round-trip box/unbox at every recursion
/// step. The retyped block arg's aggregate type already satisfies the
/// worker's signature for the recursive operand position.
static func::FuncOp cloneAsWorker(OpBuilder &builder, func::FuncOp original,
                                  StringRef workerName, FunctionType workerType,
                                  ArrayRef<LogicalShape> paramShapes) {
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

    // Rewrite self-recursive calls inside the cloned body to call the
    // worker. `eco.call` is converted to `func.call` for the recursive
    // site because the worker's signature carries aggregate types and
    // `eco.call`'s operand constraint (`Eco_AnyValue`) doesn't admit
    // aggregates. For each operand at an aggregate position whose value
    // isn't already aggregate-typed, insert `eco.from_heap` to bridge.
    StringRef origName = original.getName();
    auto bridgeOperands = [&](Location loc, OpBuilder &b,
                              SmallVectorImpl<Value> &operands) {
        for (unsigned i = 0; i < paramShapes.size() && i < operands.size(); ++i) {
            if (!paramShapes[i].isAggregate()) continue;
            Type wantedTy = workerType.getInput(i);
            if (operands[i].getType() == wantedTy) continue;
            auto bridged = b.create<eco::FromHeapOp>(loc, wantedTy, operands[i]);
            operands[i] = bridged.getResult();
        }
    };

    SmallVector<Operation *, 4> recursiveCalls;
    worker.walk([&](Operation *op) {
        if (auto fc = dyn_cast<func::CallOp>(op)) {
            if (fc.getCallee() == origName) recursiveCalls.push_back(op);
        } else if (auto ec = dyn_cast<eco::CallOp>(op)) {
            auto callee = ec.getCalleeAttr();
            if (callee && callee.getValue() == origName)
                recursiveCalls.push_back(op);
        }
    });

    for (Operation *callOp : recursiveCalls) {
        OpBuilder b(callOp);
        SmallVector<Value, 4> operands(callOp->getOperands().begin(),
                                       callOp->getOperands().end());
        bridgeOperands(callOp->getLoc(), b, operands);
        // Build a func.call to the worker with the (possibly bridged)
        // operands and worker result types; replace the original call.
        auto fc = b.create<func::CallOp>(callOp->getLoc(), workerName,
                                          workerType.getResults(), operands);
        callOp->replaceAllUsesWith(fc.getResults());
        callOp->erase();
    }

    return worker;
}

/// Replace `original`'s body with a wrapper that:
///   - calls `eco.from_heap` on each `!eco.value` aggregate param,
///   - delegates to `worker` with the resulting aggregate operands,
///   - returns the worker's result(s) directly (v1 keeps results boxed).
static void replaceBodyWithWrapper(OpBuilder &builder, func::FuncOp original,
                                   func::FuncOp worker,
                                   ArrayRef<LogicalShape> paramShapes) {
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

    builder.create<func::ReturnOp>(original.getLoc(), callOp.getResults());
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

    void runOnOperation() override {
        ModuleOp module = getOperation();
        SymbolTable symTable(module);
        OpBuilder builder(module.getContext());

        struct Candidate {
            func::FuncOp func;
            SmallVector<LogicalShape, 4> paramShapes;
        };
        SmallVector<Candidate, 16> candidates;

        module.walk([&](func::FuncOp func) {
            if (func.isExternal()) return;
            if (func->hasAttr(kUnboxedWorkerAttr)) return;
            SmallVector<LogicalShape, 4> paramShapes;
            SmallVector<LogicalShape, 4> resultShapes;
            if (!readLogicalShapes(func, paramShapes, resultShapes)) return;
            // FCA constraint: demote aggregates carrying !eco.value
            // elements (ptr addrspace(1)) before the worker signature is
            // built. Pass-by-value structs containing GC pointers trip
            // RewriteStatepointsForGC's "FCA unimplemented" assertion.
            demoteBoxedElementAggregates(paramShapes);
            if (!hasAggregateShape(paramShapes)) return;
            // Per-param use check: any aggregate param whose uses include
            // ops that strictly require `!eco.value` (safepoint, papCreate,
            // scf.while, return, etc.) is demoted back to Boxed for the
            // worker signature. v1 conservatively skips the function if
            // demotion eliminates all aggregate params, since adding a
            // worker that doesn't actually unbox any param is pure
            // overhead.
            Block &entry = func.getBody().front();
            bool anyAggregatePromoted = false;
            for (unsigned i = 0; i < paramShapes.size(); ++i) {
                if (!paramShapes[i].isAggregate()) continue;
                if (allUsesAreProjectionsOrSelfCalls(entry.getArgument(i),
                                                    func.getName())) {
                    anyAggregatePromoted = true;
                } else {
                    paramShapes[i].kind = LogicalShape::Boxed;
                    paramShapes[i].elementTys.clear();
                }
            }
            if (!anyAggregatePromoted) return;
            candidates.push_back({func, std::move(paramShapes)});
        });

        for (auto &cand : candidates) {
            FunctionType workerTy = buildWorkerType(
                module.getContext(), cand.paramShapes,
                cand.func.getFunctionType().getResults());
            std::string workerName =
                uniqueWorkerName(symTable, cand.func.getName());
            func::FuncOp worker = cloneAsWorker(
                builder, cand.func, workerName, workerTy, cand.paramShapes);
            symTable.insert(worker);
            replaceBodyWithWrapper(builder, cand.func, worker, cand.paramShapes);
        }
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoUnboxedAggCrossSpecPass() {
    return std::make_unique<EcoUnboxedAggCrossSpecPass>();
}
