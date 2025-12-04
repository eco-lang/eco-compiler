module Compiler.AST.TypedOptimized exposing
    ( Annotations
    , Choice(..)
    , Decider(..)
    , Def(..)
    , Destructor(..)
    , EffectsType(..)
    , Expr(..)
    , Global(..)
    , GlobalGraph(..)
    , LocalGraph(..)
    , Main(..)
    , Node(..)
    , Path(..)
    , addGlobalGraph
    , addLocalGraph
    , compareGlobal
    , empty
    , emptyGlobalGraph
    , emptyLocalGraph
    , globalGraphDecoder
    , globalGraphEncoder
    , localGraphDecoder
    , localGraphEncoder
    , toComparableGlobal
    , toKernelGlobal
    , typeOf
    )

{-| TypedOptimized AST - like Optimized but preserves type information.

This IR is used for backends that need type information for code generation,
such as the MLIR backend which performs monomorphization.

The key difference from Optimized:

  - Every Expr carries its Can.Type
  - Nodes carry type information for definitions
  - LocalGraph includes the full annotations dictionary

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Kernel as K
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Optimize.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- TYPE ALIASES


{-| Annotations dictionary - maps definition names to their type schemes
-}
type alias Annotations =
    Dict String Name Can.Annotation



-- EXPRESSIONS
-- Every expression variant carries its type as the LAST argument


type Expr
    = Bool A.Region Bool Can.Type
    | Chr A.Region String Can.Type
    | Str A.Region String Can.Type
    | Int A.Region Int Can.Type
    | Float A.Region Float Can.Type
    | VarLocal Name Can.Type
    | TrackedVarLocal A.Region Name Can.Type
    | VarGlobal A.Region Global Can.Type
    | VarEnum A.Region Global Index.ZeroBased Can.Type
    | VarBox A.Region Global Can.Type
    | VarCycle A.Region IO.Canonical Name Can.Type
    | VarDebug A.Region Name IO.Canonical (Maybe Name) Can.Type
    | VarKernel A.Region Name Name Can.Type
    | List A.Region (List Expr) Can.Type
    | Function (List ( Name, Can.Type )) Expr Can.Type -- params with types, body, function type
    | TrackedFunction (List ( A.Located Name, Can.Type )) Expr Can.Type
    | Call A.Region Expr (List Expr) Can.Type
    | TailCall Name (List ( Name, Expr )) Can.Type
    | If (List ( Expr, Expr )) Expr Can.Type
    | Let Def Expr Can.Type
    | Destruct Destructor Expr Can.Type
    | Case Name Name (Decider Choice) (List ( Int, Expr )) Can.Type
    | Accessor A.Region Name Can.Type
    | Access Expr A.Region Name Can.Type
    | Update A.Region Expr (Dict String (A.Located Name) Expr) Can.Type
    | Record (Dict String Name Expr) Can.Type
    | TrackedRecord A.Region (Dict String (A.Located Name) Expr) Can.Type
    | Unit Can.Type
    | Tuple A.Region Expr Expr (List Expr) Can.Type
    | Shader Shader.Source (EverySet String Name) (EverySet String Name) Can.Type


{-| Extract the type from any expression
-}
typeOf : Expr -> Can.Type
typeOf expr =
    case expr of
        Bool _ _ t ->
            t

        Chr _ _ t ->
            t

        Str _ _ t ->
            t

        Int _ _ t ->
            t

        Float _ _ t ->
            t

        VarLocal _ t ->
            t

        TrackedVarLocal _ _ t ->
            t

        VarGlobal _ _ t ->
            t

        VarEnum _ _ _ t ->
            t

        VarBox _ _ t ->
            t

        VarCycle _ _ _ t ->
            t

        VarDebug _ _ _ _ t ->
            t

        VarKernel _ _ _ t ->
            t

        List _ _ t ->
            t

        Function _ _ t ->
            t

        TrackedFunction _ _ t ->
            t

        Call _ _ _ t ->
            t

        TailCall _ _ t ->
            t

        If _ _ t ->
            t

        Let _ _ t ->
            t

        Destruct _ _ t ->
            t

        Case _ _ _ _ t ->
            t

        Accessor _ _ t ->
            t

        Access _ _ _ t ->
            t

        Update _ _ _ t ->
            t

        Record _ t ->
            t

        TrackedRecord _ _ t ->
            t

        Unit t ->
            t

        Tuple _ _ _ _ t ->
            t

        Shader _ _ _ t ->
            t


type Global
    = Global IO.Canonical Name


compareGlobal : Global -> Global -> Order
compareGlobal (Global home1 name1) (Global home2 name2) =
    case compare name1 name2 of
        LT ->
            LT

        EQ ->
            ModuleName.compareCanonical home1 home2

        GT ->
            GT


toComparableGlobal : Global -> List String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ [ name ]


toKernelGlobal : Name.Name -> Global
toKernelGlobal shortName =
    Global (IO.Canonical Pkg.kernel shortName) Name.dollar



-- DEFINITIONS


type Def
    = Def A.Region Name Expr Can.Type -- name, body, type of the definition
    | TailDef A.Region Name (List ( A.Located Name, Can.Type )) Expr Can.Type -- name, typed args, body, return type


type Destructor
    = Destructor Name Path Can.Type -- name, path, type of destructured value



-- Note: Path doesn't need types - it's just navigation


type Path
    = Index Index.ZeroBased Path
    | ArrayIndex Int Path
    | Field Name Path
    | Unbox Path
    | Root Name



-- BRANCHING


type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)


