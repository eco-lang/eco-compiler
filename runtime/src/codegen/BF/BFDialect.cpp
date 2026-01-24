//===- BFDialect.cpp - ByteFusion dialect implementation ------------------===//
//
// This file implements the BF dialect initialization.
//
//===----------------------------------------------------------------------===//

#include "BFDialect.h"
#include "BFOps.h"
#include "BFTypes.h"

using namespace mlir;
using namespace bf;

#include "bf/BFDialect.cpp.inc"

//===----------------------------------------------------------------------===//
// BF Dialect
//===----------------------------------------------------------------------===//

void BFDialect::initialize() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "bf/BFTypes.cpp.inc"
  >();

  addOperations<
#define GET_OP_LIST
#include "bf/BFOps.cpp.inc"
  >();
}
