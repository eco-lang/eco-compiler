module Compiler.AST.TypedOptimized exposing
    ( Expr(..), Global(..), Annotations, AnnotationsByGlobal, SchemeRootsByGlobal, Meta
    , Def(..), Destructor(..), Path(..)
    , ContainerHint(..)
    , Decider(..), Choice(..)
    , GlobalGraph(..), LocalGraph(..), LocalGraphData, Node(..), Main(..), EffectsType(..)
    , emptyGlobalGraph
    , compareGlobal, toComparableGlobal, toKernelGlobal
    , typeOf, metaOf, tvarOf
    , computeVarSupers, varSupersOfType
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

@docs Expr, Global, Annotations, AnnotationsByGlobal, SchemeRootsByGlobal, Meta


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


# Super Constraints

@docs computeVarSupers, varSupersOfType


# Serialization

@docs globalGraphEncoder, globalGraphDecoder, localGraphEncoder, localGraphDecoder

-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.AST.StringTable as StringTable exposing (StringTable)
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
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== TYPE ALIASES ======


{-| Annotations dictionary - maps definition names to their type schemes.
Used in LocalGraph where bare names are unique (per-module).
-}
type alias Annotations id =
    Dict Name (Can.Annotation id)


{-| Annotations keyed by fully-qualified Global identity.
Used in GlobalGraph to avoid cross-module name collisions.
-}
type alias AnnotationsByGlobal id =
    Data.Map.Dict String Global (Can.Annotation id)


{-| Scheme roots keyed by fully-qualified Global identity.
Used in GlobalGraph to avoid cross-module name collisions.
-}
type alias SchemeRootsByGlobal =
    Data.Map.Dict String Global (Dict Name IO.RootedVar)



-- ====== META ======


{-| Metadata carried with each expression: the canonical type and an optional solver variable.
The `tvar` field preserves the solver's union-find variable for MonoDirect monomorphization.
-}
type alias Meta id =
    { tipe : Can.Type id
    , tvar : Maybe IO.Variable
    }



-- ====== EXPRESSIONS ======
-- Every expression variant carries its Meta as the LAST argument


{-| Typed optimized expression. Each variant carries its Meta (type + solver var) as the last argument.
-}
type Expr id
    = Bool A.Region Bool (Meta id)
    | Chr A.Region String (Meta id)
    | Str A.Region String (Meta id)
    | Int A.Region Int (Meta id)
    | Float A.Region Float (Meta id)
    | VarLocal Name (Meta id)
    | TrackedVarLocal A.Region Name (Meta id)
    | VarGlobal A.Region Global (Meta id)
    | VarEnum A.Region Global Index.ZeroBased (Meta id)
    | VarBox A.Region Global (Meta id)
    | VarCycle A.Region IO.Canonical Name (Meta id)
    | VarDebug A.Region Name IO.Canonical (Maybe Name) (Meta id)
    | VarKernel A.Region Name Name Name (Meta id)
    | List A.Region (List (Expr id)) (Meta id)
    | Function (List ( Name, Can.Type id )) (Expr id) (Meta id) -- params with types, body, function type
    | TrackedFunction (List ( A.Located Name, Can.Type id )) (Expr id) (Meta id)
    | Call A.Region (Expr id) (List (Expr id)) (Meta id)
    | TailCall Name (List ( Name, Expr id )) (Meta id)
    | If (List ( Expr id, Expr id )) (Expr id) (Meta id)
    | Let (Def id) (Expr id) (Meta id)
    | Destruct (Destructor id) (Expr id) (Meta id)
    | Case Name Name (Decider (Choice id)) (List ( Int, Expr id )) (Meta id)
    | Accessor A.Region Name (Meta id)
    | Access (Expr id) A.Region Name (Meta id)
    | Update A.Region (Expr id) (Data.Map.Dict String (A.Located Name) (Expr id)) (Meta id)
    | Record (Dict Name (Expr id)) (Meta id)
    | TrackedRecord A.Region (Data.Map.Dict String (A.Located Name) (Expr id)) (Meta id)
    | Unit (Meta id)
    | Tuple A.Region (Expr id) (Expr id) (List (Expr id)) (Meta id)
    | Shader Shader.Source (EverySet String Name) (EverySet String Name) (Meta id)


{-| Extract the type annotation from any expression.
-}
typeOf : Expr id -> Can.Type id
typeOf expr =
    (metaOf expr).tipe


{-| Extract the Meta (type + solver var) from any expression.
-}
metaOf : Expr id -> Meta id
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
tvarOf : Expr id -> Maybe IO.Variable
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
toComparableGlobal : Global -> String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ "." ++ name


{-| Create a global reference to a kernel function.
-}
toKernelGlobal : Name.Name -> Global
toKernelGlobal shortName =
    Global (IO.Canonical Pkg.kernel shortName) Name.dollar



-- ====== DEFINITIONS ======


{-| A local definition, either a simple value or a tail-recursive function.
-}
type Def id
    = Def A.Region Name (Expr id) (Can.Type id) -- name, body, type of the definition
    | TailDef A.Region Name (List ( A.Located Name, Can.Type id )) (Expr id) (Can.Type id) (Maybe IO.Variable) -- name, typed args, body, type of the definition, tvar


{-| Destructuring pattern that extracts a value from a data structure.
-}
type Destructor id
    = Destructor Name Path (Meta id) -- name, path, meta (type + optional tvar)



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
type Choice id
    = Inline (Expr id)
    | Jump Int



-- ====== OBJECT GRAPH ======


{-| A graph of all top-level definitions across multiple modules.
-}
type GlobalGraph id
    = GlobalGraph (Data.Map.Dict String Global (Node id)) (Dict Name Int) (AnnotationsByGlobal id) SchemeRootsByGlobal (Dict Name IO.SuperType)



-- Include annotations for the whole graph


{-| Data structure for a single module's dependency graph.
-}
type alias LocalGraphData id =
    { main : Maybe (Main id)
    , nodes : Data.Map.Dict String Global (Node id)
    , fields : Dict Name Int
    , annotations : Annotations id
    , schemeRoots : Dict Name (Dict Name IO.RootedVar)
    , varSupers : Dict Name IO.SuperType
    }


{-| A graph of top-level definitions for a single module.
-}
type LocalGraph id
    = LocalGraph (LocalGraphData id)



-- Include annotations for this module


{-| Information about the main entry point of an Elm program.
-}
type Main id
    = Static
    | Dynamic (Can.Type id) (Expr id)


{-| A node in the dependency graph representing a top-level definition.
-}
type Node id
    = Define (Expr id) (EverySet String Global) (Meta id) -- body, deps, meta
    | TrackedDefine A.Region (Expr id) (EverySet String Global) (Meta id)
    | Ctor Index.ZeroBased Int (Can.Type id) -- index, arity, constructor type
    | Enum Index.ZeroBased (Can.Type id)
    | Box (Can.Type id)
    | Link Global
    | Cycle (List Name) (List ( Name, Expr id )) (List (Def id)) (EverySet String Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet String Global)
    | PortIncoming (Expr id) (EverySet String Global) (Meta id) -- decoder expr, deps, port meta
    | PortOutgoing (Expr id) (EverySet String Global) (Meta id) -- encoder expr, deps, port meta


{-| The type of effects manager (commands, subscriptions, or both).
-}
type EffectsType
    = Cmd
    | Sub
    | Fx



-- ====== GRAPHS ======


{-| Create an empty global graph (alias for `empty`).
-}
emptyGlobalGraph : GlobalGraph id
emptyGlobalGraph =
    GlobalGraph Data.Map.empty Dict.empty Data.Map.empty Data.Map.empty Dict.empty



-- ====== ENCODERS and DECODERS ======


{-| Encode a global graph to binary format.

The `fields` slot is omitted from the wire format (see ECOT\_001 in
design\_docs/invariants.csv); it is reconstructed as `Dict.empty` on decode.

This encoder emits a per-call string-table preamble (ECOT\_002): every string
field in the body is encoded as an index into the table. The table dominates
the body for any non-trivial graph, so the strict subset of strings actually
emitted determines the savings.

-}
globalGraphEncoder : GlobalGraph Name -> Bytes.Encode.Encoder
globalGraphEncoder ((GlobalGraph nodes _ annotations allSchemeRoots varSupers) as graph) =
    let
        st : StringTable
        st =
            StringTable.build (collectStringsFromGlobalGraph graph Set.empty)
    in
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 typedGraphFormatVersion
        , StringTable.tableEncoder st
        , BE.assocListDict compareGlobal (globalEncoderS st) (nodeEncoderS st) nodes
        , BE.assocListDict compareGlobal (globalEncoderS st) (Can.annotationEncoderS st) annotations
        , globalSchemeRootsEncoderS st allSchemeRoots
        , varSupersEncoderS st varSupers
        ]


