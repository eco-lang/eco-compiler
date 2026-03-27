module Compiler.AST.TypedOptimized exposing
    ( Expr(..), Global(..), Annotations, Meta
    , Def(..), Destructor(..), Path(..)
    , ContainerHint(..)
    , Decider(..), Choice(..)
    , GlobalGraph(..), LocalGraph(..), LocalGraphData, Node(..), Main(..), EffectsType(..)
    , emptyGlobalGraph
    , compareGlobal, toComparableGlobal, toKernelGlobal
    , typeOf, metaOf, tvarOf
    , globalGraphEncoder, globalGraphDecoder, localGraphEncoder, localGraphDecoder
    )

{-| TypedOptimized AST - like Optimized but preserves type information.

This IR is used for backends that need type information for code generation,
such as the MLIR backend which performs monomorphization.

The key difference from Optimized:

  - Every Expr carries a type annotation (Can.Type)
  - Nodes carry type information for definitions
  - LocalGraph includes the full annotations dictionary


# Core Types

@docs Expr, Global, Annotations, Meta


# Definitions and Destructuring

@docs Def, Destructor, Path


# Container Hints

@docs ContainerHint


# Pattern Matching

@docs Decider, Choice


# Dependency Graphs

@docs GlobalGraph, LocalGraph, LocalGraphData, Node, Main, EffectsType


# Graph Operations

@docs emptyGlobalGraph


# Global Reference Utilities

@docs compareGlobal, toComparableGlobal, toKernelGlobal


# Type Extraction

@docs typeOf, metaOf, tvarOf


# Serialization

@docs globalGraphEncoder, globalGraphDecoder, localGraphEncoder, localGraphDecoder

-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Kernel as K
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set exposing (EverySet)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== TYPE ALIASES ======


{-| Annotations dictionary - maps definition names to their type schemes
-}
type alias Annotations =
    Dict Name Can.Annotation



-- ====== META ======


{-| Metadata carried with each expression: the canonical type and an optional solver variable.
The `tvar` field preserves the solver's union-find variable for MonoDirect monomorphization.
-}
type alias Meta =
    { tipe : Can.Type
    , tvar : Maybe IO.Variable
    }



-- ====== EXPRESSIONS ======
-- Every expression variant carries its Meta as the LAST argument


{-| Typed optimized expression. Each variant carries its Meta (type + solver var) as the last argument.
-}
type Expr
    = Bool A.Region Bool Meta
    | Chr A.Region String Meta
    | Str A.Region String Meta
    | Int A.Region Int Meta
    | Float A.Region Float Meta
    | VarLocal Name Meta
    | TrackedVarLocal A.Region Name Meta
    | VarGlobal A.Region Global Meta
    | VarEnum A.Region Global Index.ZeroBased Meta
    | VarBox A.Region Global Meta
    | VarCycle A.Region IO.Canonical Name Meta
    | VarDebug A.Region Name IO.Canonical (Maybe Name) Meta
    | VarKernel A.Region Name Name Name Meta
    | List A.Region (List Expr) Meta
    | Function (List ( Name, Can.Type )) Expr Meta -- params with types, body, function type
    | TrackedFunction (List ( A.Located Name, Can.Type )) Expr Meta
    | Call A.Region Expr (List Expr) Meta
    | TailCall Name (List ( Name, Expr )) Meta
    | If (List ( Expr, Expr )) Expr Meta
    | Let Def Expr Meta
    | Destruct Destructor Expr Meta
    | Case Name Name (Decider Choice) (List ( Int, Expr )) Meta
    | Accessor A.Region Name Meta
    | Access Expr A.Region Name Meta
    | Update A.Region Expr (Data.Map.Dict String (A.Located Name) Expr) Meta
    | Record (Dict Name Expr) Meta
    | TrackedRecord A.Region (Data.Map.Dict String (A.Located Name) Expr) Meta
    | Unit Meta
    | Tuple A.Region Expr Expr (List Expr) Meta
    | Shader Shader.Source (EverySet String Name) (EverySet String Name) Meta


{-| Extract the type annotation from any expression.
-}
typeOf : Expr -> Can.Type
typeOf expr =
    (metaOf expr).tipe


{-| Extract the Meta (type + solver var) from any expression.
-}
metaOf : Expr -> Meta
metaOf expr =
    case expr of
        Bool _ _ meta ->
            meta

        Chr _ _ meta ->
            meta

        Str _ _ meta ->
            meta

        Int _ _ meta ->
            meta

        Float _ _ meta ->
            meta

        VarLocal _ meta ->
            meta

        TrackedVarLocal _ _ meta ->
            meta

        VarGlobal _ _ meta ->
            meta

        VarEnum _ _ _ meta ->
            meta

        VarBox _ _ meta ->
            meta

        VarCycle _ _ _ meta ->
            meta

        VarDebug _ _ _ _ meta ->
            meta

        VarKernel _ _ _ _ meta ->
            meta

        List _ _ meta ->
            meta

        Function _ _ meta ->
            meta

        TrackedFunction _ _ meta ->
            meta

        Call _ _ _ meta ->
            meta

        TailCall _ _ meta ->
            meta

        If _ _ meta ->
            meta

        Let _ _ meta ->
            meta

        Destruct _ _ meta ->
            meta

        Case _ _ _ _ meta ->
            meta

        Accessor _ _ meta ->
            meta

        Access _ _ _ meta ->
            meta

        Update _ _ _ meta ->
            meta

        Record _ meta ->
            meta

        TrackedRecord _ _ meta ->
            meta

        Unit meta ->
            meta

        Tuple _ _ _ _ meta ->
            meta

        Shader _ _ _ meta ->
            meta


{-| Extract the solver variable from any expression (if available).
-}
tvarOf : Expr -> Maybe IO.Variable
tvarOf expr =
    (metaOf expr).tvar


{-| A reference to a top-level definition in a module.
-}
type Global
    = Global IO.Canonical Name


{-| Compare two global references for ordering.
-}
compareGlobal : Global -> Global -> Order
compareGlobal (Global home1 name1) (Global home2 name2) =
    case compare name1 name2 of
        LT ->
            LT

        EQ ->
            ModuleName.compareCanonical home1 home2

        GT ->
            GT


{-| Convert a global reference to a comparable key for use in dictionaries.
-}
toComparableGlobal : Global -> List String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ [ name ]


{-| Create a global reference to a kernel function.
-}
toKernelGlobal : Name.Name -> Global
toKernelGlobal shortName =
    Global (IO.Canonical Pkg.kernel shortName) Name.dollar



-- ====== DEFINITIONS ======


{-| A local definition, either a simple value or a tail-recursive function.
-}
type Def
    = Def A.Region Name Expr Can.Type -- name, body, type of the definition
    | TailDef A.Region Name (List ( A.Located Name, Can.Type )) Expr Can.Type (Maybe IO.Variable) -- name, typed args, body, type of the definition, tvar


{-| Destructuring pattern that extracts a value from a data structure.
-}
type Destructor
    = Destructor Name Path Meta -- name, path, meta (type + optional tvar)



-- Note: Path includes container hints for type-specific projection operations


{-| Indicates what type of container an Index navigates into.
This is used to generate type-specific projection operations in MLIR codegen.
-}
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom Name -- Constructor name for layout lookup


{-| A path describing how to navigate into a data structure for destructuring.
Index includes a ContainerHint to enable type-specific projection operations.
-}
type Path
    = Index Index.ZeroBased ContainerHint Path
    | ArrayIndex Int Path
    | Field Name Path
    | Unbox Path
    | Root Name



-- ====== BRANCHING ======


{-| A decision tree for pattern matching, optimized from the canonical AST.
-}
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)


