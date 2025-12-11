module Compiler.AST.Canonical exposing
    ( Alias(..)
    , AliasType(..)
    , Annotation(..)
    , Binop(..)
    , CaseBranch(..)
    , Ctor(..)
    , CtorData
    , CtorOpts(..)
    , Decls(..)
    , Def(..)
    , Effects(..)
    , Export(..)
    , Exports(..)
    , Expr
    , Expr_(..)
    , FieldType(..)
    , FieldUpdate(..)
    , FreeVars
    , Manager(..)
    , Module(..)
    , ModuleData
    , Pattern
    , PatternCtorArg(..)
    , Pattern_(..)
    , Port(..)
    , Type(..)
    , Union(..)
    , UnionData
    , aliasDecoder
    , aliasEncoder
    , annotationDecoder
    , annotationEncoder
    , ctorOptsDecoder
    , ctorOptsEncoder
    , fieldUpdateDecoder
    , fieldUpdateEncoder
    , fieldsToList
    , typeDecoder
    , typeEncoder
    , unionDecoder
    , unionEncoder
    )

{- Creating a canonical AST means finding the home module for all variables.
   So if you have L.map, you need to figure out that it is from the elm/core
   package in the List module.

   In later phases (e.g. type inference, exhaustiveness checking, optimization)
   you need to look up additional info from these modules. What is the type?
   What are the alternative type constructors? These lookups can be quite costly,
   especially in type inference. To reduce costs the canonicalization phase
   caches info needed in later phases. This means we no longer build large
   dictionaries of metadata with O(log(n)) lookups in those phases. Instead
   there is an O(1) read of an existing field! I have tried to mark all
   cached data with comments like:

   -- CACHE for exhaustiveness
   -- CACHE for inference

   So it is clear why the data is kept around.
-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- EXPRESSIONS


type alias Expr =
    A.Located Expr_



-- CACHE Annotations for type inference


type Expr_
    = VarLocal Name
    | VarTopLevel IO.Canonical Name
    | VarKernel Name Name
    | VarForeign IO.Canonical Name Annotation
    | VarCtor CtorOpts IO.Canonical Name Index.ZeroBased Annotation
    | VarDebug IO.Canonical Name Annotation
    | VarOperator Name IO.Canonical Name Annotation -- CACHE real name for optimization
    | Chr String
    | Str String
    | Int Int
    | Float Float
    | List (List Expr)
    | Negate Expr
    | Binop Name IO.Canonical Name Annotation Expr Expr -- CACHE real name for optimization
    | Lambda (List Pattern) Expr
    | Call Expr (List Expr)
    | If (List ( Expr, Expr )) Expr
    | Let Def Expr
    | LetRec (List Def) Expr
    | LetDestruct Pattern Expr Expr
    | Case Expr (List CaseBranch)
    | Accessor Name
    | Access Expr (A.Located Name)
    | Update Expr (Dict String (A.Located Name) FieldUpdate)
    | Record (Dict String (A.Located Name) Expr)
    | Unit
    | Tuple Expr Expr (List Expr)
    | Shader Shader.Source Shader.Types


type CaseBranch
    = CaseBranch Pattern Expr


type FieldUpdate
    = FieldUpdate A.Region Expr



-- DEFS


type Def
    = Def (A.Located Name) (List Pattern) Expr
    | TypedDef (A.Located Name) FreeVars (List ( Pattern, Type )) Expr Type


type Decls
    = Declare Def Decls
    | DeclareRec Def (List Def) Decls
    | SaveTheEnvironment



-- PATTERNS


type alias Pattern =
    A.Located Pattern_


type Pattern_
    = PAnything
    | PVar Name
    | PRecord (List Name)
    | PAlias Pattern Name
    | PUnit
    | PTuple Pattern Pattern (List Pattern)
    | PList (List Pattern)
    | PCons Pattern Pattern
    | PBool Union Bool
    | PChr String
    | PStr String Bool
    | PInt Int
    | PCtor
        -- CACHE p_home, p_type, and p_vars for type inference
        -- CACHE p_index to replace p_name in PROD code gen
        -- CACHE p_opts to allocate less in PROD code gen
        -- CACHE p_alts and p_numAlts for exhaustiveness checker
        { home : IO.Canonical
        , type_ : Name
        , union : Union
        , name : Name
        , index : Index.ZeroBased
        , args : List PatternCtorArg
        }


type PatternCtorArg
    = PatternCtorArg
        -- CACHE for destructors/errors
        Index.ZeroBased
        -- CACHE for type inference
        Type
        Pattern



-- TYPES


type Annotation
    = Forall FreeVars Type


type alias FreeVars =
    Dict String Name ()


type Type
    = TLambda Type Type
    | TVar Name
    | TType IO.Canonical Name (List Type)
    | TRecord (Dict String Name FieldType) (Maybe Name)
    | TUnit
    | TTuple Type Type (List Type)
    | TAlias IO.Canonical Name (List ( Name, Type )) AliasType


type AliasType
    = Holey Type
    | Filled Type


type FieldType
    = FieldType Int Type



-- NOTE: The Word16 marks the source order, but it may not be available
-- for every canonical type. For example, if the canonical type is inferred
-- the orders will all be zeros.


fieldsToList : Dict String Name FieldType -> List ( Name, Type )
fieldsToList fields =
    let
        getIndex : ( a, FieldType ) -> Int
        getIndex ( _, FieldType index _ ) =
            index

        dropIndex : ( a, FieldType ) -> ( a, Type )
        dropIndex ( name, FieldType _ tipe ) =
            ( name, tipe )
    in
    Dict.toList compare fields
        |> List.sortBy getIndex
        |> List.map dropIndex



-- MODULES


type alias ModuleData =
    { name : IO.Canonical
    , exports : Exports
    , docs : Src.Docs
    , decls : Decls
    , unions : Dict String Name Union
    , aliases : Dict String Name Alias
    , binops : Dict String Name Binop
    , effects : Effects
    }


type Module
    = Module ModuleData


type Alias
    = Alias (List Name) Type


type Binop
    = Binop_ Binop.Associativity Binop.Precedence Name


type alias UnionData =
    { vars : List Name
    , alts : List Ctor
    , numAlts : Int -- CACHE for exhaustiveness checking
    , opts : CtorOpts -- CACHE which optimizations are available
    }


type Union
    = Union UnionData


type CtorOpts
    = Normal
    | Enum
    | Unbox


type alias CtorData =
    { name : Name
    , index : Index.ZeroBased
    , numArgs : Int -- CACHE length args
    , args : List Type
    }


type Ctor
    = Ctor CtorData



-- EXPORTS


type Exports
    = ExportEverything A.Region
    | Export (Dict String Name (A.Located Export))


type Export
    = ExportValue
    | ExportBinop
    | ExportAlias
    | ExportUnionOpen
    | ExportUnionClosed
    | ExportPort


type Effects
    = NoEffects
    | Ports (Dict String Name Port)
    | Manager A.Region A.Region A.Region Manager


type Port
    = Incoming
        { freeVars : FreeVars
        , payload : Type
        , func : Type
        }
    | Outgoing
        { freeVars : FreeVars
        , payload : Type
        , func : Type
        }


type Manager
    = Cmd Name
    | Sub Name
    | Fx Name Name



-- ENCODERS and DECODERS


annotationEncoder : Annotation -> Bytes.Encode.Encoder
annotationEncoder (Forall freeVars tipe) =
    Bytes.Encode.sequence
        [ freeVarsEncoder freeVars
        , typeEncoder tipe
        ]


annotationDecoder : Bytes.Decode.Decoder Annotation
annotationDecoder =
    Bytes.Decode.map2 Forall
        freeVarsDecoder
        typeDecoder


freeVarsEncoder : FreeVars -> Bytes.Encode.Encoder
freeVarsEncoder freeVars =
    BE.list BE.string (Dict.keys compare freeVars)


freeVarsDecoder : Bytes.Decode.Decoder FreeVars
freeVarsDecoder =
    BD.list BD.string
        |> Bytes.Decode.map (List.map (\key -> ( key, () )) >> Dict.fromList identity)


aliasEncoder : Alias -> Bytes.Encode.Encoder
aliasEncoder (Alias vars tipe) =
    Bytes.Encode.sequence
        [ BE.list BE.string vars
        , typeEncoder tipe
        ]


aliasDecoder : Bytes.Decode.Decoder Alias
aliasDecoder =
    Bytes.Decode.map2 Alias
        (BD.list BD.string)
        typeDecoder


typeEncoder : Type -> Bytes.Encode.Encoder
typeEncoder type_ =
    case type_ of
        TLambda a b ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , typeEncoder a
                , typeEncoder b
                ]

        TVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        TType home name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , ModuleName.canonicalEncoder home
                , BE.string name
                , BE.list typeEncoder args
                ]

        TRecord fields ext ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.assocListDict compare BE.string fieldTypeEncoder fields
                , BE.maybe BE.string ext
                ]

        TUnit ->
            Bytes.Encode.unsignedInt8 4

        TTuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , typeEncoder a
                , typeEncoder b
                , BE.list typeEncoder cs
                ]

        TAlias home name args tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , ModuleName.canonicalEncoder home
                , BE.string name
                , BE.list (BE.jsonPair BE.string typeEncoder) args
                , aliasTypeEncoder tipe
                ]


