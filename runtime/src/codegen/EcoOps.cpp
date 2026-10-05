//===- EcoOps.cpp - Eco dialect operations --------------------------------===//
//
// This file implements the operations in the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoOps.h"

#include <cstdlib>
#include "EcoDialect.h"
#include "EcoTypes.h"
#include "../allocator/Heap.hpp"  // NULL_CONS_MAX (HEAP_044)

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

LogicalResult AllocateCtorOp::verify() {
  // The 0-field form is forbidden for the same reason as 0-field
  // eco.construct.custom (CGEN_079 / HEAP_044): nullary ctors are embedded
  // null-cons constants, never heap objects.
  if (getSize() == 0 && getScalarBytes() == 0) {
    return emitOpError(
        "0-field ctor allocation is forbidden (CGEN_079): nullary "
        "constructors are embedded null-cons constants — emit "
        "eco.constant.null_cons instead");
  }
  return success();
}

LogicalResult CustomConstructOp::verify() {
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

    // B14: Bool is boxed in heap fields (REP_CLOSURE_001 / FORBID_CLOSURE_001).
    if (fieldType.isInteger(1))
      return emitOpError("field ") << i
             << " has i1 type: Bool must be boxed to !eco.value before construction";

    switch (kind) {
      case 0:  // Boxed HPointer (!eco.value)
        // Aggregate-typed fields are accepted under kind=0: the Eco→LLVM
        // construct lowering boxes them via eco.to_heap so the slot ends up
        // holding a boxed HPointer like any other kind=0 field.
        if (!isa<eco::ValueType, eco::Tuple2Type, eco::Tuple3Type,
                 eco::RecordType, eco::CustomType, eco::ConsType>(fieldType)) {
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

LogicalResult RecordConstructOp::verify() {
  // The fields operand list may contain GC live roots appended after the
  // actual fields by EcoGCPrepare. The first `field_count` entries are
  // fields; any beyond that are live roots (always !eco.value).
  int64_t fieldCount = getFieldCount();
  if (static_cast<int64_t>(getFields().size()) < fieldCount) {
    return emitOpError("number of operands (")
           << getFields().size()
           << ") must be at least field_count attribute ("
           << fieldCount << ")";
  }

  // The GC record scan reads per-slot kinds for the first 32 slots only;
  // a record with more fields would leave boxed fields unscanned.
  if (fieldCount > 32) {
    return emitOpError("field_count (")
           << fieldCount
           << ") exceeds Record's 32-slot GC scan limit";
  }

  // Verify the 2-bit kind per slot matches the field SSA types
  // (REP_BOUNDARY_002). The store lowering dispatches on the operand type
  // while the GC trusts the bitmap: a kind=boxed slot holding a raw
  // primitive is scanned as a pointer (heap corruption), and a typed slot
  // holding a boxed value is skipped by the GC (stale pointer). This is
  // the check that would have caught the 32-bit Bitwise wraparound in the
  // front-end's bitmapSetKind (>16-field records zeroed their low kinds).
  int64_t unboxedBits = getUnboxedBitmap();
  auto fields = getFields();
  for (int64_t i = 0; i < fieldCount; i++) {
    const uint64_t shift = 2ULL * static_cast<uint64_t>(i);
    const uint64_t kind =
        i < 32 ? (static_cast<uint64_t>(unboxedBits) >> shift) & 0x3ULL : 0;
    Type fieldType = fields[i].getType();

    // B14: Bool is boxed in heap fields (REP_CLOSURE_001 / FORBID_CLOSURE_001).
    if (fieldType.isInteger(1))
      return emitOpError("field ") << i
             << " has i1 type: Bool must be boxed to !eco.value before construction";

    switch (kind) {
      case 0:  // Boxed HPointer (!eco.value)
        // Aggregate-typed fields are accepted under kind=0: the Eco→LLVM
        // construct lowering boxes them via eco.to_heap so the slot ends up
        // holding a boxed HPointer like any other kind=0 field. Bool (i1)
        // is rejected above: the front end boxes it to !eco.value first.
        if (!isa<eco::ValueType, eco::Tuple2Type, eco::Tuple3Type,
                 eco::RecordType, eco::CustomType, eco::ConsType>(fieldType)) {
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

/// Slots of a legacy u64 closure bitmap the front end can describe exactly:
/// it computes the word with Elm Int arithmetic (exact to 2^53) and records no
/// kind at index >= 26 (Types.maxTypedSlots), so those slots read 0 there.
static constexpr unsigned kLegacyClosureBitmapSlots = 26;

/// CGEN_003: every closure operand is !eco.value, i64, f64 or i16 (Bool is
/// boxed, REP_CLOSURE_001; closure ops never take aggregates). `slot_kinds`,
/// when present, must have one entry per operand equal to the operand's type
/// kind. A legacy u64 attribute is advisory and verified only for the slots it
/// can describe. It is DefaultValued and stored as a property, so the parser
/// materialises an absent one as 0 and hasAttr cannot tell the two apart: a
/// zero word carries no claim (absent = derive from operand types, §S.5) and
/// is not checked; a non-zero word must agree slot by slot.
static LogicalResult verifyClosureKinds(Operation *op, ValueRange operands,
                                        std::optional<ArrayRef<int8_t>> kinds,
                                        StringRef legacyName, const char *what) {
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
  if (kinds) {
    if (kinds->size() != operands.size())
      return op->emitOpError("slot_kinds length (") << kinds->size()
             << ") != " << what << " count (" << operands.size() << ")";
    for (auto [i, v] : llvm::enumerate(operands)) {
      int k = (*kinds)[i];
      if (k < 0 || k > 3 || uint8_t(k) != operandKind(v.getType()))
        return op->emitOpError(what) << " " << i << " slot_kinds " << k
               << " does not match SSA type " << v.getType();
    }
  }
  uint64_t w = 0;
  if (!legacyName.empty() && op->hasAttr(legacyName))
    w = cast<IntegerAttr>(op->getAttr(legacyName)).getValue().getZExtValue();
  if (w != 0) {
    const unsigned n = static_cast<unsigned>(operands.size());
    const unsigned described = std::min(n, kLegacyClosureBitmapSlots);
    if (described < 32 && (w >> (2 * described)) != 0)
      return op->emitOpError(legacyName) << " has bits set beyond " << what
             << " count";
    for (unsigned i = 0; i < described; ++i)
      if (((w >> (2 * i)) & 3) != operandKind(operands[i].getType()))
        return op->emitOpError(legacyName) << " slot " << i
               << " disagrees with SSA type " << operands[i].getType();
  }
  return success();
}

/// HEAP_078 limits: stage arity <= CLOSURE_MAX_ARITY (2047), so at most 2046
/// captured values (a PAP has at least one parameter left).
static constexpr int64_t kClosureMaxArity = Elm::CLOSURE_MAX_ARITY;
static constexpr int64_t kClosureMaxCaptures = Elm::CLOSURE_MAX_ARITY - 1;

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

  // Per-slot kinds (CGEN_003). B22: only the real captures; getCaptured()
  // also holds the GC-root operands EcoGCPrepare appends.
  auto realCaptured = getCaptured().take_front(static_cast<size_t>(numCaptured));
  if (failed(verifyClosureKinds(getOperation(), realCaptured, getSlotKinds(),
                                "unboxed_bitmap", "capture")))
    return failure();

  // CGEN_057 kernel existence check is now in verifySymbolUses (O(1) cached).
  return success();
}

LogicalResult PapExtendOp::verify() {
  auto allNewargs = getNewargs();

  // Subtract appended GC roots from newargs count.
  unsigned rootCount = getGCRootsCountAttr(getOperation());
  // Roots are appended to the full operand list (closure + newargs + roots),
  // so the real newargs count is allNewargs.size() - rootCount.
  size_t realNewargsCount = allNewargs.size() - rootCount;

  if (realNewargsCount > static_cast<size_t>(kClosureMaxArity)) {
    return emitOpError("newargs count (")
           << realNewargsCount
           << ") exceeds closure arity limit (" << kClosureMaxArity << ")";
  }

  // Per-slot kinds (CGEN_003) and REP_CLOSURE_001, real newargs only.
  if (failed(verifyClosureKinds(getOperation(),
                                allNewargs.take_front(realNewargsCount),
                                getSlotKinds(), "newargs_unboxed_bitmap",
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
  auto unboxedBitmaps = getUnboxedBitmaps();   // optional (legacy, advisory)
  auto slotKinds = getSlotKinds();             // optional
  auto captureCounts = getCaptureCounts();
  auto crossEdges = getCrossEdges();

  // Per-sibling arrays must all have size numSiblings.
  if (functions.size() != numSiblings ||
      fastEvaluators.size() != numSiblings ||
      arities.size() != numSiblings ||
      numCaptured.size() != numSiblings ||
      (unboxedBitmaps && unboxedBitmaps->size() != numSiblings) ||
      (slotKinds && slotKinds->size() != numSiblings) ||
      captureCounts.size() != numSiblings) {
    return emitOpError("per-sibling attribute arrays must all have length ")
           << numSiblings;
  }
  if (slotKinds)
    for (size_t i = 0; i < numSiblings; ++i)
      if (!isa<DenseI8ArrayAttr>((*slotKinds)[i]))
        return emitOpError("slot_kinds[") << i << "] must be a DenseI8ArrayAttr";
  auto siblingKinds = [&](size_t i) -> std::optional<ArrayRef<int8_t>> {
    if (!slotKinds) return std::nullopt;
    return cast<DenseI8ArrayAttr>((*slotKinds)[i]).asArrayRef();
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
    if (auto ks = siblingKinds(consumer)) {
      if (slot < static_cast<int64_t>(ks->size()) && (*ks)[slot] != 0)
        return emitOpError("cross-edge consumer ") << consumer
               << " slot " << slot << " must be boxed (slot_kinds is "
               << int((*ks)[slot]) << ")";
    } else if (unboxedBitmaps && slot < kLegacyClosureBitmapSlots) {
      // A zero legacy word carries no claim (see verifyClosureKinds); a
      // non-zero bit pair at the slot is a typed claim on a sibling capture.
      uint64_t bitmap = cast<IntegerAttr>((*unboxedBitmaps)[consumer]).getInt();
      if (((bitmap >> (2ULL * static_cast<uint64_t>(slot))) & 0x3ULL) != 0)
        return emitOpError("cross-edge consumer ") << consumer
               << " slot " << slot << " must be boxed (unboxed_bitmap bit is set)";
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
  // Non-sibling captures occupy the low slots [0..cc); sibling captures
  // (cross-edge consumers) live at the remaining slots and are boxed.
  auto captures = getOperands().take_front(totalCaptures);
  size_t operandCursor = 0;
  for (size_t i = 0; i < numSiblings; ++i) {
    int64_t cc = cast<IntegerAttr>(captureCounts[i]).getInt();
    auto sibCaptures = captures.slice(operandCursor, static_cast<size_t>(cc));
    if (unboxedBitmaps) {
      // Legacy per-sibling word: advisory, verified for the slots it can
      // describe when non-zero (same rule as verifyClosureKinds).
      uint64_t w = cast<IntegerAttr>((*unboxedBitmaps)[i]).getInt();
      const unsigned described = w == 0 ? 0u :
          std::min<unsigned>(static_cast<unsigned>(cc), kLegacyClosureBitmapSlots);
      for (unsigned j = 0; j < described; ++j)
        if (((w >> (2 * j)) & 3) != operandKind(sibCaptures[j].getType()))
          return emitOpError("sibling ") << i << " capture " << j
                 << " unboxed_bitmap kind " << ((w >> (2 * j)) & 3)
                 << " disagrees with SSA type " << sibCaptures[j].getType();
    }
    if (auto ks = siblingKinds(i)) {
      // plans/wide-object-tail-kind-words-phase-2.md step 2.1: one kind per
      // closure slot, length num_captured; the non-sibling captures are
      // checked against their operand types, the sibling slots are boxed.
      int64_t cap = cast<IntegerAttr>(numCaptured[i]).getInt();
      if (static_cast<int64_t>(ks->size()) != cap)
        return emitOpError("slot_kinds[") << i << "] length (" << ks->size()
               << ") != num_captured (" << cap << ")";
      if (failed(verifyClosureKinds(getOperation(), sibCaptures,
                                    ks->take_front(static_cast<size_t>(cc)),
                                    StringRef(), "capture")))
        return failure();
      for (int64_t j = cc; j < cap; ++j)
        if ((*ks)[j] != 0)
          return emitOpError("sibling ") << i << " slot " << j
                 << " holds a sibling closure and must be boxed (slot_kinds is "
                 << int((*ks)[j]) << ")";
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

  // Subtract appended GC roots from operand count for verification.
  unsigned rootCount = getGCRootsCountAttr(getOperation());
  unsigned realOperandCount = operands.size() - rootCount;

  // kernel-opt-12: the purity attr's structural preconditions. The rootCount
  // arm is the only place the attr+roots combination is caught; the module
  // verifier the PassManager runs after every pass makes it fire immediately
  // after EcoGCPrepare if the strip there is ever removed.
  if ((*this)->hasAttr(kCseSafeAttrName)) {
    if (!calleeAttr)
      return emitOpError("'eco.cse_safe' is only valid on a direct call "
                         "(requires the 'callee' attribute)");
    auto musttail = getMusttail();
    if (musttail && *musttail)
      return emitOpError("'eco.cse_safe' must not be set on a musttail call");
    if (rootCount != 0)
      return emitOpError("'eco.cse_safe' must not survive GC root attachment "
                         "(a purity consumer is running after EcoGCPrepare)");
  }

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
// accepts an aggregate-typed or i1 operand which the construct lowering boxes
// via eco.to_heap — there the projected !eco.value is NOT the operand, so the
// fold must bail. Type equality is exactly that test.
//
// The index guard is against the DECLARED field count, never fields.size():
// EcoGCPrepare splices root operands into the same variadic after the declared
// fields, and a fold must never return a root.

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
  // CGEN_029: !eco.closure_env operands are rejected; closure realisation
  // goes through eco.make.closure.
  Type valTy = getValue().getType();
  if (isa<eco::ClosureEnvType>(valTy)) {
    return emitOpError("eco.to_heap rejects !eco.closure_env operands; use "
                       "eco.make.closure to realise heap closures (CGEN_029)");
  }
  // The TableGen Eco_DataAggregate constraint already restricts to
  // tuple2/3/record/custom/cons; this is just defensive belt-and-braces.
  if (!isa<eco::Tuple2Type, eco::Tuple3Type, eco::RecordType,
           eco::CustomType, eco::ConsType>(valTy)) {
    return emitOpError("operand must be a data aggregate, got ") << valTy;
  }
  return success();
}

LogicalResult FromHeapOp::verify() {
  // CGEN_063 mirror of CGEN_029: !eco.closure_env results are rejected;
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
// Value-level Aggregate GCRootCarrier impls
//===----------------------------------------------------------------------===//
// Only the boundary ops (eco.to_heap, eco.make.closure) are GCRootCarriers;
// the value-level eco.make.* ops are Pure with no live_roots.

ValueRange ToHeapOp::getGCRoots() { return getLiveRoots(); }
void ToHeapOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
}

ValueRange MakeClosureOp::getGCRoots() { return getLiveRoots(); }
void MakeClosureOp::setGCRoots(ValueRange newRoots) {
    getLiveRootsMutable().clear(); getLiveRootsMutable().append(newRoots);
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
