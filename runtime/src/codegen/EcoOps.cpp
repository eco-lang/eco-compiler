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
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

using namespace mlir;
using namespace eco;

//===----------------------------------------------------------------------===//
// Helper Functions for Verifiers
//===----------------------------------------------------------------------===//

namespace {

/// Check if a function symbol exists anywhere in the module (func::FuncOp
/// or any other symbol). Used only for CGEN_057 kernel existence checks.
/// Returns true if a symbol with the given name is found.
static bool symbolExists(Operation *anchor, FlatSymbolRefAttr sym) {
  if (!sym) return false;
  auto module = anchor->getParentOfType<ModuleOp>();
  if (!module) return false;
  // Use SymbolTable::lookupSymbolIn which is O(N) but this is only called
  // for kernel function checks, not for all ops.
  return SymbolTable::lookupNearestSymbolFrom(module, sym) != nullptr;
}

} // end anonymous namespace

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
  // Verify that the number of field operands matches the size attribute.
  int64_t size = getSize();
  if (static_cast<int64_t>(getFields().size()) != size) {
    return emitOpError("number of fields (")
           << getFields().size()
           << ") must match size attribute ("
           << size << ")";
  }

  // Verify that unboxed_bitmap only has bits set for unboxed fields.
  int64_t unboxedBits = getUnboxedBitmap();
  auto fields = getFields();
  for (size_t i = 0; i < fields.size(); i++) {
    bool bitmapSaysUnboxed = (unboxedBits & (1LL << i)) != 0;
    Type fieldType = fields[i].getType();

    // Check if field type is actually unboxed (primitive type).
    bool isUnboxedType = fieldType.isInteger(64) ||  // i64 int
                         fieldType.isF64() ||         // f64 float
                         fieldType.isInteger(16) ||   // i16 char
                         fieldType.isInteger(1);      // i1 bool

    if (bitmapSaysUnboxed && !isUnboxedType) {
      return emitOpError("unboxed_bitmap bit ")
             << i << " is set but field has boxed type "
             << fieldType << "; only primitive types can be unboxed";
    }
  }

  return success();
}

