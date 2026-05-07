//===- EcoOps.cpp - Eco dialect operations --------------------------------===//
//
// This file implements the operations in the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoOps.h"
#include "EcoDialect.h"
#include "EcoTypes.h"

#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;

/// Helper to read the eco.gc_roots_count attribute from an operation.
static unsigned getGCRootsCountAttr(Operation *op) {
    auto attr = op->getAttrOfType<IntegerAttr>("eco.gc_roots_count");
    return attr ? attr.getValue().getZExtValue() : 0;
}

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
  if (auto callee = getCalleeAttr())
    return verifySymRef(*this, callee, symbolTable, "function");
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
  if (auto fast = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator"))
    return verifySymRef(*this, fast, symbolTable, "fast evaluator");
  return success();
}

LogicalResult PapExtendOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  if (auto fast = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator"))
    return verifySymRef(*this, fast, symbolTable, "fast evaluator");
  return success();
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
  for (Attribute a : getFastEvaluators()) {
    auto sym = dyn_cast<FlatSymbolRefAttr>(a);
    if (!sym)
      return emitOpError("fast_evaluators attribute must contain FlatSymbolRefAttr entries");
    if (failed(verifySymRef(*this, sym, symbolTable, "sibling fast evaluator")))
      return failure();
  }
  return success();
}

LogicalResult AllocateClosureOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  return verifySymRef(*this, getFunctionAttr(), symbolTable, "function");
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

LogicalResult CustomConstructOp::verify() {
  // The fields operand list may contain GC live roots appended after the
  // actual fields by EcoGCPrepare. The first `size` entries are fields;
  // any beyond that are live roots (always !eco.value).
  int64_t size = getSize();
  if (static_cast<int64_t>(getFields().size()) < size) {
    return emitOpError("number of operands (")
           << getFields().size()
           << ") must be at least size attribute ("
           << size << ")";
  }

  // Custom's 48-bit bitmap supports at most 24 typed slots under 2-bit encoding.
  if (size > 24) {
    return emitOpError("size (")
           << size
           << ") exceeds Custom's 24-slot limit under 2-bit kind encoding";
  }

  // Verify the 2-bit kind per slot matches the field SSA types.
  int64_t unboxedBits = getUnboxedBitmap();
  auto fields = getFields();
  for (int64_t i = 0; i < size; i++) {
    const uint64_t shift = 2ULL * static_cast<uint64_t>(i);
    const uint64_t kind = (static_cast<uint64_t>(unboxedBits) >> shift) & 0x3ULL;
    Type fieldType = fields[i].getType();

    switch (kind) {
      case 0:  // Boxed HPointer (!eco.value)
        if (!isa<eco::ValueType>(fieldType) && !fieldType.isInteger(1)) {
          return emitOpError("field ") << i
                 << " has kind=boxed but non-boxed SSA type " << fieldType;
        }
        break;
      case 1:  // Unboxed Int
        if (!fieldType.isInteger(64)) {
          return emitOpError("field ") << i
                 << " has kind=Int but SSA type " << fieldType;
        }
        break;
      case 2:  // Unboxed Float
        if (!fieldType.isF64()) {
          return emitOpError("field ") << i
                 << " has kind=Float but SSA type " << fieldType;
        }
        break;
      case 3:  // Unboxed Char
        if (!fieldType.isInteger(16)) {
          return emitOpError("field ") << i
                 << " has kind=Char but SSA type " << fieldType;
        }
        break;
    }
  }

  return success();
}