{-| Decode a global graph from binary format.
-}
globalGraphDecoder : Bytes.Decode.Decoder (GlobalGraph Name)
globalGraphDecoder =
    formatVersionDecoder
        |> Bytes.Decode.andThen
            (\() ->
                StringTable.tableDecoder
                    |> Bytes.Decode.andThen
                        (\st ->
                            Bytes.Decode.map4
                                (\nodes annotations allSchemeRoots varSupers ->
                                    GlobalGraph nodes Dict.empty annotations allSchemeRoots varSupers
                                )
                                (BD.assocListDict toComparableGlobal (globalDecoderS st) (nodeDecoderS st))
                                (BD.assocListDict toComparableGlobal (globalDecoderS st) (Can.annotationDecoderS st))
                                (globalSchemeRootsDecoderS st)
                                (varSupersDecoderS st)
                        )
            )


{-| Encode a local graph to binary format.

The `main` and `fields` slots are omitted from the wire format (see ECOT\_001
in design\_docs/invariants.csv); they are reconstructed as `Nothing` and
`Dict.empty` on decode.

This encoder emits a per-call string-table preamble (ECOT\_002).

-}
localGraphEncoder : LocalGraph Name -> Bytes.Encode.Encoder
localGraphEncoder ((LocalGraph data) as graph) =
    let
        st : StringTable
        st =
            StringTable.build (collectStringsFromLocalGraph graph Set.empty)
    in
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 typedGraphFormatVersion
        , StringTable.tableEncoder st
        , BE.assocListDict compareGlobal (globalEncoderS st) (nodeEncoderS st) data.nodes
        , BE.stdDict (StringTable.string st) (Can.annotationEncoderS st) data.annotations
        , schemeRootsEncoderS st data.schemeRoots
        , varSupersEncoderS st data.varSupers
        ]


{-| Decode a local graph from binary format.
-}
localGraphDecoder : Bytes.Decode.Decoder (LocalGraph Name)
localGraphDecoder =
    formatVersionDecoder
        |> Bytes.Decode.andThen
            (\() ->
                StringTable.tableDecoder
                    |> Bytes.Decode.andThen
                        (\st ->
                            Bytes.Decode.map4
                                (\nodes annotations schemeRoots varSupers ->
                                    LocalGraph
                                        { main = Nothing
                                        , nodes = nodes
                                        , fields = Dict.empty
                                        , annotations = annotations
                                        , schemeRoots = schemeRoots
                                        , varSupers = varSupers
                                        }
                                )
                                (BD.assocListDict toComparableGlobal (globalDecoderS st) (nodeDecoderS st))
                                (BD.stdDict (StringTable.stringDec st) (Can.annotationDecoderS st))
                                (schemeRootsDecoderS st)
                                (varSupersDecoderS st)
                        )
            )


globalEncoderS : StringTable -> Global -> Bytes.Encode.Encoder
globalEncoderS st (Global home name) =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoderS st home
        , StringTable.string st name
        ]


globalDecoderS : StringTable -> Bytes.Decode.Decoder Global
globalDecoderS st =
    Bytes.Decode.map2 Global
        (ModuleName.canonicalDecoderS st)
        (StringTable.stringDec st)


metaEncoderS : StringTable -> Meta Name -> Bytes.Encode.Encoder
metaEncoderS st meta =
    Can.typeEncoderS st meta.tipe


metaDecoderS : StringTable -> Bytes.Decode.Decoder (Meta Name)
metaDecoderS st =
    Bytes.Decode.map (\t -> { tipe = t, tvar = Nothing }) (Can.typeDecoderS st)