typeDecoder : Bytes.Decode.Decoder Type
typeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 TLambda
                            typeDecoder
                            typeDecoder

                    1 ->
                        Bytes.Decode.map TVar BD.string

                    2 ->
                        Bytes.Decode.map3 TType
                            ModuleName.canonicalDecoder
                            BD.string
                            (BD.list typeDecoder)

                    3 ->
                        Bytes.Decode.map2 TRecord
                            (BD.assocListDict identity BD.string fieldTypeDecoder)
                            (BD.maybe BD.string)

                    4 ->
                        Bytes.Decode.succeed TUnit

                    5 ->
                        Bytes.Decode.map3 TTuple
                            typeDecoder
                            typeDecoder
                            (BD.list typeDecoder)

                    6 ->
                        Bytes.Decode.map4 TAlias
                            ModuleName.canonicalDecoder
                            BD.string
                            (BD.list (BD.jsonPair BD.string typeDecoder))
                            aliasTypeDecoder

                    _ ->
                        Bytes.Decode.fail
            )


fieldTypeEncoder : FieldType -> Bytes.Encode.Encoder
fieldTypeEncoder (FieldType index tipe) =
    Bytes.Encode.sequence
        [ BE.int index
        , typeEncoder tipe
        ]


aliasTypeEncoder : AliasType -> Bytes.Encode.Encoder
aliasTypeEncoder aliasType =
    case aliasType of
        Holey tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , typeEncoder tipe
                ]

        Filled tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , typeEncoder tipe
                ]