{-| Represents the action taken when a pattern match succeeds.
-}
type Choice
    = Inline Expr
    | Jump Int



-- ====== OBJECT GRAPH ======


{-| A graph of all top-level definitions across multiple modules.
-}
type GlobalGraph
    = GlobalGraph (Data.Map.Dict (List String) Global Node) (Dict Name Int) Annotations



-- Include annotations for the whole graph


{-| Data structure for a single module's dependency graph.
-}
type alias LocalGraphData =
    { main : Maybe Main
    , nodes : Data.Map.Dict (List String) Global Node
    , fields : Dict Name Int
    , annotations : Annotations
    }


{-| A graph of top-level definitions for a single module.
-}
type LocalGraph
    = LocalGraph LocalGraphData



-- Include annotations for this module


{-| Information about the main entry point of an Elm program.
-}
type Main
    = Static
    | Dynamic Can.Type Expr


{-| A node in the dependency graph representing a top-level definition.
-}
type Node
    = Define Expr (EverySet (List String) Global) Meta -- body, deps, meta
    | TrackedDefine A.Region Expr (EverySet (List String) Global) Meta
    | Ctor Index.ZeroBased Int Can.Type -- index, arity, constructor type
    | Enum Index.ZeroBased Can.Type
    | Box Can.Type
    | Link Global
    | Cycle (List Name) (List ( Name, Expr )) (List Def) (EverySet (List String) Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet (List String) Global)
    | PortIncoming Expr (EverySet (List String) Global) Meta -- decoder expr, deps, port meta
    | PortOutgoing Expr (EverySet (List String) Global) Meta -- encoder expr, deps, port meta


