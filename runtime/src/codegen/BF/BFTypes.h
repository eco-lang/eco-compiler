//===- BFTypes.h - ByteFusion type declarations ---------------------------===//
//
// The BF (ByteFusion) dialect, `bf`, has one type of its own, and this header
// is where C++ code gets it. That type is `bf::CursorType`, written `bf.cursor`
// in MLIR: a position in a byte buffer together with the end of that buffer,
// which `bf::BFDialect` describes. It has no parameters.
//
// The type is defined in TableGen (`BFOps.td`). This header includes the
// generated class declaration, and `BFTypes.cpp` the generated definitions.
//
//===----------------------------------------------------------------------===//

#ifndef BF_BFTYPES_H
#define BF_BFTYPES_H

#include "mlir/IR/Types.h"

#define GET_TYPEDEF_CLASSES
#include "bf/BFTypes.h.inc"

#endif // BF_BFTYPES_H
