//===- EcoOps.td - Eco dialect operations -----------------------*- tablegen -*-===//
//
// MLIR ODS definitions for the Eco dialect operations.
//
//===----------------------------------------------------------------------===//

include "mlir/IR/OpBase.td"

// Dialect
def Eco_Dialect : Dialect {
  let name = "eco";
  let cppNamespace = "eco";
}

// Base op class
class Eco_Op<string mnemonic, list<Trait> traits = []>
    : Op<Eco_Dialect, mnemonic, traits> {}

//------------------------------------------------------------------------------
// 1. Control flow / structure
//------------------------------------------------------------------------------

def Eco_CaseOp : Eco_Op<"case"> {
  let summary = "Pattern match on ADT constructor tag";
  let description = [{
    Pattern match on an ADT's constructor tag and branch to one of several
    regions. Each region handles a specific constructor tag.

    Example:
    ```mlir
    "eco.case"(%scrutinee)(
      { /* tag 0 alternative */ },
      { /* tag 1 alternative */ }
    ) {tags = [0, 1]} : (!eco.value) -> ()
    ```

    Regions take no arguments; code inside uses eco.project to extract fields
    from the scrutinee. Each region must terminate with eco.return or eco.jump.
  }];

  let arguments = (ins AnyType:$scrutinee,
                       I64ArrayAttr:$tags);
  // One region per tag, plus optional default region
  let regions = (region VariadicRegion<AnyRegion>:$alternatives);
  let results = (outs);
}

def Eco_ReturnOp : Eco_Op<"return", [Terminator]> {
  let summary = "Return from Eco function";
  let description = [{
    Return from an Eco function with optional result values.
  }];

  let arguments = (ins Variadic<AnyType>:$results);
  let results = (outs);
}

def Eco_JoinpointOp : Eco_Op<"joinpoint"> {
  let summary = "Joinpoint definition for local loops/tail recursion";
  let description = [{
    Defines a joinpoint (local label/loop head) with parameters and a body
    region, plus a continuation region for code after the joinpoint.
    Used for efficient local loops and tail recursion.

    The joinpoint body region's block arguments serve as the joinpoint parameters.
  }];

  let arguments = (ins I64Attr:$id);
  // Region 0: joinpoint body (block arguments = parameters)
  // Region 1: continuation after joinpoint definition
  let regions = (region AnyRegion:$jpRegion,
                 AnyRegion:$continuation);
  let results = (outs);
}

def Eco_JumpOp : Eco_Op<"jump", [Terminator]> {
  let summary = "Jump to joinpoint";
  let description = [{
    Jump to a previously-defined eco.joinpoint, passing arguments that match
    the joinpoint's parameters. This is like a tail call to a local function.
  }];

  let arguments = (ins I64Attr:$join_point,
                       Variadic<AnyType>:$args);
  let results = (outs);
}

def Eco_CrashOp : Eco_Op<"crash", [Terminator]> {
  let summary = "Crash / panic";
  let description = [{
    Unconditional crash (panic). Typically lowers to a call into the Eco
    runtime plus an unreachable/return.
  }];

  let arguments = (ins AnyType:$message);
  let results = (outs);
}

def Eco_ExpectOp : Eco_Op<"expect"> {
  let summary = "Debug assertion (expect)";
  let description = [{
    Represents Eco's Expect statement (runtime assertion).
  }];

  let arguments = (ins AnyType:$cond,
                       AnyType:$message);
  let results = (outs AnyType:$value);
}