{-| The type of effects manager (commands, subscriptions, or both).
-}
type EffectsType
    = Cmd
    | Sub
    | Fx



-- ====== GRAPHS ======


{-| Create an empty global graph (alias for `empty`).
-}
emptyGlobalGraph : GlobalGraph
emptyGlobalGraph =
    GlobalGraph Data.Map.empty Dict.empty Dict.empty



-- ====== ENCODERS and DECODERS ======


{-| Encode a global graph to binary format.
-}
globalGraphEncoder : GlobalGraph -> Bytes.Encode.Encoder
globalGraphEncoder (GlobalGraph nodes fields annotations) =
    Bytes.Encode.sequence
        [ BE.assocListDict compareGlobal globalEncoder nodeEncoder nodes
        , BE.stdDict BE.string BE.int fields
        , BE.stdDict BE.string Can.annotationEncoder annotations
        ]


{-| Decode a global graph from binary format.
-}
globalGraphDecoder : Bytes.Decode.Decoder GlobalGraph
globalGraphDecoder =
    Bytes.Decode.map3 GlobalGraph
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.stdDict BD.string BD.int)
        (BD.stdDict BD.string Can.annotationDecoder)


{-| Encode a local graph to binary format.
-}
localGraphEncoder : LocalGraph -> Bytes.Encode.Encoder
localGraphEncoder (LocalGraph data) =
    Bytes.Encode.sequence
        [ BE.maybe mainEncoder data.main
        , BE.assocListDict compareGlobal globalEncoder nodeEncoder data.nodes
        , BE.stdDict BE.string BE.int data.fields
        , BE.stdDict BE.string Can.annotationEncoder data.annotations
        ]


{-| Decode a local graph from binary format.
-}
localGraphDecoder : Bytes.Decode.Decoder LocalGraph
localGraphDecoder =
    Bytes.Decode.map4
        (\main nodes fields annotations ->
            LocalGraph { main = main, nodes = nodes, fields = fields, annotations = annotations }
        )
        (BD.maybe mainDecoder)
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.stdDict BD.string BD.int)
        (BD.stdDict BD.string Can.annotationDecoder)


mainEncoder : Main -> Bytes.Encode.Encoder
mainEncoder main_ =
    case main_ of
        Static ->
            Bytes.Encode.unsignedInt8 0

        Dynamic msgType decoder ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Can.typeEncoder msgType
                , exprEncoder decoder
                ]


