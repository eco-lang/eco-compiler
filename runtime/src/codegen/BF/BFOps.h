//===- BFOps.h - ByteFusion operation declarations ------------------------===//
//
// This file declares the BF dialect operations.
//
//===----------------------------------------------------------------------===//

#ifndef BF_BFOPS_H
#define BF_BFOPS_H

#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

#include "BFDialect.h"
#include "BFTypes.h"

// Include enum definitions
#include "bf/BFEnums.h.inc"

#define GET_OP_CLASSES
#include "bf/BFOps.h.inc"

#endif // BF_BFOPS_H
