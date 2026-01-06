Below is a concrete design you can hand to someone to implement. I’ll flag where I’m extrapolating beyond the current codebase (because this is a new feature), but everything is consistent with the existing Eco dialect and runtime.

---

## 0. Goals

1. **Single global type graph per compiled program**

    - Contains a descriptor for each *monomorphized* Elm type used in the program.
    - Used by `eco.dbg` to pretty‑print values, including:
        - Lists/tuples/records with unboxed fields
        - Nested records (field names)
        - Custom ADTs (constructor names, field types)

2. **No extra per‑object type metadata required on the heap**

    - Leverage existing heap layout (tags, `Custom.id`, `Custom.ctor`, unboxed bitmaps) .
    - `eco.dbg` gets only:
        - The value (pointer/unboxed)
        - A `type_id` (small integer) for the root type

   All deeper type information is found by following references in the global type graph.

3. **Reusable for future reflection**

    - The same type graph can later be surfaced to Elm or kernel APIs for reflection.

---

## 1. Type IDs and Type Graph: Runtime Representation

### 1.1 ID spaces

We define two integer ID spaces:

- `TypeId` (32-bit or 64-bit unsigned)
    - Uniquely identifies a *monomorphized Elm type* within the compiled program.
- `CtorId` (32-bit unsigned)
    - Per‑type constructor index for custom ADTs (0..n‑1).

These correspond to:

- `type_id` attribute on `eco.construct` (already present; currently described as “for custom ADTs” only) . We will generalize it to all Elm types we want to describe.
- The `tag` attribute on `eco.construct` / `eco.allocate_ctor` (currently described as “constructor discriminant (maps to Custom.ctor field)” for custom types) . For custom types, `tag == ctor_id`.

For built‑in types (List, tuples, records, primitives, functions, etc.), we assign `type_id`s but they may have no `CtorId`s (except for built‑in ADTs like `List` treated as a 2‑ctor ADT).

### 1.2 Type graph C++ structures (runtime)

Define shared enums/structs in a header included by both runtime and `EcoToLLVM` (new file, e.g. `TypeInfo.hpp`):

```cpp
enum class EcoTypeKind : uint8_t {
    Primitive,
    List,
    Tuple,
    Record,
    Custom,
    Function,
    // Future: Process, Task, DynRecord, etc.
};

enum class EcoPrimKind : uint8_t {
    Int,
    Float,
    Char,
    Bool,
    String,
    // Possibly Unit as a “primitive” for printing
};

struct EcoFieldInfo {
    uint32_t  name_index;  // index into a string table (field name)
    uint32_t  type_id;     // TypeId of field type
};

struct EcoCtorInfo {
    uint32_t  ctor_id;      // per-type constructor index (0..n-1)
    uint32_t  name_index;   // constructor name in string table
    uint32_t  first_field;  // index into a global field-type array
    uint32_t  field_count;
};

struct EcoTypeInfo {
    uint32_t    type_id;        // unique per monomorphic type
    EcoTypeKind kind;

    // Layout:
    //   For Primitive:
    //       prim_kind: EcoPrimKind
    //   For List:
    //       list_elem_type_id: uint32_t
    //   For Tuple:
    //       tuple_arity
    //       first_field, field_count
    //   For Record:
    //       first_field, field_count
    //   For Custom:
    //       first_ctor, ctor_count
    //   For Function:
    //       first_arg_type, arg_count, result_type_id
    union {
        struct {
            EcoPrimKind prim_kind;
        } primitive;

        struct {
            uint32_t elem_type_id;
        } list;

        struct {
            uint16_t arity;
            uint32_t first_field;  // into global field-type array (no names)
            uint16_t field_count;  // == arity
        } tuple;

        struct {
            uint32_t first_field;  // into global field info array (with names)
            uint32_t field_count;
        } record;

        struct {
            uint32_t first_ctor;   // into ctor array
            uint32_t ctor_count;
        } custom;

        struct {
            uint32_t first_arg_type;  // into global arg-type array
            uint16_t arg_count;
            uint32_t result_type_id;
        } function;
    } data;
};
```

