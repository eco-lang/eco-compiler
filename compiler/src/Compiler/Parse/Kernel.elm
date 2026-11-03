module Compiler.Parse.Kernel exposing (fromByteString)

{-| A kernel module is a JavaScript file that implements part of an Elm package
by hand, and the JavaScript back end has to rename things inside it as it emits
it. This module parses such a file into the pieces that need renaming and the
plain text between them.

A kernel file opens with a `/* ... */` comment holding Elm `import` lines. Each
import names either an Elm module or another kernel module (one whose name starts
with `Elm.Kernel.` or `Eco.Kernel.`), and its `exposing` list names the values the
file refers to. In the body, a value is referred to by a _kernel tag_: two
underscores followed by a name. The tag `__List_map`, given
`import List exposing (map)`, is the Elm function `List.map`. For an Elm module
the part before the underscore is its alias or, without one, its name; for a
kernel module it is the name after `Elm.Kernel.` or `Eco.Kernel.`, so
`import Elm.Kernel.Utils exposing (eq)` gives `__Utils_eq`.

The body is split at every kernel tag into a list of _chunks_. The character
after the two underscores decides what a tag is: `$` makes an Elm record field,
a digit an enumeration value, a lower case letter a JavaScript field, and
`__DEBUG` and `__PROD` are mode markers. Any other tag must be one of the names
the header imports, and is otherwise an error.

The parsed form, `Content` and its `Chunk`s, is defined in
`Compiler.IR.Kernel.Chunk`.


# Parsing

@docs fromByteString

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.IR.Kernel.Chunk exposing (Chunk(..), Content(..), Foreigns)
import Compiler.IR.Source as Src
import Compiler.Lexer.Identifier as Identifier
import Compiler.Lexer.Primitives as P exposing (Col, Row)
import Compiler.Parse.Module as Module
import Compiler.Parse.Space as Space
import Dict exposing (Dict)
import System.Crash exposing (crash)



-- ====== FROM FILE ======


{-| Parses the text of a kernel file belonging to package `pkg`.

The file must open with `/*`, then the header's import lines, each on a line of
its own, then `*/`. It returns `Nothing` if the header does not parse, or if the
body has a kernel tag that is in no category and was not imported. Some headers
that parse are rejected by crashing instead: an `as` on a kernel import, a dotted
Elm module imported without `as`, `exposing (..)`, `Type(..)`, or an operator in
an `exposing` list.

-}
fromByteString : Pkg.Name -> Foreigns -> String -> Maybe Content
fromByteString pkg foreigns bytes =
    case P.fromByteString (parser pkg foreigns) toError bytes of
        Ok content ->
            Just content

        Err () ->
            Nothing


{-| Produces the parser for a whole kernel file of package `pkg`, as
`fromByteString` describes.
-}
parser : Pkg.Name -> Foreigns -> P.Parser () Content
parser pkg foreigns =
    P.word2 '/' '*' toError
        |> P.andThen (\_ -> Space.chomp ignoreError)
        |> P.andThen (\_ -> Space.checkFreshLine toError)
        |> P.andThen (\_ -> P.specialize ignoreError (Module.chompImports []))
        |> P.andThen
            (\imports ->
                P.word2 '*' '/' toError
                    |> P.andThen (\_ -> parseChunks (toVarTable pkg foreigns imports) Dict.empty Dict.empty)
                    |> P.map (\chunks -> Content imports chunks)
            )


{-| Returns the parse error, which carries nothing, whatever the position.
-}
toError : Row -> Col -> ()
toError _ _ =
    ()


{-| Returns the parse error, which carries nothing, discarding the error of a
sub-parser and its position.
-}
ignoreError : a -> Row -> Col -> ()
ignoreError _ _ _ =
    ()



-- ====== PARSE CHUNKS ======


{-| Produces a parser that reads the rest of the input as kernel file body, resolving
imported tags with `vtable`. It fails unless every tag in the body is understood.
-}
parseChunks : VarTable -> Enums -> Fields -> P.Parser () (List Chunk)
parseChunks vtable enums fields =
    P.Parser
        (\(P.State st) ->
            let
                ( ( chunks, newPos ), ( newRow, newCol ) ) =
                    chompChunks vtable enums fields st.src st.pos st.end st.row st.col st.pos []
            in
            if newPos == st.end then
                P.Cok chunks (P.State { st | pos = newPos, row = newRow, col = newCol })

            else
                P.Cerr st.row st.col toError
        )


{-| Returns the chunks of `src` from `pos` to `end`, with the position, row and column
reached.

`lastPos` is where the current run of plain JavaScript started, and `revChunks`
holds the chunks already found, most recent first. The returned position is
`end` on success; any smaller position means a tag could not be resolved.

-}
chompChunks : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> Int -> List Chunk -> ( ( List Chunk, Int ), ( Row, Col ) )
chompChunks vs es fs src pos end row col lastPos revChunks =
    if pos >= end then
        let
            js : String
            js =
                toByteString src lastPos end
        in
        ( ( List.reverse (JS js :: revChunks), pos ), ( row, col ) )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '_' then
            let
                pos1 : Int
                pos1 =
                    pos + 1

                pos3 : Int
                pos3 =
                    pos + 3
            in
            if pos3 <= end && P.unsafeIndex src pos1 == '_' then
                let
                    js : String
                    js =
                        toByteString src lastPos pos
                in
                chompTag vs es fs src pos3 end row (col + 3) (JS js :: revChunks)

            else
                chompChunks vs es fs src pos1 end row (col + 1) lastPos revChunks

        else if word == '\n' then
            chompChunks vs es fs src (pos + 1) end (row + 1) 1 lastPos revChunks

        else
            let
                newPos : Int
                newPos =
                    pos + P.charWidthAt src pos end word
            in
            chompChunks vs es fs src newPos end row (col + 1) lastPos revChunks


{-| The enumeration numbers given so far in one file, keyed by leading digit, then
by tag name.

The digit key is the digit's value, 0 to 9, not its character code.

-}
type alias Enums =
    Dict Int (Dict Name Int)


{-| The JavaScript field numbers given so far in one file, keyed by tag name.
-}
type alias Fields =
    Dict Name Int


{-| Returns the text of `src` from index `pos` up to, but not including, `end`.
-}
toByteString : String -> Int -> Int -> String
toByteString src pos end =
    let
        off : Int
        off =
            pos

        len : Int
        len =
            end - pos
    in
    String.slice off (off + len) src


{-| Returns the chunks of `src` from `pos`, the first character after the tag's
character (the one after `__`), to `end`, having first added the chunk for that
tag.

The tag's name runs to the end of the identifier characters after `pos`. For
`__$` the name excludes the `$`; for every other tag it includes the tag
character, so `__1a` and `__a` have the names `1a` and `a`. An unresolved tag
returns `revChunks` and the position `pos`, which `parseChunks` takes as failure.

-}
chompTag : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> List Chunk -> ( ( List Chunk, Int ), ( Row, Col ) )
chompTag vs es fs src pos end row col revChunks =
    let
        ( newPos, newCol ) =
            Identifier.chompInnerChars src pos end col

        tagPos : Int
        tagPos =
            pos + -1

        word : Char
        word =
            P.unsafeIndex src tagPos
    in
    if word == '$' then
        let
            name : Name
            name =
                Name.fromPtr src pos newPos
        in
        (ElmField name :: revChunks) |> chompChunks vs es fs src newPos end row newCol newPos

    else
        let
            name : Name
            name =
                Name.fromPtr src tagPos newPos

            code : Int
            code =
                Char.toCode word
        in
        if code >= 0x30 && code <= 0x39 then
            let
                ( enum, newEnums ) =
                    lookupEnum (Char.fromCode (code - 0x30)) name es
            in
            (JsEnum enum :: revChunks) |> chompChunks vs newEnums fs src newPos end row newCol newPos

        else if code >= 0x61 && code <= 0x7A then
            let
                ( field, newFields ) =
                    lookupField name fs
            in
            (JsField field :: revChunks) |> chompChunks vs es newFields src newPos end row newCol newPos

        else if name == "DEBUG" then
            chompChunks vs es fs src newPos end row newCol newPos (Debug :: revChunks)

        else if name == "PROD" then
            chompChunks vs es fs src newPos end row newCol newPos (Prod :: revChunks)

        else
            case Dict.get name vs of
                Just chunk ->
                    chompChunks vs es fs src newPos end row newCol newPos (chunk :: revChunks)

                Nothing ->
                    ( ( revChunks, pos ), ( row, col ) )


{-| Returns the field number of `name`, giving it the next unused number when it has
none, with the table that records it.
-}
lookupField : Name -> Fields -> ( Int, Fields )
lookupField name fields =
    case Dict.get name fields of
        Just n ->
            ( n, fields )

        Nothing ->
            let
                n : Int
                n =
                    Dict.size fields
            in
            ( n, Dict.insert name n fields )


{-| Returns the enumeration number of `var` among the tags whose leading digit has
the value `Char.toCode word`, giving it the next unused number when it has none,
with the table that records it.
-}
lookupEnum : Char -> Name -> Enums -> ( Int, Enums )
lookupEnum word var allEnums =
    let
        code : Int
        code =
            Char.toCode word

        enums : Dict Name Int
        enums =
            Dict.get code allEnums
                |> Maybe.withDefault Dict.empty
    in
    case Dict.get var enums of
        Just n ->
            ( n, allEnums )

        Nothing ->
            let
                n : Int
                n =
                    Dict.size enums
            in
            ( n, Dict.insert code (Dict.insert var n enums) allEnums )



-- ====== PROCESS IMPORTS ======


{-| The chunk each imported tag name stands for, keyed by the tag name without its
leading `__`, such as `List_map`.
-}
type alias VarTable =
    Dict Name Chunk


{-| Builds the table of imported tag names from the header's `imports`. When two
imports produce the same tag name, the later one wins.
-}
toVarTable : Pkg.Name -> Foreigns -> List (Src.C1 Src.Import) -> VarTable
toVarTable pkg foreigns imports =
    List.foldl (addImport pkg foreigns) Dict.empty imports


{-| Returns `vtable` with an entry for every name in one import's `exposing` list.

A kernel module's names are prefixed with the module name after `Elm.Kernel.` or
`Eco.Kernel.`, and become `JsVar` chunks. An Elm module's names are prefixed as
`toPrefix` says and become `ElmVar` chunks, in the package `foreigns` gives, or
`pkg` when it has none. It crashes on an `as` on a kernel import.

-}
addImport : Pkg.Name -> Foreigns -> Src.C1 Src.Import -> VarTable -> VarTable
addImport pkg foreigns ( _, Src.Import ( _, A.At _ importName ) maybeAlias ( _, exposing_ ) ) vtable =
    if Name.isKernel importName then
        case maybeAlias of
            Just _ ->
                crash ("cannot use `as` with kernel import of: " ++ importName)

            Nothing ->
                let
                    ( kernelPrefix, home ) =
                        Name.getKernel importName

                    add : Name -> Dict Name Chunk -> Dict Name Chunk
                    add name table =
                        Dict.insert (Name.sepBy '_' home name) (JsVar kernelPrefix home name) table
                in
                List.foldl add vtable (toNames exposing_)

    else
        let
            home : ModuleName.Canonical
            home =
                ModuleName.Canonical (Dict.get importName foreigns |> Maybe.withDefault pkg) importName

            prefix : Name
            prefix =
                toPrefix importName (Maybe.map Src.c2Value maybeAlias)

            add : Name -> Dict Name Chunk -> Dict Name Chunk
            add name table =
                Dict.insert (Name.sepBy '_' prefix name) (ElmVar home name) table
        in
        List.foldl add vtable (toNames exposing_)


{-| Returns the prefix of the tag names for an Elm module `home`: its alias when it
has one, and otherwise its name, which must then have no dot or it crashes.
-}
toPrefix : Name -> Maybe Name -> Name
toPrefix home maybeAlias =
    case maybeAlias of
        Just alias ->
            alias

        Nothing ->
            if Name.hasDot home then
                crash ("kernel imports with dots need an alias: " ++ home)

            else
                home


{-| Returns the names in an explicit `exposing` list, and crashes on `exposing (..)`.
-}
toNames : Src.Exposing -> List Name
toNames exposing_ =
    case exposing_ of
        Src.Open _ _ ->
            crash "cannot have `exposing (..)` in kernel code."

        Src.Explicit (A.At _ exposedList) ->
            List.map (Src.c2Value >> toName) exposedList


{-| Returns the name of one exposed item. It crashes on an operator and on a type
exposed with its constructors.
-}
toName : Src.Exposed -> Name
toName exposed =
    case exposed of
        Src.Lower (A.At _ name) ->
            name

        Src.Upper (A.At _ name) ( _, Src.Private ) ->
            name

        Src.Upper _ ( _, Src.Public _ ) ->
            crash "cannot have Maybe(..) syntax in kernel code header"

        Src.Operator _ _ ->
            crash "cannot use binops in kernel code"
