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
// GCRootCarrier OpInterface
//===----------------------------------------------------------------------===//

def Eco_GCRootCarrierOpInterface : OpInterface<"GCRootCarrier"> {
  let cppNamespace = "::eco";

  let description = [{
    Operations that explicitly carry the set of Eco GC roots live across
    a safepoint. EcoGCPrepare computes liveness on Eco IR and populates
    these roots; lowering and statepoint conversion consume them.

    The interface abstracts over different operand layouts:
    - Dedicated `live_roots` segments (most allocation ops)
    - Roots appended after fields (construct.record, construct.custom)
    - Roots appended after call operands (call, papExtend, papCreate)
  }];

  let methods = [
    InterfaceMethod<
      "Return the eco.value roots carried by this operation.",
      "mlir::ValueRange", "getGCRoots", (ins)>,

    InterfaceMethod<
      "Replace the GC root operands carried by this operation. "
      "The op is responsible for preserving non-root operands "
      "and maintaining any operand layout invariants.",
      "void", "setGCRoots",
      (ins "mlir::ValueRange":$newRoots)>
  ];
}

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
// Value-level Aggregate Types (Phase 0 escape-analysis plumbing)
//===----------------------------------------------------------------------===//
//
// These types are an SSA-only representation independent of heap layout
// (REP_AGG_001). They lower to LLVM struct values held in registers, never
// to ptr addrspace(1). Heap-layout artifacts (unboxed_bitmap, field_count,
// tag, head_kind) live on heap construct/`eco.to_heap`/`eco.make.closure`
// ops, never on these types.
//
// Parameterisation: each carries its element types so the EcoTypeConverter
// can map it to LLVMStructType without an op context.
//

def Eco_Tuple2Type : Eco_Type<"Tuple2", "tuple2"> {
  let summary = "Unboxed logical 2-tuple";
  let description = [{
    Logical representation of a 2-tuple at the SSA level. Lowers to
    LLVM struct of two converted element types. Does not imply any
    particular heap layout.
  }];
  let parameters = (ins "::mlir::Type":$first, "::mlir::Type":$second);
  let assemblyFormat = "`<` $first `,` $second `>`";
}

def Eco_Tuple3Type : Eco_Type<"Tuple3", "tuple3"> {
  let summary = "Unboxed logical 3-tuple";
  let parameters = (ins "::mlir::Type":$first,
                        "::mlir::Type":$second,
                        "::mlir::Type":$third);
  let assemblyFormat = "`<` $first `,` $second `,` $third `>`";
}

def Eco_RecordType : Eco_Type<"Record", "record"> {
  let summary = "Unboxed logical record";
  let description = [{
    Logical representation of a record. Field types are carried directly
    on the type. Does not carry an unboxed_bitmap — that lives on heap
    construct/to_heap ops.
  }];
  let parameters = (ins ArrayRefParameter<"::mlir::Type">:$fields);
  let assemblyFormat = "`<` $fields `>`";
}

def Eco_CustomType : Eco_Type<"Custom", "custom"> {
  let summary = "Unboxed logical custom ADT value";
  let description = [{
    Logical representation of a Custom ADT value. The constructor tag is
    structural (op attribute on `eco.make.custom` and `eco.to_heap`), not
    on the type — the type stays generic over field types.
  }];
  let parameters = (ins ArrayRefParameter<"::mlir::Type">:$fields);
  let assemblyFormat = "`<` $fields `>`";
}

def Eco_ConsType : Eco_Type<"Cons", "cons"> {
  let summary = "Unboxed logical cons cell";
  let description = [{
    Logical representation of a list node (head/tail) at the SSA level.
    Tail is fixed to !eco.value (matches the existing heap list spine);
    fully unboxed list spines are out of scope for the initial phase.
  }];
  let parameters = (ins "::mlir::Type":$head, "::mlir::Type":$tail);
  let assemblyFormat = "`<` $head `,` $tail `>`";
}

def Eco_ClosureEnvType : Eco_Type<"ClosureEnv", "closure_env"> {
  let summary = "Unboxed closure environment";
  let description = [{
    Logical representation of a closure environment. Carries captured
    value slot types, not the function symbol or arity — those are
    attached at heap-realisation time by `eco.make.closure`.
  }];
  let parameters = (ins ArrayRefParameter<"::mlir::Type">:$captures);
  let assemblyFormat = "`<` $captures `>`";
}

//===----------------------------------------------------------------------===//
// Type Constraints
//===----------------------------------------------------------------------===//

// Boxed heap value
def Eco_Value : Type<CPred<"llvm::isa<eco::ValueType>($_self)">,
                     "eco.value",
                     "eco::ValueType">,
                     BuildableType<"$_builder.getType<eco::ValueType>()">;

// Aggregate type constraints — used as op operand/result constraints.
def Eco_Tuple2     : Type<CPred<"llvm::isa<eco::Tuple2Type>($_self)">,
                          "eco.tuple2", "eco::Tuple2Type">;
def Eco_Tuple3     : Type<CPred<"llvm::isa<eco::Tuple3Type>($_self)">,
                          "eco.tuple3", "eco::Tuple3Type">;
def Eco_Record     : Type<CPred<"llvm::isa<eco::RecordType>($_self)">,
                          "eco.record", "eco::RecordType">;
def Eco_Custom     : Type<CPred<"llvm::isa<eco::CustomType>($_self)">,
                          "eco.custom", "eco::CustomType">;
def Eco_Cons       : Type<CPred<"llvm::isa<eco::ConsType>($_self)">,
                          "eco.cons", "eco::ConsType">;
def Eco_ClosureEnv : Type<CPred<"llvm::isa<eco::ClosureEnvType>($_self)">,
                          "eco.closure_env", "eco::ClosureEnvType">;

// Data aggregates (everything except closure env). Used to constrain the
// `eco.to_heap` operand: the verifier rejects `!eco.closure_env` here
// because closure realisation goes through `eco.make.closure`.
def Eco_DataAggregate : AnyTypeOf<[Eco_Tuple2, Eco_Tuple3, Eco_Record,
                                   Eco_Custom, Eco_Cons],
                                  "eco data aggregate">;

// Operand constraints for projection ops: accept either the heap form
// (!eco.value) or the matching value-aggregate form. Lowering dispatches
// on the converted operand LLVM type (struct vs ptr addrspace(1)).
def Eco_Tuple2OrValue : AnyTypeOf<[Eco_Value, Eco_Tuple2],
                                  "!eco.value or !eco.tuple2">;
def Eco_Tuple3OrValue : AnyTypeOf<[Eco_Value, Eco_Tuple3],
                                  "!eco.value or !eco.tuple3">;
def Eco_RecordOrValue : AnyTypeOf<[Eco_Value, Eco_Record],
                                  "!eco.value or !eco.record">;
def Eco_CustomOrValue : AnyTypeOf<[Eco_Value, Eco_Custom],
                                  "!eco.value or !eco.custom">;
def Eco_ConsOrValue   : AnyTypeOf<[Eco_Value, Eco_Cons],
                                  "!eco.value or !eco.cons">;
def Eco_ClosureOrEnv  : AnyTypeOf<[Eco_Value, Eco_ClosureEnv],
                                  "!eco.value or !eco.closure_env">;

//===----------------------------------------------------------------------===//
// Constant Attribute Definition
//===----------------------------------------------------------------------===//

