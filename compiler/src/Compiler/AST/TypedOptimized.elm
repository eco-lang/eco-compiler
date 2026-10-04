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
    , globalHash
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
@docs globalHash

-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeTable as TypeTable exposing (TypeTable)
import Compiler.AST.TypeVars as Vars
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
import Eco.Hash
import Set exposing (Set)
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
    Data.Map.Dict String Global (Dict Name Vars.RootedVar)



-- ====== META ======


{-| Metadata carried with each expression: the canonical type and an optional solver variable.
The `tvar` field preserves the solver's union-find variable for MonoDirect monomorphization.
-}
type alias Meta id =
    { tipe : Can.Type id
    , tvar : Maybe Vars.Variable
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
    | VarCycle A.Region ModuleName.Canonical Name (Meta id)
    | VarDebug A.Region Name ModuleName.Canonical (Maybe Name) (Meta id)
    | VarKernel A.Region Name Name Name (Meta id)
    | List A.Region (List (Expr id)) (Meta id)
    | Function (Maybe TypeIds.SrcLambdaId) (List ( Name, Can.Type id )) (Expr id) (Meta id) -- source-lambda id (LSS member identity; NOT persisted), params with types, body, function type
    | TrackedFunction (Maybe TypeIds.SrcLambdaId) (List ( A.Located Name, Can.Type id )) (Expr id) (Meta id)
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

        Function _ _ _ meta ->
            meta

        TrackedFunction _ _ _ meta ->
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
tvarOf : Expr id -> Maybe Vars.Variable
tvarOf expr =
    (metaOf expr).tvar


{-| A reference to a top-level definition in a module.
-}
type Global
    = Global ModuleName.Canonical Name


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


{-| A cheap structural hash of a `Global`, for `Data.HashMap` keys.

Mechanical twin of `Monomorphized.globalHash` (deliberately duplicated —
`Monomorphized` imports this module, so the hash cannot be shared from there).
Like that one it hashes the NAME char-by-char but takes only the LENGTHS of the
canonical's parts: the module path is what makes `toComparableGlobal` expensive
to build, and reading three lengths keeps this far cheaper than the ~25-50-char
comparable string it replaces. Collisions are resolved by `Data.HashMap`'s
per-bucket `eq`, so a coarse hash costs performance, never correctness.

-}
globalHash : Global -> Int
globalHash g =
    case g of
        Global (ModuleName.Canonical ( author, project ) modName) name ->
            -- WIDE. This value is only ever a `Data.HashMap` bucket key, and
            -- that map keys its buckets in a `Dict Int` on the RAW hash — no
            -- mask, no `modBy`, no `Bitwise` — so the full i64 range is legal
            -- and the extra width simply shortens buckets. Nothing packs this
            -- hash with another (contrast `Monomorphized.stringHash`, which
            -- feeds `packHashes` and must stay inside `[0, 2^26)`).
            Eco.Hash.string64
                (globalMixHash
                    (globalMixHash (globalMixHash 21 (String.length author)) (String.length project))
                    (String.length modName)
                )
                name


globalMixHash : Int -> Int -> Int
globalMixHash h x =
    -- 2^26, matching Monomorphized.hashBase: two of these pack into 2^52,
    -- inside the exact-integer range of both the native i64 and the JS double.
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)


{-| Create a global reference to a kernel function.
-}
toKernelGlobal : Name.Name -> Global
toKernelGlobal shortName =
    Global (ModuleName.Canonical Pkg.kernel shortName) Name.dollar



-- ====== DEFINITIONS ======


{-| A local definition, either a simple value or a tail-recursive function.
-}
type Def id
    = Def A.Region Name (Expr id) (Can.Type id) -- name, body, type of the definition
    | TailDef A.Region Name (List ( A.Located Name, Can.Type id )) (Expr id) (Can.Type id) (Maybe Vars.Variable) -- name, typed args, body, type of the definition, tvar


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
    = GlobalGraph (Data.Map.Dict String Global (Node id)) (Dict Name Int) (AnnotationsByGlobal id) SchemeRootsByGlobal (Dict Name Vars.SuperType)



-- Include annotations for the whole graph


{-| Data structure for a single module's dependency graph.
-}
type alias LocalGraphData id =
    { main : Maybe (Main id)
    , nodes : Data.Map.Dict String Global (Node id)
    , fields : Dict Name Int
    , annotations : Annotations id
    , schemeRoots : Dict Name (Dict Name Vars.RootedVar)
    , varSupers : Dict Name Vars.SuperType
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
        ( strs, tb ) =
            prePassGlobal graph

        st : StringTable
        st =
            StringTable.build strs

        tt : TypeTable
        tt =
            TypeTable.freeze tb
    in
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 typedGraphFormatVersion
        , StringTable.tableEncoder st
        , TypeTable.encoder st tt
        , BE.assocListDict (globalEncoderS st) (nodeEncoderS st tt) nodes
        , BE.assocListDict (globalEncoderS st) (annotationEncoderT st tt) annotations
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
                            TypeTable.decoder st
                                |> Bytes.Decode.andThen
                                    (\tdt ->
                                        Bytes.Decode.map4
                                            (\nodes annotations allSchemeRoots varSupers ->
                                                GlobalGraph nodes Dict.empty annotations allSchemeRoots varSupers
                                            )
                                            (BD.assocListDict toComparableGlobal (globalDecoderS st) (nodeDecoderS st tdt))
                                            (BD.assocListDict toComparableGlobal (globalDecoderS st) (annotationDecoderT st tdt))
                                            (globalSchemeRootsDecoderS st)
                                            (varSupersDecoderS st)
                                    )
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
        ( strs, tb ) =
            prePassLocal graph

        st : StringTable
        st =
            StringTable.build strs

        tt : TypeTable
        tt =
            TypeTable.freeze tb
    in
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 typedGraphFormatVersion
        , StringTable.tableEncoder st
        , TypeTable.encoder st tt
        , BE.assocListDict (globalEncoderS st) (nodeEncoderS st tt) data.nodes
        , BE.stdDict (StringTable.string st) (annotationEncoderT st tt) data.annotations
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
                            TypeTable.decoder st
                                |> Bytes.Decode.andThen
                                    (\tdt ->
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
                                            (BD.assocListDict toComparableGlobal (globalDecoderS st) (nodeDecoderS st tdt))
                                            (BD.stdDict (StringTable.stringDec st) (annotationDecoderT st tdt))
                                            (schemeRootsDecoderS st)
                                            (varSupersDecoderS st)
                                    )
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


metaEncoderS : TypeTable -> Meta Name -> Bytes.Encode.Encoder
metaEncoderS tt meta =
    TypeTable.ref tt meta.tipe


{-| An annotation in the v2 body: its free variables, then a type reference.
-}
annotationEncoderT : StringTable -> TypeTable -> Can.Annotation Name -> Bytes.Encode.Encoder
annotationEncoderT st tt (Can.Forall freeVars tipe) =
    Bytes.Encode.sequence
        [ Can.freeVarsEncoderS st freeVars
        , TypeTable.ref tt tipe
        ]


annotationDecoderT : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Can.Annotation Name)
annotationDecoderT st tdt =
    Bytes.Decode.map2 Can.Forall
        (Can.freeVarsDecoderS st)
        (TypeTable.refDecoder tdt)


