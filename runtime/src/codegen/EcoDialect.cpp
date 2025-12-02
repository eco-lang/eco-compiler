//===- EcoDialect.cpp - Eco dialect implementation ------------------------===//
//
// This file implements the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoDialect.h"
#include "EcoOps.h"

using namespace mlir;
using namespace eco;

#include "eco/EcoDialect.cpp.inc"

//===----------------------------------------------------------------------===//
// Eco dialect initialization
//===----------------------------------------------------------------------===//

void EcoDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "eco/EcoOps.cpp.inc"
      >();
}
