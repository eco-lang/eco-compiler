module Compiler.AST.Optimized exposing
    ( Choice(..)
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
    , addKernel
    , addLocalGraph
    , compareGlobal
    , empty
    , globalGraphDecoder
    , globalGraphEncoder
    , localGraphDecoder
    , localGraphEncoder
    , toComparableGlobal
    , toKernelGlobal
    )

import Bytes.Decode
import Bytes.Encode
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



-- EXPRESSIONS


type Expr
    = Bool A.Region Bool
    | Chr A.Region String
    | Str A.Region String
    | Int A.Region Int
    | Float A.Region Float
    | VarLocal Name
    | TrackedVarLocal A.Region Name
    | VarGlobal A.Region Global
    | VarEnum A.Region Global Index.ZeroBased
    | VarBox A.Region Global
    | VarCycle A.Region IO.Canonical Name
    | VarDebug A.Region Name IO.Canonical (Maybe Name)
    | VarKernel A.Region Name Name
    | List A.Region (List Expr)
    | Function (List Name) Expr
    | TrackedFunction (List (A.Located Name)) Expr
    | Call A.Region Expr (List Expr)
    | TailCall Name (List ( Name, Expr ))
    | If (List ( Expr, Expr )) Expr
    | Let Def Expr
    | Destruct Destructor Expr
    | Case Name Name (Decider Choice) (List ( Int, Expr ))
    | Accessor A.Region Name
    | Access Expr A.Region Name
    | Update A.Region Expr (Dict String (A.Located Name) Expr)
    | Record (Dict String Name Expr)
    | TrackedRecord A.Region (Dict String (A.Located Name) Expr)
    | Unit
    | Tuple A.Region Expr Expr (List Expr)
    | Shader Shader.Source (EverySet String Name) (EverySet String Name)


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



-- DEFINITIONS


type Def
    = Def A.Region Name Expr
    | TailDef A.Region Name (List (A.Located Name)) Expr


type Destructor
    = Destructor Name Path


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
    = GlobalGraph (Dict (List String) Global Node) (Dict String Name Int)


type LocalGraph
    = LocalGraph
        (Maybe Main)
        -- PERF profile switching Global to Name
        (Dict (List String) Global Node)
        (Dict String Name Int)


type Main
    = Static
    | Dynamic Can.Type Expr


type Node
    = Define Expr (EverySet (List String) Global)
    | TrackedDefine A.Region Expr (EverySet (List String) Global)
    | DefineTailFunc A.Region (List (A.Located Name)) Expr (EverySet (List String) Global)
    | Ctor Index.ZeroBased Int
    | Enum Index.ZeroBased
    | Box
    | Link Global
    | Cycle (List Name) (List ( Name, Expr )) (List Def) (EverySet (List String) Global)
    | Manager EffectsType
    | Kernel (List K.Chunk) (EverySet (List String) Global)
    | PortIncoming Expr (EverySet (List String) Global)
    | PortOutgoing Expr (EverySet (List String) Global)


type EffectsType
    = Cmd
    | Sub
    | Fx



-- GRAPHS


empty : GlobalGraph
empty =
    GlobalGraph Dict.empty Dict.empty


addGlobalGraph : GlobalGraph -> GlobalGraph -> GlobalGraph
addGlobalGraph (GlobalGraph nodes1 fields1) (GlobalGraph nodes2 fields2) =
    GlobalGraph
        (Dict.union nodes1 nodes2)
        (Dict.union fields1 fields2)


addLocalGraph : LocalGraph -> GlobalGraph -> GlobalGraph
addLocalGraph (LocalGraph _ nodes1 fields1) (GlobalGraph nodes2 fields2) =
    GlobalGraph
        (Dict.union nodes1 nodes2)
        (Dict.union fields1 fields2)


