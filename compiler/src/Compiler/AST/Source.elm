module Compiler.AST.Source exposing
    ( Alias(..)
    , C0Eol
    , C1
    , C1Eol
    , C2
    , C2Eol
    , C3
    , Comment(..)
    , Def(..)
    , Docs(..)
    , Effects(..)
    , Exposed(..)
    , Exposing(..)
    , Expr
    , Expr_(..)
    , FComment(..)
    , FComments
    , ForceMultiline(..)
    , Import(..)
    , Infix(..)
    , Manager(..)
    , Module(..)
    , OpenCommentedList(..)
    , Pair(..)
    , Pattern
    , Pattern_(..)
    , Port(..)
    , Privacy(..)
    , Type
    , Type_(..)
    , Union(..)
    , Value(..)
    , VarType(..)
    , c0EolDecoder
    , c0EolEncoder
    , c0EolMap
    , c0EolValue
    , c1Decoder
    , c1Encoder
    , c1Value
    , c1map
    , c2EolDecoder
    , c2EolEncoder
    , c2EolMap
    , c2EolValue
    , c2Value
    , c2map
    , fCommentsDecoder
    , getImportName
    , getName
    , mapPair
    , moduleDecoder
    , moduleEncoder
    , openCommentedListMap
    , sequenceAC2
    , toCommentedList
    , typeDecoder
    , typeEncoder
    )

import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Parse.Primitives as P
import Compiler.Parse.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.Reporting.Annotation as A
import Utils.Bytes.Decode as BD
import Bytes.Decode
import Utils.Bytes.Encode as BE
import Bytes.Encode



-- FORMAT


type ForceMultiline
    = ForceMultiline Bool


type FComment
    = BlockComment (List String)
    | LineComment String
    | CommentTrickOpener
    | CommentTrickCloser
    | CommentTrickBlock String


type alias FComments =
    List FComment


type alias C1 a =
    ( FComments, a )


c1map : (a -> b) -> C1 a -> C1 b
c1map f ( comments, a ) =
    ( comments, f a )


c1Value : C1 a -> a
c1Value ( _, a ) =
    a


type alias C2 a =
    ( ( FComments, FComments ), a )


c2map : (a -> b) -> C2 a -> C2 b
c2map f ( ( before, after ), a ) =
    ( ( before, after ), f a )


c2Value : C2 a -> a
c2Value ( _, a ) =
    a


sequenceAC2 : List (C2 a) -> C2 (List a)
sequenceAC2 =
    List.foldr
        (\( ( before, after ), a ) ( ( beforeAcc, afterAcc ), acc ) ->
            ( ( before ++ beforeAcc, after ++ afterAcc ), a :: acc )
        )
        ( ( [], [] ), [] )


type alias C3 a =
    ( ( FComments, FComments, FComments ), a )


type alias C0Eol a =
    ( Maybe String, a )


c0EolMap : (a -> b) -> C0Eol a -> C0Eol b
c0EolMap f ( eol, a ) =
    ( eol, f a )


c0EolValue : C0Eol a -> a
c0EolValue ( _, a ) =
    a


type alias C1Eol a =
    ( FComments, Maybe String, a )


type alias C2Eol a =
    ( ( FComments, FComments, Maybe String ), a )


c2EolMap : (a -> b) -> C2Eol a -> C2Eol b
c2EolMap f ( ( before, after, eol ), a ) =
    ( ( before, after, eol ), f a )


c2EolValue : C2Eol a -> a
c2EolValue ( _, a ) =
    a


{-| This represents a list of things that have a clear start delimiter but no
clear end delimiter.
There must be at least one item.
Comments can appear before the last item, or around any other item.
An end-of-line comment can also appear after the last item.

For example:
= a
= a, b, c

TODO: this should be replaced with (Sequence a)

-}
type OpenCommentedList a
    = OpenCommentedList (List (C2Eol a)) (C1Eol a)


openCommentedListMap : (a -> b) -> OpenCommentedList a -> OpenCommentedList b
openCommentedListMap f (OpenCommentedList rest ( preLst, eolLst, lst )) =
    OpenCommentedList
        (List.map (\( ( pre, post, eol ), a ) -> ( ( pre, post, eol ), f a )) rest)
        ( preLst, eolLst, f lst )


toCommentedList : OpenCommentedList Type -> List (C2Eol Type)
toCommentedList (OpenCommentedList rest ( cLast, eolLast, last )) =
    rest ++ [ ( ( cLast, [], eolLast ), last ) ]


