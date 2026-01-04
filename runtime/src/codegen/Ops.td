//===- EcoOps.td - Eco dialect operations -------------------------*- tablegen -*-===//
//
// MLIR ODS definitions for the Eco dialect operations.
//
// The Eco dialect represents Elm programs after monomorphization, before
// lowering to LLVM. It captures functional programming constructs (ADTs,
// closures, pattern matching) in a form amenable to compilation with a
// tracing garbage collector.
//
//===----------------------------------------------------------------------===//

include "mlir/IR/OpBase.td"
include "mlir/IR/SymbolInterfaces.td"
include "mlir/IR/EnumAttr.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"

//===----------------------------------------------------------------------===//
// Dialect Definition
//===----------------------------------------------------------------------===//

def Eco_Dialect : Dialect {
  let name = "eco";
  let cppNamespace = "::eco";
  let summary = "Eco dialect for compiled Elm programs";
  let description = [{
    The Eco dialect represents Elm programs after monomorphization,
    before lowering to LLVM. It captures functional programming constructs
    (ADTs, closures, pattern matching) in a form amenable to compilation
    with a tracing garbage collector.

    Key design decisions:
    - `eco.value` is an opaque pointer to heap-allocated Elm values
    - Primitives (Int, Float, Char, Bool) can be unboxed as i64, f64, i32, i1
    - No write barriers needed due to Elm's immutability
    - GC integration via safepoints and stack maps
  }];
  let useDefaultTypePrinterParser = 1;
}

//===----------------------------------------------------------------------===//
// Type Definitions
//===----------------------------------------------------------------------===//

class Eco_Type<string name, string typeMnemonic, list<Trait> traits = []>
    : TypeDef<Eco_Dialect, name, traits> {
  let mnemonic = typeMnemonic;
}

def Eco_ValueType : Eco_Type<"Value", "value"> {
  let summary = "Eco heap value pointer";
  let description = [{
    An opaque pointer to a heap-allocated Elm value. Represents boxed
    values including ADTs, records, closures, and strings. During
    lowering, this becomes `ptr addrspace(1)` in LLVM IR.

    The underlying heap object has a 64-bit header containing:
    - tag: identifies the object type (Int, String, Cons, Custom, etc.)
    - GC metadata: color, age, refcount
    - size: type-specific size information
  }];

  // Builder call enables auto-generation in assembly formats
  let builderCall = "$_builder.getType<eco::ValueType>()";
}

//===----------------------------------------------------------------------===//
// Type Constraints
//===----------------------------------------------------------------------===//

// Boxed heap value
def Eco_Value : Type<CPred<"llvm::isa<eco::ValueType>($_self)">,
                     "eco.value",
                     "eco::ValueType">,
                     BuildableType<"$_builder.getType<eco::ValueType>()">;

//===----------------------------------------------------------------------===//
// Constant Attribute Definition
//===----------------------------------------------------------------------===//

// ConstantKind enum matching Heap.hpp Constant enum
// Values 1-7 (0 means regular pointer, not a constant)
def Eco_ConstantKind : I32EnumAttr<"ConstantKind", "Eco embedded constant kind", [
  I32EnumAttrCase<"Unit", 1>,        // Const_Unit
  I32EnumAttrCase<"EmptyRec", 2>,    // Const_EmptyRec
  I32EnumAttrCase<"True", 3>,        // Const_True
  I32EnumAttrCase<"False", 4>,       // Const_False
  I32EnumAttrCase<"Nil", 5>,         // Const_Nil
  I32EnumAttrCase<"Nothing", 6>,     // Const_Nothing
  I32EnumAttrCase<"EmptyString", 7>  // Const_EmptyString
]> {
  let cppNamespace = "::eco";
}

// Unboxed primitive types matching Elm semantics
def Eco_Int   : I<64>;   // Elm Int (64-bit signed)
def Eco_Float : F<64>;   // Elm Float (IEEE 754 double)
def Eco_Char  : I<16>;   // Elm Char (Unicode BMP code point)
def Eco_Bool  : I<1>;    // Elm Bool (True/False)

// Any value that can appear in Eco operations (boxed or unboxed)
def Eco_AnyValue : AnyTypeOf<[Eco_Value, Eco_Int, Eco_Float, Eco_Char, Eco_Bool],
                              "eco value or primitive">;

//===----------------------------------------------------------------------===//
// Base Op Class
//===----------------------------------------------------------------------===//

class Eco_Op<string mnemonic, list<Trait> traits = []>
    : Op<Eco_Dialect, mnemonic, traits>;

//===----------------------------------------------------------------------===//
// 1. Control Flow Operations
//===----------------------------------------------------------------------===//

def Eco_CaseOp : Eco_Op<"case", [
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>
]> {
  let summary = "Pattern match on ADT constructor tag";
  let description = [{
    Pattern match on an ADT's constructor tag and branch to one of several
    regions. Each region handles a specific constructor tag.

    The `result_types` attribute specifies the MLIR representation types
    returned from this case (e.g., `[!eco.value]`, `[]`, `[i64, !eco.value]`).
    All `eco.return` ops reachable from each alternative must have operand
    types matching this list.

    Example:
    ```mlir
    eco.case %scrutinee [0, 1] result_types [!eco.value] {
      // tag 0 alternative (e.g., Nil)
      eco.return %nil_result : !eco.value
    }, {
      // tag 1 alternative (e.g., Cons)
      %head = eco.project %scrutinee[0] : !eco.value -> !eco.value
      eco.return %head : !eco.value
    }
    ```

    Regions take no arguments; code inside uses eco.project to extract fields
    from the scrutinee. Each region must terminate with eco.return or eco.jump.
  }];

  let arguments = (ins
    Eco_AnyValue:$scrutinee,                   // Accepts !eco.value or i1 (Bool)
    DenseI64ArrayAttr:$tags,
    OptionalAttr<ArrayAttr>:$caseResultTypes  // Array of TypeAttr for SCF lowering
  );
  let regions = (region VariadicRegion<AnyRegion>:$alternatives);
  let results = (outs);

  let hasVerifier = 1;
  let hasCustomAssemblyFormat = 1;
}