metaDecoderS : TypeTable.Decoded -> Bytes.Decode.Decoder (Meta Name)
metaDecoderS tdt =
    Bytes.Decode.map (\t -> { tipe = t, tvar = Nothing }) (TypeTable.refDecoder tdt)


{-| Encode a Node. Per ECOT\_001 in design\_docs/invariants.csv, the per-Node
deps sets (Define, TrackedDefine, Cycle, Kernel, PortIncoming, PortOutgoing),
Manager's EffectsType byte, and Kernel's chunks list are NOT serialized; they
are reconstructed as `EverySet.empty` / `Cmd` / `[]` on decode.
-}
nodeEncoderS : StringTable -> TypeTable -> Node Name -> Bytes.Encode.Encoder
nodeEncoderS st tt node =
    case node of
        Define expr _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoderS st tt expr
                , TypeTable.ref tt meta.tipe
                ]

        TrackedDefine region expr _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoderV region
                , exprEncoderS st tt expr
                , TypeTable.ref tt meta.tipe
                ]

        Ctor index arity tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoderV index
                , BE.uintV arity
                , TypeTable.ref tt tipe
                ]

        Enum index tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Index.zeroBasedEncoderV index
                , TypeTable.ref tt tipe
                ]

        Box tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , TypeTable.ref tt tipe
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
                , BE.list (BE.jsonPair (StringTable.string st) (exprEncoderS st tt)) values
                , BE.list (defEncoderS st tt) functions
                ]

        Manager _ ->
            Bytes.Encode.unsignedInt8 8

        Kernel _ _ ->
            Bytes.Encode.unsignedInt8 9

        PortIncoming decoder _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , exprEncoderS st tt decoder
                , TypeTable.ref tt meta.tipe
                ]

        PortOutgoing encoder _ meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoderS st tt encoder
                , TypeTable.ref tt meta.tipe
                ]


nodeDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Node Name)
nodeDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 (\expr meta -> Define expr Data.Set.empty meta)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    1 ->
                        Bytes.Decode.map3 (\region expr meta -> TrackedDefine region expr Data.Set.empty meta)
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    3 ->
                        Bytes.Decode.map3 Ctor
                            Index.zeroBasedDecoderV
                            BD.uintV
                            (TypeTable.refDecoder tdt)

                    4 ->
                        Bytes.Decode.map2 Enum
                            Index.zeroBasedDecoderV
                            (TypeTable.refDecoder tdt)

                    5 ->
                        Bytes.Decode.map Box (TypeTable.refDecoder tdt)

                    6 ->
                        Bytes.Decode.map Link (globalDecoderS st)

                    7 ->
                        Bytes.Decode.map3 (\names values funcs -> Cycle names values funcs Data.Set.empty)
                            (BD.list (StringTable.stringDec st))
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (exprDecoderS st tdt)))
                            (BD.list (defDecoderS st tdt))

                    8 ->
                        Bytes.Decode.succeed (Manager Cmd)

                    9 ->
                        Bytes.Decode.succeed (Kernel [] Data.Set.empty)

                    10 ->
                        Bytes.Decode.map2 (\expr meta -> PortIncoming expr Data.Set.empty meta)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    11 ->
                        Bytes.Decode.map2 (\expr meta -> PortOutgoing expr Data.Set.empty meta)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    _ ->
                        Bytes.Decode.fail
            )


typedLocatedNameEncoderS : StringTable -> TypeTable -> ( A.Located Name, Can.Type Name ) -> Bytes.Encode.Encoder
typedLocatedNameEncoderS st tt ( locName, tipe ) =
    Bytes.Encode.sequence
        [ A.locatedEncoder (StringTable.string st) locName
        , TypeTable.ref tt tipe
        ]


typedLocatedNameDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder ( A.Located Name, Can.Type Name )
typedLocatedNameDecoderS st tdt =
    Bytes.Decode.map2 Tuple.pair
        (A.locatedDecoder (StringTable.stringDec st))
        (TypeTable.refDecoder tdt)


typedNameEncoderS : StringTable -> TypeTable -> ( Name, Can.Type Name ) -> Bytes.Encode.Encoder
typedNameEncoderS st tt ( name, tipe ) =
    Bytes.Encode.sequence
        [ StringTable.string st name
        , TypeTable.ref tt tipe
        ]


typedNameDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder ( Name, Can.Type Name )
typedNameDecoderS st tdt =
    Bytes.Decode.map2 Tuple.pair
        (StringTable.stringDec st)
        (TypeTable.refDecoder tdt)


