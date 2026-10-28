// The hand-written parts of the Eco ops declared in `Ops.td`.
//
// The op classes are generated, and their declarations are in generated code, so each member function defined here
// carries its comment at its definition.

#include "EcoOps.h"

#include <cstdlib>
#include "EcoDialect.h"
#include "../allocator/Heap.hpp"  // NULL_CONS_MAX and the field and arity limits

#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "mlir/Interfaces/ControlFlowInterfaces.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;

//===----------------------------------------------------------------------===//
// SymbolUserOpInterface: verifySymbolUses
//===----------------------------------------------------------------------===//

/// Checks that `sym` names a symbol visible from `op`, and reports an error on `op` naming the symbol as a `desc`
/// if it does not. A null `sym` passes.
static LogicalResult verifySymRef(Operation *op, FlatSymbolRefAttr sym,
                                  SymbolTableCollection &symbolTable,
                                  StringRef desc) {
  if (!sym) return success();
  if (!symbolTable.lookupNearestSymbolFrom(op, sym))
    return op->emitOpError("references undefined ") << desc << " '" << sym.getValue() << "'";
  return success();
}

/// Checks a direct call's callee: it must exist, and when it is a `func.func` the call's operand and result types
/// must equal its signature exactly (CGEN_011). An indirect call passes. A callee already lowered to an `llvm.func`
/// is not compared.
LogicalResult CallOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  auto callee = getCalleeAttr();
  if (!callee)
    return success();
  if (failed(verifySymRef(*this, callee, symbolTable, "function")))
    return failure();
  // Unchecked, a mismatch would surface only as LLVM's "Calling a function with a bad signature!", or not at all.
  auto fn = symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, callee);
  if (!fn)
    return success();
  FunctionType fnTy = fn.getFunctionType();
  auto operandTypes = getOperands().getTypes();
  if (fnTy.getNumInputs() != operandTypes.size())
    return emitOpError("passes ") << operandTypes.size()
           << " operands but callee '" << callee.getValue() << "' takes "
           << fnTy.getNumInputs();
  for (auto [i, pair] : llvm::enumerate(llvm::zip(operandTypes, fnTy.getInputs())))
    if (std::get<0>(pair) != std::get<1>(pair))
      return emitOpError("operand ") << i << " has type " << std::get<0>(pair)
             << " but callee '" << callee.getValue() << "' expects "
             << std::get<1>(pair);
  auto resultTypes = getResultTypes();
  if (fnTy.getNumResults() != resultTypes.size())
    return emitOpError("has ") << resultTypes.size()
           << " results but callee '" << callee.getValue() << "' returns "
           << fnTy.getNumResults();
  for (auto [i, pair] : llvm::enumerate(llvm::zip(resultTypes, fnTy.getResults())))
    if (std::get<0>(pair) != std::get<1>(pair))
      return emitOpError("result ") << i << " has type " << std::get<0>(pair)
             << " but callee '" << callee.getValue() << "' returns "
             << std::get<1>(pair);
  return success();
}

/// Checks that the closure's function exists, and that a function named `Elm_Kernel_*` has a `func.func`
/// declaration in the module (CGEN_057).
LogicalResult PapCreateOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (failed(verifySymRef(*this, getFunctionAttr(), symbolTable, "function")))
    return failure();
  auto funcName = getFunctionAttr().getValue();
  if (funcName.starts_with("Elm_Kernel_")) {
    if (!symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, getFunctionAttr()))
      return emitOpError("kernel function '") << funcName
             << "' has no func.func declaration; compiler must emit one (CGEN_057)";
  }
  return success();
}

namespace {
/// Where a closure value came from: the `eco.papCreate` that made it, and how many of its evaluator's parameters
/// are already filled. `offset` counts the captures plus the arguments of every partial typed `eco.papExtend` between
/// that creation and the value.
struct PapOrigin {
  FlatSymbolRefAttr function;
  int64_t arity = 0;
  size_t offset = 0;
};
/// The outcome of tracing a closure value back to its creation.
///
/// `Found` means the origin was filled in. `Cycle` means the value reaches only itself, through block arguments that
/// add no arguments on the way, so it neither confirms nor contradicts an origin found by another path. `Unknown`
/// means no single origin could be established.
enum class TraceResult { Unknown, Found, Cycle };
} // namespace

/// Traces `clo` back through partial typed `eco.papExtend`s and through block arguments to the `eco.papCreate` that
/// made it, and on `Found` writes that creation and the filled-parameter count to `origin`. A block argument is
/// `Found` only when every incoming value that is not a cycle traces to the same function, arity and offset.
/// `visiting` holds the block arguments already entered, and is how a cycle is recognised.
static TraceResult traceClosureOrigin(Value clo, PapOrigin &origin,
                                      llvm::SmallPtrSetImpl<Value> &visiting);

/// Appends to `in` the values `arg` can receive: the matching operand of each `eco.jump` that targets its joinpoint,
/// when `arg` is a parameter of a joinpoint body, and otherwise the matching operand of each predecessor's branch.
///
/// Returns false, with `in` possibly part filled, when any incoming value cannot be named or there is none. That
/// includes an argument of an entry block outside a joinpoint, which is a function or region parameter, and any
/// block of a joinpoint other than its body's entry block.
static bool collectIncoming(BlockArgument arg, SmallVectorImpl<Value> &in) {
  Block *block = arg.getOwner();
  unsigned idx = arg.getArgNumber();
  Operation *parent = block->getParentOp();
  if (auto jp = dyn_cast_or_null<JoinpointOp>(parent)) {
    if (block != &jp.getBody().front())
      return false;
    uint64_t id = jp.getId();
    bool ok = true;
    // A jump targets the nearest enclosing joinpoint with its id, which is
    // `jp` unless another joinpoint with the same id lies in between.
    auto visit = [&](JumpOp jump) {
      if (jump.getTarget() != id)
        return WalkResult::advance();
      for (Operation *p = jump->getParentOp(); p && p != jp.getOperation();
           p = p->getParentOp())
        if (auto inner = dyn_cast<JoinpointOp>(p))
          if (inner.getId() == id)
            return WalkResult::advance();
      if (idx >= jump.getArgs().size()) {
        ok = false;
        return WalkResult::interrupt();
      }
      in.push_back(jump.getArgs()[idx]);
      return WalkResult::advance();
    };
    jp.getBody().walk(visit);
    if (ok)
      jp.getContinuation().walk(visit);
    return ok && !in.empty();
  }
  if (block->isEntryBlock())
    return false;  // a function parameter or a region argument
  for (auto it = block->pred_begin(), e = block->pred_end(); it != e; ++it) {
    auto br = dyn_cast<BranchOpInterface>((*it)->getTerminator());
    if (!br)
      return false;
    Value v = br.getSuccessorOperands(it.getSuccessorIndex())[idx];
    if (!v)
      return false;  // produced by the terminator itself
    in.push_back(v);
  }
  return !in.empty();
}

static TraceResult traceClosureOrigin(Value clo, PapOrigin &origin,
                                      llvm::SmallPtrSetImpl<Value> &visiting) {
  if (Operation *def = clo.getDefiningOp()) {
    if (auto c = dyn_cast<PapCreateOp>(def)) {
      origin = {c.getFunctionAttr(), static_cast<int64_t>(c.getArity()),
                static_cast<size_t>(c.getNumCaptured())};
      return TraceResult::Found;
    }
    auto prev = dyn_cast<PapExtendOp>(def);
    if (!prev || !prev.getRemainingArityAttr())
      return TraceResult::Unknown;
    size_t prevReal = prev.getNewargs().size();
    if (static_cast<int64_t>(prevReal) >= prev.getRemainingArityAttr().getInt())
      return TraceResult::Unknown;  // saturated: whatever the evaluator returned
    // A cycle through an extend adds newargs per round: unknown, not neutral.
    if (traceClosureOrigin(prev.getClosure(), origin, visiting) != TraceResult::Found)
      return TraceResult::Unknown;
    origin.offset += prevReal;
    return TraceResult::Found;
  }
  auto arg = cast<BlockArgument>(clo);
  if (!visiting.insert(clo).second)
    return TraceResult::Cycle;
  SmallVector<Value, 4> incoming;
  if (!collectIncoming(arg, incoming))
    return TraceResult::Unknown;
  bool found = false;
  for (Value v : incoming) {
    PapOrigin o;
    TraceResult r = traceClosureOrigin(v, o, visiting);
    if (r == TraceResult::Unknown)
      return TraceResult::Unknown;
    if (r == TraceResult::Cycle)
      continue;
    if (found && (o.function != origin.function || o.arity != origin.arity ||
                  o.offset != origin.offset))
      return TraceResult::Unknown;  // incoming values from different creations
    origin = o;
    found = true;
  }
  return found ? TraceResult::Found : TraceResult::Cycle;
}

