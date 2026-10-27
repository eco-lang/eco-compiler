module Common.Format.Render.Box exposing (formatModule)

{-| The built-in formatter prints a parsed module back out the way elm-format
would, and this module decides that layout. `formatModule` turns a module into
a `Box` (see `Common.Format.Box`), which the caller renders to text.

The input is `Compiler.Parse.Module.Module`, the parser's record before any
checking, because it still holds the comments around the header, between the
imports and between the top-level declarations. Inside each declaration, every
syntax node carries the comments the parser found next to it, in the comment
groups `Compiler.AST.Source` defines, and the formatters here print them back
in place.

Formatting happens in two steps. `formatModu` first converts the parsed module
into this module's own model: a header with its source tag (an ordinary,
`port` or `effect` module), its `where` settings and its exposing list; the
imports keyed by module path; and a body that is a flat list of _top-level
structures_, each a doc comment, a comment between declarations, or a
declaration. Then every piece is laid out with the combinators of
`Common.Format.Render.ElmStructure`.

Two ideas run through the layout code. The first is that whether a construct
takes one line or several never depends on width. It stays on one line when all
its parts are single-line boxes and nothing forces it apart, and what usually
forces it apart is that its source region spanned several lines
(`A.isMultiline`). So the output follows the line breaks of the input. The
second is the _syntax context_: every expression and pattern formatter returns,
alongside its box, a `SyntaxContext` saying how loosely the result binds, and
the caller wraps it in parentheses when that is too loose for the place it is
put. Types do the same with `TypeParensInner` and `TypeParensRequired`.

The module's doc comment decides the order of its exposing list: the exposed
names on each `@docs` line form a group, in that order, and the exposed names no
`@docs` line mentions usually follow in one more group. Doc comments are reprinted through
`Common.Format.Render.Markdown`, and the Elm code blocks in them are
reformatted by parsing each as a declaration, then as an expression, then as a
module.

A shape the formatter does not expect is printed as a visible
`<elm-format: ... please report this ...>` marker in the output rather than
stopping the run. A union type with no constructors stops it with `crash`.


# Module Formatting

@docs formatModule

-}

import Basics.Extra exposing (flip)
import Common.Format.Box as Box exposing (Box)
import Common.Format.Cheapskate.Parse as Parse
import Common.Format.Cheapskate.Types exposing (Block(..), Blocks, Doc(..), LinkTarget(..))
import Common.Format.ImportInfo as ImportInfo exposing (ImportInfo)
import Common.Format.Render.ElmStructure as ElmStructure
import Common.Format.Render.Markdown as Markdown
import Compiler.AST.Snippet as Snippet
import Compiler.AST.Source as Src
import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Name exposing (Name)
import Compiler.Parse.Declaration as Decl
import Compiler.Parse.Expression as Expr
import Compiler.Parse.Module as M
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Annotation as A
import Data.Map as Map exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Hex
import Maybe.Extra as Maybe
import Utils.Crash exposing (crash)


{-| The formatter's model of a whole module.

`imports` maps each imported module's path to the import's comments and
`ImportMethod`, after the comments that come before all the imports. `docs` is the
module doc comment parsed as Markdown, `Nothing` when there is none. `body`
holds the infix declarations and the declarations in order, with the comments
between them.

-}
type alias Module =
    { importInfo : ImportInfo
    , initialComments : Src.FComments
    , header : Maybe Header
    , docs : A.Located (Maybe Blocks)
    , imports : Src.C1 (Dict (List String) (List Name) (Src.C1 ImportMethod))
    , body : List (TopLevelStructure Declaration)
    }


{-| The `module` line of a module, as `HeaderProps` describes it.
-}
type Header
    = Header HeaderProps


{-| The parts of a `module` line.

`name` is the module path split at its dots. `moduleSettings` is the
`where { command = ..., subscription = ... }` clause of an effect module.
`exports` is `Nothing` only for a header the formatter made up, which has no
exposing list.

-}
type alias HeaderProps =
    { srcTag : SourceTag
    , name : Src.C2 (List Name)
    , moduleSettings : Maybe (Src.C2 SourceSettings)
    , exports : Maybe (Src.C2 (Listing DetailedListing))
    }


{-| Builds a `Header` from its parts.
-}
makeHeader : SourceTag -> Src.C2 (List Name) -> Maybe (Src.C2 SourceSettings) -> Maybe (Src.C2 (Listing DetailedListing)) -> Header
makeHeader srcTag name moduleSettings exports =
    Header { srcTag = srcTag, name = name, moduleSettings = moduleSettings, exports = exports }


{-| The header of an ordinary module named `Main` with no exposing list, used when the source has no `module` line.
-}
defaultHeader : Header
defaultHeader =
    makeHeader Normal ( ( [], [] ), [ "Main" ] ) Nothing Nothing


{-| The settings of an effect module's `where` clause, each a setting name and the type name it is set to.
-}
type alias SourceSettings =
    List ( Src.C2 Name, Src.C2 Name )


{-| The kind of module a `module` line declares.

`Normal` is an ordinary `module` line. `Effect` and `Port` carry the comments between their keyword and `module`.

-}
type SourceTag
    = Normal
    | Effect Src.FComments
    | Port Src.FComments


{-| One import line: the module path with the comments before it, and what it brings in.
-}
type alias UserImport =
    ( Src.C1 (List Name), ImportMethod )


{-| What an import brings in: its `as` alias, if one is written, and its exposing listing, each with the comments around its keyword.
-}
type ImportMethod
    = ImportMethod (Maybe (Src.C2 Name)) (Src.C2 (Listing DetailedListing))


{-| What an exposing list, or a type's constructor list inside one, says is
exposed.

`ExplicitListing` names the entries, and its `Bool` is `True` when the list
spanned several lines in the source. `OpenListing` is `(..)`, with the comments
around the `..`. `ClosedListing` exposes nothing: an import with no exposing
list, an empty one, or a type exposed without its constructors.

-}
type Listing a
    = ExplicitListing a Bool
    | OpenListing (Src.C2 ())
    | ClosedListing


{-| The entries of an explicit exposing list, sorted into values, operators and types, each map keyed by name.
-}
type alias DetailedListing =
    { values : CommentedMap Name ()
    , operators : CommentedMap Name ()
    , types : CommentedMap Name (Src.C1 (Listing (CommentedMap Name ())))
    }


{-| A map from names to entries of an exposing list, each with the comments around it, so the entries print in name order.
-}
type alias CommentedMap k v =
    Dict String k (Src.C2 v)


{-| One entry of an exposing list: a lower-case value, an operator, or a type
with the comments after its name and its constructor listing.
-}
type Value
    = Value Name
    | OpValue Name
    | Union (Src.C1 Name) (Listing (CommentedMap Name ()))


{-| One top-level declaration.

`CommonDeclaration` is a definition or a type annotation, the two kinds that
also appear in a `let`. `Datatype` is a custom type: its name and type
variables, and its constructors. `TypeAlias` carries the comments between
`type` and `alias`. `PortAnnotation` carries the comments before the port's
type. `Fixity` is an `infix` declaration: its associativity, its precedence,
the operator and the function it stands for.

-}
type Declaration
    = CommonDeclaration CommonDeclaration
    | Datatype (Src.C2 (NameWithArgs Name Name)) (Src.OpenCommentedList (NameWithArgs Name Src.Type))
    | TypeAlias Src.FComments (Src.C2 (NameWithArgs Name Name)) (Src.C1 Src.Type)
    | PortAnnotation (Src.C2 Name) Src.FComments Src.Type
    | Fixity (Src.C1 Binop.Associativity) (Src.C1 Binop.Precedence) (Src.C2 Name) (Src.C1 Name)


{-| A declaration that can appear both at the top level and in a `let`.

`Definition` is the defined pattern, its argument patterns, the comments
before the body, and the body. `TypeAnnotation` names the value it annotates.

-}
type CommonDeclaration
    = Definition Src.Pattern (List (Src.C1 Src.Pattern)) Src.FComments Src.Expr
    | TypeAnnotation (Src.C1 (Ref ())) (Src.C1 Src.Type)


{-| A name followed by its arguments, each with the comments before it: a type with its type variables, or a constructor with its argument types.
-}
type NameWithArgs name arg
    = NameWithArgs name (List (Src.C1 arg))


{-| One item of a module body or of a doc-comment code block, in source order.

`DocComment` is a doc comment, already parsed as Markdown. `BodyComment` is an
ordinary comment between declarations. `Entry` is the declaration itself.

-}
type TopLevelStructure a
    = DocComment Blocks
    | BodyComment Src.FComment
    | Entry a


{-| Applies `f` to the declaration of an `Entry`, leaving comments unchanged.
-}
topLevelStructureMap : (a -> b) -> TopLevelStructure a -> TopLevelStructure b
topLevelStructureMap f topLevelStructure =
    case topLevelStructure of
        DocComment blocks ->
            DocComment blocks

        BodyComment comment ->
            BodyComment comment

        Entry a ->
            Entry (f a)


{-| A reference to a name, with its module qualifier of type `ns`.

`VarRef` is a lower-case name and `TagRef` a capitalised one. `OpRef` is an
operator, which is never qualified.

-}
type Ref ns
    = VarRef ns String
    | TagRef ns String
    | OpRef String


{-| Applies `f` to the qualifier of a reference.
-}
refMap : (a -> b) -> Ref a -> Ref b
refMap f ref =
    case ref of
        VarRef namespace name ->
            VarRef (f namespace) name

        TagRef namespace name ->
            TagRef (f namespace) name

        OpRef name ->
            OpRef name


{-| Returns each element of `input` paired with the one after it, in order, so a list of n elements gives n - 1 pairs.
-}
pairs : List a -> List ( a, a )
pairs input =
    let
        step : a -> ( Maybe b, List ( a, b ) ) -> ( Maybe a, List ( a, b ) )
        step next ( prev, acc ) =
            case prev of
                Nothing ->
                    ( Just next, acc )

                Just prev_ ->
                    ( Just next, ( next, prev_ ) :: acc )
    in
    List.foldr step ( Nothing, [] ) input
        |> Tuple.second


{-| Returns `fn` applied to every element of `list`, with what `spacer` gives for each two neighbouring elements put between their results.
-}
intersperseMap : (a -> a -> List b) -> (a -> b) -> List a -> List b
intersperseMap spacer fn list =
    case list of
        [] ->
            []

        first :: _ ->
            fn first
                :: (pairs list
                        |> List.concatMap (\( a, b ) -> spacer a b ++ [ fn b ])
                   )


{-| Returns the text of the marker the formatter prints in place of a shape it does not expect, naming `what` was unexpected and the `details`.
-}
pleaseReport__ : String -> String -> String
pleaseReport__ what details =
    "<elm-format: " ++ what ++ ": " ++ details ++ " -- please report this at https://github.com/guida-lang/compiler/issues>"


{-| Returns the marker of `pleaseReport__` as one line.
-}
pleaseReport_ : String -> String -> Box.Line
pleaseReport_ what details =
    Box.keyword (pleaseReport__ what details)


{-| Returns the marker of `pleaseReport__` as a box.
-}
pleaseReport : String -> String -> Box
pleaseReport what details =
    Box.line (pleaseReport_ what details)


{-| Returns `b` between the characters `left` and `right`: on one line when `b` is a single line, and otherwise with `left` before its first line and `right` on a line of its own.
-}
surround : Char -> Char -> Box -> Box
surround left right b =
    let
        left_ : Box.Line
        left_ =
            Box.punc (String.fromChar left)

        right_ : Box.Line
        right_ =
            Box.punc (String.fromChar right)
    in
    case b of
        Box.SingleLine b_ ->
            Box.line (Box.row [ left_, b_, right_ ])

        _ ->
            Box.stack1
                [ Box.prefix left_ b
                , Box.line right_
                ]


{-| Returns a box wrapped in parentheses.
-}
parens : Box -> Box
parens =
    surround '(' ')'


{-| Returns `left` followed by each operator and its right operand in `ops`, each
operator with the comments before it.

An operator whose `Bool` is `True` is `<|`: what precedes it stays on its line
and the rest of the chain is put after it, or indented below. Every other
operator starts the line of its own operand. When `multiline` is `True` the
chain is laid out over several lines.

-}
formatBinary : Bool -> Box -> List ( ( Bool, Src.FComments, Box ), Box ) -> Box
formatBinary multiline left ops =
    case ops of
        [] ->
            left

        ( ( isLeftPipe, comments, op ), next ) :: rest ->
            if isLeftPipe then
                ElmStructure.forceableSpaceSepOrIndented multiline
                    (ElmStructure.spaceSepOrStack left
                        (List.concat
                            [ formatComments comments |> Maybe.toList
                            , [ op ]
                            ]
                        )
                    )
                    [ formatBinary multiline next rest ]

            else
                formatBinary
                    multiline
                    (ElmStructure.forceableSpaceSepOrIndented multiline left [ formatCommentedApostrophe comments (ElmStructure.spaceSepOrPrefix op next) ])
                    rest


{-| The kind of a top-level item, as far as the blank lines around it are
concerned.

`DStarter` and `DCloser` are the two comment-trick markers, the empty block
comment that opens a stretch of code which one edit can comment out, and the
line comment ending in a block-comment closer that ends it.
`DDefinition` carries the name declared, `Nothing` for a definition of a
pattern other than a plain name, so that an annotation and the definition
of the same name can be kept together.
`DComment` is any other comment, `DDocComment` a doc comment, `DFixity` an
`infix` declaration.

-}
type DeclarationType
    = DComment
    | DStarter
    | DCloser
    | DDefinition (Maybe (Ref ()))
    | DFixity
    | DDocComment


{-| Returns the `DeclarationType` of a top-level item.
-}
declarationType : TopLevelStructure BodyEntryType -> DeclarationType
declarationType decl =
    case decl of
        Entry entry ->
            case entry of
                BodyNamed name ->
                    DDefinition (Just name)

                BodyUnnamed ->
                    DDefinition Nothing

                BodyFixity ->
                    DFixity

        DocComment _ ->
            DDocComment

        BodyComment Src.CommentTrickOpener ->
            DStarter

        BodyComment Src.CommentTrickCloser ->
            DCloser

        BodyComment _ ->
            DComment