exprEncoderS : StringTable -> TypeTable -> Expr Name -> Bytes.Encode.Encoder
exprEncoderS st tt expr =
    case expr of
        Bool region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoderV region
                , BE.bool value
                , TypeTable.ref tt meta.tipe
                ]

        Chr region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoderV region
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        Str region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoderV region
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        Int region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoderV region
                , BE.int64 value -- exact i64 (v3); BE.int is a float64
                , TypeTable.ref tt meta.tipe
                ]

        Float region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , A.regionEncoderV region
                , BE.float value
                , TypeTable.ref tt meta.tipe
                ]

        VarLocal value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        TrackedVarLocal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoderV region
                , StringTable.string st value
                , TypeTable.ref tt meta.tipe
                ]

        VarGlobal region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoderV region
                , globalEncoderS st value
                , TypeTable.ref tt meta.tipe
                ]

        VarEnum region global index meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , A.regionEncoderV region
                , globalEncoderS st global
                , Index.zeroBasedEncoderV index
                , TypeTable.ref tt meta.tipe
                ]

        VarBox region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoderV region
                , globalEncoderS st value
                , TypeTable.ref tt meta.tipe
                ]

        VarCycle region home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , A.regionEncoderV region
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , TypeTable.ref tt meta.tipe
                ]

        VarDebug region name _ _ meta ->
            -- Per ECOT_001: home and unhandledValueName are NOT serialized.
            -- They are reconstructed on decode as (ModuleName.Canonical Pkg.core Name.debug)
            -- and Nothing respectively; Specialize hardcodes "Elm" "Debug" anyway.
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , A.regionEncoderV region
                , StringTable.string st name
                , TypeTable.ref tt meta.tipe
                ]

        VarKernel region kernelPrefix home name meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , A.regionEncoderV region
                , StringTable.string st kernelPrefix
                , StringTable.string st home
                , StringTable.string st name
                , TypeTable.ref tt meta.tipe
                ]

        List region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , A.regionEncoderV region
                , BE.list (exprEncoderS st tt) value
                , TypeTable.ref tt meta.tipe
                ]

        Function _ args body meta ->
            -- srcLambda is NOT persisted (the Meta.tvar precedent): the wire
            -- format is unchanged, the decoder fills Nothing, and ids are
            -- re-stamped per run by AssignMVarIds (LSS_003).
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list (typedNameEncoderS st tt) args
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        TrackedFunction _ args body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.list (typedLocatedNameEncoderS st tt) args
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        Call region func args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , A.regionEncoderV region
                , exprEncoderS st tt func
                , BE.list (exprEncoderS st tt) args
                , TypeTable.ref tt meta.tipe
                ]

        TailCall name args meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , StringTable.string st name
                , BE.list (BE.jsonPair (StringTable.string st) (exprEncoderS st tt)) args
                , TypeTable.ref tt meta.tipe
                ]

        If branches final meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list (BE.jsonPair (exprEncoderS st tt) (exprEncoderS st tt)) branches
                , exprEncoderS st tt final
                , TypeTable.ref tt meta.tipe
                ]

        Let def body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , defEncoderS st tt def
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        Destruct destructor body meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , destructorEncoderS st tt destructor
                , exprEncoderS st tt body
                , TypeTable.ref tt meta.tipe
                ]

        Case label root decider jumps meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , StringTable.string st label
                , StringTable.string st root
                , deciderEncoderS st (choiceEncoderS st tt) decider
                , BE.list (BE.jsonPair BE.uintV (exprEncoderS st tt)) jumps
                , TypeTable.ref tt meta.tipe
                ]

        Accessor region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , A.regionEncoderV region
                , StringTable.string st field
                , TypeTable.ref tt meta.tipe
                ]

        Access record region field meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoderS st tt record
                , A.regionEncoderV region
                , StringTable.string st field
                , TypeTable.ref tt meta.tipe
                ]

        Update region record fields meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , A.regionEncoderV region
                , exprEncoderS st tt record
                , BE.assocListDict (A.locatedEncoder (StringTable.string st)) (exprEncoderS st tt) fields
                , TypeTable.ref tt meta.tipe
                ]

        Record value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 25
                , BE.stdDict (StringTable.string st) (exprEncoderS st tt) value
                , TypeTable.ref tt meta.tipe
                ]

        TrackedRecord region value meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , A.regionEncoderV region
                , BE.assocListDict (A.locatedEncoder (StringTable.string st)) (exprEncoderS st tt) value
                , TypeTable.ref tt meta.tipe
                ]

        Unit meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 27
                , TypeTable.ref tt meta.tipe
                ]

        Tuple region a b cs meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 28
                , A.regionEncoderV region
                , exprEncoderS st tt a
                , exprEncoderS st tt b
                , BE.list (exprEncoderS st tt) cs
                , TypeTable.ref tt meta.tipe
                ]

        Shader src attributes uniforms meta ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 29
                , Shader.sourceEncoderS st src
                , BE.everySet (StringTable.string st) attributes
                , BE.everySet (StringTable.string st) uniforms
                , TypeTable.ref tt meta.tipe
                ]


exprDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Expr Name)
exprDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Bool
                            A.regionDecoderV
                            BD.bool
                            (metaDecoderS tdt)

                    1 ->
                        Bytes.Decode.map3 Chr
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    2 ->
                        Bytes.Decode.map3 Str
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    3 ->
                        Bytes.Decode.map3 Int
                            A.regionDecoderV
                            BD.int64
                            (metaDecoderS tdt)

                    4 ->
                        Bytes.Decode.map3 Float
                            A.regionDecoderV
                            BD.float
                            (metaDecoderS tdt)

                    5 ->
                        Bytes.Decode.map2 VarLocal
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    6 ->
                        Bytes.Decode.map3 TrackedVarLocal
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    7 ->
                        Bytes.Decode.map3 VarGlobal
                            A.regionDecoderV
                            (globalDecoderS st)
                            (metaDecoderS tdt)

                    8 ->
                        Bytes.Decode.map4 VarEnum
                            A.regionDecoderV
                            (globalDecoderS st)
                            Index.zeroBasedDecoderV
                            (metaDecoderS tdt)

                    9 ->
                        Bytes.Decode.map3 VarBox
                            A.regionDecoderV
                            (globalDecoderS st)
                            (metaDecoderS tdt)

                    10 ->
                        Bytes.Decode.map4 VarCycle
                            A.regionDecoderV
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    11 ->
                        -- Per ECOT_001: reconstruct home and unhandledValueName locally.
                        Bytes.Decode.map3
                            (\region name meta ->
                                VarDebug region name (ModuleName.Canonical Pkg.core Name.debug) Nothing meta
                            )
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    12 ->
                        Bytes.Decode.map5 VarKernel
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    13 ->
                        Bytes.Decode.map3 List
                            A.regionDecoderV
                            (BD.list (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    14 ->
                        Bytes.Decode.map3 (Function Nothing)
                            (BD.list (typedNameDecoderS st tdt))
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    15 ->
                        Bytes.Decode.map3 (TrackedFunction Nothing)
                            (BD.list (typedLocatedNameDecoderS st tdt))
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    16 ->
                        Bytes.Decode.map4 Call
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (BD.list (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    17 ->
                        Bytes.Decode.map3 TailCall
                            (StringTable.stringDec st)
                            (BD.list (BD.jsonPair (StringTable.stringDec st) (exprDecoderS st tdt)))
                            (metaDecoderS tdt)

                    18 ->
                        Bytes.Decode.map3 If
                            (BD.list (BD.jsonPair (exprDecoderS st tdt) (exprDecoderS st tdt)))
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    19 ->
                        Bytes.Decode.map3 Let
                            (defDecoderS st tdt)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    20 ->
                        Bytes.Decode.map3 Destruct
                            (destructorDecoderS st tdt)
                            (exprDecoderS st tdt)
                            (metaDecoderS tdt)

                    21 ->
                        Bytes.Decode.map5 Case
                            (StringTable.stringDec st)
                            (StringTable.stringDec st)
                            (deciderDecoderS st (choiceDecoderS st tdt))
                            (BD.list (BD.jsonPair BD.uintV (exprDecoderS st tdt)))
                            (metaDecoderS tdt)

                    22 ->
                        Bytes.Decode.map3 Accessor
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    23 ->
                        Bytes.Decode.map4 Access
                            (exprDecoderS st tdt)
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (metaDecoderS tdt)

                    24 ->
                        Bytes.Decode.map4 Update
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (BD.assocListDict A.toValue (A.locatedDecoder (StringTable.stringDec st)) (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    25 ->
                        Bytes.Decode.map2 Record
                            (BD.stdDict (StringTable.stringDec st) (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    26 ->
                        Bytes.Decode.map3 TrackedRecord
                            A.regionDecoderV
                            (BD.assocListDict A.toValue (A.locatedDecoder (StringTable.stringDec st)) (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    27 ->
                        Bytes.Decode.map Unit (metaDecoderS tdt)

                    28 ->
                        Bytes.Decode.map5 Tuple
                            A.regionDecoderV
                            (exprDecoderS st tdt)
                            (exprDecoderS st tdt)
                            (BD.list (exprDecoderS st tdt))
                            (metaDecoderS tdt)

                    29 ->
                        Bytes.Decode.map4 Shader
                            (Shader.sourceDecoderS st)
                            (BD.everySet identity (StringTable.stringDec st))
                            (BD.everySet identity (StringTable.stringDec st))
                            (metaDecoderS tdt)

                    _ ->
                        Bytes.Decode.fail
            )


defEncoderS : StringTable -> TypeTable -> Def Name -> Bytes.Encode.Encoder
defEncoderS st tt def =
    case def of
        Def region name expr tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoderV region
                , StringTable.string st name
                , exprEncoderS st tt expr
                , TypeTable.ref tt tipe
                ]

        TailDef region name args expr tipe maybeTvar ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoderV region
                , StringTable.string st name
                , BE.list (typedLocatedNameEncoderS st tt) args
                , exprEncoderS st tt expr
                , TypeTable.ref tt tipe
                , case maybeTvar of
                    Nothing ->
                        Bytes.Encode.unsignedInt8 0

                    Just (Vars.Pt n) ->
                        Bytes.Encode.sequence
                            [ Bytes.Encode.unsignedInt8 1
                            , Bytes.Encode.signedInt32 Bytes.BE n
                            ]
                ]


defDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Def Name)
defDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 Def
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (exprDecoderS st tdt)
                            (TypeTable.refDecoder tdt)

                    1 ->
                        Bytes.Decode.map5 TailDef
                            A.regionDecoderV
                            (StringTable.stringDec st)
                            (BD.list (typedLocatedNameDecoderS st tdt))
                            (exprDecoderS st tdt)
                            (TypeTable.refDecoder tdt)
                            |> Bytes.Decode.andThen
                                (\tailDefFn ->
                                    Bytes.Decode.unsignedInt8
                                        |> Bytes.Decode.andThen
                                            (\tag ->
                                                case tag of
                                                    0 ->
                                                        Bytes.Decode.succeed (tailDefFn Nothing)

                                                    _ ->
                                                        Bytes.Decode.map (\n -> tailDefFn (Just (Vars.Pt n)))
                                                            (Bytes.Decode.signedInt32 Bytes.BE)
                                            )
                                )

                    _ ->
                        Bytes.Decode.fail
            )


destructorEncoderS : StringTable -> TypeTable -> Destructor Name -> Bytes.Encode.Encoder
destructorEncoderS st tt (Destructor name path meta) =
    Bytes.Encode.sequence
        [ StringTable.string st name
        , pathEncoderS st path
        , metaEncoderS tt meta
        ]


destructorDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Destructor Name)
destructorDecoderS st tdt =
    Bytes.Decode.map3 Destructor
        (StringTable.stringDec st)
        (pathDecoderS st)
        (metaDecoderS tdt)


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


choiceEncoderS : StringTable -> TypeTable -> Choice Name -> Bytes.Encode.Encoder
choiceEncoderS st tt choice =
    case choice of
        Inline value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoderS st tt value
                ]

        Jump value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.uintV value
                ]


choiceDecoderS : StringTable -> TypeTable.Decoded -> Bytes.Decode.Decoder (Choice Name)
choiceDecoderS st tdt =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Inline (exprDecoderS st tdt)

                    1 ->
                        Bytes.Decode.map Jump BD.uintV

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
                , Index.zeroBasedEncoderV index
                , containerHintEncoderS st hint
                , pathEncoderS st subPath
                ]

        ArrayIndex index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.uintV index
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
                            Index.zeroBasedDecoderV
                            (containerHintDecoderS st)
                            (pathDecoderS st)

                    1 ->
                        Bytes.Decode.map2 ArrayIndex
                            BD.uintV
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
    3


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


variableEncoder : Vars.Variable -> Bytes.Encode.Encoder
variableEncoder (Vars.Pt idx) =
    Bytes.Encode.signedInt32 Bytes.BE idx


variableDecoder : Bytes.Decode.Decoder Vars.Variable
variableDecoder =
    Bytes.Decode.map Vars.Pt (Bytes.Decode.signedInt32 Bytes.BE)


{-| Encode an optional super constraint as one byte (0 = none).
-}
maybeSuperToByte : Maybe Vars.SuperType -> Int
maybeSuperToByte ms =
    case ms of
        Nothing ->
            0

        Just Vars.Number ->
            1

        Just Vars.Comparable ->
            2

        Just Vars.Appendable ->
            3

        Just Vars.CompAppend ->
            4


byteToMaybeSuper : Int -> Maybe Vars.SuperType
byteToMaybeSuper b =
    case b of
        1 ->
            Just Vars.Number

        2 ->
            Just Vars.Comparable

        3 ->
            Just Vars.Appendable

        4 ->
            Just Vars.CompAppend

        _ ->
            Nothing


rootedVarEncoder : Vars.RootedVar -> Bytes.Encode.Encoder
rootedVarEncoder rv =
    Bytes.Encode.sequence
        [ variableEncoder rv.var
        , Bytes.Encode.unsignedInt8 (maybeSuperToByte rv.super)
        ]


rootedVarDecoder : Bytes.Decode.Decoder Vars.RootedVar
rootedVarDecoder =
    Bytes.Decode.map2 (\v b -> { var = v, super = byteToMaybeSuper b })
        variableDecoder
        Bytes.Decode.unsignedInt8


schemeRootsForDefEncoderS : StringTable -> Dict Name Vars.RootedVar -> Bytes.Encode.Encoder
schemeRootsForDefEncoderS st roots =
    BE.stdDict (StringTable.string st) rootedVarEncoder roots


schemeRootsForDefDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name Vars.RootedVar)
schemeRootsForDefDecoderS st =
    BD.stdDict (StringTable.stringDec st) rootedVarDecoder


