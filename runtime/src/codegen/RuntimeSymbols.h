//===- RuntimeSymbols.h - JIT Symbol Registration for Eco Runtime ---------===//
//
// This file declares the shared symbol registration API used by both ecoc
// (the CLI compiler) and EcoRunner (the test execution library).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_RUNTIME_SYMBOLS_H
#define ECO_RUNTIME_SYMBOLS_H

namespace mlir {
class ExecutionEngine;
} // namespace mlir

namespace eco {
class EcoJIT;

//===----------------------------------------------------------------------===//
// Symbol Registration
//===----------------------------------------------------------------------===//

/// Registers all runtime function symbols for JIT linking.
/// This includes:
///   - Heap allocation functions (eco_alloc_*)
///   - Field store functions (eco_store_field*, eco_set_unboxed)
///   - Closure operations (eco_apply_closure, eco_pap_extend, etc.)
///   - Runtime utilities (eco_crash, eco_dbg_print*)
///   - GC interface (eco_safepoint, eco_minor_gc, eco_major_gc, etc.)
///   - Tag extraction (eco_get_header_tag, eco_get_custom_ctor)
///   - Arithmetic helpers (eco_int_pow)
///   - Elm kernel function symbols
void registerRuntimeSymbols(mlir::ExecutionEngine &engine);

/// Overload for EcoJIT engine (same symbols, different engine type).
void registerRuntimeSymbols(eco::EcoJIT &engine);

} // namespace eco

#endif // ECO_RUNTIME_SYMBOLS_H