{-| Encode a Node. Per ECOT\_001 in design\_docs/invariants.csv, the per-Node
deps sets (Define, TrackedDefine, Cycle, Kernel, PortIncoming, PortOutgoing),
Manager's EffectsType byte, and Kernel's chunks list are NOT serialized; they
are reconstructed as `EverySet.empty` / `Cmd` / `[]` on decode.
-}
nodeEncoderS : StringTable -> Node Name -> Bytes.Encode.Encoder
nodeEncoderS st node =
    case node of
        Define expr _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoderS st expr
                , Can.typeEncoderS st meta.tipe
                ]

        TrackedDefine region expr _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , exprEncoderS st expr
                , Can.typeEncoderS st meta.tipe
                ]

        Ctor index arity tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoder index
                , BE.int arity
                , Can.typeEncoderS st tipe
                ]

        Enum index tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Index.zeroBasedEncoder index
                , Can.typeEncoderS st tipe
                ]

        Box tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , Can.typeEncoderS st tipe
                ]

        Link linkedGlobal ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , globalEncoderS st linkedGlobal
                ]

        Cycle names values functions _ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.list (StringTable.string st) names
                , BE.list (BE.jsonPair (StringTable.string st) (exprEncoderS st)) values
                , BE.list (defEncoderS st) functions
                ]

        Manager _ ->
            Bytes.Encode.unsignedInt8 8

        Kernel _ _ ->
            Bytes.Encode.unsignedInt8 9

        PortIncoming decoder _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , exprEncoderS st decoder
                , Can.typeEncoderS st meta.tipe
                ]

        PortOutgoing encoder _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoderS st encoder
                , Can.typeEncoderS st meta.tipe
                ]


nodeDecoderS : StringTable -> Bytes.Decode.Decoder (Node Name)
nodeDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 (\expr meta -> Define expr Data.Set.empty meta)
                            (exprDecoderS st)
                            (metaDecoderS st)

                    1 ->
                        Bytes.Decode.map3 (\region expr meta -> TrackedDefine region expr Data.Set.empty meta)
                            A.regionDecoder
                            (exprDecoderS st)
                            (metaDecoderS st)

                    3 ->
                        Bytes.Decode.map3 Ctor
                            Index.zeroBasedDecoder
                            BD.int
                            (Can.typeDecoderS st)

                    4 ->
                        Bytes.Decode.map2 Enum
                            Index.zeroBasedDecoder
                            (Can.typeDecoderS st)

                    5 ->
                        Bytes.Decode.map Box (Can.typeDecoderS st)

                    6 ->
                        Bytes.Decode.map Link (globalDecoderS st)

                    7 ->
                        Bytes.Decode.map3 (\names values funcs -> Cycle names values funcs Data.Set.empty)
                            (BD.list (StringTable.stringDec st))
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (exprDecoderS st)))
                            (BD.list (defDecoderS st))

                    8 ->
                        Bytes.Decode.succeed (Manager Cmd)

                    9 ->
                        Bytes.Decode.succeed (Kernel [] Data.Set.empty)

                    10 ->
                        Bytes.Decode.map2 (\expr meta -> PortIncoming expr Data.Set.empty meta)
                            (exprDecoderS st)
                            (metaDecoderS st)

                    11 ->
                        Bytes.Decode.map2 (\expr meta -> PortOutgoing expr Data.Set.empty meta)
                            (exprDecoderS st)
                            (metaDecoderS st)

                    _ ->
                        Bytes.Decode.fail
            )


typedLocatedNameEncoderS : StringTable -> ( A.Located Name, Can.Type Name ) -> Bytes.Encode.Encoder
typedLocatedNameEncoderS st ( locName, tipe ) =
    Bytes.Encode.sequence
        [ A.locatedEncoder (StringTable.string st) locName
        , Can.typeEncoderS st tipe
        ]


typedLocatedNameDecoderS : StringTable -> Bytes.Decode.Decoder ( A.Located Name, Can.Type Name )
typedLocatedNameDecoderS st =
    Bytes.Decode.map2 Tuple.pair
        (A.locatedDecoder (StringTable.stringDec st))
        (Can.typeDecoderS st)


typedNameEncoderS : StringTable -> ( Name, Can.Type Name ) -> Bytes.Encode.Encoder
typedNameEncoderS st ( name, tipe ) =
    Bytes.Encode.sequence
        [ StringTable.string st name
        , Can.typeEncoderS st tipe
        ]


typedNameDecoderS : StringTable -> Bytes.Decode.Decoder ( Name, Can.Type Name )
typedNameDecoderS st =
    Bytes.Decode.map2 Tuple.pair
        (StringTable.stringDec st)
        (Can.typeDecoderS st)


