module Compiler.Elm.Docs exposing
    ( Alias(..)
    , Binop(..)
    , Comment
    , DocsBinopData
    , Documentation
    , Error(..)
    , Module(..)
    , ModuleData
    , Union(..)
    , Value(..)
    , bytesDecoder
    , bytesEncoder
    , bytesModuleDecoder
    , bytesModuleEncoder
    , decoder
    , encode
    , fromModule
    , jsonDecoder
    , jsonEncoder
    , jsonModuleDecoder
    , jsonModuleEncoder
    , parseOverview
    )

import Basics.Extra exposing (flip)
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Compiler.Type as Type
import Compiler.Elm.Compiler.Type.Extract as Extract
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Json.String as Json
import Compiler.Parse.Primitives as P exposing (Col, Row, word1)
import Compiler.Parse.Space as Space
import Compiler.Parse.Symbol as Symbol
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Docs as E
import Compiler.Reporting.Result as ReportingResult
import Data.Map as Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- DOCUMENTATION


type alias Documentation =
    Dict String Name Module


type alias ModuleData =
    { name : Name
    , comment : Comment
    , unions : Dict String Name Union
    , aliases : Dict String Name Alias
    , values : Dict String Name Value
    , binops : Dict String Name Binop
    }


type Module
    = Module ModuleData


type alias Comment =
    String


type Alias
    = Alias Comment (List Name) Type.Type


type Union
    = Union Comment (List Name) (List ( Name, List Type.Type ))


type Value
    = Value Comment Type.Type


type alias DocsBinopData =
    { comment : Comment
    , tipe : Type.Type
    , associativity : Binop.Associativity
    , precedence : Binop.Precedence
    }


type Binop
    = Binop DocsBinopData



-- JSON


encode : Documentation -> E.Value
encode docs =
    E.list encodeModule (Dict.values compare docs)


encodeModule : Module -> E.Value
encodeModule (Module moduleData) =
    E.object
        [ ( "name", ModuleName.encode moduleData.name )
        , ( "comment", E.string moduleData.comment )
        , ( "unions", E.list encodeUnion (Dict.toList compare moduleData.unions) )
        , ( "aliases", E.list encodeAlias (Dict.toList compare moduleData.aliases) )
        , ( "values", E.list encodeValue (Dict.toList compare moduleData.values) )
        , ( "binops", E.list encodeBinop (Dict.toList compare moduleData.binops) )
        ]


type Error
    = BadAssociativity
    | BadModuleName
    | BadType


decoder : D.Decoder Error Documentation
decoder =
    D.map toDict (D.list moduleDecoder)


toDict : List Module -> Documentation
toDict modules =
    Dict.fromList identity (List.map toDictHelp modules)


toDictHelp : Module -> ( Name.Name, Module )
toDictHelp ((Module moduleData) as modul) =
    ( moduleData.name, modul )


moduleDecoder : D.Decoder Error Module
moduleDecoder =
    D.map (\name_ comment_ unions_ aliases_ values_ binops_ -> Module { name = name_, comment = comment_, unions = unions_, aliases = aliases_, values = values_, binops = binops_ }) (D.field "name" moduleNameDecoder)
        |> D.apply (D.field "comment" D.string)
        |> D.apply (D.field "unions" (dictDecoder union))
        |> D.apply (D.field "aliases" (dictDecoder alias_))
        |> D.apply (D.field "values" (dictDecoder value))
        |> D.apply (D.field "binops" (dictDecoder binop))


dictDecoder : D.Decoder Error a -> D.Decoder Error (Dict String Name a)
dictDecoder entryDecoder =
    D.map (Dict.fromList identity) (D.list (named entryDecoder))


named : D.Decoder Error a -> D.Decoder Error ( Name.Name, a )
named entryDecoder =
    D.map Tuple.pair (D.field "name" nameDecoder)
        |> D.apply entryDecoder


nameDecoder : D.Decoder e Name
nameDecoder =
    D.string