type Choice
    = Inline Expr
    | Jump Int



-- OBJECT GRAPH


type GlobalGraph
    = GlobalGraph
        (Dict (List String) Global Node)
        (Dict String Name Int)
        Annotations -- Include annotations for the whole graph


type LocalGraph
    = LocalGraph
        (Maybe Main)
        (Dict (List String) Global Node)
        (Dict String Name Int)
        Annotations -- Include annotations for this module


type Main
    = Static
    | Dynamic Can.Type Expr


type Node
    = Define Expr (EverySet (List String) Global) Can.Type -- body, deps, type
    | TrackedDefine A.Region Expr (EverySet (List String) Global) Can.Type
    | DefineTailFunc A.Region (List ( A.Located Name, Can.Type )) Expr (EverySet (List String) Global) Can.Type -- typed args, body, deps, return type
    | Ctor Index.ZeroBased Int Can.Type -- index, arity, constructor type
    | Enum Index.ZeroBased Can.Type
    | Box Can.Type
    | Link Global
    | Cycle (List Name) (List ( Name, Expr )) (List Def) (EverySet (List String) Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet (List String) Global)
    | PortIncoming Expr (EverySet (List String) Global) Can.Type
    | PortOutgoing Expr (EverySet (List String) Global) Can.Type


type EffectsType
    = Cmd
    | Sub
    | Fx



-- GRAPHS


empty : GlobalGraph
empty =
    GlobalGraph Dict.empty Dict.empty Dict.empty


emptyGlobalGraph : GlobalGraph
emptyGlobalGraph =
    GlobalGraph Dict.empty Dict.empty Dict.empty


emptyLocalGraph : LocalGraph
emptyLocalGraph =
    LocalGraph Nothing Dict.empty Dict.empty Dict.empty


addGlobalGraph : GlobalGraph -> GlobalGraph -> GlobalGraph
addGlobalGraph (GlobalGraph nodes1 fields1 ann1) (GlobalGraph nodes2 fields2 ann2) =
    GlobalGraph
        (Dict.union nodes1 nodes2)
        (Dict.union fields1 fields2)
        (Dict.union ann1 ann2)


addLocalGraph : LocalGraph -> GlobalGraph -> GlobalGraph
addLocalGraph (LocalGraph _ nodes1 fields1 ann1) (GlobalGraph nodes2 fields2 ann2) =
    GlobalGraph
        (Dict.union nodes1 nodes2)
        (Dict.union fields1 fields2)
        (Dict.union ann1 ann2)



-- ENCODERS and DECODERS


globalGraphEncoder : GlobalGraph -> BE.Encoder
globalGraphEncoder (GlobalGraph nodes fields annotations) =
    BE.sequence
        [ BE.assocListDict compareGlobal globalEncoder nodeEncoder nodes
        , BE.assocListDict compare BE.string BE.int fields
        , BE.assocListDict compare BE.string Can.annotationEncoder annotations
        ]


globalGraphDecoder : BD.Decoder GlobalGraph
globalGraphDecoder =
    BD.map3 GlobalGraph
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.assocListDict identity BD.string BD.int)
        (BD.assocListDict identity BD.string Can.annotationDecoder)


