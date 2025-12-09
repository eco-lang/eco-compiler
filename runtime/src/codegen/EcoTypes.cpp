//===- EcoTypes.cpp - Eco type implementations ----------------------------===//
//
// This file implements the custom types for the Eco MLIR dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoTypes.h"
#include "EcoDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace eco;

// Include the auto-generated type definitions
#define GET_TYPEDEF_CLASSES
#include "eco/EcoTypes.cpp.inc"