{-| Returns the groups of `input` with every value whose name has already appeared in an earlier place removed, dropping groups that become empty.
-}
removeDuplicates : List (List (Src.C2 Value)) -> List (List (Src.C2 Value))
removeDuplicates input =
    let
        step :
            List (Src.C2 Value)
            -> ( List (List (Src.C2 Value)), EverySet String (Src.C2 Value) )
            -> ( List (List (Src.C2 Value)), EverySet String (Src.C2 Value) )
        step next ( acc, seen ) =
            case List.foldl stepChildren ( [], seen ) next |> (\( a, b ) -> ( List.reverse a, b )) of
                ( [], seen_ ) ->
                    ( acc, seen_ )

                ( children_, seen_ ) ->
                    ( children_ :: acc, seen_ )

        varName : Src.C2 Value -> Name
        varName var =
            case var of
                ( _, Value name ) ->
                    name

                ( _, OpValue name ) ->
                    name

                ( _, Union ( _, name ) _ ) ->
                    name

        stepChildren :
            Src.C2 Value
            -> ( List (Src.C2 Value), EverySet String (Src.C2 Value) )
            -> ( List (Src.C2 Value), EverySet String (Src.C2 Value) )
        stepChildren next ( acc, seen ) =
            if EverySet.member varName next seen then
                ( acc, seen )

            else
                ( next :: acc, EverySet.insert varName next seen )
    in
    List.foldl step ( [], EverySet.empty ) input
        |> Tuple.first
        |> List.reverse


{-| Returns the exposing list of a module as groups of entries, together with the
comments of the entries that were moved.

`fromExposing` is what the module exposes and `fromDocs` the names on each
`@docs` line of its doc comment. Each `@docs` line that names an exposed value
becomes a group, in its own order and without repeats. The exposed values no
`@docs` line names follow as one group, operators first, then types, then
values, each in name order. When no `@docs` line names an exposed value
and `forceMultiline` is `True`, every exposed value is a group of its own instead.

An entry moved into a `@docs` group loses its comments, which are returned as
the second element so they can still be printed.

Names are matched as written on the `@docs` line, so `Type(..)` there does not
match an exposed `Type`.

-}
sortVars : Bool -> EverySet String (Src.C2 Value) -> List (List String) -> ( List (List (Src.C2 Value)), Src.FComments )
sortVars forceMultiline fromExposing fromDocs =
    let
        varOrder : Src.C2 Value -> ( Int, String )
        varOrder ( _, value ) =
            case value of
                OpValue name ->
                    ( 1, name )

                Union ( _, name ) _ ->
                    ( 2, name )

                Value name ->
                    ( 3, name )

        listedInDocs : List (List (Src.C2 Value))
        listedInDocs =
            fromDocs
                |> List.map (List.filterMap (\v -> Map.get identity v allowedInDocs))
                |> List.filter (not << List.isEmpty)
                |> List.map (List.map (Tuple.pair ( [], [] )))
                |> removeDuplicates

        listedInExposing : List (Src.C2 Value)
        listedInExposing =
            fromExposing
                |> EverySet.toList
                |> List.sortBy varOrder

        varName : Src.C2 Value -> String
        varName ( _, value ) =
            case value of
                Value name ->
                    name

                OpValue name ->
                    name

                Union ( _, name ) _ ->
                    name

        varSetToMap : EverySet String (Src.C2 Value) -> Dict String String Value
        varSetToMap set =
            EverySet.toList set
                |> List.map (\( c, var ) -> ( varName ( c, var ), var ))
                |> Map.fromList identity

        allowedInDocs : Dict String String Value
        allowedInDocs =
            varSetToMap fromExposing

        allFromDocs : EverySet String String
        allFromDocs =
            List.concat listedInDocs |> List.map varName |> EverySet.fromList identity

        inDocs : Src.C2 Value -> Bool
        inDocs x =
            EverySet.member identity (varName x) allFromDocs

        remainingFromExposing : List (Src.C2 Value)
        remainingFromExposing =
            listedInExposing
                |> List.filter (not << inDocs)

        commentsFromReorderedVars : Src.FComments
        commentsFromReorderedVars =
            listedInExposing
                |> List.filter inDocs
                |> List.concatMap (\( ( pre, post ), _ ) -> pre ++ post)
    in
    if List.isEmpty listedInDocs && forceMultiline then
        ( List.map (\x -> [ x ]) remainingFromExposing, commentsFromReorderedVars )

    else
        ( listedInDocs
            ++ (if List.isEmpty remainingFromExposing then
                    []

                else
                    [ remainingFromExposing ]
               )
        , commentsFromReorderedVars
        )


{-| Returns the lines before the module body: the `module` line, the module doc
comment and the imports, with a blank line between each two present.

The `module` line is printed only when the module has one or `addDefaultHeader`
is `True`; its exposing list is ordered as `sortVars` describes.

-}
formatModuleHeader : Bool -> Module -> List Box
formatModuleHeader addDefaultHeader modu =
    let
        maybeHeader : Maybe Header
        maybeHeader =
            if addDefaultHeader then
                Just (Maybe.withDefault defaultHeader modu.header)

            else
                modu.header

        refName : Ref (List String) -> String
        refName ref =
            case ref of
                VarRef _ name ->
                    name

                TagRef _ name ->
                    name

                OpRef name ->
                    name

        varName : Src.C2 Value -> Name
        varName var =
            case var of
                ( _, Value name ) ->
                    name

                ( _, OpValue name ) ->
                    name

                ( _, Union ( _, name ) _ ) ->
                    name

        documentedVars : List (List String)
        documentedVars =
            modu.docs
                |> A.toValue
                |> Maybe.withDefault []
                |> List.concatMap extractDocs

        extractDocs : Block -> List (List String)
        extractDocs block =
            case block of
                ElmDocs vars ->
                    List.map (List.map (refName << textToRef)) vars

                _ ->
                    []

        textToRef : String -> Ref (List String)
        textToRef text =
            case String.toList text of
                (c :: _) as s ->
                    if Char.isUpper c then
                        TagRef [] text

                    else if Char.isLower c then
                        VarRef [] text

                    else
                        case s of
                            [ '(', a, ')' ] ->
                                OpRef (String.fromChar a)

                            [ '(', a, b, ')' ] ->
                                OpRef (String.fromList [ a, b ])

                            _ ->
                                VarRef [] text

                _ ->
                    VarRef [] text

        exportsList : Listing DetailedListing
        exportsList =
            case Maybe.withDefault defaultHeader maybeHeader of
                Header props ->
                    case props.exports of
                        Just ( _, e ) ->
                            e

                        Nothing ->
                            ClosedListing

        detailedListingToSet : Listing DetailedListing -> EverySet String (Src.C2 Value)
        detailedListingToSet value =
            case value of
                OpenListing _ ->
                    EverySet.empty

                ClosedListing ->
                    EverySet.empty

                ExplicitListing { values, operators, types } _ ->
                    let
                        toComparable : Src.C2 Value -> Name
                        toComparable ( _, v ) =
                            case v of
                                OpValue name ->
                                    name

                                Union ( _, name ) _ ->
                                    name

                                Value name ->
                                    name
                    in
                    List.foldl EverySet.union EverySet.empty <|
                        [ Map.toList values |> List.map (\( name, ( c, () ) ) -> ( c, Value name )) |> EverySet.fromList toComparable
                        , Map.toList operators |> List.map (\( name, ( c, () ) ) -> ( c, OpValue name )) |> EverySet.fromList toComparable
                        , Map.toList types |> List.map (\( name, ( c, ( preListing, listing ) ) ) -> ( c, Union ( preListing, name ) listing )) |> EverySet.fromList toComparable
                        ]

        detailedListingIsMultiline : Listing a -> Bool
        detailedListingIsMultiline listing =
            case listing of
                ExplicitListing _ isMultiline ->
                    isMultiline

                _ ->
                    False

        varsToExpose : EverySet String (Src.C2 Value)
        varsToExpose =
            case Maybe.andThen (\(Header props) -> props.exports) maybeHeader of
                Nothing ->
                    let
                        definedVars : EverySet String (Src.C2 Value)
                        definedVars =
                            modu.body
                                |> List.concatMap extractVarName
                                |> List.map (Tuple.pair ( [], [] ))
                                |> EverySet.fromList
                                    (\( _, value ) ->
                                        case value of
                                            Value name ->
                                                name

                                            OpValue name ->
                                                name

                                            Union ( _, name ) _ ->
                                                name
                                    )
                    in
                    if List.all List.isEmpty documentedVars then
                        definedVars

                    else
                        let
                            documentedVarsSet : EverySet String String
                            documentedVarsSet =
                                EverySet.fromList identity (List.concat documentedVars)
                        in
                        definedVars |> EverySet.filter (\v -> EverySet.member identity (varName v) documentedVarsSet)

                Just ( _, e ) ->
                    detailedListingToSet e

        sortedExports : ( List (List (Src.C2 Value)), Src.FComments )
        sortedExports =
            sortVars
                (detailedListingIsMultiline exportsList)
                varsToExpose
                documentedVars

        extractVarName : TopLevelStructure Declaration -> List Value
        extractVarName decl =
            case decl of
                DocComment _ ->
                    []

                BodyComment _ ->
                    []

                Entry (PortAnnotation ( _, name ) _ _) ->
                    [ Value name ]

                Entry (CommonDeclaration def) ->
                    case def of
                        Definition (A.At _ pat) _ _ _ ->
                            case pat of
                                Src.PVar name ->
                                    [ Value name ]

                                Src.PRecord ( _, fields ) ->
                                    List.map (\( _, A.At _ field ) -> Value field) fields

                                _ ->
                                    []

                        _ ->
                            []

                Entry (Datatype ( _, NameWithArgs name _ ) _) ->
                    [ Union ( [], name ) (OpenListing ( ( [], [] ), () )) ]

                Entry (TypeAlias _ ( _, NameWithArgs name _ ) _) ->
                    [ Union ( [], name ) ClosedListing ]

                Entry _ ->
                    []

        formatModuleLine_ : Header -> Box
        formatModuleLine_ (Header props) =
            let
                ( preExposing, postExposing ) =
                    case props.exports of
                        Nothing ->
                            ( [], [] )

                        Just ( ( pre, post ), _ ) ->
                            ( pre, post )
            in
            formatModuleLine sortedExports props.srcTag props.name props.moduleSettings preExposing postExposing

        docs : Maybe Box
        docs =
            modu.docs |> A.toValue |> Maybe.map (formatDocComment modu.importInfo)

        imports : List Box
        imports =
            formatImports modu
    in
    List.concat
        (List.intersperse [ Box.blankLine ] <|
            List.concat
                [ Maybe.toList (Maybe.map (List.singleton << formatModuleLine_) maybeHeader)
                , Maybe.toList (Maybe.map List.singleton docs)
                , if List.isEmpty imports then
                    []

                  else
                    [ imports ]
                ]
        )


{-| Returns the import lines of a module, sorted by module path, preceded by the comments that come before them, with a blank line between the comments and the imports.
-}
formatImports : Module -> List Box
formatImports modu =
    let
        ( comments, imports ) =
            modu.imports
    in
    [ formatComments comments
        |> Maybe.toList
    , imports
        |> Map.toList
        |> List.map (\( name, ( pre, method ) ) -> formatImport ( ( pre, name ), method ))
    ]
        |> List.filter (not << List.isEmpty)
        |> List.intersperse [ Box.blankLine ]
        |> List.concat


{-| Returns the `module` line: the source tag, the name, the `where` clause of an
effect module, and `exposing` with the exposing list.

`varsToExpose` holds the groups `sortVars` returns. No groups print as `(..)`;
one group is one parenthesised list; several groups are printed one group to a
line. `extraComments` are printed at the end of the list.

-}
formatModuleLine :
    ( List (List (Src.C2 Value)), Src.FComments )
    -> SourceTag
    -> Src.C2 (List Name)
    -> Maybe (Src.C2 SourceSettings)
    -> Src.FComments
    -> Src.FComments
    -> Box
formatModuleLine ( varsToExpose, extraComments ) srcTag name moduleSettings preExposing postExposing =
    let
        tag : Box
        tag =
            case srcTag of
                Normal ->
                    Box.line (Box.keyword "module")

                Port comments ->
                    ElmStructure.spaceSepOrIndented
                        (formatTailCommented ( comments, Box.keyword "port" |> Box.line ))
                        [ Box.line (Box.keyword "module") ]

                Effect comments ->
                    ElmStructure.spaceSepOrIndented
                        (formatTailCommented ( comments, Box.keyword "effect" |> Box.line ))
                        [ Box.line (Box.keyword "module") ]

        exports : Box
        exports =
            case varsToExpose of
                [] ->
                    Box.keyword "(..)" |> Box.line

                [ oneGroup ] ->
                    oneGroup
                        |> List.map (formatCommented << Src.c2map formatVarValue)
                        |> ElmStructure.group_ False "(" "," (Maybe.toList (formatComments extraComments)) ")" False

                _ ->
                    varsToExpose
                        |> List.map (formatCommented << Src.c2map (ElmStructure.group False "" "," "" False << List.map formatVarValue) << Src.sequenceAC2)
                        |> ElmStructure.group_ False "(" "," (Maybe.toList (formatComments extraComments)) ")" True

        formatSetting : ( Src.C2 String, Src.C2 String ) -> Box
        formatSetting ( k, v ) =
            formatRecordPair "=" (formatUppercaseIdentifier >> Box.line) ( k, v, False )

        formatSettings : List ( Src.C2 String, Src.C2 String ) -> Box
        formatSettings settings =
            List.map formatSetting settings
                |> ElmStructure.group True "{" "," "}" False

        whereClause : List Box
        whereClause =
            moduleSettings
                |> Maybe.map (formatKeywordCommented "where" << Src.c2map formatSettings)
                |> Maybe.map (\x -> [ x ])
                |> Maybe.withDefault []

        nameClause : Box
        nameClause =
            case
                ( tag
                , Src.c2map (Box.line << formatQualifiedUppercaseIdentifier) name |> formatCommented
                )
            of
                ( Box.SingleLine tag_, Box.SingleLine name_ ) ->
                    Box.line
                        (Box.row
                            [ tag_
                            , Box.space
                            , name_
                            ]
                        )

                ( tag_, name_ ) ->
                    Box.stack1
                        [ tag_
                        , Box.indent name_
                        ]
    in
    ElmStructure.spaceSepOrIndented
        (ElmStructure.spaceSepOrIndented
            nameClause
            (whereClause ++ [ formatCommented ( ( preExposing, postExposing ), Box.keyword "exposing" |> Box.line ) ])
        )
        [ exports ]


