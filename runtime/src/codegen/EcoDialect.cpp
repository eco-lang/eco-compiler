//===- EcoDialect.cpp - Eco dialect implementation ------------------------===//
//
// Compiles the TableGen-generated dialect and type definitions, and registers
// the generated types and operations when the dialect is loaded.
//
//===----------------------------------------------------------------------===//

#include "EcoDialect.h"
#include "EcoOps.h"

#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace eco;

#include "eco/EcoDialect.cpp.inc"

// Pull in the generated TypeStorage class definitions, getters, and
// parse/print methods. These must be complete in this TU because
// EcoDialect::initialize() below calls addTypes<>, which instantiates
// templates that require TypeStorage types to be complete.
#define GET_TYPEDEF_CLASSES
#include "eco/EcoTypes.cpp.inc"

//===----------------------------------------------------------------------===//
// Dialect Initialization
//===----------------------------------------------------------------------===//

// Registers every type and operation that TableGen generated for the dialect.
// MLIR calls this once, when the dialect is loaded into a context.
void EcoDialect::initialize() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "eco/EcoTypes.cpp.inc"
      >();

  addOperations<
#define GET_OP_LIST
#include "eco/EcoOps.cpp.inc"
      >();
}