{-| Represents a delimiter-separated pair.

Comments can appear after the key or before the value.

For example:

key = value
key : value

-}
type Pair key value
    = Pair (C1 key) (C1 value) ForceMultiline


mapPair : (a1 -> a2) -> (b1 -> b2) -> Pair a1 b1 -> Pair a2 b2
mapPair fa fb (Pair k v fm) =
    Pair (c1map fa k) (c1map fb v) fm



-- EXPRESSIONS


type alias Expr =
    A.Located Expr_


type Expr_
    = Chr String
    | Str String Bool
    | Int Int String
    | Float Float String
    | Var VarType Name
    | VarQual VarType Name Name
    | List (List (C2Eol Expr)) FComments
    | Op Name
    | Negate Expr
    | Binops (List ( Expr, C2 (A.Located Name) )) Expr
    | Lambda (C1 (List (C1 Pattern))) (C1 Expr)
    | Call Expr (List (C1 Expr))
    | If (C1 ( C2 Expr, C2 Expr )) (List (C1 ( C2 Expr, C2 Expr ))) (C1 Expr)
    | Let (List (C2 (A.Located Def))) FComments Expr
    | Case (C2 Expr) (List ( C2 Pattern, C1 Expr ))
    | Accessor Name
    | Access Expr (A.Located Name)
    | Update (C2 Expr) (C1 (List (C2Eol ( C1 (A.Located Name), C1 Expr ))))
    | Record (C1 (List (C2Eol ( C1 (A.Located Name), C1 Expr ))))
    | Unit
    | Tuple (C2 Expr) (C2 Expr) (List (C2 Expr))
    | Shader Shader.Source Shader.Types
    | Parens (C2 Expr)


type VarType
    = LowVar
    | CapVar



-- DEFINITIONS


type Def
    = Define (A.Located Name) (List (C1 Pattern)) (C1 Expr) (Maybe (C1 (C2 Type)))
    | Destruct Pattern (C1 Expr)



-- PATTERN


type alias Pattern =
    A.Located Pattern_


type Pattern_
    = PAnything Name
    | PVar Name
    | PRecord (C1 (List (C2 (A.Located Name))))
    | PAlias (C1 Pattern) (C1 (A.Located Name))
    | PUnit FComments
    | PTuple (C2 Pattern) (C2 Pattern) (List (C2 Pattern))
    | PCtor A.Region Name (List (C1 Pattern))
    | PCtorQual A.Region Name Name (List (C1 Pattern))
    | PList (C1 (List (C2 Pattern)))
    | PCons (C0Eol Pattern) (C2Eol Pattern)
    | PChr String
    | PStr String Bool
    | PInt Int String
    | PParens (C2 Pattern)



-- TYPE


type alias Type =
    A.Located Type_


type Type_
    = TLambda (C0Eol Type) (C2Eol Type)
    | TVar Name
    | TType A.Region Name (List (C1 Type))
    | TTypeQual A.Region Name Name (List (C1 Type))
    | TRecord (List (C2 ( C1 (A.Located Name), C1 Type ))) (Maybe (C2 (A.Located Name))) FComments
    | TUnit
    | TTuple (C2Eol Type) (C2Eol Type) (List (C2Eol Type))
    | TParens (C2 Type)



-- MODULE


type Module
    = Module SyntaxVersion (Maybe (A.Located Name)) (A.Located Exposing) Docs (List Import) (List (A.Located Value)) (List (A.Located Union)) (List (A.Located Alias)) (List (A.Located Infix)) Effects


getName : Module -> Name
getName (Module _ maybeName _ _ _ _ _ _ _ _) =
    case maybeName of
        Just (A.At _ name) ->
            name

        Nothing ->
            Name.mainModule


getImportName : Import -> Name
getImportName (Import ( _, A.At _ name ) _ _) =
    name


type Import
    = Import (C1 (A.Located Name)) (Maybe (C2 Name)) (C2 Exposing)


type Value
    = Value FComments (C1 (A.Located Name)) (List (C1 Pattern)) (C1 Expr) (Maybe (C1 (C2 Type)))


type Union
    = Union (C2 (A.Located Name)) (List (C1 (A.Located Name))) (List (C2Eol ( A.Located Name, List (C1 Type) )))


type Alias
    = Alias FComments (C2 (A.Located Name)) (List (C1 (A.Located Name))) (C1 Type)


type Infix
    = Infix (C2 Name) (C1 Binop.Associativity) (C1 Binop.Precedence) (C1 Name)


type Port
    = Port FComments (C2 (A.Located Name)) Type


type Effects
    = NoEffects
    | Ports (List Port)
    | Manager A.Region Manager


