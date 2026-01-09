/**
 * Type Graph Structures for Elm Runtime Debug Printing.
 *
 * This file defines type descriptor structures used by eco.dbg to pretty-print
 * Elm values with full type information. The type graph is built at compile time
 * and emitted as LLVM globals via the eco.type_table op.
 *
 * The runtime accesses __eco_type_graph to look up type descriptors by type_id,
 * enabling it to print nested structures like List { inner = { a = 1, b = 2.0 } }
 * without requiring per-object type metadata on the heap.
 *
 * ## Value Representation for Debug Printing
 *
 * There are two distinct contexts where values are interpreted:
 *
 * ### 1. eco_dbg_print_typed ABI (dbg boundary)
 *
 * All values in the `values[]` array passed to eco_dbg_print_typed are
 * HPointer-encoded (boxed !eco.value from MLIR):
 *   - Either a real heap pointer (to ElmInt, ElmFloat, ElmString, etc.)
 *   - Or an embedded constant (True, False, Nil, EmptyString, Unit, etc.)
 *
 * At the dbg boundary, primitives are ALWAYS boxed. The EcoTypeKind/EcoPrimKind
 * describe the Elm *type*, not whether the value is boxed or unboxed.
 * eco_dbg_print_typed never receives raw unboxed primitive bits directly.
 *
 * ### 2. Unboxed fields inside heap objects
 *
 * Certain heap layouts store primitive values unboxed for performance:
 *   - Cons: Header.unboxed bit 0 indicates head is unboxed
 *   - Tuple2/Tuple3: Header.unboxed bits 0-2 for fields a/b/c
 *   - Record: record->unboxed bitmap (up to 64 fields)
 *   - Custom: custom->unboxed bitmap (up to 48 fields)
 *   - ElmArray: array->unboxed bitmap (up to 64 elements)
 *   - Closure: closure->unboxed bitmap for captured values
 *
 * For unboxed fields, when the type is primitive, the 64-bit slot contains:
 *   - EcoPrimKind::Int    -> int64_t value
 *   - EcoPrimKind::Float  -> double (IEEE 754 bits)
 *   - EcoPrimKind::Char   -> Unicode code point in low 16 bits
 *   - EcoPrimKind::Bool   -> 0 or 1
 *   - EcoPrimKind::String -> NEVER unboxed (always HPointer)
 *
 * Only container printers (printList, printTuple, printRecord, printCustom)
 * interpret unboxed bits, and only after consulting the unboxed bitmap AND
 * verifying the type is primitive via the type graph.
 */

#ifndef ECO_TYPE_INFO_H
#define ECO_TYPE_INFO_H

#include <cstdint>

namespace Elm {

// ============================================================================
// Type Kind Enumerations
// ============================================================================

/**
 * Discriminates the kind of Elm type represented by an EcoTypeInfo.
 */
enum class EcoTypeKind : uint8_t {
    Primitive,   // Int, Float, Char, Bool, String
    List,        // List a
    Tuple,       // (a, b) or (a, b, c)
    Record,      // { field1 : T1, field2 : T2, ... }
    Custom,      // type Foo = Bar Int | Baz String
    Function,    // a -> b -> c
    Polymorphic, // Type variable with constraint (number, comparable, etc.)
};

/**
 * Discriminates type variable constraints for polymorphic types.
 * These are used when a type variable with constraint leaks through monomorphization.
 */
enum class EcoConstraintKind : uint8_t {
    Number,      // number - can be Int or Float
    EcoValue,    // unconstrained type variable (falls back to generic printing)
};

/**
 * Discriminates primitive types for specialized printing.
 */
enum class EcoPrimKind : uint8_t {
    Int,
    Float,
    Char,
    Bool,
    String,
};

// ============================================================================
// Type Graph Component Structures
// ============================================================================

/**
 * Describes a field in a record or tuple.
 * For tuples, name_index may be unused (set to 0).
 */
struct EcoFieldInfo {
    uint32_t name_index;  // Index into string table (field name)
    uint32_t type_id;     // TypeId of field type
};
static_assert(sizeof(EcoFieldInfo) == 8, "EcoFieldInfo must be 8 bytes");

/**
 * Describes a constructor of a custom type (ADT).
 */
struct EcoCtorInfo {
    uint32_t ctor_id;      // Per-type constructor index (0..n-1)
    uint32_t name_index;   // Constructor name in string table
    uint32_t first_field;  // Index into global field-type array
    uint32_t field_count;  // Number of fields this constructor has
};
static_assert(sizeof(EcoCtorInfo) == 16, "EcoCtorInfo must be 16 bytes");

/**
 * Describes a monomorphized Elm type.
 * The `data` union contains kind-specific information.
 */
struct EcoTypeInfo {
    uint32_t type_id;      // Unique per monomorphic type
    EcoTypeKind kind;      // Type kind discriminant
    uint8_t padding[3];    // Explicit padding for alignment

    union {
        // For Primitive types
        struct {
            EcoPrimKind prim_kind;
            uint8_t padding[7];
        } primitive;

        // For List types
        struct {
            uint32_t elem_type_id;  // TypeId of element type
            uint32_t padding;
        } list;

        // For Tuple types
        struct {
            uint16_t arity;         // 2 or 3
            uint16_t padding1;
            uint32_t first_field;   // Index into global field-type array
            // field_count == arity, stored in first_field entries
        } tuple;

        // For Record types
        struct {
            uint32_t first_field;   // Index into global field info array
            uint32_t field_count;   // Number of fields
        } record;

        // For Custom types (ADTs)
        struct {
            uint32_t first_ctor;    // Index into ctor array
            uint32_t ctor_count;    // Number of constructors
        } custom;

        // For Function types
        struct {
            uint32_t first_arg_type;   // Index into global arg-type array
            uint16_t arg_count;        // Number of arguments
            uint16_t padding;
            uint32_t result_type_id;   // TypeId of result type
        } function;

        // For Polymorphic types (type variables with constraints)
        struct {
            EcoConstraintKind constraint;  // The type constraint
            uint8_t padding[7];
        } polymorphic;
    } data;
};
static_assert(sizeof(EcoTypeInfo) == 20, "EcoTypeInfo must be 20 bytes");

// ============================================================================
// Top-Level Type Graph Container
// ============================================================================

/**
 * The complete type graph for a compiled Elm program.
 * Exported as __eco_type_graph by the eco.type_table lowering.
 */
struct EcoTypeGraph {
    const EcoTypeInfo* types;
    uint32_t type_count;
    uint32_t padding1;

    const EcoFieldInfo* fields;
    uint32_t field_count;
    uint32_t padding2;

    const EcoCtorInfo* ctors;
    uint32_t ctor_count;
    uint32_t padding3;

    const uint32_t* function_arg_type_ids;
    uint32_t function_arg_type_count;
    uint32_t padding4;

    const char* const* strings;
    uint32_t string_count;
    uint32_t padding5;
};
static_assert(sizeof(EcoTypeGraph) == 80, "EcoTypeGraph must be 80 bytes");

} // namespace Elm

#endif // ECO_TYPE_INFO_H
