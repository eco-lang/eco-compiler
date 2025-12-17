module Compiler.Elm.Kernel exposing
    ( Chunk(..), Content(..), Foreigns
    , fromByteString
    , countFields
    , chunkEncoder, chunkDecoder
    )

{-| Parser and utilities for Elm kernel JavaScript code.

Kernel modules contain JavaScript code that interfaces with Elm values. This module parses
kernel files into chunks representing JavaScript code, Elm variable references, field accesses,
and conditional compilation markers. The parser recognizes special tags like \_\_x where x identifies
the type of reference (Elm variable, JS variable, field, enum, DEBUG/PROD).


# Types

@docs Chunk, Content, Foreigns


# Parsing

@docs fromByteString


# Field Analysis

@docs countFields


# Binary Encoding/Decoding

@docs chunkEncoder, chunkDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as Module
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Parse.Space as Space
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)



-- CHUNK


{-| Represents a parsed chunk of kernel JavaScript code.

Kernel code is parsed into chunks that represent different types of content:
- JS: Raw JavaScript code
- ElmVar: Reference to an Elm variable from another module
- JsVar: Reference to a JavaScript variable from a kernel module
- ElmField: Reference to an Elm record field (\_\_$fieldName)
- JsField: Reference to a JavaScript field by index
- JsEnum: Reference to an enumeration value by index
- Debug: Conditional compilation marker for debug mode
- Prod: Conditional compilation marker for production mode
-}
type Chunk
    = JS String
    | ElmVar IO.Canonical Name
    | JsVar Name Name
    | ElmField Name
    | JsField Int
    | JsEnum Int
    | Debug
    | Prod



-- COUNT FIELDS


{-| Count the number of times each Elm field is referenced in a list of chunks.

Returns a dictionary mapping field names to their occurrence counts. Only ElmField
chunks are counted; all other chunk types are ignored.
-}
countFields : List Chunk -> Dict String Name Int
countFields chunks =
    List.foldr addField Dict.empty chunks


addField : Chunk -> Dict String Name Int -> Dict String Name Int
addField chunk fields =
    case chunk of
        JS _ ->
            fields

        ElmVar _ _ ->
            fields

        JsVar _ _ ->
            fields

        ElmField f ->
            Dict.update identity
                f
                (Maybe.map ((+) 1)
                    >> Maybe.withDefault 1
                    >> Just
                )
                fields

        JsField _ ->
            fields

        JsEnum _ ->
            fields

        Debug ->
            fields

        Prod ->
            fields



-- FROM FILE


{-| Represents the parsed content of a kernel module file.

Contains the list of imports from the kernel module header comment and the parsed
chunks representing the JavaScript code body.
-}
type Content
    = Content (List (Src.C1 Src.Import)) (List Chunk)


{-| Maps module names to their package names.

Used to resolve imported Elm modules to their canonical package locations when
processing kernel module imports.
-}
type alias Foreigns =
    Dict String ModuleName.Raw Pkg.Name


{-| Parse a kernel module file from a string.

Expects kernel files to start with a comment block containing imports, followed by
JavaScript code with special tags (\_\_x patterns) that reference Elm and JS variables,
fields, and conditional compilation markers. Returns Nothing if parsing fails.
-}
fromByteString : Pkg.Name -> Foreigns -> String -> Maybe Content
fromByteString pkg foreigns bytes =
    case P.fromByteString (parser pkg foreigns) toError bytes of
        Ok content ->
            Just content

        Err () ->
            Nothing


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


toError : Row -> Col -> ()
toError _ _ =
    ()


ignoreError : a -> Row -> Col -> ()
ignoreError _ _ _ =
    ()



-- PARSE CHUNKS


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
                    pos + P.getCharWidth word
            in
            chompChunks vs es fs src newPos end row (col + 1) lastPos revChunks


type alias Enums =
    Dict Int Int (Dict String Name Int)


type alias Fields =
    Dict String Name Int


toByteString : String -> Int -> Int -> String
toByteString src pos end =
    let
        off : Int
        off =
            -- pos - unsafeForeignPtrToPtr src
            pos

        len : Int
        len =
            end - pos
    in
    String.slice off (off + len) src


chompTag : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> List Chunk -> ( ( List Chunk, Int ), ( Row, Col ) )
chompTag vs es fs src pos end row col revChunks =
    let
        ( newPos, newCol ) =
            Var.chompInnerChars src pos end col

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
            case Dict.get identity name vs of
                Just chunk ->
                    chompChunks vs es fs src newPos end row newCol newPos (chunk :: revChunks)

                Nothing ->
                    ( ( revChunks, pos ), ( row, col ) )