exprEncoderS : StringTable -> Expr Name -> Bytes.Encode.Encoder
exprEncoderS st expr =
    case expr of
        Bool region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.bool value
                , Can.typeEncoderS st meta.tipe
                ]

        Chr region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , StringTable.string st value
                , Can.typeEncoderS st meta.tipe
                ]

        Str region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , StringTable.string st value
                , Can.typeEncoderS st meta.tipe
                ]

        Int region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoder region
                , BE.int value
                , Can.typeEncoderS st meta.tipe
                ]

        Float region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , A.regionEncoder region
                , BE.float value
                , Can.typeEncoderS st meta.tipe
                ]

        VarLocal value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , StringTable.string st value
                , Can.typeEncoderS st meta.tipe
                ]

        TrackedVarLocal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoder region
                , StringTable.string st value
                , Can.typeEncoderS st meta.tipe
                ]

        VarGlobal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoder region
                , globalEncoderS st value
                , Can.typeEncoderS st meta.tipe
                ]

        VarEnum region global index meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , A.regionEncoder region
                , globalEncoderS st global
                , Index.zeroBasedEncoder index
                , Can.typeEncoderS st meta.tipe
                ]

        VarBox region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoder region
                , globalEncoderS st value
                , Can.typeEncoderS st meta.tipe
                ]

        VarCycle region home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , A.regionEncoder region
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , Can.typeEncoderS st meta.tipe
                ]

        VarDebug region name _ _ meta ->
            -- Per ECOT_001: home and unhandledValueName are NOT serialized.
            -- They are reconstructed on decode as (IO.Canonical Pkg.core Name.debug)
            -- and Nothing respectively; Specialize hardcodes "Elm" "Debug" anyway.
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , A.regionEncoder region
                , StringTable.string st name
                , Can.typeEncoderS st meta.tipe
                ]

        VarKernel region kernelPrefix home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , A.regionEncoder region
                , StringTable.string st kernelPrefix
                , StringTable.string st home
                , StringTable.string st name
                , Can.typeEncoderS st meta.tipe
                ]

        List region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , A.regionEncoder region
                , BE.list (exprEncoderS st) value
                , Can.typeEncoderS st meta.tipe
                ]

        Function args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list (typedNameEncoderS st) args
                , exprEncoderS st body
                , Can.typeEncoderS st meta.tipe
                ]

        TrackedFunction args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.list (typedLocatedNameEncoderS st) args
                , exprEncoderS st body
                , Can.typeEncoderS st meta.tipe
                ]

        Call region func args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , A.regionEncoder region
                , exprEncoderS st func
                , BE.list (exprEncoderS st) args
                , Can.typeEncoderS st meta.tipe
                ]

        TailCall name args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , StringTable.string st name
                , BE.list (BE.jsonPair (StringTable.string st) (exprEncoderS st)) args
                , Can.typeEncoderS st meta.tipe
                ]

        If branches final meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list (BE.jsonPair (exprEncoderS st) (exprEncoderS st)) branches
                , exprEncoderS st final
                , Can.typeEncoderS st meta.tipe
                ]

        Let def body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , defEncoderS st def
                , exprEncoderS st body
                , Can.typeEncoderS st meta.tipe
                ]

        Destruct destructor body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , destructorEncoderS st destructor
                , exprEncoderS st body
                , Can.typeEncoderS st meta.tipe
                ]

        Case label root decider jumps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , StringTable.string st label
                , StringTable.string st root
                , deciderEncoderS st (choiceEncoderS st) decider
                , BE.list (BE.jsonPair BE.int (exprEncoderS st)) jumps
                , Can.typeEncoderS st meta.tipe
                ]

        Accessor region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , A.regionEncoder region
                , StringTable.string st field
                , Can.typeEncoderS st meta.tipe
                ]

        Access record region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoderS st record
                , A.regionEncoder region
                , StringTable.string st field
                , Can.typeEncoderS st meta.tipe
                ]

        Update region record fields meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , A.regionEncoder region
                , exprEncoderS st record
                , BE.assocListDict A.compareLocated (A.locatedEncoder (StringTable.string st)) (exprEncoderS st) fields
                , Can.typeEncoderS st meta.tipe
                ]

        Record value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 25
                , BE.stdDict (StringTable.string st) (exprEncoderS st) value
                , Can.typeEncoderS st meta.tipe
                ]

        TrackedRecord region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , A.regionEncoder region
                , BE.assocListDict A.compareLocated (A.locatedEncoder (StringTable.string st)) (exprEncoderS st) value
                , Can.typeEncoderS st meta.tipe
                ]

        Unit meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 27
                , Can.typeEncoderS st meta.tipe
                ]

        Tuple region a b cs meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 28
                , A.regionEncoder region
                , exprEncoderS st a
                , exprEncoderS st b
                , BE.list (exprEncoderS st) cs
                , Can.typeEncoderS st meta.tipe
                ]

        Shader src attributes uniforms meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 29
                , Shader.sourceEncoderS st src
                , BE.everySet compare (StringTable.string st) attributes
                , BE.everySet compare (StringTable.string st) uniforms
                , Can.typeEncoderS st meta.tipe
                ]


exprDecoderS : StringTable -> Bytes.Decode.Decoder (Expr Name)
exprDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Bool
                            A.regionDecoder
                            BD.bool
                            (metaDecoderS st)

                    1 ->
                        Bytes.Decode.map3 Chr
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    2 ->
                        Bytes.Decode.map3 Str
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    3 ->
                        Bytes.Decode.map3 Int
                            A.regionDecoder
                            BD.int
                            (metaDecoderS st)

                    4 ->
                        Bytes.Decode.map3 Float
                            A.regionDecoder
                            BD.float
                            (metaDecoderS st)

                    5 ->
                        Bytes.Decode.map2 VarLocal
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    6 ->
                        Bytes.Decode.map3 TrackedVarLocal
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    7 ->
                        Bytes.Decode.map3 VarGlobal
                            A.regionDecoder
                            (globalDecoderS st)
                            (metaDecoderS st)

                    8 ->
                        Bytes.Decode.map4 VarEnum
                            A.regionDecoder
                            (globalDecoderS st)
                            Index.zeroBasedDecoder
                            (metaDecoderS st)

                    9 ->
                        Bytes.Decode.map3 VarBox
                            A.regionDecoder
                            (globalDecoderS st)
                            (metaDecoderS st)

                    10 ->
                        Bytes.Decode.map4 VarCycle
                            A.regionDecoder
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    11 ->
                        -- Per ECOT_001: reconstruct home and unhandledValueName locally.
                        Bytes.Decode.map3
                            (\region name meta ->
                                VarDebug region name (IO.Canonical Pkg.core Name.debug) Nothing meta
                            )
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    12 ->
                        Bytes.Decode.map5 VarKernel
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    13 ->
                        Bytes.Decode.map3 List
                            A.regionDecoder
                            (BD.list (exprDecoderS st))
                            (metaDecoderS st)

                    14 ->
                        Bytes.Decode.map3 Function
                            (BD.list (typedNameDecoderS st))
                            (exprDecoderS st)
                            (metaDecoderS st)

                    15 ->
                        Bytes.Decode.map3 TrackedFunction
                            (BD.list (typedLocatedNameDecoderS st))
                            (exprDecoderS st)
                            (metaDecoderS st)

                    16 ->
                        Bytes.Decode.map4 Call
                            A.regionDecoder
                            (exprDecoderS st)
                            (BD.list (exprDecoderS st))
                            (metaDecoderS st)

                    17 ->
                        Bytes.Decode.map3 TailCall
                            (StringTable.stringDec st)
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (exprDecoderS st)))
                            (metaDecoderS st)

                    18 ->
                        Bytes.Decode.map3 If
                            (BD.list (BD.jsonPair (exprDecoderS st) (exprDecoderS st)))
                            (exprDecoderS st)
                            (metaDecoderS st)

                    19 ->
                        Bytes.Decode.map3 Let
                            (defDecoderS st)
                            (exprDecoderS st)
                            (metaDecoderS st)

                    20 ->
                        Bytes.Decode.map3 Destruct
                            (destructorDecoderS st)
                            (exprDecoderS st)
                            (metaDecoderS st)

                    21 ->
                        Bytes.Decode.map5 Case
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (deciderDecoderS st (choiceDecoderS st))
                            (BD.list (BD.jsonPair BD.int (exprDecoderS st)))
                            (metaDecoderS st)

                    22 ->
                        Bytes.Decode.map3 Accessor
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    23 ->
                        Bytes.Decode.map4 Access
                            (exprDecoderS st)
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (metaDecoderS st)

                    24 ->
                        Bytes.Decode.map4 Update
                            A.regionDecoder
                            (exprDecoderS st)
                            (BD.assocListDict A.toValue (A.locatedDecoder (StringTable.stringDec st)) (exprDecoderS st))
                            (metaDecoderS st)

                    25 ->
                        Bytes.Decode.map2 Record
                            (BD.stdDict (StringTable.stringDec st) (exprDecoderS st))
                            (metaDecoderS st)

                    26 ->
                        Bytes.Decode.map3 TrackedRecord
                            A.regionDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder (StringTable.stringDec st)) (exprDecoderS st))
                            (metaDecoderS st)

                    27 ->
                        Bytes.Decode.map Unit (metaDecoderS st)

                    28 ->
                        Bytes.Decode.map5 Tuple
                            A.regionDecoder
                            (exprDecoderS st)
                            (exprDecoderS st)
                            (BD.list (exprDecoderS st))
                            (metaDecoderS st)

                    29 ->
                        Bytes.Decode.map4 Shader
                            (Shader.sourceDecoderS st)
                            (BD.everySet identity (StringTable.stringDec st))
                            (BD.everySet identity (StringTable.stringDec st))
                            (metaDecoderS st)

                    _ ->
                        Bytes.Decode.fail
            )