moduleNameDecoder : D.Decoder Error ModuleName.Raw
moduleNameDecoder =
    D.mapError (always BadModuleName) ModuleName.decoder


typeDecoder : D.Decoder Error Type.Type
typeDecoder =
    D.mapError (always BadType) Type.decoder



-- UNION JSON


encodeUnion : ( Name, Union ) -> E.Value
encodeUnion ( name, Union comment args cases ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string comment )
        , ( "args", E.list E.name args )
        , ( "cases", E.list encodeCase cases )
        ]


union : D.Decoder Error Union
union =
    D.map Union (D.field "comment" D.string)
        |> D.apply (D.field "args" (D.list nameDecoder))
        |> D.apply (D.field "cases" (D.list caseDecoder))


encodeCase : ( Name, List Type.Type ) -> E.Value
encodeCase ( tag, args ) =
    E.list identity [ E.name tag, E.list Type.encode args ]


caseDecoder : D.Decoder Error ( Name.Name, List Type.Type )
caseDecoder =
    D.pair nameDecoder (D.list typeDecoder)



-- ALIAS JSON


encodeAlias : ( Name, Alias ) -> E.Value
encodeAlias ( name, Alias comment args tipe ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string comment )
        , ( "args", E.list E.name args )
        , ( "type", Type.encode tipe )
        ]


alias_ : D.Decoder Error Alias
alias_ =
    D.map Alias (D.field "comment" D.string)
        |> D.apply (D.field "args" (D.list nameDecoder))
        |> D.apply (D.field "type" typeDecoder)



-- VALUE JSON


encodeValue : ( Name.Name, Value ) -> E.Value
encodeValue ( name, Value comment tipe ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string comment )
        , ( "type", Type.encode tipe )
        ]


value : D.Decoder Error Value
value =
    D.map Value (D.field "comment" D.string)
        |> D.apply (D.field "type" typeDecoder)



-- BINOP JSON


encodeBinop : ( Name, Binop ) -> E.Value
encodeBinop ( name, Binop data ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string data.comment )
        , ( "type", Type.encode data.tipe )
        , ( "associativity", encodeAssoc data.associativity )
        , ( "precedence", encodePrec data.precedence )
        ]


binop : D.Decoder Error Binop
binop =
    D.map (\comment tipe assoc prec -> Binop { comment = comment, tipe = tipe, associativity = assoc, precedence = prec }) (D.field "comment" D.string)
        |> D.apply (D.field "type" typeDecoder)
        |> D.apply (D.field "associativity" assocDecoder)
        |> D.apply (D.field "precedence" precDecoder)



-- ASSOCIATIVITY JSON


encodeAssoc : Binop.Associativity -> E.Value
encodeAssoc assoc =
    case assoc of
        Binop.Left ->
            E.string "left"

        Binop.Non ->
            E.string "non"

        Binop.Right ->
            E.string "right"


assocDecoder : D.Decoder Error Binop.Associativity
assocDecoder =
    let
        left : String
        left =
            "left"

        non : String
        non =
            "non"

        right : String
        right =
            "right"
    in
    D.string
        |> D.andThen
            (\str ->
                if str == left then
                    D.pure Binop.Left

                else if str == non then
                    D.pure Binop.Non

                else if str == right then
                    D.pure Binop.Right

                else
                    D.failure BadAssociativity
            )



-- PRECEDENCE JSON


encodePrec : Binop.Precedence -> E.Value
encodePrec n =
    E.int n


precDecoder : D.Decoder Error Binop.Precedence
precDecoder =
    D.int



-- FROM MODULE


fromModule : Can.Module -> Result E.Error Module
fromModule ((Can.Module canData) as modul) =
    case canData.exports of
        Can.ExportEverything region ->
            Err (E.ImplicitExposing region)

        Can.Export exportDict ->
            case canData.docs of
                Src.NoDocs region _ ->
                    Err (E.NoDocs region)

                Src.YesDocs overview comments ->
                    parseOverview overview
                        |> Result.andThen (checkNames exportDict)
                        |> Result.andThen (\_ -> checkDefs exportDict overview (Dict.fromList identity comments) modul)



