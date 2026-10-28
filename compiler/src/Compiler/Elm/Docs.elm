module Compiler.Elm.Docs exposing
    ( Documentation, Module(..), ModuleData, Comment
    , Alias(..), Union(..), Value(..), Binop(..), DocsBinopData
    , Error
    , fromModule
    , encode, decoder
    , bytesModuleEncoder, bytesModuleDecoder
    )

{-| A published package carries a description of its exposed API, and this
module builds that description from a module's source and reads and writes it.

The description of one module is its _overview_, which is the module's own doc
comment, together with every exposed name, its doc comment and, where it has
one, its type. The description of a package is one such record per module,
written as the JSON file `docs.json`. `fromModule` builds a module's record from
the canonical form of the module, `encode` and `decoder` are the `docs.json`
format, and `bytesModuleEncoder` and `bytesModuleDecoder` hold one module's
record in binary.

`fromModule` refuses a module whose exposed API is not fully documented. It
compares the names the overview lists on its `@docs` lines with the names in the
module's `exposing` list, reporting every name missing from one side, and each
exposed name needs a doc comment. A value also needs a type annotation, because its documented type is
the annotated one; a type alias or custom type needs only the comment. The
errors it returns are `Compiler.Reporting.Error.Docs.Error`, which that module
describes; this module's own `Error` is only for reading `docs.json`.

Most of the module is that check: a small parser that finds the `@docs` lines
in the overview, a comparison of their names with the `exposing` list, and a
lookup of each exposed name's comment and type.


# Types

@docs Documentation, Module, ModuleData, Comment
@docs Alias, Union, Value, Binop, DocsBinopData
@docs Error


# Extraction

@docs fromModule


# JSON Encoding

@docs encode, decoder


# Binary Encoding

@docs bytesModuleEncoder, bytesModuleDecoder

-}

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
import Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)



-- ====== DOCUMENTATION ======


{-| The description of a set of modules, keyed by module name.
-}
type alias Documentation =
    Dict Name Module


{-| The description of one module.

`name` is the module's name without its package. `comment` is the overview,
the module's own doc comment. The four dictionaries hold the exposed names of
each kind, keyed by name; an operator is keyed by the operator itself.

-}
type alias ModuleData =
    { name : Name
    , comment : Comment
    , unions : Dict Name Union
    , aliases : Dict Name Alias
    , values : Dict Name Value
    , binops : Dict Name Binop
    }


{-| The description of one module, as `ModuleData` sets out.
-}
type Module
    = Module ModuleData


{-| The text of a doc comment. Comments `fromModule` builds from source have
carriage returns removed; decoded ones are not checked. It is Markdown by
convention, which nothing here checks.
-}
type alias Comment =
    String


{-| The description of an exposed type alias: its doc comment, its type
variables and the type it stands for.
-}
type Alias
    = Alias Comment (List Name) Type.Type


{-| The description of an exposed custom type: its doc comment, its type
variables and its constructors, each with the types of its arguments.

A type exposed without its constructors, as `Type` rather than `Type(..)`, is
described with an empty list of constructors.

-}
type Union
    = Union Comment (List Name) (List ( Name, List Type.Type ))


{-| The description of an exposed value: its doc comment and its annotated type.
-}
type Value
    = Value Comment Type.Type


{-| The description of an exposed operator: its doc comment and type, which
are those of the function the operator stands for, and its associativity and
precedence.
-}
type alias DocsBinopData =
    { comment : Comment
    , tipe : Type.Type
    , associativity : Binop.Associativity
    , precedence : Binop.Precedence
    }


{-| The description of an exposed operator, as `DocsBinopData` sets out.
-}
type Binop
    = Binop DocsBinopData



-- ====== JSON ======


{-| Encodes `docs` in the `docs.json` format: a JSON array with one object per
module, in order of module name.
-}
encode : Documentation -> E.Value
encode docs =
    E.list encodeModule (Dict.values docs)