def Eco_ReturnOp : Eco_Op<"return", [
    Pure,
    Terminator,
    ReturnLike
]> {
  let summary = "Return from Eco function or region";
  let description = [{
    Return from an Eco function with optional result values. Also used
    to terminate regions in eco.case and eco.joinpoint.

    Example:
    ```mlir
    eco.return %result : !eco.value
    eco.return  // void return
    ```
  }];

  let arguments = (ins Variadic<Eco_AnyValue>:$results);
  let results = (outs);

  let builders = [
    OpBuilder<(ins), [{
      build($_builder, $_state, ValueRange{});
    }]>
  ];

  let assemblyFormat = "($results^ `:` type($results))? attr-dict";
}

def Eco_JoinpointOp : Eco_Op<"joinpoint", [
    RecursiveMemoryEffects
]> {
  let summary = "Define joinpoint for local loops/tail recursion";
  let description = [{
    Defines a joinpoint (local label/loop head) with parameters and a body
    region, plus a continuation region for code after the joinpoint.
    Used for efficient local loops and tail recursion.

    The joinpoint body region's block arguments serve as the joinpoint
    parameters. These are passed via eco.jump operations.

    The `result_types` attribute specifies the MLIR representation types
    of values ultimately returned via `eco.return` reachable from this
    joinpoint and its continuation. Typically matches the enclosing
    function's return types.

    Example:
    ```mlir
    eco.joinpoint 0(%acc: i64, %n: i64) result_types [i64] {
      // Loop body - can jump back or fall through
      %done = arith.cmpi eq, %n, %c0 : i64
      cf.cond_br %done, ^exit, ^recurse
    ^exit:
      eco.return %acc : i64
    ^recurse:
      %new_acc = arith.addi %acc, %n : i64
      %new_n = arith.subi %n, %c1 : i64
      eco.jump 0(%new_acc, %new_n : i64, i64)
    } continuation {
      // Code after joinpoint definition
    }
    ```
  }];

  let arguments = (ins
    I64Attr:$id,
    OptionalAttr<ArrayAttr>:$jpResultTypes  // Array of TypeAttr for SCF lowering
  );
  let regions = (region
    SizedRegion<1>:$body,
    AnyRegion:$continuation
  );
  let results = (outs);

  let hasVerifier = 1;
  let hasCustomAssemblyFormat = 1;
}

def Eco_JumpOp : Eco_Op<"jump", [Terminator]> {
  let summary = "Jump to joinpoint";
  let description = [{
    Jump to a previously-defined eco.joinpoint, passing arguments that match
    the joinpoint's parameters. This is like a tail call to a local function.

    Example:
    ```mlir
    eco.jump 0(%new_acc, %new_n : i64, i64)
    ```
  }];

  let arguments = (ins
    I64Attr:$target,
    Variadic<Eco_AnyValue>:$args
  );
  let results = (outs);

  let assemblyFormat = "$target `(` $args `:` type($args) `)` attr-dict";
}

def Eco_CrashOp : Eco_Op<"crash", [Terminator]> {
  let summary = "Unconditional crash/panic";
  let description = [{
    Unconditional crash (panic). Lowers to a call into the Eco runtime
    panic handler followed by unreachable.

    Example:
    ```mlir
    eco.crash %error_message : !eco.value
    ```
  }];

  let arguments = (ins Eco_Value:$message);
  let results = (outs);

  let assemblyFormat = "$message attr-dict `:` type($message)";
}

