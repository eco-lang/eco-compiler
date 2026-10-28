//===- EcoDialect.h - Eco dialect declaration -----------------------------===//
//
// The Eco MLIR dialect, `eco`, is the form a compiled Elm program takes on its
// way to LLVM, and this header is where C++ code gets the dialect class,
// `eco::EcoDialect`, and the dialect's types. Its operations are declared in
// `EcoOps.h`.
//
// The dialect and its types are defined in TableGen (`Ops.td`), and this header
// only includes the generated declarations. The types are `eco.value`
// (`eco::ValueType`), a boxed Elm value word that is either a pointer to a
// heap object or an embedded constant, and the aggregates `eco.tuple2`,
// `eco.tuple3`, `eco.record`, `eco.custom`, `eco.cons` and `eco.closure_env`,
// which are SSA-only values lowered to LLVM structs, never heap objects.
// Loading the dialect into an `MLIRContext` registers all of these types and
// every operation in `EcoOps.h`.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_ECODIALECT_H
#define ECO_ECODIALECT_H

#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/DialectImplementation.h"
#include "mlir/IR/Types.h"

#include "eco/EcoDialect.h.inc"

// Generated type declarations. Their definitions are compiled in
// `EcoDialect.cpp`.
#define GET_TYPEDEF_CLASSES
#include "eco/EcoTypes.h.inc"

#endif // ECO_ECODIALECT_H
