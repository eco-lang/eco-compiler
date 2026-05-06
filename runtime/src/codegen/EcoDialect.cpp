//===- EcoDialect.cpp - Eco dialect implementation ------------------------===//
//
// This file implements the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoDialect.h"
#include "EcoOps.h"
#include "EcoTypes.h"

#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace eco;

#include "eco/EcoDialect.cpp.inc"

// Pull in the generated TypeStorage class definitions, getters, and
// parse/print methods. These must be complete in this TU because
// EcoDialect::initialize() below calls addTypes<>, which instantiates
// templates that require TypeStorage types to be complete.
#define GET_TYPEDEF_CLASSES
#include "eco/EcoTypes.cpp.inc"

//===----------------------------------------------------------------------===//
// Dialect Initialization
//===----------------------------------------------------------------------===//

void EcoDialect::initialize() {
  // Register types.
  addTypes<
#define GET_TYPEDEF_LIST
#include "eco/EcoTypes.cpp.inc"
      >();

  // Register operations.
  addOperations<
#define GET_OP_LIST
#include "eco/EcoOps.cpp.inc"
      >();
}