{-| Encodes one module's description as a JSON object, with each kind of
exposed name as an array in order of name.
-}
encodeModule : Module -> E.Value
encodeModule (Module moduleData) =
    E.object
        [ ( "name", ModuleName.encode moduleData.name )
        , ( "comment", E.string moduleData.comment )
        , ( "unions", E.list encodeUnion (Dict.toList moduleData.unions) )
        , ( "aliases", E.list encodeAlias (Dict.toList moduleData.aliases) )
        , ( "values", E.list encodeValue (Dict.toList moduleData.values) )
        , ( "binops", E.list encodeBinop (Dict.toList moduleData.binops) )
        ]


{-| The ways the contents of a `docs.json` document can be rejected beyond its
JSON shape: an associativity other than `"left"`, `"non"` or `"right"`, a
module name that does not parse, or a type that does not parse.
-}
type Error
    = BadAssociativity
    | BadModuleName
    | BadType


{-| A decoder for the `docs.json` format that `encode` writes. When two modules
share a name, the later one is kept.
-}
decoder : D.Decoder Error Documentation
decoder =
    D.map toDict (D.list moduleDecoder)


{-| Returns `modules` keyed by their names, the later of two with the same name
winning.
-}
toDict : List Module -> Documentation
toDict modules =
    Dict.fromList (List.map toDictHelp modules)


{-| Returns a module paired with its name.
-}
toDictHelp : Module -> ( Name.Name, Module )
toDictHelp ((Module moduleData) as modul) =
    ( moduleData.name, modul )


{-| A decoder for one module's JSON object, as `encodeModule` writes it.
-}
moduleDecoder : D.Decoder Error Module
moduleDecoder =
    D.map (\name_ comment_ unions_ aliases_ values_ binops_ -> Module { name = name_, comment = comment_, unions = unions_, aliases = aliases_, values = values_, binops = binops_ }) (D.field "name" moduleNameDecoder)
        |> D.apply (D.field "comment" D.string)
        |> D.apply (D.field "unions" (dictDecoder union))
        |> D.apply (D.field "aliases" (dictDecoder alias_))
        |> D.apply (D.field "values" (dictDecoder value))
        |> D.apply (D.field "binops" (dictDecoder binop))


{-| Produces a decoder for a JSON array of objects that each carry a `"name"`
field and the fields `entryDecoder` reads, keyed by that name.
-}
dictDecoder : D.Decoder Error a -> D.Decoder Error (Dict Name a)
dictDecoder entryDecoder =
    D.map Dict.fromList (D.list (named entryDecoder))


{-| Produces a decoder for an object's `"name"` field paired with what
`entryDecoder` reads from the same object.
-}
named : D.Decoder Error a -> D.Decoder Error ( Name.Name, a )
named entryDecoder =
    D.map Tuple.pair (D.field "name" nameDecoder)
        |> D.apply entryDecoder


{-| A decoder for a name, read as any JSON string.
-}
nameDecoder : D.Decoder e Name
nameDecoder =
    D.string


{-| A decoder for a module name, failing with `BadModuleName`.
-}
moduleNameDecoder : D.Decoder Error ModuleName.Raw
moduleNameDecoder =
    D.mapError (always BadModuleName) ModuleName.decoder


{-| A decoder for a type, failing with `BadType`.
-}
typeDecoder : D.Decoder Error Type.Type
typeDecoder =
    D.mapError (always BadType) Type.decoder



-- ====== UNION JSON ======


{-| Encodes a custom type's description as a JSON object.
-}
encodeUnion : ( Name, Union ) -> E.Value
encodeUnion ( name, Union comment args cases ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string comment )
        , ( "args", E.list E.name args )
        , ( "cases", E.list encodeCase cases )
        ]


{-| A decoder for a custom type's JSON object, as `encodeUnion` writes it
without its name.
-}
union : D.Decoder Error Union
union =
    D.map Union (D.field "comment" D.string)
        |> D.apply (D.field "args" (D.list nameDecoder))
        |> D.apply (D.field "cases" (D.list caseDecoder))


