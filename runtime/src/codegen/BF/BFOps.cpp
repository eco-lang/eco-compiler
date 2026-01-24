//===- BFOps.cpp - ByteFusion operation implementations -------------------===//
//
// This file implements the BF dialect operations.
//
//===----------------------------------------------------------------------===//

#include "BFOps.h"
#include "BFDialect.h"
#include "BFTypes.h"

using namespace mlir;
using namespace bf;

// Include enum definitions
#include "bf/BFEnums.cpp.inc"

#define GET_OP_CLASSES
#include "bf/BFOps.cpp.inc"