/// Checks a `eco.papExtend` against the functions it names or reaches.
///
/// A `_fast_evaluator`, when present, must resolve. For a typed extend (one with `remaining_arity`), when the fast
/// evaluator is a `func.func`:
/// - the `_capture_abi` types must equal its leading parameter types (CGEN_CLOSURE_005);
/// - on a saturated extend, the new arguments must equal the parameters after those, and the result type its result
///   type when the arguments complete the signature (CGEN_003, CGEN_056).
///
/// Separately, when the closure traces to one `eco.papCreate` whose function is a `func.func` taking exactly `arity`
/// parameters, the new arguments must equal that function's parameters at the traced offset, and the result type
/// its result type when the extend is saturated and the arguments complete the signature. A generic extend, and a
/// closure whose origin cannot be traced, are not compared.
LogicalResult PapExtendOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (auto fast = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator"))
    if (failed(verifySymRef(*this, fast, symbolTable, "fast evaluator")))
      return failure();

  // The lowering loads one capture per `_capture_abi` entry at that type and calls the fast evaluator with the
  // captures followed by the new arguments, so a mismatch here would read a capture at the wrong kind.
  if (getRemainingArityAttr()) {
    auto fast = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator");
    auto captureAbi = getOperation()->getAttrOfType<ArrayAttr>("_capture_abi");
    if (fast && captureAbi) {
      if (auto clone = symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, fast)) {
        auto inputs = clone.getFunctionType().getInputs();
        if (captureAbi.size() > inputs.size())
          return emitOpError("CGEN_CLOSURE_005: _capture_abi has ")
                 << captureAbi.size() << " entries but fast evaluator '"
                 << fast.getValue() << "' has only " << inputs.size()
                 << " parameters";
        for (auto [i, attr] : llvm::enumerate(captureAbi)) {
          auto typeAttr = dyn_cast<TypeAttr>(attr);
          if (!typeAttr)
            return emitOpError("CGEN_CLOSURE_005: _capture_abi entry ")
                   << i << " is not a type: " << attr;
          if (typeAttr.getValue() != inputs[i])
            return emitOpError("CGEN_CLOSURE_005: _capture_abi entry ")
                   << i << " has type " << typeAttr.getValue()
                   << " but fast evaluator '" << fast.getValue()
                   << "' expects " << inputs[i] << " at parameter " << i;
        }
      }
    }
  }

  // The new arguments fill evaluator parameters, and a saturated extend may become a direct `eco.call` with these
  // operands, so their types must be the evaluator's parameter types.
  auto remainingArityAttr = getRemainingArityAttr();
  if (!remainingArityAttr)
    return success();
  auto newargs = getNewargs();
  const bool saturated =
      static_cast<int64_t>(newargs.size()) == remainingArityAttr.getInt();
  Type resultType = getResult().getType();

  auto checkAgainst = [&](func::FuncOp callee, StringRef role, size_t offset,
                          bool appliesAll) -> LogicalResult {
    auto inputs = callee.getFunctionType().getInputs();
    for (size_t i = 0; i < newargs.size() && offset + i < inputs.size(); ++i) {
      Type actual = newargs[i].getType();
      Type expected = inputs[offset + i];
      if (actual != expected)
        return emitOpError("CGEN_003: typed papExtend newarg ")
               << i << " has type " << actual << " but " << role << " '"
               << callee.getSymName() << "' expects " << expected
               << " at parameter " << (offset + i)
               << " (box/unbox the arg to the callee's param ABI)";
    }
    auto results = callee.getFunctionType().getResults();
    if (appliesAll && results.size() == 1 && results[0] != resultType)
      return emitOpError("CGEN_056: saturated typed papExtend result type ")
             << resultType << " does not match " << role << " '"
             << callee.getSymName() << "' result type " << results[0];
    return success();
  };

  auto fast = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator");
  auto captureAbi = getOperation()->getAttrOfType<ArrayAttr>("_capture_abi");
  if (saturated && fast && captureAbi) {
    if (auto clone = symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, fast)) {
      size_t nInputs = clone.getFunctionType().getNumInputs();
      if (failed(checkAgainst(clone, "fast evaluator", captureAbi.size(),
                              captureAbi.size() + newargs.size() == nInputs)))
        return failure();
    }
  }

  PapOrigin origin;
  llvm::SmallPtrSet<Value, 8> visiting;
  if (traceClosureOrigin(getClosure(), origin, visiting) != TraceResult::Found)
    return success();
  // The evaluator takes the captures followed by the remaining parameters.
  auto callee = symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, origin.function);
  if (!callee)
    return success();
  size_t nInputs = callee.getFunctionType().getNumInputs();
  if (static_cast<int64_t>(nInputs) != origin.arity)
    return success();  // not a captures+params evaluator layout
  return checkAgainst(callee, "evaluator", origin.offset,
                      saturated && origin.offset + newargs.size() == nInputs);
}

/// Checks that every entry of `functions` is a symbol reference to an existing symbol, and that one named
/// `Elm_Kernel_*` has a `func.func` declaration (CGEN_057).
LogicalResult PapCreateGroupOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  auto funcs = getFunctions();
  for (Attribute a : funcs) {
    auto sym = dyn_cast<FlatSymbolRefAttr>(a);
    if (!sym)
      return emitOpError("functions attribute must contain FlatSymbolRefAttr entries");
    if (failed(verifySymRef(*this, sym, symbolTable, "sibling function")))
      return failure();
    auto fn = sym.getValue();
    if (fn.starts_with("Elm_Kernel_")) {
      if (!symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, sym))
        return emitOpError("kernel function '") << fn
               << "' has no func.func declaration; compiler must emit one (CGEN_057)";
    }
  }
  // `fast_evaluators` needs no lookup of its own: `PapCreateGroupOp::verify` requires it to equal `functions`.
  return success();
}

/// Checks that the closure's function exists.
LogicalResult AllocateClosureOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getFunctionAttr(), symbolTable, "function");
}

/// Checks that the closure's function exists, and that a function named `Elm_Kernel_*` has a `func.func`
/// declaration (CGEN_057).
LogicalResult MakeClosureOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (failed(verifySymRef(*this, getFunctionAttr(), symbolTable, "function")))
    return failure();
  auto funcName = getFunctionAttr().getValue();
  if (funcName.starts_with("Elm_Kernel_")) {
    if (!symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, getFunctionAttr()))
      return emitOpError("kernel function '") << funcName
             << "' has no func.func declaration; compiler must emit one (CGEN_057)";
  }
  return success();
}

/// Checks that the global's initializer, if it names one, exists.
LogicalResult GlobalOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (auto init = getInitializerAttr())
    return verifySymRef(*this, init, symbolTable, "initializer");
  return success();
}

/// Checks that the global being read exists.
LogicalResult LoadGlobalOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getGlobalAttr(), symbolTable, "global");
}

/// Checks that the global being written exists.
LogicalResult StoreGlobalOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getGlobalAttr(), symbolTable, "global");
}

//===----------------------------------------------------------------------===//
// Operation Verifiers
//===----------------------------------------------------------------------===//