schemeRootsEncoderS : StringTable -> Dict Name (Dict Name Vars.RootedVar) -> Bytes.Encode.Encoder
schemeRootsEncoderS st allRoots =
    BE.stdDict (StringTable.string st) (schemeRootsForDefEncoderS st) allRoots


schemeRootsDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name (Dict Name Vars.RootedVar))
schemeRootsDecoderS st =
    BD.stdDict (StringTable.stringDec st) (schemeRootsForDefDecoderS st)



-- ====== VAR SUPERS ENCODERS/DECODERS ======


superValueEncoder : Vars.SuperType -> Bytes.Encode.Encoder
superValueEncoder s =
    Bytes.Encode.unsignedInt8 (maybeSuperToByte (Just s))


superValueDecoder : Bytes.Decode.Decoder Vars.SuperType
superValueDecoder =
    Bytes.Decode.map (\b -> Maybe.withDefault Vars.Number (byteToMaybeSuper b)) Bytes.Decode.unsignedInt8


varSupersEncoderS : StringTable -> Dict Name Vars.SuperType -> Bytes.Encode.Encoder
varSupersEncoderS st vs =
    BE.stdDict (StringTable.string st) superValueEncoder vs


varSupersDecoderS : StringTable -> Bytes.Decode.Decoder (Dict Name Vars.SuperType)
varSupersDecoderS st =
    BD.stdDict (StringTable.stringDec st) superValueDecoder


globalSchemeRootsEncoderS : StringTable -> SchemeRootsByGlobal -> Bytes.Encode.Encoder
globalSchemeRootsEncoderS st allRoots =
    BE.assocListDict (globalEncoderS st) (schemeRootsForDefEncoderS st) allRoots


globalSchemeRootsDecoderS : StringTable -> Bytes.Decode.Decoder SchemeRootsByGlobal
globalSchemeRootsDecoderS st =
    BD.assocListDict toComparableGlobal (globalDecoderS st) (schemeRootsForDefDecoderS st)



-- ====== STRING COLLECTORS (ECOT_002) ======


{-| Collect strings emitted by `localGraphEncoder`'s body into a set.
-}
collectStringsFromLocalGraph : LocalGraph Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromLocalGraph (LocalGraph data) acc =
    acc
        |> (\a -> Data.Map.foldl collectStringsFromGlobalNodePair a data.nodes)
        |> (\a -> Dict.foldl collectStringsFromAnnotationPair a data.annotations)
        |> collectStringsFromSchemeRoots data.schemeRoots
        |> (\a -> Dict.foldl (\k _ a2 -> StringTable.add k a2) a data.varSupers)


{-| Collect strings emitted by `globalGraphEncoder`'s body into a set.
-}
collectStringsFromGlobalGraph : GlobalGraph Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalGraph (GlobalGraph nodes _ annotations allSchemeRoots varSupers) acc =
    acc
        |> (\a -> Data.Map.foldl collectStringsFromGlobalNodePair a nodes)
        |> (\a -> Data.Map.foldl collectStringsFromGlobalAnnotationPair a annotations)
        |> collectStringsFromGlobalSchemeRoots allSchemeRoots
        |> (\a -> Dict.foldl (\k _ a2 -> StringTable.add k a2) a varSupers)


