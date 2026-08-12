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

// Include generated OpInterface declarations (must be before op classes).
#include "eco/EcoOpInterfaces.h.inc"

#define GET_OP_CLASSES
#include "eco/EcoOps.h.inc"

namespace eco {
/// kernel-opt-12 purity channel: discardable unit attr on eco.call. Present
/// iff the callee's KernelFacts row derives `droppable`. Stripped by
/// EcoGCPrepare — see Ops.td's Eco_CallOp description for the license.
inline constexpr llvm::StringLiteral kCseSafeAttrName{"eco.cse_safe"};
} // namespace eco

#endif // ECO_ECOOPS_H
