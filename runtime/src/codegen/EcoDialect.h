//===- EcoDialect.h - Eco dialect declaration -----------------------------===//
//
// This file declares the Eco dialect and its types.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_ECODIALECT_H
#define ECO_ECODIALECT_H

#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/DialectImplementation.h"
#include "mlir/IR/Types.h"

#include "eco/EcoDialect.h.inc"

// Auto-generated type declarations. The definitions are pulled in by
// EcoDialect.cpp.
#define GET_TYPEDEF_CLASSES
#include "eco/EcoTypes.h.inc"

#endif // ECO_ECODIALECT_H