{-| Returns the layout of a whole parsed module.

When `addDefaultHeader` is `True` and the source has no `module` line, a
`module Main exposing (...)` line is added. Its exposing list holds the names
the module defines, and is `(..)` when it defines none.

`spacing` is the usual number of blank lines between top-level declarations.
None are put between a doc comment and its definition, an annotation and its
definition, or two comments, and one more usually goes before a comment unless
`spacing` is 1. The body starts `spacing` blank lines after what comes before
it, one more when it starts with a comment.

Line breaks follow the source: a construct that spanned several lines there is
laid out over several lines here.

-}
formatModule : Bool -> Int -> M.Module -> Box
formatModule addDefaultHeader spacing modu =
    formatModule_ addDefaultHeader spacing (formatModu modu)


{-| Converts a parsed module into the formatter's model.

Imports are keyed by module path, so they come out sorted, and an import of the
same module twice keeps only the last. The comments after every import but the
last are moved before the first import, and those after the last import start
the body. The body is the `infix` declarations in source order, each followed
by the comments after it, and then the declarations. The module doc comment is
parsed as Markdown.

-}
formatModu : M.Module -> Module
formatModu modu =
    let
        declarations : List (TopLevelStructure Declaration)
        declarations =
            List.concatMap declToDeclarations modu.decls

        ( moduleHeaderComments, imports ) =
            List.foldl
                (\( comments, Src.Import ( importNameComments, A.At _ importName ) maybeAlias exposing_ ) ( importCommentsAcc, ( importComments, importsAcc ) ) ->
                    let
                        exposedVars : Src.C2 (Listing DetailedListing)
                        exposedVars =
                            Src.c2map
                                (\exposing__ ->
                                    case exposing__ of
                                        Src.Open preComments postComments ->
                                            OpenListing ( ( preComments, postComments ), () )

                                        Src.Explicit (A.At _ []) ->
                                            ClosedListing

                                        Src.Explicit (A.At region exposed) ->
                                            ExplicitListing
                                                (List.foldl
                                                    (\( entryComments, entry ) acc ->
                                                        case entry of
                                                            Src.Lower (A.At _ name) ->
                                                                { acc | values = Map.insert identity name ( entryComments, () ) acc.values }

                                                            Src.Upper (A.At _ name) ( privacyComments, Src.Public _ ) ->
                                                                { acc | types = Map.insert identity name ( entryComments, ( privacyComments, OpenListing ( ( [], [] ), () ) ) ) acc.types }

                                                            Src.Upper (A.At _ name) ( privacyComments, Src.Private ) ->
                                                                { acc | types = Map.insert identity name ( entryComments, ( privacyComments, ClosedListing ) ) acc.types }

                                                            Src.Operator _ name ->
                                                                { acc | operators = Map.insert identity name ( entryComments, () ) acc.operators }
                                                    )
                                                    { values = Map.empty
                                                    , operators = Map.empty
                                                    , types = Map.empty
                                                    }
                                                    exposed
                                                )
                                                (A.isMultiline region)
                                )
                                exposing_
                    in
                    ( comments
                    , ( importComments ++ importCommentsAcc
                      , Map.insert identity (String.split "." importName) ( importNameComments, ImportMethod maybeAlias exposedVars ) importsAcc
                      )
                    )
                )
                ( [], Src.c1map (\_ -> Map.empty) modu.imports )
                (Src.c1Value modu.imports)

        body : List (TopLevelStructure Declaration)
        body =
            List.map BodyComment moduleHeaderComments
                ++ List.concatMap
                    (\( commments, A.At _ (Src.Infix data) ) ->
                        Entry (Fixity data.associativity data.precedence data.op data.name) :: List.map BodyComment commments
                    )
                    (List.reverse modu.infixes)
                ++ declarations
    in
    { importInfo = ImportInfo.fromModule
    , initialComments = modu.initialComments
    , header =
        Maybe.map
            (\header ->
                let
                    ( sourceTag, sourceSettings ) =
                        case header.effects of
                            M.NoEffects _ ->
                                ( Normal, Nothing )

                            M.Ports _ comments ->
                                ( Port comments, Nothing )

                            M.Manager _ comments ( postWhereComments, manager ) ->
                                ( Effect comments
                                , Just
                                    ( ( [], postWhereComments )
                                    , case manager of
                                        Src.Cmd ( ( preCmdComments, postCmdComments ), ( ( preEqualComments, postEqualComments ), A.At _ cmdType ) ) ->
                                            [ ( ( ( preCmdComments, preEqualComments ), "command" ), ( ( postEqualComments, postCmdComments ), cmdType ) )
                                            ]

                                        Src.Sub ( ( preSubComments, postSubComments ), ( ( preEqualComments, postEqualComments ), A.At _ subType ) ) ->
                                            [ ( ( ( preSubComments, preEqualComments ), "subscription" ), ( ( postEqualComments, postSubComments ), subType ) )
                                            ]

                                        Src.Fx cmdArg subArg ->
                                            let
                                                ( ( preCmdComments, postCmdComments ), ( ( preEqualCmdComments, postEqualCmdComments ), cmdLocated ) ) =
                                                    cmdArg

                                                (A.At (A.Region (A.Position cmdTypeStart cmdTypeEnd) _) cmdType) =
                                                    cmdLocated

                                                ( ( preSubComments, postSubComments ), ( ( preEqualSubComments, postEqualSubComments ), subLocated ) ) =
                                                    subArg

                                                (A.At (A.Region (A.Position subTypeStart subTypeEnd) _) subType) =
                                                    subLocated
                                            in
                                            [ ( ( cmdTypeStart, cmdTypeEnd )
                                              , ( ( ( preCmdComments, preEqualCmdComments ), "command" )
                                                , ( ( postEqualCmdComments, postCmdComments ), cmdType )
                                                )
                                              )
                                            , ( ( subTypeStart, subTypeEnd )
                                              , ( ( ( preSubComments, preEqualSubComments ), "subscription" )
                                                , ( ( postEqualSubComments, postSubComments ), subType )
                                                )
                                              )
                                            ]
                                                |> List.sortBy Tuple.first
                                                |> List.map Tuple.second
                                    )
                                )

                    exportsListing : Src.C2 (Listing DetailedListing)
                    exportsListing =
                        Src.c2map
                            (\(A.At _ exposing_) ->
                                case exposing_ of
                                    Src.Open preComments postComments ->
                                        OpenListing ( ( preComments, postComments ), () )

                                    Src.Explicit (A.At region exposed) ->
                                        ExplicitListing
                                            (List.foldl
                                                (\( entryComments, entry ) acc ->
                                                    case entry of
                                                        Src.Lower (A.At _ name) ->
                                                            { acc | values = Map.insert identity name ( entryComments, () ) acc.values }

                                                        Src.Upper (A.At _ name) ( privacyComments, Src.Public _ ) ->
                                                            { acc | types = Map.insert identity name ( entryComments, ( privacyComments, OpenListing ( ( [], [] ), () ) ) ) acc.types }

                                                        Src.Upper (A.At _ name) ( privacyComments, Src.Private ) ->
                                                            { acc | types = Map.insert identity name ( entryComments, ( privacyComments, ClosedListing ) ) acc.types }

                                                        Src.Operator _ name ->
                                                            { acc | operators = Map.insert identity name ( entryComments, () ) acc.operators }
                                                )
                                                { values = Map.empty
                                                , operators = Map.empty
                                                , types = Map.empty
                                                }
                                                exposed
                                            )
                                            (A.isMultiline region)
                            )
                            header.exports
                in
                makeHeader sourceTag (Src.c2map (String.split "." << A.toValue) header.name) sourceSettings (Just exportsListing)
            )
            modu.header
    , docs =
        modu.header
            |> Maybe.andThen (.docs >> Result.toMaybe)
            |> Maybe.map
                (\(Src.Comment (Snippet.Snippet { fptr, offset, length })) ->
                    String.slice offset (offset + length) fptr
                        |> String.trim
                        |> Parse.markdown
                        |> (\(Doc blocks) -> blocks)
                )
            |> A.At A.zero
    , imports = imports
    , body = body
    }


{-| Returns a parsed top-level declaration as top-level items: the comments
before it, its doc comment parsed as Markdown, the declaration (a value with
an annotation becomes the annotation followed by the definition), and the
comments after it.

A union type with no constructors stops the program with `crash`.

-}
declToDeclarations : Src.C2 Decl.Decl -> List (TopLevelStructure Declaration)
declToDeclarations ( ( preDeclComments, postDeclComments ), decl ) =
    List.map BodyComment preDeclComments
        ++ (case decl of
                Decl.Value maybeDocs (A.At _ (Src.Value valueData)) ->
                    let
                        preValueComments =
                            valueData.comments

                        ( postNameComments, A.At nameRegion name ) =
                            valueData.name

                        srcArgs =
                            valueData.args

                        ( valueBodyComments, valueBody ) =
                            valueData.body

                        maybeType =
                            valueData.tipe
                    in
                    (maybeDocs
                        |> Maybe.map
                            (\(Src.Comment (Snippet.Snippet { fptr, offset, length })) ->
                                [ DocComment
                                    (String.slice offset (offset + length) fptr
                                        |> String.trim
                                        |> Parse.markdown
                                        |> (\(Doc blocks) -> blocks)
                                    )
                                ]
                            )
                        |> Maybe.withDefault []
                    )
                        ++ List.map BodyComment preValueComments
                        ++ (maybeType
                                |> Maybe.map
                                    (\( postComments, ( ( preTypComments, postTypeComments ), typ ) ) ->
                                        Entry (CommonDeclaration (TypeAnnotation ( preTypComments, VarRef () name ) ( postTypeComments, typ )))
                                            :: List.map BodyComment postComments
                                    )
                                |> Maybe.withDefault []
                           )
                        ++ [ Entry (CommonDeclaration (Definition (A.At nameRegion (Src.PVar name)) srcArgs (postNameComments ++ valueBodyComments) valueBody)) ]

                Decl.Union maybeDocs (A.At _ (Src.Union ( nameComments, A.At _ name ) args constructors)) ->
                    let
                        ( postTagsComments, tags ) =
                            case List.reverse constructors of
                                ( ( preLastConstructorComments, postLastConstructorComments, _ ), ( A.At _ lastName, lastArgs ) ) :: restConstructors ->
                                    ( postLastConstructorComments
                                    , Src.OpenCommentedList
                                        (List.map
                                            (\( comments, ( A.At _ constructorName, constructorArgs ) ) ->
                                                ( comments, NameWithArgs constructorName constructorArgs )
                                            )
                                            (List.reverse restConstructors)
                                        )
                                        ( preLastConstructorComments, Nothing, NameWithArgs lastName lastArgs )
                                    )

                                -- The parser never produces a union type without constructors.
                                _ ->
                                    crash "union type without constructors"
                    in
                    (maybeDocs
                        |> Maybe.map
                            (\(Src.Comment (Snippet.Snippet { fptr, offset, length })) ->
                                [ DocComment
                                    (String.slice offset (offset + length) fptr
                                        |> String.trim
                                        |> Parse.markdown
                                        |> (\(Doc blocks) -> blocks)
                                    )
                                ]
                            )
                        |> Maybe.withDefault []
                    )
                        ++ Entry (Datatype ( nameComments, NameWithArgs name (List.map (Src.c1map A.toValue) args) ) tags)
                        :: List.map BodyComment postTagsComments

                Decl.Alias maybeDocs (A.At _ (Src.Alias aliasData)) ->
                    let
                        nameWithArgs : Src.C2 (NameWithArgs Name Name)
                        nameWithArgs =
                            Src.c2map
                                (\(A.At _ n) ->
                                    NameWithArgs n (List.map (Src.c1map A.toValue) aliasData.args)
                                )
                                aliasData.name
                    in
                    (maybeDocs
                        |> Maybe.map
                            (\(Src.Comment (Snippet.Snippet { fptr, offset, length })) ->
                                [ DocComment
                                    (String.slice offset (offset + length) fptr
                                        |> String.trim
                                        |> Parse.markdown
                                        |> (\(Doc blocks) -> blocks)
                                    )
                                ]
                            )
                        |> Maybe.withDefault []
                    )
                        ++ [ Entry (TypeAlias aliasData.comments nameWithArgs aliasData.tipe) ]

                Decl.Port maybeDocs (Src.Port comments name tipe) ->
                    (maybeDocs
                        |> Maybe.map
                            (\(Src.Comment (Snippet.Snippet { fptr, offset, length })) ->
                                [ DocComment
                                    (String.slice offset (offset + length) fptr
                                        |> String.trim
                                        |> Parse.markdown
                                        |> (\(Doc blocks) -> blocks)
                                    )
                                ]
                            )
                        |> Maybe.withDefault []
                    )
                        ++ [ Entry (PortAnnotation (Src.c2map A.toValue name) comments tipe) ]
           )
        ++ List.map BodyComment postDeclComments


{-| Returns the layout of a module in the formatter's model, as `formatModule` describes: any comments before the header followed by two blank lines, the header, and the body.
-}
formatModule_ : Bool -> Int -> Module -> Box
formatModule_ addDefaultHeader spacing modu =
    let
        initialComments_ : List Box
        initialComments_ =
            case modu.initialComments of
                [] ->
                    []

                comments ->
                    List.map formatComment comments
                        ++ [ Box.blankLine, Box.blankLine ]

        spaceBeforeBody : Int
        spaceBeforeBody =
            case modu.body of
                [] ->
                    0

                (BodyComment _) :: _ ->
                    spacing + 1

                _ ->
                    spacing

        decls : List (TopLevelStructure Declaration)
        decls =
            modu.body
    in
    Box.stack1 <|
        List.concat
            [ initialComments_
            , formatModuleHeader addDefaultHeader modu
            , List.repeat spaceBeforeBody Box.blankLine
            , formatModuleBody spacing modu.importInfo decls |> Maybe.toList
            ]


