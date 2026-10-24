//===- EcoOps.cpp - Eco dialect operations --------------------------------===//
//
// This file implements the operations in the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoOps.h"

#include <cstdlib>
#include "EcoDialect.h"
#include "../allocator/Heap.hpp"  // NULL_CONS_MAX (HEAP_044)

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

/// Helper: verify a FlatSymbolRefAttr resolves to a symbol in the module.
static LogicalResult verifySymRef(Operation *op, FlatSymbolRefAttr sym,
                                  SymbolTableCollection &symbolTable,
                                  StringRef desc) {
  if (!sym) return success();
  if (!symbolTable.lookupNearestSymbolFrom(op, sym))
    return op->emitOpError("references undefined ") << desc << " '" << sym.getValue() << "'";
  return success();
}

LogicalResult CallOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  auto callee = getCalleeAttr();
  if (!callee)
    return success();
  if (failed(verifySymRef(*this, callee, symbolTable, "function")))
    return failure();
  // SD-6 (REP_ABI_001, CGEN_011): a direct call's operand and result types
  // must be the callee's func.func signature exactly; otherwise the mismatch
  // surfaces only as LLVM's "Calling a function with a bad signature!" (or
  // not at all). A callee that is already an llvm.func (mid-lowering) is not
  // checked here.
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

LogicalResult PapCreateOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (failed(verifySymRef(*this, getFunctionAttr(), symbolTable, "function")))
    return failure();
  // CGEN_057: kernel functions must have declarations
  auto funcName = getFunctionAttr().getValue();
  if (funcName.starts_with("Elm_Kernel_")) {
    if (!symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, getFunctionAttr()))
      return emitOpError("kernel function '") << funcName
             << "' has no func.func declaration; compiler must emit one (CGEN_057)";
  }
  return success();
}

/// Where a closure value came from: the papCreate's evaluator and arity, and
/// how many of its parameters are already filled (captures plus the newargs
/// of partial typed extends on the way).
namespace {
struct PapOrigin {
  FlatSymbolRefAttr function;
  int64_t arity = 0;
  size_t offset = 0;
};
/// Found: `origin` is set. Cycle: the value only reaches itself through
/// block arguments (no offset added), so it says nothing on its own.
enum class TraceResult { Unknown, Found, Cycle };
} // namespace

static TraceResult traceClosureOrigin(Value clo, PapOrigin &origin,
                                      llvm::SmallPtrSetImpl<Value> &visiting);

/// The values a block argument receives: from the eco.jumps to its joinpoint
/// (when it is a joinpoint parameter) or from the branch terminators of its
/// predecessor blocks. Returns false when some incoming value is unknown.
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

LogicalResult PapExtendOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (auto fast = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator"))
    if (failed(verifySymRef(*this, fast, symbolTable, "fast evaluator")))
      return failure();

  // CGEN_CLOSURE_005: a typed papExtend stamped with `_fast_evaluator` and
  // `_capture_abi` is lowered (emitFastClosureCall) by loading one value slot
  // per `_capture_abi` entry at that type and calling the fast clone with
  // (captures..., newargs...). So the `_capture_abi` types must equal the
  // fast clone's leading parameter types, element for element; otherwise the
  // mismatch surfaces only as an LLVM signature error, or as a capture read
  // at the wrong kind. Checked when the clone is a func.func in this module.
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

  // CGEN_003: a typed papExtend's real newargs fill evaluator params, so their
  // SSA types must be the target func.func's param types (the closure's slot
  // kinds for uncaptured params come from that signature, and EcoPAPSimplify
  // turns a saturated extend into a direct eco.call with these operands — a
  // mismatch otherwise surfaces only as LLVM's "Calling a function with a bad
  // signature!"). CGEN_056: a saturated typed extend's result type is the
  // evaluator's result type. The evaluator is known from two sources, each
  // checked when present: the `_fast_evaluator` stamp of a saturated site
  // (what emitFastClosureCall calls, with the `_capture_abi` captures first),
  // and the papCreate the closure traces to (traceClosureOrigin: through
  // partial typed extends and through block arguments whose incoming values
  // all trace to the same creation, SD-7). Generic mode is unknown.
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
  // The evaluator (`$cap` for a capturing closure) takes
  // (captures..., params...).
  auto callee = symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, origin.function);
  if (!callee)
    return success();
  size_t nInputs = callee.getFunctionType().getNumInputs();
  if (static_cast<int64_t>(nInputs) != origin.arity)
    return success();  // not a captures+params evaluator layout
  return checkAgainst(callee, "evaluator", origin.offset,
                      saturated && origin.offset + newargs.size() == nInputs);
}

LogicalResult PapCreateGroupOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  auto funcs = getFunctions();
  for (Attribute a : funcs) {
    auto sym = dyn_cast<FlatSymbolRefAttr>(a);
    if (!sym)
      return emitOpError("functions attribute must contain FlatSymbolRefAttr entries");
    if (failed(verifySymRef(*this, sym, symbolTable, "sibling function")))
      return failure();
    // CGEN_057: kernel functions must have declarations
    auto fn = sym.getValue();
    if (fn.starts_with("Elm_Kernel_")) {
      if (!symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, sym))
        return emitOpError("kernel function '") << fn
               << "' has no func.func declaration; compiler must emit one (CGEN_057)";
    }
  }
  // fast_evaluators equals functions (PapCreateGroupOp::verify).
  return success();
}

LogicalResult AllocateClosureOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getFunctionAttr(), symbolTable, "function");
}