mainDecoder : Bytes.Decode.Decoder Main
mainDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Static

                    1 ->
                        Bytes.Decode.map2 Dynamic
                            Can.typeDecoder
                            exprDecoder

                    _ ->
                        Bytes.Decode.fail
            )


globalEncoder : Global -> Bytes.Encode.Encoder
globalEncoder (Global home name) =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoder home
        , BE.string name
        ]


globalDecoder : Bytes.Decode.Decoder Global
globalDecoder =
    Bytes.Decode.map2 Global
        ModuleName.canonicalDecoder
        BD.string


metaEncoder : Meta -> Bytes.Encode.Encoder
metaEncoder meta =
    Can.typeEncoder meta.tipe


metaDecoder : Bytes.Decode.Decoder Meta
metaDecoder =
    Bytes.Decode.map (\t -> { tipe = t, tvar = Nothing }) Can.typeDecoder


nodeEncoder : Node -> Bytes.Encode.Encoder
nodeEncoder node =
    case node of
        Define expr deps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoder expr
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder meta.tipe
                ]

        TrackedDefine region expr deps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , exprEncoder expr
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder meta.tipe
                ]

        Ctor index arity tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoder index
                , BE.int arity
                , Can.typeEncoder tipe
                ]

        Enum index tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Index.zeroBasedEncoder index
                , Can.typeEncoder tipe
                ]

        Box tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , Can.typeEncoder tipe
                ]

        Link linkedGlobal ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , globalEncoder linkedGlobal
                ]

        Cycle names values functions deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.list BE.string names
                , BE.list (BE.jsonPair BE.string exprEncoder) values
                , BE.list defEncoder functions
                , BE.everySet compareGlobal globalEncoder deps
                ]

        Manager effectsType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , effectsTypeEncoder effectsType
                ]

        Kernel chunks deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.list K.chunkEncoder chunks
                , BE.everySet compareGlobal globalEncoder deps
                ]

        PortIncoming decoder deps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , exprEncoder decoder
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder meta.tipe
                ]

        PortOutgoing encoder deps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoder encoder
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder meta.tipe
                ]


nodeDecoder : Bytes.Decode.Decoder Node
nodeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Define
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            metaDecoder

                    1 ->
                        Bytes.Decode.map4 TrackedDefine
                            A.regionDecoder
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            metaDecoder

                    3 ->
                        Bytes.Decode.map3 Ctor
                            Index.zeroBasedDecoder
                            BD.int
                            Can.typeDecoder

                    4 ->
                        Bytes.Decode.map2 Enum
                            Index.zeroBasedDecoder
                            Can.typeDecoder

                    5 ->
                        Bytes.Decode.map Box Can.typeDecoder

                    6 ->
                        Bytes.Decode.map Link globalDecoder

                    7 ->
                        Bytes.Decode.map4 Cycle
                            (BD.list BD.string)
                            (BD.list (BD.jsonPair BD.string exprDecoder))
                            (BD.list defDecoder)
                            (BD.everySet toComparableGlobal globalDecoder)

                    8 ->
                        Bytes.Decode.map Manager effectsTypeDecoder

                    9 ->
                        Bytes.Decode.map2 Kernel
                            (BD.list K.chunkDecoder)
                            (BD.everySet toComparableGlobal globalDecoder)

                    10 ->
                        Bytes.Decode.map3 PortIncoming
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            metaDecoder

                    11 ->
                        Bytes.Decode.map3 PortOutgoing
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            metaDecoder

                    _ ->
                        Bytes.Decode.fail
            )


typedLocatedNameEncoder : ( A.Located Name, Can.Type ) -> Bytes.Encode.Encoder
typedLocatedNameEncoder ( locName, tipe ) =
    Bytes.Encode.sequence
        [ A.locatedEncoder BE.string locName
        , Can.typeEncoder tipe
        ]


