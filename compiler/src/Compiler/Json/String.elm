module Compiler.Json.String exposing (fromSnippet, fromName, fromComment)

{-| String extraction utilities for JSON processing in the Elm compiler.

This module provides functions to extract strings from various compiler data structures,
including parser snippets and names. It handles proper escaping when extracting strings
from comments, ensuring newlines, quotes, and backslashes are properly escaped for JSON output.


# String Extraction

@docs fromSnippet, fromName, fromComment

-}

import Compiler.AST.Snippet as Snippet
import Compiler.Data.Name as Name
import Compiler.Parse.Primitives as P



-- ====== FROM ======


{-| Extract a string from a parser snippet.
-}
fromSnippet : Snippet.Snippet -> String
fromSnippet (Snippet.Snippet { fptr, offset, length }) =
    String.slice offset (offset + length) fptr


{-| Extract a string from a Name.
-}
fromName : Name.Name -> String
fromName =
    identity



-- ====== FROM COMMENT ======


{-| Extract a string from a comment snippet, properly escaping newlines, quotes, and backslashes.
-}
fromComment : Snippet.Snippet -> String
fromComment ((Snippet.Snippet { fptr, offset, length }) as snippet) =
    let
        pos : Int
        pos =
            offset

        end : Int
        end =
            pos + length
    in
    fromChunks snippet (chompChunks fptr pos end pos [])


chompChunks : String -> Int -> Int -> Int -> List Chunk -> List Chunk
chompChunks src pos end start revChunks =
    if pos >= end then
        List.reverse (addSlice start end revChunks)

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        case word of
            '\n' ->
                chompChunks src (pos + 1) end (pos + 1) (Escape 'n' :: addSlice start pos revChunks)

            '"' ->
                chompChunks src (pos + 1) end (pos + 1) (Escape '"' :: addSlice start pos revChunks)

            '\\' ->
                chompChunks src (pos + 1) end (pos + 1) (Escape '\\' :: addSlice start pos revChunks)

            {- \r -}
            '\u{000D}' ->
                let
                    newPos : Int
                    newPos =
                        pos + 1
                in
                chompChunks src newPos end newPos (addSlice start pos revChunks)

            _ ->
                let
                    width : Int
                    width =
                        P.getCharWidth word

                    newPos : Int
                    newPos =
                        pos + width
                in
                chompChunks src newPos end start revChunks


addSlice : Int -> Int -> List Chunk -> List Chunk
addSlice start end revChunks =
    if start == end then
        revChunks

    else
        Slice start (end - start) :: revChunks



-- ====== FROM CHUNKS ======


type Chunk
    = Slice Int Int
    | Escape Char


fromChunks : Snippet.Snippet -> List Chunk -> String
fromChunks snippet chunks =
    writeChunks snippet chunks


writeChunks : Snippet.Snippet -> List Chunk -> String
writeChunks snippet chunks =
    writeChunksHelp snippet chunks ""


writeChunksHelp : Snippet.Snippet -> List Chunk -> String -> String
writeChunksHelp ((Snippet.Snippet { fptr }) as snippet) chunks acc =
    case chunks of
        [] ->
            acc

        chunk :: chunks_ ->
            writeChunksHelp snippet
                chunks_
                (case chunk of
                    Slice offset len ->
                        acc ++ String.slice offset (offset + len) fptr

                    Escape 'n' ->
                        acc ++ String.fromChar '\n'

                    Escape '"' ->
                        acc ++ String.fromChar '"'

                    Escape '\\' ->
                        acc ++ String.fromChar '\\'

                    Escape word ->
                        acc ++ String.fromList [ '\\', word ]
                )