def Eco_ExpectOp : Eco_Op<"expect"> {
  let summary = "Debug assertion (Elm's Debug.todo/crash path)";
  let description = [{
    Runtime assertion that checks a condition and crashes with a message
    if false. The passthrough value flows through unchanged when the
    condition is true.

    Example:
    ```mlir
    %result = eco.expect %cond, %msg, %value : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Bool:$condition,
    Eco_Value:$message,
    Eco_AnyValue:$passthrough
  );
  let results = (outs Eco_AnyValue:$result);

  let assemblyFormat = "$condition `,` $message `,` $passthrough attr-dict `:` type($passthrough) `->` type($result)";
}

def Eco_DbgOp : Eco_Op<"dbg"> {
  let summary = "Debug/logging operation";
  let description = [{
    Debug/log operation for development. Can be lowered to runtime
    debug print calls or stripped entirely in release builds.

    Example:
    ```mlir
    eco.dbg %value1, %value2 : !eco.value, i64
    ```
  }];

  let arguments = (ins Variadic<Eco_AnyValue>:$args);
  let results = (outs);

  let assemblyFormat = "($args^ `:` type($args))? attr-dict";
}

//===----------------------------------------------------------------------===//
// 2. ADT Construction and Projection
//===----------------------------------------------------------------------===//

def Eco_GetTagOp : Eco_Op<"get_tag", [Pure]> {
  let summary = "Extract constructor tag from ADT value";
  let description = [{
    Extract the constructor tag (discriminant) from an ADT value.
    This encapsulates the header/ctor field extraction logic.

    Used by SCF lowering to implement pattern matching via scf.if/scf.index_switch.

    Example:
    ```mlir
    %tag = eco.get_tag %value : !eco.value -> i32
    ```
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs I32:$tag);

  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($tag)";
}

def Eco_ConstructOp : Eco_Op<"construct", [Pure]> {
  let summary = "Construct ADT/record/tuple value";
  let description = [{
    Create an algebraic data type (ADT) value for a specific constructor.
    This is a high-level, pure operation representing both allocation and
    field initialization. It will be lowered to allocation + stores.

    The tag is the numeric constructor discriminant. The size must match
    the number of field operands. The unboxed_bitmap indicates which fields
    are unboxed primitives (bit N is set if field N is unboxed).

    Example:
    ```mlir
    // Construct a value with 4 fields
    %val = eco.construct(%f0, %f1, %f2, %f3) {
      tag = 0,
      size = 4,
      unboxed_bitmap = 0
    } : (!eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$fields,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<I64Attr>:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;

  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";
}

def Eco_ProjectOp : Eco_Op<"project", [Pure]> {
  let summary = "Project field from ADT value";
  let description = [{
    Project a field out of a constructor (ADT) value by index.
    No runtime tag checking is performed; using this on the wrong
    constructor is undefined behavior.

    The result type depends on the field's known type from monomorphization.
    It may be eco.value (boxed) or a primitive type (unboxed).

    Example:
    ```mlir
    // Extract head from Cons cell
    %head = eco.project %cons[0] : !eco.value -> !eco.value

    // Extract unboxed Int field from tuple
    %x = eco.project %point[0] : !eco.value -> i64
    ```
  }];

  let arguments = (ins
    Eco_Value:$value,
    I64Attr:$index
  );
  let results = (outs Eco_AnyValue:$field);

  let assemblyFormat = "$value `[` $index `]` attr-dict `:` type($value) `->` type($field)";
}

//===----------------------------------------------------------------------===//
// 3. String Operations
//===----------------------------------------------------------------------===//

def Eco_StringLiteralOp : Eco_Op<"string_literal", [Pure]> {
  let summary = "Create Eco string from literal";
  let description = [{
    Creates an Eco string value from a compile-time literal. The string
    is stored in read-only memory and the operation returns a pointer to it.

    Strings are UTF-16 encoded internally (matching Elm's String type).

    Example:
    ```mlir
    %hello = eco.string_literal "Hello, World!"
    ```
  }];

  let arguments = (ins StrAttr:$value);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$value attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 4. Call and Closure Operations
//===----------------------------------------------------------------------===//

def Eco_CallOp : Eco_Op<"call"> {
  let summary = "Call function or closure";
  let description = [{
    Function/closure application. Used for both direct calls to known
    functions and indirect calls through closures.

    For direct calls, specify the callee attribute:
    ```mlir
    %result = eco.call @function_name(%arg1, %arg2)
      : (!eco.value, i64) -> !eco.value
    ```

    For indirect calls, omit callee and pass closure as first operand.
    The remaining_arity attribute specifies how many arguments the closure
    needs. This must equal the number of additional operands (saturated call).
    ```mlir
    %result = "eco.call"(%closure, %arg) {remaining_arity = 1 : i64}
      : (!eco.value, !eco.value) -> !eco.value
    ```

    For partial application of closures, use eco.papExtend instead.

    Set musttail = true for tail calls that must be compiled as proper
    tail calls (for tail recursion). The call must be in tail position.
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$operands,
    OptionalAttr<FlatSymbolRefAttr>:$callee,
    OptionalAttr<BoolAttr>:$musttail,
    OptionalAttr<I64Attr>:$remaining_arity  // For indirect calls
  );
  let results = (outs Variadic<Eco_AnyValue>:$results);
}

def Eco_PapCreateOp : Eco_Op<"papCreate", [Pure]> {
  let summary = "Create partial application closure";
  let description = [{
    Create a closure representing a partial application (PAP) of a function
    with some captured arguments. The remaining arity after creation is
    (arity - num_captured).

    Example:
    ```mlir
    // Partially apply `add` with first argument captured
    %add_5 = eco.papCreate @add(%five) {
      arity = 2 : i32,
      num_captured = 1 : i32
    } : (i64) -> !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$captured,
    FlatSymbolRefAttr:$function,
    I64Attr:$arity,
    I64Attr:$num_captured
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;
}

def Eco_PapExtendOp : Eco_Op<"papExtend"> {
  let summary = "Extend closure with more arguments";
  let description = [{
    Extend an existing partial application (closure) with more arguments.
    This handles curried function application.

    If the closure becomes fully saturated (all arguments provided), this
    triggers the actual function call and returns the result. Otherwise,
    returns a new closure with the additional captured arguments.

    The remaining_arity attribute specifies the closure's remaining arity
    before this application. This is known statically from Elm's type system.
    If remaining_arity == newargs.size(), this is a saturated call.

    Example:
    ```mlir
    // Apply one more argument to a partially applied function (arity 1 remaining)
    // This saturates the closure, so it becomes a direct call
    %result = eco.papExtend %closure(%arg) {remaining_arity = 1 : i64}
      : !eco.value, (i64) -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Value:$closure,
    Variadic<Eco_AnyValue>:$newargs,
    I64Attr:$remaining_arity
  );
  let results = (outs Eco_AnyValue:$result);
}

//===----------------------------------------------------------------------===//
// 5. Allocation and GC Operations
//===----------------------------------------------------------------------===//

def Eco_AllocateOp : Eco_Op<"allocate"> {
  let summary = "Generic heap allocation";
  let description = [{
    Allocate a heap object of the specified size. This is a low-level
    operation typically introduced during lowering of eco.construct.

    The type attribute identifies the object type for GC purposes.
    If needs_root is true, the allocation is registered as a GC root
    during construction (for multi-field objects being initialized).

    Example:
    ```mlir
    %obj = eco.allocate %size {
      type = @"Custom.MyType",
      needs_root = true
    } : (i64) -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Int:$size,
    FlatSymbolRefAttr:$type,
    BoolAttr:$needs_root
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$size attr-dict `:` type($size) `->` type($result)";
}

def Eco_AllocateCtorOp : Eco_Op<"allocate_ctor"> {
  let summary = "Allocate constructor object";
  let description = [{
    Allocate space for a constructor object with the specified tag and
    field count. This is a specialized allocation for ADT constructors.

    - tag: constructor discriminant (maps to Custom.ctor field)
    - size: number of pointer-sized fields
    - scalar_bytes: additional bytes for unboxed scalar fields

    Example:
    ```mlir
    %obj = eco.allocate_ctor {
      tag = 1 : i32,
      size = 2 : i32,
      scalar_bytes = 0 : i32
    } : !eco.value
    ```
  }];

  let arguments = (ins
    I64Attr:$tag,
    I64Attr:$size,
    I64Attr:$scalar_bytes
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "attr-dict `:` type($result)";
}

def Eco_AllocateStringOp : Eco_Op<"allocate_string"> {
  let summary = "Allocate string storage";
  let description = [{
    Allocate storage for a string of the specified length (in UTF-16 code
    units). The string content must be written separately after allocation.

    Example:
    ```mlir
    %str = eco.allocate_string {length = 100 : i32} : !eco.value
    ```
  }];

  let arguments = (ins I64Attr:$length);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "attr-dict `:` type($result)";
}

def Eco_AllocateClosureOp : Eco_Op<"allocate_closure"> {
  let summary = "Allocate closure object";
  let description = [{
    Allocate a closure object for the specified function with space for
    values. The `arity` specifies the total number of value slots (max_values),
    which should equal num_captured + num_remaining_args.

    Example:
    ```mlir
    %closure = eco.allocate_closure {
      function = @my_func,
      arity = 3 : i64
    } : !eco.value
    ```
  }];

  let arguments = (ins
    FlatSymbolRefAttr:$function,
    I64Attr:$arity
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "attr-dict `:` type($result)";
}

def Eco_SafepointOp : Eco_Op<"safepoint"> {
  let summary = "GC safepoint";
  let description = [{
    GC safepoint operation. Marks a point where garbage collection can
    safely occur. The stack_map describes live eco.value roots at this
    point in a serialized format.

    During lowering to LLVM, this becomes an llvm.experimental.gc.statepoint
    with gc.relocate operations for each live pointer.

    Example:
    ```mlir
    eco.safepoint {stack_map = "v0,v1,v2"}
    ```
  }];

  let arguments = (ins StrAttr:$stack_map);
  let results = (outs);
}

//===----------------------------------------------------------------------===//
// 6. Global State Operations
//===----------------------------------------------------------------------===//

def Eco_GlobalOp : Eco_Op<"global", [Symbol]> {
  let summary = "Declare global variable";
  let description = [{
    Declare a global variable managed by the runtime/GC. Global variables
    are registered as GC roots and can hold eco.value pointers.

    Example:
    ```mlir
    eco.global @my_global : !eco.value
    eco.global @initialized_global = @init_func : !eco.value
    ```
  }];

  let arguments = (ins
    SymbolNameAttr:$sym_name,
    OptionalAttr<FlatSymbolRefAttr>:$initializer
  );
  let results = (outs);

  let assemblyFormat = "$sym_name (`=` $initializer^)? attr-dict";
}

def Eco_LoadGlobalOp : Eco_Op<"load_global"> {
  let summary = "Load from global variable";
  let description = [{
    Load the current value from a global variable.

    Example:
    ```mlir
    %value = eco.load_global @my_global : !eco.value
    ```
  }];

  let arguments = (ins FlatSymbolRefAttr:$global);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$global attr-dict";
}

def Eco_StoreGlobalOp : Eco_Op<"store_global"> {
  let summary = "Store to global variable";
  let description = [{
    Store a value to a global variable.

    Example:
    ```mlir
    eco.store_global %value, @my_global : !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Value:$value,
    FlatSymbolRefAttr:$global
  );
  let results = (outs);

  let assemblyFormat = "$value `,` $global attr-dict";
}

//===----------------------------------------------------------------------===//
// 7. Type Conversion Operations
//===----------------------------------------------------------------------===//

def Eco_BoxOp : Eco_Op<"box", [Pure]> {
  let summary = "Box primitive value to eco.value";
  let description = [{
    Box an unboxed primitive value (i64, f64, i32, i1) into a heap-allocated
    eco.value. This allocates an ElmInt, ElmFloat, ElmChar, or Bool object.

    Example:
    ```mlir
    %boxed = eco.box %int_val : i64 -> !eco.value
    %boxed_float = eco.box %float_val : f64 -> !eco.value
    ```
  }];

  let arguments = (ins Eco_AnyValue:$value);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_UnboxOp : Eco_Op<"unbox", [Pure]> {
  let summary = "Unbox eco.value to primitive";
  let description = [{
    Unbox an eco.value to extract its primitive value. The eco.value must
    be of the appropriate type (ElmInt, ElmFloat, ElmChar, or Bool).

    Example:
    ```mlir
    %int_val = eco.unbox %boxed : !eco.value -> i64
    %float_val = eco.unbox %boxed_float : !eco.value -> f64
    ```
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs Eco_AnyValue:$result);

  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

//===----------------------------------------------------------------------===//
// 8. Constant Values (Embedded in Tagged Pointer)
//===----------------------------------------------------------------------===//

def Eco_ConstantOp : Eco_Op<"constant", [Pure]> {
  let summary = "Create embedded constant value";
  let description = [{
    Creates an embedded constant value that is stored directly in the pointer
    representation without heap allocation. These correspond to the Constant
    enum in Heap.hpp: Unit, EmptyRec, True, False, Nil, Nothing, EmptyString.

    The constant is encoded in bits 40-43 of the i64 representation, with
    the pointer field (bits 0-39) set to 0.

    Example:
    ```mlir
    %nil = eco.constant Nil : !eco.value
    %true = eco.constant True : !eco.value
    %unit = eco.constant Unit : !eco.value
    ```

    Lowering produces an i64 with the constant field set appropriately:
    - Nil → 5 << 40 = 5497558138880
    - True → 3 << 40 = 3298534883328
    - Unit → 1 << 40 = 1099511627776
  }];

  let arguments = (ins Eco_ConstantKind:$kind);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$kind attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 9. Arithmetic Operations
//===----------------------------------------------------------------------===//
//
// Eco-specific arithmetic operations with Elm semantics.
// All ops work on unboxed primitives (i64, f64) for efficiency.
// Key Elm semantics:
//   - Division by zero returns 0 (not exception)
//   - Integer to negative power returns 0
//   - modBy uses floored (Euclidean) modulo
//   - Integer overflow wraps (wrong answer preferred over exception)
//

//===----------------------------------------------------------------------===//
// 9.1 Integer Arithmetic
//===----------------------------------------------------------------------===//

def Eco_IntAddOp : Eco_Op<"int.add", [Pure, Commutative]> {
  let summary = "Elm integer addition";
  let description = [{
    Add two 64-bit signed integers. Overflow wraps.

    Example:
    ```mlir
    %sum = eco.int.add %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntSubOp : Eco_Op<"int.sub", [Pure]> {
  let summary = "Elm integer subtraction";
  let description = [{
    Subtract two 64-bit signed integers. Overflow wraps.

    Example:
    ```mlir
    %diff = eco.int.sub %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntMulOp : Eco_Op<"int.mul", [Pure, Commutative]> {
  let summary = "Elm integer multiplication";
  let description = [{
    Multiply two 64-bit signed integers. Overflow wraps.

    Example:
    ```mlir
    %prod = eco.int.mul %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntDivOp : Eco_Op<"int.div", [Pure]> {
  let summary = "Elm integer division (returns 0 on divide-by-zero)";
  let description = [{
    Integer division with Elm semantics: division by zero returns 0
    instead of throwing an exception. Truncates toward zero.

    Examples:
      7 // 3 = 2
      7 // 0 = 0 (Elm semantics)
      -7 // 3 = -2 (truncated toward zero)

    ```mlir
    %quot = eco.int.div %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntModByOp : Eco_Op<"int.modby", [Pure]> {
  let summary = "Elm modBy (floored/Euclidean modulo)";
  let description = [{
    Floored modulo operation. Result has same sign as modulus.
    Returns 0 if modulus is 0.

    Examples:
      modBy 4 7 = 3
      modBy 4 (-7) = 1  (not -3, floored)
      modBy (-4) 7 = -1 (not 3, floored)
      modBy 0 7 = 0     (Elm semantics)

    ```mlir
    %rem = eco.int.modby %modulus, %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$modulus, Eco_Int:$x);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$modulus `,` $x attr-dict `:` type($result)";
}

def Eco_IntRemainderByOp : Eco_Op<"int.remainderby", [Pure]> {
  let summary = "Elm remainderBy (truncated modulo)";
  let description = [{
    Truncated modulo operation. Result has same sign as dividend.
    Returns 0 if divisor is 0.

    Examples:
      remainderBy 4 7 = 3
      remainderBy 4 (-7) = -3 (not 1, truncated)
      remainderBy 0 7 = 0     (Elm semantics)

    ```mlir
    %rem = eco.int.remainderby %divisor, %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$divisor, Eco_Int:$x);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$divisor `,` $x attr-dict `:` type($result)";
}

def Eco_IntNegateOp : Eco_Op<"int.negate", [Pure]> {
  let summary = "Elm integer negation";
  let description = [{
    Negate an integer. Overflow wraps (MIN_INT negates to MIN_INT).

    ```mlir
    %neg = eco.int.negate %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_IntAbsOp : Eco_Op<"int.abs", [Pure]> {
  let summary = "Elm integer absolute value";
  let description = [{
    Absolute value of an integer. Note: abs(MIN_INT) = MIN_INT (overflow wraps).

    ```mlir
    %abs = eco.int.abs %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_IntPowOp : Eco_Op<"int.pow", [Pure]> {
  let summary = "Elm integer exponentiation";
  let description = [{
    Integer exponentiation. Returns 0 if exponent is negative
    (since true result would be fractional, breaking Int type).
    Overflow wraps.

    Examples:
      2 ^ 3 = 8
      2 ^ 0 = 1
      2 ^ -1 = 0 (mathematically 0.5, returns 0 to preserve Int)

    ```mlir
    %pow = eco.int.pow %base, %exp : i64
    ```
  }];
  let arguments = (ins Eco_Int:$base, Eco_Int:$exp);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$base `,` $exp attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 9.2 Float Arithmetic
//===----------------------------------------------------------------------===//

def Eco_FloatAddOp : Eco_Op<"float.add", [Pure, Commutative]> {
  let summary = "Elm float addition";
  let description = [{
    Add two IEEE 754 double-precision floats.

    ```mlir
    %sum = eco.float.add %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_FloatSubOp : Eco_Op<"float.sub", [Pure]> {
  let summary = "Elm float subtraction";
  let description = [{
    Subtract two IEEE 754 double-precision floats.

    ```mlir
    %diff = eco.float.sub %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_FloatMulOp : Eco_Op<"float.mul", [Pure, Commutative]> {
  let summary = "Elm float multiplication";
  let description = [{
    Multiply two IEEE 754 double-precision floats.

    ```mlir
    %prod = eco.float.mul %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_FloatDivOp : Eco_Op<"float.div", [Pure]> {
  let summary = "Elm float division (IEEE 754)";
  let description = [{
    Float division with IEEE 754 semantics.
    Division by zero returns Infinity or -Infinity.
    0/0 returns NaN.

    ```mlir
    %quot = eco.float.div %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_FloatNegateOp : Eco_Op<"float.negate", [Pure]> {
  let summary = "Elm float negation";
  let description = [{
    Negate a float (flip sign bit).

    ```mlir
    %neg = eco.float.negate %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatAbsOp : Eco_Op<"float.abs", [Pure]> {
  let summary = "Elm float absolute value";
  let description = [{
    Absolute value of a float (clear sign bit).

    ```mlir
    %abs = eco.float.abs %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatPowOp : Eco_Op<"float.pow", [Pure]> {
  let summary = "Elm float exponentiation";
  let description = [{
    Float exponentiation. Follows IEEE 754 semantics.
    (-2.0) ^ 0.5 returns NaN.

    ```mlir
    %pow = eco.float.pow %base, %exp : f64
    ```
  }];
  let arguments = (ins Eco_Float:$base, Eco_Float:$exp);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$base `,` $exp attr-dict `:` type($result)";
}

def Eco_FloatSqrtOp : Eco_Op<"float.sqrt", [Pure]> {
  let summary = "Elm square root";
  let description = [{
    Square root of a float. Returns NaN for negative inputs.

    ```mlir
    %sqrt = eco.float.sqrt %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 9.2b Trigonometric Functions
//===----------------------------------------------------------------------===//

def Eco_FloatSinOp : Eco_Op<"float.sin", [Pure]> {
  let summary = "Sine function";
  let description = [{
    Compute sine of angle in radians.

    ```mlir
    %result = eco.float.sin %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatCosOp : Eco_Op<"float.cos", [Pure]> {
  let summary = "Cosine function";
  let description = [{
    Compute cosine of angle in radians.

    ```mlir
    %result = eco.float.cos %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatTanOp : Eco_Op<"float.tan", [Pure]> {
  let summary = "Tangent function";
  let description = [{
    Compute tangent of angle in radians.

    ```mlir
    %result = eco.float.tan %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatAsinOp : Eco_Op<"float.asin", [Pure]> {
  let summary = "Arc sine function";
  let description = [{
    Compute arc sine (inverse sine). Returns value in radians.
    Input must be in range [-1, 1], otherwise returns NaN.

    ```mlir
    %result = eco.float.asin %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatAcosOp : Eco_Op<"float.acos", [Pure]> {
  let summary = "Arc cosine function";
  let description = [{
    Compute arc cosine (inverse cosine). Returns value in radians.
    Input must be in range [-1, 1], otherwise returns NaN.

    ```mlir
    %result = eco.float.acos %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatAtanOp : Eco_Op<"float.atan", [Pure]> {
  let summary = "Arc tangent function";
  let description = [{
    Compute arc tangent (inverse tangent). Returns value in radians
    in range [-pi/2, pi/2].

    ```mlir
    %result = eco.float.atan %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_FloatAtan2Op : Eco_Op<"float.atan2", [Pure]> {
  let summary = "Two-argument arc tangent";
  let description = [{
    Compute arc tangent of y/x, using signs to determine quadrant.
    Returns value in radians in range [-pi, pi].

    ```mlir
    %result = eco.float.atan2 %y, %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$y, Eco_Float:$x);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$y `,` $x attr-dict `:` type($result)";
}

def Eco_FloatLogOp : Eco_Op<"float.log", [Pure]> {
  let summary = "Natural logarithm";
  let description = [{
    Compute natural logarithm (base e).
    Returns -Infinity for 0, NaN for negative inputs.

    ```mlir
    %result = eco.float.log %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 9.2c Float Classification
//===----------------------------------------------------------------------===//

def Eco_FloatIsNaNOp : Eco_Op<"float.isNaN", [Pure]> {
  let summary = "Check if float is NaN";
  let description = [{
    Returns true if the value is NaN (Not a Number).

    ```mlir
    %result = eco.float.isNaN %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$value attr-dict `:` type($value)";
}

def Eco_FloatIsInfiniteOp : Eco_Op<"float.isInfinite", [Pure]> {
  let summary = "Check if float is infinite";
  let description = [{
    Returns true if the value is positive or negative infinity.

    ```mlir
    %result = eco.float.isInfinite %x : f64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$value attr-dict `:` type($value)";
}

//===----------------------------------------------------------------------===//
// 9.3 Type Conversions
//===----------------------------------------------------------------------===//

def Eco_IntToFloatOp : Eco_Op<"int.toFloat", [Pure]> {
  let summary = "Convert Int to Float";
  let description = [{
    Convert a 64-bit integer to IEEE 754 double.
    May lose precision for large integers.

    ```mlir
    %f = eco.int.toFloat %i : i64 -> f64
    ```
  }];
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_FloatRoundOp : Eco_Op<"float.round", [Pure]> {
  let summary = "Round Float to nearest Int";
  let description = [{
    Round float to nearest integer (half away from zero).

    ```mlir
    %i = eco.float.round %f : f64 -> i64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_FloatFloorOp : Eco_Op<"float.floor", [Pure]> {
  let summary = "Round Float down to Int";
  let description = [{
    Round float down (toward negative infinity) to integer.

    ```mlir
    %i = eco.float.floor %f : f64 -> i64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_FloatCeilingOp : Eco_Op<"float.ceiling", [Pure]> {
  let summary = "Round Float up to Int";
  let description = [{
    Round float up (toward positive infinity) to integer.

    ```mlir
    %i = eco.float.ceiling %f : f64 -> i64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_FloatTruncateOp : Eco_Op<"float.truncate", [Pure]> {
  let summary = "Truncate Float toward zero to Int";
  let description = [{
    Truncate float toward zero to integer.

    ```mlir
    %i = eco.float.truncate %f : f64 -> i64
    ```
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

//===----------------------------------------------------------------------===//
// 9.4 Comparison Operations
//===----------------------------------------------------------------------===//

// Integer comparisons - all return i1 (Bool)

def Eco_IntLtOp : Eco_Op<"int.lt", [Pure]> {
  let summary = "Integer less-than comparison";
  let description = [{
    Compare two integers for less-than. Returns i1 (Bool).

    ```mlir
    %result = eco.int.lt %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_IntLeOp : Eco_Op<"int.le", [Pure]> {
  let summary = "Integer less-than-or-equal comparison";
  let description = [{
    Compare two integers for less-than-or-equal. Returns i1 (Bool).

    ```mlir
    %result = eco.int.le %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_IntGtOp : Eco_Op<"int.gt", [Pure]> {
  let summary = "Integer greater-than comparison";
  let description = [{
    Compare two integers for greater-than. Returns i1 (Bool).

    ```mlir
    %result = eco.int.gt %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_IntGeOp : Eco_Op<"int.ge", [Pure]> {
  let summary = "Integer greater-than-or-equal comparison";
  let description = [{
    Compare two integers for greater-than-or-equal. Returns i1 (Bool).

    ```mlir
    %result = eco.int.ge %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_IntEqOp : Eco_Op<"int.eq", [Pure, Commutative]> {
  let summary = "Integer equality comparison";
  let description = [{
    Compare two integers for equality. Returns i1 (Bool).

    ```mlir
    %result = eco.int.eq %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_IntNeOp : Eco_Op<"int.ne", [Pure, Commutative]> {
  let summary = "Integer not-equal comparison";
  let description = [{
    Compare two integers for inequality. Returns i1 (Bool).

    ```mlir
    %result = eco.int.ne %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

// Float comparisons - all return i1 (Bool)
// Use ordered comparisons: return false if either operand is NaN

def Eco_FloatLtOp : Eco_Op<"float.lt", [Pure]> {
  let summary = "Float less-than comparison";
  let description = [{
    Compare two floats for less-than. Returns i1 (Bool).
    Returns false if either operand is NaN (ordered comparison).

    ```mlir
    %result = eco.float.lt %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_FloatLeOp : Eco_Op<"float.le", [Pure]> {
  let summary = "Float less-than-or-equal comparison";
  let description = [{
    Compare two floats for less-than-or-equal. Returns i1 (Bool).
    Returns false if either operand is NaN (ordered comparison).

    ```mlir
    %result = eco.float.le %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_FloatGtOp : Eco_Op<"float.gt", [Pure]> {
  let summary = "Float greater-than comparison";
  let description = [{
    Compare two floats for greater-than. Returns i1 (Bool).
    Returns false if either operand is NaN (ordered comparison).

    ```mlir
    %result = eco.float.gt %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_FloatGeOp : Eco_Op<"float.ge", [Pure]> {
  let summary = "Float greater-than-or-equal comparison";
  let description = [{
    Compare two floats for greater-than-or-equal. Returns i1 (Bool).
    Returns false if either operand is NaN (ordered comparison).

    ```mlir
    %result = eco.float.ge %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_FloatEqOp : Eco_Op<"float.eq", [Pure, Commutative]> {
  let summary = "Float equality comparison";
  let description = [{
    Compare two floats for equality. Returns i1 (Bool).
    Returns false if either operand is NaN (ordered comparison).
    Note: NaN != NaN per IEEE 754.

    ```mlir
    %result = eco.float.eq %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_FloatNeOp : Eco_Op<"float.ne", [Pure, Commutative]> {
  let summary = "Float not-equal comparison";
  let description = [{
    Compare two floats for inequality. Returns i1 (Bool).
    Returns true if either operand is NaN (ordered comparison).
    Note: NaN != NaN per IEEE 754.

    ```mlir
    %result = eco.float.ne %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_IntMinOp : Eco_Op<"int.min", [Pure, Commutative]> {
  let summary = "Elm integer minimum";
  let description = [{
    Return the smaller of two integers.

    ```mlir
    %min = eco.int.min %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntMaxOp : Eco_Op<"int.max", [Pure, Commutative]> {
  let summary = "Elm integer maximum";
  let description = [{
    Return the larger of two integers.

    ```mlir
    %max = eco.int.max %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_FloatMinOp : Eco_Op<"float.min", [Pure, Commutative]> {
  let summary = "Elm float minimum";
  let description = [{
    Return the smaller of two floats.
    If either is NaN, returns NaN.

    ```mlir
    %min = eco.float.min %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_FloatMaxOp : Eco_Op<"float.max", [Pure, Commutative]> {
  let summary = "Elm float maximum";
  let description = [{
    Return the larger of two floats.
    If either is NaN, returns NaN.

    ```mlir
    %max = eco.float.max %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Float:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 9.5 Bitwise Operations
//===----------------------------------------------------------------------===//

def Eco_IntAndOp : Eco_Op<"int.and", [Pure, Commutative]> {
  let summary = "Bitwise AND";
  let description = [{
    Bitwise AND of two integers.

    ```mlir
    %and = eco.int.and %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntOrOp : Eco_Op<"int.or", [Pure, Commutative]> {
  let summary = "Bitwise OR";
  let description = [{
    Bitwise OR of two integers.

    ```mlir
    %or = eco.int.or %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntXorOp : Eco_Op<"int.xor", [Pure, Commutative]> {
  let summary = "Bitwise XOR";
  let description = [{
    Bitwise XOR of two integers.

    ```mlir
    %xor = eco.int.xor %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_IntComplementOp : Eco_Op<"int.complement", [Pure]> {
  let summary = "Bitwise NOT (complement)";
  let description = [{
    Bitwise complement (NOT) of an integer.

    ```mlir
    %not = eco.int.complement %x : i64
    ```
  }];
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_IntShiftLeftOp : Eco_Op<"int.shl", [Pure]> {
  let summary = "Shift left by n bits";
  let description = [{
    Shift left by n bits. Matches Elm's Bitwise.shiftLeftBy.
    Note: Elm argument order is (amount, value).

    ```mlir
    %shl = eco.int.shl %amount, %value : i64
    ```
  }];
  let arguments = (ins Eco_Int:$amount, Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$amount `,` $value attr-dict `:` type($result)";
}

def Eco_IntShiftRightOp : Eco_Op<"int.shr", [Pure]> {
  let summary = "Arithmetic shift right by n bits";
  let description = [{
    Arithmetic shift right by n bits (preserves sign).
    Matches Elm's Bitwise.shiftRightBy.

    ```mlir
    %shr = eco.int.shr %amount, %value : i64
    ```
  }];
  let arguments = (ins Eco_Int:$amount, Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$amount `,` $value attr-dict `:` type($result)";
}

def Eco_IntShiftRightZfOp : Eco_Op<"int.shru", [Pure]> {
  let summary = "Logical shift right by n bits (zero-fill)";
  let description = [{
    Logical shift right by n bits (fills with zeros).
    Matches Elm's Bitwise.shiftRightZfBy.

    ```mlir
    %shru = eco.int.shru %amount, %value : i64
    ```
  }];
  let arguments = (ins Eco_Int:$amount, Eco_Int:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$amount `,` $value attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 10. Boolean Operations
//===----------------------------------------------------------------------===//

def Eco_BoolNotOp : Eco_Op<"bool.not", [Pure]> {
  let summary = "Boolean NOT (logical negation)";
  let description = [{
    Logical negation of a boolean value.

    ```mlir
    %result = eco.bool.not %x : i1
    ```
  }];
  let arguments = (ins Eco_Bool:$value);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_BoolAndOp : Eco_Op<"bool.and", [Pure, Commutative]> {
  let summary = "Boolean AND";
  let description = [{
    Logical AND of two boolean values.

    ```mlir
    %result = eco.bool.and %a, %b : i1
    ```
  }];
  let arguments = (ins Eco_Bool:$lhs, Eco_Bool:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_BoolOrOp : Eco_Op<"bool.or", [Pure, Commutative]> {
  let summary = "Boolean OR";
  let description = [{
    Logical OR of two boolean values.

    ```mlir
    %result = eco.bool.or %a, %b : i1
    ```
  }];
  let arguments = (ins Eco_Bool:$lhs, Eco_Bool:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

def Eco_BoolXorOp : Eco_Op<"bool.xor", [Pure, Commutative]> {
  let summary = "Boolean XOR";
  let description = [{
    Logical XOR of two boolean values.

    ```mlir
    %result = eco.bool.xor %a, %b : i1
    ```
  }];
  let arguments = (ins Eco_Bool:$lhs, Eco_Bool:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 11. Character Operations
//===----------------------------------------------------------------------===//

def Eco_CharToIntOp : Eco_Op<"char.toInt", [Pure]> {
  let summary = "Convert Char to Int (Char.toCode)";
  let description = [{
    Get the Unicode code point of a character as an integer.

    ```mlir
    %code = eco.char.toInt %c : i16 -> i64
    ```
  }];
  let arguments = (ins Eco_Char:$value);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_CharFromIntOp : Eco_Op<"char.fromInt", [Pure]> {
  let summary = "Convert Int to Char (Char.fromCode)";
  let description = [{
    Create a character from a Unicode code point. Values outside valid
    range (0-0xFFFF) are clamped.

    ```mlir
    %c = eco.char.fromInt %code : i64 -> i16
    ```
  }];
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Char:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

//===----------------------------------------------------------------------===//
// 12. Reference Counting Placeholders (Future Perceus Support)
//===----------------------------------------------------------------------===//
//
// Note: The current GC design uses tracing GC, not reference counting.
// These operations are kept as placeholders for potential future
// Perceus-style memory management experimentation. They should be
// eliminated before codegen in the current implementation.
//

def Eco_IncrefOp : Eco_Op<"incref"> {
  let summary = "Increment reference count (placeholder)";
  let description = [{
    Increment the reference count of a heap object.

    Note: Placeholder for potential Perceus-style memory management.
    Should be eliminated before LLVM lowering in tracing GC mode.
  }];

  let arguments = (ins
    Eco_Value:$value,
    I64Attr:$amount
  );
  let results = (outs);
}

def Eco_DecrefOp : Eco_Op<"decref"> {
  let summary = "Decrement reference count (placeholder)";
  let description = [{
    Decrement reference count; if it reaches zero, recursively free children.

    Note: Placeholder for potential Perceus-style memory management.
    Should be eliminated before LLVM lowering in tracing GC mode.
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs);
}

def Eco_DecrefShallowOp : Eco_Op<"decref_shallow"> {
  let summary = "Decrement reference count non-recursively (placeholder)";
  let description = [{
    Decrement reference count without recursively freeing children (shallow).

    Note: Placeholder for potential Perceus-style memory management.
    Should be eliminated before LLVM lowering in tracing GC mode.
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs);
}

def Eco_FreeOp : Eco_Op<"free"> {
  let summary = "Free unique object (placeholder)";
  let description = [{
    Free an object known to have reference count 1 (unique/owned).

    Note: Placeholder for potential Perceus-style memory management.
    Should be eliminated before LLVM lowering in tracing GC mode.
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs);
}

def Eco_ResetOp : Eco_Op<"reset"> {
  let summary = "Reset object for reuse (placeholder)";
  let description = [{
    Reset an object for in-place reuse if unique; otherwise perform
    appropriate decrefs/frees.

    Note: Placeholder for potential Perceus-style memory management.
    Should be eliminated before LLVM lowering in tracing GC mode.
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs Eco_AnyValue:$result);
}

def Eco_ResetRefOp : Eco_Op<"reset_ref"> {
  let summary = "Reset reference with update mode (placeholder)";
  let description = [{
    Variant of reset that updates a reference (pointer slot) in-place
    depending on update mode.

    Note: Placeholder for potential Perceus-style memory management.
    Should be eliminated before LLVM lowering in tracing GC mode.
  }];

  let arguments = (ins Eco_Value:$ref);
  let results = (outs Eco_AnyValue:$result);
}