{-| Returns the layout of a list of top-level items with `linesBetween` blank lines between declarations, or `Nothing` when there are none.
-}
formatModuleBody : Int -> ImportInfo -> List (TopLevelStructure Declaration) -> Maybe Box
formatModuleBody linesBetween importInfo body =
    let
        entryType : Declaration -> BodyEntryType
        entryType adecl =
            case adecl of
                CommonDeclaration def ->
                    case def of
                        Definition (A.At _ pat) _ _ _ ->
                            case pat of
                                Src.PVar name ->
                                    VarRef () name |> BodyNamed

                                _ ->
                                    BodyUnnamed

                        TypeAnnotation ( _, name ) _ ->
                            BodyNamed name

                Datatype ( _, NameWithArgs name _ ) _ ->
                    TagRef () name |> BodyNamed

                TypeAlias _ ( _, NameWithArgs name _ ) _ ->
                    TagRef () name |> BodyNamed

                PortAnnotation ( _, name ) _ _ ->
                    VarRef () name |> BodyNamed

                Fixity _ _ _ _ ->
                    BodyFixity
    in
    List.map (topLevelStructureMap (\b -> ( entryType b, formatDeclaration importInfo b ))) body |> formatTopLevelBody linesBetween importInfo


{-| What kind of declaration a top-level entry is, for spacing.

`BodyNamed` is a declaration of one name, `BodyUnnamed` a definition of any
other pattern, and `BodyFixity` an `infix` declaration.

-}
type BodyEntryType
    = BodyNamed (Ref ())
    | BodyUnnamed
    | BodyFixity


{-| Returns the given items stacked with blank lines between them, or `Nothing`
when there are none.

Two items are usually `linesBetween` blank lines apart. Nothing separates a
doc comment from the definition after it, an annotation from the definition of
the same name, two comments, two `infix` declarations, an opening comment-trick
marker from the item after it, or a closing one from the item before it. Before a comment there is one
more blank line than usual unless `linesBetween` is 1, and between a comment
and the definition after it there are none when `linesBetween` is 1.

-}
formatTopLevelBody :
    Int
    -> ImportInfo
    -> List (TopLevelStructure ( BodyEntryType, Box ))
    -> Maybe Box
formatTopLevelBody linesBetween importInfo body =
    let
        extraLines : Int -> List Box
        extraLines n =
            List.repeat n Box.blankLine

        spacer : TopLevelStructure ( BodyEntryType, Box ) -> TopLevelStructure ( BodyEntryType, Box ) -> Int
        spacer a b =
            case ( declarationType (topLevelStructureMap Tuple.first a), declarationType (topLevelStructureMap Tuple.first b) ) of
                ( DStarter, _ ) ->
                    0

                ( _, DCloser ) ->
                    0

                ( DComment, DComment ) ->
                    0

                ( _, DComment ) ->
                    if linesBetween == 1 then
                        1

                    else
                        linesBetween + 1

                ( DComment, DDefinition _ ) ->
                    if linesBetween == 1 then
                        0

                    else
                        linesBetween

                ( DComment, _ ) ->
                    linesBetween

                ( DDocComment, DDefinition _ ) ->
                    0

                ( DDefinition Nothing, DDefinition (Just _) ) ->
                    linesBetween

                ( DDefinition _, DStarter ) ->
                    linesBetween

                ( DDefinition Nothing, DDefinition Nothing ) ->
                    linesBetween

                ( DDefinition a_, DDefinition b_ ) ->
                    if a_ == b_ then
                        0

                    else
                        linesBetween

                ( DCloser, _ ) ->
                    linesBetween

                ( _, DDocComment ) ->
                    linesBetween

                ( DDocComment, DStarter ) ->
                    0

                ( DFixity, DFixity ) ->
                    0

                ( DFixity, _ ) ->
                    linesBetween

                ( _, DFixity ) ->
                    linesBetween

        boxes : List Box
        boxes =
            intersperseMap (\a b -> spacer a b |> extraLines)
                (topLevelStructureMap Tuple.second >> formatTopLevelStructure importInfo)
                body
    in
    case boxes of
        [] ->
            Nothing

        _ ->
            Box.stack1 boxes |> Just


{-| The Elm code in a doc-comment code block, according to which of the three parses accepted it.
-}
type ElmCodeBlock
    = DeclarationsCode (List (TopLevelStructure Declaration))
    | ExpressionsCode (List (TopLevelStructure (Src.C0Eol Src.Expr)))
    | ModuleCode Module


{-| Returns a doc comment laid out as `{-| ... -}`.

The Markdown is reprinted by `Common.Format.Render.Markdown`, with `(..)`
removed from the names on `@docs` lines. Each Elm code block is reformatted
when it parses as a declaration, an expression or a module, tried in that
order, with one blank line between declarations; otherwise it is kept as
written.

-}
formatDocComment : ImportInfo -> Blocks -> Box
formatDocComment importInfo blocks =
    let
        parse : String -> Maybe ElmCodeBlock
        parse source =
            source
                |> Maybe.oneOf
                    [ parseDeclarations >> Result.toMaybe >> Maybe.map DeclarationsCode
                    , parseExpressions >> Result.toMaybe >> Maybe.map ExpressionsCode
                    , parseModule >> Result.toMaybe >> Maybe.map ModuleCode
                    ]

        format : ElmCodeBlock -> String
        format result =
            case result of
                ModuleCode modu ->
                    formatModule_ False 1 modu
                        |> Box.render

                DeclarationsCode declarations ->
                    formatModuleBody 1 importInfo declarations
                        |> Maybe.map Box.render
                        |> Maybe.withDefault ""

                ExpressionsCode expressions ->
                    expressions
                        |> List.map (topLevelStructureMap (formatEolCommented << Src.c0EolMap (syntaxParens SyntaxSeparated << formatExpression importInfo)))
                        |> List.map (topLevelStructureMap (Tuple.pair BodyUnnamed))
                        |> formatTopLevelBody 1 importInfo
                        |> Maybe.map Box.render
                        |> Maybe.withDefault ""

        content : String
        content =
            Markdown.formatMarkdown (Maybe.map format << parse) (List.map cleanBlock blocks)

        cleanBlock : Block -> Block
        cleanBlock block =
            case block of
                ElmDocs docs ->
                    ElmDocs <|
                        (List.map << List.map)
                            (String.replace "(..)" "")
                            docs

                _ ->
                    block
    in
    formatDocCommentString content


{-| Parses `source` as one top-level declaration and returns it as top-level items.
-}
parseDeclarations : String -> Result () (List (TopLevelStructure Declaration))
parseDeclarations source =
    P.fromByteString (P.specialize (\_ -> Tuple.pair) Decl.declaration) Tuple.pair source
        |> Result.mapError (\_ -> ())
        |> Result.map (\( decl, _ ) -> declToDeclarations decl)


{-| Parses `source` as one expression and returns it as a single item.
-}
parseExpressions : String -> Result () (List (TopLevelStructure (Src.C0Eol Src.Expr)))
parseExpressions source =
    P.fromByteString (P.specialize (\_ -> Tuple.pair) Expr.expression) Tuple.pair source
        |> Result.mapError (\_ -> ())
        |> Result.map (\( ( _, expr ), _ ) -> [ Entry ( Nothing, expr ) ])


{-| Parses `source` as a module of an application and returns the formatter's
model of it.

An application gets the default imports, so the result also holds `Basics`,
`List`, `Maybe` and the other default imports, except where `source` imports
the same module.

-}
parseModule : String -> Result () Module
parseModule source =
    P.fromByteString (P.specialize (\_ -> Tuple.pair) (M.chompModule M.Application)) Tuple.pair source
        |> Result.mapError (\_ -> ())
        |> Result.map formatModu


{-| Returns the doc comment whose text is `docs`: `{-|` and the first line, the other lines unchanged, and `-}` on a line of its own, with a trailing empty line dropped. Empty text gives `{-| -}` on one line.
-}
formatDocCommentString : String -> Box
formatDocCommentString docs =
    case lines docs of
        [] ->
            Box.row [ Box.punc "{-|", Box.space, Box.punc "-}" ] |> Box.line

        [ first ] ->
            Box.stack1
                [ Box.row [ Box.punc "{-|", Box.space, Box.literal first ] |> Box.line
                , Box.punc "-}" |> Box.line
                ]

        first :: rest ->
            Box.line (Box.row [ Box.punc "{-|", Box.space, Box.literal first ])
                |> Box.andThen (List.map (Box.line << Box.literal) rest)
                |> Box.andThen [ Box.punc "-}" |> Box.line ]


{-| Returns the lines of `str`, without the empty line after a final newline.
-}
lines : String -> List String
lines str =
    case List.reverse (String.lines str) of
        "" :: rest ->
            List.reverse rest

        result ->
            List.reverse result


{-| Returns one import line: the module name, its `as` clause and its `exposing`
clause.

An alias equal to the module name is not printed. The import is one line when
every part is a single line; otherwise some parts go on indented lines below.

-}
formatImport : UserImport -> Box
formatImport ( ( _, rawName ) as name, (ImportMethod _ exposedVars) as method ) =
    let
        requestedAs : Maybe (Src.C2 Name)
        requestedAs =
            case method of
                ImportMethod ((Just ( _, aliasName )) as other) _ ->
                    if [ aliasName ] == rawName then
                        Nothing

                    else
                        other

                ImportMethod other _ ->
                    other

        asVar : Maybe Box
        asVar =
            requestedAs
                |> Maybe.map
                    (formatImportClause
                        (Just << Box.line << formatUppercaseIdentifier)
                        "as"
                    )
                |> Maybe.join

        exposingVar : Maybe Box
        exposingVar =
            formatImportClause
                (formatListing formatDetailedListing)
                "exposing"
                exposedVars

        formatImportClause : (a -> Maybe Box) -> String -> Src.C2 a -> Maybe Box
        formatImportClause format keyw input =
            case Src.c2map format input of
                ( ( [], [] ), Nothing ) ->
                    Nothing

                ( ( preKeyword, postKeyword ), Just listing_ ) ->
                    case
                        ( formatPreCommented ( preKeyword, Box.line (Box.keyword keyw) )
                        , formatPreCommented ( postKeyword, listing_ )
                        )
                    of
                        ( Box.SingleLine keyword_, Box.SingleLine listing__ ) ->
                            Just
                                (Box.line
                                    (Box.row
                                        [ keyword_
                                        , Box.space
                                        , listing__
                                        ]
                                    )
                                )

                        ( keyword_, listing__ ) ->
                            Just
                                (Box.stack1
                                    [ keyword_
                                    , Box.indent listing__
                                    ]
                                )

                _ ->
                    Just (pleaseReport "UNEXPECTED IMPORT" "import clause comments with no clause")
    in
    case
        ( Src.c1map (Box.line << formatQualifiedUppercaseIdentifier) name |> formatPreCommented
        , asVar
        , exposingVar
        )
    of
        ( Box.SingleLine name_, Just (Box.SingleLine as_), Just (Box.SingleLine exposing__) ) ->
            Box.line <|
                Box.row
                    [ Box.keyword "import"
                    , Box.space
                    , name_
                    , Box.space
                    , as_
                    , Box.space
                    , exposing__
                    ]

        ( Box.SingleLine name_, Just (Box.SingleLine as_), Nothing ) ->
            Box.line <|
                Box.row
                    [ Box.keyword "import"
                    , Box.space
                    , name_
                    , Box.space
                    , as_
                    ]

        ( Box.SingleLine name_, Nothing, Just (Box.SingleLine exposing__) ) ->
            Box.line <|
                Box.row
                    [ Box.keyword "import"
                    , Box.space
                    , name_
                    , Box.space
                    , exposing__
                    ]

        ( Box.SingleLine name_, Nothing, Nothing ) ->
            Box.line <|
                Box.row
                    [ Box.keyword "import"
                    , Box.space
                    , name_
                    ]

        ( Box.SingleLine name_, Just (Box.SingleLine as_), Just exposing__ ) ->
            Box.stack1
                [ Box.line <|
                    Box.row
                        [ Box.keyword "import"
                        , Box.space
                        , name_
                        , Box.space
                        , as_
                        ]
                , Box.indent exposing__
                ]

        ( Box.SingleLine name_, Just as_, Just exposing__ ) ->
            Box.stack1
                [ Box.line <|
                    Box.row
                        [ Box.keyword "import"
                        , Box.space
                        , name_
                        ]
                , Box.indent as_
                , Box.indent exposing__
                ]

        ( Box.SingleLine name_, Nothing, Just exposing__ ) ->
            Box.stack1
                [ Box.line <|
                    Box.row
                        [ Box.keyword "import"
                        , Box.space
                        , name_
                        ]
                , Box.indent exposing__
                ]

        ( name_, Just as_, Just exposing__ ) ->
            Box.stack1
                [ Box.keyword "import" |> Box.line
                , Box.indent name_
                , Box.indent as_ |> Box.indent
                , Box.indent exposing__ |> Box.indent
                ]

        ( name_, Nothing, Just exposing__ ) ->
            Box.stack1
                [ Box.keyword "import" |> Box.line
                , Box.indent name_
                , Box.indent exposing__ |> Box.indent
                ]

        ( name_, Just as_, Nothing ) ->
            Box.stack1
                [ Box.keyword "import" |> Box.line
                , Box.indent name_
                , Box.indent as_ |> Box.indent
                ]

        ( name_, Nothing, Nothing ) ->
            Box.stack1
                [ Box.keyword "import" |> Box.line
                , Box.indent name_
                ]


{-| Returns a listing in parentheses, using `format` for the entries of an explicit one, or `Nothing` when it exposes nothing.
-}
formatListing : (a -> List Box) -> Listing a -> Maybe Box
formatListing format listing =
    case listing of
        ClosedListing ->
            Nothing

        OpenListing ( comments, () ) ->
            ( comments, Box.keyword ".." |> Box.line ) |> formatCommented |> parens |> Just

        ExplicitListing vars multiline ->
            case format vars of
                [] ->
                    Nothing

                vars_ ->
                    ElmStructure.group False "(" "," ")" multiline vars_ |> Just


{-| Returns the entries of an explicit exposing list: operators, then types, then values, each in name order.
-}
formatDetailedListing : DetailedListing -> List Box
formatDetailedListing listing =
    List.concat
        [ formatCommentedMap
            (\name () -> OpValue name)
            formatVarValue
            listing.operators
        , formatCommentedMap
            (\name ( inner, listing_ ) -> Union ( inner, name ) listing_)
            formatVarValue
            listing.types
        , formatCommentedMap
            (\name () -> Value name)
            formatVarValue
            listing.values
        ]


