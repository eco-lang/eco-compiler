//===- EcoTypes.cpp - Eco type implementations ----------------------------===//
//
// This file implements the custom types for the Eco MLIR dialect.
//
//===----------------------------------------------------------------------===//

#include "EcoTypes.h"
#include "EcoDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace eco;

// Auto-generated type definitions (storage classes, parse/print, getters)
// have been moved to EcoDialect.cpp so the dialect's initialize() method,
// which calls addTypes<>, can see complete TypeStorage types.
// This TU is intentionally minimal but kept around for the include path
// and for potential future hand-written type helpers.