-- PARSE OVERVIEW


parseOverview : Src.Comment -> Result E.Error (List (A.Located Name.Name))
parseOverview (Src.Comment snippet) =
    case P.fromSnippet (chompOverview []) E.BadEnd snippet of
        Err err ->
            Err (E.SyntaxProblem err)

        Ok names ->
            Ok names


type alias Parser a =
    P.Parser E.SyntaxProblem a


chompOverview : List (A.Located Name.Name) -> Parser (List (A.Located Name.Name))
chompOverview =
    P.loop chompOverviewHelp


chompOverviewHelp : List (A.Located Name.Name) -> Parser (P.Step (List (A.Located Name.Name)) (List (A.Located Name.Name)))
chompOverviewHelp names =
    chompUntilDocs
        |> P.andThen
            (\isDocs ->
                if isDocs then
                    Space.chomp E.Space
                        |> P.andThen (\_ -> chompDocs names)
                        |> P.map P.Loop

                else
                    P.pure (P.Done names)
            )


chompDocs : List (A.Located Name.Name) -> Parser (List (A.Located Name.Name))
chompDocs =
    P.loop chompDocsHelp


chompDocsHelp : List (A.Located Name.Name) -> Parser (P.Step (List (A.Located Name.Name)) (List (A.Located Name.Name)))
chompDocsHelp names =
    P.addLocation
        (P.oneOf E.Name
            [ Var.lower E.Name
            , Var.upper E.Name
            , chompOperator
            ]
        )
        |> P.andThen
            (\name ->
                Space.chomp E.Space
                    |> P.andThen
                        (\_ ->
                            P.oneOfWithFallback
                                [ P.getPosition
                                    |> P.andThen
                                        (\pos ->
                                            Space.checkIndent pos E.Comma
                                                |> P.andThen
                                                    (\_ ->
                                                        word1 ',' E.Comma
                                                            |> P.andThen
                                                                (\_ ->
                                                                    Space.chomp E.Space
                                                                        |> P.map (\_ -> P.Loop (name :: names))
                                                                )
                                                    )
                                        )
                                ]
                                (P.Done (name :: names))
                        )
            )


chompOperator : Parser Name
chompOperator =
    word1 '(' E.Op
        |> P.andThen
            (\_ ->
                Symbol.operator E.Op E.OpBad
                    |> P.andThen
                        (\op ->
                            word1 ')' E.Op
                                |> P.map (\_ -> op)
                        )
            )



-- TODO add rule that @docs must be after newline in 0.20
--


chompUntilDocs : Parser Bool
chompUntilDocs =
    P.Parser
        (\(P.State st) ->
            let
                ( ( isDocs, newPos ), ( newRow, newCol ) ) =
                    untilDocs st.src st.pos st.end st.row st.col

                newState : P.State
                newState =
                    P.State { st | pos = newPos, row = newRow, col = newCol }
            in
            P.Cok isDocs newState
        )


untilDocs : String -> Int -> Int -> Row -> Col -> ( ( Bool, Int ), ( Row, Col ) )
untilDocs src pos end row col =
    if pos >= end then
        ( ( False, pos ), ( row, col ) )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '\n' then
            untilDocs src (pos + 1) end (row + 1) 1

        else
            let
                pos5 : Int
                pos5 =
                    pos + 5
            in
            if
                (pos5 <= end)
                    && (P.unsafeIndex src pos == '@')
                    && (P.unsafeIndex src (pos + 1) == 'd')
                    && (P.unsafeIndex src (pos + 2) == 'o')
                    && (P.unsafeIndex src (pos + 3) == 'c')
                    && (P.unsafeIndex src (pos + 4) == 's')
                    && (Var.getInnerWidth src pos5 end == 0)
            then
                ( ( True, pos5 ), ( row, col + 5 ) )

            else
                let
                    newPos : Int
                    newPos =
                        pos + P.getCharWidth word
                in
                untilDocs src newPos end row (col + 1)



-- CHECK NAMES