type Manager
    = Cmd (C2 (C2 (A.Located Name)))
    | Sub (C2 (C2 (A.Located Name)))
    | Fx (C2 (C2 (A.Located Name))) (C2 (C2 (A.Located Name)))


type Docs
    = NoDocs A.Region (List ( Name, Comment ))
    | YesDocs Comment (List ( Name, Comment ))


type Comment
    = Comment P.Snippet



-- EXPOSING


type Exposing
    = Open FComments FComments
    | Explicit (A.Located (List (C2 Exposed)))


type Exposed
    = Lower (A.Located Name)
    | Upper (A.Located Name) (C1 Privacy)
    | Operator A.Region Name


type Privacy
    = Public A.Region
    | Private



-- ENCODERS and DECODERS


fCommentEncoder : FComment -> Bytes.Encode.Encoder
fCommentEncoder formatComment =
    case formatComment of
        BlockComment c ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.list BE.string c
                ]

        LineComment c ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string c
                ]

        CommentTrickOpener ->
            Bytes.Encode.unsignedInt8 2

        CommentTrickCloser ->
            Bytes.Encode.unsignedInt8 3

        CommentTrickBlock c ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.string c
                ]


fCommentDecoder : Bytes.Decode.Decoder FComment
fCommentDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map BlockComment (BD.list BD.string)

                    1 ->
                        Bytes.Decode.map LineComment BD.string

                    2 ->
                        Bytes.Decode.succeed CommentTrickOpener

                    3 ->
                        Bytes.Decode.succeed CommentTrickCloser

                    4 ->
                        Bytes.Decode.map CommentTrickBlock BD.string

                    _ ->
                        Bytes.Decode.fail
            )


fCommentsEncoder : FComments -> Bytes.Encode.Encoder
fCommentsEncoder =
    BE.list fCommentEncoder


fCommentsDecoder : Bytes.Decode.Decoder FComments
fCommentsDecoder =
    BD.list fCommentDecoder


c0EolEncoder : (a -> Bytes.Encode.Encoder) -> C0Eol a -> Bytes.Encode.Encoder
c0EolEncoder encoder ( eol, a ) =
    Bytes.Encode.sequence
        [ BE.maybe BE.string eol
        , encoder a
        ]


c0EolDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C0Eol a)
c0EolDecoder decoder =
    Bytes.Decode.map2 Tuple.pair
        (BD.maybe BD.string)
        decoder


c1Encoder : (a -> Bytes.Encode.Encoder) -> C1 a -> Bytes.Encode.Encoder
c1Encoder encoder ( comments, a ) =
    Bytes.Encode.sequence
        [ fCommentsEncoder comments
        , encoder a
        ]


c1Decoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C1 a)
c1Decoder decoder =
    Bytes.Decode.map2 Tuple.pair fCommentsDecoder decoder


c2Encoder : (a -> Bytes.Encode.Encoder) -> C2 a -> Bytes.Encode.Encoder
c2Encoder encoder ( ( preComments, postComments ), a ) =
    Bytes.Encode.sequence
        [ fCommentsEncoder preComments
        , fCommentsEncoder postComments
        , encoder a
        ]


c2Decoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C2 a)
c2Decoder decoder =
    Bytes.Decode.map3
        (\preComments postComments a ->
            ( ( preComments, postComments ), a )
        )
        fCommentsDecoder
        fCommentsDecoder
        decoder


c2EolEncoder : (a -> Bytes.Encode.Encoder) -> C2Eol a -> Bytes.Encode.Encoder
c2EolEncoder encoder ( ( preComments, postComments, eol ), a ) =
    Bytes.Encode.sequence
        [ fCommentsEncoder preComments
        , fCommentsEncoder postComments
        , BE.maybe BE.string eol
        , encoder a
        ]


c2EolDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C2Eol a)
c2EolDecoder decoder =
    Bytes.Decode.map4
        (\preComments postComments eol a ->
            ( ( preComments, postComments, eol ), a )
        )
        fCommentsDecoder
        fCommentsDecoder
        (BD.maybe BD.string)
        decoder


typeEncoder : Type -> Bytes.Encode.Encoder
typeEncoder =
    A.locatedEncoder internalTypeEncoder


typeDecoder : Bytes.Decode.Decoder Type
typeDecoder =
    A.locatedDecoder internalTypeDecoder