lookupField : Name -> Fields -> ( Int, Fields )
lookupField name fields =
    case Dict.get identity name fields of
        Just n ->
            ( n, fields )

        Nothing ->
            let
                n : Int
                n =
                    Dict.size fields
            in
            ( n, Dict.insert identity name n fields )


lookupEnum : Char -> Name -> Enums -> ( Int, Enums )
lookupEnum word var allEnums =
    let
        code : Int
        code =
            Char.toCode word

        enums : Dict String Name Int
        enums =
            Dict.get identity code allEnums
                |> Maybe.withDefault Dict.empty
    in
    case Dict.get identity var enums of
        Just n ->
            ( n, allEnums )

        Nothing ->
            let
                n : Int
                n =
                    Dict.size enums
            in
            ( n, Dict.insert identity code (Dict.insert identity var n enums) allEnums )



-- PROCESS IMPORTS


type alias VarTable =
    Dict String Name Chunk


toVarTable : Pkg.Name -> Foreigns -> List (Src.C1 Src.Import) -> VarTable
toVarTable pkg foreigns imports =
    List.foldl (addImport pkg foreigns) Dict.empty imports


addImport : Pkg.Name -> Foreigns -> Src.C1 Src.Import -> VarTable -> VarTable
addImport pkg foreigns ( _, Src.Import ( _, A.At _ importName ) maybeAlias ( _, exposing_ ) ) vtable =
    if Name.isKernel importName then
        case maybeAlias of
            Just _ ->
                crash ("cannot use `as` with kernel import of: " ++ importName)

            Nothing ->
                let
                    home : Name
                    home =
                        Name.getKernel importName

                    add : Name -> Dict String Name Chunk -> Dict String Name Chunk
                    add name table =
                        Dict.insert identity (Name.sepBy '_' home name) (JsVar home name) table
                in
                List.foldl add vtable (toNames exposing_)

    else
        let
            home : IO.Canonical
            home =
                IO.Canonical (Dict.get identity importName foreigns |> Maybe.withDefault pkg) importName

            prefix : Name
            prefix =
                toPrefix importName (Maybe.map Src.c2Value maybeAlias)

            add : Name -> Dict String Name Chunk -> Dict String Name Chunk
            add name table =
                Dict.insert identity (Name.sepBy '_' prefix name) (ElmVar home name) table
        in
        List.foldl add vtable (toNames exposing_)


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


toNames : Src.Exposing -> List Name
toNames exposing_ =
    case exposing_ of
        Src.Open _ _ ->
            crash "cannot have `exposing (..)` in kernel code."

        Src.Explicit (A.At _ exposedList) ->
            List.map (Src.c2Value >> toName) exposedList


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



-- ENCODERS and DECODERS


{-| Encode a Chunk to bytes for serialization.

Each chunk type is encoded with a tag byte followed by its data. Used for caching
parsed kernel modules in artifact files.
-}
chunkEncoder : Chunk -> Bytes.Encode.Encoder
chunkEncoder chunk =
    case chunk of
        JS javascript ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string javascript
                ]

        ElmVar home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.canonicalEncoder home
                , BE.string name
                ]

        JsVar home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string home
                , BE.string name
                ]

        ElmField name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string name
                ]

        JsField int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.int int
                ]

        JsEnum int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.int int
                ]

        Debug ->
            Bytes.Encode.unsignedInt8 6

        Prod ->
            Bytes.Encode.unsignedInt8 7


{-| Decode a Chunk from bytes during deserialization.

Reads the tag byte to determine the chunk type, then decodes the corresponding data.
Used for loading cached kernel module artifacts.
-}
chunkDecoder : Bytes.Decode.Decoder Chunk
chunkDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map JS BD.string

                    1 ->
                        Bytes.Decode.map2 ElmVar
                            ModuleName.canonicalDecoder
                            BD.string

                    2 ->
                        Bytes.Decode.map2 JsVar
                            BD.string
                            BD.string

                    3 ->
                        Bytes.Decode.map ElmField BD.string

                    4 ->
                        Bytes.Decode.map JsField BD.int

                    5 ->
                        Bytes.Decode.map JsEnum BD.int

                    6 ->
                        Bytes.Decode.succeed Debug

                    7 ->
                        Bytes.Decode.succeed Prod

                    _ ->
                        Bytes.Decode.fail
            )
