//===- BFDialect.cpp - ByteFusion dialect implementation ------------------===//
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

// Registers every type and operation that TableGen generated for the dialect.
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