internalTypeEncoder : Type_ -> Bytes.Encode.Encoder
internalTypeEncoder type_ =
    case type_ of
        TLambda arg result ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , c0EolEncoder typeEncoder arg
                , c2EolEncoder typeEncoder result
                ]

        TVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        TType region name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string name
                , BE.list (c1Encoder typeEncoder) args
                ]

        TTypeQual region home name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoder region
                , BE.string home
                , BE.string name
                , BE.list (c1Encoder typeEncoder) args
                ]

        TRecord fields ext trailing ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.list (c2Encoder (BE.jsonPair (c1Encoder (A.locatedEncoder BE.string)) (c1Encoder typeEncoder))) fields
                , BE.maybe (c2Encoder (A.locatedEncoder BE.string)) ext
                , fCommentsEncoder trailing
                ]

        TUnit ->
            Bytes.Encode.unsignedInt8 5

        TTuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , c2EolEncoder typeEncoder a
                , c2EolEncoder typeEncoder b
                , BE.list (c2EolEncoder typeEncoder) cs
                ]

        TParens type__ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , c2Encoder typeEncoder type__
                ]


internalTypeDecoder : Bytes.Decode.Decoder Type_
internalTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 TLambda
                            (c0EolDecoder typeDecoder)
                            (c2EolDecoder typeDecoder)

                    1 ->
                        Bytes.Decode.map TVar BD.string

                    2 ->
                        Bytes.Decode.map3 TType
                            A.regionDecoder
                            BD.string
                            (BD.list (c1Decoder typeDecoder))

                    3 ->
                        Bytes.Decode.map4 TTypeQual
                            A.regionDecoder
                            BD.string
                            BD.string
                            (BD.list (c1Decoder typeDecoder))

                    4 ->
                        Bytes.Decode.map3 TRecord
                            (BD.list (c2Decoder (BD.jsonPair (c1Decoder (A.locatedDecoder BD.string)) (c1Decoder typeDecoder))))
                            (BD.maybe (c2Decoder (A.locatedDecoder BD.string)))
                            fCommentsDecoder

                    5 ->
                        Bytes.Decode.succeed TUnit

                    6 ->
                        Bytes.Decode.map3 TTuple
                            (c2EolDecoder typeDecoder)
                            (c2EolDecoder typeDecoder)
                            (BD.list (c2EolDecoder typeDecoder))

                    7 ->
                        Bytes.Decode.map TParens
                            (c2Decoder typeDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


moduleEncoder : Module -> Bytes.Encode.Encoder
moduleEncoder (Module syntaxVersion maybeName exports docs imports values unions aliases binops effects) =
    Bytes.Encode.sequence
        [ SV.encoder syntaxVersion
        , BE.maybe (A.locatedEncoder BE.string) maybeName
        , A.locatedEncoder exposingEncoder exports
        , docsEncoder docs
        , BE.list importEncoder imports
        , BE.list (A.locatedEncoder valueEncoder) values
        , BE.list (A.locatedEncoder unionEncoder) unions
        , BE.list (A.locatedEncoder aliasEncoder) aliases
        , BE.list (A.locatedEncoder infixEncoder) binops
        , effectsEncoder effects
        ]


moduleDecoder : Bytes.Decode.Decoder Module
moduleDecoder =
    BD.map8 (\( syntaxVersion, maybeName ) ( exports, docs ) -> Module syntaxVersion maybeName exports docs)
        (BD.jsonPair SV.decoder (BD.maybe (A.locatedDecoder BD.string)))
        (BD.jsonPair (A.locatedDecoder exposingDecoder) docsDecoder)
        (BD.list importDecoder)
        (BD.list (A.locatedDecoder valueDecoder))
        (BD.list (A.locatedDecoder unionDecoder))
        (BD.list (A.locatedDecoder aliasDecoder))
        (BD.list (A.locatedDecoder infixDecoder))
        effectsDecoder


exposingEncoder : Exposing -> Bytes.Encode.Encoder
exposingEncoder exposing_ =
    case exposing_ of
        Open preComments postComments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , fCommentsEncoder preComments
                , fCommentsEncoder postComments
                ]

        Explicit exposedList ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.locatedEncoder (BE.list (c2Encoder exposedEncoder)) exposedList
                ]


exposingDecoder : Bytes.Decode.Decoder Exposing
exposingDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Open
                            fCommentsDecoder
                            fCommentsDecoder

                    1 ->
                        Bytes.Decode.map Explicit (A.locatedDecoder (BD.list (c2Decoder exposedDecoder)))

                    _ ->
                        Bytes.Decode.fail
            )