defEncoderS : StringTable -> Def Name -> Bytes.Encode.Encoder
defEncoderS st def =
    case def of
        Def region name expr tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , StringTable.string st name
                , exprEncoderS st expr
                , Can.typeEncoderS st tipe
                ]

        TailDef region name args expr tipe maybeTvar ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , StringTable.string st name
                , BE.list (typedLocatedNameEncoderS st) args
                , exprEncoderS st expr
                , Can.typeEncoderS st tipe
                , case maybeTvar of
                    Nothing ->
                        Bytes.Encode.unsignedInt8 0

                    Just (IO.Pt n) ->
                        Bytes.Encode.sequence
                            [ Bytes.Encode.unsignedInt8 1
                            , Bytes.Encode.signedInt32 Bytes.BE n
                            ]
                ]


defDecoderS : StringTable -> Bytes.Decode.Decoder (Def Name)
defDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 Def
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (exprDecoderS st)
                            (Can.typeDecoderS st)

                    1 ->
                        Bytes.Decode.map5 TailDef
                            A.regionDecoder
                            (StringTable.stringDec st)
                            (BD.list (typedLocatedNameDecoderS st))
                            (exprDecoderS st)
                            (Can.typeDecoderS st)
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


destructorEncoderS : StringTable -> Destructor Name -> Bytes.Encode.Encoder
destructorEncoderS st (Destructor name path meta) =
    Bytes.Encode.sequence
        [ StringTable.string st name
        , pathEncoderS st path
        , metaEncoderS st meta
        ]


destructorDecoderS : StringTable -> Bytes.Decode.Decoder (Destructor Name)
destructorDecoderS st =
    Bytes.Decode.map3 Destructor
        (StringTable.stringDec st)
        (pathDecoderS st)
        (metaDecoderS st)


deciderEncoderS : StringTable -> (a -> Bytes.Encode.Encoder) -> Decider a -> Bytes.Encode.Encoder
deciderEncoderS st encoder decider =
    case decider of
        Leaf value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , encoder value
                ]

        Chain testChain success failure ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list (BE.jsonPair (DT.pathEncoderS st) (DT.testEncoderS st)) testChain
                , deciderEncoderS st encoder success
                , deciderEncoderS st encoder failure
                ]

        FanOut path edges fallback ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , DT.pathEncoderS st path
                , BE.list (BE.jsonPair (DT.testEncoderS st) (deciderEncoderS st encoder)) edges
                , deciderEncoderS st encoder fallback
                ]


deciderDecoderS : StringTable -> Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Decider a)
deciderDecoderS st decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Leaf decoder

                    1 ->
                        Bytes.Decode.map3 Chain
                            (BD.list (BD.jsonPair (DT.pathDecoderS st) (DT.testDecoderS st)))
                            (deciderDecoderS st decoder)
                            (deciderDecoderS st decoder)

                    2 ->
                        Bytes.Decode.map3 FanOut
                            (DT.pathDecoderS st)
                            (BD.list (BD.jsonPair (DT.testDecoderS st) (deciderDecoderS st decoder)))
                            (deciderDecoderS st decoder)

                    _ ->
                        Bytes.Decode.fail
            )


choiceEncoderS : StringTable -> Choice Name -> Bytes.Encode.Encoder
choiceEncoderS st choice =
    case choice of
        Inline value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoderS st value
                ]

        Jump value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int value
                ]


choiceDecoderS : StringTable -> Bytes.Decode.Decoder (Choice Name)
choiceDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Inline (exprDecoderS st)

                    1 ->
                        Bytes.Decode.map Jump BD.int

                    _ ->
                        Bytes.Decode.fail
            )


containerHintEncoderS : StringTable -> ContainerHint -> Bytes.Encode.Encoder
containerHintEncoderS st hint =
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
                , StringTable.string st ctorName
                ]


containerHintDecoderS : StringTable -> Bytes.Decode.Decoder ContainerHint
containerHintDecoderS st =
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
                        Bytes.Decode.map HintCustom (StringTable.stringDec st)
            )


pathEncoderS : StringTable -> Path -> Bytes.Encode.Encoder
pathEncoderS st path =
    case path of
        Index index hint subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , containerHintEncoderS st hint
                , pathEncoderS st subPath
                ]

        ArrayIndex index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int index
                , pathEncoderS st subPath
                ]

        Field field subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , StringTable.string st field
                , pathEncoderS st subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , pathEncoderS st subPath
                ]

        Root name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , StringTable.string st name
                ]


pathDecoderS : StringTable -> Bytes.Decode.Decoder Path
pathDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Index
                            Index.zeroBasedDecoder
                            (containerHintDecoderS st)
                            (pathDecoderS st)

                    1 ->
                        Bytes.Decode.map2 ArrayIndex
                            BD.int
                            (pathDecoderS st)

                    2 ->
                        Bytes.Decode.map2 Field
                            (StringTable.stringDec st)
                            (pathDecoderS st)

                    3 ->
                        Bytes.Decode.map Unbox (pathDecoderS st)

                    4 ->
                        Bytes.Decode.map Root (StringTable.stringDec st)

                    _ ->
                        Bytes.Decode.fail
            )



-- ====== FORMAT VERSION ======


