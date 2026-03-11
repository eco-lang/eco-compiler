module Compiler.Generate.JavaScript.Name exposing
    ( Name
    , fromLocal, fromLocalHumanReadable
    , fromGlobal, fromGlobalHumanReadable, fromCycle
    , fromKernel
    , fromIndex, fromInt, makeF, makeA, makeLabel, makeTemp
    , dollar
    )

{-| JavaScript identifier generation and mangling for the Elm compiler.

This module handles the conversion of Elm identifiers to valid JavaScript names,
ensuring no collisions with JavaScript reserved words while maintaining compact
and predictable naming. It implements name mangling for globals, locals, and
temporary variables used during code generation.


# Core Type

@docs Name


# Local Names

@docs fromLocal, fromLocalHumanReadable


# Global Names

@docs fromGlobal, fromGlobalHumanReadable, fromCycle


# Kernel Names

@docs fromKernel


# Generated Names

@docs fromIndex, fromInt, makeF, makeA, makeLabel, makeTemp


# Special Values

@docs dollar

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO



-- ====== NAME ======


{-| JavaScript identifier name as a string.
-}
type alias Name =
    String



-- ====== CONSTRUCTORS ======


{-| Convert a zero-based index to a compact JavaScript name using ASCII encoding.
-}
fromIndex : Index.ZeroBased -> Name
fromIndex index =
    fromInt (Index.toMachine index)


{-| Convert an integer to a compact JavaScript name using ASCII encoding.
Avoids JavaScript and Elm reserved words through a renaming scheme.
-}
fromInt : Int -> Name
fromInt n =
    intToAscii n


{-| Convert a local Elm name to a JavaScript name, prefixing with underscore
if it conflicts with JavaScript or Elm reserved words.
-}
fromLocal : Name.Name -> Name
fromLocal name =
    if EverySet.member identity name reservedNames then
        "_" ++ name

    else
        name


{-| Convert a local Elm name to a human-readable JavaScript name without mangling.
Used for debugging or when readability is prioritized over collision avoidance.
-}
fromLocalHumanReadable : Name.Name -> Name
fromLocalHumanReadable name =
    name


{-| Convert a globally-qualified Elm name to a JavaScript name.
Encodes the module's canonical name (author, project, module path) with the value name,
using dollar signs as separators to ensure uniqueness.
-}
fromGlobal : IO.Canonical -> Name.Name -> Name
fromGlobal home name =
    homeToBuilder home ++ usd ++ name


{-| Convert a globally-qualified Elm name to a human-readable JavaScript name.
Uses dot-separated module.name format for debugging output.
-}
fromGlobalHumanReadable : IO.Canonical -> Name.Name -> Name
fromGlobalHumanReadable (IO.Canonical _ moduleName) name =
    moduleName ++ "." ++ name


{-| Generate a name for a cyclic definition in the module dependency graph.
Marks the value with $cyclic$ to distinguish it from regular global names.
-}
fromCycle : IO.Canonical -> Name.Name -> Name
fromCycle home name =
    homeToBuilder home ++ "$cyclic$" ++ name


{-| Generate a name for a kernel function (built-in JavaScript implementation).
Kernel names use underscore prefix and separator to namespace them separately.
-}
fromKernel : Name.Name -> Name.Name -> Name
fromKernel home name =
    "_" ++ home ++ "_" ++ name


homeToBuilder : IO.Canonical -> String
homeToBuilder (IO.Canonical ( author, project ) home) =
    usd
        ++ String.replace "-" "_" author
        ++ usd
        ++ String.replace "-" "_" project
        ++ usd
        ++ String.replace "." "$" home



-- ====== TEMPORARY NAMES ======


{-| Generate a function wrapper name (F2, F3, F4, etc.) for curried function application.
-}
makeF : Int -> Name
makeF n =
    "F" ++ String.fromInt n


{-| Generate an argument name (A2, A3, A4, etc.) for function parameters.
-}
makeA : Int -> Name
makeA n =
    "A" ++ String.fromInt n


{-| Generate a labeled name with an index suffix (e.g., loop$0, branch$1).
Used for loop labels and branching constructs in generated code.
-}
makeLabel : String -> Int -> Name
makeLabel name index =
    name ++ usd ++ String.fromInt index


{-| Generate a temporary variable name with $temp$ prefix.
Used for intermediate values during code generation.
-}
makeTemp : String -> Name
makeTemp name =
    "$temp$" ++ name


{-| The dollar sign character as a Name, used as a separator in generated identifiers.
-}
dollar : Name
dollar =
    usd


usd : String
usd =
    Name.dollar



-- ====== RESERVED NAMES ======


reservedNames : EverySet String String
reservedNames =
    EverySet.union jsReservedWords elmReservedWords


jsReservedWords : EverySet String String
jsReservedWords =
    EverySet.fromList identity
        [ "do"
        , "if"
        , "in"
        , "NaN"
        , "int"
        , "for"
        , "new"
        , "try"
        , "var"
        , "let"
        , "null"
        , "true"
        , "eval"
        , "byte"
        , "char"
        , "goto"
        , "long"
        , "case"
        , "else"
        , "this"
        , "void"
        , "with"
        , "enum"
        , "false"
        , "final"
        , "float"
        , "short"
        , "break"
        , "catch"
        , "throw"
        , "while"
        , "class"
        , "const"
        , "super"
        , "yield"
        , "double"
        , "native"
        , "throws"
        , "delete"
        , "return"
        , "switch"
        , "typeof"
        , "export"
        , "import"
        , "public"
        , "static"
        , "boolean"
        , "default"
        , "finally"
        , "extends"
        , "package"
        , "private"
        , "Infinity"
        , "abstract"
        , "volatile"
        , "function"
        , "continue"
        , "debugger"
        , "function"
        , "undefined"
        , "arguments"
        , "transient"
        , "interface"
        , "protected"
        , "instanceof"
        , "implements"
        , "synchronized"
        ]


elmReservedWords : EverySet String String
elmReservedWords =
    EverySet.fromList identity
        [ "F2"
        , "F3"
        , "F4"
        , "F5"
        , "F6"
        , "F7"
        , "F8"
        , "F9"
        , "A2"
        , "A3"
        , "A4"
        , "A5"
        , "A6"
        , "A7"
        , "A8"
        , "A9"
        ]



-- ====== INT TO ASCII ======


intToAscii : Int -> Name.Name
intToAscii n =
    if n < 53 then
        -- skip $ as a standalone name
        Name.fromWords [ toByte n ]

    else
        intToAsciiHelp 2 (numStartBytes * numInnerBytes) allBadFields (n - 53)


intToAsciiHelp : Int -> Int -> List BadFields -> Int -> Name.Name
intToAsciiHelp width blockSize badFields n =
    case badFields of
        [] ->
            if n < blockSize then
                unsafeIntToAscii width [] n

            else
                intToAsciiHelp (width + 1) (blockSize * numInnerBytes) [] (n - blockSize)

        (BadFields renamings) :: biggerBadFields ->
            let
                availableSize : Int
                availableSize =
                    blockSize - Dict.size renamings
            in
            if n < availableSize then
                let
                    name : Name.Name
                    name =
                        unsafeIntToAscii width [] n
                in
                Dict.get name renamings |> Maybe.withDefault name

            else
                intToAsciiHelp (width + 1) (blockSize * numInnerBytes) biggerBadFields (n - availableSize)



-- ====== UNSAFE INT TO ASCII ======


unsafeIntToAscii : Int -> List Char -> Int -> Name.Name
unsafeIntToAscii width bytes n =
    if width <= 1 then
        Name.fromWords (toByte n :: bytes)

    else
        let
            quotient : Int
            quotient =
                n // numInnerBytes

            remainder : Int
            remainder =
                n - (numInnerBytes * quotient)
        in
        unsafeIntToAscii (width - 1) (toByte remainder :: bytes) quotient



-- ====== ASCII BYTES ======


numStartBytes : Int
numStartBytes =
    54


numInnerBytes : Int
numInnerBytes =
    64


toByte : Int -> Char
toByte n =
    if n < 26 then
        -- lower
        Char.fromCode (97 + n)

    else if n < 52 then
        -- upper
        Char.fromCode (65 + n - 26)

    else if n == 52 then
        -- _
        Char.fromCode 95

    else if n == 53 then
        -- $
        Char.fromCode 36

    else if n < 64 then
        -- digit
        Char.fromCode (48 + n - 54)

    else
        -- crash ("cannot convert int " ++ String.fromInt n ++ " to ASCII")
        Char.fromCode n



-- ====== BAD FIELDS ======


type BadFields
    = BadFields Renamings


type alias Renamings =
    Dict Name.Name Name.Name


allBadFields : List BadFields
allBadFields =
    let
        add : String -> Dict Int BadFields -> Dict Int BadFields
        add keyword dict =
            Dict.update (String.length keyword) (addRenaming keyword >> Just) dict
    in
    Dict.values (EverySet.foldr compare add Dict.empty jsReservedWords)


addRenaming : String -> Maybe BadFields -> BadFields
addRenaming keyword maybeBadFields =
    let
        width : Int
        width =
            String.length keyword

        maxName : Int
        maxName =
            numStartBytes * numInnerBytes ^ (width - 1) - 1
    in
    case maybeBadFields of
        Nothing ->
            BadFields (Dict.singleton keyword (unsafeIntToAscii width [] maxName))

        Just (BadFields renamings) ->
            BadFields (Dict.insert keyword (unsafeIntToAscii width [] (maxName - Dict.size renamings)) renamings)