docsEncoder : Docs -> Bytes.Encode.Encoder
docsEncoder docs =
    case docs of
        NoDocs region comments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.list (BE.jsonPair BE.string commentEncoder) comments
                ]

        YesDocs overview comments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , commentEncoder overview
                , BE.list (BE.jsonPair BE.string commentEncoder) comments
                ]


docsDecoder : Bytes.Decode.Decoder Docs
docsDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 NoDocs
                            A.regionDecoder
                            (BD.list (BD.jsonPair BD.string commentDecoder))

                    1 ->
                        Bytes.Decode.map2 YesDocs
                            commentDecoder
                            (BD.list (BD.jsonPair BD.string commentDecoder))

                    _ ->
                        Bytes.Decode.fail
            )


importEncoder : Import -> Bytes.Encode.Encoder
importEncoder (Import importName maybeAlias exposing_) =
    Bytes.Encode.sequence
        [ c1Encoder (A.locatedEncoder BE.string) importName
        , BE.maybe (c2Encoder BE.string) maybeAlias
        , c2Encoder exposingEncoder exposing_
        ]


importDecoder : Bytes.Decode.Decoder Import
importDecoder =
    Bytes.Decode.map3 Import
        (c1Decoder (A.locatedDecoder BD.string))
        (BD.maybe (c2Decoder BD.string))
        (c2Decoder exposingDecoder)


valueEncoder : Value -> Bytes.Encode.Encoder
valueEncoder (Value formatComments name srcArgs body maybeType) =
    Bytes.Encode.sequence
        [ fCommentsEncoder formatComments
        , c1Encoder (A.locatedEncoder BE.string) name
        , BE.list (c1Encoder patternEncoder) srcArgs
        , c1Encoder exprEncoder body
        , BE.maybe (c1Encoder (c2Encoder typeEncoder)) maybeType
        ]


valueDecoder : Bytes.Decode.Decoder Value
valueDecoder =
    Bytes.Decode.map5 Value
        fCommentsDecoder
        (c1Decoder (A.locatedDecoder BD.string))
        (BD.list (c1Decoder patternDecoder))
        (c1Decoder exprDecoder)
        (BD.maybe (c1Decoder (c2Decoder typeDecoder)))


unionEncoder : Union -> Bytes.Encode.Encoder
unionEncoder (Union name args constructors) =
    Bytes.Encode.sequence
        [ c2Encoder (A.locatedEncoder BE.string) name
        , BE.list (c1Encoder (A.locatedEncoder BE.string)) args
        , BE.list (c2EolEncoder (BE.jsonPair (A.locatedEncoder BE.string) (BE.list (c1Encoder typeEncoder)))) constructors
        ]


unionDecoder : Bytes.Decode.Decoder Union
unionDecoder =
    Bytes.Decode.map3 Union
        (c2Decoder (A.locatedDecoder BD.string))
        (BD.list (c1Decoder (A.locatedDecoder BD.string)))
        (BD.list (c2EolDecoder (BD.jsonPair (A.locatedDecoder BD.string) (BD.list (c1Decoder typeDecoder)))))


aliasEncoder : Alias -> Bytes.Encode.Encoder
aliasEncoder (Alias formatComments name args tipe) =
    Bytes.Encode.sequence
        [ fCommentsEncoder formatComments
        , c2Encoder (A.locatedEncoder BE.string) name
        , BE.list (c1Encoder (A.locatedEncoder BE.string)) args
        , c1Encoder typeEncoder tipe
        ]


aliasDecoder : Bytes.Decode.Decoder Alias
aliasDecoder =
    Bytes.Decode.map4 Alias
        fCommentsDecoder
        (c2Decoder (A.locatedDecoder BD.string))
        (BD.list (c1Decoder (A.locatedDecoder BD.string)))
        (c1Decoder typeDecoder)


infixEncoder : Infix -> Bytes.Encode.Encoder
infixEncoder (Infix op associativity precedence name) =
    Bytes.Encode.sequence
        [ c2Encoder BE.string op
        , c1Encoder Binop.associativityEncoder associativity
        , c1Encoder Binop.precedenceEncoder precedence
        , c1Encoder BE.string name
        ]


infixDecoder : Bytes.Decode.Decoder Infix
infixDecoder =
    Bytes.Decode.map4 Infix
        (c2Decoder BD.string)
        (c1Decoder Binop.associativityDecoder)
        (c1Decoder Binop.precedenceDecoder)
        (c1Decoder BD.string)


effectsEncoder : Effects -> Bytes.Encode.Encoder
effectsEncoder effects =
    case effects of
        NoEffects ->
            Bytes.Encode.unsignedInt8 0

        Ports ports ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list portEncoder ports
                ]

        Manager region manager ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , managerEncoder manager
                ]


