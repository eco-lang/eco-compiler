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

Every way a kernel file can be wrong is a `Compiler.Parse.Error.Kernel`
problem, reported to the user like any syntax error.

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
import Compiler.Parse.Error as Syntax
import Compiler.Parse.Module as Module
import Compiler.Parse.Space as Space
import Dict exposing (Dict)



-- ====== FROM FILE ======


{-| Parses the text of a kernel file belonging to package `pkg`.

The file must open with `/*`, then the header's import lines, each on a line of
its own, then `*/`. It fails with `Syntax.KernelHeaderSyntax` if the header does
not parse, with `Syntax.KernelUnknownTag` if the body has a kernel tag that is
in no category and was not imported, and with one of the other
`Compiler.Parse.Error.Kernel` problems for a header import the Elm syntax
allows but a kernel file does not: an `as` on a kernel import, a dotted Elm
module imported without `as`, `exposing (..)`, `Type(..)`, or an operator in
an `exposing` list.

-}
fromByteString : Pkg.Name -> Foreigns -> String -> Result Syntax.Kernel Content
fromByteString pkg foreigns bytes =
    P.fromByteString (parser pkg foreigns) Syntax.KernelHeaderSyntax bytes


{-| Produces the parser for a whole kernel file of package `pkg`, as
`fromByteString` describes.
-}
parser : Pkg.Name -> Foreigns -> P.Parser Syntax.Kernel Content
parser pkg foreigns =
    P.word2 '/' '*' Syntax.KernelHeaderSyntax
        |> P.andThen (\_ -> Space.chomp ignoreError)
        |> P.andThen (\_ -> Space.checkFreshLine Syntax.KernelHeaderSyntax)
        |> P.andThen (\_ -> P.specialize ignoreError (Module.chompImports []))
        |> P.andThen
            (\imports ->
                P.word2 '*' '/' Syntax.KernelHeaderSyntax
                    |> P.andThen
                        (\_ ->
                            case toVarTable pkg foreigns imports of
                                Ok vtable ->
                                    parseChunks vtable Dict.empty Dict.empty

                                Err problem ->
                                    failWith problem
                        )
                    |> P.map (\chunks -> Content imports chunks)
            )


{-| Returns a header syntax error at the position where a sub-parser failed,
discarding that sub-parser's own error.
-}
ignoreError : a -> Row -> Col -> Syntax.Kernel
ignoreError _ row col =
    Syntax.KernelHeaderSyntax row col


{-| Produces a parser that consumes nothing and fails with `problem`, which
carries its own position.
-}
failWith : Syntax.Kernel -> P.Parser Syntax.Kernel a
failWith problem =
    P.Parser (\(P.State st) -> P.Cerr st.row st.col (\_ _ -> problem))



-- ====== PARSE CHUNKS ======


{-| Produces a parser that reads the rest of the input as kernel file body, resolving
imported tags with `vtable`. It fails with `Syntax.KernelUnknownTag` at the first
tag in the body that is not understood.
-}
parseChunks : VarTable -> Enums -> Fields -> P.Parser Syntax.Kernel (List Chunk)
parseChunks vtable enums fields =
    P.Parser
        (\(P.State st) ->
            case chompChunks vtable enums fields st.src st.pos st.end st.row st.col st.pos [] of
                Chomped chunks ( newRow, newCol ) ->
                    P.Cok chunks (P.State { st | pos = st.end, row = newRow, col = newCol })

                UnknownTag row col name ->
                    P.Cerr row col (\_ _ -> Syntax.KernelUnknownTag row col name)
        )


{-| What `chompChunks` reached: every chunk of the body, with the row and column
at its end, or a tag that could not be resolved, with the position of its
leading `__` and its name without them.
-}
type Chomped
    = Chomped (List Chunk) ( Row, Col )
    | UnknownTag Row Col Name


{-| Returns the chunks of `src` from `pos` to `end`, with the row and column
reached, or the first tag that could not be resolved.

`lastPos` is where the current run of plain JavaScript started, and `revChunks`
holds the chunks already found, most recent first.

-}
chompChunks : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> Int -> List Chunk -> Chomped
chompChunks vs es fs src pos end row col lastPos revChunks =
    if pos >= end then
        let
            js : String
            js =
                toByteString src lastPos end
        in
        Chomped (List.reverse (JS js :: revChunks)) ( row, col )

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
                chompTag vs es fs src pos3 end row col (JS js :: revChunks)

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
tag. `tagCol` is the column of the tag's leading `__`.

