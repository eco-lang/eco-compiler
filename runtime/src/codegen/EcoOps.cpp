//===- EcoOps.cpp - Eco dialect operations --------------------------------===//
//
// This file implements the operations in the Eco dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoOps.h"
#include "EcoDialect.h"

using namespace mlir;
using namespace eco;

#define GET_OP_CLASSES
#include "eco/EcoOps.cpp.inc"
