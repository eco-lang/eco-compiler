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

{-| Semantic versioning utilities for Elm packages and the compiler.

This module implements semantic versioning (major.minor.patch) with parsers, encoders,
comparison functions, and version bumping operations. It follows the SemVer specification
for version ordering and compatibility.


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


{-| Represents a semantic version with major, minor, and patch components.
-}
type Version
    = Version Int Int Int


{-| Extract the major version number from a Version.
-}
major : Version -> Int
major (Version major_ _ _) =
    major_


{-| Compare two versions following semantic versioning rules.
Returns LT if the first version is less than the second, GT if greater, EQ if equal.
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


{-| Convert a Version to a comparable tuple for use in sorting and comparison operations.
-}
toComparable : Version -> ( Int, Int, Int )
toComparable (Version major_ minor_ patch_) =
    ( major_, minor_, patch_ )


{-| Return the smaller of two versions according to semantic versioning order.
-}
min : Version -> Version -> Version
min v1 v2 =
    case compare v1 v2 of
        GT ->
            v2

        _ ->
            v1


{-| Return the larger of two versions according to semantic versioning order.
-}
max : Version -> Version -> Version
max v1 v2 =
    case compare v1 v2 of
        LT ->
            v2

        _ ->
            v1


{-| Version 1.0.0, commonly used as the initial package version.
-}
one : Version
one =
    Version 1 0 0


{-| The maximum representable version (2147483647.0.0), using the maximum 32-bit signed integer.
-}
maxVersion : Version
maxVersion =
    Version 2147483647 0 0


{-| The version of this compiler implementation. Currently returns 1.0.0.
-}
compiler : Version
compiler =
    --   case map fromIntegral (Version.versionBranch Paths_elm.version) of
    --     major : minor : patch : _ ->
    --       Version major minor patch
    --     [major, minor] ->
    --       Version major minor 0
    --     [major] ->
    --       Version major 0 0
    --     [] ->
    --       error "could not detect version of elm-compiler you are using"
    Version 1 0 0


{-| The version of the Elm compiler this implementation targets: 0.19.1.
-}
elmCompiler : Version
elmCompiler =
    Version 0 19 1



-- ====== BUMP ======


{-| Increment the patch version number by 1 (e.g., 1.2.3 becomes 1.2.4).
Used for backwards-compatible bug fixes.
-}
bumpPatch : Version -> Version
bumpPatch (Version major_ minor patch) =
    Version major_ minor (patch + 1)


{-| Increment the minor version number by 1 and reset patch to 0 (e.g., 1.2.3 becomes 1.3.0).
Used for backwards-compatible new features.
-}
bumpMinor : Version -> Version
bumpMinor (Version major_ minor _) =
    Version major_ (minor + 1) 0


{-| Increment the major version number by 1 and reset minor and patch to 0 (e.g., 1.2.3 becomes 2.0.0).
Used for backwards-incompatible API changes.
-}
bumpMajor : Version -> Version
bumpMajor (Version major_ _ _) =
    Version (major_ + 1) 0 0



-- ====== TO CHARS ======


{-| Convert a Version to its string representation in the format "major.minor.patch".
-}
toChars : Version -> String
toChars (Version major_ minor patch) =
    String.fromInt major_ ++ "." ++ String.fromInt minor ++ "." ++ String.fromInt patch



-- ====== JSON ======


{-| Decode a Version from a JSON string using the custom parser.
Returns a decoder that produces error positions on parse failure.
-}
decoder : D.Decoder ( Row, Col ) Version
decoder =
    D.customString parser Tuple.pair


{-| Encode a Version to a JSON string value in the format "major.minor.patch".
-}
encode : Version -> E.Value
encode version =
    E.string (toChars version)



-- ====== PARSER ======


{-| Parse a semantic version string in the format "major.minor.patch".
Each component must be a valid non-negative integer. Leading zeros are only allowed for "0".
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


isDigit : Char -> Bool
isDigit word =
    '0' <= word && word <= '9'



-- ====== ENCODERS and DECODERS ======


{-| Encode a Version to a binary format as three consecutive integers (major, minor, patch).
-}
versionEncoder : Version -> Bytes.Encode.Encoder
versionEncoder (Version major_ minor_ patch_) =
    Bytes.Encode.sequence
        [ BE.int major_
        , BE.int minor_
        , BE.int patch_
        ]


{-| Decode a Version from a binary format expecting three consecutive integers (major, minor, patch).
-}
versionDecoder : Bytes.Decode.Decoder Version
versionDecoder =
    Bytes.Decode.map3 Version
        BD.int
        BD.int
        BD.int
