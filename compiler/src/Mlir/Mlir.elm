module Mlir.Mlir exposing
    ( MlirAttr(..)
    , Visibility(..)
    , MlirType(..)
    , MlirOp
    , MlirBlock, MlirRegion(..), MlirModule
    , OpBuilderFns, OpBuilder, opBuilder, mlirOp
    )

{-| The compiler's native back end produces an MLIR program, and this module is
the in-memory form that program takes between being generated and being written
out as text or as bytecode.

MLIR is a compiler framework whose programs are built from _operations_. An
operation has a name of the form `dialect.op`, where a _dialect_ is a named
family of operations and types, such as `func`, `arith` or the compiler's own
`eco`. It reads values, its _operands_, and defines new ones, its _results_. It
carries _attributes_, which are constant data such as a callee's name or an
integer flag, and it may contain _regions_ of nested code. A region is a list
of _blocks_, and a block is a straight run of operations that ends in a
_terminator_, the operation that says where control goes next. Values are in
SSA form: each is defined exactly once, by an operation's result or a block's
argument, and is referred to everywhere else by its name.

The model is generic. An operation is described by its name string and its
fields, not by a type of its own, so nothing here knows which operations exist
or checks that an operation's operands, results or attributes make sense for
it. The names of values and of blocks are plain strings. The attributes and
types are a fixed set, the ones the compiler uses, rather than all that MLIR
allows.

Most of the module is that model. The rest is the _op builder_: `mlirOp` starts
an operation and draws its `id` from an environment, the fields of `opBuilder`
fill it in, and `build` returns the operation with the environment left after
the `id` was drawn.


# MLIR Model


## Attributes

@docs MlirAttr
@docs Visibility


## Types

@docs MlirType


## Operations

@docs MlirOp


## Blocks, Regions and Modules

@docs MlirBlock, MlirRegion, MlirModule


# Builders

@docs OpBuilderFns, OpBuilder, opBuilder, mlirOp

-}

import Dict exposing (Dict)
import Mlir.Loc as Loc exposing (Loc)
import OrderedDict exposing (OrderedDict)



-- Attributes


{-| A constant value attached to an operation under a name in its `attrs`.

`StringAttr` holds text with its escape sequences, such as `\n`, still
written out rather than decoded. `Mlir.Pretty` and `Mlir.Bytecode.StringTable`
each convert them for their own output, and not in the same way. Nothing here
checks that the text is in that form.

`BoolAttr` holds `true` or `false`.

`IntAttr` carries the type the integer is given, or `Nothing` for an integer
written without one. `TypedFloatAttr` always carries its type.

`TypeAttr` is a type used as a value.

`ArrayAttr` is a list of attributes. With `Just t` it is a dense array of
elements of type `t`, and its elements should then all be untyped `IntAttr`s
(`IntAttr Nothing`). The bytecode encoder in `Mlir.Bytecode.AttrType` keeps
the integer of each `IntAttr` element and drops any other element, and
`Mlir.Pretty` prints a typed `IntAttr` element with its type. With `Nothing`
it is an ordinary list whose elements may be of any kind, mixed.

`SymbolRefAttr` refers to a named symbol, such as a function, by its name
without MLIR's leading `@`.

`VisibilityAttr` gives a symbol's visibility.

`UnitAttr` carries no value; its presence under a name is the whole of what it
says.

-}
type MlirAttr
    = StringAttr String
    | BoolAttr Bool
    | IntAttr (Maybe MlirType) Int
    | TypedFloatAttr Float MlirType
    | TypeAttr MlirType
    | ArrayAttr (Maybe MlirType) (List MlirAttr)
    | SymbolRefAttr String
    | VisibilityAttr Visibility
    | UnitAttr


{-| The visibility a `VisibilityAttr` can give a symbol. `Private` is the only
one modelled.
-}
type Visibility
    = Private



-- Types


{-| The type of an SSA value, or of an attribute's contents.

MLIR has no fixed list of types: each dialect may define its own. This is the
handful of built-in types the compiler uses, plus a way to name any dialect's
type.

`I1` to `I64` are integers of that many bits, and `F64` is a 64-bit float.

`NamedStruct` names a type defined by a dialect, in full and without MLIR's
leading `!`, such as `eco.value`. The part before the first `.` is the
dialect. The type need not be a struct.

`FunctionType` is the type of a function, from its input types to its result
types.

-}
type MlirType
    = I1
    | I8
    | I16
    | I32
    | I64
    | F64
    | NamedStruct String
    | FunctionType { inputs : List MlirType, results : List MlirType }



-- Operations