LogicalResult PapCreateOp::verify() {
  // Verify that num_captured matches the number of captured operands.
  // Subtract appended GC roots from operand count.
  int64_t numCaptured = getNumCaptured();
  unsigned rootCount = getGCRootsCountAttr(getOperation());
  int64_t realCapturedCount = static_cast<int64_t>(getCaptured().size()) - rootCount;
  if (realCapturedCount != numCaptured) {
    return emitOpError("number of captured operands (")
           << realCapturedCount
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

  // Verify closure struct limits (6-bit fields).
  if (numCaptured > 63) {
    return emitOpError("num_captured (")
           << numCaptured
           << ") exceeds 6-bit n_values limit (63)";
  }
  if (arity > 63) {
    return emitOpError("arity (")
           << arity
           << ") exceeds 6-bit max_values limit (63)";
  }

  // Verify unboxed_bitmap constraints (2-bit-per-slot kinds).
  uint64_t bitmap = getUnboxedBitmap();

  // Bitmap must fit in 50 bits (runtime Closure struct: unboxed:50, flags:2).
  if (bitmap >= (1ULL << 50)) {
    return emitOpError("unboxed_bitmap exceeds 50-bit capacity");
  }

  // At most 25 typed captures fit in 50 bits (2 bits each).
  if (numCaptured > 25) {
    return emitOpError("num_captured (")
           << numCaptured
           << ") exceeds 25-slot limit under 2-bit kind encoding";
  }

  // No bits should be set beyond num_captured's slot range (2 bits/slot).
  if (numCaptured > 0) {
    const unsigned usedBits = 2 * static_cast<unsigned>(numCaptured);
    if (usedBits < 64) {
      const uint64_t validMask = (1ULL << usedBits) - 1;
      if (bitmap & ~validMask) {
        return emitOpError("unboxed_bitmap has bits set beyond num_captured");
      }
    }
  } else if (bitmap != 0) {
    return emitOpError("unboxed_bitmap must be 0 when num_captured is 0");
  }

  // Verify per-slot kind matches operand SSA type.
  auto captured = getCaptured();
  for (size_t i = 0; i < captured.size(); ++i) {
    const uint64_t shift = 2ULL * i;
    const uint64_t kind = (bitmap >> shift) & 0x3ULL;
    Type ty = captured[i].getType();
    switch (kind) {
      case 0:
        if (!isa<eco::ValueType>(ty)) {
          return emitOpError("capture ") << i
                 << " has kind=boxed but non-boxed SSA type " << ty;
        }
        break;
      case 1:
        if (!ty.isInteger(64)) {
          return emitOpError("capture ") << i
                 << " has kind=Int but SSA type " << ty;
        }
        break;
      case 2:
        if (!ty.isF64()) {
          return emitOpError("capture ") << i
                 << " has kind=Float but SSA type " << ty;
        }
        break;
      case 3:
        if (!ty.isInteger(16)) {
          return emitOpError("capture ") << i
                 << " has kind=Char but SSA type " << ty;
        }
        break;
    }
  }

  // CGEN_057 kernel existence check is now in verifySymbolUses (O(1) cached).

  // REP_CLOSURE_001: Bool (i1) must NOT be captured at closure boundary
  for (size_t i = 0; i < captured.size(); ++i) {
    Type ty = captured[i].getType();
    if (ty.isInteger(1)) {
      return emitOpError("captured Bool (i1) at index ") << i
             << " violates REP_CLOSURE_001: Bool must be boxed to !eco.value at closure boundary";
    }
  }

  return success();
}

LogicalResult PapExtendOp::verify() {
  uint64_t bitmap = getNewargsUnboxedBitmap();
  auto allNewargs = getNewargs();

  // Subtract appended GC roots from newargs count.
  unsigned rootCount = getGCRootsCountAttr(getOperation());
  // Roots are appended to the full operand list (closure + newargs + roots),
  // so the real newargs count is allNewargs.size() - rootCount.
  size_t realNewargsCount = allNewargs.size() - rootCount;

  // Bitmap must fit in 50 bits (runtime Closure struct: unboxed:50, flags:2).
  if (bitmap >= (1ULL << 50)) {
    return emitOpError("newargs_unboxed_bitmap exceeds 50-bit capacity");
  }

  // At most 25 typed newargs fit in 50 bits (2 bits each).
  if (realNewargsCount > 25) {
    return emitOpError("newargs count (")
           << realNewargsCount
           << ") exceeds 25-slot limit under 2-bit kind encoding";
  }

  // No bits should be set beyond newargs size's slot range.
  if (realNewargsCount > 0) {
    const unsigned usedBits = 2 * static_cast<unsigned>(realNewargsCount);
    if (usedBits < 64) {
      const uint64_t validMask = (1ULL << usedBits) - 1;
      if (bitmap & ~validMask) {
        return emitOpError("newargs_unboxed_bitmap has bits set beyond newargs count");
      }
    }
  } else if (bitmap != 0) {
    return emitOpError("newargs_unboxed_bitmap must be 0 when there are no newargs");
  }

  // Verify per-slot kind matches operand SSA type (only real newargs, not roots).
  for (size_t i = 0; i < realNewargsCount; ++i) {
    const uint64_t shift = 2ULL * i;
    const uint64_t kind = (bitmap >> shift) & 0x3ULL;
    Type ty = allNewargs[i].getType();
    switch (kind) {
      case 0:
        if (!isa<eco::ValueType>(ty)) {
          return emitOpError("newarg ") << i
                 << " has kind=boxed but non-boxed SSA type " << ty;
        }
        break;
      case 1:
        if (!ty.isInteger(64)) {
          return emitOpError("newarg ") << i
                 << " has kind=Int but SSA type " << ty;
        }
        break;
      case 2:
        if (!ty.isF64()) {
          return emitOpError("newarg ") << i
                 << " has kind=Float but SSA type " << ty;
        }
        break;
      case 3:
        if (!ty.isInteger(16)) {
          return emitOpError("newarg ") << i
                 << " has kind=Char but SSA type " << ty;
        }
        break;
    }
  }

  // === REP_CLOSURE_001: Bool must not be passed at closure boundary ===
  for (size_t i = 0; i < realNewargsCount; ++i) {
    Type ty = allNewargs[i].getType();
    if (ty.isInteger(1)) {
      return emitOpError("newarg Bool (i1) at index ") << i
             << " violates REP_CLOSURE_001: Bool must be boxed to !eco.value at closure boundary";
    }
  }

  // === Generic mode: remaining_arity absent ===
  // In generic mode, saturation is determined at runtime from the closure header.
  // We only enforce local invariants (bitmap, REP_CLOSURE_001) — no definition-chain
  // walk, no arity consistency, no evaluator parameter type checks.
  // Result type must be !eco.value (since saturation outcome is unknown at compile time).
  auto remainingArityAttr = getRemainingArityAttr();
  if (!remainingArityAttr) {
    // Generic mode: verify result is !eco.value
    if (!isa<eco::ValueType>(getResult().getType())) {
      return emitOpError("generic-mode papExtend (no remaining_arity) must have "
                         "!eco.value result type, got ") << getResult().getType();
    }
    return success();
  }

  // Typed mode: remaining_arity present.
  // CGEN_057 kernel existence is checked by PapCreateOp::verifySymbolUses (O(1)).
  // Signature validation is in CheckEcoClosureCapturesPass.
  return success();
}

LogicalResult PapCreateGroupOp::verify() {
  const size_t numSiblings = getClosures().size();
  if (numSiblings < 2)
    return emitOpError("expects at least 2 siblings, got ") << numSiblings;

  auto functions = getFunctions();
  auto fastEvaluators = getFastEvaluators();
  auto arities = getArities();
  auto numCaptured = getNumCaptured();
  auto unboxedBitmaps = getUnboxedBitmaps();
  auto captureCounts = getCaptureCounts();
  auto crossEdges = getCrossEdges();

  // Per-sibling arrays must all have size numSiblings.
  if (functions.size() != numSiblings ||
      fastEvaluators.size() != numSiblings ||
      arities.size() != numSiblings ||
      numCaptured.size() != numSiblings ||
      unboxedBitmaps.size() != numSiblings ||
      captureCounts.size() != numSiblings) {
    return emitOpError("per-sibling attribute arrays must all have length ")
           << numSiblings;
  }

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
    // Cross-edge slot must be boxed (bit 2*slot of unboxed_bitmap[consumer] == 0).
    uint64_t bitmap = cast<IntegerAttr>(unboxedBitmaps[consumer]).getInt();
    if (((bitmap >> (2ULL * static_cast<uint64_t>(slot))) & 0x3ULL) != 0)
      return emitOpError("cross-edge consumer ") << consumer
             << " slot " << slot << " must be boxed (unboxed_bitmap bit is set)";
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
    if (cap > 63)
      return emitOpError("sibling ") << i << " num_captured (" << cap
             << ") exceeds 6-bit n_values limit (63)";
    if (arity > 63)
      return emitOpError("sibling ") << i << " arity ("
             << arity << ") exceeds 6-bit max_values limit (63)";
    if (cap > 25)
      return emitOpError("sibling ") << i << " num_captured (" << cap
             << ") exceeds 25-slot limit under 2-bit kind encoding";
    uint64_t bitmap = cast<IntegerAttr>(unboxedBitmaps[i]).getInt();
    if (bitmap >= (1ULL << 50))
      return emitOpError("sibling ") << i
             << " unboxed_bitmap exceeds 50-bit capacity";
    totalCaptures += cc;
  }

  // Operand partition: [captures..., roots...].
  unsigned rootCount = getGCRootsCountAttr(getOperation());
  int64_t realOperandCount =
      static_cast<int64_t>(getOperands().size()) - rootCount;
  if (realOperandCount != totalCaptures)
    return emitOpError("operand count minus GC roots (")
           << realOperandCount
           << ") must equal sum of capture_counts ("
           << totalCaptures << ")";

  // Per-slot kind check on the captures prefix (mirrors papCreate).
  auto captures = getOperands().take_front(totalCaptures);
  size_t operandCursor = 0;
  for (size_t i = 0; i < numSiblings; ++i) {
    int64_t cc = cast<IntegerAttr>(captureCounts[i]).getInt();
    uint64_t bitmap = cast<IntegerAttr>(unboxedBitmaps[i]).getInt();
    for (int64_t j = 0; j < cc; ++j) {
      // Non-sibling captures occupy the low slots [0..cc); sibling captures
      // (cross-edge consumers) live at the remaining slots.
      const uint64_t shift = 2ULL * static_cast<uint64_t>(j);
      const uint64_t kind = (bitmap >> shift) & 0x3ULL;
      Type ty = captures[operandCursor + j].getType();
      switch (kind) {
        case 0:
          if (!isa<eco::ValueType>(ty))
            return emitOpError("sibling ") << i << " capture " << j
                   << " has kind=boxed but non-boxed SSA type " << ty;
          break;
        case 1:
          if (!ty.isInteger(64))
            return emitOpError("sibling ") << i << " capture " << j
                   << " has kind=Int but SSA type " << ty;
          break;
        case 2:
          if (!ty.isF64())
            return emitOpError("sibling ") << i << " capture " << j
                   << " has kind=Float but SSA type " << ty;
          break;
        case 3:
          if (!ty.isInteger(16))
            return emitOpError("sibling ") << i << " capture " << j
                   << " has kind=Char but SSA type " << ty;
          break;
      }
      if (ty.isInteger(1))
        return emitOpError("sibling ") << i << " captured Bool (i1) at slot "
               << j << " violates REP_CLOSURE_001: Bool must be boxed";
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

  // Verify closure operand is !eco.value type
  if (!isa<eco::ValueType>(getClosure().getType())) {
    return emitOpError("closure operand must be !eco.value type");
  }

  return success();
}

LogicalResult CallOp::verify() {
  auto operands = getOperands();
  auto calleeAttr = getCalleeAttr();
  auto remainingArityAttr = getRemainingArityAttr();

  // Subtract appended GC roots from operand count for verification.
  unsigned rootCount = getGCRootsCountAttr(getOperation());
  unsigned realOperandCount = operands.size() - rootCount;

  // Case 1: Direct call (callee present)
  if (calleeAttr) {
    if (remainingArityAttr) {
      return emitOpError("must not have both 'callee' and 'remaining_arity' attributes");
    }

    // Signature validation is deferred to CheckEcoClosureCapturesPass to avoid
    // O(N) module walks on every verifier invocation during conversion.
    return success();
  }

  // Case 2: Indirect call (closure application)
  if (realOperandCount == 0) {
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
  unsigned numNewArgs = realOperandCount - 1;

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
// GCRootCarrier Interface Implementations
//===----------------------------------------------------------------------===//

// --- Pattern 1: Ops with dedicated $live_roots segment ---

ValueRange AllocateOp::getGCRoots() { return getLiveRoots(); }
void AllocateOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange AllocateCtorOp::getGCRoots() { return getLiveRoots(); }
void AllocateCtorOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange AllocateStringOp::getGCRoots() { return getLiveRoots(); }
void AllocateStringOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange AllocateClosureOp::getGCRoots() { return getLiveRoots(); }
void AllocateClosureOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange BoxOp::getGCRoots() { return getLiveRoots(); }
void BoxOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange ListConstructOp::getGCRoots() { return getLiveRoots(); }
void ListConstructOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange Tuple2ConstructOp::getGCRoots() { return getLiveRoots(); }
void Tuple2ConstructOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange Tuple3ConstructOp::getGCRoots() { return getLiveRoots(); }
void Tuple3ConstructOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange SafepointOp::getGCRoots() { return getLiveRoots(); }
void SafepointOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

// --- Pattern 2: Ops with roots appended after fields ---

ValueRange RecordConstructOp::getGCRoots() {
    int64_t fieldCount = getFieldCount();
    auto all = getFields();
    if (static_cast<int64_t>(all.size()) <= fieldCount) return {};
    return all.drop_front(fieldCount);
}
void RecordConstructOp::setGCRoots(ValueRange newRoots) {
    int64_t fieldCount = getFieldCount();
    auto all = getFields();
    SmallVector<Value, 8> ops(all.begin(), all.begin() + fieldCount);
    ops.append(newRoots.begin(), newRoots.end());
    getFieldsMutable().clear(); getFieldsMutable().append(ops);
}

ValueRange CustomConstructOp::getGCRoots() {
    int64_t sz = getSize();
    auto all = getFields();
    if (static_cast<int64_t>(all.size()) <= sz) return {};
    return all.drop_front(sz);
}
void CustomConstructOp::setGCRoots(ValueRange newRoots) {
    int64_t sz = getSize();
    auto all = getFields();
    SmallVector<Value, 8> ops(all.begin(), all.begin() + sz);
    ops.append(newRoots.begin(), newRoots.end());
    getFieldsMutable().clear(); getFieldsMutable().append(ops);
}

// --- Pattern 3: Append-pattern ops (Call, PapExtend, PapCreate) ---

ValueRange CallOp::getGCRoots() {
    unsigned rootCount = getGCRootsCountAttr(getOperation());
    if (rootCount == 0) return {};
    auto all = getOperands();
    return all.drop_front(all.size() - rootCount);
}
void CallOp::setGCRoots(ValueRange newRoots) {
    unsigned oldRootCount = getGCRootsCountAttr(getOperation());
    auto all = getOperands();
    unsigned nonRootCount = all.size() - oldRootCount;
    SmallVector<Value, 8> ops(all.begin(), all.begin() + nonRootCount);
    ops.append(newRoots.begin(), newRoots.end());
    getOperation()->setOperands(ops);
    OpBuilder b(getOperation());
    getOperation()->setAttr("eco.gc_roots_count",
        b.getI64IntegerAttr(newRoots.size()));
}

ValueRange PapExtendOp::getGCRoots() {
    unsigned rootCount = getGCRootsCountAttr(getOperation());
    if (rootCount == 0) return {};
    auto all = getOperation()->getOperands();
    return all.drop_front(all.size() - rootCount);
}
void PapExtendOp::setGCRoots(ValueRange newRoots) {
    unsigned oldRootCount = getGCRootsCountAttr(getOperation());
    auto all = getOperation()->getOperands();
    unsigned nonRootCount = all.size() - oldRootCount;
    SmallVector<Value, 8> ops(all.begin(), all.begin() + nonRootCount);
    ops.append(newRoots.begin(), newRoots.end());
    getOperation()->setOperands(ops);
    OpBuilder b(getOperation());
    getOperation()->setAttr("eco.gc_roots_count",
        b.getI64IntegerAttr(newRoots.size()));
}

ValueRange PapCreateOp::getGCRoots() {
    unsigned rootCount = getGCRootsCountAttr(getOperation());
    if (rootCount == 0) return {};
    auto all = getOperation()->getOperands();
    return all.drop_front(all.size() - rootCount);
}
void PapCreateOp::setGCRoots(ValueRange newRoots) {
    unsigned oldRootCount = getGCRootsCountAttr(getOperation());
    auto all = getOperation()->getOperands();
    unsigned nonRootCount = all.size() - oldRootCount;
    SmallVector<Value, 8> ops(all.begin(), all.begin() + nonRootCount);
    ops.append(newRoots.begin(), newRoots.end());
    getOperation()->setOperands(ops);
    OpBuilder b(getOperation());
    getOperation()->setAttr("eco.gc_roots_count",
        b.getI64IntegerAttr(newRoots.size()));
}

ValueRange PapCreateGroupOp::getGCRoots() {
    unsigned rootCount = getGCRootsCountAttr(getOperation());
    if (rootCount == 0) return {};
    auto all = getOperation()->getOperands();
    return all.drop_front(all.size() - rootCount);
}
void PapCreateGroupOp::setGCRoots(ValueRange newRoots) {
    unsigned oldRootCount = getGCRootsCountAttr(getOperation());
    auto all = getOperation()->getOperands();
    unsigned nonRootCount = all.size() - oldRootCount;
    SmallVector<Value, 8> ops(all.begin(), all.begin() + nonRootCount);
    ops.append(newRoots.begin(), newRoots.end());
    getOperation()->setOperands(ops);
    OpBuilder b(getOperation());
    getOperation()->setAttr("eco.gc_roots_count",
        b.getI64IntegerAttr(newRoots.size()));
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

// Include generated OpInterface definitions.
#include "eco/EcoOpInterfaces.cpp.inc"

#define GET_OP_CLASSES
#include "eco/EcoOps.cpp.inc"
