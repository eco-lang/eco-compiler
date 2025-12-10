//===- EcoTypes.h - Eco type declarations ---------------------------------===//
//
// This file defines the custom types for the Eco MLIR dialect.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_ECOTYPES_H
#define ECO_ECOTYPES_H

#include "mlir/IR/Types.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/DialectImplementation.h"

#include "EcoDialect.h"

// Include the auto-generated type declarations.
#define GET_TYPEDEF_CLASSES
#include "eco/EcoTypes.h.inc"

#endif // ECO_ECOTYPES_H