{-| Encodes a constructor as a two-element JSON array: its name and the array of
its argument types.
-}
encodeCase : ( Name, List Type.Type ) -> E.Value
encodeCase ( tag, args ) =
    E.list identity [ E.name tag, E.list Type.encode args ]


{-| A decoder for a constructor, as `encodeCase` writes it.
-}
caseDecoder : D.Decoder Error ( Name.Name, List Type.Type )
caseDecoder =
    D.pair nameDecoder (D.list typeDecoder)



-- ====== ALIAS JSON ======


{-| Encodes a type alias's description as a JSON object.
-}
encodeAlias : ( Name, Alias ) -> E.Value
encodeAlias ( name, Alias comment args tipe ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string comment )
        , ( "args", E.list E.name args )
        , ( "type", Type.encode tipe )
        ]


{-| A decoder for a type alias's JSON object, as `encodeAlias` writes it
without its name.
-}
alias_ : D.Decoder Error Alias
alias_ =
    D.map Alias (D.field "comment" D.string)
        |> D.apply (D.field "args" (D.list nameDecoder))
        |> D.apply (D.field "type" typeDecoder)



-- ====== VALUE JSON ======


{-| Encodes a value's description as a JSON object.
-}
encodeValue : ( Name.Name, Value ) -> E.Value
encodeValue ( name, Value comment tipe ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string comment )
        , ( "type", Type.encode tipe )
        ]


{-| A decoder for a value's JSON object, as `encodeValue` writes it without its
name.
-}
value : D.Decoder Error Value
value =
    D.map Value (D.field "comment" D.string)
        |> D.apply (D.field "type" typeDecoder)



-- ====== BINOP JSON ======


{-| Encodes an operator's description as a JSON object.
-}
encodeBinop : ( Name, Binop ) -> E.Value
encodeBinop ( name, Binop data ) =
    E.object
        [ ( "name", E.name name )
        , ( "comment", E.string data.comment )
        , ( "type", Type.encode data.tipe )
        , ( "associativity", encodeAssoc data.associativity )
        , ( "precedence", encodePrec data.precedence )
        ]


{-| A decoder for an operator's JSON object, as `encodeBinop` writes it without
its name.
-}
binop : D.Decoder Error Binop
binop =
    D.map (\comment tipe assoc prec -> Binop { comment = comment, tipe = tipe, associativity = assoc, precedence = prec }) (D.field "comment" D.string)
        |> D.apply (D.field "type" typeDecoder)
        |> D.apply (D.field "associativity" assocDecoder)
        |> D.apply (D.field "precedence" precDecoder)



-- ====== ASSOCIATIVITY JSON ======


{-| Encodes an associativity as the string `"left"`, `"non"` or `"right"`.
-}
encodeAssoc : Binop.Associativity -> E.Value
encodeAssoc assoc =
    case assoc of
        Binop.Left ->
            E.string "left"

        Binop.Non ->
            E.string "non"

        Binop.Right ->
            E.string "right"


{-| A decoder for an associativity as `encodeAssoc` writes it, failing with
`BadAssociativity` on any other string.
-}
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



-- ====== PRECEDENCE JSON ======


{-| Encodes a precedence as a JSON number.
-}
encodePrec : Binop.Precedence -> E.Value
encodePrec n =
    E.int n


{-| A decoder for a precedence, read as any JSON integer.
-}
precDecoder : D.Decoder Error Binop.Precedence
precDecoder =
    D.int



-- ====== FROM MODULE ======


{-| Returns the description of `modul`, or why its exposed API is not fully
documented.

It fails with `ImplicitExposing` for a module that uses `exposing (..)`, with
`NoDocs` for one without a doc comment of its own, and with `SyntaxProblem` when
a `@docs` line does not parse. Then it fails with `NameProblems` when any of
the `@docs` names and the exposed names is missing from one side or listed
twice, with one problem per such name in key order (by character code, so
upper-case names come before lower-case ones).
Last, it fails with `DefProblems` for exposed names with no doc comment, and for
exposed values with no type annotation; an exposed operator needs both
on the function it stands for. A missing annotation on a value is reported
instead of, not as well as, its missing comment. Exposing a port crashes, as
its name is not among the module's definitions.

The type of a value is its annotation, not its inferred type.

-}
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
                        |> Result.andThen (\_ -> checkDefs exportDict overview (Dict.fromList comments) modul)