localGraphEncoder : LocalGraph -> BE.Encoder
localGraphEncoder (LocalGraph main nodes fields annotations) =
    BE.sequence
        [ BE.maybe mainEncoder main
        , BE.assocListDict compareGlobal globalEncoder nodeEncoder nodes
        , BE.assocListDict compare BE.string BE.int fields
        , BE.assocListDict compare BE.string Can.annotationEncoder annotations
        ]


localGraphDecoder : BD.Decoder LocalGraph
localGraphDecoder =
    BD.map4 LocalGraph
        (BD.maybe mainDecoder)
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.assocListDict identity BD.string BD.int)
        (BD.assocListDict identity BD.string Can.annotationDecoder)


mainEncoder : Main -> BE.Encoder
mainEncoder main_ =
    case main_ of
        Static ->
            BE.unsignedInt8 0

        Dynamic msgType decoder ->
            BE.sequence
                [ BE.unsignedInt8 1
                , Can.typeEncoder msgType
                , exprEncoder decoder
                ]


mainDecoder : BD.Decoder Main
mainDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.succeed Static

                    1 ->
                        BD.map2 Dynamic
                            Can.typeDecoder
                            exprDecoder

                    _ ->
                        BD.fail
            )


globalEncoder : Global -> BE.Encoder
globalEncoder (Global home name) =
    BE.sequence
        [ ModuleName.canonicalEncoder home
        , BE.string name
        ]


globalDecoder : BD.Decoder Global
globalDecoder =
    BD.map2 Global
        ModuleName.canonicalDecoder
        BD.string


nodeEncoder : Node -> BE.Encoder
nodeEncoder node =
    case node of
        Define expr deps tipe ->
            BE.sequence
                [ BE.unsignedInt8 0
                , exprEncoder expr
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder tipe
                ]

        TrackedDefine region expr deps tipe ->
            BE.sequence
                [ BE.unsignedInt8 1
                , A.regionEncoder region
                , exprEncoder expr
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder tipe
                ]

        DefineTailFunc region argNames body deps tipe ->
            BE.sequence
                [ BE.unsignedInt8 2
                , A.regionEncoder region
                , BE.list typedLocatedNameEncoder argNames
                , exprEncoder body
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder tipe
                ]

        Ctor index arity tipe ->
            BE.sequence
                [ BE.unsignedInt8 3
                , Index.zeroBasedEncoder index
                , BE.int arity
                , Can.typeEncoder tipe
                ]

        Enum index tipe ->
            BE.sequence
                [ BE.unsignedInt8 4
                , Index.zeroBasedEncoder index
                , Can.typeEncoder tipe
                ]

        Box tipe ->
            BE.sequence
                [ BE.unsignedInt8 5
                , Can.typeEncoder tipe
                ]

        Link linkedGlobal ->
            BE.sequence
                [ BE.unsignedInt8 6
                , globalEncoder linkedGlobal
                ]

        Cycle names values functions deps ->
            BE.sequence
                [ BE.unsignedInt8 7
                , BE.list BE.string names
                , BE.list (BE.jsonPair BE.string exprEncoder) values
                , BE.list defEncoder functions
                , BE.everySet compareGlobal globalEncoder deps
                ]

        Manager effectsType ->
            BE.sequence
                [ BE.unsignedInt8 8
                , effectsTypeEncoder effectsType
                ]

        Kernel chunks deps ->
            BE.sequence
                [ BE.unsignedInt8 9
                , BE.list K.chunkEncoder chunks
                , BE.everySet compareGlobal globalEncoder deps
                ]

        PortIncoming decoder deps tipe ->
            BE.sequence
                [ BE.unsignedInt8 10
                , exprEncoder decoder
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder tipe
                ]

        PortOutgoing encoder deps tipe ->
            BE.sequence
                [ BE.unsignedInt8 11
                , exprEncoder encoder
                , BE.everySet compareGlobal globalEncoder deps
                , Can.typeEncoder tipe
                ]


