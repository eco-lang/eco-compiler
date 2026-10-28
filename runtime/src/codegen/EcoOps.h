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

// Include enum declarations (must be before op classes).
#include "eco/EcoEnums.h.inc"

#define GET_OP_CLASSES
#include "eco/EcoOps.h.inc"

namespace eco {
/// kernel-opt-12 purity channel: discardable unit attr on eco.call. Present
/// iff the callee's KernelFacts row derives `droppable`. Stripped by
/// EcoGCPrepare — see Ops.td's Eco_CallOp description for the license.
inline constexpr llvm::StringLiteral kCseSafeAttrName{"eco.cse_safe"};

/// Bit width of Elm Char in SSA, ABI and LLVM aggregate fields: a Char value
/// (a Unicode code point 0..0x10FFFF, or an encoded case-mapping result,
/// KERN_008) held in i32 (Eco_Char, CGEN_015, REP_ABI_001). A kind-3 (Char)
/// heap/closure word holds it zero-extended to 64 bits (REP_HEAP_002).
inline constexpr unsigned kEcoCharBits = 32;

/// True iff `t` is the Char SSA type (i32). Use this - never a literal width -
/// wherever an integer type means Char. Note i32 is also the ctor-tag type
/// (eco.get_tag) and the BytesFusion counter type; those never reach a
/// slot-kind classifier, and this helper must not be applied in BF lowering.
inline bool isEcoCharType(mlir::Type t) { return t.isInteger(kEcoCharBits); }

/// The Char SSA type (i32).
inline mlir::IntegerType getEcoCharType(mlir::MLIRContext *ctx) {
  return mlir::IntegerType::get(ctx, kEcoCharBits);
}
} // namespace eco

#endif // ECO_ECOOPS_H