/// Checks an `eco.case`.
///
/// There is one alternative per tag. `case_kind` is present and agrees with the scrutinee type: `ctor` or `str` for
/// `!eco.value`, `bool` or `ctor` for `i1` (whose tags must be 0 or 1), `int` for `i64`, and `chr` for `i32`; no
/// other scrutinee type is accepted. A `str` case has one string pattern per alternative except the last, which is
/// the default. The case has at least one result (CGEN_010), and each alternative is one block ending in
/// `eco.yield` whose operand types equal the result types (CGEN_028).
///
/// With the environment variable `ECO_LAX_CASE_VERIFY` set to any value, a yield type mismatch is a warning instead
/// of an error, so that invalid IR can still be printed for diagnosis.
LogicalResult CaseOp::verify() {
  if (getTags().size() != getAlternatives().size()) {
    return emitOpError("number of tags (")
           << getTags().size()
           << ") must match number of alternative regions ("
           << getAlternatives().size() << ")";
  }

  auto caseKindAttr = getCaseKindAttr();
  if (!caseKindAttr) {
    return emitOpError("requires 'case_kind' attribute");
  }
  StringRef caseKind = caseKindAttr.getValue();

  if (caseKind != "ctor" && caseKind != "int" &&
      caseKind != "chr" && caseKind != "str" && caseKind != "bool") {
    return emitOpError("invalid case_kind '") << caseKind
           << "'; expected one of 'ctor', 'int', 'chr', 'str', 'bool'";
  }

  Type scrutineeType = getScrutinee().getType();

  if (isa<eco::ValueType>(scrutineeType)) {
    if (caseKind != "ctor" && caseKind != "str") {
      return emitOpError("!eco.value scrutinee requires case_kind 'ctor' or 'str', got '")
             << caseKind << "'";
    }
  } else if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
    unsigned width = intType.getWidth();

    if (width == 1) {
      if (caseKind != "bool" && caseKind != "ctor") {
        return emitOpError("i1 scrutinee requires case_kind 'bool' or 'ctor', got '")
               << caseKind << "'";
      }
      for (int64_t tag : getTags()) {
        if (tag != 0 && tag != 1) {
          return emitOpError("i1 scrutinee requires tags in {0, 1}, got ")
                 << tag;
        }
      }
    } else if (width == 64) {
      if (caseKind != "int") {
        return emitOpError("i64 scrutinee requires case_kind 'int', got '")
               << caseKind << "'";
      }
    } else if (width == eco::kEcoCharBits) {
      if (caseKind != "chr") {
        return emitOpError("i32 (Char) scrutinee requires case_kind 'chr', got '")
               << caseKind << "'";
      }
    } else {
      return emitOpError("scrutinee must be !eco.value, i1, i32 (Char), or i64, got ")
             << scrutineeType;
    }
  } else {
    return emitOpError("scrutinee must be !eco.value, i1, i32 (Char), or i64, got ")
           << scrutineeType;
  }

  if (caseKind == "str") {
    auto patternsAttr = getStringPatternsAttr();
    if (!patternsAttr) {
      return emitOpError("case_kind 'str' requires 'string_patterns' attribute");
    }

    size_t numAlts = getAlternatives().size();
    size_t numPatterns = patternsAttr.size();

    if (numPatterns + 1 != numAlts) {
      return emitOpError("string_patterns has ")
             << numPatterns << " elements but expected " << (numAlts - 1)
             << " (one per non-default alternative)";
    }

    for (Attribute attr : patternsAttr) {
      if (!isa<StringAttr>(attr)) {
        return emitOpError("string_patterns must contain only string attributes");
      }
    }
  }

  auto resultTypes = getResultTypes();
  if (resultTypes.empty()) {
    return emitOpError("must have at least one result type; void cases are not supported");
  }

  size_t altIndex = 0;
  for (auto &region : getAlternatives()) {
    if (region.empty()) {
      return emitOpError("alternative region must not be empty");
    }
    if (!region.hasOneBlock()) {
      return emitOpError("alternative region must have exactly one block");
    }
    Block &block = region.front();
    if (block.empty()) {
      return emitOpError("alternative block must not be empty");
    }
    Operation *terminator = block.getTerminator();
    if (!terminator) {
      return emitOpError("alternative block must have a terminator");
    }

    if (!isa<YieldOp>(terminator)) {
      return emitOpError("alternative ")
             << altIndex << " must terminate with 'eco.yield', got '"
             << terminator->getName() << "'";
    }

    auto yieldOp = cast<YieldOp>(terminator);
    auto yieldTypes = yieldOp.getOperandTypes();
    if (yieldTypes.size() != resultTypes.size()) {
      return emitOpError("alternative ")
             << altIndex << " eco.yield has " << yieldTypes.size()
             << " operands but eco.case has " << resultTypes.size() << " results";
    }
    for (size_t i = 0; i < resultTypes.size(); ++i) {
      if (yieldTypes[i] != resultTypes[i]) {
        if (::getenv("ECO_LAX_CASE_VERIFY")) {
          mlir::emitWarning(getLoc())
              << "LAX: alternative " << altIndex << " eco.yield operand " << i
              << " has type " << yieldTypes[i] << " but eco.case result " << i
              << " has type " << resultTypes[i];
          continue;
        }
        return emitOpError("alternative ")
               << altIndex << " eco.yield operand " << i
               << " has type " << yieldTypes[i]
               << " but eco.case result " << i << " has type " << resultTypes[i];
      }
    }

    ++altIndex;
  }

  return success();
}

/// Checks that an `eco.yield` is inside an `eco.case` (CGEN_053) and that its operand types equal that case's result
/// types. `ECO_LAX_CASE_VERIFY` turns a type mismatch into a warning, as for `CaseOp::verify`.
LogicalResult YieldOp::verify() {
  // The `HasParent` trait in `Ops.td` already requires the direct parent to be an `eco.case`.
  auto parentCaseOp = (*this)->getParentOfType<CaseOp>();
  if (!parentCaseOp) {
    return emitOpError("must be inside an eco.case alternative region");
  }

  auto caseResultTypes = parentCaseOp.getResultTypes();
  auto yieldTypes = getOperandTypes();

  if (yieldTypes.size() != caseResultTypes.size()) {
    return emitOpError("has ") << yieldTypes.size()
           << " operands but parent eco.case has "
           << caseResultTypes.size() << " results";
  }

  for (size_t i = 0; i < caseResultTypes.size(); ++i) {
    if (yieldTypes[i] != caseResultTypes[i]) {
      if (::getenv("ECO_LAX_CASE_VERIFY")) {
        mlir::emitWarning(getLoc())
            << "LAX: operand " << i << " has type " << yieldTypes[i]
            << " but parent eco.case result " << i << " has type "
            << caseResultTypes[i];
        continue;
      }
      return emitOpError("operand ") << i << " has type " << yieldTypes[i]
             << " but parent eco.case result " << i
             << " has type " << caseResultTypes[i];
    }
  }

  return success();
}


/// Checks that a joinpoint's body region is not empty. Uniqueness of joinpoint ids (CGEN_031) is not checked here.
LogicalResult JoinpointOp::verify() {
  if (getBody().empty()) {
    return emitOpError("body region must not be empty");
  }
  return success();
}

/// Checks that a null-cons constant's tag fits the 10-bit constructor index of a null-cons word, 0 to
/// `NULL_CONS_MAX` (HEAP_044).
LogicalResult ConstantNullConsOp::verify() {
  if (getTag() < 0 || getTag() > static_cast<int64_t>(NULL_CONS_MAX)) {
    return emitOpError("null-cons tag ")
           << getTag() << " outside the 10-bit null_cons_idx range [0, "
           << NULL_CONS_MAX << "] (HEAP_044)";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// Custom/Record slot kinds
//===----------------------------------------------------------------------===//

/// Rejects `op` if it carries `unboxed_bitmap`, `newargs_unboxed_bitmap` or `unboxed_bitmaps`. It is called only
/// on ops that do not declare these attributes, where MLIR would otherwise keep one as an unregistered attribute
/// that nothing reads; on those ops `slot_kinds` carries the layout instead.
static LogicalResult rejectStaleBitmapAttr(Operation *op) {
  for (StringRef n : {"unboxed_bitmap", "newargs_unboxed_bitmap", "unboxed_bitmaps"})
    if (op->hasAttr(n))
      return op->emitOpError("stale attribute '") << n
             << "': regenerate the MLIR (slot_kinds replaced it; "
                "plans/wide-object-tail-kind-words.md Phase 3D)";
  return success();
}

/// Returns the slot kind of a field of type `t`: 1 for `i64`, 2 for `f64`, 3 for `i32`, and 0 (boxed) for any other
/// type, including `i1`, which callers reject separately.
static uint8_t fieldKind(Type t) {
  if (t.isInteger(64)) return 1;
  if (t.isF64()) return 2;
  if (eco::isEcoCharType(t)) return 3;
  return 0;
}


/// Checks that `kinds` has one entry per type in `slots`, each the slot kind of that type (REP_BOUNDARY_002).
///
/// A field of type `i1` is rejected: Bool must be boxed first. A boxed field must be `!eco.value` or a value-level
/// aggregate (tuple, record, custom or cons), which the construct lowering boxes. `what` names a field in
/// diagnostics.
static LogicalResult verifySlotKinds(Operation *op, TypeRange slots,
                                     ArrayRef<int8_t> kinds, StringRef what) {
  if (kinds.size() != slots.size())
    return op->emitOpError("slot_kinds has ") << kinds.size()
           << " entries but there are " << slots.size() << " " << what << "s";
  for (unsigned i = 0; i < slots.size(); ++i) {
    Type t = slots[i];
    if (t.isInteger(1))
      return op->emitOpError(what) << " " << i
             << " has i1 type: Bool must be boxed to !eco.value before construction";
    const uint8_t k = fieldKind(t);
    if (k == 0 && !isa<eco::ValueType, eco::Tuple2Type, eco::Tuple3Type,
                        eco::RecordType, eco::CustomType, eco::ConsType>(t))
      return op->emitOpError(what) << " " << i
             << " has kind=boxed but non-boxed SSA type " << t;
    const int8_t want = kinds[i];
    if (want < 0 || want > 3)
      return op->emitOpError("slot_kinds[") << i << "] = " << int(want)
             << " is not a kind (0..3)";
    if (uint8_t(want) != k)
      return op->emitOpError("slot_kinds[") << i << "] = " << int(want)
             << " does not match operand type " << t << " (kind " << int(k) << ")";
  }
  return success();
}

/// Checks a custom-type construction: no stale bitmap attribute, at least one field (CGEN_079), one operand per
/// field, at most `CUSTOM_MAX_FIELDS` fields (HEAP_019), and slot kinds that match the operand types.
///
/// A nullary constructor is an embedded null-cons constant, `eco.constant.null_cons`. A zero-field construct would
/// give the same value a second, heap, representation, which comparison by word equality would treat as different.
LogicalResult CustomConstructOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  if (getSize() == 0) {
    return emitOpError(
        "0-field custom construction is forbidden (CGEN_079): nullary "
        "constructors are embedded null-cons constants — emit "
        "eco.constant.null_cons instead");
  }

  int64_t size = getSize();
  if (static_cast<int64_t>(getFields().size()) != size) {
    return emitOpError("number of operands (")
           << getFields().size()
           << ") must equal size attribute ("
           << size << ")";
  }

  if (size > static_cast<int64_t>(Elm::CUSTOM_MAX_FIELDS)) {
    return emitOpError("size (") << size << ") exceeds Custom's "
           << Elm::CUSTOM_MAX_FIELDS << "-field limit (HEAP_019)";
  }

  return verifySlotKinds(getOperation(), getFields().getTypes(),
                         getSlotKinds(), "field");
}

/// Checks a record construction: no stale bitmap attribute, one operand per field, at most `RECORD_MAX_FIELDS`
/// fields (HEAP_019), and slot kinds that match the operand types. `slot_kinds` is only checked; the lowering takes
/// the kinds from the operand types.
LogicalResult RecordConstructOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  int64_t fieldCount = getFieldCount();
  if (static_cast<int64_t>(getFields().size()) != fieldCount) {
    return emitOpError("number of operands (")
           << getFields().size()
           << ") must equal field_count attribute ("
           << fieldCount << ")";
  }

  if (fieldCount > static_cast<int64_t>(Elm::RECORD_MAX_FIELDS)) {
    return emitOpError("field_count (") << fieldCount << ") exceeds Record's "
           << Elm::RECORD_MAX_FIELDS << "-field limit (HEAP_019)";
  }

  return verifySlotKinds(getOperation(), getFields().getTypes(),
                         getSlotKinds(), "field");
}