checkNames : Dict String Name (A.Located Can.Export) -> List (A.Located Name) -> Result E.Error ()
checkNames exports names =
    let
        docs : DocNameRegions
        docs =
            List.foldl addName Dict.empty names

        loneExport : Name -> A.Located Can.Export -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        loneExport name export_ _ =
            onlyInExports name export_

        checkBoth : Name -> A.Located Can.Export -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        checkBoth n _ r _ =
            isUnique n r

        loneDoc : Name -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        loneDoc name regions _ =
            onlyInDocs name regions
    in
    case ReportingResult.run (Dict.merge compare loneExport checkBoth loneDoc exports docs (ReportingResult.ok A.zero)) of
        ( _, Ok _ ) ->
            Ok ()

        ( _, Err es ) ->
            Err (E.NameProblems (OneOrMore.destruct NE.Nonempty es))


type alias DocNameRegions =
    Dict String Name (OneOrMore.OneOrMore A.Region)


addName : A.Located Name -> DocNameRegions -> DocNameRegions
addName (A.At region name) dict =
    Utils.mapInsertWith identity OneOrMore.more name (OneOrMore.one region) dict


isUnique : Name -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
isUnique name regions =
    case regions of
        OneOrMore.One region ->
            ReportingResult.ok region

        OneOrMore.More left right ->
            let
                ( r1, r2 ) =
                    OneOrMore.getFirstTwo left right
            in
            ReportingResult.throw (E.NameDuplicate name r1 r2)


onlyInDocs : Name -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem a
onlyInDocs name regions =
    isUnique name regions
        |> ReportingResult.andThen
            (\region ->
                ReportingResult.throw (E.NameOnlyInDocs name region)
            )


onlyInExports : Name -> A.Located Can.Export -> ReportingResult.RResult i w E.NameProblem a
onlyInExports name (A.At region _) =
    ReportingResult.throw (E.NameOnlyInExports name region)



-- CHECK DEFS


checkDefs : Dict String Name (A.Located Can.Export) -> Src.Comment -> Dict String Name Src.Comment -> Can.Module -> Result E.Error Module
checkDefs exportDict overview comments (Can.Module canData) =
    let
        types : Types
        types =
            gatherTypes canData.decls Dict.empty

        info : Info
        info =
            Info { comments = comments, types = types, unions = canData.unions, aliases = canData.aliases, binops = canData.binops, effects = canData.effects }
    in
    case ReportingResult.run (ReportingResult.mapTraverseWithKey identity compare (checkExport info) exportDict) of
        ( _, Err problems ) ->
            Err (E.DefProblems (OneOrMore.destruct NE.Nonempty problems))

        ( _, Ok inserters ) ->
            Ok (Dict.foldr compare (\_ -> (<|)) (emptyModule canData.name overview) inserters)


emptyModule : IO.Canonical -> Src.Comment -> Module
emptyModule (IO.Canonical _ name) (Src.Comment overview) =
    Module { name = name, comment = Json.fromComment overview, unions = Dict.empty, aliases = Dict.empty, values = Dict.empty, binops = Dict.empty }


type alias InfoData =
    { comments : Dict String Name.Name Src.Comment
    , types : Dict String Name.Name (Result A.Region Can.Type)
    , unions : Dict String Name.Name Can.Union
    , aliases : Dict String Name.Name Can.Alias
    , binops : Dict String Name.Name Can.Binop
    , effects : Can.Effects
    }


type Info
    = Info InfoData