effectsDecoder : Bytes.Decode.Decoder Effects
effectsDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed NoEffects

                    1 ->
                        Bytes.Decode.map Ports (BD.list portDecoder)

                    2 ->
                        Bytes.Decode.map2 Manager
                            A.regionDecoder
                            managerDecoder

                    _ ->
                        Bytes.Decode.fail
            )


commentEncoder : Comment -> Bytes.Encode.Encoder
commentEncoder (Comment snippet) =
    P.snippetEncoder snippet


commentDecoder : Bytes.Decode.Decoder Comment
commentDecoder =
    Bytes.Decode.map Comment P.snippetDecoder


portEncoder : Port -> Bytes.Encode.Encoder
portEncoder (Port typeComments name tipe) =
    Bytes.Encode.sequence
        [ fCommentsEncoder typeComments
        , c2Encoder (A.locatedEncoder BE.string) name
        , typeEncoder tipe
        ]


portDecoder : Bytes.Decode.Decoder Port
portDecoder =
    Bytes.Decode.map3 Port
        fCommentsDecoder
        (c2Decoder (A.locatedDecoder BD.string))
        typeDecoder


managerEncoder : Manager -> Bytes.Encode.Encoder
managerEncoder manager =
    case manager of
        Cmd cmdType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) cmdType
                ]

        Sub subType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) subType
                ]

        Fx cmdType subType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) cmdType
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) subType
                ]


managerDecoder : Bytes.Decode.Decoder Manager
managerDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Cmd (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))

                    1 ->
                        Bytes.Decode.map Sub (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))

                    2 ->
                        Bytes.Decode.map2 Fx
                            (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))
                            (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))

                    _ ->
                        Bytes.Decode.fail
            )


exposedEncoder : Exposed -> Bytes.Encode.Encoder
exposedEncoder exposed =
    case exposed of
        Lower name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.locatedEncoder BE.string name
                ]

        Upper name dotDotRegion ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.locatedEncoder BE.string name
                , c1Encoder privacyEncoder dotDotRegion
                ]

        Operator region name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string name
                ]


exposedDecoder : Bytes.Decode.Decoder Exposed
exposedDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Lower (A.locatedDecoder BD.string)

                    1 ->
                        Bytes.Decode.map2 Upper
                            (A.locatedDecoder BD.string)
                            (c1Decoder privacyDecoder)

                    2 ->
                        Bytes.Decode.map2 Operator
                            A.regionDecoder
                            BD.string

                    _ ->
                        Bytes.Decode.fail
            )


privacyEncoder : Privacy -> Bytes.Encode.Encoder
privacyEncoder privacy =
    case privacy of
        Public region ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                ]

        Private ->
            Bytes.Encode.unsignedInt8 1


privacyDecoder : Bytes.Decode.Decoder Privacy
privacyDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Public A.regionDecoder

                    1 ->
                        Bytes.Decode.succeed Private

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
        PAnything name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string name
                ]

        PVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        PRecord fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , c1Encoder (BE.list (c2Encoder (A.locatedEncoder BE.string))) fields
                ]

        PAlias aliasPattern name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , c1Encoder patternEncoder aliasPattern
                , c1Encoder (A.locatedEncoder BE.string) name
                ]

        PUnit comments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , fCommentsEncoder comments
                ]

        PTuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , c2Encoder patternEncoder a
                , c2Encoder patternEncoder b
                , BE.list (c2Encoder patternEncoder) cs
                ]

        PCtor nameRegion name patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoder nameRegion
                , BE.string name
                , BE.list (c1Encoder patternEncoder) patterns
                ]

        PCtorQual nameRegion home name patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoder nameRegion
                , BE.string home
                , BE.string name
                , BE.list (c1Encoder patternEncoder) patterns
                ]

        PList patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , c1Encoder (BE.list (c2Encoder patternEncoder)) patterns
                ]

        PCons hd tl ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , c0EolEncoder patternEncoder hd
                , c2EolEncoder patternEncoder tl
                ]

        PChr chr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.string chr
                ]

        PStr str multiline ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.string str
                , BE.bool multiline
                ]

        PInt int src ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , BE.int int
                , BE.string src
                ]

        PParens pattern ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , c2Encoder patternEncoder pattern
                ]


