//===- BFOps.h - ByteFusion operation declarations ------------------------===//
//
// The operations of the BF (ByteFusion) dialect, `bf`, are defined in TableGen
// (`BFOps.td`), and this header is where C++ code gets their classes. The
// dialect and its cursor are described in `BFDialect.h`.
//
// It includes two generated files. `bf/BFEnums.h.inc` declares
// `bf::Endianness`, a byte order: `LE` (0) for
// little-endian and `BE` (1) for big-endian. The 16- and 32-bit integer and
// the float writes and reads carry it as their `endianness` attribute; the
// single-byte ones do not. `bf/BFOps.h.inc` declares one class per operation,
// such as `bf::WriteU16Op` for `bf.write.u16`.
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

#include "bf/BFEnums.h.inc"

#define GET_OP_CLASSES
#include "bf/BFOps.h.inc"

#endif // BF_BFOPS_H
