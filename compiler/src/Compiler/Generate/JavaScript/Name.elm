module Compiler.Generate.JavaScript.Name exposing
    ( Name
    , fromLocal, fromLocalHumanReadable
    , fromGlobal, fromGlobalHumanReadable, fromCycle
    , fromKernel
    , fromIndex, fromInt, makeF, makeA, makeLabel, makeTemp
    , dollar
    )

{-| Generated JavaScript needs a name for every Elm value it defines or refers
to, and this module decides what those names are.

Elm and JavaScript disagree about which names are allowed and where. A local
Elm name such as `new` or `int` is legal in Elm but reserved in JavaScript, and
a top-level Elm name is unique only within its module, while the generated
program puts every module's values side by side. So each kind of Elm name is
spelled differently here:

  - A local keeps its Elm name, unless that name is on the reserved list, in
    which case `fromLocal` puts `_` in front of it. The reserved list is the
    JavaScript keywords and reserved words, a few names with a fixed meaning
    such as `NaN`, `undefined` and `arguments`, and the runtime helper names
    `F2` to `F9` and `A2` to `A9` that `makeF` and `makeA` produce.
  - A top-level value is spelled with the whole of its module's canonical name
    in front: `fromGlobal` gives `$author$project$Module$Sub$name`.
  - A kernel value, one the runtime implements in JavaScript, is
    `_Module_name` (`fromKernel`).

`fromInt` and `fromIndex` turn a number into a short name, shortest names
first: `a` to `z`, `A` to `Z`, `_`, then names of two characters, and so on.
Two different non-negative numbers below 5 × 10 ^ 10 (all of them names of up
to six characters) never get the same name, and none of those names is a
JavaScript reserved word or `$` on its own. On the JavaScript build of the
compiler `//` keeps only 32 bits, so names of seven characters or more can come
out wrong.

Most of the file is the machinery behind that guarantee. The first character of
a name is one of 54 (the letters, `_` and `$`) and each later character one of
64 (those and the ten digits), so a number is written in base 64 with a
narrower first digit. The one-character names come first, without `$`, and
then each width in turn. Within one width, the last few names are held back,
one for each reserved word of that width, and a number whose name would spell a
reserved word is given one of the held-back names instead.

The `HumanReadable` forms are not for emitting as code. They spell a name the
way an Elm programmer would read it, for showing to a person; the global form,
with its `.`, is not even a valid JavaScript identifier.


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
import Compiler.Elm.ModuleName as ModuleName
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)



-- ====== NAME ======


{-| A name for the generated JavaScript or its source map: usually an identifier
or the name of a property.

This is a name for `String`, not a new type. Any `String` is accepted where a
`Name` is expected, so the compiler does not check that a value is a valid, or
a safe, JavaScript identifier.

-}
type alias Name =
    String



-- ====== CONSTRUCTORS ======


{-| Returns the short name `fromInt` gives to the position counted from zero, so
`Index.first` gives `a`.
-}
fromIndex : Index.ZeroBased -> Name
fromIndex index =
    fromInt (Index.toMachine index)


{-| Returns the `n`th short name, counting from zero and shortest names first:
0 to 25 give `a` to `z`, 26 to 51 give `A` to `Z`, 52 gives `_`, and 53 gives
`aa`.

For non-negative numbers below 5 × 10 ^ 10, different numbers give different
names, and no name is `$` on its own or a word in the JavaScript reserved list;
a number whose name would spell a reserved word gets one of the last names of
that width instead (`do`, `if` and `in` become `$7`, `$8` and `$9`). Only the
JavaScript words are avoided: the runtime helper names `F2` to `F9` and `A2` to
`A9` are produced like any other name.

-}
fromInt : Int -> Name
fromInt n =
    intToAscii n


{-| Returns the JavaScript name of a local variable: `name` itself, or `name`
with `_` in front when it is a JavaScript reserved word or one of the runtime
helper names `F2` to `F9` and `A2` to `A9`.
-}
fromLocal : Name.Name -> Name
fromLocal name =
    if EverySet.member identity name reservedNames then
        "_" ++ name

    else
        name