checkExport : Info -> Name -> A.Located Can.Export -> ReportingResult.RResult i w E.DefProblem (Module -> Module)
checkExport ((Info infoData) as info) name (A.At region export) =
    let
        iUnions =
            infoData.unions

        iAliases =
            infoData.aliases

        iBinops =
            infoData.binops
    in
    case export of
        Can.ExportValue ->
            getType name info
                |> ReportingResult.andThen
                    (\tipe ->
                        getComment region name info
                            |> ReportingResult.andThen
                                (\comment ->
                                    ReportingResult.ok
                                        (\(Module mData) ->
                                            Module { mData | values = Dict.insert identity name (Value comment tipe) mData.values }
                                        )
                                )
                    )

        Can.ExportBinop ->
            let
                (Can.Binop_ assoc prec realName) =
                    Utils.find identity name iBinops
            in
            getType realName info
                |> ReportingResult.andThen
                    (\tipe ->
                        getComment region realName info
                            |> ReportingResult.andThen
                                (\comment ->
                                    ReportingResult.ok
                                        (\(Module mData) ->
                                            Module { mData | binops = Dict.insert identity name (Binop { comment = comment, tipe = tipe, associativity = assoc, precedence = prec }) mData.binops }
                                        )
                                )
                    )

        Can.ExportAlias ->
            let
                (Can.Alias tvars tipe) =
                    Utils.find identity name iAliases
            in
            getComment region name info
                |> ReportingResult.andThen
                    (\comment ->
                        ReportingResult.ok
                            (\(Module mData) ->
                                Module { mData | aliases = Dict.insert identity name (Alias comment tvars (Extract.fromType tipe)) mData.aliases }
                            )
                    )

        Can.ExportUnionOpen ->
            let
                (Can.Union unionData) =
                    Utils.find identity name iUnions
            in
            getComment region name info
                |> ReportingResult.andThen
                    (\comment ->
                        ReportingResult.ok
                            (\(Module mData) ->
                                Module { mData | unions = Dict.insert identity name (Union comment unionData.vars (List.map dector unionData.alts)) mData.unions }
                            )
                    )

        Can.ExportUnionClosed ->
            let
                (Can.Union unionData) =
                    Utils.find identity name iUnions
            in
            getComment region name info
                |> ReportingResult.andThen
                    (\comment ->
                        ReportingResult.ok
                            (\(Module mData) ->
                                Module { mData | unions = Dict.insert identity name (Union comment unionData.vars []) mData.unions }
                            )
                    )

        Can.ExportPort ->
            getType name info
                |> ReportingResult.andThen
                    (\tipe ->
                        getComment region name info
                            |> ReportingResult.andThen
                                (\comment ->
                                    ReportingResult.ok
                                        (\(Module mData) ->
                                            Module { mData | values = Dict.insert identity name (Value comment tipe) mData.values }
                                        )
                                )
                    )


getComment : A.Region -> Name.Name -> Info -> ReportingResult.RResult i w E.DefProblem Comment
getComment region name (Info infoData) =
    case Dict.get identity name infoData.comments of
        Nothing ->
            ReportingResult.throw (E.NoComment name region)

        Just (Src.Comment snippet) ->
            ReportingResult.ok (Json.fromComment snippet)


getType : Name.Name -> Info -> ReportingResult.RResult i w E.DefProblem Type.Type
getType name (Info infoData) =
    case Utils.find identity name infoData.types of
        Err region ->
            ReportingResult.throw (E.NoAnnotation name region)

        Ok tipe ->
            ReportingResult.ok (Extract.fromType tipe)


dector : Can.Ctor -> ( Name, List Type.Type )
dector (Can.Ctor c) =
    ( c.name, List.map Extract.fromType c.args )



-- GATHER TYPES


type alias Types =
    Dict String Name.Name (Result A.Region Can.Type)


gatherTypes : Can.Decls -> Types -> Types
gatherTypes decls types =
    case decls of
        Can.Declare def subDecls ->
            gatherTypes subDecls (addDef types def)

        Can.DeclareRec def defs subDecls ->
            gatherTypes subDecls (List.foldl (flip addDef) (addDef types def) defs)

        Can.SaveTheEnvironment ->
            types


addDef : Types -> Can.Def -> Types
addDef types def =
    case def of
        Can.Def (A.At region name) _ _ ->
            Dict.insert identity name (Err region) types

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                tipe : Can.Type
                tipe =
                    List.foldr Can.TLambda resultType (List.map Tuple.second typedArgs)
            in
            Dict.insert identity name (Ok tipe) types



-- JSON ENCODERS and DECODERS