And top‑level containers:

```cpp
struct EcoTypeGraph {
    const EcoTypeInfo* types;
    uint32_t           type_count;

    const EcoFieldInfo* fields;
    uint32_t            field_count;

    const EcoCtorInfo* ctors;
    uint32_t           ctor_count;

    const uint32_t* function_arg_type_ids;
    uint32_t        function_arg_type_count;

    const char* const* strings;  // string table (names)
    uint32_t           string_count;
};
```

We then export a single global instance in the compiled module:

```cpp
extern "C" {
    extern const EcoTypeGraph __eco_type_graph;
}
```

The runtime (debug printer) links against this symbol.

(Exactly how MLIR → LLVM emits these globals is described later.)

---

## 2. Compiler: Type Graph Construction

We build the type graph in two stages:

1. **Assign `TypeId`s to `Mono.MonoType`s** (monomorphization / MLIR emission side).
2. **Emit a serialized representation of all descriptors into the compiled module** (MLIR → LLVM).

### 2.1 TypeId assignment in the Elm compiler backend

We already have machinery to create `type_id`s for custom types when generating constructors:

- In `generateCtor` / `generateEnum` (MLIR.elm) we see:

  ```elm
  maybeTypeName =
      case monoType of
          Mono.MCustom _ typeName _ ->
              Just (Name.toElmString typeName)
          _ -> Nothing

  ( typeId, ctxWithTypeId ) =
      case maybeTypeName of
          Just typeName -> getOrCreateTypeId typeName ctx
          Nothing -> ( Nothing, ctx )
  ``` 

We will generalize this into a global “type registry” keyed by full `Mono.MonoType`:

1. **Extend the MLIR generation `Context`** to include:

   ```elm
   type alias TypeRegistry =
       { nextTypeId : Int
       , typeIds : Dict Mono.MonoType Int
       }

   type alias Context =
       { ...
       , typeRegistry : TypeRegistry
       }
   ```

2. **Add helper**:

   ```elm
   getOrCreateTypeIdForMonoType : Mono.MonoType -> Context -> ( Int, Context )
   ```

    - If `Mono.MonoType` is in `ctx.typeRegistry.typeIds`, return the existing id.
    - Otherwise, assign `nextTypeId`, increment it, and insert into the dict.

3. **Use this for all relevant types**:

    - When emitting any heap value via `ecoConstruct`, compute the semantic type of the result and ask for a `type_id`:

        - Custom ADTs: already present; now call `getOrCreateTypeIdForMonoType` instead of the old custom‑only helper.
        - Records: `Mono.MRecord layout` in `Mono.MonoType` .
        - Tuples: `Mono.MTuple layout`.
        - Lists: `Mono.MList inner`.
        - Unit, Maybe, Result, etc. all end up as `MCustom` or other concrete variants in `Mono.MonoType`.

    - `ecoConstruct` already accepts optional `type_id`:

      ```mlir
      OptionalAttr<I64Attr>:$type_id  
      ```

      So for every heap‑allocated Elm value that you want debug printing for, set this attribute to the TypeId you just obtained.

4. **Collect a complete set of `Mono.MonoType`s**:

    - The `TypeRegistry` sits in the same `Context` that’s threaded through all `generateExpr` calls in `MLIR.elm` .
    - Each time you:
        - Emit `eco.construct` for a value of some `Mono.MonoType`,
        - Or recognize a non‑heap primitive type (Int, Float, Char, Bool, String, Function),
          you ensure `getOrCreateTypeIdForMonoType` is called.

By the end of MLIR generation, `ctx.typeRegistry` holds:

- A mapping `Mono.MonoType -> TypeId` for all types you care about.
- The maximum TypeId used (`nextTypeId - 1`).

### 2.2 Serializing the graph into MLIR

We need to get these descriptors into the MLIR module so EcoToLLVM can lower them to LLVM globals.

One concrete design:

1. **Introduce a module‑level op** in the Eco dialect:

   ```tablegen
   def Eco_TypeTableOp : Eco_Op<"type_table"> {
     let summary = "Global type information graph for debug/reflection";
     let description = [{
       Holds a serialized description of all monomorphized types in this program.
       Used by eco.dbg and, in the future, reflection.
     }];

     let arguments = (ins);
     let results   = (outs);

     // attributes:
     //   - types      : ArrayAttr of DictionaryAttr (each describing one type)
     //   - fields     : ArrayAttr of DictionaryAttr (field entries)
     //   - ctors      : ArrayAttr of DictionaryAttr (ctor entries)
     //   - func_args  : ArrayAttr of I64Attr (flattened arg type ids)
     //   - strings    : ArrayAttr of StrAttr  (string table: names)

     let hasCustomAssemblyFormat = 1;
   }
   ```

2. **Populate Eco_TypeTableOp at the end of MLIR emission**:

    - After generating all functions/ops, traverse `ctx.typeRegistry.typeIds` and produce:

        - `types`:
            - For each `Mono.MonoType` with `type_id`:
                - Compute:
                    - `kind` : one of `"primitive" | "list" | "tuple" | "record" | "custom" | "function"`.
                    - For each kind, compute subfields (field ranges, elem type id, ctor ranges, etc.).
                - Store as a `DictionaryAttr` with keys:
                    - `"type_id"` : IntAttr
                    - `"kind"`    : StrAttr
                    - `"first_field"`, `"field_count"` etc. as needed.

        - `fields`:
            - Flatten all record and tuple fields into an array of entries:
                - `"name_index"`: IntAttr
                - `"type_id"`   : IntAttr

        - `ctors`:
            - For each `MCustom` / Elm custom type:
                - For each constructor:
                    - `"ctor_id"`     : IntAttr
                    - `"name_index"`  : IntAttr
                    - `"first_field"` : IntAttr
                    - `"field_count"` : IntAttr

        - `func_args`:
            - Flatten all function argument type ids into a single array; each `Function` type in `types` stores an offset into this array.

        - `strings`:
            - Build a deduplicated string table of *all* names:
                - Type names (`Module.Type` or alias names if desired).
                - Constructor names.
                - Record field names.

    - Emit a single `eco.type_table` op in the module region, with all these attributes set.

   This can be done in `MLIR.elm` by adding an extra “module finalization” step that runs after all functions are emitted, or by accumulating “type descriptor pending entries” in the context and emitting the op at the end.

3. **Determinism**

    - Ensure deterministic iteration order over `Dict` when building arrays so type_ids map to stable indices in `types`, `fields`, `ctors`, `func_args`, `strings`.
    - Easiest is to use a `List` of `(Mono.MonoType, type_id)` sorted by `type_id`.

---

## 3. eco.dbg: IR and Lowering Changes

### 3.1 Extend Eco_DbgOp to carry TypeIds per arg

Current definition:

```tablegen
def Eco_DbgOp : Eco_Op<"dbg"> {
  let arguments = (ins Variadic<Eco_AnyValue>:$args);
  let results   = (outs);
}
``` 

Extend with an optional attribute:

```tablegen
def Eco_DbgOp : Eco_Op<"dbg"> {
  let arguments = (ins Variadic<Eco_AnyValue>:$args);
  let results   = (outs);

  // New: arg types as TypeIds, one per arg
  let extraClassDeclaration = [{
    static constexpr llvm::StringLiteral getArgTypeIdsAttrName() { 
      return "arg_type_ids"; 
    }
  }];

  // Attribute: DenseI64ArrayAttr or ArrayAttr of I64Attr
  //   DenseI64ArrayAttr:$arg_type_ids

  let hasCustomAssemblyFormat = 1;
}
```

Concrete ODS snippet:

```tablegen
let arguments = (ins Variadic<Eco_AnyValue>:$args);
let results   = (outs);
let assemblyFormat = "($args^ `:` type($args))? "
                     "(`arg_type_ids` `=` $arg_type_ids^)? "
                     "attr-dict";
```

### 3.2 Emitting arg_type_ids in MLIR.elm

In `generateExpr`, when you emit an `eco.dbg` (today you probably use `Eco_DbgOp` only in tests; you can add a frontend Debug.log mapping later), you know the Elm types of all arguments.