fieldTypeDecoder : Bytes.Decode.Decoder FieldType
fieldTypeDecoder =
    Bytes.Decode.map2 FieldType
        BD.int
        typeDecoder


aliasTypeDecoder : Bytes.Decode.Decoder AliasType
aliasTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Holey typeDecoder

                    1 ->
                        Bytes.Decode.map Filled typeDecoder

                    _ ->
                        Bytes.Decode.fail
            )


unionEncoder : Union -> Bytes.Encode.Encoder
unionEncoder (Union u) =
    Bytes.Encode.sequence
        [ BE.list BE.string u.vars
        , BE.list ctorEncoder u.alts
        , BE.int u.numAlts
        , ctorOptsEncoder u.opts
        ]


unionDecoder : Bytes.Decode.Decoder Union
unionDecoder =
    Bytes.Decode.map4 (\vars_ alts_ numAlts_ opts_ -> Union { vars = vars_, alts = alts_, numAlts = numAlts_, opts = opts_ })
        (BD.list BD.string)
        (BD.list ctorDecoder)
        BD.int
        ctorOptsDecoder


ctorEncoder : Ctor -> Bytes.Encode.Encoder
ctorEncoder (Ctor c) =
    Bytes.Encode.sequence
        [ BE.string c.name
        , Index.zeroBasedEncoder c.index
        , BE.int c.numArgs
        , BE.list typeEncoder c.args
        ]