-- ====== PARSE OVERVIEW ======


{-| Returns the names listed on the `@docs` lines of the overview, in reverse
order, each with its region, or the syntax error in a `@docs` line.

A `@docs` line starts wherever the five characters `@docs` appear and are not
followed by a letter, digit or `_`, not only at the start of a line. After it
comes a name, an operator in parentheses, or several of these separated by
commas. Text that follows the last name is skipped up to the next `@docs`, so a
name after a comma at the start of a line, in the first column, is not part of
the list.

-}
parseOverview : Src.Comment -> Result E.Error (List (A.Located Name.Name))
parseOverview (Src.Comment snippet) =
    case P.fromSnippet (chompOverview []) E.BadEnd snippet of
        Err err ->
            Err (E.SyntaxProblem err)

        Ok names ->
            Ok names


{-| A parser whose errors are syntax errors in the overview.
-}
type alias Parser a =
    P.Parser E.SyntaxProblem a


{-| Produces a parser that reads the rest of the overview and returns every name
on its `@docs` lines, most recent first, ahead of `names`.
-}
chompOverview : List (A.Located Name.Name) -> Parser (List (A.Located Name.Name))
chompOverview =
    P.loop chompOverviewHelp


{-| Produces a parser that skips to the next `@docs` and reads its names onto
`names`, or stops at the end of the overview.
-}
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


{-| Produces a parser that reads the comma-separated names of one `@docs` line,
most recent first, ahead of `names`.
-}
chompDocs : List (A.Located Name.Name) -> Parser (List (A.Located Name.Name))
chompDocs =
    P.loop chompDocsHelp


{-| Produces a parser that reads one name and, if a comma follows it outside the
first column, the comma, asking to continue; otherwise it stops after the name.
-}
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


{-| A parser for an operator written in parentheses, as `(|=)`, giving the
operator without them.
-}
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


{-| A parser that skips to just after the next `@docs` that is not followed by a
letter, digit or `_`, giving `True`, or to the end of the overview, giving
`False`.
-}
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


{-| Returns whether `src` holds a `@docs`, matched as `chompUntilDocs`
describes, between `pos` and `end`, with the position, row and column just
after it, or those of `end` when there is none.
-}
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
                        pos + P.charWidthAt src pos end word
                in
                untilDocs src newPos end row (col + 1)



-- ====== CHECK NAMES ======


{-| Checks every name across `names`, the names on the `@docs` lines, and
`exports`. Fails with `NameProblems` when any name is missing from one side or
listed twice in `names`, holding one problem per such name, in key order.
-}
checkNames : Dict Name (A.Located Can.Export) -> List (A.Located Name) -> Result E.Error ()
checkNames exports names =
    let
        docs : DocNameRegions
        docs =
            List.foldl addName Dict.empty names

        loneExport : Name -> A.Located Can.Export -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        loneExport name export_ acc =
            keepBoth acc (onlyInExports name export_)

        checkBoth : Name -> A.Located Can.Export -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        checkBoth n _ r acc =
            keepBoth acc (isUnique n r)

        loneDoc : Name -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        loneDoc name regions acc =
            keepBoth acc (onlyInDocs name regions)

        keepBoth : ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region -> ReportingResult.RResult i w E.NameProblem A.Region
        keepBoth acc next =
            ReportingResult.ok (\_ r -> r)
                |> ReportingResult.apply acc
                |> ReportingResult.apply next
    in
    case ReportingResult.run (Dict.merge loneExport checkBoth loneDoc exports docs (ReportingResult.ok A.zero)) of
        ( _, Ok _ ) ->
            Ok ()

        ( _, Err es ) ->
            Err (E.NameProblems (OneOrMore.destruct NE.Nonempty es))


{-| The names on the `@docs` lines, each with the regions of its listings.
-}
type alias DocNameRegions =
    Dict Name (OneOrMore.OneOrMore A.Region)