collectStringsFromGlobalNodePair : Global -> Node Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalNodePair g node acc =
    acc
        |> collectStringsFromGlobal g
        |> collectStringsFromNode node


collectStringsFromAnnotationPair : Name -> Can.Annotation Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromAnnotationPair name (Can.Forall freeVars _) acc =
    acc
        |> StringTable.add name
        |> collectStringsFromFreeVars freeVars


collectStringsFromGlobalAnnotationPair : Global -> Can.Annotation Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalAnnotationPair g (Can.Forall freeVars _) acc =
    acc
        |> collectStringsFromGlobal g
        |> collectStringsFromFreeVars freeVars


{-| Annotation types live in the type table; only the free-var keys are body strings.
-}
collectStringsFromFreeVars : Can.FreeVars -> StringTable.Collector -> StringTable.Collector
collectStringsFromFreeVars freeVars acc =
    Dict.foldl (\k _ a -> StringTable.add k a) acc freeVars


collectStringsFromSchemeRoots : Dict Name (Dict Name Vars.RootedVar) -> StringTable.Collector -> StringTable.Collector
collectStringsFromSchemeRoots roots acc =
    Dict.foldl
        (\k inner a ->
            Dict.foldl (\k2 _ a2 -> StringTable.add k2 a2) (StringTable.add k a) inner
        )
        acc
        roots


collectStringsFromGlobalSchemeRoots : SchemeRootsByGlobal -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalSchemeRoots roots acc =
    Data.Map.foldl
        (\g inner a ->
            Dict.foldl (\k _ a2 -> StringTable.add k a2) (collectStringsFromGlobal g a) inner
        )
        acc
        roots



-- ====== TYPE-TABLE PRE-PASS (ECOT_003) ======


{-| One walk feeding both tables of a local graph: intern every type the
encoder references (`TypeTable.ref`), then collect the body strings plus the
strings of the DISTINCT table entries. The `internTypesFrom*` walkers MUST
visit exactly the type positions the encoders emit; a missed one crashes in
`TypeTable.ref`.
-}
prePassLocal : LocalGraph Name -> ( Set String, TypeTable.Builder )
prePassLocal graph =
    let
        tb : TypeTable.Builder
        tb =
            internTypesFromLocalGraph graph TypeTable.empty
    in
    ( StringTable.collected (TypeTable.collectStrings tb (collectStringsFromLocalGraph graph StringTable.collectAll))
    , tb
    )


{-| Global-graph twin of `prePassLocal`.
-}
prePassGlobal : GlobalGraph Name -> ( Set String, TypeTable.Builder )
prePassGlobal graph =
    let
        tb : TypeTable.Builder
        tb =
            internTypesFromGlobalGraph graph TypeTable.empty
    in
    ( StringTable.collected (TypeTable.collectStrings tb (collectStringsFromGlobalGraph graph StringTable.collectAll))
    , tb
    )


internTypesFromLocalGraph : LocalGraph Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromLocalGraph (LocalGraph data) tb =
    tb
        |> (\b -> Data.Map.foldl (\_ node b2 -> internTypesFromNode node b2) b data.nodes)
        |> (\b -> Dict.foldl (\_ (Can.Forall _ t) b2 -> TypeTable.add t b2) b data.annotations)


internTypesFromGlobalGraph : GlobalGraph Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromGlobalGraph (GlobalGraph nodes _ annotations _ _) tb =
    tb
        |> (\b -> Data.Map.foldl (\_ node b2 -> internTypesFromNode node b2) b nodes)
        |> (\b -> Data.Map.foldl (\_ (Can.Forall _ t) b2 -> TypeTable.add t b2) b annotations)


internTypesFromNode : Node Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromNode node tb =
    case node of
        Define expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe

        TrackedDefine _ expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe

        Ctor _ _ tipe ->
            TypeTable.add tipe tb

        Enum _ tipe ->
            TypeTable.add tipe tb

        Box tipe ->
            TypeTable.add tipe tb

        Link _ ->
            tb

        Cycle _ values funcs _ ->
            List.foldl internTypesFromDef
                (List.foldl (\( _, e ) b -> internTypesFromExpr e b) tb values)
                funcs

        Manager _ ->
            tb

        Kernel _ _ ->
            tb

        PortIncoming expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe

        PortOutgoing expr _ meta ->
            tb |> internTypesFromExpr expr |> TypeTable.add meta.tipe


internTypesFromDef : Def Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromDef def tb =
    case def of
        Def _ _ expr tipe ->
            tb |> internTypesFromExpr expr |> TypeTable.add tipe

        TailDef _ _ args expr tipe _ ->
            List.foldl (\( _, t ) b -> TypeTable.add t b) tb args
                |> internTypesFromExpr expr
                |> TypeTable.add tipe


