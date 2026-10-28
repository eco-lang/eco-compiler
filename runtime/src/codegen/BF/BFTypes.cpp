//===- BFTypes.cpp - ByteFusion type implementations ----------------------===//
//
// Compiles the TableGen-generated definitions of the BF dialect types. The
// list of types the dialect registers is included separately, by
// `BFDialect.cpp`.
//
//===----------------------------------------------------------------------===//

#include "BFTypes.h"
#include "BFDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace bf;

#define GET_TYPEDEF_CLASSES
#include "bf/BFTypes.cpp.inc"