def Eco_DbgOp : Eco_Op<"dbg"> {
  let summary = "Debug/logging operation";
  let description = [{
    Debug/log op; can be lowered to calls or metadata as needed.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results = (outs);
}

//------------------------------------------------------------------------------
// 2. ADT construction and projection
//------------------------------------------------------------------------------

def Eco_ConstructOp : Eco_Op<"construct"> {
  let summary = "Construct ADT/record/tuple value";
  let description = [{
    Create an algebraic data type (ADT) value for a specific constructor.
    High-level, pure op representing both allocation and field initialization.

    Example:
    ```mlir
    %obj = "eco.construct"(%field1, %field2) {
      constructor = @"Module.Type.Ctor",
      tag = 1,
      size = 2
    } : (!eco.value, !eco.value) -> (!eco.value)
    ```

    For zero-field constructors (e.g. []):
    ```mlir
    %nil = "eco.construct"() {
      constructor = @"List.[]",
      tag = 0,
      size = 0
    } : () -> (!eco.value)
    ```
  }];

  let arguments = (ins Variadic<AnyType>:$fields,
                       FlatSymbolRefAttr:$constructor,
                       I64Attr:$tag,
                       I64Attr:$size);
  let results = (outs AnyType:$result);
}

def Eco_ProjectOp : Eco_Op<"project"> {
  let summary = "Project field from ADT value";
  let description = [{
    Project a field out of a constructor (ADT) value by index.
    No runtime tag checking; using on wrong constructor is undefined behavior.

    Example:
    ```mlir
    %field = "eco.project"(%obj) {index = 0}
      : (!eco.value) -> (!eco.value)
    ```
  }];

  let arguments = (ins AnyType:$value,
                       I64Attr:$index);
  let results = (outs AnyType:$field);
}

//------------------------------------------------------------------------------
// 3. String literals
//------------------------------------------------------------------------------

def Eco_StringLiteralOp : Eco_Op<"string_literal"> {
  let summary = "Eco string literal";
  let description = [{
    Creates an Eco string value from a literal.
  }];

  let arguments = (ins StrAttr:$value);
  let results = (outs AnyType:$result);
}

//------------------------------------------------------------------------------
// 4. Calls and closures
//------------------------------------------------------------------------------

def Eco_CallOp : Eco_Op<"call"> {
  let summary = "Call function or closure";
  let description = [{
    Function/closure application. Used for both direct calls and closure calls.

    For direct calls, specify the function attribute:
    ```mlir
    %result = "eco.call"(%arg1, %arg2) {
      function = @func_name,
      musttail = false
    } : (!eco.value, !eco.value) -> (!eco.value)
    ```

    For closure calls, omit the function attribute:
    ```mlir
    %result = "eco.call"(%closure, %arg) {musttail = false}
      : (!eco.value, !eco.value) -> (!eco.value)
    ```

    Set musttail = true for tail calls that must be compiled as proper tail
    calls (for tail recursion). The call must be in tail position.
  }];

  let arguments = (ins Variadic<AnyType>:$args,
                       OptionalAttr<FlatSymbolRefAttr>:$function,
                       BoolAttr:$musttail);
  let results = (outs Variadic<AnyType>:$results);
}

def Eco_PapCreateOp : Eco_Op<"papCreate"> {
  let summary = "Create partial application closure";
  let description = [{
    Create a closure representing a partial application (PAP) of a function
    with some captured arguments.

    Example:
    ```mlir
    %closure = "eco.papCreate"(%captured1, %captured2) {
      function = @func_name,
      arity = 4,
      num_captured = 2
    } : (!eco.value, !eco.value) -> (!eco.value)
    ```

    The number of operands must equal num_captured. The remaining arity
    after creation is (arity - num_captured).
  }];

  let arguments = (ins Variadic<AnyType>:$captured,
                       FlatSymbolRefAttr:$function,
                       I64Attr:$arity,
                       I64Attr:$num_captured);
  let results = (outs AnyType:$result);
}

def Eco_PapExtendOp : Eco_Op<"papExtend"> {
  let summary = "Extend closure with more arguments";
  let description = [{
    Extend an existing partial application (closure) with more arguments.
    This is the second phase of closure handling for currying.

    If the closure becomes fully saturated (all arguments provided), this
    may trigger an actual function call and return the result. Otherwise,
    returns a new closure with the additional captured arguments.

    Example:
    ```mlir
    %extended = "eco.papExtend"(%closure, %arg1, %arg2)
      : (!eco.value, !eco.value, !eco.value) -> (!eco.value)
    ```
  }];

  let arguments = (ins AnyType:$closure,
                       Variadic<AnyType>:$newargs);
  let results = (outs AnyType:$result);
}

//------------------------------------------------------------------------------
// 5. Allocation and GC operations
//------------------------------------------------------------------------------

def Eco_AllocateOp : Eco_Op<"allocate"> {
  let summary = "Generic heap allocation";
  let description = [{
    Allocate a heap object of the specified size.

    Example:
    ```mlir
    %obj = "eco.allocate"(%size) {
      type = @TypeName,
      needs_root = true
    } : (i64) -> (!eco.value)
    ```
  }];

  let arguments = (ins AnyType:$size,
                       FlatSymbolRefAttr:$type,
                       BoolAttr:$needs_root);
  let results = (outs AnyType:$result);
}

def Eco_AllocateCtorOp : Eco_Op<"allocate_ctor"> {
  let summary = "Allocate constructor object";
  let description = [{
    Allocate space for a constructor object with the specified tag and size.

    Example:
    ```mlir
    %obj = "eco.allocate_ctor"() {
      tag = 1,
      size = 2,
      scalar_bytes = 0
    } : () -> (!eco.value)
    ```
  }];

  let arguments = (ins I64Attr:$tag,
                       I64Attr:$size,
                       I64Attr:$scalar_bytes);
  let results = (outs AnyType:$result);
}

def Eco_AllocateStringOp : Eco_Op<"allocate_string"> {
  let summary = "Allocate string storage";
  let description = [{
    Allocate storage for a string of the specified length.
  }];

  let arguments = (ins I64Attr:$length);
  let results = (outs AnyType:$result);
}

def Eco_AllocateClosureOp : Eco_Op<"allocate_closure"> {
  let summary = "Allocate closure object";
  let description = [{
    Allocate a closure object for the specified function with space for
    captured values.

    Example:
    ```mlir
    %closure = "eco.allocate_closure"() {
      function = @func,
      num_captures = 3
    } : () -> (!eco.value)
    ```
  }];

  let arguments = (ins FlatSymbolRefAttr:$function,
                       I64Attr:$num_captures);
  let results = (outs AnyType:$result);
}

def Eco_SafepointOp : Eco_Op<"safepoint"> {
  let summary = "GC safepoint";
  let description = [{
    GC safepoint operation. Inserted by GC passes to mark points where
    garbage collection can safely occur. The stack_map describes live
    !eco.value roots at this point.
  }];

  let arguments = (ins StrAttr:$stack_map);
  let results = (outs);
}

//------------------------------------------------------------------------------
// 6. Module and global state
//------------------------------------------------------------------------------

def Eco_GlobalOp : Eco_Op<"global"> {
  let summary = "Declare global variable";
  let description = [{
    Declare a global variable managed by the runtime/GC.

    Example:
    ```mlir
    "eco.global"() {name = @global_name} : () -> ()
    ```
  }];

  let arguments = (ins FlatSymbolRefAttr:$name);
  let results = (outs);
}

def Eco_StoreGlobalOp : Eco_Op<"store_global"> {
  let summary = "Store to global variable";
  let description = [{
    Initialize or update a global variable.

    Example:
    ```mlir
    "eco.store_global"(%value) {global = @global_name}
      : (!eco.value) -> ()
    ```
  }];

  let arguments = (ins AnyType:$value,
                       FlatSymbolRefAttr:$global);
  let results = (outs);
}

//------------------------------------------------------------------------------
// 7. Reference counting / reuse (Perceus) - Placeholders
//------------------------------------------------------------------------------
// Note: The current GC design uses tracing GC, not reference counting.
// These operations are kept as placeholders for potential future use.

def Eco_IncrefOp : Eco_Op<"incref"> {
  let summary = "Increment reference count (placeholder)";
  let description = [{
    Increment the reference count of a heap object. The increment amount
    is usually modeled as an integer attribute.

    Note: Placeholder for potential Perceus-style memory management.
  }];

  let arguments = (ins AnyType:$value,
                       I64Attr:$amount);
  let results = (outs);
}

def Eco_DecrefOp : Eco_Op<"decref"> {
  let summary = "Decrement reference count (placeholder)";
  let description = [{
    Decrement reference count; if it reaches zero, recursively free children.

    Note: Placeholder for potential Perceus-style memory management.
  }];

  let arguments = (ins AnyType:$value);
  let results = (outs);
}

def Eco_DecrefShallowOp : Eco_Op<"decref_shallow"> {
  let summary = "Decrement reference count non-recursively (placeholder)";
  let description = [{
    Decrement reference count without recursively freeing children
    (shallow dec).

    Note: Placeholder for potential Perceus-style memory management.
  }];

  let arguments = (ins AnyType:$value);
  let results = (outs);
}

def Eco_FreeOp : Eco_Op<"free"> {
  let summary = "Free unique object (placeholder)";
  let description = [{
    Free an object known to have reference count 1 (unique / owned).

    Note: Placeholder for potential Perceus-style memory management.
  }];

  let arguments = (ins AnyType:$value);
  let results = (outs);
}

def Eco_ResetOp : Eco_Op<"reset"> {
  let summary = "Reset object for reuse (placeholder)";
  let description = [{
    Reset an object for in-place reuse if unique; otherwise perform
    appropriate decrefs/frees.

    Note: Placeholder for potential Perceus-style memory management.
  }];

  let arguments = (ins AnyType:$value);
  let results = (outs AnyType:$newValue);
}

def Eco_ResetRefOp : Eco_Op<"reset_ref"> {
  let summary = "Reset reference with update mode (placeholder)";
  let description = [{
    Variant of reset that updates a reference (pointer slot) in-place
    depending on update mode.

    Note: Placeholder for potential Perceus-style memory management.
  }];

  let arguments = (ins AnyType:$ref);
  let results = (outs AnyType:$newRef);
}