The tag's name runs to the end of the identifier characters after `pos`. For
`__$` the name excludes the `$`; for every other tag it includes the tag
character, so `__1a` and `__a` have the names `1a` and `a`. A tag that resolves
to nothing is returned as `UnknownTag`.

-}
chompTag : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> List Chunk -> Chomped
chompTag vs es fs src pos end row tagCol revChunks =
    let
        ( newPos, newCol ) =
            Identifier.chompInnerChars src pos end (tagCol + 3)

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
                    UnknownTag row tagCol name


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


{-| Builds the table of imported tag names from the header's `imports`, or
fails with the problem of the first import a kernel file may not have. When two
imports produce the same tag name, the later one wins.
-}
toVarTable : Pkg.Name -> Foreigns -> List (Src.C1 Src.Import) -> Result Syntax.Kernel VarTable
toVarTable pkg foreigns imports =
    List.foldl (\imp acc -> Result.andThen (addImport pkg foreigns imp) acc) (Ok Dict.empty) imports


{-| Returns `vtable` with an entry for every name in one import's `exposing` list.

A kernel module's names are prefixed with the module name after `Elm.Kernel.` or
`Eco.Kernel.`, and become `JsVar` chunks; it fails on an `as` on such an import.
An Elm module's names are prefixed as `toPrefix` says and become `ElmVar`
chunks, in the package `foreigns` gives, or `pkg` when it has none.

-}
addImport : Pkg.Name -> Foreigns -> Src.C1 Src.Import -> VarTable -> Result Syntax.Kernel VarTable
addImport pkg foreigns ( _, Src.Import ( _, A.At region importName ) maybeAlias ( _, exposing_ ) ) vtable =
    case Name.toKernel importName of
        Just ( kernelPrefix, home ) ->
            case maybeAlias of
                Just _ ->
                    Err (Syntax.KernelImportAlias region importName)

                Nothing ->
                    let
                        add : Name -> Dict Name Chunk -> Dict Name Chunk
                        add name table =
                            Dict.insert (Name.sepBy '_' home name) (JsVar kernelPrefix home name) table
                    in
                    toNames region importName exposing_
                        |> Result.map (List.foldl add vtable)

        Nothing ->
            let
                home : ModuleName.Canonical
                home =
                    ModuleName.Canonical (Dict.get importName foreigns |> Maybe.withDefault pkg) importName
            in
            toPrefix region importName (Maybe.map Src.c2Value maybeAlias)
                |> Result.andThen
                    (\prefix ->
                        let
                            add : Name -> Dict Name Chunk -> Dict Name Chunk
                            add name table =
                                Dict.insert (Name.sepBy '_' prefix name) (ElmVar home name) table
                        in
                        toNames region importName exposing_
                            |> Result.map (List.foldl add vtable)
                    )


{-| Returns the prefix of the tag names for an Elm module `home`, whose name is
at `region`: its alias when it has one, and otherwise its name, which must then
have no dot.
-}
toPrefix : A.Region -> Name -> Maybe Name -> Result Syntax.Kernel Name
toPrefix region home maybeAlias =
    case maybeAlias of
        Just alias ->
            Ok alias

        Nothing ->
            if Name.hasDot home then
                Err (Syntax.KernelDottedWithoutAlias region home)

            else
                Ok home


{-| Returns the names in the explicit `exposing` list of the import of `home`,
whose name is at `region`. It fails on `exposing (..)`, on a type exposed with
its constructors, and on an operator.
-}
toNames : A.Region -> Name -> Src.Exposing -> Result Syntax.Kernel (List Name)
toNames region home exposing_ =
    case exposing_ of
        Src.Open _ _ ->
            Err (Syntax.KernelExposingAll region home)

        Src.Explicit (A.At _ exposedList) ->
            List.foldr
                (\exposed acc ->
                    Result.map2 (::) (toName region home (Src.c2Value exposed)) acc
                )
                (Ok [])
                exposedList


{-| Returns the name of one item exposed by the import of `home`, whose name is
at `region`. It fails on an operator and on a type exposed with its
constructors.
-}
toName : A.Region -> Name -> Src.Exposed -> Result Syntax.Kernel Name
toName region home exposed =
    case exposed of
        Src.Lower (A.At _ name) ->
            Ok name

        Src.Upper (A.At _ name) ( _, Src.Private ) ->
            Ok name

        Src.Upper (A.At _ name) ( _, Src.Public _ ) ->
            Err (Syntax.KernelExposingCtors region home name)

        Src.Operator _ op ->
            Err (Syntax.KernelExposingOperator region home op)