ctorDecoder : Bytes.Decode.Decoder Ctor
ctorDecoder =
    Bytes.Decode.map4 (\name_ index_ numArgs_ args_ -> Ctor { name = name_, index = index_, numArgs = numArgs_, args = args_ })
        BD.string
        Index.zeroBasedDecoder
        BD.int
        (BD.list typeDecoder)


ctorOptsEncoder : CtorOpts -> Bytes.Encode.Encoder
ctorOptsEncoder ctorOpts =
    Bytes.Encode.unsignedInt8
        (case ctorOpts of
            Normal ->
                0

            Enum ->
                1

            Unbox ->
                2
        )


ctorOptsDecoder : Bytes.Decode.Decoder CtorOpts
ctorOptsDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Normal

                    1 ->
                        Bytes.Decode.succeed Enum

                    2 ->
                        Bytes.Decode.succeed Unbox

                    _ ->
                        Bytes.Decode.fail
            )


fieldUpdateEncoder : FieldUpdate -> Bytes.Encode.Encoder
fieldUpdateEncoder (FieldUpdate fieldRegion expr) =
    Bytes.Encode.sequence
        [ A.regionEncoder fieldRegion
        , exprEncoder expr
        ]


fieldUpdateDecoder : Bytes.Decode.Decoder FieldUpdate
fieldUpdateDecoder =
    Bytes.Decode.map2 FieldUpdate
        A.regionDecoder
        exprDecoder


exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder =
    A.locatedEncoder expr_Encoder


exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    A.locatedDecoder expr_Decoder


expr_Encoder : Expr_ -> Bytes.Encode.Encoder
expr_Encoder expr_ =
    case expr_ of
        VarLocal name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string name
                ]

        VarTopLevel home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.canonicalEncoder home
                , BE.string name
                ]

        VarKernel home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string home
                , BE.string name
                ]

        VarForeign home name annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                ]

        VarCtor opts home name index annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , ctorOptsEncoder opts
                , ModuleName.canonicalEncoder home
                , BE.string name
                , Index.zeroBasedEncoder index
                , annotationEncoder annotation
                ]

        VarDebug home name annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                ]

        VarOperator op home name annotation ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.string op
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                ]

        Chr chr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.string chr
                ]

        Str str ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , BE.string str
                ]

        Int int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.int int
                ]

        Float float ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.float float
                ]

        List entries ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.list exprEncoder entries
                ]

        Negate expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , exprEncoder expr
                ]

        Binop op home name annotation left right ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , BE.string op
                , ModuleName.canonicalEncoder home
                , BE.string name
                , annotationEncoder annotation
                , exprEncoder left
                , exprEncoder right
                ]

        Lambda args body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , BE.list patternEncoder args
                , exprEncoder body
                ]

        Call func args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , exprEncoder func
                , BE.list exprEncoder args
                ]

        If branches finally ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , BE.list (BE.jsonPair exprEncoder exprEncoder) branches
                , exprEncoder finally
                ]

        Let def body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , defEncoder def
                , exprEncoder body
                ]

        LetRec defs body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , BE.list defEncoder defs
                , exprEncoder body
                ]

        LetDestruct pattern expr body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 19
                , patternEncoder pattern
                , exprEncoder expr
                , exprEncoder body
                ]

        Case expr branches ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , exprEncoder expr
                , BE.list caseBranchEncoder branches
                ]

        Accessor field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , BE.string field
                ]

        Access record field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , exprEncoder record
                , A.locatedEncoder BE.string field
                ]

        Update record updates ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 23
                , exprEncoder record
                , BE.assocListDict A.compareLocated (A.toValue >> BE.string) fieldUpdateEncoder updates
                ]

        Record fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 24
                , BE.assocListDict A.compareLocated (A.toValue >> BE.string) exprEncoder fields
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 25

        Tuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 26
                , exprEncoder a
                , exprEncoder b
                , BE.list exprEncoder cs
                ]

        Shader src types ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 27
                , Shader.sourceEncoder src
                , Shader.typesEncoder types
                ]