jsonEncoder : Documentation -> Encode.Value
jsonEncoder =
    E.toJsonValue << encode


jsonDecoder : Decode.Decoder Documentation
jsonDecoder =
    Decode.map toDict (Decode.list jsonModuleDecoder)


jsonModuleEncoder : Module -> Encode.Value
jsonModuleEncoder (Module moduleData) =
    Encode.object
        [ ( "name", Encode.string moduleData.name )
        , ( "comment", Encode.string moduleData.comment )
        , ( "unions", E.assocListDict compare Encode.string jsonUnionEncoder moduleData.unions )
        , ( "aliases", E.assocListDict compare Encode.string jsonAliasEncoder moduleData.aliases )
        , ( "values", E.assocListDict compare Encode.string jsonValueEncoder moduleData.values )
        , ( "binops", E.assocListDict compare Encode.string jsonBinopEncoder moduleData.binops )
        ]


jsonModuleDecoder : Decode.Decoder Module
jsonModuleDecoder =
    Decode.map6 (\name_ comment_ unions_ aliases_ values_ binops_ -> Module { name = name_, comment = comment_, unions = unions_, aliases = aliases_, values = values_, binops = binops_ })
        (Decode.field "name" Decode.string)
        (Decode.field "comment" Decode.string)
        (Decode.field "unions" (D.assocListDict identity Decode.string jsonUnionDecoder))
        (Decode.field "aliases" (D.assocListDict identity Decode.string jsonAliasDecoder))
        (Decode.field "values" (D.assocListDict identity Decode.string jsonValueDecoder))
        (Decode.field "binops" (D.assocListDict identity Decode.string jsonBinopDecoder))


jsonUnionEncoder : Union -> Encode.Value
jsonUnionEncoder (Union comment args cases) =
    Encode.object
        [ ( "comment", Encode.string comment )
        , ( "args", Encode.list Encode.string args )
        , ( "cases", Encode.list (E.jsonPair Encode.string (Encode.list Type.jsonEncoder)) cases )
        ]


jsonUnionDecoder : Decode.Decoder Union
jsonUnionDecoder =
    Decode.map3 Union
        (Decode.field "comment" Decode.string)
        (Decode.field "args" (Decode.list Decode.string))
        (Decode.field "cases" (Decode.list (D.jsonPair Decode.string (Decode.list Type.jsonDecoder))))


jsonAliasEncoder : Alias -> Encode.Value
jsonAliasEncoder (Alias comment args type_) =
    Encode.object
        [ ( "comment", Encode.string comment )
        , ( "args", Encode.list Encode.string args )
        , ( "type", Type.jsonEncoder type_ )
        ]


jsonAliasDecoder : Decode.Decoder Alias
jsonAliasDecoder =
    Decode.map3 Alias
        (Decode.field "comment" Decode.string)
        (Decode.field "args" (Decode.list Decode.string))
        (Decode.field "type" Type.jsonDecoder)


jsonValueEncoder : Value -> Encode.Value
jsonValueEncoder (Value comment type_) =
    Encode.object
        [ ( "comment", Encode.string comment )
        , ( "type", Type.jsonEncoder type_ )
        ]


jsonValueDecoder : Decode.Decoder Value
jsonValueDecoder =
    Decode.map2 Value
        (Decode.field "comment" Decode.string)
        (Decode.field "type" Type.jsonDecoder)


jsonBinopEncoder : Binop -> Encode.Value
jsonBinopEncoder (Binop data) =
    Encode.object
        [ ( "comment", Encode.string data.comment )
        , ( "type", Type.jsonEncoder data.tipe )
        , ( "associativity", Binop.jsonAssociativityEncoder data.associativity )
        , ( "precedence", Binop.jsonPrecedenceEncoder data.precedence )
        ]


jsonBinopDecoder : Decode.Decoder Binop
jsonBinopDecoder =
    Decode.map4
        (\comment tipe associativity precedence ->
            Binop { comment = comment, tipe = tipe, associativity = associativity, precedence = precedence }
        )
        (Decode.field "comment" Decode.string)
        (Decode.field "type" Type.jsonDecoder)
        (Decode.field "associativity" Binop.jsonAssociativityDecoder)
        (Decode.field "precedence" Binop.jsonPrecedenceDecoder)



