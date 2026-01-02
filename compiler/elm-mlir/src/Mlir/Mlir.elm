module Mlir.Mlir exposing
    ( MlirAttr(..)
    , Dim(..), DenseF64, DenseF64Value(..), Visibility(..)
    , MlirType(..)
    , MlirOp
    , MlirBlock, MlirRegion(..), MlirModule
    , OpBuilderFns, OpBuilder, opBuilder, mlirOp
    )

{-| MLIR models the MLIR SSA compiler representation. This can be used to build MLIR code for further
processing by the MLIR tool-chain and development system.


# MLIR Model


## Atributes

@docs MlirAttr
@docs Dim, DenseF64, DenseF64Value, Visibility


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


{-| Attributes are constant, known-value pieces of metadata attached to operations and functions.
-}
type MlirAttr
    = StringAttr String
    | BoolAttr Bool
    | IntAttr (Maybe MlirType) Int
    | TypedFloatAttr Float MlirType
    | FloatAttr Float
    | TypeAttr MlirType
    | ArrayAttr (Maybe MlirType) (List MlirAttr)
    | DenseF64Attr { type_ : MlirType, payload : DenseF64 }
    | SymbolRefAttr String
    | VisibilityAttr Visibility
    | UnitAttr


{-| Function visibility attribute values.
-}
type Visibility
    = Public
    | Private
    | Nested


{-| Array dimensions.
-}
type Dim
    = Static Int
    | Dynamic


{-| Dense F64 values, such as tensors.
-}
type alias DenseF64 =
    { shape : List Dim
    , values : DenseF64Value
    }


{-| Dense F64 values, such as tensors.
-}
type DenseF64Value
    = Scalar Float
    | Tensor (List DenseF64Value)



-- Types


{-| MLIR uses an open type system, meaning there is no fixed, hardcoded list of all valid types.
Instead, types are defined within specific dialects, which are modular extensions to the core MLIR
framework.

A hard-coded set of common types is provided here.

-}
type MlirType
    = I1
    | I8
    | I16
    | I32
    | I64
    | F32
    | F64
    | Index
    | MemRef { dims : List Dim, elem : MlirType }
    | StructType (List MlirType)
    | NamedStruct String
    | FunctionType { inputs : List MlirType, results : List MlirType }
    | RankedTensor (List Dim) MlirType
    | UnrankedTensor MlirType



-- Operations


{-| A MLIR operation or instruction.
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


{-| A basic block.
-}
type alias MlirBlock =
    { args : List ( String, MlirType )
    , body : List MlirOp
    , terminator : MlirOp
    }


{-| A region, which is a sequence of basic blocks with scoping.
-}
type MlirRegion
    = MlirRegion
        { entry : MlirBlock
        , blocks : OrderedDict String MlirBlock
        }


{-| A module which is a list of MLIR operations, often functions with regions.
-}
type alias MlirModule =
    { body : List MlirOp
    , loc : Loc
    }



--=== Builders


unknownLoc : Loc
unknownLoc =
    Loc.unknown


{-| A set of builder functions for creation `MlirOp`s.
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


{-| An opaque builder representing a MlirOp under construction.
-}
type OpBuilder e
    = OpBuilder e MlirOp


{-| An implementation of the builder functions.
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


{-| Creates a builder for a named MlirOp with a generated id that is unique within a given environment.
This is designed for convenience of allowing an id generation function to be specified, and to pass
through a new environment (with a particular id consumed).

The remaining parameters can be filled in using the builder functions in OpBuilderFn.

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