typedLocatedNameDecoder : Bytes.Decode.Decoder ( A.Located Name, Can.Type )
typedLocatedNameDecoder =
    Bytes.Decode.map2 Tuple.pair
        (A.locatedDecoder BD.string)
        Can.typeDecoder


typedNameEncoder : ( Name, Can.Type ) -> Bytes.Encode.Encoder
typedNameEncoder ( name, tipe ) =
    Bytes.Encode.sequence
        [ BE.string name
        , Can.typeEncoder tipe
        ]


typedNameDecoder : Bytes.Decode.Decoder ( Name, Can.Type )
typedNameDecoder =
    Bytes.Decode.map2 Tuple.pair
        BD.string
        Can.typeDecoder


exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder expr =
    case expr of
        Bool region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.bool value
                , Can.typeEncoder meta.tipe
                ]

        Chr region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string value
                , Can.typeEncoder meta.tipe
                ]

        Str region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string value
                , Can.typeEncoder meta.tipe
                ]

        Int region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoder region
                , BE.int value
                , Can.typeEncoder meta.tipe
                ]

        Float region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , A.regionEncoder region
                , BE.float value
                , Can.typeEncoder meta.tipe
                ]

        VarLocal value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.string value
                , Can.typeEncoder meta.tipe
                ]

        TrackedVarLocal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoder region
                , BE.string value
                , Can.typeEncoder meta.tipe
                ]

        VarGlobal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoder region
                , globalEncoder value
                , Can.typeEncoder meta.tipe
                ]

        VarEnum region global index meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , A.regionEncoder region
                , globalEncoder global
                , Index.zeroBasedEncoder index
                , Can.typeEncoder meta.tipe
                ]

        VarBox region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoder region
                , globalEncoder value
                , Can.typeEncoder meta.tipe
                ]

        VarCycle region home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , A.regionEncoder region
                , ModuleName.canonicalEncoder home
                , BE.string name
                , Can.typeEncoder meta.tipe
                ]

        VarDebug region name home unhandledValueName meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , A.regionEncoder region
                , BE.string name
                , ModuleName.canonicalEncoder home
                , BE.maybe BE.string unhandledValueName
                , Can.typeEncoder meta.tipe
                ]

        VarKernel region kernelPrefix home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , A.regionEncoder region
                , BE.string kernelPrefix
                , BE.string home
                , BE.string name
                , Can.typeEncoder meta.tipe
                ]

        List region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , A.regionEncoder region
                , BE.list exprEncoder value
                , Can.typeEncoder meta.tipe
                ]

        Function args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list typedNameEncoder args
                , exprEncoder body
                , Can.typeEncoder meta.tipe
                ]

        TrackedFunction args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.list typedLocatedNameEncoder args
                , exprEncoder body
                , Can.typeEncoder meta.tipe
                ]

        Call region func args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , A.regionEncoder region
                , exprEncoder func
                , BE.list exprEncoder args
                , Can.typeEncoder meta.tipe
                ]

        TailCall name args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , BE.string name
                , BE.list (BE.jsonPair BE.string exprEncoder) args
                , Can.typeEncoder meta.tipe
                ]

        If branches final meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list (BE.jsonPair exprEncoder exprEncoder) branches
                , exprEncoder final
                , Can.typeEncoder meta.tipe
                ]

        Let def body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , defEncoder def
                , exprEncoder body
                , Can.typeEncoder meta.tipe
                ]

        Destruct destructor body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , destructorEncoder destructor
                , exprEncoder body
                , Can.typeEncoder meta.tipe
                ]

        Case label root decider jumps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , BE.string label
                , BE.string root
                , deciderEncoder choiceEncoder decider
                , BE.list (BE.jsonPair BE.int exprEncoder) jumps
                , Can.typeEncoder meta.tipe
                ]

        Accessor region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , A.regionEncoder region
                , BE.string field
                , Can.typeEncoder meta.tipe
                ]

        Access record region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoder record
                , A.regionEncoder region
                , BE.string field
                , Can.typeEncoder meta.tipe
                ]

        Update region record fields meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , A.regionEncoder region
                , exprEncoder record
                , BE.assocListDict A.compareLocated (A.locatedEncoder BE.string) exprEncoder fields
                , Can.typeEncoder meta.tipe
                ]

        Record value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 25
                , BE.stdDict BE.string exprEncoder value
                , Can.typeEncoder meta.tipe
                ]

        TrackedRecord region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , A.regionEncoder region
                , BE.assocListDict A.compareLocated (A.locatedEncoder BE.string) exprEncoder value
                , Can.typeEncoder meta.tipe
                ]

        Unit meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 27
                , Can.typeEncoder meta.tipe
                ]

        Tuple region a b cs meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 28
                , A.regionEncoder region
                , exprEncoder a
                , exprEncoder b
                , BE.list exprEncoder cs
                , Can.typeEncoder meta.tipe
                ]

        Shader src attributes uniforms meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 29
                , Shader.sourceEncoder src
                , BE.everySet compare BE.string attributes
                , BE.everySet compare BE.string uniforms
                , Can.typeEncoder meta.tipe
                ]


exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Bool
                            A.regionDecoder
                            BD.bool
                            metaDecoder

                    1 ->
                        Bytes.Decode.map3 Chr
                            A.regionDecoder
                            BD.string
                            metaDecoder

                    2 ->
                        Bytes.Decode.map3 Str
                            A.regionDecoder
                            BD.string
                            metaDecoder

                    3 ->
                        Bytes.Decode.map3 Int
                            A.regionDecoder
                            BD.int
                            metaDecoder

                    4 ->
                        Bytes.Decode.map3 Float
                            A.regionDecoder
                            BD.float
                            metaDecoder

                    5 ->
                        Bytes.Decode.map2 VarLocal
                            BD.string
                            metaDecoder

                    6 ->
                        Bytes.Decode.map3 TrackedVarLocal
                            A.regionDecoder
                            BD.string
                            metaDecoder

                    7 ->
                        Bytes.Decode.map3 VarGlobal
                            A.regionDecoder
                            globalDecoder
                            metaDecoder

                    8 ->
                        Bytes.Decode.map4 VarEnum
                            A.regionDecoder
                            globalDecoder
                            Index.zeroBasedDecoder
                            metaDecoder

                    9 ->
                        Bytes.Decode.map3 VarBox
                            A.regionDecoder
                            globalDecoder
                            metaDecoder

                    10 ->
                        Bytes.Decode.map4 VarCycle
                            A.regionDecoder
                            ModuleName.canonicalDecoder
                            BD.string
                            metaDecoder

                    11 ->
                        Bytes.Decode.map5 VarDebug
                            A.regionDecoder
                            BD.string
                            ModuleName.canonicalDecoder
                            (BD.maybe BD.string)
                            metaDecoder

                    12 ->
                        Bytes.Decode.map5 VarKernel
                            A.regionDecoder
                            BD.string
                            BD.string
                            BD.string
                            metaDecoder

                    13 ->
                        Bytes.Decode.map3 List
                            A.regionDecoder
                            (BD.list exprDecoder)
                            metaDecoder

                    14 ->
                        Bytes.Decode.map3 Function
                            (BD.list typedNameDecoder)
                            exprDecoder
                            metaDecoder

                    15 ->
                        Bytes.Decode.map3 TrackedFunction
                            (BD.list typedLocatedNameDecoder)
                            exprDecoder
                            metaDecoder

                    16 ->
                        Bytes.Decode.map4 Call
                            A.regionDecoder
                            exprDecoder
                            (BD.list exprDecoder)
                            metaDecoder

                    17 ->
                        Bytes.Decode.map3 TailCall
                            BD.string
                            (BD.list (BD.jsonPair BD.string exprDecoder))
                            metaDecoder

                    18 ->
                        Bytes.Decode.map3 If
                            (BD.list (BD.jsonPair exprDecoder exprDecoder))
                            exprDecoder
                            metaDecoder

                    19 ->
                        Bytes.Decode.map3 Let
                            defDecoder
                            exprDecoder
                            metaDecoder

                    20 ->
                        Bytes.Decode.map3 Destruct
                            destructorDecoder
                            exprDecoder
                            metaDecoder

                    21 ->
                        Bytes.Decode.map5 Case
                            BD.string
                            BD.string
                            (deciderDecoder choiceDecoder)
                            (BD.list (BD.jsonPair BD.int exprDecoder))
                            metaDecoder

                    22 ->
                        Bytes.Decode.map3 Accessor
                            A.regionDecoder
                            BD.string
                            metaDecoder

                    23 ->
                        Bytes.Decode.map4 Access
                            exprDecoder
                            A.regionDecoder
                            BD.string
                            metaDecoder

                    24 ->
                        Bytes.Decode.map4 Update
                            A.regionDecoder
                            exprDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)
                            metaDecoder

                    25 ->
                        Bytes.Decode.map2 Record
                            (BD.stdDict BD.string exprDecoder)
                            metaDecoder

                    26 ->
                        Bytes.Decode.map3 TrackedRecord
                            A.regionDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)
                            metaDecoder

                    27 ->
                        Bytes.Decode.map Unit metaDecoder

                    28 ->
                        Bytes.Decode.map5 Tuple
                            A.regionDecoder
                            exprDecoder
                            exprDecoder
                            (BD.list exprDecoder)
                            metaDecoder

                    29 ->
                        Bytes.Decode.map4 Shader
                            Shader.sourceDecoder
                            (BD.everySet identity BD.string)
                            (BD.everySet identity BD.string)
                            metaDecoder

                    _ ->
                        Bytes.Decode.fail
            )


defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Def region name expr tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.string name
                , exprEncoder expr
                , Can.typeEncoder tipe
                ]

        TailDef region name args expr tipe maybeTvar ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string name
                , BE.list typedLocatedNameEncoder args
                , exprEncoder expr
                , Can.typeEncoder tipe
                , case maybeTvar of
                    Nothing ->
                        Bytes.Encode.unsignedInt8 0

                    Just (IO.Pt n) ->
                        Bytes.Encode.sequence
                            [ Bytes.Encode.unsignedInt8 1
                            , Bytes.Encode.signedInt32 Bytes.BE n
                            ]
                ]


defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 Def
                            A.regionDecoder
                            BD.string
                            exprDecoder
                            Can.typeDecoder

                    1 ->
                        Bytes.Decode.map5 TailDef
                            A.regionDecoder
                            BD.string
                            (BD.list typedLocatedNameDecoder)
                            exprDecoder
                            Can.typeDecoder
                            |> Bytes.Decode.andThen
                                (\tailDefFn ->
                                    Bytes.Decode.unsignedInt8
                                        |> Bytes.Decode.andThen
                                            (\tag ->
                                                case tag of
                                                    0 ->
                                                        Bytes.Decode.succeed (tailDefFn Nothing)

                                                    _ ->
                                                        Bytes.Decode.map (\n -> tailDefFn (Just (IO.Pt n)))
                                                            (Bytes.Decode.signedInt32 Bytes.BE)
                                            )
                                )

                    _ ->
                        Bytes.Decode.fail
            )


destructorEncoder : Destructor -> Bytes.Encode.Encoder
destructorEncoder (Destructor name path meta) =
    Bytes.Encode.sequence
        [ BE.string name
        , pathEncoder path
        , metaEncoder meta
        ]


destructorDecoder : Bytes.Decode.Decoder Destructor
destructorDecoder =
    Bytes.Decode.map3 Destructor
        BD.string
        pathDecoder
        metaDecoder