nodeDecoder : BD.Decoder Node
nodeDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map3 Define
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            Can.typeDecoder

                    1 ->
                        BD.map4 TrackedDefine
                            A.regionDecoder
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            Can.typeDecoder

                    2 ->
                        BD.map5 DefineTailFunc
                            A.regionDecoder
                            (BD.list typedLocatedNameDecoder)
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            Can.typeDecoder

                    3 ->
                        BD.map3 Ctor
                            Index.zeroBasedDecoder
                            BD.int
                            Can.typeDecoder

                    4 ->
                        BD.map2 Enum
                            Index.zeroBasedDecoder
                            Can.typeDecoder

                    5 ->
                        BD.map Box Can.typeDecoder

                    6 ->
                        BD.map Link globalDecoder

                    7 ->
                        BD.map4 Cycle
                            (BD.list BD.string)
                            (BD.list (BD.jsonPair BD.string exprDecoder))
                            (BD.list defDecoder)
                            (BD.everySet toComparableGlobal globalDecoder)

                    8 ->
                        BD.map Manager effectsTypeDecoder

                    9 ->
                        BD.map2 Kernel
                            (BD.list K.chunkDecoder)
                            (BD.everySet toComparableGlobal globalDecoder)

                    10 ->
                        BD.map3 PortIncoming
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            Can.typeDecoder

                    11 ->
                        BD.map3 PortOutgoing
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)
                            Can.typeDecoder

                    _ ->
                        BD.fail
            )


typedLocatedNameEncoder : ( A.Located Name, Can.Type ) -> BE.Encoder
typedLocatedNameEncoder ( locName, tipe ) =
    BE.sequence
        [ A.locatedEncoder BE.string locName
        , Can.typeEncoder tipe
        ]


typedLocatedNameDecoder : BD.Decoder ( A.Located Name, Can.Type )
typedLocatedNameDecoder =
    BD.map2 Tuple.pair
        (A.locatedDecoder BD.string)
        Can.typeDecoder


typedNameEncoder : ( Name, Can.Type ) -> BE.Encoder
typedNameEncoder ( name, tipe ) =
    BE.sequence
        [ BE.string name
        , Can.typeEncoder tipe
        ]


typedNameDecoder : BD.Decoder ( Name, Can.Type )
typedNameDecoder =
    BD.map2 Tuple.pair
        BD.string
        Can.typeDecoder