// ConstantKind enum matching the Heap.hpp Constant enum (2-bit code): bit 0 is
// the Bool value, bit 1 is the Empty flag. The five former empty constants
// (Unit/EmptyRec/Nil/Nothing/EmptyString) are unified into Empty. See plan D3.
def Eco_ConstantKind : I32EnumAttr<"ConstantKind", "Eco embedded constant kind", [
  I32EnumAttrCase<"False", 0>,   // Const_False
  I32EnumAttrCase<"True", 1>,    // Const_True
  I32EnumAttrCase<"Empty", 2>    // Const_Empty (unified Unit/EmptyRec/Nil/Nothing/"")
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

// Phase 3.4 #1: eco.case may carry an aggregate-typed result when
// cross-spec promotes a join chain whose every alternative's eco.yield
// produces an aggregate. Scrutinees stay `Eco_AnyValue` (Q4: aggregate
// scrutinees are forbidden), only result-side widening applies.
def Eco_AnyValueOrAggregate :
    AnyTypeOf<[Eco_Value, Eco_Int, Eco_Float, Eco_Char, Eco_Bool,
               Eco_Tuple2, Eco_Tuple3, Eco_Record, Eco_Custom, Eco_Cons],
              "eco value, primitive, or value-level aggregate">;

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
    SingleBlockImplicitTerminator<"YieldOp">
]> {
  let summary = "Pattern match on a value and produce results";
  let description = [{
    Pattern match on a value and execute one of several alternative regions,
    producing SSA results. Each region handles a specific tag value and must
    terminate with eco.yield whose operand types match this op's result types.

    **Scrutinee Types and case_kind (required):**
    - `!eco.value` + `case_kind="ctor"`: ADT constructor matching (extract tag via eco.get_tag)
    - `!eco.value` + `case_kind="str"`: String pattern matching. Requires `string_patterns`
      attribute containing N-1 string literals (one per non-default alternative).
      The last alternative region is the default. Lowering uses string equality chain.
    - `i1` + `case_kind="bool"`: Boolean fanout (True/False patterns)
    - `i1` + `case_kind="ctor"`: Boolean from Chain lowering (legacy compatibility)
    - `i64` + `case_kind="int"`: Integer literal matching (direct comparison)
    - `i16` + `case_kind="chr"`: Character literal matching (direct comparison)

    eco.case is a value-producing expression op, NOT a terminator. It produces
    SSA results that can be used by subsequent operations. Each alternative
    region must terminate with eco.yield (not eco.return).

    Example (ADT matching):
    ```mlir
    %result = eco.case %scrutinee [0, 1] -> (!eco.value) { case_kind = "ctor" } {
      eco.yield %nil_result : !eco.value
    }, {
      %head = eco.project.list_head %scrutinee : !eco.value -> !eco.value
      eco.yield %head : !eco.value
    }
    ```

    Example (integer matching):
    ```mlir
    %result = eco.case %x [0, 1, 2] -> (!eco.value) { case_kind = "int" } {
      eco.yield %zero_result : !eco.value
    }, {
      eco.yield %one_result : !eco.value
    }, {
      eco.yield %two_result : !eco.value
    }
    ```

    Regions take no arguments; code inside uses eco.project to extract fields
    from the scrutinee. Each region must terminate with eco.yield. eco.return,
    eco.jump, eco.crash are forbidden inside eco.case alternatives.
  }];

  let arguments = (ins
    Eco_AnyValue:$scrutinee,                   // !eco.value, i1, i16, or i64
    DenseI64ArrayAttr:$tags,
    StrAttr:$case_kind,                        // Required: "ctor", "int", "chr", "str", or "bool"
    OptionalAttr<ArrayAttr>:$string_patterns   // For case_kind="str": N-1 string literals
  );
  let regions = (region VariadicRegion<SizedRegion<1>>:$alternatives);
  // Phase 3.4 #1: results may be aggregate-typed when cross-spec
  // promotes a join chain. Scrutinee stays Eco_AnyValue (Q4).
  let results = (outs Variadic<Eco_AnyValueOrAggregate>:$results);

  let hasVerifier = 1;
  let hasCustomAssemblyFormat = 1;
}

def Eco_ReturnOp : Eco_Op<"return", [
    Pure,
    Terminator,
    ReturnLike
]> {
  let summary = "Return from Eco function or joinpoint body";
  let description = [{
    Return from an Eco function or joinpoint body with optional result values.

    eco.return is used ONLY for:
    - Function body returns (terminating a func.func body)
    - Joinpoint body exits (exiting from eco.joinpoint body region)

    eco.return is NOT valid inside eco.case alternatives. Use eco.yield instead
    to terminate case alternatives.

    Example:
    ```mlir
    eco.return %result : !eco.value
    eco.return  // void return
    ```
  }];

  // Phase 3.4 #1: eco.return operands widen to aggregate types so
  // cross-spec workers (which run before EcoToLLVMControlFlow lowers
  // eco.return → func.return) can terminate with aggregate-typed
  // operands matching the worker's promoted result signature.
  let arguments = (ins Variadic<Eco_AnyValueOrAggregate>:$results);
  let results = (outs);

  let builders = [
    OpBuilder<(ins), [{
      build($_builder, $_state, ValueRange{});
    }]>
  ];

  let assemblyFormat = "($results^ `:` type($results))? attr-dict";
}

def Eco_YieldOp : Eco_Op<"yield", [
    Pure,
    Terminator,
    HasParent<"::eco::CaseOp">
]> {
  let summary = "Yield values from eco.case alternative";
  let description = [{
    Terminates an alternative region in eco.case, yielding values back to the
    parent case expression. The number and types of yielded values must match
    the result types declared by the parent eco.case.

    eco.yield is ONLY valid inside eco.case alternatives. For function returns,
    use eco.return.

    Example:
    ```mlir
    %result = eco.case %scrutinee [0, 1] -> (!eco.value) { case_kind = "ctor" } {
      eco.yield %nil_result : !eco.value
    }, {
      %head = eco.project.list_head %scrutinee : !eco.value -> !eco.value
      eco.yield %head : !eco.value
    }
    ```
  }];

  // Phase 3.4 #1: yield operands widen in lockstep with eco.case
  // results. The YieldOp verifier still enforces yield-types ==
  // parent-case-result-types, so the two stay structurally aligned.
  let arguments = (ins Variadic<Eco_AnyValueOrAggregate>:$values);
  let results = (outs);

  let assemblyFormat = "($values^ `:` type($values))? attr-dict";

  let hasVerifier = 1;
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
    AnyRegion:$body,
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

    When `arg_type_ids` is present, uses the global type graph for
    pretty-printing with full Elm syntax (field names, constructor names).

    Example:
    ```mlir
    eco.dbg %value1, %value2 : !eco.value, i64
    eco.dbg %x : !eco.value { arg_type_ids = [0 : i64] }
    ```
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$args,
    OptionalAttr<DenseI64ArrayAttr>:$arg_type_ids
  );
  let results = (outs);

  let assemblyFormat = "($args^ `:` type($args))? attr-dict";
}

