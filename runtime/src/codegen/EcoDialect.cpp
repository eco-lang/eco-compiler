//===- EcoDialect.cpp - Eco dialect implementation ------------------------===//
//
// This file implements the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoDialect.h"
#include "EcoOps.h"
#include "EcoTypes.h"

using namespace mlir;
using namespace eco;

#include "eco/EcoDialect.cpp.inc"

//===----------------------------------------------------------------------===//
// Eco dialect initialization
//===----------------------------------------------------------------------===//

void EcoDialect::initialize() {
  // Register types
  addTypes<
#define GET_TYPEDEF_LIST
#include "eco/EcoTypes.cpp.inc"
      >();

  // Register operations
  addOperations<
#define GET_OP_LIST
#include "eco/EcoOps.cpp.inc"
      >();
}