{-| Returns each entry of `values` in name order, built with `construct`, laid out with `format`, and printed with its comments.
-}
formatCommentedMap : (k -> v -> a) -> (a -> Box) -> CommentedMap k v -> List Box
formatCommentedMap construct format values =
    let
        format_ : ( k, Src.C2 v ) -> Box
        format_ ( k, ( c, v ) ) =
            formatCommented ( c, format (construct k v) )
    in
    values
        |> Map.toList
        |> List.map format_


{-| Returns one exposing-list entry. A type whose constructor listing exposes anything is printed as `Type(..)`, whatever constructors the listing names.
-}
formatVarValue : Value -> Box
formatVarValue aval =
    case aval of
        Value val ->
            formatLowercaseIdentifier [] val |> Box.line

        OpValue name ->
            ("(" ++ name ++ ")") |> Box.identifier |> Box.line

        Union name listing ->
            case
                ( formatListing
                    (formatCommentedMap
                        (\name_ () -> name_)
                        (Box.line << formatUppercaseIdentifier)
                    )
                    listing
                , Src.c1map (Box.line << formatUppercaseIdentifier) name |> formatTailCommented
                , (\( c, _ ) -> c) name
                )
            of
                ( Just _, _, _ ) ->
                    formatTailCommented <|
                        Src.c1map (\n -> Box.row [ formatUppercaseIdentifier n, Box.keyword "(..)" ] |> Box.line)
                            name

                ( Nothing, name_, _ ) ->
                    name_


{-| Returns a top-level item whose declaration is already laid out.
-}
formatTopLevelStructure : ImportInfo -> TopLevelStructure Box -> Box
formatTopLevelStructure importInfo topLevelStructure =
    case topLevelStructure of
        DocComment docs ->
            formatDocComment importInfo docs

        BodyComment c ->
            formatComment c

        Entry entry ->
            entry


{-| Returns the layout of a definition or a type annotation.
-}
formatCommonDeclaration : ImportInfo -> CommonDeclaration -> Box
formatCommonDeclaration importInfo decl =
    case decl of
        Definition name args comments expr ->
            formatDefinition importInfo name args comments expr

        TypeAnnotation name typ ->
            formatTypeAnnotation name typ


{-| Returns the layout of a top-level declaration.

A custom type puts `=` before the first constructor and `|` before each other
one, one constructor to a line. An `infix` associativity is padded to five
characters, so that `left` and `non` take as much room as `right`.

-}
formatDeclaration : ImportInfo -> Declaration -> Box
formatDeclaration importInfo decl =
    case decl of
        CommonDeclaration def ->
            formatCommonDeclaration importInfo def

        Datatype nameWithArgs tags ->
            let
                ctor : NameWithArgs Name Src.Type -> Box
                ctor (NameWithArgs tag args_) =
                    case List.map (formatPreCommented << Src.c1map (typeParens ForCtor << formatType)) args_ |> Box.allSingles of
                        Ok args__ ->
                            (formatUppercaseIdentifier tag :: args__) |> List.intersperse Box.space |> Box.row |> Box.line

                        Err [] ->
                            formatUppercaseIdentifier tag |> Box.line

                        Err args__ ->
                            Box.stack1
                                [ formatUppercaseIdentifier tag |> Box.line
                                , Box.stack1 args__
                                    |> Box.indent
                                ]
            in
            case
                Src.openCommentedListMap ctor tags |> formatOpenCommentedList
            of
                [] ->
                    crash "List can't be empty"

                first :: rest ->
                    case Src.c2map formatNameWithArgs nameWithArgs |> formatCommented of
                        Box.SingleLine nameWithArgs_ ->
                            Box.stack1
                                [ Box.line <|
                                    Box.row
                                        [ Box.keyword "type"
                                        , Box.space
                                        , nameWithArgs_
                                        ]
                                , first
                                    |> Box.prefix (Box.row [ Box.punc "=", Box.space ])
                                    |> Box.andThen (List.map (Box.prefix (Box.row [ Box.punc "|", Box.space ])) rest)
                                    |> Box.indent
                                ]

                        nameWithArgs_ ->
                            Box.stack1
                                [ Box.keyword "type" |> Box.line
                                , Box.indent nameWithArgs_
                                , first
                                    |> Box.prefix (Box.row [ Box.punc "=", Box.space ])
                                    |> Box.andThen (List.map (Box.prefix (Box.row [ Box.punc "|", Box.space ])) rest)
                                    |> Box.indent
                                ]

        TypeAlias preAlias nameWithArgs typ ->
            ElmStructure.definition "="
                True
                (Box.line <| Box.keyword "type")
                [ formatPreCommented ( preAlias, Box.keyword "alias" |> Box.line )
                , Src.c2map formatNameWithArgs nameWithArgs |> formatCommented
                ]
                (formatPreCommentedStack <| Src.c1map (typeParens NotRequired << formatType) typ)

        PortAnnotation name typeComments typ ->
            ElmStructure.definition ":"
                False
                (Box.line <| Box.keyword "port")
                [ Src.c2map (Box.line << formatLowercaseIdentifier []) name |> formatCommented ]
                (formatCommentedApostrophe typeComments <| typeParens NotRequired <| formatType typ)

        Fixity assoc precedence name value ->
            let
                formatAssoc : Binop.Associativity -> Box.Line
                formatAssoc a =
                    case a of
                        Binop.Left ->
                            Box.keyword "left "

                        Binop.Right ->
                            Box.keyword "right"

                        Binop.Non ->
                            Box.keyword "non  "
            in
            ElmStructure.spaceSepOrIndented
                (Box.keyword "infix" |> Box.line)
                [ Src.c1map (Box.line << formatAssoc) assoc |> formatPreCommented
                , Src.c1map (Box.line << Box.literal << String.fromInt) precedence |> formatPreCommented
                , Src.c2map (Box.line << formatSymbolIdentifierInParens) name |> formatCommented
                , Box.keyword "=" |> Box.line
                , Src.c1map (Box.line << Box.identifier << formatVarName) value |> formatPreCommented
                ]


{-| Returns a type's name followed by its type variables, on one line when every variable with its comments is one line, and otherwise stacked.
-}
formatNameWithArgs : NameWithArgs Name Name -> Box
formatNameWithArgs (NameWithArgs name args) =
    case List.map (formatPreCommented << Src.c1map (Box.line << formatLowercaseIdentifier [])) args |> Box.allSingles of
        Ok args_ ->
            List.intersperse Box.space (formatUppercaseIdentifier name :: args_) |> Box.row |> Box.line

        Err args_ ->
            Box.stack1 <|
                (Box.line <| formatUppercaseIdentifier name)
                    :: List.map Box.indent args_


{-| Returns `name args = expr`, with `comments` above the body.
-}
formatDefinition : ImportInfo -> Src.Pattern -> List (Src.C1 Src.Pattern) -> Src.FComments -> Src.Expr -> Box
formatDefinition importInfo (A.At _ name) args comments expr =
    let
        body : Box
        body =
            Box.stack1
                (List.concat
                    [ List.map formatComment comments
                    , [ syntaxParens SyntaxSeparated (formatExpression importInfo expr) ]
                    ]
                )
    in
    ElmStructure.definition "="
        True
        (syntaxParens SpaceSeparated (formatPattern name))
        (List.map (\( x, A.At _ y ) -> formatCommentedApostrophe x (syntaxParens SpaceSeparated (formatPattern y))) args)
        body


{-| Returns `name : type`, with each part's comments.
-}
formatTypeAnnotation : Src.C1 (Ref ()) -> Src.C1 Src.Type -> Box
formatTypeAnnotation name typ =
    ElmStructure.definition ":"
        False
        (formatTailCommented (Src.c1map (Box.line << formatVar << refMap (\() -> [])) name))
        []
        (formatPreCommented (Src.c1map (typeParens NotRequired << formatType) typ))


{-| Returns the layout of a pattern and its syntax context.

A record pattern's fields are printed in reverse of their stored order, which
is source order because the parser stores them reversed. Parentheses with no
comments inside are dropped, so the caller adds them back only where the
context needs them.

-}
formatPattern : Src.Pattern_ -> ( SyntaxContext, Box )
formatPattern apattern =
    case apattern of
        Src.PAnything name ->
            ( SyntaxSeparated, Box.line (Box.identifier ("_" ++ name)) )

        Src.PVar name ->
            ( SyntaxSeparated, Box.line (formatLowercaseIdentifier [] name) )

        Src.PRecord ( comments, [] ) ->
            ( SyntaxSeparated
            , formatUnit '{' '}' comments
            )

        Src.PRecord ( _, fields ) ->
            ( SyntaxSeparated
            , ElmStructure.group True "{" "," "}" False (List.map (formatCommented << Src.c2map (Box.line << formatLowercaseIdentifier [] << A.toValue)) (List.reverse fields))
            )

        Src.PAlias aliasPattern name ->
            ( SpaceSeparated
            , case
                ( formatTailCommented (Src.c1map (syntaxParens SpaceSeparated << formatPattern << A.toValue) aliasPattern)
                , formatPreCommented (Src.c1map (Box.line << formatLowercaseIdentifier [] << A.toValue) name)
                )
              of
                ( Box.SingleLine pattern_, Box.SingleLine name_ ) ->
                    Box.line
                        (Box.row
                            [ pattern_
                            , Box.space
                            , Box.keyword "as"
                            , Box.space
                            , name_
                            ]
                        )

                ( pattern_, name_ ) ->
                    Box.stack1
                        [ pattern_
                        , Box.line (Box.keyword "as")
                        , Box.indent name_
                        ]
            )

        Src.PUnit comments ->
            ( SyntaxSeparated, formatUnit '(' ')' comments )

        Src.PTuple a b cs ->
            let
                patterns : List (Src.C2 Src.Pattern)
                patterns =
                    a :: b :: cs
            in
            ( SyntaxSeparated
            , ElmStructure.group True "(" "," ")" False (List.map (formatCommented << Src.c2map (syntaxParens SyntaxSeparated << formatPattern << A.toValue)) patterns)
            )

        Src.PCtor _ name [] ->
            let
                ctor : List Name
                ctor =
                    [ name ]
            in
            ( SyntaxSeparated
            , Box.line (formatQualifiedUppercaseIdentifier ctor)
            )

        Src.PCtor _ name patterns ->
            let
                ctor : List Name
                ctor =
                    [ name ]
            in
            ( SpaceSeparated
            , ElmStructure.application
                (ElmStructure.FAJoinFirst ElmStructure.JoinAll)
                (Box.line (formatQualifiedUppercaseIdentifier ctor))
                (List.map (formatPreCommented << Src.c1map (syntaxParens SpaceSeparated << formatPattern << A.toValue)) patterns)
            )

        Src.PCtorQual _ home name [] ->
            let
                ctor : List String
                ctor =
                    String.split "." home ++ [ name ]
            in
            ( SyntaxSeparated
            , Box.line (formatQualifiedUppercaseIdentifier ctor)
            )

        Src.PCtorQual _ home name patterns ->
            let
                ctor : List String
                ctor =
                    String.split "." home ++ [ name ]
            in
            ( SpaceSeparated
            , ElmStructure.application
                (ElmStructure.FAJoinFirst ElmStructure.JoinAll)
                (Box.line (formatQualifiedUppercaseIdentifier ctor))
                (List.map (formatPreCommented << Src.c1map (syntaxParens SpaceSeparated << formatPattern << A.toValue)) patterns)
            )

        Src.PList ( comments, [] ) ->
            ( SyntaxSeparated
            , formatUnit '[' ']' comments
            )

        Src.PList ( _, patterns ) ->
            ( SyntaxSeparated
            , ElmStructure.group True "[" "," "]" False (List.map (formatCommented << Src.c2map (syntaxParens SyntaxSeparated << formatPattern << A.toValue)) patterns)
            )

        Src.PCons hd tl ->
            let
                go : List (Src.C2Eol Src.Pattern) -> Src.C2Eol Src.Pattern -> List (Src.C2Eol Src.Pattern)
                go acc p =
                    case p of
                        ( comments, A.At _ (Src.PCons ( _, hd_ ) tl_) ) ->
                            go (( comments, hd_ ) :: acc) tl_

                        _ ->
                            List.reverse (p :: acc)

                rest : List (Src.C2Eol Src.Pattern)
                rest =
                    go [] tl

                formatRight : Src.C2Eol Src.Pattern -> ( ( Bool, Src.FComments, Box ), Box )
                formatRight ( ( preOp, postOp, eol ), term ) =
                    ( ( False
                      , preOp
                      , Box.line (Box.punc "::")
                      )
                    , formatC2Eol
                        (Src.c2EolMap (syntaxParens SpaceSeparated << formatPattern << A.toValue)
                            ( ( postOp, [], eol ), term )
                        )
                    )
            in
            ( SpaceSeparated
            , formatBinary False
                (formatEolCommented (Src.c0EolMap (syntaxParens SpaceSeparated << formatPattern << A.toValue) hd))
                (List.map formatRight rest)
            )

        Src.PChr chr ->
            ( SyntaxSeparated, formatString SChar chr )

        Src.PStr str False ->
            ( SyntaxSeparated, formatString (SString SingleQuotedString) str )

        Src.PStr str True ->
            ( SyntaxSeparated, formatString (SString TripleQuotedString) str )

        Src.PInt _ src ->
            ( SyntaxSeparated
            , formatLiteral (IntNum src)
            )

        Src.PParens ( ( [], [] ), A.At _ pattern ) ->
            formatPattern pattern

        Src.PParens pattern ->
            ( SyntaxSeparated
            , parens (formatCommented (Src.c2map (syntaxParens SyntaxSeparated << formatPattern << A.toValue) pattern))
            )


{-| Returns a `key delim value` pair of the `where` clause of an effect module, with the comments around each side.
-}
formatRecordPair : String -> (v -> Box) -> ( Src.C2 String, Src.C2 v, Bool ) -> Box
formatRecordPair delim formatValue ( ( ( pre, postK ), k ), v, forceMultiline ) =
    ElmStructure.equalsPair delim
        forceMultiline
        (formatCommented <| Src.c2map (Box.line << formatLowercaseIdentifier []) ( ( [], postK ), k ))
        (formatCommented <| Src.c2map formatValue v)
        |> Tuple.pair pre
        |> formatPreCommented


