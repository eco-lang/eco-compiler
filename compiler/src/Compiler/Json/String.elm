module Compiler.Json.String exposing (fromSnippet, fromName, fromComment)

{-| Some text that is read from or written to JSON is held as a snippet or a name
rather than as a `String`. This module turns each into a plain `String`.

A _snippet_ names a piece of a source text by its position in the whole text,
as `Compiler.AST.Snippet` describes, so the text of the piece is a slice of that
whole text. A name is already a `String`.

None of these functions escapes or unescapes anything. `fromSnippet` returns the
text as it stands in the source, and `fromComment` differs from it only in
removing carriage returns. Escaping for JSON output is left to whatever encodes
the result.

@docs fromSnippet, fromName, fromComment

-}

import Compiler.AST.Snippet as Snippet
import Compiler.Data.Name as Name
import Compiler.Parse.Primitives as P



-- ====== FROM ======


{-| Returns the text of the piece the snippet names, exactly as it appears in
the source. Escape sequences in it are kept as written, not decoded.
-}
fromSnippet : Snippet.Snippet -> String
fromSnippet (Snippet.Snippet { fptr, offset, length }) =
    String.slice offset (offset + length) fptr


{-| Returns the name unchanged.
-}
fromName : Name.Name -> String
fromName =
    identity



-- ====== FROM COMMENT ======


{-| Returns the text of the piece `snippet` names with every carriage return
removed. Every other character, including newlines, quotes and backslashes, is
kept as it is: nothing is escaped.
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


{-| Returns, in order, the chunks in `revChunks`, which holds the chunks found
so far most recent first, followed by the chunks that spell out `src` from
`start` to `end` with carriage returns left out. `start` is where the slice
still being scanned began, and `pos` is how far the scan has reached.

A newline, a double quote or a backslash closes the current slice and becomes
an `Escape` chunk. A carriage return closes the current slice and is dropped.

-}
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


{-| Returns `revChunks` with a `Slice` for the text from `start` to `end` added
at the front, or `revChunks` unchanged when that range is empty.
-}
addSlice : Int -> Int -> List Chunk -> List Chunk
addSlice start end revChunks =
    if start == end then
        revChunks

    else
        Slice start (end - start) :: revChunks



-- ====== FROM CHUNKS ======


{-| One piece of the text that `fromComment` builds.

`Slice` carries the offset and the length of a run of the snippet's whole text
to copy, counted in the units `String.slice` uses.

`Escape` carries a character at which the current slice was closed: `'n'` for
a newline, `'"'` or `'\\'`. Each is written back as the character it stands
for, so the output holds a real newline, quote or backslash. Any other
character would be written after a backslash, but the scan produces no other.

-}
type Chunk
    = Slice Int Int
    | Escape Char


{-| Returns the text that `chunks` spell out, reading each `Slice` from the
whole text of `snippet`.
-}
fromChunks : Snippet.Snippet -> List Chunk -> String
fromChunks snippet chunks =
    writeChunks snippet chunks


{-| Returns the text that `chunks` spell out, reading each `Slice` from the
whole text of `snippet`.
-}
writeChunks : Snippet.Snippet -> List Chunk -> String
writeChunks snippet chunks =
    writeChunksHelp snippet chunks ""


{-| Returns `acc` followed by the text that `chunks` spell out, reading each
`Slice` from the whole text of `snippet`.
-}
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
