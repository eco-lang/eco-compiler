// The debug printer needs to know the Elm type of a value to print it, and the heap does not record types: an
// object's header says how it is laid out, not which Elm type it belongs to, and many values are embedded
// constants with no object at all. So the compiler describes every type the program prints in a static table,
// the type graph, and this header is the layout of that table.
//
// The type graph is plain data. The `eco.type_table` op is lowered to LLVM globals in this layout,
// with `__eco_type_graph` as the root `EcoTypeGraph`, and `__eco_init_globals` hands that root to
// `eco_register_type_graph`. `eco_dbg_print_typed` then reads it to print values such as
// `[ { a = 1, b = 2.0 } ]` with their field and constructor names.
//
// The table is a set of flat arrays that refer to each other by index:
//   - `types` holds one `EcoTypeInfo` per type. A type is named by its type id, which is its index here.
//   - `fields` holds the element types of tuples, the fields of records, and the fields of constructors.
//   - `ctors` holds the constructors of custom types.
//   - `function_arg_type_ids` holds the argument types of function types.
//   - `strings` holds field and constructor names.
// A record, tuple, constructor, custom type or function type refers to a contiguous run of one of these arrays
// by a first index and a count. Nothing in this header checks an index; the printer checks some of them with
// assertions.
//
// The emitter (`EcoToLLVMGlobals.cpp`) also writes these structs: it packs `EcoTypeInfo`, `EcoFieldInfo` and
// `EcoCtorInfo` as little-endian bytes at these offsets, and emits `EcoTypeGraph` as an LLVM struct of the same
// shape. The `static_assert`s on the sizes pin the C++ sizes that the emitter assumes; nothing checks the
// emitter against them. The numeric values of the enumerations are shared with the compiler, so none of them
// may be reordered.
//
// A kind in the type graph describes the Elm type, not how a particular value is stored. Whether a slot holds
// a boxed word or raw Int, Float or Char bits is told by its 2-bit slot kind in the containing object, as
// `Heap.hpp` defines (Bool and String are never stored unboxed). The printer reads raw bits only where the
// slot kind says the slot is unboxed, and then takes the primitive kind from the type graph.

#ifndef ECO_TYPE_INFO_H
#define ECO_TYPE_INFO_H

#include <cstdint>

namespace Elm {

// ============================================================================
// Type Kind Enumerations
// ============================================================================

/// The shape of an Elm type, which selects the member of `EcoTypeInfo::data` that describes it.
///
/// The emitter writes these values as numbers (`Primitive` is 0, `Polymorphic` is 6), so the order is fixed.
enum class EcoTypeKind : uint8_t {
    Primitive,   ///< One of the types `EcoPrimKind` lists.
    List,
    Tuple,       ///< A pair or a triple.
    Record,
    Custom,      ///< A custom type (algebraic data type), described by its constructors.
    Function,    ///< Printed as `<function>`; its argument and result types are not read by the printer.
    Polymorphic, ///< A type variable left after monomorphization. Printed by `print_value` without type info.
};

/// The constraint on a type variable that a `Polymorphic` type stands for.
///
/// The emitter writes these values as numbers (`Number` is 0, `EcoValue` is 1). The printer does not read them.
enum class EcoConstraintKind : uint8_t {
    Number,      ///< The `number` constraint: the value is an Int or a Float.
    EcoValue,    ///< No constraint: the value may be of any type.
};

/// Which primitive Elm type a `Primitive` type is.
///
/// The values are numbered as in the compiler's `Compiler.Generate.MLIR.TypeTable.primKindToTag`, so the order is
/// fixed.
enum class EcoPrimKind : uint8_t {
    Int,
    Float,
    Char,
    Bool,
    String,
    Unit,  ///< Elm `()`, whose value is an embedded constant rather than a heap object.
};

// ============================================================================
// Type Graph Component Structures
// ============================================================================

/// One entry of `EcoTypeGraph::fields`: a field of a record, an element of a tuple, or a field of a constructor.
struct EcoFieldInfo {
    uint32_t name_index;  ///< Index of the field's name in `EcoTypeGraph::strings`. Read only for record fields.
    uint32_t type_id;
};
static_assert(sizeof(EcoFieldInfo) == 8, "EcoFieldInfo must be 8 bytes");

/// One entry of `EcoTypeGraph::ctors`: a constructor of a custom type, with its name and its fields.
struct EcoCtorInfo {
    uint32_t ctor_id;      ///< The constructor's tag, matched against `Custom::ctor` of a heap object.
    uint32_t name_index;   ///< Index of the constructor's name in `EcoTypeGraph::strings`.
    uint32_t first_field;  ///< Index of the constructor's first field in `EcoTypeGraph::fields`.
    uint32_t field_count;
};
static_assert(sizeof(EcoCtorInfo) == 16, "EcoCtorInfo must be 16 bytes");

/// One entry of `EcoTypeGraph::types`: a single monomorphic Elm type.
///
/// `kind` says which member of `data` is meaningful. The printer finds an entry by indexing `types` with a type
/// id, so `type_id` is expected to equal the entry's own index; nothing checks this.
struct EcoTypeInfo {
    uint32_t type_id;
    EcoTypeKind kind;
    uint8_t padding[3];

    union {
        // For Primitive types
        struct {
            EcoPrimKind prim_kind;
            uint8_t padding[7];
        } primitive;

        // For List types
        struct {
            uint32_t elem_type_id;
            uint32_t padding;
        } list;

        // For Tuple types
        struct {
            uint16_t arity;         // 2 or 3, which is also the number of entries in `fields`.
            uint16_t padding1;
            uint32_t first_field;   // Index of the first element's entry in `EcoTypeGraph::fields`.
        } tuple;

        // For Record types
        struct {
            uint32_t first_field;   // Index of the first field's entry in `EcoTypeGraph::fields`.
            uint32_t field_count;
        } record;

        // For Custom types (ADTs)
        struct {
            uint32_t first_ctor;    // Index of the first constructor's entry in `EcoTypeGraph::ctors`.
            uint32_t ctor_count;
        } custom;

        // For Function types
        struct {
            uint32_t first_arg_type;   // Index of the first argument's type id in `function_arg_type_ids`.
            uint16_t arg_count;
            uint16_t padding;
            uint32_t result_type_id;
        } function;

        // For Polymorphic types (type variables with constraints)
        struct {
            EcoConstraintKind constraint;
            uint8_t padding[7];
        } polymorphic;
    } data;
};
static_assert(sizeof(EcoTypeInfo) == 20, "EcoTypeInfo must be 20 bytes");

// ============================================================================
// Top-Level Type Graph Container
// ============================================================================

/// The root of a program's type graph: the five arrays and their lengths.
///
/// Each pointer refers to read-only data emitted with the program. A pointer may be null when its array is
/// empty, and the matching count is then 0. Each count is the number of entries, not bytes.
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
