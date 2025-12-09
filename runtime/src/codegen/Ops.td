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
}

//===----------------------------------------------------------------------===//
// Type Constraints
//===----------------------------------------------------------------------===//

// Boxed heap value
def Eco_Value : Type<CPred<"llvm::isa<eco::ValueType>($_self)">,
                     "eco.value",
                     "eco::ValueType">;

// Unboxed primitive types matching Elm semantics
def Eco_Int   : I<64>;   // Elm Int (64-bit signed)
def Eco_Float : F<64>;   // Elm Float (IEEE 754 double)
def Eco_Char  : I<32>;   // Elm Char (Unicode code point)
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
    RecursiveMemoryEffects,
    SingleBlockImplicitTerminator<"ReturnOp">
]> {
  let summary = "Pattern match on ADT constructor tag";
  let description = [{
    Pattern match on an ADT's constructor tag and branch to one of several
    regions. Each region handles a specific constructor tag.

    Example:
    ```mlir
    eco.case %scrutinee [0, 1] {
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
    Eco_Value:$scrutinee,
    DenseI64ArrayAttr:$tags
  );
  let regions = (region VariadicRegion<AnyRegion>:$alternatives);
  let results = (outs);

  let hasVerifier = 1;
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

    Example:
    ```mlir
    eco.joinpoint @loop(%acc: i64, %n: i64) {
      // Loop body - can jump back to @loop or fall through
      %done = arith.cmpi eq, %n, %c0 : i64
      cf.cond_br %done, ^exit, ^recurse
    ^exit:
      eco.return %acc : i64
    ^recurse:
      %new_acc = arith.addi %acc, %n : i64
      %new_n = arith.subi %n, %c1 : i64
      eco.jump @loop(%new_acc, %new_n : i64, i64)
    } continuation {
      // Code after joinpoint definition
    }
    ```
  }];

  let arguments = (ins I64Attr:$id);
  let regions = (region
    SizedRegion<1>:$body,
    AnyRegion:$continuation
  );
  let results = (outs);

  let hasVerifier = 1;
}

def Eco_JumpOp : Eco_Op<"jump", [Terminator]> {
  let summary = "Jump to joinpoint";
  let description = [{
    Jump to a previously-defined eco.joinpoint, passing arguments that match
    the joinpoint's parameters. This is like a tail call to a local function.

    Example:
    ```mlir
    eco.jump @loop(%new_acc, %new_n : i64, i64)
    ```
  }];

  let arguments = (ins
    I64Attr:$target,
    Variadic<Eco_AnyValue>:$args
  );
  let results = (outs);
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
}

def Eco_ExpectOp : Eco_Op<"expect"> {
  let summary = "Debug assertion (Elm's Debug.todo/crash path)";
  let description = [{
    Runtime assertion that checks a condition and crashes with a message
    if false. The passthrough value flows through unchanged when the
    condition is true.

    Example:
    ```mlir
    %result = eco.expect %cond, %msg, %value
      : i1, !eco.value, !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Bool:$condition,
    Eco_Value:$message,
    Eco_AnyValue:$passthrough
  );
  let results = (outs Eco_AnyValue:$result);
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
}

//===----------------------------------------------------------------------===//
// 2. ADT Construction and Projection
//===----------------------------------------------------------------------===//

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

    For closure calls, omit the callee and pass the closure as first operand:
    ```mlir
    %result = eco.call(%closure, %arg) {musttail = false}
      : (!eco.value, !eco.value) -> !eco.value
    ```

    Set musttail = true for tail calls that must be compiled as proper
    tail calls (for tail recursion). The call must be in tail position.
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$operands,
    OptionalAttr<FlatSymbolRefAttr>:$callee,
    OptionalAttr<BoolAttr>:$musttail
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

    Example:
    ```mlir
    // Apply one more argument to a partially applied function
    %result = eco.papExtend %closure(%arg1, %arg2)
      : !eco.value, (!eco.value, i64) -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Value:$closure,
    Variadic<Eco_AnyValue>:$newargs
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
}

def Eco_AllocateClosureOp : Eco_Op<"allocate_closure"> {
  let summary = "Allocate closure object";
  let description = [{
    Allocate a closure object for the specified function with space for
    captured values. The closure's evaluator function pointer and capture
    slots must be initialized separately.

    Example:
    ```mlir
    %closure = eco.allocate_closure {
      function = @my_func,
      num_captures = 3 : i32
    } : !eco.value
    ```
  }];

  let arguments = (ins
    FlatSymbolRefAttr:$function,
    I64Attr:$num_captures
  );
  let results = (outs Eco_Value:$result);
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
}

//===----------------------------------------------------------------------===//
// 8. Reference Counting Placeholders (Future Perceus Support)
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