def Eco_TypeTableOp : Eco_Op<"type_table", [HasParent<"::mlir::ModuleOp">]> {
  let summary = "Global type information graph for debug/reflection";
  let description = [{
    Module-level operation that holds the serialized type graph for the
    compiled Elm program. Used by eco.dbg with arg_type_ids for typed
    debug printing with full Elm syntax.

    Lowered to LLVM globals that form the EcoTypeGraph struct, which the
    runtime accesses via the __eco_type_graph symbol.

    Example:
    ```mlir
    eco.type_table {
      types = [...],
      fields = [...],
      ctors = [...],
      func_args = [...],
      strings = [...]
    }
    ```
  }];

  let arguments = (ins
    OptionalAttr<ArrayAttr>:$types,
    OptionalAttr<ArrayAttr>:$fields,
    OptionalAttr<ArrayAttr>:$ctors,
    OptionalAttr<ArrayAttr>:$func_args,
    OptionalAttr<ArrayAttr>:$strings
  );
  let results = (outs);

  let assemblyFormat = "attr-dict";
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
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

//===----------------------------------------------------------------------===//
// 2b. Type-Specific Construction and Projection Operations
//===----------------------------------------------------------------------===//
//
// Type-specific construction and projection ops enforce HEAP_015: header tag
// must match the concrete runtime type.
//

//===----------------------------------------------------------------------===//
// List Operations (Cons / Nil)
//===----------------------------------------------------------------------===//

def Eco_ListConstructOp : Eco_Op<"construct.list", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Construct a list Cons cell";
  let description = [{
    Allocate a list cons cell: head :: tail.

    Head can be boxed (!eco.value) or unboxed primitive (i64, f64, i16).
    Tail is always boxed (!eco.value). Nil is represented as an embedded
    constant via `eco.constant Nil`, not heap-allocated.

    `head_unboxed` is a boolean flag (true iff head is a primitive).
    `head_kind` is the 2-bit slot kind stored into `cons->header.unboxed`
    slot 0: `00` = boxed HPointer, `01` = Int, `10` = Float, `11` = Char.

    Example:
    ```mlir
    %cons = eco.construct.list %head, %tail {head_unboxed = false, head_kind = 0}
      : !eco.value, !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_AnyValueOrAggregate:$head,
    Eco_Value:$tail,
    Variadic<Eco_Value>:$live_roots,
    DefaultValuedAttr<BoolAttr, "false">:$head_unboxed,
    DefaultValuedAttr<I64Attr, "0">:$head_kind
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$head `,` $tail (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($head) `,` type($tail) `->` type($result)";
}

def Eco_ListHeadOp : Eco_Op<"project.list_head", [Pure]> {
  let summary = "Project head of a list Cons cell";
  let description = [{
    Project the head field of a non-empty list (Cons cell).
    Result type depends on whether head is unboxed.

    Operand may be either `!eco.value` (heap Cons — current heap-load
    lowering) or `!eco.cons<head, tail>` (value-level cons — lowers to
    LLVM extractvalue at index 0).

    Example:
    ```mlir
    %head = eco.project.list_head %list : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_ConsOrValue:$list);
  let results = (outs Eco_AnyValueOrAggregate:$head);

  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($head)";
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

def Eco_ListTailOp : Eco_Op<"project.list_tail", [Pure]> {
  let summary = "Project tail of a list Cons cell";
  let description = [{
    Project the tail field of a non-empty list (Cons cell).
    Tail is always a boxed list pointer (!eco.value).

    Operand may be either `!eco.value` (heap Cons) or
    `!eco.cons<head, tail>` (value-level cons; tail is fixed to
    `!eco.value` for now). Lowering dispatches on the converted operand
    LLVM type.

    Example:
    ```mlir
    %tail = eco.project.list_tail %list : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_ConsOrValue:$list);
  let results = (outs Eco_Value:$tail);

  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($tail)";
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

def Eco_ListAppendOp : Eco_Op<"list.append"> {
  let summary = "Concatenate two Lists (a ++ b), typed";
  let description = [{
    Typed replacement for `Elm_Kernel_Utils_append` at `(List _, List _)` mono
    sites. Accepts every spine form (Tag_Cons, Tag_ConsChunk, Nil embedded
    constant). Allocates a VARIABLE number of cells (or one chunk chain), so it
    is NOT fixed-size-groupable and is deliberately trait-free. The result
    SHARES the rhs spine.

    ```mlir
    %l = eco.list.append %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

//===----------------------------------------------------------------------===//
// Tuple Operations
//===----------------------------------------------------------------------===//

def Eco_Tuple2ConstructOp : Eco_Op<"construct.tuple2", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Construct a 2-tuple";
  let description = [{
    Construct a 2-tuple value. Elements may be boxed (!eco.value) or
    unboxed primitives (i64, f64, i16).

    Each slot occupies 2 bits of `unboxed_bitmap`: `00` = boxed HPointer,
    `01` = Int, `10` = Float, `11` = Char. Slot i's kind lives at bits
    [2i, 2i+1]. Tuple2 uses 4 bits (slots 0 and 1).

    Example:
    ```mlir
    %tuple = eco.construct.tuple2 %a, %b {unboxed_bitmap = 0}
      : !eco.value, !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_AnyValueOrAggregate:$a,
    Eco_AnyValueOrAggregate:$b,
    Variadic<Eco_Value>:$live_roots,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$a `,` $b (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($a) `,` type($b) `->` type($result)";
}

def Eco_Tuple3ConstructOp : Eco_Op<"construct.tuple3", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Construct a 3-tuple";
  let description = [{
    Construct a 3-tuple value.

    Each slot occupies 2 bits of `unboxed_bitmap`: `00` = boxed HPointer,
    `01` = Int, `10` = Float, `11` = Char. Slot i's kind lives at bits
    [2i, 2i+1]. Tuple3 uses 6 bits (slots 0, 1, 2).

    Example:
    ```mlir
    %tuple = eco.construct.tuple3 %a, %b, %c {unboxed_bitmap = 0}
      : !eco.value, !eco.value, !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_AnyValueOrAggregate:$a,
    Eco_AnyValueOrAggregate:$b,
    Eco_AnyValueOrAggregate:$c,
    Variadic<Eco_Value>:$live_roots,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$a `,` $b `,` $c (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($a) `,` type($b) `,` type($c) `->` type($result)";
}

def Eco_Tuple2ProjectOp : Eco_Op<"project.tuple2", [Pure]> {
  let summary = "Project field from 2-tuple";
  let description = [{
    Project element 0 or 1 from a 2-tuple. Result type is the concrete
    SSA type (primitive or !eco.value) based on unboxed status.

    Operand may be either `!eco.value` (heap-backed Tuple2 — existing
    heap-load lowering) or `!eco.tuple2<...>` (value-level aggregate —
    lowers to LLVM extractvalue).

    Example:
    ```mlir
    %first = eco.project.tuple2 %tuple[0] : !eco.value -> !eco.value
    %a     = eco.project.tuple2 %agg[0]   : !eco.tuple2<i64, !eco.value> -> i64
    ```
  }];

  let arguments = (ins Eco_Tuple2OrValue:$tuple, I64Attr:$field);
  let results = (outs Eco_AnyValueOrAggregate:$result);

  let assemblyFormat = "$tuple `[` $field `]` attr-dict `:` type($tuple) `->` type($result)";
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

def Eco_Tuple3ProjectOp : Eco_Op<"project.tuple3", [Pure]> {
  let summary = "Project field from 3-tuple";
  let description = [{
    Project element 0, 1, or 2 from a 3-tuple.

    Operand may be either `!eco.value` or `!eco.tuple3<...>`; lowering
    dispatches on the converted operand LLVM type.

    Example:
    ```mlir
    %second = eco.project.tuple3 %tuple[1] : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_Tuple3OrValue:$tuple, I64Attr:$field);
  let results = (outs Eco_AnyValueOrAggregate:$result);

  let assemblyFormat = "$tuple `[` $field `]` attr-dict `:` type($tuple) `->` type($result)";
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

//===----------------------------------------------------------------------===//
// Record Operations
//===----------------------------------------------------------------------===//

def Eco_RecordConstructOp : Eco_Op<"construct.record", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Construct an Elm record";
  let description = [{
    Construct a record with a fixed set of fields. `field_count` gives
    the slot count; `unboxed_bitmap` carries the 2-bit-per-slot kinds.

    Each slot occupies 2 bits of `unboxed_bitmap`: `00` = boxed HPointer,
    `01` = Int, `10` = Float, `11` = Char. Slot i's kind lives at bits
    [2i, 2i+1]. Record's bitmap is 64 bits wide, but the GC scan reads
    kinds for the first 32 slots only, and the Elm front-end computes
    bitmaps with exact Int arithmetic capped at 26 typed slots
    (Types.maxTypedSlots); fields beyond that cap are stored boxed.

    The per-slot kind must exactly match the field operand's SSA type
    (REP_BOUNDARY_002): the lowering dispatches the store on the operand
    type while the GC trusts the bitmap, so any mismatch is a
    GC-corruption bug. The verifier enforces this.

    GC live roots may be appended after the fields by EcoGCPrepare.
    The first `field_count` operands are fields; any beyond that are
    live GC roots tracked across this allocation.

    Example:
    ```mlir
    %rec = eco.construct.record(%x, %y) {field_count = 2, unboxed_bitmap = 0}
      : (!eco.value, !eco.value) -> !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$fields,
    I64Attr:$field_count,
    I64Attr:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";

  let hasVerifier = 1;
}

def Eco_RecordProjectOp : Eco_Op<"project.record", [Pure]> {
  let summary = "Project a record field";
  let description = [{
    Project the field at a given index from a record. Result type is
    the concrete SSA type based on unboxed status.

    Operand may be either `!eco.value` (heap record — current heap-load
    lowering) or `!eco.record<...>` (value-level aggregate — lowers to
    LLVM extractvalue).

    Example:
    ```mlir
    %x = eco.project.record %rec[0] : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_RecordOrValue:$record, I64Attr:$field_index);
  let results = (outs Eco_AnyValueOrAggregate:$result);

  let assemblyFormat = "$record `[` $field_index `]` attr-dict `:` type($record) `->` type($result)";
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

//===----------------------------------------------------------------------===//
// Custom ADT Operations
//===----------------------------------------------------------------------===//

def Eco_CustomConstructOp : Eco_Op<"construct.custom", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Construct a custom ADT value";
  let description = [{
    Create a custom algebraic data type (ADT) value for a user-defined type.
    This is ONLY for custom ADTs (Maybe, Result, user types), NOT for:
    - Lists (use eco.construct.list)
    - Tuples (use eco.construct.tuple2, eco.construct.tuple3)
    - Records (use eco.construct.record)

    The tag is the numeric constructor discriminant. The size must match
    the number of field operands.

    Each slot occupies 2 bits of `unboxed_bitmap`: `00` = boxed HPointer,
    `01` = Int, `10` = Float, `11` = Char. Slot i's kind lives at bits
    [2i, 2i+1]. Custom's bitmap is 48 bits wide (up to 24 fields with
    typed slots); fields beyond index 23 are stored boxed.

    The optional constructor attribute is for MLIR readability only and is
    not stored at runtime. Debug printing uses generic Ctor1, Ctor2, etc.

    GC live roots may be appended after the fields by EcoGCPrepare.
    The first `size` operands are fields; any beyond that are live GC
    roots tracked across this allocation.

    Example:
    ```mlir
    %just = eco.construct.custom(%inner) {
      tag = 1,
      size = 1,
      unboxed_bitmap = 0,
      constructor = "Just"
    } : (!eco.value) -> !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$fields,
    I64Attr:$tag,
    I64Attr:$size,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap,
    OptionalAttr<StrAttr>:$constructor
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;

  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";
}

def Eco_CustomProjectOp : Eco_Op<"project.custom", [Pure]> {
  let summary = "Project field from custom ADT value";
  let description = [{
    Project field at given index from a Custom ADT value.
    Only use for Custom ADTs, not for Lists/Tuples/Records.

    Operand may be either `!eco.value` (heap Custom — current heap-load
    lowering) or `!eco.custom<...>` (value-level aggregate — lowers to
    LLVM extractvalue).

    Example:
    ```mlir
    %inner = eco.project.custom %just[0] : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_CustomOrValue:$container, I64Attr:$field_index);
  let results = (outs Eco_AnyValueOrAggregate:$result);

  let assemblyFormat = "$container `[` $field_index `]` attr-dict `:` type($container) `->` type($result)";
  let hasFolder = 1; // kernel-opt-10: fold through a dominating eco.construct.*
}

//===----------------------------------------------------------------------===//
// 2b. Array Operations (ElmArray intrinsics)
//===----------------------------------------------------------------------===//

def Eco_ArrayGetOp : Eco_Op<"array.get", [Pure]> {
  let summary = "Get element from Elm array by index";
  let description = [{
    Load element at index from an ElmArray. The result type is determined
    by the monomorphized element type:
    - i64 for Int elements (read unboxed from elements[])
    - f64 for Float elements (bitcast from i64 in elements[])
    - i16 for Char elements (truncate from i64 in elements[])
    - !eco.value for boxed elements (pointer from elements[])

    No bounds checking is performed (mirrors JsArray.unsafeGet semantics).

    Example:
    ```mlir
    %elt = eco.array.get %arr[%i] : i64
    %boxed = eco.array.get %arr[%i] : !eco.value
    ```
  }];

  let arguments = (ins Eco_Value:$array, Eco_Int:$index);
  let results = (outs Eco_AnyValue:$result);
  let assemblyFormat = "$array `[` $index `]` attr-dict `:` type($result)";
}

def Eco_ArraySetOp : Eco_Op<"array.set"> {
  let summary = "Functional update of Elm array element";
  let description = [{
    Return a new ElmArray with element at index replaced by value.
    Allocates a new array (Elm arrays are immutable). The value type
    determines how it is stored in elements[]:
    - i64 stored directly
    - f64 bitcast to i64
    - i16 zero-extended to i64
    - !eco.value stored as pointer bits

    No bounds checking (mirrors JsArray.unsafeSet semantics).

    Example:
    ```mlir
    %arr2 = eco.array.set %arr[%i] = %v : i64
    %arr3 = eco.array.set %arr[%i] = %boxed_v : !eco.value
    ```
  }];

  let arguments = (ins Eco_Value:$array, Eco_Int:$index, Eco_AnyValue:$value);
  let results = (outs Eco_Value:$result);
  let assemblyFormat =
    "$array `[` $index `]` `=` $value attr-dict `:` type($value)";
}

def Eco_ArrayLengthOp : Eco_Op<"array.length", [Pure]> {
  let summary = "Get length of Elm array";
  let description = [{
    Read the length field from an ElmArray header. Returns the count
    of elements currently in use (not capacity).

    Example:
    ```mlir
    %len = eco.array.length %arr
    ```
  }];

  let arguments = (ins Eco_Value:$array);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$array attr-dict";
}

def Eco_ArrayEmptyOp : Eco_Op<"array.empty"> {
  let summary = "Allocate empty Elm array";
  let description = [{
    Allocate an empty ElmArray. Element kind is unbound — fixed by the first
    `eco.array.set` / `eco.array.push` write.
  }];
  let arguments = (ins);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "attr-dict `:` type($result)";
}

def Eco_ArraySingletonOp : Eco_Op<"array.singleton"> {
  let summary = "Allocate single-element Elm array";
  let description = [{
    Allocate a 1-element ElmArray. Element kind comes from the operand's
    MLIR type (i64/f64/i16 unboxed, !eco.value boxed).
  }];
  let arguments = (ins Eco_AnyValue:$value);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_ArrayPushOp : Eco_Op<"array.push"> {
  let summary = "Push value onto Elm array (returns new array)";
  let description = [{
    Functional push: returns a new ElmArray with `value` appended. Element
    kind comes from the operand MLIR type, mirroring `eco.array.set`.
  }];
  let arguments = (ins Eco_AnyValue:$value, Eco_Value:$array);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$value `,` $array attr-dict `:` type($value) `->` type($result)";
}

def Eco_ArraySliceOp : Eco_Op<"array.slice"> {
  let summary = "Slice an Elm array";
  let description = [{
    Allocate a new ElmArray containing array[start:end]. Element kind is
    inherited from the source array at runtime.
  }];
  let arguments = (ins Eco_Int:$start, Eco_Int:$end, Eco_Value:$array);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$start `,` $end `,` $array attr-dict `:` type($result)";
}

def Eco_ArrayAppendNOp : Eco_Op<"array.append_n"> {
  let summary = "Append up to N elements from source onto dest";
  let description = [{
    Allocate a new ElmArray with up to `n` total elements from `dest` then
    `source`. Element kind inherited at runtime.
  }];
  let arguments = (ins Eco_Int:$n, Eco_Value:$dest, Eco_Value:$source);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$n `,` $dest `,` $source attr-dict `:` type($result)";
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

    Representation: this op always lowers to a flat `Tag_String` leaf in the
    runtime heap. The runtime String operations (StringOps, kernel String
    module) may transform results into structural views (`Tag_StringSlice`,
    Phase 1) or rope nodes (`Tag_StringRope`, Phase 2). MLIR/codegen never
    directly produces those tags — they arise only from runtime operations.

    Example:
    ```mlir
    %hello = eco.string_literal "Hello, World!"
    ```
  }];

  let arguments = (ins StrAttr:$value);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$value attr-dict `:` type($result)";
}

def Eco_StringFromIntOp : Eco_Op<"string.from_int"> {
  let summary = "Convert unboxed Int to String (String.fromInt)";
  let description = [{
    Allocates a String representation of the integer. Operand is unboxed i64;
    result is `!eco.value` carrying a Tag_String leaf. Allocates — RS4GC
    inserts statepoint at the lowered call site.
  }];
  let arguments = (ins Eco_Int:$value);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

def Eco_StringFromFloatOp : Eco_Op<"string.from_float"> {
  let summary = "Convert unboxed Float to String (String.fromFloat)";
  let description = [{
    Allocates a String representation of the float. Operand is unboxed f64;
    result is `!eco.value` carrying a Tag_String leaf. Allocates.
  }];
  let arguments = (ins Eco_Float:$value);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$value attr-dict `:` type($value) `->` type($result)";
}

// String ops that READ heap through their operand. [Pure] is sound only because
// Eco strings are immutable after construction (every chars[]/byte write in
// StringOps.hpp targets a freshly allocated, not-yet-published `out` object) and
// SSA dominance already prevents motion above the operand's def. If a mutable
// string form (in-place builder) is ever added, revisit these traits FIRST.

def Eco_StringLengthOp : Eco_Op<"string.length", [Pure]> {
  let summary = "Logical UTF-16 length of a String (String.length)";
  let description = [{
    Reads `header.size`, which HEAP_025/HEAP_032 define as the logical UTF-16 unit
    count for ALL SIX String forms (Tag_String, Tag_StringRope, Tag_StringSlice,
    Tag_LargeStringHeader, Tag_StringUtf8View, Tag_StringUtf8Leaf) - so there is no
    per-tag dispatch. Any embedded constant (ptr_ind set) yields 0. Result is an
    unboxed Elm Int; the observable result is IDENTICAL to Elm_Kernel_String_length
    (elm-kernel-cpp/src/core/StringExports.cpp:18-27).

    ```mlir
    %len = eco.string.length %s
    ```
  }];
  let arguments = (ins Eco_Value:$str);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$str attr-dict";
}

def Eco_StringCodeUnitAtOp : Eco_Op<"string.code_unit_at", [Pure]> {
  let summary = "UTF-16 code unit at index (GC-LEAF-CALL to StringOps::charAt)";
  let description = [{
    Tag-dispatched over all six String forms; iterative over ropes (deep trees
    cannot blow the C stack). Allocation-free, so the lowered call is gc-leaf and
    callers need no rooting.

    OUT-OF-RANGE AND EMPTY YIELD 0, not a trap - this mirrors StringOps::charAt
    and is a caveat to document, never to "fix": consumers must bounds-check
    against `eco.string.length` first. Result is `i16` (Eco_Char); widening to
    Elm Int is the consumer's job via `eco.char.toInt`.

    ```mlir
    %c = eco.string.code_unit_at %s, %i
    ```
  }];
  let arguments = (ins Eco_Value:$str, Eco_Int:$index);
  let results = (outs Eco_Char:$result);
  let assemblyFormat = "$str `,` $index attr-dict";
}

def Eco_StringAppendOp : Eco_Op<"string.append"> {
  let summary = "Concatenate two Strings (a ++ b), typed";
  let description = [{
    Typed replacement for `Elm_Kernel_Utils_append` at `(String, String)` mono
    sites. Operands are boxed strings (REP_ABI_001: String crosses every ABI as
    `!eco.value`) and accept the FULL string-shape domain - leaf, UTF-8 view,
    slice and rope - because either side may be a view. Allocates a
    VARIABLE-size result (flat leaf below `string_flatten_limit`,
    `Tag_StringRope` above), so it is NOT fixed-size-groupable and is
    deliberately trait-free; RS4GC inserts the statepoint at the lowered call.

    ```mlir
    %s = eco.string.append %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

//===----------------------------------------------------------------------===//
// 4. Call and Closure Operations
//===----------------------------------------------------------------------===//

def Eco_CallOp : Eco_Op<"call", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>,
    DeclareOpInterfaceMethods<MemoryEffectsOpInterface>
]> {
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

    Purity channel (kernel-opt-12). The discardable unit attribute
    `eco.cse_safe` is stamped at emission for direct calls whose
    Compiler.GlobalOpt.KernelFacts row derives `droppable`
    (cseSafe && totality == Total). It licenses exactly two transforms:

      * MERGE two identical calls that are in the same dominance scope;
      * ERASE a call whose results are unused.

    It does NOT license speculation or motion (eco.call implements no
    ConditionallySpeculatable), and it is INVALID after EcoGCPrepare, which
    appends GC roots to the operand list and strips the attribute. A call
    WITHOUT the attribute reports conservative read+write on the default
    resource — identical in practice to having no effect interface at all.
    Never valid on an indirect call or a musttail call.
  }];

  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$operands,
    OptionalAttr<FlatSymbolRefAttr>:$callee,
    OptionalAttr<BoolAttr>:$musttail,
    OptionalAttr<I64Attr>:$remaining_arity  // For indirect calls
  );
  let results = (outs Variadic<Eco_AnyValue>:$results);

  let hasVerifier = 1;
}

def Eco_PapCreateOp : Eco_Op<"papCreate", [
    Pure,
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Create partial application closure";
  let description = [{
    Create a closure representing a partial application (PAP) of a function
    with some captured arguments. The remaining arity after creation is
    (arity - num_captured).

    Each captured slot occupies 2 bits of `unboxed_bitmap`: `00` = boxed
    HPointer, `01` = Int, `10` = Float, `11` = Char. Slot i's kind lives
    at bits [2i, 2i+1]. The 50-bit bitmap supports at most 25 typed
    captures (captures beyond that are stored boxed). The upper 2 bits of
    the 52-bit packed field hold per-closure capability flags
    (Closure::flags), not bitmap data.
    This is the source-of-truth; lowering trusts this value.

    For typed closure calling, closures with captures have:
    - `function`: References the generic clone (funcName$clo)
    - `_fast_evaluator`: References the fast clone (funcName$cap)
    - `_closure_kind`: Integer ID or "heterogeneous" (omit if unknown)

    Zero-capture closures have no _fast_evaluator or _closure_kind.

    Example:
    ```mlir
    // Partially apply `add` with first argument captured as i64
    %add_5 = eco.papCreate @add$clo(%five) {
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64,
      _fast_evaluator = @add$cap,
      _closure_kind = 42 : i64
    } : (i64) -> !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$captured,
    FlatSymbolRefAttr:$function,
    I64Attr:$arity,
    I64Attr:$num_captured,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap,
    OptionalAttr<FlatSymbolRefAttr>:$_fast_evaluator,
    OptionalAttr<AnyAttr>:$_closure_kind,
    DefaultValuedAttr<I8Attr, "0">:$_result_kind
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;
}

def Eco_PapCreateGroupOp : Eco_Op<"papCreateGroup", [
    Pure,
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Create a group of mutually-recursive PAP closures atomically";
  let description = [{
    Allocates N sibling closures in a single contiguous runtime region and
    wires cross-sibling captures after all HPointers are known. This
    eliminates the SSA-dominance problem of mutual let-rec closures (where
    sibling A needs sibling B's HPointer as a capture, but B is not yet
    defined at A's papCreate) without introducing a write barrier: all
    siblings are co-allocated in the same generation so there is no
    old->young pointer.

    Operand layout:
      [sibling0_captures..., sibling1_captures..., ...,
       siblingN-1_captures..., roots...]
    Per-sibling capture count is `capture_counts[i]`; the captures for
    sibling i live at operands[prefix_i .. prefix_i + capture_counts[i]).
    All trailing operands (after `sum(capture_counts)`) are GC live roots,
    consumed by the GCRootCarrier interface. `eco.gc_roots_count`
    tracks how many trailing operands are roots.

    Results: N `!eco.value` HPointers in sibling order.

    Attributes:
    - `functions`: ArrayAttr of FlatSymbolRefAttr, one per sibling,
      the $clo clone used by generic closure dispatch.
    - `fast_evaluators`: ArrayAttr of FlatSymbolRefAttr, one per sibling,
      the $cap clone used by typed closure dispatch. Group members all
      have captures (cross-edges count as captures), so every sibling
      has a fast evaluator.
    - `arities`: I64 ArrayAttr, one entry per sibling.
    - `num_captured`: I64 ArrayAttr, single source of truth for each
      sibling's Closure.n_values. Must satisfy
      `num_captured[i] == capture_counts[i] +
        count{(p,c,s) in cross_edges | c == i}`.
    - `unboxed_bitmaps`: I64 ArrayAttr of per-sibling unboxed_bitmap.
    - `capture_counts`: I64 ArrayAttr, non-sibling capture count per
      sibling, used to partition the operand list.
    - `cross_edges`: I64 ArrayAttr, flat triples of
      [producer, consumer, slot]. Cross-edge slots must be boxed
      (bit 2*slot of unboxed_bitmap[consumer] is zero).
    - `_operand_types`: optional ArrayAttr of TypeAttr, one per capture
      operand (before roots), mirroring the papCreate convention.
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$operands,
    ArrayAttr:$functions,
    ArrayAttr:$fast_evaluators,
    I64ArrayAttr:$arities,
    I64ArrayAttr:$num_captured,
    I64ArrayAttr:$unboxed_bitmaps,
    I64ArrayAttr:$capture_counts,
    I64ArrayAttr:$cross_edges,
    OptionalAttr<I64ArrayAttr>:$_result_kinds
  );
  let results = (outs Variadic<Eco_Value>:$closures);

  let hasVerifier = 1;
}

def Eco_PapExtendOp : Eco_Op<"papExtend", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Extend closure with more arguments (typed or generic apply)";
  let description = [{
    Extend an existing partial application (closure) with more arguments.
    Operates in two modes:

    **Typed mode** (remaining_arity present):
    Compile-time saturation check. If remaining_arity == newargs.size(), this
    is a saturated call that invokes the evaluator and returns the result.
    Otherwise, returns a new closure with additional captured arguments.
    CGEN_052 and CGEN_056 are enforced. Result type may be a typed ABI value.
    Typed closure calling attributes (_dispatch_mode, _fast_evaluator,
    _closure_kind) control lowering dispatch.

    **Generic mode** (remaining_arity absent):
    Runtime saturation check via the closure header's n_values/max_values.
    EcoToLLVM loads the header, computes remaining = max_values - n_values,
    and branches at runtime:
    - Under-saturated: returns new PAP (!eco.value)
    - Exactly saturated: calls evaluator, returns result
    - Over-saturated: saturates, then chains to result closure
    Result type may be !eco.value, or a primitive (i64/f64/i16) when Mono
    types the call as a primitive return — in that case the JIT lowers
    with the matching `desired_kind` and the runtime writes the primitive
    straight into the result slot. CGEN_052/CGEN_056 do not apply. Typed
    closure calling attributes are ignored.

    Each new-arg slot occupies 2 bits of `newargs_unboxed_bitmap`: `00` =
    boxed HPointer, `01` = Int, `10` = Float, `11` = Char. Slot i's kind
    lives at bits [2i, 2i+1]. At most 25 typed new-args fit in the
    resulting closure's 50-bit bitmap (the remaining 2 bits of the 52-bit
    field hold per-closure capability flags; see Closure::flags).
    This is the source-of-truth; lowering trusts this value.

    For typed closure calling (typed mode only):
    - `_closure_kind`: Propagated from source closure (int or "heterogeneous")
    - `_dispatch_mode`: How to lower this call ("fast", "closure", "unknown")
    - `_fast_evaluator`: Fast clone symbol (required when _dispatch_mode="fast")

    Examples:
    ```mlir
    // Typed mode: saturated call with known remaining arity
    %result = eco.papExtend %closure(%arg) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _dispatch_mode = "fast",
      _fast_evaluator = @add$cap
    } : !eco.value, (i64) -> i64

    // Generic mode: runtime saturation check, result always !eco.value
    %result = eco.papExtend %closure(%arg0, %arg1) {
      newargs_unboxed_bitmap = 0 : i64
    } : !eco.value, (!eco.value, !eco.value) -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Value:$closure,
    Variadic<Eco_AnyValue>:$newargs,
    OptionalAttr<I64Attr>:$remaining_arity,
    DefaultValuedAttr<I64Attr, "0">:$newargs_unboxed_bitmap,
    OptionalAttr<AnyAttr>:$_closure_kind,
    OptionalAttr<StrAttr>:$_dispatch_mode,
    OptionalAttr<FlatSymbolRefAttr>:$_fast_evaluator,
    DefaultValuedAttr<I8Attr, "0">:$_result_kind
  );
  let results = (outs Eco_AnyValue:$result);

  let hasVerifier = 1;
}

def Eco_ProjectClosureOp : Eco_Op<"project.closure", [Pure]> {
  let summary = "Project a captured value from a closure";
  let description = [{
    Load a captured value from a closure at the specified index.
    Used in the generic clone body to extract captures before
    calling the fast clone.

    The `index` attribute specifies which capture to load (0-indexed).
    The `is_unboxed` attribute indicates whether the capture is stored
    as an unboxed primitive.

    Operand may be either `!eco.value` (heap closure — existing closure
    lowering in `EcoToLLVMClosures.cpp`) or `!eco.closure_env<...>`
    (value-level env — handled by a small parallel pattern in
    `EcoToLLVMValueAgg.cpp` that emits `extractvalue` at the requested
    index). The heavy closure dispatch file is intentionally untouched
    in Phase 0.

    Example:
    ```mlir
    // Load the first capture (unboxed i64) from closure
    %cap0 = eco.project.closure %closure {
      index = 0 : i64,
      is_unboxed = true
    } : (!eco.value) -> i64

    // Load the second capture (boxed value) from closure
    %cap1 = eco.project.closure %closure {
      index = 1 : i64,
      is_unboxed = false
    } : (!eco.value) -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_ClosureOrEnv:$closure,
    I64Attr:$index,
    DefaultValuedAttr<BoolAttr, "false">:$is_unboxed
  );
  let results = (outs Eco_AnyValue:$result);

  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// 5. Allocation and GC Operations
//===----------------------------------------------------------------------===//

def Eco_AllocateOp : Eco_Op<"allocate", [
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Generic heap allocation";
  let description = [{
    Allocate a heap object of the specified size. This is a low-level
    operation typically introduced during lowering of eco.construct.

    The type attribute identifies the object type for GC purposes.
    If needs_root is true, the allocation is registered as a GC root
    during construction (for multi-field objects being initialized).

    The optional live_roots operands are GC roots that must be tracked
    across this allocation (populated by EcoGCPrepare).

    Example:
    ```mlir
    %obj = eco.allocate %size (%r0 : !eco.value) {
      type = @"Custom.MyType",
      needs_root = true
    } : (i64) -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_Int:$size,
    Variadic<Eco_Value>:$live_roots,
    FlatSymbolRefAttr:$type,
    BoolAttr:$needs_root
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$size (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($size) `->` type($result)";
}

def Eco_AllocateCtorOp : Eco_Op<"allocate_ctor", [
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Allocate constructor object";
  let description = [{
    Allocate space for a constructor object with the specified tag and
    field count. This is a specialized allocation for ADT constructors.

    - tag: constructor discriminant (maps to Custom.ctor field)
    - size: number of pointer-sized fields
    - scalar_bytes: additional bytes for unboxed scalar fields

    The optional live_roots operands are GC roots that must be tracked
    across this allocation (populated by EcoGCPrepare).

    Example:
    ```mlir
    %obj = eco.allocate_ctor(%r0 : !eco.value) {
      tag = 1 : i64,
      size = 2 : i64,
      scalar_bytes = 0 : i64
    } : !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_Value>:$live_roots,
    I64Attr:$tag,
    I64Attr:$size,
    I64Attr:$scalar_bytes
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "(`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($result)";
}

def Eco_AllocateStringOp : Eco_Op<"allocate_string", [
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Allocate string storage";
  let description = [{
    Allocate storage for a string of the specified length (in UTF-16 code
    units). The string content must be written separately after allocation.

    Representation: always allocates a flat `Tag_String` leaf. Runtime ops
    may later return slices (`Tag_StringSlice`) or ropes (`Tag_StringRope`)
    when transforming such leaves; allocate_string itself does not.

    The optional live_roots operands are GC roots that must be tracked
    across this allocation (populated by EcoGCPrepare).

    Example:
    ```mlir
    %str = eco.allocate_string(%r0 : !eco.value) {length = 100 : i64} : !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_Value>:$live_roots,
    I64Attr:$length
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "(`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($result)";
}

def Eco_AllocateClosureOp : Eco_Op<"allocate_closure", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Allocate closure object";
  let description = [{
    Allocate a closure object for the specified function with space for
    values. The `arity` specifies the total number of value slots (max_values),
    which should equal num_captured + num_remaining_args.

    The optional live_roots operands are GC roots that must be tracked
    across this allocation (populated by EcoGCPrepare).

    Example:
    ```mlir
    %closure = eco.allocate_closure(%r0, %r1 : !eco.value, !eco.value) {
      function = @my_func,
      arity = 3 : i64
    } : !eco.value
    ```
  }];

  let arguments = (ins
    Variadic<Eco_Value>:$live_roots,
    FlatSymbolRefAttr:$function,
    I64Attr:$arity
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "(`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($result)";
}

//===----------------------------------------------------------------------===//
// 6. Global State Operations
//===----------------------------------------------------------------------===//

def Eco_GlobalOp : Eco_Op<"global", [
    Symbol,
    DeclareOpInterfaceMethods<SymbolUserOpInterface>
]> {
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

def Eco_LoadGlobalOp : Eco_Op<"load_global", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>
]> {
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

def Eco_StoreGlobalOp : Eco_Op<"store_global", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>
]> {
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

def Eco_BoxOp : Eco_Op<"box", [Pure,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Box primitive value to eco.value";
  let description = [{
    Box an unboxed primitive value (i64, f64, i32, i1) into a heap-allocated
    eco.value. This allocates an ElmInt, ElmFloat, ElmChar, or Bool object.

    The optional live_roots operands are GC roots that must be tracked
    across this allocation (populated by EcoGCPrepare). For Bool boxing
    (i1), no allocation occurs and roots are unused.

    Example:
    ```mlir
    %boxed = eco.box %int_val (%r0 : !eco.value) : i64 -> !eco.value
    %boxed_float = eco.box %float_val : f64 -> !eco.value
    ```
  }];

  let arguments = (ins Eco_AnyValue:$value, Variadic<Eco_Value>:$live_roots);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$value (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($value) `->` type($result)";
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
    Creates an embedded constant value stored directly in the HPointer word
    without heap allocation. The kind is one of the Constant codes in Heap.hpp:
    False, True, or Empty (the unified nullary/empty constant — Unit, EmptyRec,
    Nil, Nothing, and the empty string all lower to Empty). See plan D3/D6.

    Lowering sets ptr_ind (bit 2) and the 2-bit constant field (bits 0-1); the
    ptr / enum_idx / padding fields are 0. So the words are:
    - False → 0x4
    - True  → 0x5
    - Empty → 0x6

    Example:
    ```mlir
    %false = eco.constant False : !eco.value
    %true  = eco.constant True  : !eco.value
    %empty = eco.constant Empty : !eco.value
    ```
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

// Char comparisons - all return i1 (Bool)
// Char is i16 representing a Unicode code point. Use unsigned predicates
// for ordering (eq/ne are signedness-agnostic).

def Eco_CharLtOp : Eco_Op<"char.lt", [Pure]> {
  let summary = "Char less-than comparison (unsigned)";
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CharLeOp : Eco_Op<"char.le", [Pure]> {
  let summary = "Char less-than-or-equal comparison (unsigned)";
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CharGtOp : Eco_Op<"char.gt", [Pure]> {
  let summary = "Char greater-than comparison (unsigned)";
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CharGeOp : Eco_Op<"char.ge", [Pure]> {
  let summary = "Char greater-than-or-equal comparison (unsigned)";
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CharEqOp : Eco_Op<"char.eq", [Pure, Commutative]> {
  let summary = "Char equality comparison";
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CharNeOp : Eco_Op<"char.ne", [Pure, Commutative]> {
  let summary = "Char not-equal comparison";
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

//===----------------------------------------------------------------------===//
// 9.5 Compare-to-Order Intrinsics
//===----------------------------------------------------------------------===//
//
// Direct primitive `compare` ops that return one of three pre-allocated Order
// singletons (LT/EQ/GT) instead of allocating a fresh Order Custom per call.
// These intrinsics are dispatched in MLIRGen for `Utils.compare` on monomorphic
// Int/Float/Char operands and replace the usual `eco.box`+kernel call shape.

def Eco_IntCmpOrderOp : Eco_Op<"int.cmp_order", [Pure]> {
  let summary = "Compare two ints; return Order singleton (LT/EQ/GT)";
  let description = [{
    Returns a pre-allocated Order Custom value as `!eco.value`.

    ```mlir
    %ord = eco.int.cmp_order %a, %b : i64
    ```
  }];
  let arguments = (ins Eco_Int:$lhs, Eco_Int:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_FloatCmpOrderOp : Eco_Op<"float.cmp_order", [Pure]> {
  let summary = "Compare two floats; return Order singleton (LT/EQ/GT)";
  let description = [{
    Returns a pre-allocated Order Custom value as `!eco.value`. Uses ordered
    `<` and `>`, so any NaN routes to EQ (matches Elm's Basics.compare).

    ```mlir
    %ord = eco.float.cmp_order %a, %b : f64
    ```
  }];
  let arguments = (ins Eco_Float:$lhs, Eco_Float:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_CharCmpOrderOp : Eco_Op<"char.cmp_order", [Pure]> {
  let summary = "Compare two chars; return Order singleton (LT/EQ/GT)";
  let description = [{
    Returns a pre-allocated Order Custom value as `!eco.value`. Char compares
    are unsigned (mirrors `eco.char.lt`).

    ```mlir
    %ord = eco.char.cmp_order %a, %b : i16
    ```
  }];
  let arguments = (ins Eco_Char:$lhs, Eco_Char:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

// String compare ops. Unlike the primitive cmp_order ops above (which read no
// heap), these read string CONTENTS through their operands. [Pure] — i.e.
// CSE/hoist/DCE-able — is sound only because Eco strings are immutable after
// construction: every chars[]/byte write in StringOps.hpp targets a freshly
// allocated, not-yet-published `out` object, and SSA dominance already prevents
// motion above the operands' defs. If a mutable string form (in-place builder)
// is ever added, revisit these traits FIRST.

def Eco_StringCmpOrderOp : Eco_Op<"string.cmp_order", [Pure]> {
  let summary = "Compare two strings; return Order singleton (LT/EQ/GT)";
  let description = [{
    Returns a pre-allocated Order Custom value as `!eco.value`. Operands are
    boxed strings (REP_ABI_001: String crosses every ABI as `!eco.value`).
    Empty is the embedded constant, ordered below every non-empty string.

    ```mlir
    %ord = eco.string.cmp_order %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
}

def Eco_StringCmp3Op : Eco_Op<"string.cmp3", [Pure]> {
  let summary = "Three-way compare of two strings; return an UNCLAMPED sign";
  let description = [{
    Returns a sign integer: negative if lhs < rhs, zero if equal, positive if
    lhs > rhs. The magnitude is UNCLAMPED (a code-unit difference, a memcmp
    result, or a size difference) — consumers must test `<0` / `==0` / `>0`
    and never compare against ±1.

    Produced by the compare-case rewrite (EcoCompareCaseRewrite) as the
    Order-free replacement for `eco.string.cmp_order` feeding a case on Order.

    ```mlir
    %sign = eco.string.cmp3 %a, %b : !eco.value -> i64
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs) `->` type($result)";
}

def Eco_ValueEqOp : Eco_Op<"value.eq", [Pure, Commutative]> {
  let summary = "Structural equality of two boxed values; returns i1";
  let description = [{
    Bit-exact replacement for a call to `Elm_Kernel_Utils_equal` followed by a
    boxed-Bool decode. Operands are boxed (REP_ABI_001), the result is the SSA
    i1 Bool.

    Lowers to the declare-only marker `__eco_value_eq`, which
    `expandValueEqFastPath` (EcoBackend.cpp) expands pre-RS4GC into:
      (1) word equality -> true (Utils.cpp's `if (a == b) return true` runs
          BEFORE the tag switch, so this never disagrees with the kernel --
          pointer-equal closures included);
      (2) either word has bit 2 (ptr_ind) set -> false, exactly
          equalRespectingConstants;
      (3) otherwise a gc-leaf call to Elm_Kernel_Utils_equal, decoded by
          comparing against the True word (0x5).

    `Pure` is sound for the same reason as eco.string.cmp_order: every Eco heap
    value is immutable after construction, and SSA dominance already prevents
    motion above the operands' defs. It ALSO required the tag-mismatch stderr
    trace to be gone -- kernel-opt-07 deleted it, which is what unblocked this
    trait; do not re-introduce an observable effect on the equality path.

    ```mlir
    %eq = eco.value.eq %a, %b : !eco.value
    ```
  }];
  let arguments = (ins Eco_Value:$lhs, Eco_Value:$rhs);
  let results = (outs Eco_Bool:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($lhs)";
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

//===----------------------------------------------------------------------===//
// 11. Value-level Aggregate Operations (Phase 0 escape-analysis plumbing)
//===----------------------------------------------------------------------===//
//
// `eco.make.*` ops produce SSA-only aggregate values; they are Pure, do
// NOT participate in GC root sets, and never carry heap-layout artifacts
// (`unboxed_bitmap`, `field_count`, `head_kind`).  Phase 1 escape analysis
// rewrites non-escaping `eco.construct.*` heap ops into these.
//
// `eco.to_heap` is the boxing op for the four data-aggregate shapes
// (tuple2/3, record, custom, cons); it allocates and is `GCRootCarrier`.
// Closure realisation goes through the dedicated `eco.make.closure` op
// (Q-A): it is the only `make.*` that allocates, the only one returning
// `!eco.value`, and the only one carrying a function symbol + arity.
//

//=== Value-level constructors ============================================//

def Eco_Tuple2MakeOp : Eco_Op<"make.tuple2", [Pure]> {
  let summary = "Create unboxed 2-tuple aggregate";
  let description = [{
    Build a value-level 2-tuple aggregate. Pure; never allocates; not a
    GCRootCarrier. Result is `!eco.tuple2<T0, T1>` with element types
    matching the operand SSA types.
  }];

  let arguments = (ins Eco_AnyValueOrAggregate:$a, Eco_AnyValueOrAggregate:$b);
  let results = (outs Eco_Tuple2:$result);
  // functional-type renders `(T0, T1) -> !eco.tuple2<T0, T1>` so the
  // dialect-qualified result type is preserved on round-trip.
  let assemblyFormat =
    "$a `,` $b attr-dict `:` functional-type(operands, $result)";

  let hasVerifier = 1;
}

def Eco_Tuple3MakeOp : Eco_Op<"make.tuple3", [Pure]> {
  let summary = "Create unboxed 3-tuple aggregate";

  let arguments = (ins Eco_AnyValueOrAggregate:$a, Eco_AnyValueOrAggregate:$b, Eco_AnyValueOrAggregate:$c);
  let results = (outs Eco_Tuple3:$result);
  let assemblyFormat =
    "$a `,` $b `,` $c attr-dict `:` functional-type(operands, $result)";

  let hasVerifier = 1;
}

def Eco_RecordMakeOp : Eco_Op<"make.record", [Pure]> {
  let summary = "Create unboxed record aggregate";
  let description = [{
    Build a value-level record aggregate. Field types are taken from the
    operand SSA types; the result type's parameter list must match.
  }];

  let arguments = (ins Variadic<Eco_AnyValueOrAggregate>:$fields);
  let results = (outs Eco_Record:$result);
  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";

  let hasVerifier = 1;
}

def Eco_CustomMakeOp : Eco_Op<"make.custom", [Pure]> {
  let summary = "Create unboxed custom ADT aggregate";
  let description = [{
    Build a value-level Custom ADT aggregate. The tag attribute is the
    structural constructor discriminant (Q-B: tag stays on the op, never
    on the type).
  }];

  let arguments = (ins
    Variadic<Eco_AnyValueOrAggregate>:$fields,
    I64Attr:$tag,
    OptionalAttr<StrAttr>:$constructor
  );
  let results = (outs Eco_Custom:$result);
  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";

  let hasVerifier = 1;
}

def Eco_ConsMakeOp : Eco_Op<"make.cons", [Pure]> {
  let summary = "Create unboxed cons cell aggregate";
  let description = [{
    Build a value-level cons cell. Tail is fixed to `!eco.value` (matches
    the existing heap list spine); fully unboxed list spines are out of
    scope for this phase. Naming asymmetry with the existing heap op
    `eco.construct.list` is deliberate (Q-D): heap-level list constructor
    vs value-level cons cell constructor.
  }];

  let arguments = (ins Eco_AnyValueOrAggregate:$head, Eco_Value:$tail);
  let results = (outs Eco_Cons:$result);
  let assemblyFormat =
    "$head `,` $tail attr-dict `:` functional-type(operands, $result)";

  let hasVerifier = 1;
}

def Eco_ClosureEnvMakeOp : Eco_Op<"make.closure_env", [Pure]> {
  let summary = "Create unboxed closure environment aggregate";
  let description = [{
    Build a value-level closure environment from a list of captured
    values. Captures only — no function symbol or arity. Heap closures
    are realised by `eco.make.closure`, which combines this env with
    a function/arity into `!eco.value`.
  }];

  let arguments = (ins Variadic<Eco_AnyValueOrAggregate>:$captures);
  let results = (outs Eco_ClosureEnv:$result);
  let assemblyFormat = "`(` $captures `)` attr-dict `:` functional-type($captures, $result)";

  let hasVerifier = 1;
}

//=== Heap/value boundary ops =============================================//

def Eco_ToHeapOp : Eco_Op<"to_heap", [
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Box a data aggregate into a heap object";
  let description = [{
    Allocate a heap object matching the input aggregate kind and store
    the aggregate's fields into it. Output layout is identical to what
    the corresponding `eco.construct.*` heap op produces.

    Accepts only data-aggregate inputs (tuple2/3, record, custom, cons).
    `!eco.closure_env` is rejected by the verifier (CGEN_029) — closure
    realisation goes through `eco.make.closure`.

    Heap-layout attributes (record/custom `unboxed_bitmap`, custom `tag`,
    cons `head_unboxed`/`head_kind`) live on this op, mirroring the
    corresponding `eco.construct.*` shapes (Q-B). Unspecified attributes
    default to zero / inferred from operand types at lowering time.

    Example:
    ```mlir
    %heap = eco.to_heap %t : !eco.tuple2<i64, !eco.value> -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_DataAggregate:$value,
    Variadic<Eco_Value>:$live_roots,

    // Heap-layout attributes (per kind; only the relevant ones are read
    // at lowering time):
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap,   // record/custom
    DefaultValuedAttr<I64Attr, "0">:$tag,              // custom
    DefaultValuedAttr<I64Attr, "0">:$head_kind,        // cons
    DefaultValuedAttr<BoolAttr, "false">:$head_unboxed // cons
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;

  let assemblyFormat =
    "$value (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict "
    "`:` functional-type($value, $result)";
}

def Eco_FromHeapOp : Eco_Op<"from_heap", [Pure]> {
  let summary = "Unbox a heap aggregate into a value-level aggregate";
  let description = [{
    Read a heap aggregate (tuple2/3, record, custom, cons) addressed by
    `!eco.value` and pack its fields into the corresponding aggregate
    SSA value (`!eco.tuple2<...>`, `!eco.record<...>`, etc.).

    `Pure` (no memory effect: the heap object is immutable in Elm).
    Mirror of `eco.to_heap` — together they form the entry/exit points
    of worker functions in Phase 3 cross-function specialisation.

    Accepts only data-aggregate result types; `!eco.closure_env` is
    rejected (CGEN_063) — closure environments come out of the
    eco_alloc_closure header path, not from a heap object.

    Example:
    ```mlir
    %t = eco.from_heap %hp : !eco.value -> !eco.tuple2<i64, i64>
    ```
  }];

  let arguments = (ins Eco_Value:$value);
  let results = (outs Eco_DataAggregate:$result);

  let hasVerifier = 1;

  let assemblyFormat =
    "$value attr-dict `:` functional-type($value, $result)";
}

def Eco_MakeClosureOp : Eco_Op<"make.closure", [
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>
]> {
  let summary = "Realise a heap closure from a value-level environment";
  let description = [{
    Allocate a heap closure for `function` with `arity` total value slots
    and populate its captures from the input `!eco.closure_env`. Layout
    matches what `eco.allocate_closure` + capture stores produces today.

    This is the **only** `eco.make.*` op that allocates; it is the only
    one that returns `!eco.value`; it is the only one that is a
    `GCRootCarrier` rather than `Pure`. Documented exception to the
    `make.*` family convention (Q-A-b, see CGEN_028).

    Example:
    ```mlir
    %clo = eco.make.closure @add$cap, %env(%r0 : !eco.value) {
      arity = 2 : i64
    } : !eco.closure_env<i64> -> !eco.value
    ```
  }];

  let arguments = (ins
    Eco_ClosureEnv:$env,
    Variadic<Eco_Value>:$live_roots,
    FlatSymbolRefAttr:$function,
    I64Attr:$arity
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;

  let assemblyFormat =
    "$function `,` $env (`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict "
    "`:` functional-type($env, $result)";
}