{-| Returns a field of a record expression or type: the name, `delim` and the value, with their comments.
-}
formatPair : String -> Src.Pair Box.Line Box -> Box
formatPair delim (Src.Pair a b (Src.ForceMultiline forceMultiline)) =
    ElmStructure.equalsPair delim
        forceMultiline
        (formatTailCommented <| Src.c1map Box.line a)
        (formatPreCommented b)


{-| Returns the function that wraps a case-branch pattern in parentheses when it is a negative integer, and leaves any other pattern alone.
-}
negativeCasePatternWorkaround : Src.Pattern_ -> Box -> Box
negativeCasePatternWorkaround pattern =
    case pattern of
        Src.PInt i _ ->
            if i < 0 then
                parens

            else
                identity

        _ ->
            identity


{-| How loosely an expression or pattern binds, which is what decides whether it
needs parentheses where it is placed.

A formatter returns the context of what it built, and a caller passes the
context of the place it is putting it. `SyntaxSeparated` binds tightest: a
name, a literal, or something already delimited such as a list. `SpaceSeparated`
is a function application or a constructor with arguments; an `as` pattern and
a `::` pattern chain are also `SpaceSeparated`. `InfixSeparated` is an operator
chain. `AmbiguousEnd` is an expression that extends as far to the
right as it can, such as a lambda, `if`, `let` or `case`. `needsParensInContext`
says which combinations need parentheses.

-}
type SyntaxContext
    = SyntaxSeparated
    | InfixSeparated
    | SpaceSeparated
    | AmbiguousEnd


{-| Returns the box of an expression or pattern of context `inner`, in parentheses when it is placed where `outer` says they are needed.
-}
syntaxParens : SyntaxContext -> ( SyntaxContext, Box ) -> Box
syntaxParens outer ( inner, box ) =
    let
        parensIf : Bool -> Box -> Box
        parensIf bool =
            if bool then
                parens

            else
                identity
    in
    parensIf (needsParensInContext inner outer) box


{-| Tells whether something of context `inner` needs parentheses in a place of
context `outer`.

An application or an operator chain needs them as an argument. An operator
chain needs them as an operand of another chain. An `AmbiguousEnd` expression
needs them as an argument or an operand, and an operator chain needs them in
an `AmbiguousEnd` place.

-}
needsParensInContext : SyntaxContext -> SyntaxContext -> Bool
needsParensInContext inner outer =
    case ( inner, outer ) of
        ( SpaceSeparated, SpaceSeparated ) ->
            True

        ( InfixSeparated, SpaceSeparated ) ->
            True

        ( InfixSeparated, InfixSeparated ) ->
            True

        ( AmbiguousEnd, SpaceSeparated ) ->
            True

        ( AmbiguousEnd, InfixSeparated ) ->
            True

        ( InfixSeparated, AmbiguousEnd ) ->
            True

        _ ->
            False


{-| Returns the layout of an expression and its syntax context.

Whether a list, record, tuple, operator chain, lambda or function application
is split over several lines comes from whether its source region spanned
several lines. Parentheses with no comments inside are dropped, so the caller
adds them back only where the context needs them.

-}
formatExpression : ImportInfo -> Src.Expr -> ( SyntaxContext, Box )
formatExpression importInfo (A.At region aexpr) =
    case aexpr of
        Src.Chr char ->
            ( SyntaxSeparated, formatString SChar char )

        Src.Str string False ->
            ( SyntaxSeparated, formatString (SString SingleQuotedString) string )

        Src.Str string True ->
            ( SyntaxSeparated, formatString (SString TripleQuotedString) string )

        Src.Int _ src ->
            ( SyntaxSeparated, formatLiteral (IntNum src) )

        Src.Float _ src ->
            ( SyntaxSeparated, formatLiteral (FloatNum src) )

        Src.Var Src.LowVar name ->
            ( SyntaxSeparated, Box.line (formatVar (VarRef [] name)) )

        Src.Var Src.CapVar name ->
            ( SyntaxSeparated, Box.line (formatVar (TagRef [] name)) )

        Src.VarQual Src.LowVar prefix name ->
            ( SyntaxSeparated, Box.line (formatVar (VarRef (String.split "." prefix) name)) )

        Src.VarQual Src.CapVar prefix name ->
            ( SyntaxSeparated, Box.line (formatVar (TagRef (String.split "." prefix) name)) )

        Src.List list trailing ->
            let
                multiline : Src.ForceMultiline
                multiline =
                    Src.ForceMultiline (A.isMultiline region)
            in
            ( SyntaxSeparated
            , formatSequence '['
                ','
                (Just ']')
                multiline
                trailing
                (List.map (Src.c2EolMap (syntaxParens SyntaxSeparated << formatExpression importInfo)) list)
            )

        Src.Op op ->
            ( SyntaxSeparated
            , Box.line (formatSymbolIdentifierInParens op)
            )

        Src.Negate expr ->
            ( SyntaxSeparated
            , Box.prefix (Box.punc "-") (syntaxParens SpaceSeparated (formatExpression importInfo expr))
            )

        Src.Binops ops final ->
            let
                ( left, clauses ) =
                    List.foldr
                        (\( currExpr, ( ( preOpComments, postOpComments ), A.At _ currOp ) ) ( leftAcc, clausesAcc ) ->
                            ( currExpr, makeBinopsClause preOpComments (OpRef currOp) postOpComments leftAcc :: clausesAcc )
                        )
                        ( final, [] )
                        ops

                multiline : Bool
                multiline =
                    A.isMultiline region
            in
            ( InfixSeparated
            , formatBinops importInfo left clauses multiline
            )

        Src.Lambda ( trailingComments, srcArgs ) ( exprComments, expr ) ->
            let
                multiline : Bool
                multiline =
                    A.isMultiline region

                bodyComments : Src.FComments
                bodyComments =
                    trailingComments ++ exprComments
            in
            ( AmbiguousEnd
            , case
                ( ( multiline
                  , Box.allSingles (List.map (formatPreCommented << Src.c1map (syntaxParens SpaceSeparated << formatPattern << A.toValue)) srcArgs)
                  )
                , ( bodyComments == []
                  , syntaxParens SyntaxSeparated (formatExpression importInfo expr)
                  )
                )
              of
                ( ( False, Ok patterns_ ), ( True, Box.SingleLine expr_ ) ) ->
                    Box.line <|
                        Box.row
                            [ Box.punc "\\"
                            , List.intersperse Box.space patterns_ |> Box.row
                            , Box.space
                            , Box.punc "->"
                            , Box.space
                            , expr_
                            ]

                ( ( _, Ok patterns_ ), ( _, expr_ ) ) ->
                    Box.stack1
                        [ Box.line <|
                            Box.row
                                [ Box.punc "\\"
                                , Box.row (List.intersperse Box.space patterns_)
                                , Box.space
                                , Box.punc "->"
                                ]
                        , (List.map formatComment bodyComments
                            ++ [ expr_ ]
                          )
                            |> Box.stack1
                            |> Box.indent
                        ]

                ( ( _, Err [] ), _ ) ->
                    pleaseReport "UNEXPECTED LAMBDA" "no patterns"

                ( ( _, Err patterns_ ), ( _, expr_ ) ) ->
                    Box.stack1
                        [ Box.stack1 patterns_ |> Box.prefix (Box.punc "\\")
                        , Box.punc "->" |> Box.line
                        , (List.map formatComment bodyComments
                            ++ [ expr_ ]
                          )
                            |> Box.stack1
                            |> Box.indent
                        ]
            )

        Src.Call func [] ->
            formatExpression importInfo func

        Src.Call func ((( _, A.At (A.Region _ (A.Position firstArgEndRow _)) _ ) :: _) as args) ->
            let
                (A.Region (A.Position aexprStartRow _) _) =
                    region

                multiline : ElmStructure.FunctionApplicationMultiline
                multiline =
                    if firstArgEndRow > aexprStartRow then
                        ElmStructure.FASplitFirst

                    else
                        ElmStructure.FAJoinFirst
                            (if A.isMultiline region then
                                ElmStructure.SplitAll

                             else
                                ElmStructure.JoinAll
                            )
            in
            ( SpaceSeparated
            , ElmStructure.application
                multiline
                (syntaxParens InfixSeparated <| formatExpression importInfo func)
                (List.map (formatPreCommentedExpression importInfo SpaceSeparated) args)
            )

        Src.If ( _, if_ ) elseifs ( elsComments, els ) ->
            let
                opening : Box -> Box -> Box
                opening key cond =
                    case ( key, cond ) of
                        ( Box.SingleLine key_, Box.SingleLine cond_ ) ->
                            Box.line <|
                                Box.row
                                    [ key_
                                    , Box.space
                                    , cond_
                                    , Box.space
                                    , Box.keyword "then"
                                    ]

                        _ ->
                            Box.stack1
                                [ key
                                , Box.indent cond
                                , Box.line (Box.keyword "then")
                                ]

                formatIf : ( Src.C2 Src.Expr, Src.C2 Src.Expr ) -> Box
                formatIf ( cond, body ) =
                    Box.stack1
                        [ opening (Box.line (Box.keyword "if")) (formatCommentedExpression importInfo cond)
                        , Src.c2map (syntaxParens SyntaxSeparated << formatExpression importInfo) body |> formatCommented_ True |> Box.indent
                        ]

                formatElseIf : Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ) -> Box
                formatElseIf ( ifComments, ( cond, body ) ) =
                    let
                        key : Box
                        key =
                            case formatPreCommented ( ifComments, Box.line (Box.keyword "if") ) of
                                Box.SingleLine key_ ->
                                    Box.row [ Box.keyword "else", Box.space, key_ ] |> Box.line

                                key_ ->
                                    Box.stack1
                                        [ Box.line (Box.keyword "else")
                                        , key_
                                        ]
                    in
                    Box.stack1
                        [ Box.blankLine
                        , formatCommentedExpression importInfo cond |> opening key
                        , Src.c2map (syntaxParens SyntaxSeparated << formatExpression importInfo) body |> formatCommented_ True |> Box.indent
                        ]
            in
            ( AmbiguousEnd
            , formatIf if_
                |> Box.andThen (List.map formatElseIf elseifs)
                |> Box.andThen
                    [ Box.blankLine
                    , Box.line (Box.keyword "else")
                    , Src.c2map (syntaxParens SyntaxSeparated << formatExpression importInfo) ( ( elsComments, [] ), els ) |> formatCommented_ True |> Box.indent
                    ]
            )

        Src.Let defs bodyComments expr ->
            let
                letDeclarations : Src.C2 (A.Located Src.Def) -> List LetDeclaration
                letDeclarations ( ( preDefComments, postDefComments ), A.At _ def ) =
                    let
                        ( typeAnnotation, commonDeclaration ) =
                            case def of
                                Src.Define (A.At nameRegion name) srcArgs ( comments, body ) maybeType ->
                                    ( maybeType
                                        |> Maybe.map
                                            (\( postComments, ( ( preTypComments, postTypeComments ), typ ) ) ->
                                                LetCommonDeclaration (TypeAnnotation ( preTypComments, VarRef () name ) ( postTypeComments, typ ))
                                                    :: List.map LetComment postComments
                                            )
                                        |> Maybe.withDefault []
                                    , Definition (A.At nameRegion (Src.PVar name)) srcArgs comments body
                                    )

                                Src.Destruct pattern ( comments, body ) ->
                                    ( [], Definition pattern [] comments body )
                    in
                    List.map LetComment preDefComments
                        ++ typeAnnotation
                        ++ LetCommonDeclaration commonDeclaration
                        :: List.map LetComment postDefComments

                spacer : LetDeclaration -> LetDeclaration -> List Box
                spacer first _ =
                    case first of
                        LetCommonDeclaration (Definition _ _ _ _) ->
                            [ Box.blankLine ]

                        _ ->
                            []

                formatDefinition_ : LetDeclaration -> Box
                formatDefinition_ def =
                    case def of
                        LetCommonDeclaration (Definition name args comments expr_) ->
                            formatDefinition importInfo name args comments expr_

                        LetCommonDeclaration (TypeAnnotation name typ) ->
                            formatTypeAnnotation name typ

                        LetComment comment ->
                            formatComment comment
            in
            ( AmbiguousEnd
            , Box.line (Box.keyword "let")
                |> Box.andThen
                    (defs
                        |> List.concatMap letDeclarations
                        |> intersperseMap spacer formatDefinition_
                        |> List.map Box.indent
                    )
                |> Box.andThen
                    [ Box.line (Box.keyword "in")
                    , Box.stack1 <|
                        List.map formatComment bodyComments
                            ++ [ formatExpression importInfo expr |> syntaxParens SyntaxSeparated ]
                    ]
            )

        Src.Case (( _, A.At subjectRegion _ ) as subject) clauses ->
            let
                opening : Box
                opening =
                    case
                        ( A.isMultiline subjectRegion
                        , formatCommentedExpression importInfo subject
                        )
                    of
                        ( False, Box.SingleLine subject_ ) ->
                            Box.line <|
                                Box.row
                                    [ Box.keyword "case"
                                    , Box.space
                                    , subject_
                                    , Box.space
                                    , Box.keyword "of"
                                    ]

                        ( _, subject_ ) ->
                            Box.stack1
                                [ Box.keyword "case" |> Box.line
                                , Box.indent subject_
                                , Box.keyword "of" |> Box.line
                                ]

                clause : ( Src.C2 Src.Pattern, Src.C1 Src.Expr ) -> Box
                clause ( ( ( prePat, postPat ), A.At _ pat ), ( preExpr, expr ) ) =
                    case
                        ( ( postPat
                          , formatPattern pat
                                |> syntaxParens SyntaxSeparated
                                |> negativeCasePatternWorkaround pat
                          )
                        , ( formatCommentedStack (Src.c2map (syntaxParens SyntaxSeparated << formatPattern) ( ( prePat, postPat ), pat ))
                                |> negativeCasePatternWorkaround pat
                          , Src.c1map (syntaxParens SyntaxSeparated << formatExpression importInfo) ( preExpr, expr ) |> formatPreCommentedStack
                          )
                        )
                    of
                        ( _, ( Box.SingleLine pat_, body_ ) ) ->
                            Box.stack1
                                [ Box.line (Box.row [ pat_, Box.space, Box.keyword "->" ])
                                , Box.indent body_
                                ]

                        ( ( [], Box.SingleLine pat_ ), ( _, body_ ) ) ->
                            Box.stack1
                                (List.map formatComment prePat
                                    ++ [ Box.line (Box.row [ pat_, Box.space, Box.keyword "->" ])
                                       , Box.indent body_
                                       ]
                                )

                        ( _, ( pat_, body_ ) ) ->
                            Box.stack1
                                [ pat_
                                , Box.line (Box.keyword "->")
                                , Box.indent body_
                                ]
            in
            ( AmbiguousEnd
            , opening
                |> Box.andThen
                    (clauses
                        |> List.map clause
                        |> List.intersperse Box.blankLine
                        |> List.map Box.indent
                    )
            )

        Src.Accessor field ->
            ( SyntaxSeparated
            , Box.line (Box.identifier ("." ++ formatVarName field))
            )

        Src.Access record (A.At _ field) ->
            ( SyntaxSeparated
            , formatExpression importInfo record
                |> syntaxParens SpaceSeparated
                |> Box.addSuffix (Box.row [ Box.punc ".", formatLowercaseIdentifier [] field ])
            )

        Src.Update name ( trailing, fields ) ->
            let
                multiline : Src.ForceMultiline
                multiline =
                    Src.ForceMultiline (A.isMultiline region)

                fields_ : List (Src.C2Eol (Src.Pair Name Src.Expr))
                fields_ =
                    List.map
                        (Src.c2EolMap
                            (\( ( nameComments, A.At _ name_ ), ( _, A.At exprRegion _ ) as expr ) ->
                                Src.Pair ( nameComments, name_ ) expr (Src.ForceMultiline (A.isMultiline exprRegion))
                            )
                        )
                        fields
            in
            ( SyntaxSeparated
            , formatRecordLike
                (Just (Src.c2map (syntaxParens SyntaxSeparated << formatExpression importInfo) name))
                (List.map (Src.c2EolMap (formatPair "=" << Src.mapPair (formatLowercaseIdentifier []) (syntaxParens SyntaxSeparated << formatExpression importInfo))) fields_)
                trailing
                multiline
            )

        Src.Record ( trailing, fields ) ->
            let
                multiline : Src.ForceMultiline
                multiline =
                    Src.ForceMultiline (A.isMultiline region)

                fields_ : List (Src.C2Eol (Src.Pair Name Src.Expr))
                fields_ =
                    List.map
                        (Src.c2EolMap
                            (\( ( nameComments, A.At nameRegion name_ ), ( _, A.At exprRegion _ ) as expr ) ->
                                Src.Pair ( nameComments, name_ ) expr (Src.ForceMultiline (A.isMultiline (A.mergeRegions nameRegion exprRegion)))
                            )
                        )
                        fields
            in
            ( SyntaxSeparated
            , formatRecordLike Nothing
                (List.map (Src.c2EolMap (formatPair "=" << Src.mapPair (formatLowercaseIdentifier []) (syntaxParens SyntaxSeparated << formatExpression importInfo))) fields_)
                trailing
                multiline
            )

        Src.Unit ->
            ( SyntaxSeparated
            , formatUnit '(' ')' []
            )

        Src.Tuple a b cs ->
            let
                multiline : Bool
                multiline =
                    A.isMultiline region

                exprs : List (Src.C2 Src.Expr)
                exprs =
                    a :: b :: cs
            in
            ( SyntaxSeparated
            , List.map (formatCommentedExpression importInfo) exprs |> ElmStructure.group True "(" "," ")" multiline
            )

        Src.Shader (Shader.Source src) _ ->
            ( SyntaxSeparated
            , Box.line <|
                Box.row
                    [ Box.punc "[glsl|"
                    , Box.literal (Shader.unescape src)
                    , Box.punc "|]"
                    ]
            )

        Src.Parens expr ->
            case expr of
                ( ( [], [] ), expr_ ) ->
                    formatExpression importInfo expr_

                _ ->
                    ( SyntaxSeparated
                    , formatCommentedExpression importInfo expr
                        |> parens
                    )