//===----------------------------------------------------------------------===//
// Tuple / Cons header kinds (CGEN_026)
//===----------------------------------------------------------------------===//

/// Returns the slot kind of a tuple field or cons head of type `t`, or reports an error on `op` and fails when `t` is
/// `i1` or a boxed type other than `!eco.value` or a value-level aggregate. `what` names the operand in diagnostics.
///
/// The tuple and cons lowerings copy `unboxed_bitmap` or `head_kind` into the heap header but store each field by its
/// SSA type, so the two must agree, or the collector would trace a raw number as a pointer or skip a real one.
static FailureOr<uint8_t> heapOperandKind(Operation *op, Type t,
                                          StringRef what) {
  if (t.isInteger(1)) {
    op->emitOpError(what)
        << " has i1 type: Bool must be boxed to !eco.value before construction";
    return failure();
  }
  const uint8_t k = fieldKind(t);
  if (k == 0 && !isa<eco::ValueType, eco::Tuple2Type, eco::Tuple3Type,
                      eco::RecordType, eco::CustomType, eco::ConsType>(t)) {
    op->emitOpError(what) << " has kind=boxed but non-boxed SSA type " << t;
    return failure();
  }
  return k;
}

/// Checks that a tuple's `bitmap` equals the slot kinds of `slots`, slot `i` in bits `2i` and `2i+1`, with no bit set
/// beyond the last slot (CGEN_026).
static LogicalResult verifyTupleBitmap(Operation *op, TypeRange slots,
                                       int64_t bitmap) {
  int64_t want = 0;
  for (auto [i, t] : llvm::enumerate(slots)) {
    FailureOr<uint8_t> k =
        heapOperandKind(op, t, ("operand " + Twine(i)).str());
    if (failed(k))
      return failure();
    want |= int64_t(*k) << (2 * i);
  }
  if (bitmap != want)
    return op->emitOpError("unboxed_bitmap = ") << bitmap
           << " does not match the operand types (expected " << want
           << "; 2 bits per slot: 0 boxed, 1 i64, 2 f64, 3 i32) (CGEN_026)";
  return success();
}

/// Checks that the pair's `unboxed_bitmap` matches its operand types.
LogicalResult Tuple2ConstructOp::verify() {
  Type slots[2] = {getA().getType(), getB().getType()};
  return verifyTupleBitmap(getOperation(), slots, getUnboxedBitmap());
}

/// Checks that the triple's `unboxed_bitmap` matches its operand types.
LogicalResult Tuple3ConstructOp::verify() {
  Type slots[3] = {getA().getType(), getB().getType(), getC().getType()};
  return verifyTupleBitmap(getOperation(), slots, getUnboxedBitmap());
}

/// Checks that a cons cell's `head_kind` is the slot kind of its head's type, and that `head_unboxed` is true
/// exactly when that kind is not boxed.
LogicalResult ListConstructOp::verify() {
  FailureOr<uint8_t> k =
      heapOperandKind(getOperation(), getHead().getType(), "head");
  if (failed(k))
    return failure();
  if (getHeadKind() != int64_t(*k))
    return emitOpError("head_kind = ") << getHeadKind()
           << " does not match head type " << getHead().getType()
           << " (kind " << int(*k) << ") (CGEN_026)";
  if (getHeadUnboxed() != (*k != 0))
    return emitOpError("head_unboxed = ") << getHeadUnboxed()
           << " disagrees with head_kind = " << getHeadKind();
  return success();
}

//===----------------------------------------------------------------------===//
// Closure slot kinds
//===----------------------------------------------------------------------===//

/// Returns the slot kind of a closure operand of type `t`. The mapping is the same as `fieldKind`'s.
static uint8_t operandKind(Type t) {
  if (t.isInteger(64)) return 1;
  if (t.isF64()) return 2;
  if (eco::isEcoCharType(t)) return 3;
  return 0;
}

/// Checks that every operand stored in a closure is `!eco.value`, `i64`, `f64` or `i32`, and that `kinds` has one
/// entry per operand equal to its slot kind (CGEN_003). An `i1` operand is rejected because Bool must be boxed
/// (REP_CLOSURE_001); aggregates are rejected as boxed but not `!eco.value`. `what` names an operand in
/// diagnostics.
static LogicalResult verifyClosureKinds(Operation *op, ValueRange operands,
                                        ArrayRef<int8_t> kinds, const char *what) {
  for (auto [i, v] : llvm::enumerate(operands)) {
    Type ty = v.getType();
    if (ty.isInteger(1))
      return op->emitOpError(StringRef(what) == "capture" ? "captured" : what)
             << " Bool (i1) at index " << i
             << " violates REP_CLOSURE_001: Bool must be boxed to !eco.value "
                "at closure boundary";
    if (operandKind(ty) == 0 && !isa<eco::ValueType>(ty))
      return op->emitOpError(what) << " " << i
             << " has kind=boxed but non-boxed SSA type " << ty;
  }
  if (kinds.size() != operands.size())
    return op->emitOpError("slot_kinds length (") << kinds.size()
           << ") != " << what << " count (" << operands.size() << ")";
  for (auto [i, v] : llvm::enumerate(operands)) {
    int k = kinds[i];
    if (k < 0 || k > 3 || uint8_t(k) != operandKind(v.getType()))
      return op->emitOpError(what) << " " << i << " slot_kinds " << k
             << " does not match SSA type " << v.getType();
  }
  return success();
}

/// The largest arity a closure may have, set by the width of the closure header's arity field (HEAP_078).
static constexpr int64_t kClosureMaxArity = Elm::CLOSURE_MAX_ARITY;
/// The largest number of values a closure may capture: one less than the largest arity, because a partial
/// application always has at least one parameter left.
static constexpr int64_t kClosureMaxCaptures = Elm::CLOSURE_MAX_ARITY - 1;

/// Checks a closure creation: no stale bitmap attribute, a `_fast_evaluator` equal to `function` when present, one
/// operand per `num_captured`, fewer captures than `arity`, both within the closure limits, and slot kinds that match
/// the captured operands. The kernel declaration check is in `verifySymbolUses`.
LogicalResult PapCreateOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  if (auto fast = get_fastEvaluatorAttr()) {
    if (fast != getFunctionAttr())
      return emitOpError("_fast_evaluator '") << fast.getValue()
             << "' must equal function '" << getFunction() << "'";
  }

  int64_t numCaptured = getNumCaptured();
  int64_t capturedCount = static_cast<int64_t>(getCaptured().size());
  if (capturedCount != numCaptured) {
    return emitOpError("number of captured operands (")
           << capturedCount
           << ") must match num_captured attribute ("
           << numCaptured << ")";
  }

  int64_t arity = getArity();
  if (numCaptured >= arity) {
    return emitOpError("num_captured (")
           << numCaptured
           << ") must be less than arity ("
           << arity << ")";
  }

  if (numCaptured > kClosureMaxCaptures) {
    return emitOpError("num_captured (")
           << numCaptured
           << ") exceeds closure capture limit (" << kClosureMaxCaptures << ")";
  }
  if (arity > kClosureMaxArity) {
    return emitOpError("arity (")
           << arity
           << ") exceeds closure arity limit (" << kClosureMaxArity << ")";
  }

  if (failed(verifyClosureKinds(getOperation(), getCaptured(), getSlotKinds(),
                                "capture")))
    return failure();

  return success();
}

