//===- EcoOps.h - Eco dialect operations ----------------------------------===//
//
// This file declares the operations in the Eco dialect.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_ECOOPS_H
#define ECO_ECOOPS_H

#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "mlir/Interfaces/ControlFlowInterfaces.h"

#include "EcoDialect.h"
#include "EcoTypes.h"

// Include enum declarations (must be before op classes).
#include "eco/EcoEnums.h.inc"

#define GET_OP_CLASSES
#include "eco/EcoOps.h.inc"

#endif // ECO_ECOOPS_H