pattern_Decoder : Bytes.Decode.Decoder Pattern_
pattern_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map PAnything BD.string

                    1 ->
                        Bytes.Decode.map PVar BD.string

                    2 ->
                        Bytes.Decode.map PRecord (c1Decoder (BD.list (c2Decoder (A.locatedDecoder BD.string))))

                    3 ->
                        Bytes.Decode.map2 PAlias
                            (c1Decoder patternDecoder)
                            (c1Decoder (A.locatedDecoder BD.string))

                    4 ->
                        Bytes.Decode.map PUnit fCommentsDecoder

                    5 ->
                        Bytes.Decode.map3 PTuple
                            (c2Decoder patternDecoder)
                            (c2Decoder patternDecoder)
                            (BD.list (c2Decoder patternDecoder))

                    6 ->
                        Bytes.Decode.map3 PCtor
                            A.regionDecoder
                            BD.string
                            (BD.list (c1Decoder patternDecoder))

                    7 ->
                        Bytes.Decode.map4 PCtorQual
                            A.regionDecoder
                            BD.string
                            BD.string
                            (BD.list (c1Decoder patternDecoder))

                    8 ->
                        Bytes.Decode.map PList (c1Decoder (BD.list (c2Decoder patternDecoder)))

                    9 ->
                        Bytes.Decode.map2 PCons
                            (c0EolDecoder patternDecoder)
                            (c2EolDecoder patternDecoder)

                    10 ->
                        Bytes.Decode.map PChr BD.string

                    11 ->
                        Bytes.Decode.map2 PStr
                            BD.string
                            BD.bool

                    12 ->
                        Bytes.Decode.map2 PInt
                            BD.int
                            BD.string

                    13 ->
                        Bytes.Decode.map PParens (c2Decoder patternDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder =
    A.locatedEncoder expr_Encoder


exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    A.locatedDecoder expr_Decoder


expr_Encoder : Expr_ -> Bytes.Encode.Encoder
expr_Encoder expr_ =
    case expr_ of
        Chr char ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string char
                ]

        Str string multiline ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string string
                , BE.bool multiline
                ]

        Int int src ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.int int
                , BE.string src
                ]

        Float float src ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.float float
                , BE.string src
                ]

        Var varType name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , varTypeEncoder varType
                , BE.string name
                ]

        VarQual varType prefix name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , varTypeEncoder varType
                , BE.string prefix
                , BE.string name
                ]

        List list trailing ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.list (c2EolEncoder exprEncoder) list
                , fCommentsEncoder trailing
                ]

        Op op ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.string op
                ]

        Negate expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , exprEncoder expr
                ]

        Binops ops final ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.list (BE.jsonPair exprEncoder (c2Encoder (A.locatedEncoder BE.string))) ops
                , exprEncoder final
                ]

        Lambda srcArgs body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , c1Encoder (BE.list (c1Encoder patternEncoder)) srcArgs
                , c1Encoder exprEncoder body
                ]

        Call func args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoder func
                , BE.list (c1Encoder exprEncoder) args
                ]

        If firstBranch branches finally ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , c1Encoder (BE.jsonPair (c2Encoder exprEncoder) (c2Encoder exprEncoder)) firstBranch
                , BE.list (c1Encoder (BE.jsonPair (c2Encoder exprEncoder) (c2Encoder exprEncoder))) branches
                , c1Encoder exprEncoder finally
                ]

        Let defs comments expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , BE.list (c2Encoder (A.locatedEncoder defEncoder)) defs
                , fCommentsEncoder comments
                , exprEncoder expr
                ]

        Case expr branches ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , c2Encoder exprEncoder expr
                , BE.list (BE.jsonPair (c2Encoder patternEncoder) (c1Encoder exprEncoder)) branches
                ]

        Accessor field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.string field
                ]

        Access record field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , exprEncoder record
                , A.locatedEncoder BE.string field
                ]

        Update name fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , c2Encoder exprEncoder name
                , c1Encoder (BE.list (c2EolEncoder (BE.jsonPair (c1Encoder (A.locatedEncoder BE.string)) (c1Encoder exprEncoder)))) fields
                ]

        Record fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , c1Encoder (BE.list (c2EolEncoder (BE.jsonPair (c1Encoder (A.locatedEncoder BE.string)) (c1Encoder exprEncoder)))) fields
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 19

        Tuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , c2Encoder exprEncoder a
                , c2Encoder exprEncoder b
                , BE.list (c2Encoder exprEncoder) cs
                ]

        Shader src tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , Shader.sourceEncoder src
                , Shader.typesEncoder tipe
                ]

        Parens expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , c2Encoder exprEncoder expr
                ]