/// Checks a closure application on its own, without looking at where the closure came from.
///
/// There must be no stale bitmap attribute, no more new arguments than the closure arity limit, and slot kinds that
/// match them. Without `remaining_arity` (generic mode), whether the application is saturated is decided at run time
/// from the closure header, so the result may be `!eco.value` or a primitive (`i64`, `f64` or `i32`). With it (typed
/// mode), a partial application must yield `!eco.value`, the new closure, and a saturated one `!eco.value` or a
/// primitive, never `i1`. The comparison with the evaluator's signature is in `verifySymbolUses`.
LogicalResult PapExtendOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  auto newargs = getNewargs();

  if (newargs.size() > static_cast<size_t>(kClosureMaxArity)) {
    return emitOpError("newargs count (")
           << newargs.size()
           << ") exceeds closure arity limit (" << kClosureMaxArity << ")";
  }

  if (failed(verifyClosureKinds(getOperation(), newargs, getSlotKinds(),
                                "newarg")))
    return failure();

  // A primitive result in generic mode is a promise from the compiler that the application is saturated at run time;
  // nothing here can check it.
  auto remainingArityAttr = getRemainingArityAttr();
  if (!remainingArityAttr) {
    Type resultType = getResult().getType();
    bool isBoxed = isa<eco::ValueType>(resultType);
    bool isPrimitive = resultType.isInteger(64) || resultType.isF64()
                       || eco::isEcoCharType(resultType);
    if (!isBoxed && !isPrimitive) {
      return emitOpError("generic-mode papExtend (no remaining_arity) must "
                         "have !eco.value or primitive (i64/f64/i32) result "
                         "type, got ") << resultType;
    }
    return success();
  }

  Type resultType = getResult().getType();
  int64_t remainingArity = remainingArityAttr.getInt();
  if (static_cast<int64_t>(newargs.size()) < remainingArity) {
    if (!isa<eco::ValueType>(resultType))
      return emitOpError("partial typed-mode papExtend (")
             << newargs.size() << " of " << remainingArity
             << " remaining args) must have !eco.value (closure) result type, got "
             << resultType;
  } else if (!isa<eco::ValueType>(resultType) && !resultType.isInteger(64) &&
             !resultType.isF64() && !eco::isEcoCharType(resultType)) {
    return emitOpError("saturated typed-mode papExtend must have !eco.value "
                       "or primitive (i64/f64/i32) result type, got ")
           << resultType;
  }
  return success();
}

/// Checks a group of sibling closures created together, which may capture one another.
///
/// A cross edge is a triple (producer, consumer, slot): sibling `consumer` captures sibling `producer` in capture slot
/// `slot`. In each sibling, the captures that are not siblings come first, `capture_counts[i]` of them, and are the
/// op's operands, sibling by sibling in order; the sibling captures fill the slots after them.
///
/// The checks are: at least two siblings; every per-sibling array of that length; `functions` equal to
/// `fast_evaluators`; each sibling's `slot_kinds` a `DenseI8ArrayAttr` of length `num_captured`; `cross_edges` a
/// multiple of three long, with producer and consumer in range and the slot within the consumer's captures and boxed;
/// `num_captured` equal to `capture_counts` plus the sibling's incoming cross edges; captures and arity within the
/// closure limits and fewer captures than arity; and kinds that match the operand captures, with every sibling slot
/// boxed.
///
/// The entries of `cross_edges`, `num_captured`, `capture_counts` and `arities` are assumed to be integer attributes
/// and are not checked to be.
LogicalResult PapCreateGroupOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  const size_t numSiblings = getClosures().size();
  if (numSiblings < 2)
    return emitOpError("expects at least 2 siblings, got ") << numSiblings;

  auto functions = getFunctions();
  auto fastEvaluators = getFastEvaluators();
  auto arities = getArities();
  auto numCaptured = getNumCaptured();
  auto slotKinds = getSlotKinds();
  auto captureCounts = getCaptureCounts();
  auto crossEdges = getCrossEdges();

  if (functions.size() != numSiblings ||
      fastEvaluators.size() != numSiblings ||
      arities.size() != numSiblings ||
      numCaptured.size() != numSiblings ||
      slotKinds.size() != numSiblings ||
      captureCounts.size() != numSiblings) {
    return emitOpError("per-sibling attribute arrays must all have length ")
           << numSiblings;
  }
  for (size_t i = 0; i < numSiblings; ++i)
    if (functions[i] != fastEvaluators[i])
      return emitOpError("functions[") << i << "] must equal fast_evaluators["
             << i << "]";
  for (size_t i = 0; i < numSiblings; ++i)
    if (!isa<DenseI8ArrayAttr>(slotKinds[i]))
      return emitOpError("slot_kinds[") << i << "] must be a DenseI8ArrayAttr";
  auto siblingKinds = [&](size_t i) -> ArrayRef<int8_t> {
    return cast<DenseI8ArrayAttr>(slotKinds[i]).asArrayRef();
  };

  if (crossEdges.size() % 3 != 0)
    return emitOpError("cross_edges must be flat triples, length ")
           << crossEdges.size() << " is not a multiple of 3";

  SmallVector<int64_t, 8> crossEdgeInDegree(numSiblings, 0);
  for (size_t i = 0; i < crossEdges.size(); i += 3) {
    int64_t producer = cast<IntegerAttr>(crossEdges[i]).getInt();
    int64_t consumer = cast<IntegerAttr>(crossEdges[i + 1]).getInt();
    int64_t slot = cast<IntegerAttr>(crossEdges[i + 2]).getInt();
    if (producer < 0 || producer >= static_cast<int64_t>(numSiblings))
      return emitOpError("cross_edges producer ") << producer << " out of range";
    if (consumer < 0 || consumer >= static_cast<int64_t>(numSiblings))
      return emitOpError("cross_edges consumer ") << consumer << " out of range";
    int64_t consumerCap = cast<IntegerAttr>(numCaptured[consumer]).getInt();
    if (slot < 0 || slot >= consumerCap)
      return emitOpError("cross_edges slot ") << slot
             << " out of range for consumer " << consumer
             << " with num_captured " << consumerCap;
    {
      ArrayRef<int8_t> ks = siblingKinds(consumer);
      if (slot < static_cast<int64_t>(ks.size()) && ks[slot] != 0)
        return emitOpError("cross-edge consumer ") << consumer
               << " slot " << slot << " must be boxed (slot_kinds is "
               << int(ks[slot]) << ")";
    }
    crossEdgeInDegree[consumer] += 1;
  }

  int64_t totalCaptures = 0;
  for (size_t i = 0; i < numSiblings; ++i) {
    int64_t cap = cast<IntegerAttr>(numCaptured[i]).getInt();
    int64_t cc = cast<IntegerAttr>(captureCounts[i]).getInt();
    if (cc < 0)
      return emitOpError("capture_counts[") << i << "] is negative";
    if (cap != cc + crossEdgeInDegree[i])
      return emitOpError("sibling ") << i << " num_captured (" << cap
             << ") must equal capture_counts (" << cc
             << ") + cross-edge in-degree (" << crossEdgeInDegree[i] << ")";
    int64_t arity = cast<IntegerAttr>(arities[i]).getInt();
    if (cap >= arity)
      return emitOpError("sibling ") << i << " num_captured (" << cap
             << ") must be less than arity (" << arity << ")";
    if (cap > kClosureMaxCaptures)
      return emitOpError("sibling ") << i << " num_captured (" << cap
             << ") exceeds closure capture limit (" << kClosureMaxCaptures << ")";
    if (arity > kClosureMaxArity)
      return emitOpError("sibling ") << i << " arity ("
             << arity << ") exceeds closure arity limit (" << kClosureMaxArity << ")";
    totalCaptures += cc;
  }

  int64_t operandCount = static_cast<int64_t>(getOperands().size());
  if (operandCount != totalCaptures)
    return emitOpError("operand count (")
           << operandCount
           << ") must equal sum of capture_counts ("
           << totalCaptures << ")";

  auto captures = getOperands();
  size_t operandCursor = 0;
  for (size_t i = 0; i < numSiblings; ++i) {
    int64_t cc = cast<IntegerAttr>(captureCounts[i]).getInt();
    auto sibCaptures = captures.slice(operandCursor, static_cast<size_t>(cc));
    {
      ArrayRef<int8_t> ks = siblingKinds(i);
      int64_t cap = cast<IntegerAttr>(numCaptured[i]).getInt();
      if (static_cast<int64_t>(ks.size()) != cap)
        return emitOpError("slot_kinds[") << i << "] length (" << ks.size()
               << ") != num_captured (" << cap << ")";
      if (failed(verifyClosureKinds(getOperation(), sibCaptures,
                                    ks.take_front(static_cast<size_t>(cc)),
                                    "capture")))
        return failure();
      for (int64_t j = cc; j < cap; ++j)
        if (ks[j] != 0)
          return emitOpError("sibling ") << i << " slot " << j
                 << " holds a sibling closure and must be boxed (slot_kinds is "
                 << int(ks[j]) << ")";
    }
    operandCursor += cc;
  }

  return success();
}

