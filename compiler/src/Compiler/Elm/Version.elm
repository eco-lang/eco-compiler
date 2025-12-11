module Compiler.Elm.Version exposing
    ( Version(..)
    , bumpMajor
    , bumpMinor
    , bumpPatch
    , compare
    , compiler
    , decoder
    , elmCompiler
    , encode
    , jsonDecoder
    , jsonEncoder
    , major
    , max
    , maxVersion
    , min
    , one
    , parser
    , toChars
    , toComparable
    , versionDecoder
    , versionEncoder
    )

import Bytes.Decode
import Bytes.Encode
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Json.Decode as Decode
import Json.Encode as Encode
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- VERSION


type Version
    = Version Int Int Int


major : Version -> Int
major (Version major_ _ _) =
    major_


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


toComparable : Version -> ( Int, Int, Int )
toComparable (Version major_ minor_ patch_) =
    ( major_, minor_, patch_ )


min : Version -> Version -> Version
min v1 v2 =
    case compare v1 v2 of
        GT ->
            v2

        _ ->
            v1


max : Version -> Version -> Version
max v1 v2 =
    case compare v1 v2 of
        LT ->
            v2

        _ ->
            v1


one : Version
one =
    Version 1 0 0


maxVersion : Version
maxVersion =
    Version 2147483647 0 0


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


elmCompiler : Version
elmCompiler =
    Version 0 19 1



-- BUMP


bumpPatch : Version -> Version
bumpPatch (Version major_ minor patch) =
    Version major_ minor (patch + 1)


bumpMinor : Version -> Version
bumpMinor (Version major_ minor _) =
    Version major_ (minor + 1) 0


bumpMajor : Version -> Version
bumpMajor (Version major_ _ _) =
    Version (major_ + 1) 0 0



-- TO CHARS


toChars : Version -> String
toChars (Version major_ minor patch) =
    String.fromInt major_ ++ "." ++ String.fromInt minor ++ "." ++ String.fromInt patch



-- JSON


decoder : D.Decoder ( Row, Col ) Version
decoder =
    D.customString parser Tuple.pair


encode : Version -> E.Value
encode version =
    E.string (toChars version)



-- PARSER


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



-- ENCODERS and DECODERS


jsonEncoder : Version -> Encode.Value
jsonEncoder version =
    Encode.string (toChars version)


jsonDecoder : Decode.Decoder Version
jsonDecoder =
    Decode.string
        |> Decode.andThen
            (\str ->
                case P.fromByteString parser Tuple.pair str of
                    Ok version ->
                        Decode.succeed version

                    Err _ ->
                        Decode.fail "failed to parse version"
            )


versionEncoder : Version -> Bytes.Encode.Encoder
versionEncoder (Version major_ minor_ patch_) =
    Bytes.Encode.sequence
        [ BE.int major_
        , BE.int minor_
        , BE.int patch_
        ]


versionDecoder : Bytes.Decode.Decoder Version
versionDecoder =
    Bytes.Decode.map3 Version
        BD.int
        BD.int
        BD.int
