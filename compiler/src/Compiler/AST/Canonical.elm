module Compiler.AST.Canonical exposing
    ( Module(..), ModuleData, Exports(..), Export(..), Effects(..), Manager(..), Port(..)
    , Expr, ExprInfo, Expr_(..), CaseBranch(..), FieldUpdate(..)
    , Def(..), Decls(..)
    , Pattern, PatternInfo, Pattern_(..), PatternCtorArg(..)
    , Type(..), Annotation(..), FreeVars, AliasType(..), FieldType(..), fieldsToList
    , Union(..), UnionData, Alias(..), Ctor(..), CtorData, CtorOpts(..), Binop(..)
    , annotationEncoder, annotationDecoder
    , typeEncoder, typeDecoder
    , aliasEncoder, aliasDecoder
    , unionEncoder, unionDecoder
    , ctorOptsEncoder, ctorOptsDecoder
    , fieldUpdateEncoder, fieldUpdateDecoder
    )

{-| The Canonical AST represents Elm code after name resolution.

During canonicalization, all variable references are resolved to their home modules.
For example, `L.map` becomes a reference to `elm/core:List.map`. This phase also
caches information needed by later compiler phases to avoid expensive lookups during
type inference and exhaustiveness checking.

Cached data is marked with comments like `-- CACHE for exhaustiveness` or
`-- CACHE for inference` to clarify why certain fields exist.


# Modules

@docs Module, ModuleData, Exports, Export, Effects, Manager, Port


# Expressions

@docs Expr, ExprInfo, Expr_, CaseBranch, FieldUpdate


# Definitions

@docs Def, Decls


# Patterns

@docs Pattern, PatternInfo, Pattern_, PatternCtorArg


# Types

@docs Type, Annotation, FreeVars, AliasType, FieldType, fieldsToList


# Type Declarations

@docs Union, UnionData, Alias, Ctor, CtorData, CtorOpts, Binop


# Serialization

@docs annotationEncoder, annotationDecoder
@docs typeEncoder, typeDecoder
@docs aliasEncoder, aliasDecoder
@docs unionEncoder, unionDecoder
@docs ctorOptsEncoder, ctorOptsDecoder
@docs fieldUpdateEncoder, fieldUpdateDecoder

-}

