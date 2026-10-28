//===- BFDialect.h - ByteFusion dialect declaration -----------------------===//
//
// Elm's `Bytes.Encode` and `Bytes.Decode` pipelines are compiled into straight
// runs of byte loads and stores, and the BF (ByteFusion) MLIR dialect, named
// `bf`, is the form they take before they are lowered to LLVM. This header
// declares the dialect class, `bf::BFDialect`. Its C++ namespace is `::bf`, not
// `eco`.
//
// The dialect rests on one idea, the cursor. A `bf.cursor` (`bf::CursorType`)
// is a position in a byte buffer together with the end of that buffer: a pair
// of pointers, current and end, which lowering turns into a two-pointer LLVM
// struct. An operation that writes or reads takes a cursor and returns a new
// one advanced past the bytes it touched, so the order of byte accesses is
// carried by SSA values rather than by memory. Read operations do not check
// bounds themselves; `bf.require` is the check, and a reader must emit it
// before the reads it guards.
//
// The dialect, its types and its operations are all defined in TableGen
// (`BFOps.td`), and this header only includes the generated class. Loading the
// dialect into an `MLIRContext` registers the types declared in `BFTypes.h` and
// the operations declared in `BFOps.h`.
//
//===----------------------------------------------------------------------===//

#ifndef BF_BFDIALECT_H
#define BF_BFDIALECT_H

#include "mlir/IR/Dialect.h"

#include "bf/BFDialect.h.inc"

#endif // BF_BFDIALECT_H