-- ENCODERS and DECODERS


bytesEncoder : Documentation -> Bytes.Encode.Encoder
bytesEncoder docs =
    BE.list bytesModuleEncoder (Dict.values compare docs)


bytesDecoder : Bytes.Decode.Decoder Documentation
bytesDecoder =
    Bytes.Decode.map toDict (BD.list bytesModuleDecoder)


bytesModuleEncoder : Module -> Bytes.Encode.Encoder
bytesModuleEncoder (Module moduleData) =
    Bytes.Encode.sequence
        [ BE.string moduleData.name
        , BE.string moduleData.comment
        , BE.assocListDict compare BE.string bytesUnionEncoder moduleData.unions
        , BE.assocListDict compare BE.string bytesAliasEncoder moduleData.aliases
        , BE.assocListDict compare BE.string bytesValueEncoder moduleData.values
        , BE.assocListDict compare BE.string bytesBinopEncoder moduleData.binops
        ]


bytesModuleDecoder : Bytes.Decode.Decoder Module
bytesModuleDecoder =
    BD.map6 (\name_ comment_ unions_ aliases_ values_ binops_ -> Module { name = name_, comment = comment_, unions = unions_, aliases = aliases_, values = values_, binops = binops_ })
        BD.string
        BD.string
        (BD.assocListDict identity BD.string bytesUnionDecoder)
        (BD.assocListDict identity BD.string bytesAliasDecoder)
        (BD.assocListDict identity BD.string bytesValueDecoder)
        (BD.assocListDict identity BD.string bytesBinopDecoder)


bytesUnionEncoder : Union -> Bytes.Encode.Encoder
bytesUnionEncoder (Union comment args cases) =
    Bytes.Encode.sequence
        [ BE.string comment
        , BE.list BE.string args
        , BE.list (BE.jsonPair BE.string (BE.list Type.bytesEncoder)) cases
        ]


bytesUnionDecoder : Bytes.Decode.Decoder Union
bytesUnionDecoder =
    Bytes.Decode.map3 Union
        BD.string
        (BD.list BD.string)
        (BD.list (BD.jsonPair BD.string (BD.list Type.bytesDecoder)))


bytesAliasEncoder : Alias -> Bytes.Encode.Encoder
bytesAliasEncoder (Alias comment args type_) =
    Bytes.Encode.sequence
        [ BE.string comment
        , BE.list BE.string args
        , Type.bytesEncoder type_
        ]


bytesAliasDecoder : Bytes.Decode.Decoder Alias
bytesAliasDecoder =
    Bytes.Decode.map3 Alias
        BD.string
        (BD.list BD.string)
        Type.bytesDecoder


bytesValueEncoder : Value -> Bytes.Encode.Encoder
bytesValueEncoder (Value comment type_) =
    Bytes.Encode.sequence
        [ BE.string comment
        , Type.bytesEncoder type_
        ]


bytesValueDecoder : Bytes.Decode.Decoder Value
bytesValueDecoder =
    Bytes.Decode.map2 Value
        BD.string
        Type.bytesDecoder


bytesBinopEncoder : Binop -> Bytes.Encode.Encoder
bytesBinopEncoder (Binop data) =
    Bytes.Encode.sequence
        [ BE.string data.comment
        , Type.bytesEncoder data.tipe
        , Binop.associativityEncoder data.associativity
        , Binop.precedenceEncoder data.precedence
        ]


bytesBinopDecoder : Bytes.Decode.Decoder Binop
bytesBinopDecoder =
    Bytes.Decode.map4
        (\comment tipe associativity precedence ->
            Binop { comment = comment, tipe = tipe, associativity = associativity, precedence = precedence }
        )
        BD.string
        Type.bytesDecoder
        Binop.associativityDecoder
        Binop.precedenceDecoder