{-| Wire-format version for the typed graph binary encoders (LocalGraph /
GlobalGraph, hence `.ecot` and `typed-artifacts.dat`). Bump on any change to
the persisted layout so stale artifacts fail decode deterministically rather
than misparsing.
-}
typedGraphFormatVersion : Int
typedGraphFormatVersion =
    1


{-| Read and check the leading format-version byte; fail the whole decode on
mismatch (stale artifact).
-}
formatVersionDecoder : Bytes.Decode.Decoder ()
formatVersionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\v ->
                if v == typedGraphFormatVersion then
                    Bytes.Decode.succeed ()

                else
                    Bytes.Decode.fail
            )



-- ====== SCHEME ROOTS ENCODERS/DECODERS ======


variableEncoder : IO.Variable -> Bytes.Encode.Encoder
variableEncoder (IO.Pt idx) =
    Bytes.Encode.signedInt32 Bytes.BE idx


variableDecoder : Bytes.Decode.Decoder IO.Variable
variableDecoder =
    Bytes.Decode.map IO.Pt (Bytes.Decode.signedInt32 Bytes.BE)


{-| Encode an optional super constraint as one byte (0 = none).
-}
maybeSuperToByte : Maybe IO.SuperType -> Int
maybeSuperToByte ms =
    case ms of
        Nothing ->
            0

        Just IO.Number ->
            1

        Just IO.Comparable ->
            2

        Just IO.Appendable ->
            3

        Just IO.CompAppend ->
            4


byteToMaybeSuper : Int -> Maybe IO.SuperType
byteToMaybeSuper b =
    case b of
        1 ->
            Just IO.Number

        2 ->
            Just IO.Comparable

        3 ->
            Just IO.Appendable

        4 ->
            Just IO.CompAppend

        _ ->
            Nothing


rootedVarEncoder : IO.RootedVar -> Bytes.Encode.Encoder
rootedVarEncoder rv =
    Bytes.Encode.sequence
        [ variableEncoder rv.var
        , Bytes.Encode.unsignedInt8 (maybeSuperToByte rv.super)
        ]


rootedVarDecoder : Bytes.Decode.Decoder IO.RootedVar
rootedVarDecoder =
    Bytes.Decode.map2 (\v b -> { var = v, super = byteToMaybeSuper b })
        variableDecoder
        Bytes.Decode.unsignedInt8


schemeRootsForDefEncoderS : StringTable -> Dict Name IO.RootedVar -> Bytes.Encode.Encoder
schemeRootsForDefEncoderS st roots =
    BE.stdDict (StringTable.string st) rootedVarEncoder roots


schemeRootsForDefDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name IO.RootedVar)
schemeRootsForDefDecoderS st =
    BD.stdDict (StringTable.stringDec st) rootedVarDecoder


schemeRootsEncoderS : StringTable -> Dict Name (Dict Name IO.RootedVar) -> Bytes.Encode.Encoder
schemeRootsEncoderS st allRoots =
    BE.stdDict (StringTable.string st) (schemeRootsForDefEncoderS st) allRoots


schemeRootsDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name (Dict Name IO.RootedVar))
schemeRootsDecoderS st =
    BD.stdDict (StringTable.stringDec st) (schemeRootsForDefDecoderS st)



-- ====== VAR SUPERS ENCODERS/DECODERS ======


superValueEncoder : IO.SuperType -> Bytes.Encode.Encoder
superValueEncoder s =
    Bytes.Encode.unsignedInt8 (maybeSuperToByte (Just s))


superValueDecoder : Bytes.Decode.Decoder IO.SuperType
superValueDecoder =
    Bytes.Decode.map (\b -> Maybe.withDefault IO.Number (byteToMaybeSuper b)) Bytes.Decode.unsignedInt8


varSupersEncoderS : StringTable -> Dict Name IO.SuperType -> Bytes.Encode.Encoder
varSupersEncoderS st vs =
    BE.stdDict (StringTable.string st) superValueEncoder vs


varSupersDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name IO.SuperType)
varSupersDecoderS st =
    BD.stdDict (StringTable.stringDec st) superValueDecoder


globalSchemeRootsEncoderS : StringTable -> SchemeRootsByGlobal -> Bytes.Encode.Encoder
globalSchemeRootsEncoderS st allRoots =
    BE.assocListDict compareGlobal (globalEncoderS st) (schemeRootsForDefEncoderS st) allRoots


globalSchemeRootsDecoderS : StringTable -> Bytes.Decode.Decoder SchemeRootsByGlobal
globalSchemeRootsDecoderS st =
    BD.assocListDict toComparableGlobal (globalDecoderS st) (schemeRootsForDefDecoderS st)



-- ====== STRING COLLECTORS (ECOT_002) ======


{-| Collect strings emitted by `localGraphEncoder`'s body into a set.
-}
collectStringsFromLocalGraph : LocalGraph Name -> Set String -> Set String
collectStringsFromLocalGraph (LocalGraph data) acc =
    acc
        |> (\a -> Data.Map.foldl compareGlobal collectStringsFromGlobalNodePair a data.nodes)
        |> (\a -> Dict.foldl collectStringsFromAnnotationPair a data.annotations)
        |> collectStringsFromSchemeRoots data.schemeRoots
        |> (\a -> Dict.foldl (\k _ a2 -> Set.insert k a2) a data.varSupers)


{-| Collect strings emitted by `globalGraphEncoder`'s body into a set.
-}
collectStringsFromGlobalGraph : GlobalGraph Name -> Set String -> Set String
collectStringsFromGlobalGraph (GlobalGraph nodes _ annotations allSchemeRoots varSupers) acc =
    acc
        |> (\a -> Data.Map.foldl compareGlobal collectStringsFromGlobalNodePair a nodes)
        |> (\a -> Data.Map.foldl compareGlobal collectStringsFromGlobalAnnotationPair a annotations)
        |> collectStringsFromGlobalSchemeRoots allSchemeRoots
        |> (\a -> Dict.foldl (\k _ a2 -> Set.insert k a2) a varSupers)


collectStringsFromGlobalNodePair : Global -> Node Name -> Set String -> Set String
collectStringsFromGlobalNodePair g node acc =
    acc
        |> collectStringsFromGlobal g
        |> collectStringsFromNode node


collectStringsFromAnnotationPair : Name -> Can.Annotation Name -> Set String -> Set String
collectStringsFromAnnotationPair name ann acc =
    acc
        |> Set.insert name
        |> Can.collectStringsFromAnnotation ann