{-| One item of a `let` block: a definition or annotation, or a comment between them.
-}
type LetDeclaration
    = LetCommonDeclaration CommonDeclaration
    | LetComment Src.FComment


{-| Returns an expression with the comments before and after it.
-}
formatCommentedExpression : ImportInfo -> Src.C2 Src.Expr -> Box
formatCommentedExpression importInfo ( ( pre, post ), e ) =
    let
        commented_ : Src.C2 Src.Expr
        commented_ =
            ( ( pre, post ), e )
    in
    Src.c2map (syntaxParens SyntaxSeparated << formatExpression importInfo) commented_ |> formatCommented


{-| Returns an expression with the comments before it, in parentheses when its context requires them in a place of `context`.
-}
formatPreCommentedExpression : ImportInfo -> SyntaxContext -> Src.C1 Src.Expr -> Box
formatPreCommentedExpression importInfo context ( pre, e ) =
    let
        ( pre_, e_ ) =
            ( pre, e )
    in
    formatCommentedApostrophe pre_ (syntaxParens context <| formatExpression importInfo e_)


{-| Returns a record expression or type: `{ base | fields }` when there is a base record, and `{ fields }` otherwise, with `trailing` comments before the closing brace.
-}
formatRecordLike : Maybe (Src.C2 Box) -> List (Src.C2Eol Box) -> Src.FComments -> Src.ForceMultiline -> Box
formatRecordLike base_ fields trailing multiline =
    case ( base_, fields ) of
        ( Just base, pairs_ ) ->
            ElmStructure.extensionGroup_
                ((\(Src.ForceMultiline b) -> b) multiline)
                (formatCommented base)
                (formatSequence '|'
                    ','
                    Nothing
                    multiline
                    trailing
                    pairs_
                )

        ( Nothing, pairs_ ) ->
            formatSequence '{'
                ','
                (Just '}')
                multiline
                trailing
                pairs_


{-| Returns a delimited sequence: `left` before the first item, `delim` before each
other one, `trailing` comments after the last, and `maybeRight` to close it.

On one line when `multiline` is `False` and every part is one line, and
otherwise one item to a line. Comments before an item go on lines of their own
above it. With no items the result is `left` and the closing character (a space
when `maybeRight` is `Nothing`) with the comments between them.

-}
formatSequence : Char -> Char -> Maybe Char -> Src.ForceMultiline -> Src.FComments -> List (Src.C2Eol Box) -> Box
formatSequence left delim maybeRight (Src.ForceMultiline multiline) trailing list =
    case ( maybeRight, list ) of
        ( _, first :: rest ) ->
            let
                formatItem : Char -> Src.C2Eol Box -> Box
                formatItem delim_ ( ( pre, post, eol ), item ) =
                    formatC2Eol ( ( post, [], eol ), item ) |> Box.prefix (Box.row [ Box.punc (String.fromChar delim_), Box.space ]) |> Maybe.unwrap identity (Box.stack_ << Box.stack_ Box.blankLine) (formatComments pre)
            in
            ElmStructure.forceableSpaceSepOrStack multiline
                (ElmStructure.forceableRowOrStack multiline
                    (formatItem left first)
                    (List.map (formatItem delim) rest)
                )
                (Maybe.unwrap [] (flip (::) [] << Box.stack_ Box.blankLine) (formatComments trailing) ++ Maybe.toList (Maybe.map (Box.line << Box.punc << String.fromChar) maybeRight))

        ( Just right, [] ) ->
            formatUnit left right trailing

        ( Nothing, [] ) ->
            formatUnit left ' ' trailing


{-| Applies `f` to every element of `l`, telling it whether the element is the last.
-}
mapIsLast : (Bool -> a -> b) -> List a -> List b
mapIsLast f l =
    case l of
        [] ->
            []

        [ last_ ] ->
            [ f True last_ ]

        next :: rest ->
            f False next :: mapIsLast f rest


{-| One operator of an operator chain with the operand to its right, as `BinopsClauseProps` describes.
-}
type BinopsClause varRef expr
    = BinopsClause (BinopsClauseProps varRef expr)


{-| The parts of a `BinopsClause`: the comments before the operator, the operator, the comments after it, and the operand.
-}
type alias BinopsClauseProps varRef expr =
    { preOpComments : Src.FComments
    , op : varRef
    , postOpComments : Src.FComments
    , expr : expr
    }


{-| Builds a `BinopsClause` from its parts.
-}
makeBinopsClause : Src.FComments -> varRef -> Src.FComments -> expr -> BinopsClause varRef expr
makeBinopsClause preOpComments op postOpComments expr =
    BinopsClause { preOpComments = preOpComments, op = op, postOpComments = postOpComments, expr = expr }


{-| Returns the operator chain that starts with `left` and continues with each of
`ops`.

Every operand is parenthesised as an operand of an operator chain, except the
last operand of a final `<|`, which may be a lambda or another expression that
extends to the right without parentheses.

-}
formatBinops : ImportInfo -> Src.Expr -> List (BinopsClause (Ref (List String)) Src.Expr) -> Bool -> Box
formatBinops importInfo left ops multiline =
    let
        formatPair_ : Bool -> BinopsClause (Ref (List String)) Src.Expr -> ( ( Bool, Src.FComments, Box ), Box )
        formatPair_ isLast (BinopsClause props) =
            let
                isLeftPipe : Bool
                isLeftPipe =
                    props.op == OpRef "<|"

                formatContext : SyntaxContext
                formatContext =
                    if isLeftPipe && isLast then
                        AmbiguousEnd

                    else
                        InfixSeparated
            in
            ( ( isLeftPipe
              , props.preOpComments
              , (formatInfixVar >> Box.line) props.op
              )
            , formatExpression importInfo props.expr |> syntaxParens formatContext |> formatCommentedApostrophe props.postOpComments
            )
    in
    formatBinary
        multiline
        (syntaxParens InfixSeparated <| formatExpression importInfo left)
        (mapIsLast formatPair_ ops)


{-| Returns `left` and `right` with `comments` between them, as an empty record,
list or unit.

With no comments this is the two characters together. A `{` whose first comment
is a `--` comment puts the comments on lines of their own.

-}
formatUnit : Char -> Char -> Src.FComments -> Box
formatUnit left right comments =
    case ( left, comments ) of
        ( _, [] ) ->
            Box.punc (String.fromList [ left, right ]) |> Box.line

        ( '{', (Src.LineComment _) :: _ ) ->
            List.map formatComment comments |> Box.stack1 |> Box.prefix Box.space |> surround left right

        _ ->
            surround left right <|
                case List.map formatComment comments |> Box.allSingles of
                    Ok comments_ ->
                        List.intersperse Box.space comments_ |> Box.row |> Box.line

                    Err comments_ ->
                        Box.stack1 comments_


{-| Returns the comments on one line when each is one line, stacked otherwise, or `Nothing` when there are none.
-}
formatComments : Src.FComments -> Maybe Box
formatComments comments =
    case List.map formatComment comments of
        [] ->
            Nothing

        first :: rest ->
            Just (ElmStructure.spaceSepOrStack first rest)


{-| Returns `inner` between the comments before and after it, on one line unless `forceMultiline` is `True` or a part is not a single line.
-}
formatCommented_ : Bool -> Src.C2 Box -> Box
formatCommented_ forceMultiline ( ( pre, post ), inner ) =
    ElmStructure.forceableSpaceSepOrStack1 forceMultiline <|
        List.concat
            [ Maybe.toList (formatComments pre)
            , [ inner ]
            , Maybe.toList (formatComments post)
            ]


{-| Returns a box between the comments before and after it, on one line when every part is one line.
-}
formatCommented : Src.C2 Box -> Box
formatCommented =
    formatCommented_ False


{-| Returns a box after the comments before it.
-}
formatPreCommented : Src.C1 Box -> Box
formatPreCommented ( pre, inner ) =
    formatCommentedApostrophe pre inner


{-| Returns `inner` after the comments `pre`.
-}
formatCommentedApostrophe : Src.FComments -> Box -> Box
formatCommentedApostrophe pre inner =
    formatCommented ( ( pre, [] ), inner )


{-| Returns a box followed by the comments after it.
-}
formatTailCommented : Src.C1 Box -> Box
formatTailCommented ( post, inner ) =
    formatCommented ( ( [], post ), inner )


{-| Returns a box between the comments before and after it, followed by its end-of-line comment if it has one.
-}
formatC2Eol : Src.C2Eol Box -> Box
formatC2Eol ( ( pre, post, eol ), a ) =
    formatCommented ( ( pre, post ), formatEolCommented ( eol, a ) )


{-| Returns `inner` followed by the end-of-line comment `post`: on the same line, after which the line must break, when `inner` is one line, and on a line of its own otherwise.
-}
formatEolCommented : ( Maybe String, Box ) -> Box
formatEolCommented ( post, inner ) =
    case ( post, inner ) of
        ( Nothing, box ) ->
            box

        ( Just eol, Box.SingleLine result ) ->
            Box.row [ result, Box.space, Box.punc "--", Box.literal eol ] |> Box.mustBreak

        ( Just eol, box ) ->
            Box.stack1 [ box, Src.LineComment eol |> formatComment ]


{-| Returns a box with each comment before and after it on a line of its own.
-}
formatCommentedStack : Src.C2 Box -> Box
formatCommentedStack ( ( pre, post ), inner ) =
    Box.stack1 <|
        List.map formatComment pre
            ++ inner
            :: List.map formatComment post


{-| Returns a box with each comment before it on a line of its own.
-}
formatPreCommentedStack : Src.C1 Box -> Box
formatPreCommentedStack ( pre, inner ) =
    formatCommentedStack ( ( pre, [] ), inner )


{-| Returns `word` between its comments, followed by `value` on the same line or indented below.
-}
formatKeywordCommented : String -> Src.C2 Box -> Box
formatKeywordCommented word ( ( pre, post ), value ) =
    ElmStructure.spaceSepOrIndented
        (formatCommented ( ( pre, post ), Box.line (Box.keyword word) ))
        [ value ]


{-| Returns every element of the list with its comments, the last included.
-}
formatOpenCommentedList : Src.OpenCommentedList Box -> List Box
formatOpenCommentedList (Src.OpenCommentedList rest ( preLst, eol, lst )) =
    List.map formatC2Eol rest
        ++ [ formatC2Eol ( ( preLst, [], eol ), lst ) ]


