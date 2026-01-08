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

using namespace mlir;
using namespace eco;

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

  // Verify scrutinee type is allowed: !eco.value or i1 (Bool)
  Type scrutineeType = getScrutinee().getType();
  if (!isa<eco::ValueType>(scrutineeType)) {
    // For non-eco.value scrutinees, only allow i1 (Bool)
    if (auto intType = dyn_cast<IntegerType>(scrutineeType)) {
      if (intType.getWidth() != 1) {
        return emitOpError("scrutinee must be !eco.value or i1, got ")
               << scrutineeType;
      }
      // For i1 scrutinee, verify tags are only 0 or 1
      for (int64_t tag : getTags()) {
        if (tag != 0 && tag != 1) {
          return emitOpError("i1 scrutinee requires tags in {0, 1}, got ")
                 << tag;
        }
      }
    } else {
      return emitOpError("scrutinee must be !eco.value or i1, got ")
             << scrutineeType;
    }
  }

  // CGEN_010 invariant: eco.case ALWAYS requires result_types attribute.
  // Elm codegen always produces eco.case with result_types and eco.return terminators.
  // eco.jump is never used as a case alternative terminator.
  auto caseResultTypesAttr = getCaseResultTypes();
  if (!caseResultTypesAttr) {
    return emitOpError("requires 'result_types' (caseResultTypes) attribute; "
                       "eco.case is always an expression form");
  }

  // Extract expected result types
  SmallVector<Type> expectedTypes;
  for (Attribute attr : *caseResultTypesAttr) {
    if (auto typeAttr = dyn_cast<TypeAttr>(attr)) {
      expectedTypes.push_back(typeAttr.getValue());
    } else {
      return emitOpError("result_types must contain TypeAttr elements");
    }
  }

  // eco.case must have at least one result type (no void cases)
  if (expectedTypes.empty()) {
    return emitOpError("result_types must not be empty; void cases are not supported");
  }

  // Verify that each region has exactly one block with eco.return terminator.
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

    // All alternatives must terminate with eco.return (not eco.jump)
    auto retOp = dyn_cast<ReturnOp>(terminator);
    if (!retOp) {
      return emitOpError("alternative ")
             << altIndex << " must terminate with 'eco.return', got '"
             << terminator->getName() << "'; eco.jump is not allowed in case alternatives";
    }

    // Validate eco.return operand types match expectedTypes
    auto actualTypes = retOp.getOperandTypes();
    if (actualTypes.size() != expectedTypes.size()) {
      return emitOpError("alternative ")
             << altIndex << " eco.return has " << actualTypes.size()
             << " operands but result_types specifies " << expectedTypes.size();
    }
    for (size_t i = 0; i < expectedTypes.size(); ++i) {
      if (actualTypes[i] != expectedTypes[i]) {
        return emitOpError("alternative ")
               << altIndex << " eco.return operand " << i
               << " has type " << actualTypes[i]
               << " but result_types specifies " << expectedTypes[i];
      }
    }

    ++altIndex;
  }

  return success();
}

// Implement MemoryEffectsOpInterface for CaseOp
// Mark the operation as having side effects to prevent DCE from removing it
// before pattern lowering has a chance to run.
void CaseOp::getEffects(
    SmallVectorImpl<SideEffects::EffectInstance<MemoryEffects::Effect>> &effects) {
  // Add a write effect to prevent DCE (case expressions have observable behavior)
  effects.emplace_back(MemoryEffects::Write::get());
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

  return success();
}

//===----------------------------------------------------------------------===//
// Custom Assembly Format: CaseOp
//===----------------------------------------------------------------------===//

// Format: eco.case %scrutinee [tag0, tag1, ...] result_types [type0, ...] { region0 }, { region1 }, ...
void CaseOp::print(OpAsmPrinter &p) {
  p << " " << getScrutinee() << " [";
  llvm::interleaveComma(getTags(), p);
  p << "]";

  // Print result_types if present
  if (auto resultTypes = getCaseResultTypes()) {
    p << " result_types [";
    llvm::interleaveComma(*resultTypes, p, [&](Attribute attr) {
      p << cast<TypeAttr>(attr).getValue();
    });
    p << "]";
  }

  for (Region &region : getAlternatives()) {
    p << " ";
    p.printRegion(region, /*printEntryBlockArgs=*/false,
                  /*printBlockTerminators=*/true);
    if (&region != &getAlternatives().back())
      p << ",";
  }
  p.printOptionalAttrDict((*this)->getAttrs(), {"tags", "caseResultTypes"});
}

ParseResult CaseOp::parse(OpAsmParser &parser, OperationState &result) {
  OpAsmParser::UnresolvedOperand scrutinee;
  if (parser.parseOperand(scrutinee))
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

  // Parse optional result_types [type0, type1, ...] (can be empty [])
  if (succeeded(parser.parseOptionalKeyword("result_types"))) {
    if (parser.parseLSquare())
      return failure();

    SmallVector<Attribute> resultTypeAttrs;
    // Handle empty list case: result_types []
    if (failed(parser.parseOptionalRSquare())) {
      // Non-empty list: parse first type, then optional comma-separated types
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
    }

    result.addAttribute("caseResultTypes",
                        parser.getBuilder().getArrayAttr(resultTypeAttrs));
  }

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

  // Parse optional attr-dict
  if (parser.parseOptionalAttrDict(result.attributes))
    return failure();

  // Resolve scrutinee operand
  Type valueType = eco::ValueType::get(parser.getContext());
  if (parser.resolveOperand(scrutinee, valueType, result.operands))
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