collectStringsFromGlobalAnnotationPair : Global -> Can.Annotation Name -> Set String -> Set String
collectStringsFromGlobalAnnotationPair g ann acc =
    acc
        |> collectStringsFromGlobal g
        |> Can.collectStringsFromAnnotation ann


collectStringsFromSchemeRoots : Dict Name (Dict Name IO.RootedVar) -> Set String -> Set String
collectStringsFromSchemeRoots roots acc =
    Dict.foldl
        (\k inner a ->
            Dict.foldl (\k2 _ a2 -> Set.insert k2 a2) (Set.insert k a) inner
        )
        acc
        roots


collectStringsFromGlobalSchemeRoots : SchemeRootsByGlobal -> Set String -> Set String
collectStringsFromGlobalSchemeRoots roots acc =
    Data.Map.foldl compareGlobal
        (\g inner a ->
            Dict.foldl (\k _ a2 -> Set.insert k a2) (collectStringsFromGlobal g a) inner
        )
        acc
        roots



-- ====== VAR SUPERS COMPUTATION ======


{-| The single name→super ingestion point for persisted typed graphs.

Maps the surface-syntax type-variable naming convention (`number*`,
`comparable*`, `appendable*`, `compappend*`) to a structured super constraint.
This is the ONLY place the name convention is read into the persisted-graph
channel; monomorphization consumes the resulting `varSupers` / `RootedVar.super`
data, never the names themselves. Mirrors `Compiler.Type.Type.toSuper`.

-}
superOfName : Name -> Maybe IO.SuperType
superOfName name =
    if Name.isNumberType name then
        Just IO.Number

    else if Name.isComparableType name then
        Just IO.Comparable

    else if Name.isAppendableType name then
        Just IO.Appendable

    else if Name.isCompappendType name then
        Just IO.CompAppend

    else
        Nothing


insertSuperOfName : Name -> Dict Name IO.SuperType -> Dict Name IO.SuperType
insertSuperOfName name acc =
    case superOfName name of
        Just s ->
            Dict.insert name s acc

        Nothing ->
            acc


{-| Compute the `varSupers` map for a finished local graph by sweeping every
name it emits and keeping those that carry a super constraint. Complete by
construction: it reuses the same collector the encoder uses, so every type
variable in the graph is covered.
-}
computeVarSupers : LocalGraph Name -> Dict Name IO.SuperType
computeVarSupers graph =
    Set.foldl insertSuperOfName Dict.empty (collectStringsFromLocalGraph graph Set.empty)


{-| Compute a `varSupers` map for a single standalone canonical type (used by
`AssignMVarIds.assignIdsToType`, the test-only single-type entry point).
-}
varSupersOfType : Can.Type Name -> Dict Name IO.SuperType
varSupersOfType tipe =
    Set.foldl insertSuperOfName Dict.empty (Can.collectStringsFromType tipe Set.empty)


collectStringsFromGlobal : Global -> Set String -> Set String
collectStringsFromGlobal (Global home name) acc =
    acc
        |> ModuleName.collectStringsFromCanonical home
        |> Set.insert name


collectStringsFromMeta : Meta Name -> Set String -> Set String
collectStringsFromMeta meta acc =
    Can.collectStringsFromType meta.tipe acc


collectStringsFromNode : Node Name -> Set String -> Set String
collectStringsFromNode node acc =
    case node of
        Define expr _ meta ->
            acc |> collectStringsFromExpr expr |> Can.collectStringsFromType meta.tipe

        TrackedDefine _ expr _ meta ->
            acc |> collectStringsFromExpr expr |> Can.collectStringsFromType meta.tipe

        Ctor _ _ tipe ->
            Can.collectStringsFromType tipe acc

        Enum _ tipe ->
            Can.collectStringsFromType tipe acc

        Box tipe ->
            Can.collectStringsFromType tipe acc

        Link g ->
            collectStringsFromGlobal g acc

        Cycle names values funcs _ ->
            let
                withNames : Set String
                withNames =
                    List.foldl Set.insert acc names

                withValues : Set String
                withValues =
                    List.foldl
                        (\( n, e ) a -> a |> Set.insert n |> collectStringsFromExpr e)
                        withNames
                        values
            in
            List.foldl collectStringsFromDef withValues funcs

        Manager _ ->
            acc

        Kernel _ _ ->
            acc

        PortIncoming expr _ meta ->
            acc |> collectStringsFromExpr expr |> Can.collectStringsFromType meta.tipe

        PortOutgoing expr _ meta ->
            acc |> collectStringsFromExpr expr |> Can.collectStringsFromType meta.tipe


collectStringsFromDef : Def Name -> Set String -> Set String
collectStringsFromDef def acc =
    case def of
        Def _ name expr tipe ->
            acc
                |> Set.insert name
                |> collectStringsFromExpr expr
                |> Can.collectStringsFromType tipe

        TailDef _ name args expr tipe _ ->
            let
                withArgs : Set String
                withArgs =
                    List.foldl
                        (\( locName, t ) a ->
                            a |> Set.insert (A.toValue locName) |> Can.collectStringsFromType t
                        )
                        (Set.insert name acc)
                        args
            in
            withArgs |> collectStringsFromExpr expr |> Can.collectStringsFromType tipe


