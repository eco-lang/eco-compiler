module Compiler.Json.String exposing (fromSnippet, fromName, fromComment)

{-| Some text that is read from or written to JSON is held as a snippet or a name
rather than as a `String`. This module turns each into a plain `String`.

A _snippet_ names a piece of a source text by its position in the whole text,
as `Compiler.Core.Snippet` describes, so the text of the piece is a slice of that
whole text. A name is already a `String`.

None of these functions escapes or unescapes anything. `fromSnippet` returns the
text as it stands in the source, and `fromComment` differs from it only in
removing carriage returns. Escaping for JSON output is left to whatever encodes
the result.

@docs fromSnippet, fromName, fromComment

-}

import Compiler.Core.Name as Name
import Compiler.Core.Snippet as Snippet



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
fromComment snippet =
    String.filter (\c -> c /= '\u{000D}') (fromSnippet snippet)