LogicalResult MakeClosureOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (failed(verifySymRef(*this, getFunctionAttr(), symbolTable, "function")))
    return failure();
  // Mirror PapCreateOp::verifySymbolUses kernel-existence check (CGEN_057):
  // kernel functions must have a func.func declaration in the module.
  auto funcName = getFunctionAttr().getValue();
  if (funcName.starts_with("Elm_Kernel_")) {
    if (!symbolTable.lookupNearestSymbolFrom<func::FuncOp>(*this, getFunctionAttr()))
      return emitOpError("kernel function '") << funcName
             << "' has no func.func declaration; compiler must emit one (CGEN_057)";
  }
  return success();
}

LogicalResult GlobalOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (auto init = getInitializerAttr())
    return verifySymRef(*this, init, symbolTable, "initializer");
  return success();
}

LogicalResult LoadGlobalOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getGlobalAttr(), symbolTable, "global");
}

LogicalResult StoreGlobalOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getGlobalAttr(), symbolTable, "global");
}

//===----------------------------------------------------------------------===//
// Operation Verifiers
//===----------------------------------------------------------------------===//

LogicalResult CaseOp::verify() {
  // Verify that the number of alternative regions matches the number of tags.
  if (getTags().size() != getAlternatives().size()) {
    return emitOpError("number of tags (")
           << getTags().size()
           << ") must match number of alternative regions ("
           << getAlternatives().size() << ")";
  }

  // Get case_kind attribute - REQUIRED
  auto caseKindAttr = getCaseKindAttr();
  if (!caseKindAttr) {
    return emitOpError("requires 'case_kind' attribute");
  }
  StringRef caseKind = caseKindAttr.getValue();

  // Validate case_kind is known
  if (caseKind != "ctor" && caseKind != "int" &&
      caseKind != "chr" && caseKind != "str" && caseKind != "bool") {
    return emitOpError("invalid case_kind '") << caseKind
           << "'; expected one of 'ctor', 'int', 'chr', 'str', 'bool'";
  }

  // Validate scrutinee type / case_kind compatibility
  Type scrutineeType = getScrutinee().getType();

  if (isa<eco::ValueType>(scrutineeType)) {
    // !eco.value: allow case_kind in {"ctor", "str"}
    if (caseKind != "ctor" && caseKind != "str") {
      return emitOpError("!eco.value scrutinee requires case_kind 'ctor' or 'str', got '")
             << caseKind << "'";
    }
  } else if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
    unsigned width = intType.getWidth();

    if (width == 1) {
      // i1 (Bool): allow case_kind in {"bool", "ctor"}
      // "ctor" for Chain lowering compatibility, "bool" for Bool fanout
      if (caseKind != "bool" && caseKind != "ctor") {
        return emitOpError("i1 scrutinee requires case_kind 'bool' or 'ctor', got '")
               << caseKind << "'";
      }
      // Validate tags are 0 or 1 for i1
      for (int64_t tag : getTags()) {
        if (tag != 0 && tag != 1) {
          return emitOpError("i1 scrutinee requires tags in {0, 1}, got ")
                 << tag;
        }
      }
    } else if (width == 64) {
      // i64 (Int): require case_kind "int"
      if (caseKind != "int") {
        return emitOpError("i64 scrutinee requires case_kind 'int', got '")
               << caseKind << "'";
      }
    } else if (width == 16) {
      // i16 (Char): require case_kind "chr"
      if (caseKind != "chr") {
        return emitOpError("i16 scrutinee requires case_kind 'chr', got '")
               << caseKind << "'";
      }
    } else {
      return emitOpError("scrutinee must be !eco.value, i1, i16, or i64, got ")
             << scrutineeType;
    }
  } else {
    return emitOpError("scrutinee must be !eco.value, i1, i16, or i64, got ")
           << scrutineeType;
  }

  // Verify string_patterns for case_kind="str"
  if (caseKind == "str") {
    auto patternsAttr = getStringPatternsAttr();
    if (!patternsAttr) {
      return emitOpError("case_kind 'str' requires 'string_patterns' attribute");
    }

    size_t numAlts = getAlternatives().size();
    size_t numPatterns = patternsAttr.size();

    // string_patterns should have N-1 elements (last alt is default)
    if (numPatterns + 1 != numAlts) {
      return emitOpError("string_patterns has ")
             << numPatterns << " elements but expected " << (numAlts - 1)
             << " (one per non-default alternative)";
    }

    // Verify all elements are StringAttr
    for (Attribute attr : patternsAttr) {
      if (!isa<StringAttr>(attr)) {
        return emitOpError("string_patterns must contain only string attributes");
      }
    }
  }

  // CGEN_010 invariant: eco.case is SSA value-producing with explicit result types.
  // eco.case must have at least one result (no void cases).
  auto resultTypes = getResultTypes();
  if (resultTypes.empty()) {
    return emitOpError("must have at least one result type; void cases are not supported");
  }

  // Verify that each region has exactly one block with eco.yield terminator.
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

    // CGEN_028: Alternatives must terminate with eco.yield only.
    // eco.return, eco.jump, eco.crash are forbidden inside eco.case alternatives.
    if (!isa<YieldOp>(terminator)) {
      return emitOpError("alternative ")
             << altIndex << " must terminate with 'eco.yield', got '"
             << terminator->getName() << "'";
    }

    // Validate eco.yield operand types match case result types
    auto yieldOp = cast<YieldOp>(terminator);
    auto yieldTypes = yieldOp.getOperandTypes();
    if (yieldTypes.size() != resultTypes.size()) {
      return emitOpError("alternative ")
             << altIndex << " eco.yield has " << yieldTypes.size()
             << " operands but eco.case has " << resultTypes.size() << " results";
    }
    for (size_t i = 0; i < resultTypes.size(); ++i) {
      if (yieldTypes[i] != resultTypes[i]) {
        // ECO_LAX_CASE_VERIFY=1: demote to a warning so invalid IR can be
        // dumped for diagnosis (--emit=mlir); never set in real builds.
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

LogicalResult YieldOp::verify() {
  // CGEN_053: eco.yield may only appear inside eco.case alternative regions.
  // HasParent<"::eco::CaseOp"> trait handles this, but we double-check.
  auto parentCaseOp = (*this)->getParentOfType<CaseOp>();
  if (!parentCaseOp) {
    return emitOpError("must be inside an eco.case alternative region");
  }

  // Verify yield types match parent case result types
  auto caseResultTypes = parentCaseOp.getResultTypes();
  auto yieldTypes = getOperandTypes();

  if (yieldTypes.size() != caseResultTypes.size()) {
    return emitOpError("has ") << yieldTypes.size()
           << " operands but parent eco.case has "
           << caseResultTypes.size() << " results";
  }

  for (size_t i = 0; i < caseResultTypes.size(); ++i) {
    if (yieldTypes[i] != caseResultTypes[i]) {
      // ECO_LAX_CASE_VERIFY=1: diagnostic dumps only (see CaseOp verifier).
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


LogicalResult JoinpointOp::verify() {
  // Verify that the body region is not empty.
  if (getBody().empty()) {
    return emitOpError("body region must not be empty");
  }
  return success();
}

LogicalResult ConstantNullConsOp::verify() {
  // 10-bit null_cons_idx capacity (HEAP_044). The Elm side crashes first with
  // a better message (Compiler.Data.CtorTag.checkNullConsCapacity); this is
  // the MLIR-level backstop.
  if (getTag() < 0 || getTag() > static_cast<int64_t>(NULL_CONS_MAX)) {
    return emitOpError("null-cons tag ")
           << getTag() << " outside the 10-bit null_cons_idx range [0, "
           << NULL_CONS_MAX << "] (HEAP_044)";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// Custom/Record slot kinds (plans/wide-object-tail-kind-words-phase-3.md 3B.2)
//===----------------------------------------------------------------------===//

/// 3D-D3: the u64 kind bitmaps left the op definitions in Phase 3D; a leftover
/// one would be carried as an unregistered discardable attribute and silently
/// ignored (a stale pre-3C .mlir cache, or a missed fixture). Reject it.
static LogicalResult rejectStaleBitmapAttr(Operation *op) {
  for (StringRef n : {"unboxed_bitmap", "newargs_unboxed_bitmap", "unboxed_bitmaps"})
    if (op->hasAttr(n))
      return op->emitOpError("stale attribute '") << n
             << "': regenerate the MLIR (slot_kinds replaced it; "
                "plans/wide-object-tail-kind-words.md Phase 3D)";
  return success();
}

/// Kind of a Custom/Record field's MLIR type (= codegen slotKindOf):
/// i64 -> 1 Int, f64 -> 2 Float, i16 -> 3 Char, everything else -> 0 boxed.
static uint8_t fieldKind(Type t) {
  if (t.isInteger(64)) return 1;
  if (t.isF64()) return 2;
  if (t.isInteger(16)) return 3;
  return 0;
}


/// Checks the operand types of `slots` (the fields) and
/// `slot_kinds` (one entry per field) against them (REP_BOUNDARY_002).
static LogicalResult verifySlotKinds(Operation *op, TypeRange slots,
                                     ArrayRef<int8_t> kinds, StringRef what) {
  if (kinds.size() != slots.size())
    return op->emitOpError("slot_kinds has ") << kinds.size()
           << " entries but there are " << slots.size() << " " << what << "s";
  for (unsigned i = 0; i < slots.size(); ++i) {
    Type t = slots[i];
    // B14: Bool is boxed in heap fields (REP_CLOSURE_001 / FORBID_CLOSURE_001).
    if (t.isInteger(1))
      return op->emitOpError(what) << " " << i
             << " has i1 type: Bool must be boxed to !eco.value before construction";
    const uint8_t k = fieldKind(t);
    // Aggregate-typed fields are boxed (kind 0): the construct lowering boxes
    // them via eco.to_heap so the slot holds an HPointer like any boxed field.
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

LogicalResult CustomConstructOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  // Nullary ctors are embedded null-cons constants (HEAP_044,
  // plans/null-cons-hpointer-embedding.md §2.3): a 0-field construct would
  // mint a second (heap) representation and silently break the word-equality
  // fast paths. The compiler emits eco.constant.null_cons instead.
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

  // HEAP_019: slots 0..23 in the header bitmap, the rest in <= 63 tail kind words.
  if (size > static_cast<int64_t>(Elm::CUSTOM_MAX_FIELDS)) {
    return emitOpError("size (") << size << ") exceeds Custom's "
           << Elm::CUSTOM_MAX_FIELDS << "-field limit (HEAP_019)";
  }

  return verifySlotKinds(getOperation(), getFields().getTypes(),
                         getSlotKinds(), "field");
}

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

  // HEAP_019: 32 header slots + <= 63 tail kind words; 2047 (not 2048) so the
  // record-alias constructor (arity = field count) fits CLOSURE_MAX_ARITY.
  if (fieldCount > static_cast<int64_t>(Elm::RECORD_MAX_FIELDS)) {
    return emitOpError("field_count (") << fieldCount << ") exceeds Record's "
           << Elm::RECORD_MAX_FIELDS << "-field limit (HEAP_019)";
  }

  // REP_BOUNDARY_002: the lowering derives the kinds from the operand types,
  // so slot_kinds is a check of the front end's layout, never trusted.
  return verifySlotKinds(getOperation(), getFields().getTypes(),
                         getSlotKinds(), "field");
}

//===----------------------------------------------------------------------===//
// Tuple / Cons header kinds (SD-4, CGEN_026)
//===----------------------------------------------------------------------===//

/// Kind of one Tuple2/Tuple3/Cons-head operand, or failure. The lowerings
/// copy `unboxed_bitmap` / `head_kind` straight into the heap header but store
/// each field by its SSA type, so the two must agree or the GC traces a raw
/// primitive as a pointer (or skips a real one). Bool (i1) never reaches a
/// heap field (CGEN_009, REP_CLOSURE_001); aggregate operands are boxed by the
/// lowering (kind 0), like verifySlotKinds.
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

/// CGEN_026: a tuple's unboxed_bitmap equals the operand kinds, slot i at
/// bits [2i, 2i+1], and has no bits beyond the last slot.
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
           << "; 2 bits per slot: 0 boxed, 1 i64, 2 f64, 3 i16) (CGEN_026)";
  return success();
}

LogicalResult Tuple2ConstructOp::verify() {
  Type slots[2] = {getA().getType(), getB().getType()};
  return verifyTupleBitmap(getOperation(), slots, getUnboxedBitmap());
}

LogicalResult Tuple3ConstructOp::verify() {
  Type slots[3] = {getA().getType(), getB().getType(), getC().getType()};
  return verifyTupleBitmap(getOperation(), slots, getUnboxedBitmap());
}

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
// Closure slot kinds (plans/wide-object-tail-kind-words.md §S.5, Phase 2)
//===----------------------------------------------------------------------===//

/// Kind of a closure operand's MLIR type (same mapping as codegen slotKindOf):
/// i64 -> 1 Int, f64 -> 2 Float, i16 -> 3 Char, everything else -> 0 boxed.
static uint8_t operandKind(Type t) {
  if (t.isInteger(64)) return 1;
  if (t.isF64()) return 2;
  if (t.isInteger(16)) return 3;
  return 0;
}

/// CGEN_003: every closure operand is !eco.value, i64, f64 or i16 (Bool is
/// boxed, REP_CLOSURE_001; closure ops never take aggregates). `slot_kinds`
/// has one entry per operand, equal to the operand's type kind.
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

/// HEAP_078 limits: stage arity <= CLOSURE_MAX_ARITY (2047), so at most 2046
/// captured values (a PAP has at least one parameter left).
static constexpr int64_t kClosureMaxArity = Elm::CLOSURE_MAX_ARITY;
static constexpr int64_t kClosureMaxCaptures = Elm::CLOSURE_MAX_ARITY - 1;

LogicalResult PapCreateOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  // A capturing closure's evaluator is its `$cap` clone, named by both
  // `function` and `_fast_evaluator`.
  if (auto fast = get_fastEvaluatorAttr()) {
    if (fast != getFunctionAttr())
      return emitOpError("_fast_evaluator '") << fast.getValue()
             << "' must equal function '" << getFunction() << "'";
  }

  // Verify that num_captured matches the number of captured operands.
  int64_t numCaptured = getNumCaptured();
  int64_t capturedCount = static_cast<int64_t>(getCaptured().size());
  if (capturedCount != numCaptured) {
    return emitOpError("number of captured operands (")
           << capturedCount
           << ") must match num_captured attribute ("
           << numCaptured << ")";
  }

  // Verify that num_captured is less than arity (PAPs have fewer args than arity).
  int64_t arity = getArity();
  if (numCaptured >= arity) {
    return emitOpError("num_captured (")
           << numCaptured
           << ") must be less than arity ("
           << arity << ")";
  }

  // Closure limits (HEAP_078: n_values:11 | max_values:11).
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

  // Per-slot kinds (CGEN_003).
  if (failed(verifyClosureKinds(getOperation(), getCaptured(), getSlotKinds(),
                                "capture")))
    return failure();

  // CGEN_057 kernel existence check is now in verifySymbolUses (O(1) cached).
  return success();
}

LogicalResult PapExtendOp::verify() {
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  auto newargs = getNewargs();

  if (newargs.size() > static_cast<size_t>(kClosureMaxArity)) {
    return emitOpError("newargs count (")
           << newargs.size()
           << ") exceeds closure arity limit (" << kClosureMaxArity << ")";
  }

  // Per-slot kinds (CGEN_003) and REP_CLOSURE_001.
  if (failed(verifyClosureKinds(getOperation(), newargs, getSlotKinds(),
                                "newarg")))
    return failure();

  // === Generic mode: remaining_arity absent ===
  // In generic mode, saturation is determined at runtime from the closure header.
  // We only enforce local invariants (bitmap, REP_CLOSURE_001) — no definition-chain
  // walk, no arity consistency, no evaluator parameter type checks.
  //
  // Result type may be `!eco.value` (the conservative case, used when the
  // call could be under-saturated and produce a closure HPtr) OR a primitive
  // (i64 / f64 / i16) when Mono types the call as a primitive — i.e. the
  // call applies enough args to land on a primitive return at runtime. In
  // that case the JIT lowers `lowerGenericApply` with a matching
  // `desired_kind` and `eco_apply_closure_eval` writes the primitive
  // straight into the result slot. Well-typed IR cannot reach the
  // under-saturated branch with a primitive result type — the runtime
  // additionally asserts this in debug builds.
  auto remainingArityAttr = getRemainingArityAttr();
  if (!remainingArityAttr) {
    Type resultType = getResult().getType();
    bool isBoxed = isa<eco::ValueType>(resultType);
    bool isPrimitive = resultType.isInteger(64) || resultType.isF64()
                       || resultType.isInteger(16);
    if (!isBoxed && !isPrimitive) {
      return emitOpError("generic-mode papExtend (no remaining_arity) must "
                         "have !eco.value or primitive (i64/f64/i16) result "
                         "type, got ") << resultType;
    }
    return success();
  }

  // Typed mode: remaining_arity present (SD-8, CGEN_056). A partial extend
  // builds a new closure, so its result is !eco.value; a saturated one
  // returns the evaluator's result, an ABI type (REP_ABI_001): !eco.value or
  // i64/f64/i16, never i1 (Bool is boxed, CGEN_009). verifySymbolUses checks
  // the saturated result against the evaluator's signature when it is known.
  // CGEN_057 kernel existence is checked by PapCreateOp::verifySymbolUses (O(1)).
  Type resultType = getResult().getType();
  int64_t remainingArity = remainingArityAttr.getInt();
  if (static_cast<int64_t>(newargs.size()) < remainingArity) {
    if (!isa<eco::ValueType>(resultType))
      return emitOpError("partial typed-mode papExtend (")
             << newargs.size() << " of " << remainingArity
             << " remaining args) must have !eco.value (closure) result type, got "
             << resultType;
  } else if (!isa<eco::ValueType>(resultType) && !resultType.isInteger(64) &&
             !resultType.isF64() && !resultType.isInteger(16)) {
    return emitOpError("saturated typed-mode papExtend must have !eco.value "
                       "or primitive (i64/f64/i16) result type, got ")
           << resultType;
  }
  return success();
}

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

  // Per-sibling arrays must all have size numSiblings.
  if (functions.size() != numSiblings ||
      fastEvaluators.size() != numSiblings ||
      arities.size() != numSiblings ||
      numCaptured.size() != numSiblings ||
      slotKinds.size() != numSiblings ||
      captureCounts.size() != numSiblings) {
    return emitOpError("per-sibling attribute arrays must all have length ")
           << numSiblings;
  }
  // Each sibling's evaluator is its `$cap` clone, named by both arrays.
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

  // cross_edges must be flat triples of I64 attrs.
  if (crossEdges.size() % 3 != 0)
    return emitOpError("cross_edges must be flat triples, length ")
           << crossEdges.size() << " is not a multiple of 3";

  // Count cross-edges per consumer to validate num_captured relation.
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
    // Cross-edge slot must be boxed. slot_kinds has one kind per slot,
    // [0, num_captured): the non-sibling captures [0, capture_counts), then
    // the sibling captures, which are boxed.
    {
      ArrayRef<int8_t> ks = siblingKinds(consumer);
      if (slot < static_cast<int64_t>(ks.size()) && ks[slot] != 0)
        return emitOpError("cross-edge consumer ") << consumer
               << " slot " << slot << " must be boxed (slot_kinds is "
               << int(ks[slot]) << ")";
    }
    crossEdgeInDegree[consumer] += 1;
  }

  // Per-sibling num_captured == capture_counts[i] + cross-edge in-degree for i.
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

  // Per-slot kind check on the captures (mirrors papCreate).
  // Non-sibling captures occupy the low slots [0..cc); sibling captures
  // (cross-edge consumers) live at the remaining slots and are boxed.
  auto captures = getOperands();
  size_t operandCursor = 0;
  for (size_t i = 0; i < numSiblings; ++i) {
    int64_t cc = cast<IntegerAttr>(captureCounts[i]).getInt();
    auto sibCaptures = captures.slice(operandCursor, static_cast<size_t>(cc));
    {
      // plans/wide-object-tail-kind-words-phase-2.md step 2.1: one kind per
      // closure slot, length num_captured; the non-sibling captures are
      // checked against their operand types, the sibling slots are boxed.
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

LogicalResult ProjectClosureOp::verify() {
  // Verify index is non-negative
  int64_t index = getIndex();
  if (index < 0) {
    return emitOpError("index must be non-negative, got ") << index;
  }

  // Operand may be either !eco.value (heap closure) or !eco.closure_env
  // (value-level env, Phase 0 plumbing). The TableGen constraint
  // Eco_ClosureOrEnv enforces this at the operand level; here we just
  // additionally bounds-check the index against the env's capture count
  // when we have a value-level operand.
  Type closureType = getClosure().getType();
  if (auto envTy = dyn_cast<eco::ClosureEnvType>(closureType)) {
    if (static_cast<size_t>(index) >= envTy.getCaptures().size()) {
      return emitOpError("index ") << index
             << " out of range for closure env with "
             << envTy.getCaptures().size() << " captures";
    }
    // Result type must match the env's slot type at this index.
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

LogicalResult CallOp::verify() {
  auto operands = getOperands();
  auto calleeAttr = getCalleeAttr();
  auto remainingArityAttr = getRemainingArityAttr();

  // kernel-opt-12: the purity attr's structural preconditions. A surviving
  // 'eco.cse_safe' after EcoGCPrepare is reported by EcoGCLivenessAudit
  // (validation builds).
  if ((*this)->hasAttr(kCseSafeAttrName)) {
    if (!calleeAttr)
      return emitOpError("'eco.cse_safe' is only valid on a direct call "
                         "(requires the 'callee' attribute)");
    auto musttail = getMusttail();
    if (musttail && *musttail)
      return emitOpError("'eco.cse_safe' must not be set on a musttail call");
  }

  // Case 1: Direct call (callee present)
  if (calleeAttr) {
    if (remainingArityAttr) {
      return emitOpError("must not have both 'callee' and 'remaining_arity' attributes");
    }

    // The signature check against the callee (SD-6) is in verifySymbolUses,
    // which gets a cached symbol table.
    return success();
  }

  // Case 2: Indirect call (closure application)
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

// kernel-opt-12. `eco.cse_safe` present => report NO effects, which licenses
// exactly {merge duplicates, erase if unused}. It does NOT license
// speculation: we implement no ConditionallySpeculatable, so isSpeculatable()
// stays false and LICM-style motion is impossible.
//
// Attr ABSENT => conservative read+write on the default resource. This is the
// correctness-critical branch: declaring the interface at all removes the
// "no interface => unknown effects" default, so every unstamped call must
// claim effects explicitly or the whole program's calls become erasable.
// The equivalence "read+write == no interface" is discharged empirically by
// test/codegen/call_purity_attr_conservative.mlir, which was green BEFORE
// this hunk landed.
void CallOp::getEffects(
    SmallVectorImpl<MemoryEffects::EffectInstance> &effects) {
    if ((*this)->hasAttr(kCseSafeAttrName))
        return; // no effects

    effects.emplace_back(MemoryEffects::Read::get());
    effects.emplace_back(MemoryEffects::Write::get());
}

//===----------------------------------------------------------------------===//
// Projection Folders (kernel-opt-10)
//===----------------------------------------------------------------------===//
//
// eco.project.X %c[i]  where %c = eco.construct.X(..., f_i, ...)   ==>   f_i
// eco.get_tag %c       where %c = eco.construct.custom {tag = N}   ==>   N
//
// Legality: heap aggregates are write-once. The dialect states "No write
// barriers needed due to Elm's immutability" (Ops.td) and RCElimination
// hard-errors on every in-place mutator, so the field operand IS the value the
// projection would load. get_tag's runtime contract (eco_get_tag,
// RuntimeExports.cpp) returns Custom::ctor for a Tag_Custom object, which is
// exactly the construct's `tag` attr.
//
// A fold returns an EXISTING value (or an attr) and never builds IR — the only
// thing fold() may do. Dominance is free: the field is an operand of a defining
// op that already dominates the projection.
//
// The guard demands EXACT SSA type equality. The construct verifiers tie the
// 2-bit slot kind to the field's SSA type, BUT a kind=0 (boxed) slot legally
// accepts an aggregate-typed operand which the construct lowering boxes via
// eco.to_heap — there the projected !eco.value is NOT the operand, so the
// fold must bail. Type equality is exactly that test. (An i1 field is not
// accepted: verifySlotKinds rejects it, Bool is boxed first — B14.)
//
// The index guard is against the DECLARED field count (which the construct
// verifiers tie to fields.size()).

/// Shared guard: index within the declared field count and types identical.
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

OpFoldResult CustomProjectOp::fold(FoldAdaptor) {
    auto ctor = getContainer().getDefiningOp<eco::CustomConstructOp>();
    if (!ctor)
        return {};
    // I64Attr accessors return uint64_t; cast so the guard's <0 arm catches a
    // wrapped absurd value.
    return foldConstructedField(ctor.getFields(),
                                static_cast<int64_t>(ctor.getSize()),
                                static_cast<int64_t>(getFieldIndex()),
                                getResult().getType());
}

OpFoldResult RecordProjectOp::fold(FoldAdaptor) {
    auto ctor = getRecord().getDefiningOp<eco::RecordConstructOp>();
    if (!ctor)
        return {};
    return foldConstructedField(ctor.getFields(),
                                static_cast<int64_t>(ctor.getFieldCount()),
                                static_cast<int64_t>(getFieldIndex()),
                                getResult().getType());
}

OpFoldResult Tuple2ProjectOp::fold(FoldAdaptor) {
    auto ctor = getTuple().getDefiningOp<eco::Tuple2ConstructOp>();
    if (!ctor)
        return {};
    SmallVector<Value, 2> fields{ctor.getA(), ctor.getB()};
    return foldConstructedField(fields, 2, static_cast<int64_t>(getField()),
                                getResult().getType());
}

OpFoldResult Tuple3ProjectOp::fold(FoldAdaptor) {
    auto ctor = getTuple().getDefiningOp<eco::Tuple3ConstructOp>();
    if (!ctor)
        return {};
    SmallVector<Value, 3> fields{ctor.getA(), ctor.getB(), ctor.getC()};
    return foldConstructedField(fields, 3, static_cast<int64_t>(getField()),
                                getResult().getType());
}

/// kernel-opt-10: the two list folds are gated separately because folding a
/// list projection changes the loop shapes EcoListCursor pattern-matches, and
/// the fold+CSE composition crashed that pass's rewrite on the self-compile
/// module (each pass alone was clean). Default OFF; ECO_MLIR_FOLD_LIST=1 is
/// the experiment switch. 137 static sites of the 5,131-site pool.
static bool listFoldsEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_MLIR_FOLD_LIST");
        return e && *e && !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}

OpFoldResult ListHeadOp::fold(FoldAdaptor) {
    if (!listFoldsEnabled())
        return {};
    auto ctor = getList().getDefiningOp<eco::ListConstructOp>();
    if (!ctor)
        return {};
    // head_unboxed/head_kind are redundant here: type equality already implies
    // the slot kind, because ListConstructOp derives head_kind from the head
    // operand's SSA type.
    SmallVector<Value, 1> f{ctor.getHead()};
    return foldConstructedField(f, 1, 0, getResult().getType());
}

OpFoldResult ListTailOp::fold(FoldAdaptor) {
    if (!listFoldsEnabled())
        return {};
    auto ctor = getList().getDefiningOp<eco::ListConstructOp>();
    if (!ctor)
        return {};
    SmallVector<Value, 1> f{ctor.getTail()}; // tail is always !eco.value
    return foldConstructedField(f, 1, 0, getResult().getType());
}

OpFoldResult GetTagOp::fold(FoldAdaptor) {
    auto ctor = getValue().getDefiningOp<eco::CustomConstructOp>();
    if (!ctor)
        return {};
    // eco_get_tag returns Custom::ctor for Tag_Custom — the construct's tag.
    // Returned as an attr; the driver pass materializes the arith.constant.
    return IntegerAttr::get(getResult().getType(),
                            static_cast<int64_t>(ctor.getTag()));
}

//===----------------------------------------------------------------------===//
// Value-level Aggregate Op Verifiers (Phase 0 escape-analysis plumbing)
//===----------------------------------------------------------------------===//

// Helper: verify that `actual` matches the result type's element list `expected`.
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

LogicalResult Tuple2MakeOp::verify() {
  auto resTy = cast<eco::Tuple2Type>(getResult().getType());
  Type expected[2] = { resTy.getFirst(), resTy.getSecond() };
  Type actual[2]   = { getA().getType(), getB().getType() };
  return verifyAggElements(getOperation(), actual, expected, "operand");
}

LogicalResult Tuple3MakeOp::verify() {
  auto resTy = cast<eco::Tuple3Type>(getResult().getType());
  Type expected[3] = { resTy.getFirst(), resTy.getSecond(), resTy.getThird() };
  Type actual[3]   = { getA().getType(), getB().getType(), getC().getType() };
  return verifyAggElements(getOperation(), actual, expected, "operand");
}

LogicalResult RecordMakeOp::verify() {
  auto resTy = cast<eco::RecordType>(getResult().getType());
  SmallVector<Type, 8> actual;
  for (Value f : getFields()) actual.push_back(f.getType());
  return verifyAggElements(getOperation(), actual, resTy.getFields(), "field");
}

LogicalResult CustomMakeOp::verify() {
  auto resTy = cast<eco::CustomType>(getResult().getType());
  SmallVector<Type, 8> actual;
  for (Value f : getFields()) actual.push_back(f.getType());
  if (failed(verifyAggElements(getOperation(), actual, resTy.getFields(), "field")))
    return failure();
  // tag must be non-negative; the heap encoding uses 16 bits so guard
  // against absurd values that would silently truncate at to_heap time.
  int64_t tag = getTag();
  if (tag < 0 || tag > 0xFFFF) {
    return emitOpError("tag (") << tag << ") must fit in 16 bits";
  }
  return success();
}

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
  // Phase 0 constraint: tail is fixed to !eco.value.
  if (!isa<eco::ValueType>(resTy.getTail())) {
    return emitOpError("cons tail element type must be !eco.value in this phase, got ")
           << resTy.getTail();
  }
  return success();
}

LogicalResult ListMapOp::verify() {
  // 2-bit slot kinds, both axes (REP_HEAP_002). Rejecting out-of-range here
  // is the guard against the ListOps::take kind-collapse defect class: a
  // boolean "is boxed" smuggled in as a kind would pass silently otherwise.
  for (auto [what, kind] :
       {std::make_pair("in_kind", getInKind()),
        std::make_pair("out_kind", getOutKind())}) {
    if (kind < 0 || kind > 3) {
      return emitOpError(what) << " must be a 2-bit slot kind (0..3), got "
                               << kind;
    }
  }

  // Captures are only meaningful alongside a devirtualized callee: the
  // expansion passes them positionally to that symbol (captures-then-params),
  // and with no callee there is nothing to pass them to.
  if (!getCalleeAttr() && !getCaptures().empty()) {
    return emitOpError("captures require a callee attribute; a generic-apply "
                       "eco.list.map must have none, got ")
           << getCaptures().size();
  }

  // The callee, when named, must resolve to a real function whose parameter
  // row is exactly captures-then-one-element. Catching arity disagreement
  // here turns a silent miscompile at a licensed site into a verifier error.
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

LogicalResult ClosureEnvMakeOp::verify() {
  auto resTy = cast<eco::ClosureEnvType>(getResult().getType());
  SmallVector<Type, 8> actual;
  for (Value c : getCaptures()) actual.push_back(c.getType());
  return verifyAggElements(getOperation(), actual, resTy.getCaptures(), "capture");
}

LogicalResult ToHeapOp::verify() {
  // CGEN_062: !eco.closure_env operands are rejected; closure realisation
  // goes through eco.make.closure.
  Type valTy = getValue().getType();
  if (isa<eco::ClosureEnvType>(valTy)) {
    return emitOpError("eco.to_heap rejects !eco.closure_env operands; use "
                       "eco.make.closure to realise heap closures (CGEN_062)");
  }
  // The TableGen Eco_DataAggregate constraint already restricts to
  // tuple2/3/record/custom/cons; this is just defensive belt-and-braces.
  if (!isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
           eco::CustomType, eco::ConsType>(valTy)) {
    return emitOpError("operand must be a data aggregate, got ") << valTy;
  }
  if (failed(rejectStaleBitmapAttr(getOperation())))
    return failure();
  // Record/custom: the lowering derives the heap kinds from the element
  // types; slot_kinds (optional, 3D-D2) is a check only.
  const bool isRec = isa<eco::RecordType>(valTy);
  if (isRec || isa<eco::CustomType>(valTy)) {
    ArrayRef<Type> fields = isRec ? cast<eco::RecordType>(valTy).getFields()
                                  : cast<eco::CustomType>(valTy).getFields();
    const uint64_t cap = isRec ? Elm::RECORD_MAX_FIELDS : Elm::CUSTOM_MAX_FIELDS;
    if (fields.size() > cap)
      return emitOpError(isRec ? "record" : "custom") << " aggregate has "
             << fields.size() << " fields; limit is " << cap << " (HEAP_019)";
    // Absent slot_kinds: check the derived kinds, i.e. only that every field
    // type is storable (i1 boxed first, B14).
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

LogicalResult FromHeapOp::verify() {
  // CGEN_063 mirror of CGEN_062: !eco.closure_env results are rejected;
  // closure environments are produced by eco.make.closure_env (or read out
  // of the closure header at lower levels), not from heap-aggregate loads.
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

LogicalResult MakeClosureOp::verify() {
  auto envTy = cast<eco::ClosureEnvType>(getEnv().getType());
  int64_t numCaptures = static_cast<int64_t>(envTy.getCaptures().size());
  int64_t arity = getArity();
  // Mirror PapCreateOp constraints: num_captured < arity, both within
  // closure-header bit limits.
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
  // REP_CLOSURE_001: Bool (i1) must NOT be captured at closure boundary.
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

// Format: eco.case %scrutinee : type [tag0, tag1, ...] -> (result_type0, ...) { attr-dict } { region0 }, { region1 }, ...
void CaseOp::print(OpAsmPrinter &p) {
  p << " " << getScrutinee() << " : " << getScrutinee().getType() << " [";
  llvm::interleaveComma(getTags(), p);
  p << "]";

  // Print result types: -> (type0, type1, ...)
  p << " -> (";
  llvm::interleaveComma(getResultTypes(), p);
  p << ")";

  // Print attr-dict (excluding "tags" which is already printed)
  p.printOptionalAttrDict((*this)->getAttrs(), {"tags"});

  // Print regions
  for (Region &region : getAlternatives()) {
    p << " ";
    p.printRegion(region, /*printEntryBlockArgs=*/false,
                  /*printBlockTerminators=*/true);
    if (&region != &getAlternatives().back())
      p << ",";
  }
}

ParseResult CaseOp::parse(OpAsmParser &parser, OperationState &result) {
  OpAsmParser::UnresolvedOperand scrutinee;
  Type scrutineeType;
  if (parser.parseOperand(scrutinee) ||
      parser.parseColon() ||
      parser.parseType(scrutineeType))
    return failure();

  // Parse [tag0, tag1, ...]
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

  // Parse result types: -> (type0, type1, ...)
  SmallVector<Type> resultTypes;
  if (parser.parseArrow() || parser.parseLParen())
    return failure();

  // Handle empty result list case: -> ()
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

  // Parse optional attr-dict
  if (parser.parseOptionalAttrDict(result.attributes))
    return failure();

  // Parse each region
  for (size_t i = 0; i < tags.size(); ++i) {
    Region *region = result.addRegion();
    if (parser.parseRegion(*region, /*arguments=*/{}, /*argTypes=*/{}))
      return failure();

    // Parse optional comma between regions
    if (i < tags.size() - 1) {
      if (parser.parseComma())
        return failure();
    }
  }

  // Resolve scrutinee operand with the parsed type
  if (parser.resolveOperand(scrutinee, scrutineeType, result.operands))
    return failure();

  return success();
}

//===----------------------------------------------------------------------===//
// Custom Assembly Format: JoinpointOp
//===----------------------------------------------------------------------===//

// Format: eco.joinpoint id(%arg0: type0, %arg1: type1) result_types [type0, ...] { body } continuation { cont }
void JoinpointOp::print(OpAsmPrinter &p) {
  p << " " << getId();

  // Print block arguments if any
  Block &bodyEntry = getBody().front();
  if (!bodyEntry.getArguments().empty()) {
    p << "(";
    llvm::interleaveComma(bodyEntry.getArguments(), p, [&](BlockArgument arg) {
      p << arg << ": " << arg.getType();
    });
    p << ")";
  }

  // Print result_types if present
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

ParseResult JoinpointOp::parse(OpAsmParser &parser, OperationState &result) {
  // Parse the joinpoint id
  int64_t id;
  if (parser.parseInteger(id))
    return failure();
  result.addAttribute("id", parser.getBuilder().getI64IntegerAttr(id));

  // Parse optional block arguments: (arg0: type0, arg1: type1)
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

  // Parse optional result_types [type0, type1, ...]
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

  // Parse body region with arguments
  Region *body = result.addRegion();
  if (parser.parseRegion(*body, regionArgs))
    return failure();

  // Parse "continuation" keyword and continuation region
  if (parser.parseKeyword("continuation"))
    return failure();

  Region *continuation = result.addRegion();
  if (parser.parseRegion(*continuation, /*arguments=*/{}, /*argTypes=*/{}))
    return failure();

  // Parse optional attr-dict
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
