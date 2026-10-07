module Compiler.Elm.Version exposing
    ( Version(..)
    , major
    , compare, toComparable, min, max
    , one, maxVersion, compiler, elmCompiler
    , bumpPatch, bumpMinor, bumpMajor
    , toChars
    , encode, decoder
    , versionEncoder, versionDecoder
    , parser
    )

{-| Packages, the Elm language and the compiler's own caches are all identified
by a version number, and this module is that number.

A version is three whole numbers, written `major.minor.patch`, such as `1.0.5`.
There is nothing else to it: no pre-release tag and no build metadata. Versions
are ordered by major number, then minor, then patch, and every comparison here
uses that order.

The module holds the ordering, the bumps that make the next version, the
written form and its parser, a JSON codec for the written form, a binary codec,
and a few versions with fixed meanings. Of those, `compiler` is the one that
needs care: it is not the version Eco reports to its users but the
_artifact-format version_, which names the directories that cached build
artifacts are kept in. Its docstring says when to change it.


# Types

@docs Version


# Accessors

@docs major


# Comparison

@docs compare, toComparable, min, max


# Version Constants

@docs one, maxVersion, compiler, elmCompiler


# Version Bumping

@docs bumpPatch, bumpMinor, bumpMajor


# Conversion

@docs toChars


# JSON Encoding/Decoding

@docs encode, decoder


# Binary Encoding/Decoding

@docs versionEncoder, versionDecoder


# Parsing

@docs parser

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== VERSION ======


{-| A version number: the major, minor and patch numbers, in that order.

Nothing stops a component from being negative.

-}
type Version
    = Version Int Int Int


{-| Returns the major number of a version.
-}
major : Version -> Int
major (Version major_ _ _) =
    major_


{-| Returns how the first version is ordered against the second, comparing the
major numbers, then the minor numbers, then the patch numbers.
-}
compare : Version -> Version -> Order
compare (Version major1 minor1 patch1) (Version major2 minor2 patch2) =
    case Basics.compare major1 major2 of
        EQ ->
            case Basics.compare minor1 minor2 of
                EQ ->
                    Basics.compare patch1 patch2

                minorRes ->
                    minorRes

        majorRes ->
            majorRes


{-| Returns the version as a tuple of its three numbers, which Elm's built-in
comparison orders the same way `compare` does, so it can serve as a sort key or
a `Dict` key.
-}
toComparable : Version -> ( Int, Int, Int )
toComparable (Version major_ minor_ patch_) =
    ( major_, minor_, patch_ )


{-| Returns the earlier of two versions, by `compare`.
-}
min : Version -> Version -> Version
min v1 v2 =
    case compare v1 v2 of
        GT ->
            v2

        _ ->
            v1


{-| Returns the later of two versions, by `compare`.
-}
max : Version -> Version -> Version
max v1 v2 =
    case compare v1 v2 of
        LT ->
            v2

        _ ->
            v1


{-| Version `1.0.0`: the version a new package is created with, and the one
`Terminal.Bump` expects of a package that has not been published before.
-}
one : Version
one =
    Version 1 0 0


{-| A version whose major number is the largest 32-bit signed integer, and whose
minor and patch numbers are zero.

It is later than every version with a smaller major number. It is not the
largest possible `Version`: one with the same major number and a non-zero minor
or patch number is later still, and an `Int` may exceed 32 bits.

-}
maxVersion : Version
maxVersion =
    Version 2147483647 0 0


{-| The artifact-format version: the version of the layout in which the
compiler writes its cached build artifacts.

`Builder.Stuff` names both a project's cache directory,
`<root>/eco-stuff/<version>`, and the caches under the Eco home directory,
`<home>/<version>/`, after it. Changing it therefore leaves every existing cache
behind at once, and everything that was cached, packages included, has to be
downloaded or built again.

It must change whenever the format of anything cached changes. An artifact
written in an older format is not reliably rejected when it is read back: it
can decode with no error and fail only later in compilation.

This is not the version Eco reports to its users, which is
`Compiler.Elm.Version_Build.userFacing`. The two change independently.

-}
compiler : Version
compiler =
    Version 0 2 0


{-| The version of Elm that this compiler implements.
-}
elmCompiler : Version
elmCompiler =
    Version 0 19 1



-- ====== BUMP ======


{-| Returns the version with its patch number raised by one, so `1.2.3` becomes
`1.2.4`.
-}
bumpPatch : Version -> Version
bumpPatch (Version major_ minor patch) =
    Version major_ minor (patch + 1)


{-| Returns the version with its minor number raised by one and its patch number
set to zero, so `1.2.3` becomes `1.3.0`.
-}
bumpMinor : Version -> Version
bumpMinor (Version major_ minor _) =
    Version major_ (minor + 1) 0


{-| Returns the version with its major number raised by one and its minor and
patch numbers set to zero, so `1.2.3` becomes `2.0.0`.
-}
bumpMajor : Version -> Version
bumpMajor (Version major_ _ _) =
    Version (major_ + 1) 0 0



-- ====== TO CHARS ======


{-| Returns the written form of a version, its three numbers in decimal joined
by dots, such as `1.0.5`.
-}
toChars : Version -> String
toChars (Version major_ minor patch) =
    String.fromInt major_ ++ "." ++ String.fromInt minor ++ "." ++ String.fromInt patch



-- ====== JSON ======


{-| A decoder for a version written as a JSON string, read by `parser`.

The whole string must be a version. When the string is not a version, the
failure carries the row and column at which reading stopped, as
`Compiler.Json.Decode.customString` reports it.

-}
decoder : D.Decoder ( Row, Col ) Version
decoder =
    D.customString parser Tuple.pair


{-| Returns a version as a JSON string in its written form.
-}
encode : Version -> E.Value
encode version =
    E.string (toChars version)



-- ====== PARSER ======


{-| A parser for the written form of a version: three runs of decimal digits
separated by single dots.

A number that starts with `0` is read as just that `0`, and reading stops after
it. So `01.0.0` fails, because a dot is expected after the `0`, but in
`1.0.01` the parser reads `1.0.0` and leaves the final `1` for whatever
follows. The parser does not check what comes after the patch number. Nothing
limits how many digits a number has, or how large it is.

On failure the error is the row and column at which a digit or a dot was
expected.

-}
parser : P.Parser ( Row, Col ) Version
parser =
    numberParser
        |> P.andThen
            (\major_ ->
                P.word1 '.' Tuple.pair
                    |> P.andThen (\_ -> numberParser)
                    |> P.andThen
                        (\minor ->
                            P.word1 '.' Tuple.pair
                                |> P.andThen (\_ -> numberParser)
                                |> P.map
                                    (\patch ->
                                        Version major_ minor patch
                                    )
                        )
            )


{-| A parser for one number of a version: either a single `0`, or a run of
digits that starts with any other digit.

It reads as many digits as follow, with no bound on the value. It fails, at the
current position, when the next character is not a digit or there is none.

-}
numberParser : P.Parser ( Row, Col ) Int
numberParser =
    P.Parser <|
        \(P.State st) ->
            if st.pos >= st.end then
                P.Eerr st.row st.col Tuple.pair

            else
                let
                    word : Char
                    word =
                        P.unsafeIndex st.src st.pos
                in
                if word == '0' then
                    let
                        newState : P.State
                        newState =
                            P.State { st | pos = st.pos + 1, col = st.col + 1 }
                    in
                    P.Cok 0 newState

                else if isDigit word then
                    let
                        ( total, newPos ) =
                            chompWord16 st.src (st.pos + 1) st.end (Char.toCode word - 0x30)

                        newState : P.State
                        newState =
                            P.State { st | pos = newPos, col = st.col + (newPos - st.pos) }
                    in
                    P.Cok total newState

                else
                    P.Eerr st.row st.col Tuple.pair


{-| Returns `total` extended by the decimal digits of `src` from `pos` onwards,
with the position just past the last digit.

It stops at the first character that is not a digit, or at `end`. Despite the
name, nothing bounds the value to 16 bits.

-}
chompWord16 : String -> Int -> Int -> Int -> ( Int, Int )
chompWord16 src pos end total =
    if pos >= end then
        ( total, pos )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if isDigit word then
            chompWord16 src (pos + 1) end (10 * total + (Char.toCode word - 0x30))

        else
            ( total, pos )


{-| Returns whether a character is one of the ASCII digits `0` to `9`.
-}
isDigit : Char -> Bool
isDigit word =
    '0' <= word && word <= '9'



-- ====== ENCODERS and DECODERS ======


{-| Returns the binary form of a version: its major, minor and patch numbers in
that order, each written by `Utils.Bytes.Encode.int`.
-}
versionEncoder : Version -> Bytes.Encode.Encoder
versionEncoder (Version major_ minor_ patch_) =
    Bytes.Encode.sequence
        [ BE.int major_
        , BE.int minor_
        , BE.int patch_
        ]


{-| A decoder for the binary form that `versionEncoder` writes.
-}
versionDecoder : Bytes.Decode.Decoder Version
versionDecoder =
    Bytes.Decode.map3 Version
        BD.int
        BD.int
        BD.int