{- Internal note: Creating a canonical AST means finding the home module for all variables.
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
import Data.Map
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== Expressions ======


{-| An expression with source location annotation and unique ID.
-}
type alias Expr =
    A.Located ExprInfo


{-| Expression info containing the unique ID and expression node.
-}
type alias ExprInfo =
    { id : Int
    , node : Expr_
    }


{-| Expression variants in the canonical AST.

Many variants include cached type annotations for efficient type inference.

-}
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
    | Update Expr (Data.Map.Dict String (A.Located Name) FieldUpdate)
    | Record (Data.Map.Dict String (A.Located Name) Expr)
    | Unit
    | Tuple Expr Expr (List Expr)
    | Shader Shader.Source Shader.Types


{-| A single branch in a case expression, pairing a pattern with its body.
-}
type CaseBranch
    = CaseBranch Pattern Expr


{-| A field update in a record update expression.
-}
type FieldUpdate
    = FieldUpdate A.Region Expr



-- ====== Definitions ======


{-| A value or function definition.

  - `Def` - A definition without a type annotation
  - `TypedDef` - A definition with a type annotation and free type variables

-}
type Def
    = Def (A.Located Name) (List Pattern) Expr
    | TypedDef (A.Located Name) FreeVars (List ( Pattern, Type )) Expr Type


{-| A linked list of top-level declarations in a module.

  - `Declare` - A non-recursive definition
  - `DeclareRec` - A group of mutually recursive definitions
  - `SaveTheEnvironment` - Sentinel marking the end of declarations

-}
type Decls
    = Declare Def Decls
    | DeclareRec Def (List Def) Decls
    | SaveTheEnvironment



-- ====== Patterns ======


{-| A pattern with source location annotation and unique ID.
-}
type alias Pattern =
    A.Located PatternInfo


{-| Pattern info containing the unique ID and pattern node.
-}
type alias PatternInfo =
    { id : Int
    , node : Pattern_
    }


{-| Pattern variants for destructuring values.

Constructor patterns (`PCtor`) include extensive cached data for type inference
and exhaustiveness checking.

-}
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


{-| A constructor argument in a pattern, with cached index and type.
-}
type PatternCtorArg
    = PatternCtorArg
        Index.ZeroBased
        -- CACHE for destructors/errors
        Type
        -- CACHE for type inference
        Pattern



-- ====== Types ======


{-| A type annotation with universally quantified type variables.

The `FreeVars` contains the names of type variables that are polymorphic.

-}
type Annotation
    = Forall FreeVars Type


{-| Free type variables in a type annotation.
-}
type alias FreeVars =
    Dict Name ()


{-| Canonical type representation.

  - `TLambda` - Function type (a -> b)
  - `TVar` - Type variable
  - `TType` - Named type with arguments (e.g., List Int)
  - `TRecord` - Record type with optional extension variable
  - `TUnit` - Unit type ()
  - `TTuple` - Tuple type
  - `TAlias` - Type alias application

-}
type Type
    = TLambda Type Type
    | TVar Name
    | TType IO.Canonical Name (List Type)
    | TRecord (Dict Name FieldType) (Maybe Name)
    | TUnit
    | TTuple Type Type (List Type)
    | TAlias IO.Canonical Name (List ( Name, Type )) AliasType


{-| Tracks whether a type alias has been fully expanded.

  - `Holey` - Alias body still contains type variables to substitute
  - `Filled` - Alias has been fully expanded with concrete types

-}
type AliasType
    = Holey Type
    | Filled Type


{-| A record field with its source order index and type.

The index preserves source order for canonical types from annotations.
Inferred types may have all zeros for the index.

-}
type FieldType
    = FieldType Int Type


{-| Converts record fields to an ordered list, sorted by source position.
-}
fieldsToList : Dict Name FieldType -> List ( Name, Type )
fieldsToList fields =
    let
        getIndex : ( a, FieldType ) -> Int
        getIndex ( _, FieldType index _ ) =
            index

        dropIndex : ( a, FieldType ) -> ( a, Type )
        dropIndex ( name, FieldType _ tipe ) =
            ( name, tipe )
    in
    Dict.toList fields
        |> List.sortBy getIndex
        |> List.map dropIndex



-- ====== Modules ======


{-| Internal data for a canonical module.
-}
type alias ModuleData =
    { name : IO.Canonical
    , exports : Exports
    , docs : Src.Docs
    , decls : Decls
    , unions : Dict Name Union
    , aliases : Dict Name Alias
    , binops : Dict Name Binop
    , effects : Effects
    }


{-| A canonicalized Elm module.
-}
type Module
    = Module ModuleData


{-| A type alias definition with its type parameters and body.
-}
type Alias
    = Alias (List Name) Type


{-| An infix operator definition with associativity, precedence, and function name.
-}
type Binop
    = Binop_ Binop.Associativity Binop.Precedence Name


{-| Internal data for a union type declaration.
-}
type alias UnionData =
    { vars : List Name
    , alts : List Ctor
    , numAlts : Int -- CACHE for exhaustiveness checking
    , opts : CtorOpts -- CACHE which optimizations are available
    }


{-| A union type (custom type) declaration.
-}
type Union
    = Union UnionData


{-| Code generation optimization hints for constructors.

  - `Normal` - Standard constructor representation
  - `Enum` - All constructors are nullary (no arguments)
  - `Unbox` - Single constructor with single argument can be unboxed

-}
type CtorOpts
    = Normal
    | Enum
    | Unbox


{-| Internal data for a type constructor.
-}
type alias CtorData =
    { name : Name
    , index : Index.ZeroBased
    , numArgs : Int -- CACHE length args
    , args : List Type
    }


{-| A type constructor in a union type.
-}
type Ctor
    = Ctor CtorData



-- ====== Exports ======


{-| What a module exports.

  - `ExportEverything` - Module uses `exposing (..)` syntax
  - `Export` - Module has explicit export list

-}
type Exports
    = ExportEverything A.Region
    | Export (Dict Name (A.Located Export))


{-| The kind of thing being exported.
-}
type Export
    = ExportValue
    | ExportBinop
    | ExportAlias
    | ExportUnionOpen
    | ExportUnionClosed
    | ExportPort


{-| Effects that a module can define.

  - `NoEffects` - A normal module
  - `Ports` - A port module with JavaScript interop
  - `Manager` - An effect manager (kernel code only)

-}
type Effects
    = NoEffects
    | Ports (Dict Name Port)
    | Manager A.Region A.Region A.Region Manager


{-| A port declaration for JavaScript interop.

  - `Incoming` - Receives values from JavaScript (subscription)
  - `Outgoing` - Sends values to JavaScript (command)

-}
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


{-| The kind of effect manager.

  - `Cmd` - Manages commands only
  - `Sub` - Manages subscriptions only
  - `Fx` - Manages both commands and subscriptions

-}
type Manager
    = Cmd Name
    | Sub Name
    | Fx Name Name



-- ====== Serialization ======


{-| Encodes an Annotation to bytes for serialization.
-}
annotationEncoder : Annotation -> Bytes.Encode.Encoder
annotationEncoder (Forall freeVars tipe) =
    Bytes.Encode.sequence
        [ freeVarsEncoder freeVars
        , typeEncoder tipe
        ]


{-| Decodes an Annotation from bytes.
-}
annotationDecoder : Bytes.Decode.Decoder Annotation
annotationDecoder =
    Bytes.Decode.map2 Forall
        freeVarsDecoder
        typeDecoder


freeVarsEncoder : FreeVars -> Bytes.Encode.Encoder
freeVarsEncoder freeVars =
    BE.list BE.string (Dict.keys freeVars)


freeVarsDecoder : Bytes.Decode.Decoder FreeVars
freeVarsDecoder =
    BD.list BD.string
        |> Bytes.Decode.map (List.map (\key -> ( key, () )) >> Dict.fromList)


{-| Encodes an Alias to bytes for serialization.
-}
aliasEncoder : Alias -> Bytes.Encode.Encoder
aliasEncoder (Alias vars tipe) =
    Bytes.Encode.sequence
        [ BE.list BE.string vars
        , typeEncoder tipe
        ]


{-| Decodes an Alias from bytes.
-}
aliasDecoder : Bytes.Decode.Decoder Alias
aliasDecoder =
    Bytes.Decode.map2 Alias
        (BD.list BD.string)
        typeDecoder


{-| Encodes a Type to bytes for serialization.
-}
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
                , BE.stdDict BE.string fieldTypeEncoder fields
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


{-| Decodes a Type from bytes.
-}
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
                            (BD.stdDict BD.string fieldTypeDecoder)
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


{-| Encodes a Union to bytes for serialization.
-}
unionEncoder : Union -> Bytes.Encode.Encoder
unionEncoder (Union u) =
    Bytes.Encode.sequence
        [ BE.list BE.string u.vars
        , BE.list ctorEncoder u.alts
        , BE.int u.numAlts
        , ctorOptsEncoder u.opts
        ]


{-| Decodes a Union from bytes.
-}
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


{-| Encodes CtorOpts to bytes for serialization.
-}
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


{-| Decodes CtorOpts from bytes.
-}
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


{-| Encodes a FieldUpdate to bytes for serialization.
-}
fieldUpdateEncoder : FieldUpdate -> Bytes.Encode.Encoder
fieldUpdateEncoder (FieldUpdate fieldRegion expr) =
    Bytes.Encode.sequence
        [ A.regionEncoder fieldRegion
        , exprEncoder expr
        ]


{-| Decodes a FieldUpdate from bytes.
-}
fieldUpdateDecoder : Bytes.Decode.Decoder FieldUpdate
fieldUpdateDecoder =
    Bytes.Decode.map2 FieldUpdate
        A.regionDecoder
        exprDecoder


exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder =
    A.locatedEncoder exprInfoEncoder


exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    A.locatedDecoder exprInfoDecoder


exprInfoEncoder : ExprInfo -> Bytes.Encode.Encoder
exprInfoEncoder info =
    Bytes.Encode.sequence
        [ BE.int info.id
        , expr_Encoder info.node
        ]


exprInfoDecoder : Bytes.Decode.Decoder ExprInfo
exprInfoDecoder =
    Bytes.Decode.map2 (\id node -> { id = id, node = node })
        BD.int
        expr_Decoder


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
    A.locatedEncoder patternInfoEncoder


patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    A.locatedDecoder patternInfoDecoder


patternInfoEncoder : PatternInfo -> Bytes.Encode.Encoder
patternInfoEncoder info =
    Bytes.Encode.sequence
        [ BE.int info.id
        , pattern_Encoder info.node
        ]


patternInfoDecoder : Bytes.Decode.Decoder PatternInfo
patternInfoDecoder =
    Bytes.Decode.map2 PatternInfo
        BD.int
        pattern_Decoder


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