expr_Decoder : Bytes.Decode.Decoder Expr_
expr_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map VarLocal BD.string

                    1 ->
                        Bytes.Decode.map2 VarTopLevel
                            ModuleName.canonicalDecoder
                            BD.string

                    2 ->
                        Bytes.Decode.map2 VarKernel
                            BD.string
                            BD.string

                    3 ->
                        Bytes.Decode.map3 VarForeign
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder

                    4 ->
                        Bytes.Decode.map5 VarCtor
                            ctorOptsDecoder
                            ModuleName.canonicalDecoder
                            BD.string
                            Index.zeroBasedDecoder
                            annotationDecoder

                    5 ->
                        Bytes.Decode.map3 VarDebug
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder

                    6 ->
                        Bytes.Decode.map4 VarOperator
                            BD.string
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder

                    7 ->
                        Bytes.Decode.map Chr BD.string

                    8 ->
                        Bytes.Decode.map Str BD.string

                    9 ->
                        Bytes.Decode.map Int BD.int

                    10 ->
                        Bytes.Decode.map Float BD.float

                    11 ->
                        Bytes.Decode.map List (BD.list exprDecoder)

                    12 ->
                        Bytes.Decode.map Negate exprDecoder

                    13 ->
                        BD.map6 Binop
                            BD.string
                            ModuleName.canonicalDecoder
                            BD.string
                            annotationDecoder
                            exprDecoder
                            exprDecoder

                    14 ->
                        Bytes.Decode.map2 Lambda
                            (BD.list patternDecoder)
                            exprDecoder

                    15 ->
                        Bytes.Decode.map2 Call
                            exprDecoder
                            (BD.list exprDecoder)

                    16 ->
                        Bytes.Decode.map2 If
                            (BD.list (BD.jsonPair exprDecoder exprDecoder))
                            exprDecoder

                    17 ->
                        Bytes.Decode.map2 Let
                            defDecoder
                            exprDecoder

                    18 ->
                        Bytes.Decode.map2 LetRec
                            (BD.list defDecoder)
                            exprDecoder

                    19 ->
                        Bytes.Decode.map3 LetDestruct
                            patternDecoder
                            exprDecoder
                            exprDecoder

                    20 ->
                        Bytes.Decode.map2 Case
                            exprDecoder
                            (BD.list caseBranchDecoder)

                    21 ->
                        Bytes.Decode.map Accessor BD.string

                    22 ->
                        Bytes.Decode.map2 Access
                            exprDecoder
                            (A.locatedDecoder BD.string)

                    23 ->
                        Bytes.Decode.map2 Update
                            exprDecoder
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) fieldUpdateDecoder)

                    24 ->
                        Bytes.Decode.map Record
                            (BD.assocListDict A.toValue (A.locatedDecoder BD.string) exprDecoder)

                    25 ->
                        Bytes.Decode.succeed Unit

                    26 ->
                        Bytes.Decode.map3 Tuple
                            exprDecoder
                            exprDecoder
                            (BD.list exprDecoder)

                    27 ->
                        Bytes.Decode.map2 Shader
                            Shader.sourceDecoder
                            Shader.typesDecoder

                    _ ->
                        Bytes.Decode.fail
            )


patternEncoder : Pattern -> Bytes.Encode.Encoder
patternEncoder =
    A.locatedEncoder pattern_Encoder


patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    A.locatedDecoder pattern_Decoder