/// Checks a read of a closure's capture: the index is not negative, and when the operand is a `!eco.closure_env` the
/// index is within its captures and the result type is the capture's type. A `!eco.value` operand's index is not
/// bounds-checked.
LogicalResult ProjectClosureOp::verify() {
  int64_t index = getIndex();
  if (index < 0) {
    return emitOpError("index must be non-negative, got ") << index;
  }

  Type closureType = getClosure().getType();
  if (auto envTy = dyn_cast<eco::ClosureEnvType>(closureType)) {
    if (static_cast<size_t>(index) >= envTy.getCaptures().size()) {
      return emitOpError("index ") << index
             << " out of range for closure env with "
             << envTy.getCaptures().size() << " captures";
    }
    Type expected = envTy.getCaptures()[index];
    if (getResult().getType() != expected) {
      return emitOpError("result type ") << getResult().getType()
             << " does not match env slot type " << expected
             << " at index " << index;
    }
  } else if (!isa<eco::ValueType>(closureType)) {
    return emitOpError("closure operand must be !eco.value or !eco.closure_env");
  }

  return success();
}

/// Checks a call's attributes against its form.
///
/// `eco.cse_safe` is accepted only on a direct call that is not `musttail`. A direct call (with `callee`) must not
/// have `remaining_arity`; its signature is checked in `verifySymbolUses`. An indirect call applies its first operand,
/// which must be `!eco.value`, to the rest, and its `remaining_arity` must be present, positive and equal to the
/// number of those other operands.
LogicalResult CallOp::verify() {
  auto operands = getOperands();
  auto calleeAttr = getCalleeAttr();
  auto remainingArityAttr = getRemainingArityAttr();

  if ((*this)->hasAttr(kCseSafeAttrName)) {
    if (!calleeAttr)
      return emitOpError("'eco.cse_safe' is only valid on a direct call "
                         "(requires the 'callee' attribute)");
    auto musttail = getMusttail();
    if (musttail && *musttail)
      return emitOpError("'eco.cse_safe' must not be set on a musttail call");
  }

  if (calleeAttr) {
    if (remainingArityAttr) {
      return emitOpError("must not have both 'callee' and 'remaining_arity' attributes");
    }

    return success();
  }

  if (operands.empty()) {
    return emitOpError("indirect call must have at least one operand (closure)");
  }

  Value closure = operands.front();
  if (!isa<eco::ValueType>(closure.getType())) {
    return emitOpError("first operand of indirect call must be !eco.value (closure)");
  }

  if (!remainingArityAttr) {
    return emitOpError("indirect call must specify 'remaining_arity' attribute");
  }

  int64_t remainingArity = remainingArityAttr.getValue().getSExtValue();
  unsigned numNewArgs = operands.size() - 1;

  if (remainingArity <= 0) {
    return emitOpError("remaining_arity must be > 0, got ") << remainingArity;
  }

  if (remainingArity != static_cast<int64_t>(numNewArgs)) {
    return emitOpError("remaining_arity (") << remainingArity
           << ") must equal number of new arguments (" << numNewArgs << ")";
  }

  return success();
}

//===----------------------------------------------------------------------===//
// MemoryEffectOpInterface: CallOp
//===----------------------------------------------------------------------===//

/// Appends a call's memory effects to `effects`: none when it carries `eco.cse_safe`, and otherwise a read and a
/// write of the default resource.
///
/// Reporting no effects lets MLIR merge identical calls and erase unused ones. It does not let a call be hoisted or
/// executed speculatively, because `CallOp` does not implement `ConditionallySpeculatable`. A call without the
/// attribute must report effects explicitly: an op that implements this interface and reports nothing is treated as
/// having no effects, so every call would become erasable.
void CallOp::getEffects(
    SmallVectorImpl<MemoryEffects::EffectInstance> &effects) {
    if ((*this)->hasAttr(kCseSafeAttrName))
        return; // no effects

    effects.emplace_back(MemoryEffects::Read::get());
    effects.emplace_back(MemoryEffects::Write::get());
}

//===----------------------------------------------------------------------===//
// Projection Folders
//===----------------------------------------------------------------------===//
//
// A projection whose operand is defined directly by a construct op folds to the construct's operand:
//
//   eco.project.X %c[i]  where %c = eco.construct.X(..., f_i, ...)   ==>   f_i
//   eco.get_tag %c       where %c = eco.construct.custom {tag = N}   ==>   N
//
// This relies on the object not being modified between construction and projection. The operand already dominates
// the projection, because it dominates the construct.
//
// The operand is the projected value only when the two have the same type. A boxed slot may hold an aggregate-typed
// operand that the construct lowering boxes with `eco.to_heap`, and then the projection yields an `!eco.value` that
// is not the operand, so no fold is made.

/// Returns `fields[index]` when `index` is within `declaredCount`, `fields` has at least that many entries, and the
/// field's type is `resultTy`, and otherwise a null value, meaning no fold.
static Value foldConstructedField(ValueRange fields, int64_t declaredCount,
                                  int64_t index, Type resultTy) {
    if (index < 0 || index >= declaredCount)
        return {};
    if (static_cast<int64_t>(fields.size()) < declaredCount)
        return {};
    Value f = fields[index];
    if (f.getType() != resultTy)
        return {};
    return f;
}

/// Folds a projection whose operand is defined directly by an `eco.construct.custom` to the projected field operand.
OpFoldResult CustomProjectOp::fold(FoldAdaptor) {
    auto ctor = getContainer().getDefiningOp<eco::CustomConstructOp>();
    if (!ctor)
        return {};
    // The accessors return `uint64_t`; the cast lets the guard's negative test catch a wrapped value.
    return foldConstructedField(ctor.getFields(),
                                static_cast<int64_t>(ctor.getSize()),
                                static_cast<int64_t>(getFieldIndex()),
                                getResult().getType());
}

/// Folds a projection whose operand is defined directly by an `eco.construct.record` to the projected field operand.
OpFoldResult RecordProjectOp::fold(FoldAdaptor) {
    auto ctor = getRecord().getDefiningOp<eco::RecordConstructOp>();
    if (!ctor)
        return {};
    return foldConstructedField(ctor.getFields(),
                                static_cast<int64_t>(ctor.getFieldCount()),
                                static_cast<int64_t>(getFieldIndex()),
                                getResult().getType());
}

/// Folds a pair projection whose operand is defined directly by its construct op to the projected field operand.
OpFoldResult Tuple2ProjectOp::fold(FoldAdaptor) {
    auto ctor = getTuple().getDefiningOp<eco::Tuple2ConstructOp>();
    if (!ctor)
        return {};
    SmallVector<Value, 2> fields{ctor.getA(), ctor.getB()};
    return foldConstructedField(fields, 2, static_cast<int64_t>(getField()),
                                getResult().getType());
}

/// Folds a triple projection whose operand is defined directly by its construct op to the projected field operand.
OpFoldResult Tuple3ProjectOp::fold(FoldAdaptor) {
    auto ctor = getTuple().getDefiningOp<eco::Tuple3ConstructOp>();
    if (!ctor)
        return {};
    SmallVector<Value, 3> fields{ctor.getA(), ctor.getB(), ctor.getC()};
    return foldConstructedField(fields, 3, static_cast<int64_t>(getField()),
                                getResult().getType());
}

/// Returns whether the list head and tail folds are on: true when `ECO_MLIR_FOLD_LIST` is set to a non-empty value
/// other than `0`. The variable is read once per process.
///
/// They are off by default because folding a list projection changes the loop shapes that the EcoListCursor pass
/// matches.
static bool listFoldsEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_MLIR_FOLD_LIST");
        return e && *e && !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

/// Folds the head of a cons cell defined directly by `eco.construct.list` to its head operand, when list folds
/// are on.
OpFoldResult ListHeadOp::fold(FoldAdaptor) {
    if (!listFoldsEnabled())
        return {};
    auto ctor = getList().getDefiningOp<eco::ListConstructOp>();
    if (!ctor)
        return {};
    // Type equality also implies the slot kind, because `ListConstructOp::verify` ties `head_kind` to the head type.
    SmallVector<Value, 1> f{ctor.getHead()};
    return foldConstructedField(f, 1, 0, getResult().getType());
}

