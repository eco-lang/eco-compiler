//===- EcoOps.td - Eco dialect operations -----------------------*- tablegen -*-===//
//
// Minimal, skeletal MLIR ODS definitions for Eco dialect operations.
// No parser/printer/builder/verification is provided.
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

def Eco_FuncOp : Eco_Op<"func"> {
  let summary = "Function definition";
  let description = [{
    Defines a function with a body region. Used for Elm functions that have been
    lambda-lifted and converted to top-level definitions.
  }];

  let regions = (region AnyRegion:$body);
}

def Eco_LetOp : Eco_Op<"let"> {
  let summary = "Let-binding";
  let description = [{
    Represents an Elm let-binding. Passes the input value through unchanged,
    providing a named binding point in the IR for debugging and analysis.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$result);
}

def Eco_SwitchOp : Eco_Op<"switch"> {
  let summary = "Pattern match on ADT constructor tag";
  let description = [{
    Pattern match on an Elm value's constructor tag. The cases region contains
    one block per constructor alternative, and defaultRegion handles unmatched
    cases. Used for compiling Elm case expressions.
  }];

  let arguments = (ins AnyType:$scrutinee);
  let regions   = (region AnyRegion:$cases,
                   AnyRegion:$defaultRegion);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_RetOp : Eco_Op<"ret", [Terminator]> {
  let summary = "Return from function";
  let description = [{
    Returns values from an eco.func. Terminates the current block.
  }];

  let arguments = (ins Variadic<AnyType>:$results);
  let results   = (outs);
}

def Eco_JoinpointOp : Eco_Op<"joinpoint"> {
  let summary = "Local control flow label";
  let description = [{
    Defines a joinpoint for efficient local control flow without heap allocation.
    The jpRegion contains the joinpoint body with block arguments as parameters.
    The continuation region contains code that follows the joinpoint declaration
    and may jump to the joinpoint via eco.jump.
  }];

  let regions = (region AnyRegion:$jpRegion,
                 AnyRegion:$continuation);
  let results = (outs);
}

def Eco_JumpOp : Eco_Op<"jump", [Terminator]> {
  let summary = "Jump to joinpoint";
  let description = [{
    Transfers control to a joinpoint defined by eco.joinpoint, passing arguments
    that bind to the joinpoint's block parameters. Terminates the current block.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs);
}

def Eco_CrashOp : Eco_Op<"crash", [Terminator]> {
  let summary = "Unconditional program abort";
  let description = [{
    Aborts execution with an error message. Used for Elm's Debug.todo and
    exhaustive pattern match failures. Lowers to a runtime call followed by
    unreachable.
  }];

  let arguments = (ins AnyType:$message);
  let results   = (outs);
}

def Eco_ExpectOp : Eco_Op<"expect"> {
  let summary = "Runtime assertion";
  let description = [{
    Checks a condition and aborts with message if false. Returns the condition
    value for chaining. Used for internal runtime invariant checks.
  }];

  let arguments = (ins AnyType:$cond,
                       AnyType:$message);
  let results   = (outs AnyType:$value);
}

def Eco_DbgOp : Eco_Op<"dbg"> {
  let summary = "Debug logging";
  let description = [{
    Emits debug output for development. Used to implement Elm's Debug.log.
    Lowers to a runtime logging call or is stripped in release builds.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs);
}

//------------------------------------------------------------------------------
// 2. Values / aggregates / ADTs
//------------------------------------------------------------------------------

def Eco_StringLiteralOp : Eco_Op<"string_literal"> {
  let summary = "String constant";
  let description = [{
    Creates a heap-allocated Elm String from a compile-time constant. The string
    data is stored in the constant pool and wrapped in a String header at runtime.
  }];

  let results = (outs AnyType:$result);
}

def Eco_StructOp : Eco_Op<"struct"> {
  let summary = "Construct record or tuple";
  let description = [{
    Constructs an Elm record or tuple from field values. Fields are stored
    contiguously after the object header in the order provided.
  }];

  let arguments = (ins Variadic<AnyType>:$fields);
  let results   = (outs AnyType:$result);
}

def Eco_StructExtractOp : Eco_Op<"struct_extract"> {
  let summary = "Extract record or tuple field";
  let description = [{
    Extracts a field from an Elm record or tuple by index. The field index
    is specified via an attribute.
  }];

  let arguments = (ins AnyType:$structValue);
  let results   = (outs AnyType:$field);
}

def Eco_TagConstructOp : Eco_Op<"tag_construct"> {
  let summary = "Construct custom type value";
  let description = [{
    Constructs an Elm custom type (ADT) variant. The constructor tag and name
    are specified via attributes. Payload fields follow the header in memory.
  }];

  let arguments = (ins Variadic<AnyType>:$payload);
  let results   = (outs AnyType:$result);
}

def Eco_TagGetIdOp : Eco_Op<"tag_get_id"> {
  let summary = "Read constructor tag";
  let description = [{
    Reads the constructor tag from an Elm custom type value's header. Returns
    an integer identifying which variant the value represents.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$tagId);
}

def Eco_TagExtractOp : Eco_Op<"tag_extract"> {
  let summary = "Extract custom type payload field";
  let description = [{
    Extracts a payload field from an Elm custom type variant by index. Assumes
    the value has the expected constructor tag; behavior is undefined otherwise.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$field);
}

def Eco_ListLiteralOp : Eco_Op<"list_literal"> {
  let summary = "Construct list from elements";
  let description = [{
    Constructs an Elm List from element values. Allocates Cons cells for each
    element, linking them into a singly-linked list terminated by Nil.
  }];

  let arguments = (ins Variadic<AnyType>:$elems);
  let results   = (outs AnyType:$result);
}

def Eco_EmptyListOp : Eco_Op<"empty_list"> {
  let summary = "Empty list constant";
  let description = [{
    Returns Elm's empty list (Nil). This is a constant embedded in the pointer
    representation, not a heap allocation.
  }];

  let results = (outs AnyType:$result);
}

def Eco_ErasedPackOp : Eco_Op<"erased.pack"> {
  let summary = "Erase type information";
  let description = [{
    Converts a typed value to the uniform boxed representation. Used when
    storing values in polymorphic containers or passing to generic functions.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$erased);
}

def Eco_ErasedUnpackOp : Eco_Op<"erased.unpack"> {
  let summary = "Restore type information";
  let description = [{
    Converts a boxed value back to a typed representation. The result type
    must match the original value's type; behavior is undefined otherwise.
  }];

  let arguments = (ins AnyType:$erased);
  let results   = (outs AnyType:$value);
}

//------------------------------------------------------------------------------
// 3. Calls and builtins
//------------------------------------------------------------------------------

def Eco_CallOp : Eco_Op<"call"> {
  let summary = "Direct function call";
  let description = [{
    Calls a function by symbol reference. The function symbol and optional
    tail-call attribute are specified via attributes. Arguments must match
    the function's parameter types.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallIndirectOp : Eco_Op<"call_indirect"> {
  let summary = "Call through closure";
  let description = [{
    Invokes a function through a closure value. The callee is a Closure object
    containing a function pointer and captured environment. Used for calling
    partially-applied functions and first-class function values.
  }];

  let arguments = (ins AnyType:$callee,
                       Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallForeignOp : Eco_Op<"call_foreign"> {
  let summary = "Call external C function";
  let description = [{
    Calls an external C function for FFI or runtime integration. The foreign
    symbol and calling convention are specified via attributes. Arguments are
    marshalled according to the C ABI.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallLowLevelOp : Eco_Op<"call_lowlevel"> {
  let summary = "Invoke primitive operation";
  let description = [{
    Invokes a built-in primitive operation such as arithmetic, string
    concatenation, or list operations. The specific operation is identified
    by an enum attribute. Lowers to inlined code or runtime calls.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallHOOp : Eco_Op<"call_ho"> {
  let summary = "Higher-order builtin";
  let description = [{
    Invokes a higher-order built-in function like List.map or List.filter.
    These operations take a function argument and are later lowered to loops
    with direct calls for efficiency.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

//------------------------------------------------------------------------------
// 4. Reference counting / reuse (Perceus-style optimization)
//------------------------------------------------------------------------------

def Eco_IncrefOp : Eco_Op<"incref"> {
  let summary = "Increment reference count";
  let description = [{
    Increments the reference count field in a heap object's header. Used for
    Perceus-style reuse analysis where RC=1 enables in-place mutation. The
    increment amount is specified via an integer attribute.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_DecrefOp : Eco_Op<"decref"> {
  let summary = "Decrement reference count";
  let description = [{
    Decrements the reference count and recursively decrements children if
    the count reaches zero. Used in conjunction with eco.incref for
    Perceus-style memory reuse optimization.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_DecrefShallowOp : Eco_Op<"decref_shallow"> {
  let summary = "Shallow reference count decrement";
  let description = [{
    Decrements the reference count without recursively processing children.
    Used when the caller will separately handle child references, avoiding
    redundant traversals.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_FreeOp : Eco_Op<"free"> {
  let summary = "Deallocate unique object";
  let description = [{
    Deallocates an object known to have reference count 1. Used when static
    analysis proves uniqueness, allowing immediate deallocation without
    checking the reference count at runtime.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_ResetOp : Eco_Op<"reset"> {
  let summary = "Prepare object for reuse";
  let description = [{
    Checks if an object can be reused in-place (RC=1). If unique, releases
    child references and returns the object for reuse. If shared, decrements
    the reference and returns null to signal fresh allocation is needed.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$newValue);
}

def Eco_ResetRefOp : Eco_Op<"reset_ref"> {
  let summary = "Reset reference slot for reuse";
  let description = [{
    Like eco.reset but operates on a pointer slot rather than a value.
    Conditionally updates the slot contents based on uniqueness, enabling
    in-place field updates when the containing object is unique.
  }];

  let arguments = (ins AnyType:$ref);
  let results   = (outs AnyType:$newRef);
}