{-| Returns `dict` with one more listing of a name.
-}
addName : A.Located Name -> DocNameRegions -> DocNameRegions
addName (A.At region name) dict =
    Dict.update name
        (\existing ->
            case existing of
                Nothing ->
                    Just (OneOrMore.one region)

                Just old ->
                    Just (OneOrMore.more old (OneOrMore.one region))
        )
        dict


{-| Returns the region of a name listed once, or a `NameDuplicate` for a name
listed more than once.
-}
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


{-| Returns the problem for a name listed on `@docs` lines but not exposed:
`NameDuplicate` if it is listed more than once, otherwise `NameOnlyInDocs`.
-}
onlyInDocs : Name -> OneOrMore.OneOrMore A.Region -> ReportingResult.RResult i w E.NameProblem a
onlyInDocs name regions =
    isUnique name regions
        |> ReportingResult.andThen
            (\region ->
                ReportingResult.throw (E.NameOnlyInDocs name region)
            )


{-| Returns the `NameOnlyInExports` problem for an exposed name that no `@docs`
line lists.
-}
onlyInExports : Name -> A.Located Can.Export -> ReportingResult.RResult i w E.NameProblem a
onlyInExports name (A.At region _) =
    ReportingResult.throw (E.NameOnlyInExports name region)



-- ====== CHECK DEFS ======


{-| Returns the description of the module, with `overview` as its own comment and
an entry for each name in `exportDict`, or a `DefProblems` holding the problems
of every exposed name that lacks a doc comment or a needed annotation.
-}
checkDefs : Dict Name (A.Located Can.Export) -> Src.Comment -> Dict Name Src.Comment -> Can.Module -> Result E.Error Module
checkDefs exportDict overview comments (Can.Module canData) =
    let
        types : Types
        types =
            gatherTypes canData.decls Dict.empty

        info : Info
        info =
            Info { comments = comments, types = types, unions = canData.unions, aliases = canData.aliases, binops = canData.binops, effects = canData.effects }
    in
    case ReportingResult.run (ReportingResult.traverse (\( k, v ) -> ReportingResult.map (Tuple.pair k) (checkExport info k v)) (Dict.toList exportDict)) of
        ( _, Err problems ) ->
            Err (E.DefProblems (OneOrMore.destruct NE.Nonempty problems))

        ( _, Ok inserters ) ->
            Ok (List.foldr (\( _, fn ) acc -> fn acc) (emptyModule canData.name overview) inserters)


{-| Returns the description of a module with the given name and overview and no
exposed names.
-}
emptyModule : ModuleName.Canonical -> Src.Comment -> Module
emptyModule (ModuleName.Canonical _ name) (Src.Comment overview) =
    Module { name = name, comment = Json.fromComment overview, unions = Dict.empty, aliases = Dict.empty, values = Dict.empty, binops = Dict.empty }


{-| What the module declares that an exposed name is looked up in: the doc
comments of its top-level declarations, the types of its definitions, and its
type aliases, custom types and operators. `types` holds, for each top-level definition, its annotated type, or
the region of its name when it has no annotation.
-}
type alias InfoData =
    { comments : Dict Name.Name Src.Comment
    , types : Dict Name.Name (Result A.Region (Can.Type Name))
    , unions : Dict Name.Name Can.Union
    , aliases : Dict Name.Name Can.Alias
    , binops : Dict Name.Name Can.Binop
    , effects : Can.Effects
    }


{-| The lookup tables an exposed name is checked against, as `InfoData` sets out.
-}
type Info
    = Info InfoData