Add a helper:

```elm
emitEcoDbg : Context -> List ExprResult -> ( Context, MlirOp )
emitEcoDbg ctx args =
    let
        argVars  = List.map .resultVar args
        argTypes = List.map .resultType args  -- MLIR types

        -- Map Elm Mono.MonoType of each argument to TypeId
        argElmTypes : List Mono.MonoType
        argElmTypes = ... -- from the surrounding context / AST

        ( typeIds, ctx1 ) =
            List.foldl
                (\ty (acc, c) ->
                    let
                        (tid, c1) = getOrCreateTypeIdForMonoType ty c
                    in
                    (tid :: acc, c1)
                )
                ([], ctx)
                argElmTypes
                |> Tuple.mapFirst List.reverse

        argTypeIdsAttr =
            DenseI64ArrayAttr typeIds  -- or ArrayAttr of IntAttr
    in
    mlirOp ctx1 "eco.dbg"
        |> opBuilder.withOperands argVars
        |> opBuilder.withAttrs
            (Dict.singleton "arg_type_ids" argTypeIdsAttr)
        |> opBuilder.build
```

### 3.3 Lowering Eco_DbgOp to LLVM

In `EcoToLLVM.cpp`, add/modify the pattern for `Eco_DbgOp`:

1. **If `arg_type_ids` is present**:

    - Let `n = args.size`.
    - Allocate two arrays on the LLVM stack:

      ```mlir
      %vals = llvm.alloca %c_n : i32 -> !llvm.ptr<i64>
      %tys  = llvm.alloca %c_n : i32 -> !llvm.ptr<i32>
      ```

    - For each argument i:
        - Convert the MLIR value to a 64‑bit representation in `vals[i]`:
            - If the arg is `!eco.value` (heap pointer), just bitcast to `i64`.
            - If the arg is primitive (`i64`, `f64`, `i1`, `i16`), extend/bitcast to `i64` in the same way `eco_dbg_print_int/float/char` expect.
        - Load the i‑th `type_id` from the `arg_type_ids` attribute (compile‑time constant) and store into `tys[i]` as `i32`.

    - Call a new runtime function:

      ```c
      extern "C"
      void eco_dbg_print_typed(uint64_t* values,
                               uint32_t* type_ids,
                               uint32_t num_args);
      ```

      lowering the MLIR call to:

      ```mlir
      llvm.call @eco_dbg_print_typed(%vals, %tys, %c_n) : (!llvm.ptr<i64>, !llvm.ptr<i32>, i32) -> ()
      ```

2. **If `arg_type_ids` absent** (backwards compatibility / tests):

    - Keep the current behavior:
        - If all args are `!eco.value`, call `eco_dbg_print(values, num_args)` .
        - Or use specialized `eco_dbg_print_int/float/char` for single primitives.

---

## 4. Runtime: eco_dbg_print_typed Implementation

### 4.1 Exposed function

Add to `RuntimeExports.h` (near `eco_dbg_print`):

```c
/// Debug print for typed values (for eco.dbg with type graph).
/// @param values   Array of 64-bit values (pointers or unboxed numbers)
/// @param type_ids Array of TypeIds (one per value)
/// @param num_args Number of values
void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args);
```  (this file already hosts dbg and print exports).

### 4.2 Accessing the type graph

In the runtime library, declare:

```cpp
extern "C" {
    extern const EcoTypeGraph __eco_type_graph;
}
```

(Structs from §1.2 live in a shared header.)

Helper functions:

```cpp
static const EcoTypeInfo* lookupType(uint32_t type_id) {
    // scan or binary search __eco_type_graph.types[0..type_count)
    // if you ensure type_id is an index, you can index directly.
}

static const char* lookupString(uint32_t name_index) {
    return (name_index < __eco_type_graph.string_count)
        ? __eco_type_graph.strings[name_index]
        : "<invalid>";
}
```

### 4.3 Core printing algorithm

Pseudocode for `eco_dbg_print_typed`:

```cpp
void eco_dbg_print_typed(uint64_t* values,
                         uint32_t* type_ids,
                         uint32_t num_args) {
    for (uint32_t i = 0; i < num_args; ++i) {
        printValueTyped(values[i], type_ids[i]);
        eco_output_text("\n");
    }
}
```

`printValueTyped` dispatches by `EcoTypeKind`:

```cpp
void printValueTyped(uint64_t raw, uint32_t type_id) {
    const EcoTypeInfo* t = lookupType(type_id);
    if (!t) {
        eco_output_text("<unknown-type>");
        return;
    }

    switch (t->kind) {
    case EcoTypeKind::Primitive:
        printPrimitive(raw, t->data.primitive.prim_kind);
        break;

    case EcoTypeKind::List:
        printList(raw, t->data.list.elem_type_id);
        break;

    case EcoTypeKind::Tuple:
        printTuple(raw, t);
        break;

    case EcoTypeKind::Record:
        printRecord(raw, t);
        break;

    case EcoTypeKind::Custom:
        printCustom(raw, t);
        break;

    case EcoTypeKind::Function:
        printFunction(raw, t);
        break;
    }
}
```

Key cases:

#### 4.3.1 Primitive

Map `EcoPrimKind` to existing helpers:

```cpp
void printPrimitive(uint64_t raw, EcoPrimKind k) {
    switch (k) {
    case EcoPrimKind::Int:
        eco_dbg_print_int((int64_t)raw);
        break;
    case EcoPrimKind::Float: {
        double d;
        static_assert(sizeof(d) == sizeof(raw));
        std::memcpy(&d, &raw, sizeof(d));
        eco_dbg_print_float(d);
        break;
    }
    case EcoPrimKind::Char:
        eco_dbg_print_char((int32_t)raw);
        break;
    case EcoPrimKind::Bool:
        eco_output_text(raw ? "True" : "False");
        break;
    case EcoPrimKind::String:
        eco_print_value(raw);  // treat as ElmString pointer
        break;
    }
}
```

#### 4.3.2 List

List heap layout:

```cpp
typedef struct {
    Header header; // Header.unboxed indicates if head is unboxed.
    Unboxable head;
    HPointer tail;
} Cons;  
```

Algorithm:

```cpp
void printList(uint64_t raw, uint32_t elem_type_id) {
    // Handle empty list via constants (Const_Nil) or Tag_Cons
    if (isNilConstant(raw)) {
        eco_output_text("[]");
        return;
    }

    eco_output_text("[");
    bool first = true;
    HPointer hp = (HPointer)raw;  // tagged pointer → raw pointer

    while (!isNilCons(hp)) {
        Cons* cons = (Cons*)unwrap(hp);  // depends on HPointer encoding
        bool headUnboxed = cons->header.unboxed != 0;  // single bit

        if (!first) eco_output_text(", ");
        first = false;

        const EcoTypeInfo* elemType = lookupType(elem_type_id);
        if (!elemType) {
            eco_output_text("<unknown-elem>");
        } else if (headUnboxed && elemType->kind == EcoTypeKind::Primitive) {
            // Interpret Unboxable as primitive bits
            printPrimitive(cons->head.bits, elemType->data.primitive.prim_kind);
        } else {
            // head stored boxed; cons->head.ptr is HPointer to heap
            uint64_t elemRaw = cons->head.bits;  // or decode pointer
            printValueTyped(elemRaw, elem_type_id);
        }

        hp = cons->tail;
    }

    eco_output_text("]");
}
```

So the **type graph** provides `elem_type_id` and `prim_kind`; the **heap** provides “is this slot unboxed?” via `header.unboxed`. No extra heap fields required.

#### 4.3.3 Tuple

Tuples:

```cpp
typedef struct {
    Header header; // Header.unboxed indicates which fields are unboxed.
    Unboxable a;
    Unboxable b;
} Tuple2;

typedef struct {
    Header header; // Header.unboxed indicates which fields are unboxed.
    Unboxable a;
    Unboxable b;
    Unboxable c;
} Tuple3;  
```

Using the type descriptor:

- `t->data.tuple.arity`
- `t->data.tuple.first_field` .. `field_count`: an array of field `type_id`s (no names).

Algorithm:

```cpp
void printTuple(uint64_t raw, const EcoTypeInfo* t) {
    uint16_t arity = t->data.tuple.field_count;
    eco_output_text("(");

    // Map raw pointer to Tuple2/Tuple3 based on heap Tag_Tuple2/Tuple3
    void* ptr = unwrap((HPointer)raw);
    uint64_t unboxedMask = ((Header*)ptr)->unboxed;

    for (uint16_t i = 0; i < arity; ++i) {
        if (i > 0) eco_output_text(", ");

        uint32_t fieldTypeId = getTupleFieldTypeId(t, i);  // from global field array
        const EcoTypeInfo* fieldType = lookupType(fieldTypeId);

        Unboxable val = getTupleField(ptr, i);  // a/b/c

        bool isUnboxed = (unboxedMask & (1ull << i)) != 0;

        if (isUnboxed && fieldType && fieldType->kind == EcoTypeKind::Primitive) {
            printPrimitive(val.bits, fieldType->data.primitive.prim_kind);
        } else {
            uint64_t fieldRaw = val.bits;
            printValueTyped(fieldRaw, fieldTypeId);
        }
    }

    eco_output_text(")");
}
```

#### 4.3.4 Record

Records:

```cpp
typedef struct {
    Header header; // Header.size contains field count.
    u64 unboxed;   // Bitmap: bit N set means field N is unboxed.
    Unboxable values[];
} Record;  
```

Type descriptor:

- `t->data.record.first_field` / `field_count`.
- In global field array, each `EcoFieldInfo` has:
    - `name_index` → string table entry for field name.
    - `type_id`    → field type.

Algorithm:

```cpp
void printRecord(uint64_t raw, const EcoTypeInfo* t) {
    Record* rec = (Record*)unwrap((HPointer)raw);
    uint64_t unboxedMask = rec->unboxed;

    eco_output_text("{");

    for (uint32_t i = 0; i < t->data.record.field_count; ++i) {
        if (i > 0) eco_output_text(", ");

        const EcoFieldInfo* fi = &__eco_type_graph.fields[t->data.record.first_field + i];
        const char* fname = lookupString(fi->name_index);
        const EcoTypeInfo* fType = lookupType(fi->type_id);

        eco_output_text(fname);
        eco_output_text(" = ");

        Unboxable val = rec->values[i];
        bool isUnboxed = (unboxedMask & (1ull << i)) != 0;

        if (isUnboxed && fType && fType->kind == EcoTypeKind::Primitive) {
            printPrimitive(val.bits, fType->data.primitive.prim_kind);
        } else {
            printValueTyped(val.bits, fi->type_id);
        }
    }

    eco_output_text("}");
}
```

#### 4.3.5 Custom ADTs

Custom layout:

```cpp
typedef struct {
    Header header;           // Header.size: field count
    u64 ctor : CTOR_BITS;    // per-type constructor index
    u64 id   : ID_BITS;      // TypeId
    u64 unboxed : 32;        // Bitmap
    Unboxable values[];
} Custom;  
```

Type descriptor:

- `t->data.custom.first_ctor` / `ctor_count`.
- Each `EcoCtorInfo` has:
    - `ctor_id`, `name_index`, `first_field`, `field_count`.

Algorithm:

```cpp
void printCustom(uint64_t raw, const EcoTypeInfo* t) {
    Custom* obj = (Custom*)unwrap((HPointer)raw);
    uint32_t ctorId = obj->ctor;
    uint64_t unboxedMask = obj->unboxed;

    const EcoCtorInfo* ci = findCtorForType(t, ctorId);
    if (!ci) {
        eco_output_text("<unknown-ctor>");
        return;
    }

    const char* ctorName = lookupString(ci->name_index);
    eco_output_text(ctorName);

    if (ci->field_count == 0) return;

    eco_output_text(" ");

    for (uint32_t i = 0; i < ci->field_count; ++i) {
        if (i > 0) eco_output_text(" ");

        uint32_t fieldTypeId = getCtorFieldTypeId(ci, i);
        const EcoTypeInfo* fType = lookupType(fieldTypeId);
        Unboxable val = obj->values[i];
        bool isUnboxed = (unboxedMask & (1ull << i)) != 0;

        if (isUnboxed && fType && fType->kind == EcoTypeKind::Primitive) {
            printPrimitive(val.bits, fType->data.primitive.prim_kind);
        } else {
            printValueTyped(val.bits, fieldTypeId);
        }
    }
}
```