expr_Decoder : Bytes.Decode.Decoder Expr_
expr_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Chr BD.string

                    1 ->
                        Bytes.Decode.map2 Str
                            BD.string
                            BD.bool

                    2 ->
                        Bytes.Decode.map2 Int
                            BD.int
                            BD.string

                    3 ->
                        Bytes.Decode.map2 Float
                            BD.float
                            BD.string

                    4 ->
                        Bytes.Decode.map2 Var
                            varTypeDecoder
                            BD.string

                    5 ->
                        Bytes.Decode.map3 VarQual
                            varTypeDecoder
                            BD.string
                            BD.string

                    6 ->
                        Bytes.Decode.map2 List
                            (BD.list (c2EolDecoder exprDecoder))
                            fCommentsDecoder

                    7 ->
                        Bytes.Decode.map Op BD.string

                    8 ->
                        Bytes.Decode.map Negate exprDecoder

                    9 ->
                        Bytes.Decode.map2 Binops
                            (BD.list (BD.jsonPair exprDecoder (c2Decoder (A.locatedDecoder BD.string))))
                            exprDecoder

                    10 ->
                        Bytes.Decode.map2 Lambda
                            (c1Decoder (BD.list (c1Decoder patternDecoder)))
                            (c1Decoder exprDecoder)

                    11 ->
                        Bytes.Decode.map2 Call
                            exprDecoder
                            (BD.list (c1Decoder exprDecoder))

                    12 ->
                        Bytes.Decode.map3 If
                            (c1Decoder (BD.jsonPair (c2Decoder exprDecoder) (c2Decoder exprDecoder)))
                            (BD.list (c1Decoder (BD.jsonPair (c2Decoder exprDecoder) (c2Decoder exprDecoder))))
                            (c1Decoder exprDecoder)

                    13 ->
                        Bytes.Decode.map3 Let
                            (BD.list (c2Decoder (A.locatedDecoder defDecoder)))
                            fCommentsDecoder
                            exprDecoder

                    14 ->
                        Bytes.Decode.map2 Case
                            (c2Decoder exprDecoder)
                            (BD.list (BD.jsonPair (c2Decoder patternDecoder) (c1Decoder exprDecoder)))

                    15 ->
                        Bytes.Decode.map Accessor BD.string

                    16 ->
                        Bytes.Decode.map2 Access
                            exprDecoder
                            (A.locatedDecoder BD.string)

                    17 ->
                        Bytes.Decode.map2 Update
                            (c2Decoder exprDecoder)
                            (c1Decoder (BD.list (c2EolDecoder (BD.jsonPair (c1Decoder (A.locatedDecoder BD.string)) (c1Decoder exprDecoder)))))

                    18 ->
                        Bytes.Decode.map Record
                            (c1Decoder (BD.list (c2EolDecoder (BD.jsonPair (c1Decoder (A.locatedDecoder BD.string)) (c1Decoder exprDecoder)))))

                    19 ->
                        Bytes.Decode.succeed Unit

                    20 ->
                        Bytes.Decode.map3 Tuple
                            (c2Decoder exprDecoder)
                            (c2Decoder exprDecoder)
                            (BD.list (c2Decoder exprDecoder))

                    21 ->
                        Bytes.Decode.map2 Shader
                            Shader.sourceDecoder
                            Shader.typesDecoder

                    22 ->
                        Bytes.Decode.map Parens (c2Decoder exprDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


varTypeEncoder : VarType -> Bytes.Encode.Encoder
varTypeEncoder varType =
    Bytes.Encode.unsignedInt8
        (case varType of
            LowVar ->
                0

            CapVar ->
                1
        )


varTypeDecoder : Bytes.Decode.Decoder VarType
varTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed LowVar

                    1 ->
                        Bytes.Decode.succeed CapVar

                    _ ->
                        Bytes.Decode.fail
            )


defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Define name srcArgs body maybeType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.locatedEncoder BE.string name
                , BE.list (c1Encoder patternEncoder) srcArgs
                , c1Encoder exprEncoder body
                , BE.maybe (c1Encoder (c2Encoder typeEncoder)) maybeType
                ]

        Destruct pattern body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , patternEncoder pattern
                , c1Encoder exprEncoder body
                ]


defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 Define
                            (A.locatedDecoder BD.string)
                            (BD.list (c1Decoder patternDecoder))
                            (c1Decoder exprDecoder)
                            (BD.maybe (c1Decoder (c2Decoder typeDecoder)))

                    1 ->
                        Bytes.Decode.map2 Destruct
                            patternDecoder
                            (c1Decoder exprDecoder)

                    _ ->
                        Bytes.Decode.fail
            )