deciderEncoder : (a -> Bytes.Encode.Encoder) -> Decider a -> Bytes.Encode.Encoder
deciderEncoder encoder decider =
    case decider of
        Leaf value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , encoder value
                ]

        Chain testChain success failure ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list (BE.jsonPair DT.pathEncoder DT.testEncoder) testChain
                , deciderEncoder encoder success
                , deciderEncoder encoder failure
                ]

        FanOut path edges fallback ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , DT.pathEncoder path
                , BE.list (BE.jsonPair DT.testEncoder (deciderEncoder encoder)) edges
                , deciderEncoder encoder fallback
                ]


deciderDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Decider a)
deciderDecoder decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Leaf decoder

                    1 ->
                        Bytes.Decode.map3 Chain
                            (BD.list (BD.jsonPair DT.pathDecoder DT.testDecoder))
                            (deciderDecoder decoder)
                            (deciderDecoder decoder)

                    2 ->
                        Bytes.Decode.map3 FanOut
                            DT.pathDecoder
                            (BD.list (BD.jsonPair DT.testDecoder (deciderDecoder decoder)))
                            (deciderDecoder decoder)

                    _ ->
                        Bytes.Decode.fail
            )


choiceEncoder : Choice -> Bytes.Encode.Encoder
choiceEncoder choice =
    case choice of
        Inline value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoder value
                ]

        Jump value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int value
                ]


choiceDecoder : Bytes.Decode.Decoder Choice
choiceDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Inline exprDecoder

                    1 ->
                        Bytes.Decode.map Jump BD.int

                    _ ->
                        Bytes.Decode.fail
            )


containerHintEncoder : ContainerHint -> Bytes.Encode.Encoder
containerHintEncoder hint =
    case hint of
        HintList ->
            Bytes.Encode.unsignedInt8 0

        HintTuple2 ->
            Bytes.Encode.unsignedInt8 1

        HintTuple3 ->
            Bytes.Encode.unsignedInt8 2

        HintCustom ctorName ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string ctorName
                ]


containerHintDecoder : Bytes.Decode.Decoder ContainerHint
containerHintDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\n ->
                case n of
                    0 ->
                        Bytes.Decode.succeed HintList

                    1 ->
                        Bytes.Decode.succeed HintTuple2

                    2 ->
                        Bytes.Decode.succeed HintTuple3

                    _ ->
                        -- Tag 3 = HintCustom with constructor name
                        Bytes.Decode.map HintCustom BD.string
            )


pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder path =
    case path of
        Index index hint subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , containerHintEncoder hint
                , pathEncoder subPath
                ]

        ArrayIndex index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int index
                , pathEncoder subPath
                ]

        Field field subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string field
                , pathEncoder subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , pathEncoder subPath
                ]

        Root name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.string name
                ]


pathDecoder : Bytes.Decode.Decoder Path
pathDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Index
                            Index.zeroBasedDecoder
                            containerHintDecoder
                            pathDecoder

                    1 ->
                        Bytes.Decode.map2 ArrayIndex
                            BD.int
                            pathDecoder

                    2 ->
                        Bytes.Decode.map2 Field
                            BD.string
                            pathDecoder

                    3 ->
                        Bytes.Decode.map Unbox pathDecoder

                    4 ->
                        Bytes.Decode.map Root BD.string

                    _ ->
                        Bytes.Decode.fail
            )


effectsTypeEncoder : EffectsType -> Bytes.Encode.Encoder
effectsTypeEncoder effectsType =
    Bytes.Encode.unsignedInt8
        (case effectsType of
            Cmd ->
                0

            Sub ->
                1

            Fx ->
                2
        )


effectsTypeDecoder : Bytes.Decode.Decoder EffectsType
effectsTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Cmd

                    1 ->
                        Bytes.Decode.succeed Sub

                    2 ->
                        Bytes.Decode.succeed Fx

                    _ ->
                        Bytes.Decode.fail
            )