pattern_Encoder : Pattern_ -> Bytes.Encode.Encoder
pattern_Encoder pattern_ =
    case pattern_ of
        PAnything ->
            Bytes.Encode.unsignedInt8 0

        PVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        PRecord names ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.list BE.string names
                ]

        PAlias pattern name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , patternEncoder pattern
                , BE.string name
                ]

        PUnit ->
            Bytes.Encode.unsignedInt8 4

        PTuple pattern1 pattern2 otherPatterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , patternEncoder pattern1
                , patternEncoder pattern2
                , BE.list patternEncoder otherPatterns
                ]

        PList patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.list patternEncoder patterns
                ]

        PCons pattern1 pattern2 ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , patternEncoder pattern1
                , patternEncoder pattern2
                ]

        PBool union bool ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , unionEncoder union
                , BE.bool bool
                ]

        PChr chr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.string chr
                ]

        PStr str multiline ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.string str
                , BE.bool multiline
                ]

        PInt int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.int int
                ]

        PCtor { home, type_, union, name, index, args } ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , ModuleName.canonicalEncoder home
                , BE.string type_
                , unionEncoder union
                , BE.string name
                , Index.zeroBasedEncoder index
                , BE.list patternCtorArgEncoder args
                ]


pattern_Decoder : Bytes.Decode.Decoder Pattern_
pattern_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed PAnything

                    1 ->
                        Bytes.Decode.map PVar
                            BD.string

                    2 ->
                        Bytes.Decode.map PRecord
                            (BD.list BD.string)

                    3 ->
                        Bytes.Decode.map2 PAlias
                            patternDecoder
                            BD.string

                    4 ->
                        Bytes.Decode.succeed PUnit

                    5 ->
                        Bytes.Decode.map3 PTuple
                            patternDecoder
                            patternDecoder
                            (BD.list patternDecoder)

                    6 ->
                        Bytes.Decode.map PList
                            (BD.list patternDecoder)

                    7 ->
                        Bytes.Decode.map2 PCons
                            patternDecoder
                            patternDecoder

                    8 ->
                        Bytes.Decode.map2 PBool
                            unionDecoder
                            BD.bool

                    9 ->
                        Bytes.Decode.map PChr BD.string

                    10 ->
                        Bytes.Decode.map2 PStr
                            BD.string
                            BD.bool

                    11 ->
                        Bytes.Decode.map PInt BD.int

                    12 ->
                        BD.map6
                            (\home type_ union name index args ->
                                PCtor
                                    { home = home
                                    , type_ = type_
                                    , union = union
                                    , name = name
                                    , index = index
                                    , args = args
                                    }
                            )
                            ModuleName.canonicalDecoder
                            BD.string
                            unionDecoder
                            BD.string
                            Index.zeroBasedDecoder
                            (BD.list patternCtorArgDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


patternCtorArgEncoder : PatternCtorArg -> Bytes.Encode.Encoder
patternCtorArgEncoder (PatternCtorArg index srcType pattern) =
    Bytes.Encode.sequence
        [ Index.zeroBasedEncoder index
        , typeEncoder srcType
        , patternEncoder pattern
        ]


patternCtorArgDecoder : Bytes.Decode.Decoder PatternCtorArg
patternCtorArgDecoder =
    Bytes.Decode.map3 PatternCtorArg
        Index.zeroBasedDecoder
        typeDecoder
        patternDecoder


defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Def name args expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.locatedEncoder BE.string name
                , BE.list patternEncoder args
                , exprEncoder expr
                ]

        TypedDef name freeVars typedArgs expr srcResultType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.locatedEncoder BE.string name
                , freeVarsEncoder freeVars
                , BE.list (BE.jsonPair patternEncoder typeEncoder) typedArgs
                , exprEncoder expr
                , typeEncoder srcResultType
                ]


defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Def
                            (A.locatedDecoder BD.string)
                            (BD.list patternDecoder)
                            exprDecoder

                    1 ->
                        Bytes.Decode.map5 TypedDef
                            (A.locatedDecoder BD.string)
                            freeVarsDecoder
                            (BD.list (BD.jsonPair patternDecoder typeDecoder))
                            exprDecoder
                            typeDecoder

                    _ ->
                        Bytes.Decode.fail
            )


caseBranchEncoder : CaseBranch -> Bytes.Encode.Encoder
caseBranchEncoder (CaseBranch pattern expr) =
    Bytes.Encode.sequence
        [ patternEncoder pattern
        , exprEncoder expr
        ]


caseBranchDecoder : Bytes.Decode.Decoder CaseBranch
caseBranchDecoder =
    Bytes.Decode.map2 CaseBranch
        patternDecoder
        exprDecoder