#### 4.3.6 Function

For function types, there is no standard Elm syntax in Debug; you might print a placeholder:

```cpp
void printFunction(uint64_t raw, const EcoTypeInfo* t) {
    eco_output_text("<function:");
    // Optionally print a type signature from arg/result type_ids.
    eco_output_text(">");
}
```

---

## 5. Example: Struct = List SomeRecord

From your example:

```elm
type alias Inner      = { a : Int, b : Float }
type alias SomeRecord = { inner : Inner }
Struct = List SomeRecord
```

### 5.1 Type graph entries

Assume we assign:

- `type_id(Inner)      = 10`
- `type_id(SomeRecord) = 11`
- `type_id(Struct)     = 12`

Then:

- `types[10]`: kind = Record, `first_field = i0`, `field_count = 2`
    - `fields[i0 + 0]`: `{name_index = "a", type_id = IntTypeId}`
    - `fields[i0 + 1]`: `{name_index = "b", type_id = FloatTypeId}`

- `types[11]`: kind = Record, `first_field = i2`, `field_count = 1`
    - `fields[i2 + 0]`: `{name_index = "inner", type_id = 10}`

- `types[12]`: kind = List, `elem_type_id = 11`

When you emit `eco.dbg` for a value `v : Struct`, you set `arg_type_ids = [12]`.

### 5.2 Printing

- `eco_dbg_print_typed(values = [&v], type_ids = [12])`:
    - `printValueTyped(v, 12)`:
        - sees `kind = List`, `elem_type_id = 11` → `printList(v, 11)`:
            - for each cons cell:
                - looks up `type_id = 11`, record descriptor.
                - prints `{ inner = { a = 1, b = 2.0 } }` using `printRecord` logic, which itself uses `type_id = 10` for `inner` field.

All nested `Inner`/`SomeRecord` field structure flows from the type graph; no nested type info is passed explicitly in the eco.dbg call.

---

## 6. Summary of Implementation Steps

1. **Runtime:**
    - Add `EcoTypeKind`, `EcoPrimKind`, `EcoTypeInfo`, `EcoFieldInfo`, `EcoCtorInfo`, `EcoTypeGraph` structs.
    - Add `extern const EcoTypeGraph __eco_type_graph;`.
    - Implement `eco_dbg_print_typed` and the helpers in §4.

2. **Dialect & MLIR:**
    - Add `Eco_TypeTableOp` (module‑level) with attributes `types`, `fields`, `ctors`, `func_args`, `strings`.
    - Extend `Eco_DbgOp` with `arg_type_ids : DenseI64ArrayAttr` (or similar) and parsing/printing.
    - Add/extend EcoToLLVM patterns:
        - Lower `eco.type_table` to LLVM globals matching `EcoTypeGraph`.
        - Lower `eco.dbg` with `arg_type_ids` to `eco_dbg_print_typed`.

3. **Elm backend (MLIR.elm / Monomorphize.elm):**
    - Add a `TypeRegistry` to `Context` and `getOrCreateTypeIdForMonoType`.
    - Whenever you work with a `Mono.MonoType` that can reach `eco.dbg` or heap, assign a `type_id` if not present.
    - Set `type_id` attribute on all `eco.construct` uses where you want debug printing.
    - At the end of module emission, traverse `TypeRegistry` to build and emit a single `eco.type_table` op with descriptor attributes.
    - When emitting `eco.dbg`, add `arg_type_ids` based on the `Mono.MonoType` of each argument.

This gives you:

- A single global type graph representing the full type structure of the compiled program.
- A type‑aware `eco.dbg` that can pretty‑print arbitrary nested data, including unboxed fields, using that graph.
- A foundation you can later repurpose for Elm‑level reflection without revisiting the basic representation.

