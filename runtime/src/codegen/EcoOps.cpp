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

using namespace mlir;
using namespace eco;

//===----------------------------------------------------------------------===//
// Verifiers
//===----------------------------------------------------------------------===//

LogicalResult CaseOp::verify() {
  // Verify that the number of regions matches the number of tags
  if (getTags().size() != getAlternatives().size()) {
    return emitOpError("number of tags (")
           << getTags().size()
           << ") must match number of alternative regions ("
           << getAlternatives().size() << ")";
  }
  return success();
}

LogicalResult JoinpointOp::verify() {
  // Verify that the body region has exactly one block
  if (getBody().empty()) {
    return emitOpError("body region must not be empty");
  }
  return success();
}

LogicalResult ConstructOp::verify() {
  // Verify that the number of fields matches the size attribute
  int64_t size = getSize();
  if (static_cast<int64_t>(getFields().size()) != size) {
    return emitOpError("number of fields (")
           << getFields().size()
           << ") must match size attribute ("
           << size << ")";
  }
  return success();
}

LogicalResult PapCreateOp::verify() {
  // Verify that num_captured matches the number of captured operands
  int64_t numCaptured = getNumCaptured();
  if (static_cast<int64_t>(getCaptured().size()) != numCaptured) {
    return emitOpError("number of captured operands (")
           << getCaptured().size()
           << ") must match num_captured attribute ("
           << numCaptured << ")";
  }

  // Verify that num_captured is less than arity
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
// Include the auto-generated op definitions
//===----------------------------------------------------------------------===//

#define GET_OP_CLASSES
#include "eco/EcoOps.cpp.inc"