exprEncoder : Expr -> BE.Encoder
exprEncoder expr =
    case expr of
        Bool region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 0
                , A.regionEncoder region
                , BE.bool value
                , Can.typeEncoder tipe
                ]

        Chr region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 1
                , A.regionEncoder region
                , BE.string value
                , Can.typeEncoder tipe
                ]

        Str region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 2
                , A.regionEncoder region
                , BE.string value
                , Can.typeEncoder tipe
                ]

        Int region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 3
                , A.regionEncoder region
                , BE.int value
                , Can.typeEncoder tipe
                ]

        Float region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 4
                , A.regionEncoder region
                , BE.float value
                , Can.typeEncoder tipe
                ]

        VarLocal value tipe ->
            BE.sequence
                [ BE.unsignedInt8 5
                , BE.string value
                , Can.typeEncoder tipe
                ]

        TrackedVarLocal region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 6
                , A.regionEncoder region
                , BE.string value
                , Can.typeEncoder tipe
                ]

        VarGlobal region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 7
                , A.regionEncoder region
                , globalEncoder value
                , Can.typeEncoder tipe
                ]

        VarEnum region global index tipe ->
            BE.sequence
                [ BE.unsignedInt8 8
                , A.regionEncoder region
                , globalEncoder global
                , Index.zeroBasedEncoder index
                , Can.typeEncoder tipe
                ]

        VarBox region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 9
                , A.regionEncoder region
                , globalEncoder value
                , Can.typeEncoder tipe
                ]

        VarCycle region home name tipe ->
            BE.sequence
                [ BE.unsignedInt8 10
                , A.regionEncoder region
                , ModuleName.canonicalEncoder home
                , BE.string name
                , Can.typeEncoder tipe
                ]

        VarDebug region name home unhandledValueName tipe ->
            BE.sequence
                [ BE.unsignedInt8 11
                , A.regionEncoder region
                , BE.string name
                , ModuleName.canonicalEncoder home
                , BE.maybe BE.string unhandledValueName
                , Can.typeEncoder tipe
                ]

        VarKernel region home name tipe ->
            BE.sequence
                [ BE.unsignedInt8 12
                , A.regionEncoder region
                , BE.string home
                , BE.string name
                , Can.typeEncoder tipe
                ]

        List region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 13
                , A.regionEncoder region
                , BE.list exprEncoder value
                , Can.typeEncoder tipe
                ]

        Function args body tipe ->
            BE.sequence
                [ BE.unsignedInt8 14
                , BE.list typedNameEncoder args
                , exprEncoder body
                , Can.typeEncoder tipe
                ]

        TrackedFunction args body tipe ->
            BE.sequence
                [ BE.unsignedInt8 15
                , BE.list typedLocatedNameEncoder args
                , exprEncoder body
                , Can.typeEncoder tipe
                ]

        Call region func args tipe ->
            BE.sequence
                [ BE.unsignedInt8 16
                , A.regionEncoder region
                , exprEncoder func
                , BE.list exprEncoder args
                , Can.typeEncoder tipe
                ]

        TailCall name args tipe ->
            BE.sequence
                [ BE.unsignedInt8 17
                , BE.string name
                , BE.list (BE.jsonPair BE.string exprEncoder) args
                , Can.typeEncoder tipe
                ]

        If branches final tipe ->
            BE.sequence
                [ BE.unsignedInt8 18
                , BE.list (BE.jsonPair exprEncoder exprEncoder) branches
                , exprEncoder final
                , Can.typeEncoder tipe
                ]

        Let def body tipe ->
            BE.sequence
                [ BE.unsignedInt8 19
                , defEncoder def
                , exprEncoder body
                , Can.typeEncoder tipe
                ]

        Destruct destructor body tipe ->
            BE.sequence
                [ BE.unsignedInt8 20
                , destructorEncoder destructor
                , exprEncoder body
                , Can.typeEncoder tipe
                ]

        Case label root decider jumps tipe ->
            BE.sequence
                [ BE.unsignedInt8 21
                , BE.string label
                , BE.string root
                , deciderEncoder choiceEncoder decider
                , BE.list (BE.jsonPair BE.int exprEncoder) jumps
                , Can.typeEncoder tipe
                ]

        Accessor region field tipe ->
            BE.sequence
                [ BE.unsignedInt8 22
                , A.regionEncoder region
                , BE.string field
                , Can.typeEncoder tipe
                ]

        Access record region field tipe ->
            BE.sequence
                [ BE.unsignedInt8 23
                , exprEncoder record
                , A.regionEncoder region
                , BE.string field
                , Can.typeEncoder tipe
                ]

        Update region record fields tipe ->
            BE.sequence
                [ BE.unsignedInt8 24
                , A.regionEncoder region
                , exprEncoder record
                , BE.assocListDict A.compareLocated (A.locatedEncoder BE.string) exprEncoder fields
                , Can.typeEncoder tipe
                ]

        Record value tipe ->
            BE.sequence
                [ BE.unsignedInt8 25
                , BE.assocListDict compare BE.string exprEncoder value
                , Can.typeEncoder tipe
                ]

        TrackedRecord region value tipe ->
            BE.sequence
                [ BE.unsignedInt8 26
                , A.regionEncoder region
                , BE.assocListDict A.compareLocated (A.locatedEncoder BE.string) exprEncoder value
                , Can.typeEncoder tipe
                ]

        Unit tipe ->
            BE.sequence
                [ BE.unsignedInt8 27
                , Can.typeEncoder tipe
                ]

        Tuple region a b cs tipe ->
            BE.sequence
                [ BE.unsignedInt8 28
                , A.regionEncoder region
                , exprEncoder a
                , exprEncoder b
                , BE.list exprEncoder cs
                , Can.typeEncoder tipe
                ]

        Shader src attributes uniforms tipe ->
            BE.sequence
                [ BE.unsignedInt8 29
                , Shader.sourceEncoder src
                , BE.everySet compare BE.string attributes
                , BE.everySet compare BE.string uniforms
                , Can.typeEncoder tipe
                ]