{-| Returns a local name as an Elm programmer would read it, which is `name`
unchanged. Unlike `fromLocal` it does not avoid reserved words, so it is for
showing to a person, not for emitting as code.
-}
fromLocalHumanReadable : Name.Name -> Name
fromLocalHumanReadable name =
    name


{-| Returns the JavaScript name of the top-level value `name` defined in the
module `home`: `$author$project$Module$Sub$name`, with every `-` in the author
and project replaced by `_` and every `.` in the module name by `$`. For
example, `map` in `elm/core`'s `List` is `$elm$core$List$map`.
-}
fromGlobal : ModuleName.Canonical -> Name.Name -> Name
fromGlobal home name =
    homeToBuilder home ++ usd ++ name


{-| Returns a top-level name as an Elm programmer would read it, `Module.name`,
for showing to a person. The package is left out, so values of two packages'
modules with the same name read the same, and the `.` makes the result an
invalid JavaScript identifier.
-}
fromGlobalHumanReadable : ModuleName.Canonical -> Name.Name -> Name
fromGlobalHumanReadable (ModuleName.Canonical _ moduleName) name =
    moduleName ++ "." ++ name


{-| Returns a JavaScript name for the top-level value `name` of `home` that
differs from its `fromGlobal` name, for a value that is part of a cycle of
definitions within its module: `$cyclic` goes before the value name, as in
`$author$project$Module$cyclic$name`. It is used for the values of such a cycle
that take no arguments.
-}
fromCycle : ModuleName.Canonical -> Name.Name -> Name
fromCycle home name =
    homeToBuilder home ++ "$cyclic$" ++ name


{-| Returns the JavaScript name of the kernel value `name` in the kernel module
`home`, `_home_name`, so `fromKernel "List" "Nil"` is `_List_Nil`.
-}
fromKernel : Name.Name -> Name.Name -> Name
fromKernel home name =
    "_" ++ home ++ "_" ++ name


{-| Returns the prefix `fromGlobal` and `fromCycle` put in front of a value
name: `$author$project$Module`, with `-` replaced by `_` in the author and
project and `.` replaced by `$` in the module name.
-}
homeToBuilder : ModuleName.Canonical -> String
homeToBuilder (ModuleName.Canonical ( author, project ) home) =
    usd
        ++ String.replace "-" "_" author
        ++ usd
        ++ String.replace "-" "_" project
        ++ usd
        ++ String.replace "." "$" home



-- ====== TEMPORARY NAMES ======


{-| Returns `F` followed by `n`. For `n` from 2 to 9 this is the name of the
runtime helper that wraps a JavaScript function of `n` arguments so that it can
also be called one argument at a time.
-}
makeF : Int -> Name
makeF n =
    "F" ++ String.fromInt n


{-| Returns `A` followed by `n`. For `n` from 2 to 9 this is the name of the
runtime helper that applies a function to `n` arguments.
-}
makeA : Int -> Name
makeA n =
    "A" ++ String.fromInt n


{-| Returns `name$index`, a name for a JavaScript statement label.
-}
makeLabel : String -> Int -> Name
makeLabel name index =
    name ++ usd ++ String.fromInt index


{-| Returns `$temp$name`, a name for a temporary variable that belongs with the
local `name`.
-}
makeTemp : String -> Name
makeTemp name =
    "$temp$" ++ name


{-| The name `$`, the same text as `Compiler.Data.Name.dollar`. It is also the
separator in the names `fromGlobal`, `fromCycle` and `makeLabel` build, and
`fromInt` never returns it for a non-negative number.
-}
dollar : Name
dollar =
    usd


{-| The separator `$` that this module puts between the parts of a name.
-}
usd : String
usd =
    Name.dollar



-- ====== RESERVED NAMES ======


{-| The names a local may not keep, which `fromLocal` prefixes with `_`: the
JavaScript reserved list and the runtime helper names together.
-}
reservedNames : EverySet String String
reservedNames =
    EverySet.union jsReservedWords elmReservedWords