internTypesFromExpr : Expr Name -> TypeTable.Builder -> TypeTable.Builder
internTypesFromExpr expr tb =
    case expr of
        List _ values meta ->
            List.foldl internTypesFromExpr (TypeTable.add meta.tipe tb) values

        Function _ args body meta ->
            List.foldl (\( _, t ) b -> TypeTable.add t b) tb args
                |> internTypesFromExpr body
                |> TypeTable.add meta.tipe

        TrackedFunction _ args body meta ->
            List.foldl (\( _, t ) b -> TypeTable.add t b) tb args
                |> internTypesFromExpr body
                |> TypeTable.add meta.tipe

        Call _ func args meta ->
            List.foldl internTypesFromExpr
                (tb |> internTypesFromExpr func |> TypeTable.add meta.tipe)
                args

        TailCall _ args meta ->
            List.foldl (\( _, e ) b -> internTypesFromExpr e b) (TypeTable.add meta.tipe tb) args

        If branches final meta ->
            List.foldl
                (\( c, e ) b -> b |> internTypesFromExpr c |> internTypesFromExpr e)
                (tb |> internTypesFromExpr final |> TypeTable.add meta.tipe)
                branches

        Let def body meta ->
            tb |> internTypesFromDef def |> internTypesFromExpr body |> TypeTable.add meta.tipe

        Destruct (Destructor _ _ dmeta) body meta ->
            tb |> TypeTable.add dmeta.tipe |> internTypesFromExpr body |> TypeTable.add meta.tipe

        Case _ _ decider jumps meta ->
            List.foldl (\( _, e ) b -> internTypesFromExpr e b)
                (internTypesFromDecider decider tb)
                jumps
                |> TypeTable.add meta.tipe

        Access record _ _ meta ->
            tb |> internTypesFromExpr record |> TypeTable.add meta.tipe

        Update _ record fields meta ->
            Data.Map.foldl
                (\_ e b -> internTypesFromExpr e b)
                (internTypesFromExpr record tb)
                fields
                |> TypeTable.add meta.tipe

        Record value meta ->
            Dict.foldl (\_ e b -> internTypesFromExpr e b) tb value
                |> TypeTable.add meta.tipe

        TrackedRecord _ value meta ->
            Data.Map.foldl (\_ e b -> internTypesFromExpr e b) tb value
                |> TypeTable.add meta.tipe

        Tuple _ a b cs meta ->
            List.foldl internTypesFromExpr
                (tb |> internTypesFromExpr a |> internTypesFromExpr b |> TypeTable.add meta.tipe)
                cs

        _ ->
            TypeTable.add (typeOf expr) tb


internTypesFromDecider : Decider (Choice Name) -> TypeTable.Builder -> TypeTable.Builder
internTypesFromDecider decider tb =
    case decider of
        Leaf (Inline value) ->
            internTypesFromExpr value tb

        Leaf (Jump _) ->
            tb

        Chain _ success failure ->
            tb |> internTypesFromDecider success |> internTypesFromDecider failure

        FanOut _ edges fallback ->
            List.foldl (\( _, d ) b -> internTypesFromDecider d b) tb edges
                |> internTypesFromDecider fallback



-- ====== VAR SUPERS COMPUTATION ======


{-| The single name→super ingestion point for persisted typed graphs.

Maps the surface-syntax type-variable naming convention (`number*`,
`comparable*`, `appendable*`, `compappend*`) to a structured super constraint.
This is the ONLY place the name convention is read into the persisted-graph
channel; monomorphization consumes the resulting `varSupers` / `RootedVar.super`
data, never the names themselves. Mirrors `Compiler.Type.Type.toSuper`.

-}



-- `StringTable.isSuperName` MUST stay the exact disjunction of the `Just`
-- cases below: the varSupers sweep runs the collectors in `collectSupers` mode.


superOfName : Name -> Maybe Vars.SuperType
superOfName name =
    if Name.isNumberType name then
        Just Vars.Number

    else if Name.isComparableType name then
        Just Vars.Comparable

    else if Name.isAppendableType name then
        Just Vars.Appendable

    else if Name.isCompappendType name then
        Just Vars.CompAppend

    else
        Nothing


insertSuperOfName : Name -> Dict Name Vars.SuperType -> Dict Name Vars.SuperType
insertSuperOfName name acc =
    case superOfName name of
        Just s ->
            Dict.insert name s acc

        Nothing ->
            acc


{-| Compute the `varSupers` map for a finished local graph by sweeping every
name it emits and keeping those that carry a super constraint. Complete by
construction: it reuses the encoder's pre-pass (body collector plus the type
table's distinct entries, ECOT\_003), so every type variable in the graph is
covered.
-}
computeVarSupers : LocalGraph Name -> Dict Name Vars.SuperType
computeVarSupers graph =
    let
        tb : TypeTable.Builder
        tb =
            internTypesFromLocalGraph graph TypeTable.empty
    in
    Set.foldl insertSuperOfName
        Dict.empty
        (StringTable.collected
            (TypeTable.collectStrings tb (collectStringsFromLocalGraph graph StringTable.collectSupers))
        )


{-| Compute a `varSupers` map for a single standalone canonical type (used by
`AssignMVarIds.assignIdsToType`, the test-only single-type entry point).
-}
varSupersOfType : Can.Type Name -> Dict Name Vars.SuperType
varSupersOfType tipe =
    Set.foldl insertSuperOfName
        Dict.empty
        (StringTable.collected (Can.collectStringsFromType tipe StringTable.collectSupers))


collectStringsFromGlobal : Global -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobal (Global home name) acc =
    acc
        |> ModuleName.collectStringsFromCanonical home
        |> StringTable.add name


collectStringsFromNode : Node Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromNode node acc =
    case node of
        Define expr _ _ ->
            acc |> collectStringsFromExpr expr

        TrackedDefine _ expr _ _ ->
            acc |> collectStringsFromExpr expr

        Ctor _ _ _ ->
            acc

        Enum _ _ ->
            acc

        Box _ ->
            acc

        Link g ->
            collectStringsFromGlobal g acc

        Cycle names values funcs _ ->
            let
                withNames : StringTable.Collector
                withNames =
                    List.foldl StringTable.add acc names

                withValues : StringTable.Collector
                withValues =
                    List.foldl
                        (\( n, e ) a -> a |> StringTable.add n |> collectStringsFromExpr e)
                        withNames
                        values
            in
            List.foldl collectStringsFromDef withValues funcs

        Manager _ ->
            acc

        Kernel _ _ ->
            acc

        PortIncoming expr _ _ ->
            acc |> collectStringsFromExpr expr

        PortOutgoing expr _ _ ->
            acc |> collectStringsFromExpr expr


collectStringsFromDef : Def Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromDef def acc =
    case def of
        Def _ name expr _ ->
            acc
                |> StringTable.add name
                |> collectStringsFromExpr expr

        TailDef _ name args expr _ _ ->
            let
                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( locName, _ ) a ->
                            a |> StringTable.add (A.toValue locName)
                        )
                        (StringTable.add name acc)
                        args
            in
            withArgs |> collectStringsFromExpr expr