{-| Returns a comment as it is written in source.

A block comment of one line is trimmed and printed with a space inside each
delimiter. A `--` comment and the three comment-trick forms end their line.

-}
formatComment : Src.FComment -> Box
formatComment comment =
    case comment of
        Src.BlockComment c ->
            case c of
                [] ->
                    Box.punc "{- -}" |> Box.line

                [ l ] ->
                    Box.line <|
                        Box.row
                            [ Box.punc "{-"
                            , Box.space
                            , Box.literal (String.trim l)
                            , Box.space
                            , Box.punc "-}"
                            ]

                ls ->
                    Box.stack1
                        [ Box.prefix
                            (Box.row [ Box.punc "{-", Box.space ])
                            (Box.stack1 <| List.map (Box.line << Box.literal) ls)
                        , Box.punc "-}" |> Box.line
                        ]

        Src.LineComment c ->
            Box.row [ Box.punc "--", Box.literal c ] |> Box.mustBreak

        Src.CommentTrickOpener ->
            Box.punc "{--}" |> Box.mustBreak

        Src.CommentTrickCloser ->
            Box.punc "--}" |> Box.mustBreak

        Src.CommentTrickBlock c ->
            Box.row [ Box.punc "{--", Box.literal c, Box.punc "-}" ] |> Box.mustBreak


{-| Whether a string literal is written with `"` or with `"""`.
-}
type StringRepresentation
    = SingleQuotedString
    | TripleQuotedString


{-| A number literal, holding its spelling in the source.
-}
type LiteralValue
    = IntNum String
    | FloatNum String


{-| Returns a number literal as it was written, except that the digits of a hexadecimal integer are made upper-case.
-}
formatLiteral : LiteralValue -> Box
formatLiteral lit =
    case lit of
        IntNum i ->
            let
                number : String
                number =
                    if String.startsWith "0x" i then
                        "0x" ++ String.toUpper (String.dropLeft 2 i)

                    else
                        i
            in
            Box.line (Box.literal number)

        FloatNum f ->
            Box.line (Box.literal f)


{-| The kind of text literal being printed: a character, or a string written with `"` or `"""`.
-}
type StringStyle
    = SChar
    | SString StringRepresentation


{-| Tells whether a character is printed as itself in a literal; only U+2028 and U+2029 are not.
-}
charIsPrint : Char -> Bool
charIsPrint c =
    case c of
        '\u{2028}' ->
            False

        '\u{2029}' ->
            False

        _ ->
            True


{-| Returns a character or string literal, from its escaped text `s`.

Escapes the delimiter makes unnecessary are removed: `\"` in a character and in
a `"""` string, `\'` in a string, and `\n` in a `"""` string, which becomes a
real line break. A tab becomes `\t`, and U+2028 and U+2029 become `\u{...}`
escapes. In a `"""` string, every quote of a run of three or more, and every
quote at the very end, is escaped.

-}
formatString : StringStyle -> String -> Box
formatString style s =
    let
        stringBox : String -> (String -> String) -> Box
        stringBox quotes escaper =
            Box.line <|
                Box.row
                    [ Box.punc quotes
                    , escaper fixedString |> Box.literal
                    , Box.punc quotes
                    ]

        styleBasedFix : String -> String
        styleBasedFix =
            case style of
                SChar ->
                    String.replace "\\\"" "\""
                        >> String.replace "\t" "\\t"

                SString TripleQuotedString ->
                    String.replace "\\n" "\n"
                        >> String.replace "\\\"" "\""
                        >> String.replace "\\'" "'"
                        >> String.replace "\t" "\\t"

                SString SingleQuotedString ->
                    String.replace "\\'" "'"

        fixedString : String
        fixedString =
            s
                |> styleBasedFix
                |> String.replace "\t" "\\t"
                |> String.toList
                |> List.map
                    (\c ->
                        if not (charIsPrint c) then
                            hex c

                        else
                            String.fromChar c
                    )
                |> String.concat

        hex : Char -> String
        hex char =
            "\\u{" ++ String.padLeft 4 '0' (Hex.toString (Char.toCode char)) ++ "}"
    in
    case style of
        SChar ->
            stringBox "'" identity

        SString SingleQuotedString ->
            stringBox "\"" identity

        SString TripleQuotedString ->
            let
                escapeMultiQuote : String -> String
                escapeMultiQuote =
                    let
                        step : String -> Int -> String -> String
                        step okay quotes remaining =
                            case String.toList remaining of
                                [] ->
                                    String.reverse (String.repeat quotes "\"\\" ++ okay)

                                next :: rest ->
                                    if next == '"' then
                                        step okay (quotes + 1) (String.fromList rest)

                                    else if quotes >= 3 then
                                        step (String.cons next (String.repeat quotes "\"\\") ++ okay) 0 (String.fromList rest)

                                    else if quotes > 0 then
                                        step (String.cons next (String.fromList (List.repeat quotes '"') ++ okay)) 0 (String.fromList rest)

                                    else
                                        step (String.cons next okay) 0 (String.fromList rest)
                    in
                    step "" 0
            in
            stringBox "\"\"\"" escapeMultiQuote


{-| The kind of place a type is put, which decides whether it needs parentheses
there.

The constructors are ordered from the most permissive place to the least.
`NotRequired` is a place where any type may stand, such as the right of a
`:`. `ForLambda` is a part of a function-arrow chain. `ForCtor` is an argument of a
type constructor.

-}
type TypeParensRequired
    = NotRequired
    | ForLambda
    | ForCtor


{-| What kind of type a type formatter produced, as far as parentheses are
concerned.

`ForFunctionType` is a function type and `ForTypeConstruction` a type
constructor applied to arguments. `NotNeeded` is anything that never needs
parentheses.

-}
type TypeParensInner
    = NotNeeded
    | ForFunctionType
    | ForTypeConstruction


{-| Returns the box of a type of kind `inner`, in parentheses when `outer` requires them.
-}
typeParens : TypeParensRequired -> ( TypeParensInner, Box ) -> Box
typeParens outer ( inner, box ) =
    if typeParensNeeded outer inner then
        parens box

    else
        box


{-| Tells whether a type of the given kind needs parentheses in a place of kind `outer`: a function type does on the left of an arrow and as an argument, and an applied type constructor does as an argument.
-}
typeParensNeeded : TypeParensRequired -> TypeParensInner -> Bool
typeParensNeeded outer typeParensInner =
    case typeParensInner of
        NotNeeded ->
            False

        ForTypeConstruction ->
            outer == ForCtor

        ForFunctionType ->
            outer == ForLambda || outer == ForCtor


{-| Returns a possibly qualified type name, given with its dots.
-}
formatTypeConstructor : String -> Box
formatTypeConstructor name =
    formatQualifiedUppercaseIdentifier (String.split "." name) |> Box.line


{-| Returns the layout of a type and the kind of type it is.

Function arrows are flattened into one chain. A function type, an applied type
constructor, a record or a tuple is split over several lines when its source
region spanned several lines.

-}
formatType : Src.Type -> ( TypeParensInner, Box )
formatType (A.At region atype) =
    case atype of
        Src.TLambda first result ->
            let
                rest : List (Src.C2Eol Src.Type)
                rest =
                    let
                        go : Src.C2Eol Src.Type -> List (Src.C2Eol Src.Type) -> List (Src.C2Eol Src.Type)
                        go ( comments, type_ ) acc =
                            case type_ of
                                A.At _ (Src.TLambda ( _, subFirst ) subRest) ->
                                    go subRest (( comments, subFirst ) :: acc)

                                _ ->
                                    List.reverse (( comments, type_ ) :: acc)
                    in
                    go result []

                forceMultiline : Bool
                forceMultiline =
                    A.isMultiline region

                formatRight : Src.C2Eol Src.Type -> Box
                formatRight ( ( preOp, postOp, eol ), term ) =
                    ElmStructure.forceableSpaceSepOrStack1 False <|
                        ((Maybe.toList <| formatComments preOp)
                            ++ [ ElmStructure.prefixOrIndented
                                    (Box.line <| Box.punc "->")
                                    (formatC2Eol <|
                                        (Src.c2EolMap <| typeParens ForLambda << formatType)
                                            ( ( postOp, [], eol ), term )
                                    )
                               ]
                        )
            in
            ( ForFunctionType
            , ElmStructure.forceableSpaceSepOrStack
                forceMultiline
                (formatEolCommented (Src.c0EolMap (typeParens ForLambda << formatType) first))
                (List.map formatRight rest)
            )

        Src.TVar name ->
            ( NotNeeded
            , formatVarName name |> Box.identifier |> Box.line
            )

        Src.TType _ ctor args ->
            let
                forceMultiline : Src.ForceMultiline
                forceMultiline =
                    Src.ForceMultiline (A.isMultiline region)

                join : ElmStructure.FunctionApplicationMultiline
                join =
                    case forceMultiline of
                        Src.ForceMultiline True ->
                            ElmStructure.FASplitFirst

                        Src.ForceMultiline False ->
                            ElmStructure.FAJoinFirst ElmStructure.JoinAll
            in
            ( if List.isEmpty args then
                NotNeeded

              else
                ForTypeConstruction
            , ElmStructure.application
                join
                (formatTypeConstructor ctor)
                (List.map (formatPreCommented << Src.c1map (typeParens ForCtor << formatType)) args)
            )

        Src.TTypeQual _ home name args ->
            let
                forceMultiline : Src.ForceMultiline
                forceMultiline =
                    Src.ForceMultiline (A.isMultiline region)

                join : ElmStructure.FunctionApplicationMultiline
                join =
                    case forceMultiline of
                        Src.ForceMultiline True ->
                            ElmStructure.FASplitFirst

                        Src.ForceMultiline False ->
                            ElmStructure.FAJoinFirst ElmStructure.JoinAll
            in
            ( if List.isEmpty args then
                NotNeeded

              else
                ForTypeConstruction
            , ElmStructure.application
                join
                (formatTypeConstructor (home ++ "." ++ name))
                (List.map (formatPreCommented << Src.c1map (typeParens ForCtor << formatType)) args)
            )

        Src.TRecord fields ext trailing ->
            let
                base : Maybe (Src.C2 Name)
                base =
                    Maybe.map (Src.c2map A.toValue) ext

                fields_ : List (Src.C2Eol (Src.Pair Name Src.Type))
                fields_ =
                    List.map
                        (\( ( preFieldComments, postFieldComments ), ( ( postNameComments, A.At _ name ), ( preTypeComments, typ ) ) ) ->
                            ( ( preFieldComments, postFieldComments, Nothing )
                            , Src.Pair ( postNameComments, name ) ( preTypeComments, typ ) (Src.ForceMultiline False)
                            )
                        )
                        fields

                multiline : Src.ForceMultiline
                multiline =
                    Src.ForceMultiline (A.isMultiline region)
            in
            ( NotNeeded
            , formatRecordLike
                (Maybe.map (Src.c2map (Box.line << formatLowercaseIdentifier [])) base)
                (List.map (Src.c2EolMap (formatPair ":" << Src.mapPair (formatLowercaseIdentifier []) (typeParens NotRequired << formatType))) fields_)
                trailing
                multiline
            )

        Src.TUnit ->
            ( NotNeeded
            , formatUnit '(' ')' []
            )

        Src.TTuple a b cs ->
            let
                types : List (Src.C2Eol Src.Type)
                types =
                    a :: b :: cs

                forceMultiline : Bool
                forceMultiline =
                    A.isMultiline region
            in
            ( NotNeeded
            , ElmStructure.group True "(" "," ")" forceMultiline (List.map (formatC2Eol << Src.c2EolMap (typeParens NotRequired << formatType)) types)
            )

        Src.TParens type_ ->
            ( NotNeeded
            , Src.c2map (typeParens NotRequired << formatType) type_ |> formatCommented |> parens
            )


{-| Returns a reference to a value, constructor or operator, with its qualifier.
-}
formatVar : Ref (List String) -> Box.Line
formatVar var =
    case var of
        VarRef namespace name ->
            formatLowercaseIdentifier namespace name

        TagRef namespace name ->
            case namespace of
                [] ->
                    Box.identifier (formatVarName name)

                _ ->
                    Box.row
                        [ formatQualifiedUppercaseIdentifier namespace
                        , Box.punc "."
                        , Box.identifier (formatVarName name)
                        ]

        OpRef name ->
            formatSymbolIdentifierInParens name


{-| Returns an operator in parentheses, as it is written when used as a value.
-}
formatSymbolIdentifierInParens : String -> Box.Line
formatSymbolIdentifierInParens name =
    ("(" ++ name ++ ")") |> Box.identifier


{-| Returns a reference written in infix position: an operator as it is, and any other name between backticks.
-}
formatInfixVar : Ref (List String) -> Box.Line
formatInfixVar var =
    case var of
        VarRef _ _ ->
            Box.row
                [ Box.punc "`"
                , formatVar var
                , Box.punc "`"
                ]

        TagRef _ _ ->
            Box.row
                [ Box.punc "`"
                , formatVar var
                , Box.punc "`"
                ]

        OpRef name ->
            Box.identifier name


{-| Returns a lower-case name, qualified by `namespace` when that is not empty.
-}
formatLowercaseIdentifier : List String -> String -> Box.Line
formatLowercaseIdentifier namespace name =
    case ( namespace, name ) of
        ( [], _ ) ->
            Box.identifier (formatVarName name)

        _ ->
            Box.row
                [ formatQualifiedUppercaseIdentifier namespace
                , Box.punc "."
                , Box.identifier (formatVarName name)
                ]


{-| Returns a capitalised name.
-}
formatUppercaseIdentifier : String -> Box.Line
formatUppercaseIdentifier name =
    Box.identifier (formatVarName name)


{-| Returns a module path or qualified name, its parts joined with dots.
-}
formatQualifiedUppercaseIdentifier : List String -> Box.Line
formatQualifiedUppercaseIdentifier names =
    List.map formatVarName names |> String.join "." |> Box.identifier


{-| Returns `name` with every `'` replaced by `_`.
-}
formatVarName : String -> String
formatVarName name =
    String.map
        (\x ->
            if x == '\'' then
                '_'

            else
                x
        )
        name
