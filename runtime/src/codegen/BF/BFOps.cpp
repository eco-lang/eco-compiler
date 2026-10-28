//===- BFOps.cpp - ByteFusion operation implementations -------------------===//
//
// Compiles the generated definitions; the header describes them.
//
//===----------------------------------------------------------------------===//

#include "BFOps.h"
#include "BFDialect.h"
#include "BFTypes.h"

using namespace mlir;
using namespace bf;

#include "bf/BFEnums.cpp.inc"

#define GET_OP_CLASSES
#include "bf/BFOps.cpp.inc"