exprDecoder : BD.Decoder Expr
exprDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map3 Bool
                            A.regionDecoder
                            BD.bool
                            Can.typeDecoder

                    1 ->
                        BD.map3 Chr
                            A.regionDecoder
                            BD.string
                            Can.typeDecoder

                    2 ->
                        BD.map3 Str
                            A.regionDecoder
                            BD.string
                            Can.typeDecoder

                    3 ->
                        BD.map3 Int
                            A.regionDecoder
                            BD.int
                            Can.typeDecoder

                    4 ->
                        BD.map3 Float
                            A.regionDecoder
                            BD.float
                            Can.typeDecoder

                    5 ->
                        BD.map2 VarLocal
                            BD.string
                            Can.typeDecoder

                    6 ->
                        BD.map3 TrackedVarLocal
                            A.regionDecoder
                            BD.string
                            Can.typeDecoder

                    7 ->
                        BD.map3 VarGlobal
                            A.regionDecoder
                            globalDecoder
                            Can.typeDecoder

                    8 ->
                        BD.map4 VarEnum
                            A.regionDecoder
                            globalDecoder
                            Index.zeroBasedDecoder
                            Can.typeDecoder

                    9 ->
                        BD.map3 VarBox
                            A.regionDecoder
                            globalDecoder
                            Can.typeDecoder

                    10 ->
                        BD.map4 VarCycle
                            A.regionDecoder
                            ModuleName.canonicalDecoder
                            BD.string
                            Can.typeDecoder

                    11 ->
                        BD.map5 VarDebug
                            A.regionDecoder
                            BD.string
                            ModuleName.canonicalDecoder
                            (BD.maybe BD.string)
                            Can.typeDecoder

                    12 ->
                        BD.map4 VarKernel
                            A.regionDecoder
                            BD.string
                            BD.string
                            Can.typeDecoder

                    13 ->
                        BD.map3 List
                            A.regionDecoder
                            (BD.list exprDecoder)
                            Can.typeDecoder

                    14 ->
                        BD.map3 Function
                            (BD.list typedNameDecoder)
                            exprDecoder
                            Can.typeDecoder

                    15 ->
                        BD.map3 TrackedFunction
                            (BD.list typedLocatedNameDecoder)
                            exprDecoder
                            Can.typeDecoder

                    16 ->
                        BD.map4 Call
                            A.regionDecoder
                            exprDecoder
                            (BD.list exprDecoder)
                            Can.typeDecoder

                    17 ->
                        BD.map3 TailCall
                            BD.string
                            (BD.list (BD.jsonPair BD.string exprDecoder))
                            Can.typeDecoder

                    18 ->
                        BD.map3 If
                            (BD.list (BD.jsonPair exprDecoder exprDecoder))
                            exprDecoder
                            Can.typeDecoder

                    19 ->
                        BD.map3 Let
                            defDecoder
                            exprDecoder
                            Can.typeDecoder

                    20 ->
                        BD.map3 Destruct
                            destructorDecoder
                            exprDecoder
                            Can.typeDecoder

                    21 ->
                        BD.map5 Case
                            BD.string
                            BD.string
                            (deciderDecoder choiceDecoder)
                            (BD.list (BD.jsonPair BD.int exprDecoder))
                            Can.typeDecoder

                    22 ->
                        BD.map3 Accessor
                            A.regionDecoder
                            BD.string
                            Can.typeDecoder

                    23 ->
                        BD.map4 Access
                            exprDecoder
                            A.regionDecoder
                            BD.string
                            Can.typeDecoder

                    24 ->
                        BD.map4 Update
                            A.regionDecoder
                            exprDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)
                            Can.typeDecoder

                    25 ->
                        BD.map2 Record
                            (BD.assocListDict identity BD.string exprDecoder)
                            Can.typeDecoder

                    26 ->
                        BD.map3 TrackedRecord
                            A.regionDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)
                            Can.typeDecoder

                    27 ->
                        BD.map Unit Can.typeDecoder

                    28 ->
                        BD.map5 Tuple
                            A.regionDecoder
                            exprDecoder
                            exprDecoder
                            (BD.list exprDecoder)
                            Can.typeDecoder

                    29 ->
                        BD.map4 Shader
                            Shader.sourceDecoder
                            (BD.everySet identity BD.string)
                            (BD.everySet identity BD.string)
                            Can.typeDecoder

                    _ ->
                        BD.fail
            )


defEncoder : Def -> BE.Encoder
defEncoder def =
    case def of
        Def region name expr tipe ->
            BE.sequence
                [ BE.unsignedInt8 0
                , A.regionEncoder region
                , BE.string name
                , exprEncoder expr
                , Can.typeEncoder tipe
                ]

        TailDef region name args expr tipe ->
            BE.sequence
                [ BE.unsignedInt8 1
                , A.regionEncoder region
                , BE.string name
                , BE.list typedLocatedNameEncoder args
                , exprEncoder expr
                , Can.typeEncoder tipe
                ]