/// Folds the tail of a cons cell defined directly by `eco.construct.list` to its tail operand, when list folds
/// are on.
OpFoldResult ListTailOp::fold(FoldAdaptor) {
    if (!listFoldsEnabled())
        return {};
    auto ctor = getList().getDefiningOp<eco::ListConstructOp>();
    if (!ctor)
        return {};
    SmallVector<Value, 1> f{ctor.getTail()};
    return foldConstructedField(f, 1, 0, getResult().getType());
}

/// Folds the tag of a custom value defined directly by an `eco.construct.custom` to that construct's `tag`,
/// as an attribute that the fold driver turns into a constant.
OpFoldResult GetTagOp::fold(FoldAdaptor) {
    auto ctor = getValue().getDefiningOp<eco::CustomConstructOp>();
    if (!ctor)
        return {};
    // At run time the tag of a custom object is the constructor index stored by the construct.
    return IntegerAttr::get(getResult().getType(),
                            static_cast<int64_t>(ctor.getTag()));
}

//===----------------------------------------------------------------------===//
// Value-level Aggregate Op Verifiers
//===----------------------------------------------------------------------===//
//
// A value-level aggregate (`!eco.tuple2`, `!eco.record`, `!eco.closure_env`, ...) is an SSA value whose type lists
// the types of its elements, not yet an object on the heap.

/// Checks that `actual` has the same length as `expected` and equal types in order. `label` names an element in
/// diagnostics.
static LogicalResult verifyAggElements(Operation *op,
                                       ArrayRef<Type> actual,
                                       ArrayRef<Type> expected,
                                       StringRef label) {
  if (actual.size() != expected.size()) {
    return op->emitOpError(label) << " count " << actual.size()
           << " does not match result aggregate element count "
           << expected.size();
  }
  for (size_t i = 0; i < actual.size(); ++i) {
    if (actual[i] != expected[i]) {
      return op->emitOpError(label) << " " << i << " has SSA type "
             << actual[i] << " but result aggregate expects "
             << expected[i];
    }
  }
  return success();
}

/// Checks that the operand types equal the element types of the resulting pair type.
LogicalResult Tuple2MakeOp::verify() {
  auto resTy = cast<eco::Tuple2Type>(getResult().getType());
  Type expected[2] = { resTy.getFirst(), resTy.getSecond() };
  Type actual[2]   = { getA().getType(), getB().getType() };
  return verifyAggElements(getOperation(), actual, expected, "operand");
}

/// Checks that the operand types equal the element types of the resulting triple type.
LogicalResult Tuple3MakeOp::verify() {
  auto resTy = cast<eco::Tuple3Type>(getResult().getType());
  Type expected[3] = { resTy.getFirst(), resTy.getSecond(), resTy.getThird() };
  Type actual[3]   = { getA().getType(), getB().getType(), getC().getType() };
  return verifyAggElements(getOperation(), actual, expected, "operand");
}

/// Checks that the field operand types equal the field types of the resulting record type.
LogicalResult RecordMakeOp::verify() {
  auto resTy = cast<eco::RecordType>(getResult().getType());
  SmallVector<Type, 8> actual;
  for (Value f : getFields()) actual.push_back(f.getType());
  return verifyAggElements(getOperation(), actual, resTy.getFields(), "field");
}

/// Checks that the field operand types equal the field types of the resulting custom type, and that the tag is in
/// 0 to 65535, the range of the 16-bit tag it will have on the heap.
LogicalResult CustomMakeOp::verify() {
  auto resTy = cast<eco::CustomType>(getResult().getType());
  SmallVector<Type, 8> actual;
  for (Value f : getFields()) actual.push_back(f.getType());
  if (failed(verifyAggElements(getOperation(), actual, resTy.getFields(), "field")))
    return failure();
  int64_t tag = getTag();
  if (tag < 0 || tag > 0xFFFF) {
    return emitOpError("tag (") << tag << ") must fit in 16 bits";
  }
  return success();
}

/// Checks that the head and tail types equal those of the resulting cons type, and that the tail type is
/// `!eco.value`.
LogicalResult ConsMakeOp::verify() {
  auto resTy = cast<eco::ConsType>(getResult().getType());
  if (getHead().getType() != resTy.getHead()) {
    return emitOpError("head SSA type ") << getHead().getType()
           << " does not match cons head element type " << resTy.getHead();
  }
  if (getTail().getType() != resTy.getTail()) {
    return emitOpError("tail SSA type ") << getTail().getType()
           << " does not match cons tail element type " << resTy.getTail();
  }
  if (!isa<eco::ValueType>(resTy.getTail())) {
    return emitOpError("cons tail element type must be !eco.value in this phase, got ")
           << resTy.getTail();
  }
  return success();
}

/// Checks an `eco.list.map`: `in_kind` and `out_kind` are slot kinds, 0 to 3 (REP_HEAP_002); captures appear only
/// with a `callee`; and a named callee is a `func.func` whose parameters are the captures' types followed by one
/// element. The element parameter's type is not compared.
///
/// The callee is looked up without a symbol table cache, once per op verified.
LogicalResult ListMapOp::verify() {
  for (auto [what, kind] :
       {std::make_pair("in_kind", getInKind()),
        std::make_pair("out_kind", getOutKind())}) {
    if (kind < 0 || kind > 3) {
      return emitOpError(what) << " must be a 2-bit slot kind (0..3), got "
                               << kind;
    }
  }

  if (!getCalleeAttr() && !getCaptures().empty()) {
    return emitOpError("captures require a callee attribute; a generic-apply "
                       "eco.list.map must have none, got ")
           << getCaptures().size();
  }

  if (auto callee = getCalleeAttr()) {
    auto fn = SymbolTable::lookupNearestSymbolFrom<func::FuncOp>(
        getOperation(), callee);
    if (!fn) {
      return emitOpError("callee '") << callee.getValue()
             << "' does not resolve to a func.func";
    }
    size_t want = getCaptures().size() + 1;
    if (fn.getNumArguments() != want) {
      return emitOpError("callee '")
             << callee.getValue() << "' takes " << fn.getNumArguments()
             << " parameters but the template supplies " << want
             << " (" << getCaptures().size() << " captures + 1 element)";
    }
    for (auto [i, cap] : llvm::enumerate(getCaptures())) {
      if (cap.getType() != fn.getArgumentTypes()[i]) {
        return emitOpError("capture ")
               << i << " has type " << cap.getType()
               << " but callee '" << callee.getValue() << "' expects "
               << fn.getArgumentTypes()[i];
      }
    }
  }

  return success();
}

/// Checks that the capture operand types equal the capture types of the resulting closure environment type.
LogicalResult ClosureEnvMakeOp::verify() {
  auto resTy = cast<eco::ClosureEnvType>(getResult().getType());
  SmallVector<Type, 8> actual;
  for (Value c : getCaptures()) actual.push_back(c.getType());
  return verifyAggElements(getOperation(), actual, resTy.getCaptures(), "capture");
}

/// Checks a move of a value-level aggregate to the heap.
///
/// A closure environment is rejected (CGEN_062): `eco.make.closure` builds closures. The operand must be a tuple,
/// record, custom or cons value, with no stale bitmap attribute. A record or custom value must have no more fields
/// than its heap limit (HEAP_019), and its field types must be storable; `slot_kinds`, if given, must match them, and
/// is only checked, because the lowering takes the kinds from the field types. Other aggregates must not carry
/// `slot_kinds`.
LogicalResult ToHeapOp::verify() {
  Type valTy = getValue().getType();
  if (isa<eco::ClosureEnvType>(valTy)) {
    return emitOpError("eco.to_heap rejects !eco.closure_env operands; use "
                       "eco.make.closure to realise heap closures (CGEN_062)");
  }
  // The operand constraint in `Ops.td` already restricts the type to these.
  if (!isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
           eco::CustomType, eco::ConsType>(valTy)) {
    return emitOpError("operand must be a data aggregate, got ") << valTy;
  }
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  const bool isRec = isa<eco::RecordType>(valTy);
  if (isRec || isa<eco::CustomType>(valTy)) {
    ArrayRef<Type> fields = isRec ? cast<eco::RecordType>(valTy).getFields()
                                  : cast<eco::CustomType>(valTy).getFields();
    const uint64_t cap = isRec ? Elm::RECORD_MAX_FIELDS : Elm::CUSTOM_MAX_FIELDS;
    if (fields.size() > cap)
      return emitOpError(isRec ? "record" : "custom") << " aggregate has "
             << fields.size() << " fields; limit is " << cap << " (HEAP_019)";
    // Without `slot_kinds`, checking the derived kinds checks only that every field type is storable.
    SmallVector<int8_t> derived;
    for (Type t : fields) derived.push_back(static_cast<int8_t>(fieldKind(t)));
    auto ks = getSlotKinds();
    return verifySlotKinds(getOperation(), TypeRange(fields),
                           ks ? *ks : ArrayRef<int8_t>(derived), "field");
  }
  if (getSlotKinds())
    return emitOpError("slot_kinds is only meaningful on a record/custom aggregate");
  return success();
}

