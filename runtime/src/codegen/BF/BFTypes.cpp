//===- BFTypes.cpp - ByteFusion type implementations ----------------------===//
//
// This file implements the BF dialect types.
//
//===----------------------------------------------------------------------===//

#include "BFTypes.h"
#include "BFDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace bf;

#define GET_TYPEDEF_CLASSES
#include "bf/BFTypes.cpp.inc"