{-| The JavaScript reserved list: keywords, words reserved in some edition of
the language, and names with a fixed meaning such as `NaN`, `Infinity`,
`undefined`, `eval` and `arguments`. Neither `fromLocal` nor `fromInt` returns
one of these, the latter for a non-negative number below 5 × 10 ^ 10.
-}
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


{-| The runtime helper names `F2` to `F9` and `A2` to `A9`, the names `makeF`
and `makeA` produce for 2 to 9, which a local must not hide.
-}
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


{-| Returns the `n`th short name, as `fromInt` describes. The first 53 numbers
get one character each, every one-character name except `$`; from 53 on the
count continues among names of two characters or more.
-}
intToAscii : Int -> Name.Name
intToAscii n =
    if n < 53 then
        Name.fromWords [ toByte n ]

    else
        intToAsciiHelp 2 (numStartBytes * numInnerBytes) allBadFields (n - 53)


{-| Returns the `n`th name, counting from zero, among names of `width`
characters or more, where `blockSize` is the number of names of exactly `width`
characters.

`badFields` must hold the reserved words of `width` characters first, then
those of each next width in turn, since each step moves one width along and
drops one entry. Within a width that has reserved words, the last of its names
are skipped, one per reserved word, and a name that spells a reserved word is
replaced by one of those skipped names. Once the list is empty no name is
replaced.

-}
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


{-| Returns the `n`th name of exactly `width` characters, followed by the
characters `bytes`, without checking for reserved words. The last character is
`n` modulo 64 and each earlier one the next base-64 digit, with whatever is
left for the first.

That first character is a valid start of an identifier only when `n` is below
the number of `width`-character names, 54 × 64 ^ (`width` - 1); nothing here
checks it.

-}
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


{-| The number of characters a name can begin with: the 52 letters, `_` and
`$`. A digit cannot begin an identifier.
-}
numStartBytes : Int
numStartBytes =
    54


{-| The number of characters that can follow the first in a name: those a name
can begin with and the ten digits.
-}
numInnerBytes : Int
numInnerBytes =
    64


{-| Returns the character for the digit `n` of a name: 0 to 25 are `a` to `z`,
26 to 51 are `A` to `Z`, 52 is `_`, 53 is `$`, and 54 to 63 are `0` to `9`.
The digits a name can begin with are therefore the first 54. A number of 64 or
more gives the character with that code, which is no part of the scheme.
-}
toByte : Int -> Char
toByte n =
    if n < 26 then
        Char.fromCode (97 + n)

    else if n < 52 then
        Char.fromCode (65 + n - 26)

    else if n == 52 then
        Char.fromCode 95

    else if n == 53 then
        Char.fromCode 36

    else if n < 64 then
        Char.fromCode (48 + n - 54)

    else
        Char.fromCode n



-- ====== BAD FIELDS ======


{-| The JavaScript reserved words of one width, each paired with the name of
that width chosen to stand in its place.
-}
type BadFields
    = BadFields Renamings


{-| A table from a reserved word to the name used in its place.

This is a name for `Dict`, not a new type, and nothing checks that a key and its
name have the same width.

-}
type alias Renamings =
    Dict Name.Name Name.Name


{-| The replacements for every word of the JavaScript reserved list, one
`BadFields` for each width that has a reserved word, shortest first.

There is no entry for a width with no reserved word. The list has entries for
2 to 10 characters and then 12, so from 11 characters on `intToAsciiHelp` is
one entry out of step: it skips one 11-character name for nothing, and does not
replace `synchronized`. Only numbers above 9 × 10 ^ 17 reach that width.

-}
allBadFields : List BadFields
allBadFields =
    let
        add : String -> Dict Int BadFields -> Dict Int BadFields
        add keyword dict =
            Dict.update (String.length keyword) (addRenaming keyword >> Just) dict
    in
    Dict.values (EverySet.foldr add Dict.empty jsReservedWords)


{-| Returns the replacements for one width with `keyword` added, given those
already chosen for its width. `keyword` gets the last name of its width that
is not yet taken: the very last for the first word added, the one before it for
the second, and so on.
-}
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