{-| One MLIR operation.

`name` is the full `dialect.op` name. `id` is a name for the operation, which
`mlirOp` takes from its `idFn`. Neither `Mlir.Pretty` nor the bytecode
encoders read it.

`operands` are the names of the SSA values the operation reads, and `results`
the names and types of those it defines. `operands` holds names only; an
operand's type is the one given where the value was defined.

`isTerminator` marks an operation that ends a block. `successors` name, by
their labels, the blocks a terminator may pass control to. `Mlir.Pretty`
prints them as given, so for text output each must carry MLIR's leading `^`;
the bytecode encoder accepts a label with or without it.

-}
type alias MlirOp =
    { name : String
    , id : String
    , operands : List String
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    , loc : Loc
    , successors : List String
    }



-- Blocks, Regions and Modules


{-| A block: arguments, a run of operations, and the terminator that ends it.

`args` are the SSA values the block defines on entry, as names and types.

`terminator` is the operation that ends the block. `body` may also hold
operations whose `isTerminator` is set; `Mlir.Pretty` and
`Mlir.Bytecode.IrSection` skip those and write only `terminator` at the end.

-}
type alias MlirBlock =
    { args : List ( String, MlirType )
    , body : List MlirOp
    , terminator : MlirOp
    }


{-| A region of nested code inside an operation: an entry block, where control
enters, followed by any further blocks.

The further blocks are kept in `blocks` under their labels, in the order they
were inserted, and those labels are what `successors` refer to. The entry block
has no label here; `Mlir.Pretty` and `Mlir.Bytecode.IrSection` both call it
`bb0`, so no block in `blocks` should be labelled `bb0`.

-}
type MlirRegion
    = MlirRegion
        { entry : MlirBlock
        , blocks : OrderedDict String MlirBlock
        }


{-| A whole MLIR program: its top-level operations, such as function
definitions, in order, and a location for the module itself.
-}
type alias MlirModule =
    { body : List MlirOp
    , loc : Loc
    }



--=== Builders


{-| The location an operation started by `mlirOp` has until `withLoc` replaces
it, `Mlir.Loc.unknown`.
-}
unknownLoc : Loc
unknownLoc =
    Loc.unknown


{-| The functions of the op builder, as a record so that they are reached
through the one value `opBuilder`.

Each `with...` field, and `isTerminator`, replaces the field of the operation
it names; none adds to what is already there, so a second `withAttrs` discards
the attributes the first one set. `build` finishes the operation and returns it
with the environment carried in the builder.

-}
type alias OpBuilderFns e =
    { withOperands : List String -> OpBuilder e -> OpBuilder e
    , withResults : List ( String, MlirType ) -> OpBuilder e -> OpBuilder e
    , withAttrs : Dict String MlirAttr -> OpBuilder e -> OpBuilder e
    , withRegions : List MlirRegion -> OpBuilder e -> OpBuilder e
    , isTerminator : Bool -> OpBuilder e -> OpBuilder e
    , withLoc : Loc -> OpBuilder e -> OpBuilder e
    , withSuccessors : List String -> OpBuilder e -> OpBuilder e
    , build : OpBuilder e -> ( e, MlirOp )
    }


{-| An operation under construction, together with the environment that was
left after its `id` was drawn.

The only way to get one is `mlirOp`. The fields of `opBuilder` fill in the
operation, and `build` gives back the operation and the environment.

-}
type OpBuilder e
    = OpBuilder e MlirOp


{-| The op builder's functions, as `OpBuilderFns` describes them.
-}
opBuilder : OpBuilderFns e
opBuilder =
    { withOperands =
        \operands (OpBuilder e op) ->
            OpBuilder e { op | operands = operands }
    , withResults =
        \results (OpBuilder e op) ->
            OpBuilder e { op | results = results }
    , withAttrs =
        \attrs (OpBuilder e op) ->
            OpBuilder e { op | attrs = attrs }
    , withRegions =
        \regions (OpBuilder e op) ->
            OpBuilder e { op | regions = regions }
    , isTerminator =
        \flag (OpBuilder e op) ->
            OpBuilder e { op | isTerminator = flag }
    , withLoc =
        \loc (OpBuilder e op) ->
            OpBuilder e { op | loc = loc }
    , withSuccessors =
        \succs (OpBuilder e op) ->
            OpBuilder e { op | successors = succs }
    , build = \(OpBuilder e op) -> ( e, op )
    }


{-| Starts building an operation called `name`, taking its `id` and the next
environment from `idFn env`.

The operation starts with no operands, results, attributes, regions or
successors, is not a terminator, and has the unknown location. Whether the `id`
is unique depends only on `idFn`.

-}
mlirOp : (e -> ( e, String )) -> e -> String -> OpBuilder e
mlirOp idFn env name =
    let
        ( nextEnv, id ) =
            idFn env
    in
    OpBuilder
        nextEnv
        { name = name
        , id = id
        , operands = []
        , results = []
        , attrs = Dict.empty
        , regions = []
        , isTerminator = False
        , loc = unknownLoc
        , successors = []
        }