collectStringsFromExpr : Expr Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromExpr expr acc =
    case expr of
        Bool _ _ _ ->
            acc

        Chr _ value _ ->
            acc |> StringTable.add value

        Str _ value _ ->
            acc |> StringTable.add value

        Int _ _ _ ->
            acc

        Float _ _ _ ->
            acc

        VarLocal value _ ->
            acc |> StringTable.add value

        TrackedVarLocal _ value _ ->
            acc |> StringTable.add value

        VarGlobal _ g _ ->
            acc |> collectStringsFromGlobal g

        VarEnum _ g _ _ ->
            acc |> collectStringsFromGlobal g

        VarBox _ g _ ->
            acc |> collectStringsFromGlobal g

        VarCycle _ home name _ ->
            acc
                |> ModuleName.collectStringsFromCanonical home
                |> StringTable.add name

        VarDebug _ name _ _ _ ->
            acc |> StringTable.add name

        VarKernel _ kp home name _ ->
            acc
                |> StringTable.add kp
                |> StringTable.add home
                |> StringTable.add name

        List _ values _ ->
            List.foldl collectStringsFromExpr acc values

        Function _ args body _ ->
            let
                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( n, _ ) a -> StringTable.add n a)
                        acc
                        args
            in
            withArgs |> collectStringsFromExpr body

        TrackedFunction _ args body _ ->
            let
                withArgs : StringTable.Collector
                withArgs =
                    List.foldl
                        (\( locN, _ ) a ->
                            a |> StringTable.add (A.toValue locN)
                        )
                        acc
                        args
            in
            withArgs |> collectStringsFromExpr body

        Call _ func args _ ->
            List.foldl collectStringsFromExpr
                (acc |> collectStringsFromExpr func)
                args

        TailCall name args _ ->
            List.foldl
                (\( n, e ) a -> a |> StringTable.add n |> collectStringsFromExpr e)
                (acc |> StringTable.add name)
                args

        If branches final _ ->
            List.foldl
                (\( c, b ) a -> a |> collectStringsFromExpr c |> collectStringsFromExpr b)
                (acc |> collectStringsFromExpr final)
                branches

        Let def body _ ->
            acc
                |> collectStringsFromDef def
                |> collectStringsFromExpr body

        Destruct destructor body _ ->
            acc
                |> collectStringsFromDestructor destructor
                |> collectStringsFromExpr body

        Case label root decider jumps _ ->
            let
                withLabels : StringTable.Collector
                withLabels =
                    acc |> StringTable.add label |> StringTable.add root

                withDecider : StringTable.Collector
                withDecider =
                    collectStringsFromDecider collectStringsFromChoice decider withLabels
            in
            List.foldl (\( _, e ) a -> collectStringsFromExpr e a) withDecider jumps

        Accessor _ field _ ->
            acc |> StringTable.add field

        Access record _ field _ ->
            acc
                |> collectStringsFromExpr record
                |> StringTable.add field

        Update _ record fields _ ->
            let
                withRecord : StringTable.Collector
                withRecord =
                    collectStringsFromExpr record acc
            in
            Data.Map.foldl
                (\locN e a ->
                    a |> StringTable.add (A.toValue locN) |> collectStringsFromExpr e
                )
                withRecord
                fields

        Record value _ ->
            Dict.foldl
                (\k e a -> a |> StringTable.add k |> collectStringsFromExpr e)
                acc
                value

        TrackedRecord _ value _ ->
            Data.Map.foldl
                (\locN e a ->
                    a |> StringTable.add (A.toValue locN) |> collectStringsFromExpr e
                )
                acc
                value

        Unit _ ->
            acc

        Tuple _ a b cs _ ->
            List.foldl collectStringsFromExpr
                (acc
                    |> collectStringsFromExpr a
                    |> collectStringsFromExpr b
                )
                cs

        Shader src attributes uniforms _ ->
            let
                withSrc : StringTable.Collector
                withSrc =
                    Shader.collectStringsFromSource src acc

                withAttrs : StringTable.Collector
                withAttrs =
                    Data.Set.foldr StringTable.add withSrc attributes
            in
            Data.Set.foldr StringTable.add withAttrs uniforms


collectStringsFromDestructor : Destructor Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromDestructor (Destructor name path _) acc =
    acc
        |> StringTable.add name
        |> collectStringsFromPath path


collectStringsFromPath : Path -> StringTable.Collector -> StringTable.Collector
collectStringsFromPath path acc =
    case path of
        Index _ hint subPath ->
            acc |> collectStringsFromContainerHint hint |> collectStringsFromPath subPath

        ArrayIndex _ subPath ->
            collectStringsFromPath subPath acc

        Field field subPath ->
            acc |> StringTable.add field |> collectStringsFromPath subPath

        Unbox subPath ->
            collectStringsFromPath subPath acc

        Root name ->
            StringTable.add name acc


collectStringsFromContainerHint : ContainerHint -> StringTable.Collector -> StringTable.Collector
collectStringsFromContainerHint hint acc =
    case hint of
        HintCustom ctorName ->
            StringTable.add ctorName acc

        _ ->
            acc


collectStringsFromDecider : (a -> StringTable.Collector -> StringTable.Collector) -> Decider a -> StringTable.Collector -> StringTable.Collector
collectStringsFromDecider collectInner decider acc =
    case decider of
        Leaf value ->
            collectInner value acc

        Chain testChain success failure ->
            let
                withTests : StringTable.Collector
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
                withPath : StringTable.Collector
                withPath =
                    DT.collectStringsFromPath path acc

                withEdges : StringTable.Collector
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


collectStringsFromChoice : Choice Name -> StringTable.Collector -> StringTable.Collector
collectStringsFromChoice choice acc =
    case choice of
        Inline value ->
            collectStringsFromExpr value acc

        Jump _ ->
            acc
