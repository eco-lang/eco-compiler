// The operations of the Eco dialect, the MLIR form in which the Elm compiler hands a program to this runtime's code
// generator.
//
// The ops themselves (their operands, attributes, traits and assembly formats) are declared in `Ops.td`, and
// TableGen generates their C++ classes, which this header includes. What TableGen cannot generate is written by hand
// in `EcoOps.cpp`: the verifiers, the checks of symbol references, the memory effects of `eco.call`, the folders of
// projections and `eco.get_tag`, and the custom syntax of `eco.case` and `eco.joinpoint`.
//
// One fact shapes most of that code. The compiler decides how each value is laid out, and records its decisions as
// attributes: a `slot_kinds` entry per heap field or closure slot, a closure's arity, the evaluator a call reaches.
// Some lowerings copy such an attribute straight into a heap header, as the tuple and cons lowerings do with their
// kind bitmaps; others take the layout from the SSA types and leave the attribute as a statement to check. Either
// way the attribute and the types must agree, so a verifier checks each decision against them: a disagreement that
// got through would surface only later, as an LLVM signature error, or as a field the collector traces with the wrong
// kind. A slot kind is the 2-bit code for how a field is stored: 0 boxed (`!eco.value`), 1 Int (`i64`), 2 Float
// (`f64`), 3 Char (`i32`). Bool (`i1`) has no kind of its own and is boxed before it is stored. The `CGEN_*`, `HEAP_*`
// and `REP_*` identifiers in diagnostics and comments name rules in the project's invariants list.
//
// The folders are hooks that any MLIR fold driver may call, so they fire wherever ops are folded. Setting
// `ECO_MLIR_FOLD=0` removes the EcoFoldProject pass but does not turn them off.

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
// The name of the unit attribute that marks an `eco.call` as free of memory effects.
//
// A call carrying it reports no effects (`CallOp::getEffects`), so MLIR may merge two identical calls or erase one
// whose result is unused. It does not make the call speculatable, so it does not let a call be hoisted or executed
// speculatively. The verifier accepts it only on a direct call that is not `musttail`. The pass from
// `createEcoGCPreparePass` removes it from every call, so no pass after that one may rely on it.
inline constexpr llvm::StringLiteral kCseSafeAttrName{"eco.cse_safe"};

// Bit width of Elm Char in SSA, ABI and LLVM aggregate fields: a Char value
// (a Unicode code point 0..0x10FFFF, or an encoded case-mapping result,
// KERN_008) held in i32 (Eco_Char, CGEN_015, REP_ABI_001). A kind-3 (Char)
// heap/closure word holds it zero-extended to 64 bits (REP_HEAP_002).
inline constexpr unsigned kEcoCharBits = 32;

// True iff `t` is the Char SSA type (i32). Use this - never a literal width -
// wherever an integer type means Char. Note i32 is also the ctor-tag type
// (eco.get_tag) and the BytesFusion counter type; those never reach a
// slot-kind classifier, and this helper must not be applied in BF lowering.
inline bool isEcoCharType(mlir::Type t) { return t.isInteger(kEcoCharBits); }

// The Char SSA type (i32).
inline mlir::IntegerType getEcoCharType(mlir::MLIRContext *ctx) {
  return mlir::IntegerType::get(ctx, kEcoCharBits);
}
} // namespace eco

#endif // ECO_ECOOPS_H