{-| Returns the function that adds the exposed `name` to a module's description,
or what it lacks.

A value needs an annotation and a comment, an operator needs both on the
function it stands for, and a type alias or custom type needs only a comment.
A port is looked up among the definitions, which do not include ports, so
exposing one crashes.

-}
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
                                            Module { mData | values = Dict.insert name (Value comment tipe) mData.values }
                                        )
                                )
                    )

        Can.ExportBinop ->
            let
                (Can.Binop_ assoc prec realName) =
                    dictFind name iBinops
            in
            getType realName info
                |> ReportingResult.andThen
                    (\tipe ->
                        getComment region realName info
                            |> ReportingResult.andThen
                                (\comment ->
                                    ReportingResult.ok
                                        (\(Module mData) ->
                                            Module { mData | binops = Dict.insert name (Binop { comment = comment, tipe = tipe, associativity = assoc, precedence = prec }) mData.binops }
                                        )
                                )
                    )

        Can.ExportAlias ->
            let
                (Can.Alias tvars tipe) =
                    dictFind name iAliases
            in
            getComment region name info
                |> ReportingResult.andThen
                    (\comment ->
                        ReportingResult.ok
                            (\(Module mData) ->
                                Module { mData | aliases = Dict.insert name (Alias comment tvars (Extract.fromType tipe)) mData.aliases }
                            )
                    )

        Can.ExportUnionOpen ->
            let
                (Can.Union unionData) =
                    dictFind name iUnions
            in
            getComment region name info
                |> ReportingResult.andThen
                    (\comment ->
                        ReportingResult.ok
                            (\(Module mData) ->
                                Module { mData | unions = Dict.insert name (Union comment unionData.vars (List.map dector unionData.alts)) mData.unions }
                            )
                    )

        Can.ExportUnionClosed ->
            let
                (Can.Union unionData) =
                    dictFind name iUnions
            in
            getComment region name info
                |> ReportingResult.andThen
                    (\comment ->
                        ReportingResult.ok
                            (\(Module mData) ->
                                Module { mData | unions = Dict.insert name (Union comment unionData.vars []) mData.unions }
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
                                            Module { mData | values = Dict.insert name (Value comment tipe) mData.values }
                                        )
                                )
                    )


{-| Returns the doc comment of `name`, or a `NoComment` at `region`.
-}
getComment : A.Region -> Name.Name -> Info -> ReportingResult.RResult i w E.DefProblem Comment
getComment region name (Info infoData) =
    case Dict.get name infoData.comments of
        Nothing ->
            ReportingResult.throw (E.NoComment name region)

        Just (Src.Comment snippet) ->
            ReportingResult.ok (Json.fromComment snippet)


{-| Returns the annotated type of the definition `name`, or a `NoAnnotation` at
the region of its name. It crashes when `name` is not a top-level definition.
-}
getType : Name.Name -> Info -> ReportingResult.RResult i w E.DefProblem Type.Type
getType name (Info infoData) =
    case dictFind name infoData.types of
        Err region ->
            ReportingResult.throw (E.NoAnnotation name region)

        Ok tipe ->
            ReportingResult.ok (Extract.fromType tipe)


{-| Returns the entry for `key`, crashing when there is none.
-}
dictFind : comparable -> Dict comparable v -> v
dictFind key dict =
    case Dict.get key dict of
        Just v ->
            v

        Nothing ->
            crash "Compiler.Elm.Docs: key not found in dict"


{-| Returns a constructor's name and the types of its arguments.
-}
dector : Can.Ctor -> ( Name, List Type.Type )
dector (Can.Ctor c) =
    ( c.name, List.map Extract.fromType c.args )



-- ====== GATHER TYPES ======


{-| For each top-level definition, its annotated type, or the region of its name
when it has no annotation.
-}
type alias Types =
    Dict Name.Name (Result A.Region (Can.Type Name))


{-| Returns `types` with an entry for every definition in `decls`.
-}
gatherTypes : Can.Decls -> Types -> Types
gatherTypes decls types =
    case decls of
        Can.Declare def subDecls ->
            gatherTypes subDecls (addDef types def)

        Can.DeclareRec def defs subDecls ->
            gatherTypes subDecls (List.foldl (flip addDef) (addDef types def) defs)

        Can.SaveTheEnvironment ->
            types