addKernel : Name -> List K.Chunk -> GlobalGraph -> GlobalGraph
addKernel shortName chunks (GlobalGraph nodes fields) =
    let
        global : Global
        global =
            toKernelGlobal shortName

        node : Node
        node =
            Kernel chunks (List.foldr addKernelDep EverySet.empty chunks)
    in
    GlobalGraph
        (Dict.insert toComparableGlobal global node nodes)
        (Dict.union (K.countFields chunks) fields)


addKernelDep : K.Chunk -> EverySet (List String) Global -> EverySet (List String) Global
addKernelDep chunk deps =
    case chunk of
        K.JS _ ->
            deps

        K.ElmVar home name ->
            EverySet.insert toComparableGlobal (Global home name) deps

        K.JsVar shortName _ ->
            EverySet.insert toComparableGlobal (toKernelGlobal shortName) deps

        K.ElmField _ ->
            deps

        K.JsField _ ->
            deps

        K.JsEnum _ ->
            deps

        K.Debug ->
            deps

        K.Prod ->
            deps


toKernelGlobal : Name.Name -> Global
toKernelGlobal shortName =
    Global (IO.Canonical Pkg.kernel shortName) Name.dollar



-- ENCODERS and DECODERS


globalGraphEncoder : GlobalGraph -> Bytes.Encode.Encoder
globalGraphEncoder (GlobalGraph nodes fields) =
    Bytes.Encode.sequence
        [ BE.assocListDict compareGlobal globalEncoder nodeEncoder nodes
        , BE.assocListDict compare BE.string BE.int fields
        ]


globalGraphDecoder : Bytes.Decode.Decoder GlobalGraph
globalGraphDecoder =
    Bytes.Decode.map2 GlobalGraph
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.assocListDict identity BD.string BD.int)


localGraphEncoder : LocalGraph -> Bytes.Encode.Encoder
localGraphEncoder (LocalGraph main nodes fields) =
    Bytes.Encode.sequence
        [ BE.maybe mainEncoder main
        , BE.assocListDict compareGlobal globalEncoder nodeEncoder nodes
        , BE.assocListDict compare BE.string BE.int fields
        ]


localGraphDecoder : Bytes.Decode.Decoder LocalGraph
localGraphDecoder =
    Bytes.Decode.map3 LocalGraph
        (BD.maybe mainDecoder)
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.assocListDict identity BD.string BD.int)


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


nodeEncoder : Node -> Bytes.Encode.Encoder
nodeEncoder node =
    case node of
        Define expr deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , exprEncoder expr
                , BE.everySet compareGlobal globalEncoder deps
                ]

        TrackedDefine region expr deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , exprEncoder expr
                , BE.everySet compareGlobal globalEncoder deps
                ]

        DefineTailFunc region argNames body deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.list (A.locatedEncoder BE.string) argNames
                , exprEncoder body
                , BE.everySet compareGlobal globalEncoder deps
                ]

        Ctor index arity ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoder index
                , BE.int arity
                ]

        Enum index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , Index.zeroBasedEncoder index
                ]

        Box ->
            Bytes.Encode.unsignedInt8 5

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

        PortIncoming decoder deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , exprEncoder decoder
                , BE.everySet compareGlobal globalEncoder deps
                ]

        PortOutgoing encoder deps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoder encoder
                , BE.everySet compareGlobal globalEncoder deps
                ]