defDecoder : BD.Decoder Def
defDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map4 Def
                            A.regionDecoder
                            BD.string
                            exprDecoder
                            Can.typeDecoder

                    1 ->
                        BD.map5 TailDef
                            A.regionDecoder
                            BD.string
                            (BD.list typedLocatedNameDecoder)
                            exprDecoder
                            Can.typeDecoder

                    _ ->
                        BD.fail
            )


destructorEncoder : Destructor -> BE.Encoder
destructorEncoder (Destructor name path tipe) =
    BE.sequence
        [ BE.string name
        , pathEncoder path
        , Can.typeEncoder tipe
        ]


destructorDecoder : BD.Decoder Destructor
destructorDecoder =
    BD.map3 Destructor
        BD.string
        pathDecoder
        Can.typeDecoder


deciderEncoder : (a -> BE.Encoder) -> Decider a -> BE.Encoder
deciderEncoder encoder decider =
    case decider of
        Leaf value ->
            BE.sequence
                [ BE.unsignedInt8 0
                , encoder value
                ]

        Chain testChain success failure ->
            BE.sequence
                [ BE.unsignedInt8 1
                , BE.list (BE.jsonPair DT.pathEncoder DT.testEncoder) testChain
                , deciderEncoder encoder success
                , deciderEncoder encoder failure
                ]

        FanOut path edges fallback ->
            BE.sequence
                [ BE.unsignedInt8 2
                , DT.pathEncoder path
                , BE.list (BE.jsonPair DT.testEncoder (deciderEncoder encoder)) edges
                , deciderEncoder encoder fallback
                ]


deciderDecoder : BD.Decoder a -> BD.Decoder (Decider a)
deciderDecoder decoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map Leaf decoder

                    1 ->
                        BD.map3 Chain
                            (BD.list (BD.jsonPair DT.pathDecoder DT.testDecoder))
                            (deciderDecoder decoder)
                            (deciderDecoder decoder)

                    2 ->
                        BD.map3 FanOut
                            DT.pathDecoder
                            (BD.list (BD.jsonPair DT.testDecoder (deciderDecoder decoder)))
                            (deciderDecoder decoder)

                    _ ->
                        BD.fail
            )


choiceEncoder : Choice -> BE.Encoder
choiceEncoder choice =
    case choice of
        Inline value ->
            BE.sequence
                [ BE.unsignedInt8 0
                , exprEncoder value
                ]

        Jump value ->
            BE.sequence
                [ BE.unsignedInt8 1
                , BE.int value
                ]


choiceDecoder : BD.Decoder Choice
choiceDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map Inline exprDecoder

                    1 ->
                        BD.map Jump BD.int

                    _ ->
                        BD.fail
            )


pathEncoder : Path -> BE.Encoder
pathEncoder path =
    case path of
        Index index subPath ->
            BE.sequence
                [ BE.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , pathEncoder subPath
                ]

        ArrayIndex index subPath ->
            BE.sequence
                [ BE.unsignedInt8 1
                , BE.int index
                , pathEncoder subPath
                ]

        Field field subPath ->
            BE.sequence
                [ BE.unsignedInt8 2
                , BE.string field
                , pathEncoder subPath
                ]

        Unbox subPath ->
            BE.sequence
                [ BE.unsignedInt8 3
                , pathEncoder subPath
                ]

        Root name ->
            BE.sequence
                [ BE.unsignedInt8 4
                , BE.string name
                ]


pathDecoder : BD.Decoder Path
pathDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.map2 Index
                            Index.zeroBasedDecoder
                            pathDecoder

                    1 ->
                        BD.map2 ArrayIndex
                            BD.int
                            pathDecoder

                    2 ->
                        BD.map2 Field
                            BD.string
                            pathDecoder

                    3 ->
                        BD.map Unbox pathDecoder

                    4 ->
                        BD.map Root BD.string

                    _ ->
                        BD.fail
            )


effectsTypeEncoder : EffectsType -> BE.Encoder
effectsTypeEncoder effectsType =
    BE.unsignedInt8
        (case effectsType of
            Cmd ->
                0

            Sub ->
                1

            Fx ->
                2
        )


effectsTypeDecoder : BD.Decoder EffectsType
effectsTypeDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\idx ->
                case idx of
                    0 ->
                        BD.succeed Cmd

                    1 ->
                        BD.succeed Sub

                    2 ->
                        BD.succeed Fx

                    _ ->
                        BD.fail
            )