collectStringsFromExpr : Expr Name -> Set String -> Set String
collectStringsFromExpr expr acc =
    case expr of
        Bool _ _ meta ->
            collectStringsFromMeta meta acc

        Chr _ value meta ->
            acc |> Set.insert value |> collectStringsFromMeta meta

        Str _ value meta ->
            acc |> Set.insert value |> collectStringsFromMeta meta

        Int _ _ meta ->
            collectStringsFromMeta meta acc

        Float _ _ meta ->
            collectStringsFromMeta meta acc

        VarLocal value meta ->
            acc |> Set.insert value |> collectStringsFromMeta meta

        TrackedVarLocal _ value meta ->
            acc |> Set.insert value |> collectStringsFromMeta meta

        VarGlobal _ g meta ->
            acc |> collectStringsFromGlobal g |> collectStringsFromMeta meta

        VarEnum _ g _ meta ->
            acc |> collectStringsFromGlobal g |> collectStringsFromMeta meta

        VarBox _ g meta ->
            acc |> collectStringsFromGlobal g |> collectStringsFromMeta meta

        VarCycle _ home name meta ->
            acc
                |> ModuleName.collectStringsFromCanonical home
                |> Set.insert name
                |> collectStringsFromMeta meta

        VarDebug _ name _ _ meta ->
            acc |> Set.insert name |> collectStringsFromMeta meta

        VarKernel _ kp home name meta ->
            acc
                |> Set.insert kp
                |> Set.insert home
                |> Set.insert name
                |> collectStringsFromMeta meta

        List _ values meta ->
            List.foldl collectStringsFromExpr (collectStringsFromMeta meta acc) values

        Function args body meta ->
            let
                withArgs : Set String
                withArgs =
                    List.foldl
                        (\( n, t ) a -> a |> Set.insert n |> Can.collectStringsFromType t)
                        acc
                        args
            in
            withArgs |> collectStringsFromExpr body |> collectStringsFromMeta meta

        TrackedFunction args body meta ->
            let
                withArgs : Set String
                withArgs =
                    List.foldl
                        (\( locN, t ) a ->
                            a |> Set.insert (A.toValue locN) |> Can.collectStringsFromType t
                        )
                        acc
                        args
            in
            withArgs |> collectStringsFromExpr body |> collectStringsFromMeta meta

        Call _ func args meta ->
            List.foldl collectStringsFromExpr
                (acc |> collectStringsFromExpr func |> collectStringsFromMeta meta)
                args

        TailCall name args meta ->
            List.foldl
                (\( n, e ) a -> a |> Set.insert n |> collectStringsFromExpr e)
                (acc |> Set.insert name |> collectStringsFromMeta meta)
                args

        If branches final meta ->
            List.foldl
                (\( c, b ) a -> a |> collectStringsFromExpr c |> collectStringsFromExpr b)
                (acc |> collectStringsFromExpr final |> collectStringsFromMeta meta)
                branches

        Let def body meta ->
            acc
                |> collectStringsFromDef def
                |> collectStringsFromExpr body
                |> collectStringsFromMeta meta

        Destruct destructor body meta ->
            acc
                |> collectStringsFromDestructor destructor
                |> collectStringsFromExpr body
                |> collectStringsFromMeta meta

        Case label root decider jumps meta ->
            let
                withLabels : Set String
                withLabels =
                    acc |> Set.insert label |> Set.insert root

                withDecider : Set String
                withDecider =
                    collectStringsFromDecider collectStringsFromChoice decider withLabels

                withJumps : Set String
                withJumps =
                    List.foldl (\( _, e ) a -> collectStringsFromExpr e a) withDecider jumps
            in
            collectStringsFromMeta meta withJumps

        Accessor _ field meta ->
            acc |> Set.insert field |> collectStringsFromMeta meta

        Access record _ field meta ->
            acc
                |> collectStringsFromExpr record
                |> Set.insert field
                |> collectStringsFromMeta meta

        Update _ record fields meta ->
            let
                withRecord : Set String
                withRecord =
                    collectStringsFromExpr record acc

                withFields : Set String
                withFields =
                    Data.Map.foldl A.compareLocated
                        (\locN e a ->
                            a |> Set.insert (A.toValue locN) |> collectStringsFromExpr e
                        )
                        withRecord
                        fields
            in
            collectStringsFromMeta meta withFields

        Record value meta ->
            let
                withFields : Set String
                withFields =
                    Dict.foldl
                        (\k e a -> a |> Set.insert k |> collectStringsFromExpr e)
                        acc
                        value
            in
            collectStringsFromMeta meta withFields

        TrackedRecord _ value meta ->
            let
                withFields : Set String
                withFields =
                    Data.Map.foldl A.compareLocated
                        (\locN e a ->
                            a |> Set.insert (A.toValue locN) |> collectStringsFromExpr e
                        )
                        acc
                        value
            in
            collectStringsFromMeta meta withFields

        Unit meta ->
            collectStringsFromMeta meta acc

        Tuple _ a b cs meta ->
            List.foldl collectStringsFromExpr
                (acc
                    |> collectStringsFromExpr a
                    |> collectStringsFromExpr b
                    |> collectStringsFromMeta meta
                )
                cs

        Shader src attributes uniforms meta ->
            let
                withSrc : Set String
                withSrc =
                    Shader.collectStringsFromSource src acc

                withAttrs : Set String
                withAttrs =
                    Data.Set.foldr compare Set.insert withSrc attributes

                withUnis : Set String
                withUnis =
                    Data.Set.foldr compare Set.insert withAttrs uniforms
            in
            collectStringsFromMeta meta withUnis


collectStringsFromDestructor : Destructor Name -> Set String -> Set String
collectStringsFromDestructor (Destructor name path meta) acc =
    acc
        |> Set.insert name
        |> collectStringsFromPath path
        |> collectStringsFromMeta meta


collectStringsFromPath : Path -> Set String -> Set String
collectStringsFromPath path acc =
    case path of
        Index _ hint subPath ->
            acc |> collectStringsFromContainerHint hint |> collectStringsFromPath subPath

        ArrayIndex _ subPath ->
            collectStringsFromPath subPath acc

        Field field subPath ->
            acc |> Set.insert field |> collectStringsFromPath subPath

        Unbox subPath ->
            collectStringsFromPath subPath acc

        Root name ->
            Set.insert name acc


collectStringsFromContainerHint : ContainerHint -> Set String -> Set String
collectStringsFromContainerHint hint acc =
    case hint of
        HintCustom ctorName ->
            Set.insert ctorName acc

        _ ->
            acc


collectStringsFromDecider : (a -> Set String -> Set String) -> Decider a -> Set String -> Set String
collectStringsFromDecider collectInner decider acc =
    case decider of
        Leaf value ->
            collectInner value acc

        Chain testChain success failure ->
            let
                withTests : Set String
                withTests =
                    List.foldl
                        (\( p, t ) a -> a |> DT.collectStringsFromPath p |> DT.collectStringsFromTest t)
                        acc
                        testChain
            in
            withTests
                |> collectStringsFromDecider collectInner success
                |> collectStringsFromDecider collectInner failure

        FanOut path edges fallback ->
            let
                withPath : Set String
                withPath =
                    DT.collectStringsFromPath path acc

                withEdges : Set String
                withEdges =
                    List.foldl
                        (\( t, d ) a ->
                            a
                                |> DT.collectStringsFromTest t
                                |> collectStringsFromDecider collectInner d
                        )
                        withPath
                        edges
            in
            collectStringsFromDecider collectInner fallback withEdges


collectStringsFromChoice : Choice Name -> Set String -> Set String
collectStringsFromChoice choice acc =
    case choice of
        Inline value ->
            collectStringsFromExpr value acc

        Jump _ ->
            acc