nodeDecoder : Bytes.Decode.Decoder Node
nodeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Define
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    1 ->
                        Bytes.Decode.map3 TrackedDefine
                            A.regionDecoder
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    2 ->
                        Bytes.Decode.map4 DefineTailFunc
                            A.regionDecoder
                            (BD.list (A.locatedDecoder BD.string))
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    3 ->
                        Bytes.Decode.map2 Ctor
                            Index.zeroBasedDecoder
                            BD.int

                    4 ->
                        Bytes.Decode.map Enum
                            Index.zeroBasedDecoder

                    5 ->
                        Bytes.Decode.succeed Box

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
                        Bytes.Decode.map2 PortIncoming
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    11 ->
                        Bytes.Decode.map2 PortOutgoing
                            exprDecoder
                            (BD.everySet toComparableGlobal globalDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder expr =
    case expr of
        Bool region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.bool value
                ]

        Chr region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string value
                ]

        Str region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string value
                ]

        Int region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoder region
                , BE.int value
                ]

        Float region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , A.regionEncoder region
                , BE.float value
                ]

        VarLocal value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.string value
                ]

        TrackedVarLocal region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoder region
                , BE.string value
                ]

        VarGlobal region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoder region
                , globalEncoder value
                ]

        VarEnum region global index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , A.regionEncoder region
                , globalEncoder global
                , Index.zeroBasedEncoder index
                ]

        VarBox region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoder region
                , globalEncoder value
                ]

        VarCycle region home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , A.regionEncoder region
                , ModuleName.canonicalEncoder home
                , BE.string name
                ]

        VarDebug region name home unhandledValueName ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , A.regionEncoder region
                , BE.string name
                , ModuleName.canonicalEncoder home
                , BE.maybe BE.string unhandledValueName
                ]

        VarKernel region home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , A.regionEncoder region
                , BE.string home
                , BE.string name
                ]

        List region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , A.regionEncoder region
                , BE.list exprEncoder value
                ]

        Function args body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list BE.string args
                , exprEncoder body
                ]

        TrackedFunction args body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.list (A.locatedEncoder BE.string) args
                , exprEncoder body
                ]

        Call region func args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , A.regionEncoder region
                , exprEncoder func
                , BE.list exprEncoder args
                ]

        TailCall name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , BE.string name
                , BE.list (BE.jsonPair BE.string exprEncoder) args
                ]

        If branches final ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list (BE.jsonPair exprEncoder exprEncoder) branches
                , exprEncoder final
                ]

        Let def body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , defEncoder def
                , exprEncoder body
                ]

        Destruct destructor body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , destructorEncoder destructor
                , exprEncoder body
                ]

        Case label root decider jumps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , BE.string label
                , BE.string root
                , deciderEncoder choiceEncoder decider
                , BE.list (BE.jsonPair BE.int exprEncoder) jumps
                ]

        Accessor region field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , A.regionEncoder region
                , BE.string field
                ]

        Access record region field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoder record
                , A.regionEncoder region
                , BE.string field
                ]

        Update region record fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , A.regionEncoder region
                , exprEncoder record
                , BE.assocListDict A.compareLocated (A.locatedEncoder BE.string) exprEncoder fields
                ]

        Record value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 25
                , BE.assocListDict compare BE.string exprEncoder value
                ]

        TrackedRecord region value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , A.regionEncoder region
                , BE.assocListDict A.compareLocated (A.locatedEncoder BE.string) exprEncoder value
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 27

        Tuple region a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 28
                , A.regionEncoder region
                , exprEncoder a
                , exprEncoder b
                , BE.list exprEncoder cs
                ]

        Shader src attributes uniforms ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 29
                , Shader.sourceEncoder src
                , BE.everySet compare BE.string attributes
                , BE.everySet compare BE.string uniforms
                ]


exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Bool
                            A.regionDecoder
                            BD.bool

                    1 ->
                        Bytes.Decode.map2 Chr
                            A.regionDecoder
                            BD.string

                    2 ->
                        Bytes.Decode.map2 Str
                            A.regionDecoder
                            BD.string

                    3 ->
                        Bytes.Decode.map2 Int
                            A.regionDecoder
                            BD.int

                    4 ->
                        Bytes.Decode.map2 Float
                            A.regionDecoder
                            BD.float

                    5 ->
                        Bytes.Decode.map VarLocal BD.string

                    6 ->
                        Bytes.Decode.map2 TrackedVarLocal
                            A.regionDecoder
                            BD.string

                    7 ->
                        Bytes.Decode.map2 VarGlobal
                            A.regionDecoder
                            globalDecoder

                    8 ->
                        Bytes.Decode.map3 VarEnum
                            A.regionDecoder
                            globalDecoder
                            Index.zeroBasedDecoder

                    9 ->
                        Bytes.Decode.map2 VarBox
                            A.regionDecoder
                            globalDecoder

                    10 ->
                        Bytes.Decode.map3 VarCycle
                            A.regionDecoder
                            ModuleName.canonicalDecoder
                            BD.string

                    11 ->
                        Bytes.Decode.map4 VarDebug
                            A.regionDecoder
                            BD.string
                            ModuleName.canonicalDecoder
                            (BD.maybe BD.string)

                    12 ->
                        Bytes.Decode.map3 VarKernel
                            A.regionDecoder
                            BD.string
                            BD.string

                    13 ->
                        Bytes.Decode.map2 List
                            A.regionDecoder
                            (BD.list exprDecoder)

                    14 ->
                        Bytes.Decode.map2 Function
                            (BD.list BD.string)
                            exprDecoder

                    15 ->
                        Bytes.Decode.map2 TrackedFunction
                            (BD.list (A.locatedDecoder BD.string))
                            exprDecoder

                    16 ->
                        Bytes.Decode.map3 Call
                            A.regionDecoder
                            exprDecoder
                            (BD.list exprDecoder)

                    17 ->
                        Bytes.Decode.map2 TailCall
                            BD.string
                            (BD.list (BD.jsonPair BD.string exprDecoder))

                    18 ->
                        Bytes.Decode.map2 If
                            (BD.list (BD.jsonPair exprDecoder exprDecoder))
                            exprDecoder

                    19 ->
                        Bytes.Decode.map2 Let
                            defDecoder
                            exprDecoder

                    20 ->
                        Bytes.Decode.map2 Destruct
                            destructorDecoder
                            exprDecoder

                    21 ->
                        Bytes.Decode.map4 Case
                            BD.string
                            BD.string
                            (deciderDecoder choiceDecoder)
                            (BD.list (BD.jsonPair BD.int exprDecoder))

                    22 ->
                        Bytes.Decode.map2 Accessor
                            A.regionDecoder
                            BD.string

                    23 ->
                        Bytes.Decode.map3 Access
                            exprDecoder
                            A.regionDecoder
                            BD.string

                    24 ->
                        Bytes.Decode.map3 Update
                            A.regionDecoder
                            exprDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)

                    25 ->
                        Bytes.Decode.map Record
                            (BD.assocListDict identity BD.string exprDecoder)

                    26 ->
                        Bytes.Decode.map2 TrackedRecord
                            A.regionDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)

                    27 ->
                        Bytes.Decode.succeed Unit

                    28 ->
                        Bytes.Decode.map4 Tuple
                            A.regionDecoder
                            exprDecoder
                            exprDecoder
                            (BD.list exprDecoder)

                    29 ->
                        Bytes.Decode.map3 Shader
                            Shader.sourceDecoder
                            (BD.everySet identity BD.string)
                            (BD.everySet identity BD.string)

                    _ ->
                        Bytes.Decode.fail
            )


defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Def region name expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.string name
                , exprEncoder expr
                ]

        TailDef region name args expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string name
                , BE.list (A.locatedEncoder BE.string) args
                , exprEncoder expr
                ]


defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Def
                            A.regionDecoder
                            BD.string
                            exprDecoder

                    1 ->
                        Bytes.Decode.map4 TailDef
                            A.regionDecoder
                            BD.string
                            (BD.list (A.locatedDecoder BD.string))
                            exprDecoder

                    _ ->
                        Bytes.Decode.fail
            )


destructorEncoder : Destructor -> Bytes.Encode.Encoder
destructorEncoder (Destructor name path) =
    Bytes.Encode.sequence
        [ BE.string name
        , pathEncoder path
        ]


destructorDecoder : Bytes.Decode.Decoder Destructor
destructorDecoder =
    Bytes.Decode.map2 Destructor
        BD.string
        pathDecoder


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


pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder path =
    case path of
        Index index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
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
                        Bytes.Decode.map2 Index
                            Index.zeroBasedDecoder
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