{-| Returns `types` with an entry for `def`: the function type built from its
annotated arguments and result, or the region of its name when it has no
annotation.
-}
addDef : Types -> Can.Def -> Types
addDef types def =
    case def of
        Can.Def (A.At region name) _ _ ->
            Dict.insert name (Err region) types

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                tipe : Can.Type Name
                tipe =
                    List.foldr Can.tLambda resultType (List.map Tuple.second typedArgs)
            in
            Dict.insert name (Ok tipe) types



-- ====== ENCODERS and DECODERS ======


{-| Encodes one module's description in binary, as `bytesModuleDecoder` reads
it.
-}
bytesModuleEncoder : Module -> Bytes.Encode.Encoder
bytesModuleEncoder (Module moduleData) =
    Bytes.Encode.sequence
        [ BE.string moduleData.name
        , BE.string moduleData.comment
        , BE.stdDict BE.string bytesUnionEncoder moduleData.unions
        , BE.stdDict BE.string bytesAliasEncoder moduleData.aliases
        , BE.stdDict BE.string bytesValueEncoder moduleData.values
        , BE.stdDict BE.string bytesBinopEncoder moduleData.binops
        ]


{-| A decoder for one module's description in binary, as `bytesModuleEncoder`
writes it.
-}
bytesModuleDecoder : Bytes.Decode.Decoder Module
bytesModuleDecoder =
    BD.map6 (\name_ comment_ unions_ aliases_ values_ binops_ -> Module { name = name_, comment = comment_, unions = unions_, aliases = aliases_, values = values_, binops = binops_ })
        BD.string
        BD.string
        (BD.stdDict BD.string bytesUnionDecoder)
        (BD.stdDict BD.string bytesAliasDecoder)
        (BD.stdDict BD.string bytesValueDecoder)
        (BD.stdDict BD.string bytesBinopDecoder)


{-| Encodes a custom type's description in binary.
-}
bytesUnionEncoder : Union -> Bytes.Encode.Encoder
bytesUnionEncoder (Union comment args cases) =
    Bytes.Encode.sequence
        [ BE.string comment
        , BE.list BE.string args
        , BE.list (BE.jsonPair BE.string (BE.list Type.bytesEncoder)) cases
        ]


{-| A decoder for a custom type's description, as `bytesUnionEncoder` writes it.
-}
bytesUnionDecoder : Bytes.Decode.Decoder Union
bytesUnionDecoder =
    Bytes.Decode.map3 Union
        BD.string
        (BD.list BD.string)
        (BD.list (BD.jsonPair BD.string (BD.list Type.bytesDecoder)))


{-| Encodes a type alias's description in binary.
-}
bytesAliasEncoder : Alias -> Bytes.Encode.Encoder
bytesAliasEncoder (Alias comment args type_) =
    Bytes.Encode.sequence
        [ BE.string comment
        , BE.list BE.string args
        , Type.bytesEncoder type_
        ]


{-| A decoder for a type alias's description, as `bytesAliasEncoder` writes it.
-}
bytesAliasDecoder : Bytes.Decode.Decoder Alias
bytesAliasDecoder =
    Bytes.Decode.map3 Alias
        BD.string
        (BD.list BD.string)
        Type.bytesDecoder


{-| Encodes a value's description in binary.
-}
bytesValueEncoder : Value -> Bytes.Encode.Encoder
bytesValueEncoder (Value comment type_) =
    Bytes.Encode.sequence
        [ BE.string comment
        , Type.bytesEncoder type_
        ]


{-| A decoder for a value's description, as `bytesValueEncoder` writes it.
-}
bytesValueDecoder : Bytes.Decode.Decoder Value
bytesValueDecoder =
    Bytes.Decode.map2 Value
        BD.string
        Type.bytesDecoder


{-| Encodes an operator's description in binary.
-}
bytesBinopEncoder : Binop -> Bytes.Encode.Encoder
bytesBinopEncoder (Binop data) =
    Bytes.Encode.sequence
        [ BE.string data.comment
        , Type.bytesEncoder data.tipe
        , Binop.associativityEncoder data.associativity
        , Binop.precedenceEncoder data.precedence
        ]


{-| A decoder for an operator's description, as `bytesBinopEncoder` writes it.
-}
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