/// Checks that a load of a heap object into a value-level aggregate produces a tuple, record, custom or cons value,
/// and never a closure environment (CGEN_063).
LogicalResult FromHeapOp::verify() {
  Type resTy = getResult().getType();
  if (isa<eco::ClosureEnvType>(resTy)) {
    return emitOpError("eco.from_heap rejects !eco.closure_env results; "
                       "closure environments do not flow through heap "
                       "aggregates (CGEN_063)");
  }
  if (!isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
           eco::CustomType, eco::ConsType>(resTy)) {
    return emitOpError("result must be a data aggregate, got ") << resTy;
  }
  return success();
}

/// Checks a closure built from a closure environment: fewer captures than `arity`, both within the closure limits,
/// and no `i1` capture (REP_CLOSURE_001).
LogicalResult MakeClosureOp::verify() {
  auto envTy = cast<eco::ClosureEnvType>(getEnv().getType());
  int64_t numCaptures = static_cast<int64_t>(envTy.getCaptures().size());
  int64_t arity = getArity();
  if (numCaptures >= arity) {
    return emitOpError("env captures (") << numCaptures
           << ") must be less than arity (" << arity << ")";
  }
  if (numCaptures > kClosureMaxCaptures) {
    return emitOpError("num_captured (") << numCaptures
           << ") exceeds closure capture limit (" << kClosureMaxCaptures << ")";
  }
  if (arity > kClosureMaxArity) {
    return emitOpError("arity (") << arity
           << ") exceeds closure arity limit (" << kClosureMaxArity << ")";
  }
  for (size_t i = 0; i < envTy.getCaptures().size(); ++i) {
    Type ty = envTy.getCaptures()[i];
    if (ty.isInteger(1)) {
      return emitOpError("captured Bool (i1) at index ") << i
             << " violates REP_CLOSURE_001: Bool must be boxed to !eco.value "
                "at closure boundary";
    }
  }
  return success();
}

//===----------------------------------------------------------------------===//
// Custom Assembly Format: CaseOp
//===----------------------------------------------------------------------===//

/// Prints an `eco.case` as
/// `eco.case %scrutinee : type [tag0, tag1, ...] -> (result_type0, ...) {attr-dict} {region0}, {region1}, ...`,
/// with every attribute other than `tags` in the attribute dictionary.
void CaseOp::print(OpAsmPrinter &p) {
  p << " " << getScrutinee() << " : " << getScrutinee().getType() << " [";
  llvm::interleaveComma(getTags(), p);
  p << "]";

  p << " -> (";
  llvm::interleaveComma(getResultTypes(), p);
  p << ")";

  p.printOptionalAttrDict((*this)->getAttrs(), {"tags"});

  for (Region &region : getAlternatives()) {
    p << " ";
    p.printRegion(region, /*printEntryBlockArgs=*/false,
                  /*printBlockTerminators=*/true);
    if (&region != &getAlternatives().back())
      p << ",";
  }
}

/// Parses the form `CaseOp::print` writes. At least one tag is required, and one region is read per tag. An empty
/// result list `-> ()` parses, and is then rejected by the verifier.
ParseResult CaseOp::parse(OpAsmParser &parser, OperationState &result) {
  OpAsmParser::UnresolvedOperand scrutinee;
  Type scrutineeType;
  if (parser.parseOperand(scrutinee) ||
      parser.parseColon() ||
      parser.parseType(scrutineeType))
    return failure();

  SmallVector<int64_t> tags;
  if (parser.parseLSquare())
    return failure();

  int64_t tag;
  if (parser.parseInteger(tag))
    return failure();
  tags.push_back(tag);

  while (succeeded(parser.parseOptionalComma())) {
    if (parser.parseInteger(tag))
      return failure();
    tags.push_back(tag);
  }

  if (parser.parseRSquare())
    return failure();

  result.addAttribute("tags", parser.getBuilder().getDenseI64ArrayAttr(tags));

  SmallVector<Type> resultTypes;
  if (parser.parseArrow() || parser.parseLParen())
    return failure();

  if (failed(parser.parseOptionalRParen())) {
    Type firstType;
    if (parser.parseType(firstType))
      return failure();
    resultTypes.push_back(firstType);

    while (succeeded(parser.parseOptionalComma())) {
      Type nextType;
      if (parser.parseType(nextType))
        return failure();
      resultTypes.push_back(nextType);
    }

    if (parser.parseRParen())
      return failure();
  }

  result.addTypes(resultTypes);

  if (parser.parseOptionalAttrDict(result.attributes))
    return failure();

  for (size_t i = 0; i < tags.size(); ++i) {
    Region *region = result.addRegion();
    if (parser.parseRegion(*region, /*arguments=*/{}, /*argTypes=*/{}))
      return failure();

    if (i < tags.size() - 1) {
      if (parser.parseComma())
        return failure();
    }
  }

  if (parser.resolveOperand(scrutinee, scrutineeType, result.operands))
    return failure();

  return success();
}

//===----------------------------------------------------------------------===//
// Custom Assembly Format: JoinpointOp
//===----------------------------------------------------------------------===//

/// Prints a joinpoint as
/// `eco.joinpoint id(%arg0: type0, ...) result_types [type0, ...] {body} continuation {cont} {attr-dict}`, where the
/// argument list is the body's entry block arguments and is left out when there are none, and `result_types` is left
/// out when absent. The body region must not be empty.
void JoinpointOp::print(OpAsmPrinter &p) {
  p << " " << getId();

  Block &bodyEntry = getBody().front();
  if (!bodyEntry.getArguments().empty()) {
    p << "(";
    llvm::interleaveComma(bodyEntry.getArguments(), p, [&](BlockArgument arg) {
      p << arg << ": " << arg.getType();
    });
    p << ")";
  }

  if (auto resultTypes = getJpResultTypes()) {
    p << " result_types [";
    llvm::interleaveComma(*resultTypes, p, [&](Attribute attr) {
      p << cast<TypeAttr>(attr).getValue();
    });
    p << "]";
  }

  p << " ";
  p.printRegion(getBody(), /*printEntryBlockArgs=*/false,
                /*printBlockTerminators=*/true);

  p << " continuation ";
  p.printRegion(getContinuation(), /*printEntryBlockArgs=*/false,
                /*printBlockTerminators=*/true);

  p.printOptionalAttrDict((*this)->getAttrs(), {"id", "jpResultTypes"});
}

/// Parses the form `JoinpointOp::print` writes. The arguments become the body's entry block arguments.
ParseResult JoinpointOp::parse(OpAsmParser &parser, OperationState &result) {
  int64_t id;
  if (parser.parseInteger(id))
    return failure();
  result.addAttribute("id", parser.getBuilder().getI64IntegerAttr(id));

  SmallVector<OpAsmParser::Argument> regionArgs;
  if (succeeded(parser.parseOptionalLParen())) {
    do {
      OpAsmParser::Argument arg;
      if (parser.parseArgument(arg) || parser.parseColon() ||
          parser.parseType(arg.type))
        return failure();
      regionArgs.push_back(arg);
    } while (succeeded(parser.parseOptionalComma()));

    if (parser.parseRParen())
      return failure();
  }

  if (succeeded(parser.parseOptionalKeyword("result_types"))) {
    if (parser.parseLSquare())
      return failure();

    SmallVector<Attribute> resultTypeAttrs;
    Type firstType;
    if (parser.parseType(firstType))
      return failure();
    resultTypeAttrs.push_back(TypeAttr::get(firstType));

    while (succeeded(parser.parseOptionalComma())) {
      Type nextType;
      if (parser.parseType(nextType))
        return failure();
      resultTypeAttrs.push_back(TypeAttr::get(nextType));
    }

    if (parser.parseRSquare())
      return failure();

    result.addAttribute("jpResultTypes",
                        parser.getBuilder().getArrayAttr(resultTypeAttrs));
  }

  Region *body = result.addRegion();
  if (parser.parseRegion(*body, regionArgs))
    return failure();

  if (parser.parseKeyword("continuation"))
    return failure();

  Region *continuation = result.addRegion();
  if (parser.parseRegion(*continuation, /*arguments=*/{}, /*argTypes=*/{}))
    return failure();

  if (parser.parseOptionalAttrDict(result.attributes))
    return failure();

  return success();
}

//===----------------------------------------------------------------------===//
// Auto-generated Definitions
//===----------------------------------------------------------------------===//

// Include enum definitions.
#include "eco/EcoEnums.cpp.inc"

#define GET_OP_CLASSES
#include "eco/EcoOps.cpp.inc"
