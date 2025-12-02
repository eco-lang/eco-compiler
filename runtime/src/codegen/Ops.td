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
  let summary = "Eco function (placeholder; typically you would just use func.func)";
  let description = [{
    Placeholder Eco function op. In practice you can likely reuse builtin
    func.func and not define this.
  }];

  // Function body region.
  let regions = (region AnyRegion:$body);
}

def Eco_LetOp : Eco_Op<"let"> {
  let summary = "Let-binding placeholder op";
  let description = [{
    Represents a Eco IR let-binding; in MLIR SSA form this is usually not
    needed and can be modeled directly with SSA values.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$result);
}

def Eco_SwitchOp : Eco_Op<"switch"> {
  let summary = "Eco switch / pattern-match on scrutinee";
  let description = [{
    High-level switch over a scrutinee value. For now this is modeled with
    one region for the case arms and one for the default; you may want
    variadic regions plus attributes for case keys.
  }];

  let arguments = (ins AnyType:$scrutinee);
  let regions   = (region AnyRegion:$cases,
                   AnyRegion:$defaultRegion);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_RetOp : Eco_Op<"ret", [Terminator]> {
  let summary = "Eco return";
  let description = [{
    Return from a Eco function.
  }];

  let arguments = (ins Variadic<AnyType>:$results);
  let results   = (outs);
}

def Eco_JoinpointOp : Eco_Op<"joinpoint"> {
  let summary = "Joinpoint definition";
  let description = [{
    Defines a joinpoint with parameters and a body region, plus a continuation
    region for code after the joinpoint declaration.
  }];

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
    the joinpoint’s parameters.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs);
}

def Eco_CrashOp : Eco_Op<"crash", [Terminator]> {
  let summary = "Crash / panic";
  let description = [{
    Unconditional crash (panic). Typically lowers to a call into the Eco
    runtime plus an unreachable/return.
  }];

  let arguments = (ins AnyType:$message);
  let results   = (outs);
}

def Eco_ExpectOp : Eco_Op<"expect"> {
  let summary = "Debug assertion (expect)";
  let description = [{
    Represents Eco's Expect statement (runtime assertion).
  }];

  let arguments = (ins AnyType:$cond,
                       AnyType:$message);
  let results   = (outs AnyType:$value);
}

def Eco_DbgOp : Eco_Op<"dbg"> {
  let summary = "Debug/logging operation";
  let description = [{
    Debug/log op; can be lowered to calls or metadata as needed.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs);
}

//------------------------------------------------------------------------------
// 2. Values / aggregates / ADTs
//------------------------------------------------------------------------------

def Eco_StringLiteralOp : Eco_Op<"string_literal"> {
  let summary = "Eco string literal";
  let description = [{
    Creates a Eco string value (e.g. {ptr,len,cap} layout).
  }];

  let results = (outs AnyType:$result);
}

def Eco_StructOp : Eco_Op<"struct"> {
  let summary = "Construct Eco struct value";
  let description = [{
    Constructs a Eco struct (product) value from field operands.
  }];

  let arguments = (ins Variadic<AnyType>:$fields);
  let results   = (outs AnyType:$result);
}

def Eco_StructExtractOp : Eco_Op<"struct_extract"> {
  let summary = "Extract field from Eco struct";
  let description = [{
    Extract a single field from a Eco struct value.
  }];

  let arguments = (ins AnyType:$structValue);
  let results   = (outs AnyType:$field);
}

def Eco_TagConstructOp : Eco_Op<"tag_construct"> {
  let summary = "Construct tagged union value";
  let description = [{
    Construct a Eco tagged union (ADT constructor) with a given payload.
  }];

  let arguments = (ins Variadic<AnyType>:$payload);
  let results   = (outs AnyType:$result);
}

def Eco_TagGetIdOp : Eco_Op<"tag_get_id"> {
  let summary = "Get tag id from tagged union";
  let description = [{
    Read the discriminant/tag id from a Eco union value.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$tagId);
}

def Eco_TagExtractOp : Eco_Op<"tag_extract"> {
  let summary = "Extract field from tagged union variant";
  let description = [{
    Extract a payload field from a Eco tagged union, given that it is a
    particular constructor.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$field);
}

def Eco_ListLiteralOp : Eco_Op<"list_literal"> {
  let summary = "Construct Eco list from elements";
  let description = [{
    Construct a Eco list (array) value from element operands.
  }];

  let arguments = (ins Variadic<AnyType>:$elems);
  let results   = (outs AnyType:$result);
}

def Eco_EmptyListOp : Eco_Op<"empty_list"> {
  let summary = "Empty Eco list";
  let description = [{
    Construct an empty Eco list value for a given element type/layout.
  }];

  let results = (outs AnyType:$result);
}

def Eco_ErasedPackOp : Eco_Op<"erased.pack"> {
  let summary = "Pack value into erased representation";
  let description = [{
    Pack a value into Eco's erased representation (for existential/erased
    types).
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$erased);
}

def Eco_ErasedUnpackOp : Eco_Op<"erased.unpack"> {
  let summary = "Unpack value from erased representation";
  let description = [{
    Unpack a value from Eco's erased representation.
  }];

  let arguments = (ins AnyType:$erased);
  let results   = (outs AnyType:$value);
}

//------------------------------------------------------------------------------
// 3. Calls and builtins
//------------------------------------------------------------------------------

def Eco_CallOp : Eco_Op<"call"> {
  let summary = "Direct call to Eco function";
  let description = [{
    Direct call to a Eco function by symbol/name. Function symbol and
    calling convention are typically modeled as attributes.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallIndirectOp : Eco_Op<"call_indirect"> {
  let summary = "Indirect call via function pointer";
  let description = [{
    Call a function value or function pointer with arguments.
  }];

  let arguments = (ins AnyType:$callee,
                       Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallForeignOp : Eco_Op<"call_foreign"> {
  let summary = "Call foreign (FFI) function";
  let description = [{
    Call into foreign code (C, etc.). Foreign symbol, ABI, and other
    metadata are typically modeled as attributes.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallLowLevelOp : Eco_Op<"call_lowlevel"> {
  let summary = "Call Eco low-level builtin";
  let description = [{
    Represents Eco's low-level builtin operations (List.concat, Str.concat,
    numerical ops, etc.). The specific builtin is usually encoded as an
    enum attribute.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

def Eco_CallHOOp : Eco_Op<"call_ho"> {
  let summary = "Higher-order builtin call";
  let description = [{
    Represents higher-order Eco builtins (e.g. list.map) before they are
    expanded into loops and direct calls.
  }];

  let arguments = (ins Variadic<AnyType>:$args);
  let results   = (outs Variadic<AnyType>:$results);
}

//------------------------------------------------------------------------------
// 4. Reference counting / reuse (Perceus)
//------------------------------------------------------------------------------

def Eco_IncrefOp : Eco_Op<"incref"> {
  let summary = "Increment reference count";
  let description = [{
    Increment the reference count of a heap object. The increment amount
    is usually modeled as an integer attribute.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_DecrefOp : Eco_Op<"decref"> {
  let summary = "Decrement reference count (possibly recursive free)";
  let description = [{
    Decrement reference count; if it reaches zero, recursively free children.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_DecrefShallowOp : Eco_Op<"decref_shallow"> {
  let summary = "Decrement reference count (non-recursive)";
  let description = [{
    Decrement reference count without recursively freeing children
    (shallow dec).
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_FreeOp : Eco_Op<"free"> {
  let summary = "Free unique object";
  let description = [{
    Free an object known to have reference count 1 (unique / owned).
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs);
}

def Eco_ResetOp : Eco_Op<"reset"> {
  let summary = "Reset object for potential in-place reuse";
  let description = [{
    Reset an object for in-place reuse if unique; otherwise perform
    appropriate decrefs/frees.
  }];

  let arguments = (ins AnyType:$value);
  let results   = (outs AnyType:$newValue);
}

def Eco_ResetRefOp : Eco_Op<"reset_ref"> {
  let summary = "Reset reference with update mode semantics";
  let description = [{
    Variant of reset that updates a reference (pointer slot) in-place
    depending on update mode.
  }];

  let arguments = (ins AnyType:$ref);
  let results   = (outs AnyType:$newRef);
}