LogicalResult PapCreateOp::verify() {
  // Verify that num_captured matches the number of captured operands.
  int64_t numCaptured = getNumCaptured();
  if (static_cast<int64_t>(getCaptured().size()) != numCaptured) {
    return emitOpError("number of captured operands (")
           << getCaptured().size()
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

  // Verify unboxed_bitmap constraints.
  uint64_t bitmap = getUnboxedBitmap();

  // Bitmap must fit in 52 bits (runtime Closure struct constraint).
  if (bitmap >= (1ULL << 52)) {
    return emitOpError("unboxed_bitmap exceeds 52-bit capacity");
  }

  // No bits should be set beyond num_captured.
  if (numCaptured > 0) {
    uint64_t validMask = (1ULL << numCaptured) - 1;
    if (bitmap & ~validMask) {
      return emitOpError("unboxed_bitmap has bits set beyond num_captured");
    }
  } else if (bitmap != 0) {
    return emitOpError("unboxed_bitmap must be 0 when num_captured is 0");
  }

  // Verify bitmap matches operand types.
  auto captured = getCaptured();
  for (size_t i = 0; i < captured.size(); ++i) {
    bool isBitSet = (bitmap >> i) & 1;
    bool isUnboxedType = !isa<eco::ValueType>(captured[i].getType());
    if (isBitSet != isUnboxedType) {
      return emitOpError("unboxed_bitmap bit ")
             << i << " doesn't match operand type: bit is "
             << (isBitSet ? "set" : "unset") << " but operand type is "
             << captured[i].getType();
    }
  }

  // CGEN_057: Kernel functions must have func.func is_kernel declarations.
  // Signature validation is deferred to CheckEcoClosureCapturesPass to avoid
  // O(N) module walks on every verifier invocation during conversion.
  {
    auto fastEvalAttr = getOperation()->getAttrOfType<FlatSymbolRefAttr>("_fast_evaluator");
    auto funcSym = fastEvalAttr ? fastEvalAttr : getFunctionAttr();
    auto funcName = getFunctionAttr().getValue();
    if (funcName.starts_with("Elm_Kernel_") && !symbolExists(getOperation(), funcSym)) {
      return emitOpError("kernel function '") << funcName
             << "' has no func.func declaration; compiler must emit one "
             << "(CGEN_057)";
    }
  }

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
  auto newargs = getNewargs();

  // Bitmap must fit in 52 bits (runtime Closure struct constraint).
  if (bitmap >= (1ULL << 52)) {
    return emitOpError("newargs_unboxed_bitmap exceeds 52-bit capacity");
  }

  // No bits should be set beyond newargs size.
  if (!newargs.empty()) {
    uint64_t validMask = (1ULL << newargs.size()) - 1;
    if (bitmap & ~validMask) {
      return emitOpError("newargs_unboxed_bitmap has bits set beyond newargs count");
    }
  } else if (bitmap != 0) {
    return emitOpError("newargs_unboxed_bitmap must be 0 when there are no newargs");
  }

  // Verify bitmap matches operand types.
  for (size_t i = 0; i < newargs.size(); ++i) {
    bool isBitSet = (bitmap >> i) & 1;
    bool isUnboxedType = !isa<eco::ValueType>(newargs[i].getType());
    if (isBitSet != isUnboxedType) {
      return emitOpError("newargs_unboxed_bitmap bit ")
             << i << " doesn't match operand type: bit is "
             << (isBitSet ? "set" : "unset") << " but operand type is "
             << newargs[i].getType();
    }
  }

  // === REP_CLOSURE_001: Bool must not be passed at closure boundary ===
  for (size_t i = 0; i < newargs.size(); ++i) {
    Type ty = newargs[i].getType();
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

  // === Typed mode: remaining_arity present ===
  // Walk closure-def chain to find root papCreate for evaluator-parameter checks.
  //
  // IMPORTANT: We must stop walking when we cross a STAGE SATURATION BOUNDARY.
  // When a papExtend saturates its stage (remaining_arity == newargs.size()),
  // the result is a NEW closure (the function's return value), not a partial
  // application of the original function. Subsequent papExtends operate on this
  // new closure, which has its own arity from the returned function.

  int64_t remainingArity = remainingArityAttr.getInt();

  unsigned alreadyApplied = 0;
  Operation *currentDef = getClosure().getDefiningOp();
  FlatSymbolRefAttr funcSym;
  int64_t arityFromCreate = -1;

  while (currentDef) {
    if (auto priorExt = dyn_cast<PapExtendOp>(currentDef)) {
      // Prior papExtend in generic mode breaks the chain — can't trace through
      // runtime-determined saturation.
      auto priorRemainingAttr = priorExt.getRemainingArityAttr();
      if (!priorRemainingAttr) {
        break;
      }

      // Check if this papExtend saturated its stage (CGEN_052 stage boundary)
      int64_t priorRemaining = priorRemainingAttr.getInt();
      unsigned priorNewargs = priorExt.getNewargs().size();

      if (priorRemaining == static_cast<int64_t>(priorNewargs)) {
        // Stage saturation boundary - the result is a NEW closure returned by
        // calling the function, not a partial application. We cannot trace
        // further back through the original papCreate chain.
        break;
      }

      alreadyApplied += priorNewargs;
      currentDef = priorExt.getClosure().getDefiningOp();
      continue;
    }
    if (auto create = dyn_cast<PapCreateOp>(currentDef)) {
      alreadyApplied += create.getNumCaptured();
      // Use fast evaluator for parameter checking if available (matches papCreate verifier).
      // The $clo generic clone has (closure, params...) signature which doesn't include
      // captures as explicit params, while $cap has (captures..., params...) matching arity.
      auto fastEval = create.get_fastEvaluatorAttr();
      funcSym = fastEval ? fastEval : create.getFunctionAttr();
      arityFromCreate = create.getArity();
      break;
    }
    // Non-PAP closure source (block arg, external op) - can't trace further.
    break;
  }

  // Signature validation is deferred to CheckEcoClosureCapturesPass to avoid
  // O(N) module walks on every verifier invocation during conversion.
  // Only check CGEN_057 kernel existence here.
  if (funcSym && arityFromCreate >= 0) {
    auto funcName = funcSym.getValue();
    if (funcName.starts_with("Elm_Kernel_") && !symbolExists(getOperation(), funcSym)) {
      return emitOpError("kernel function '") << funcName
             << "' has no func.func declaration; compiler must emit one "
             << "(CGEN_057)";
    }
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
  auto results = getResults();
  auto calleeAttr = getCalleeAttr();
  auto remainingArityAttr = getRemainingArityAttr();

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
