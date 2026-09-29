module StringRopeContentTest exposing (main)

{-| G3/E14: build a rope via repeated ++ exceeding the 128 Ki-unit flatten limit,
then assert content (not just length). 1400 appends of a 100-char chunk = 140000
chars; past 131072 code units (STRING\_FLATTEN\_LIMIT) append builds
Tag_StringRope nodes. Head and tail must be the intact chunk boundary.
-}

-- CHECK: rope_len: 140000
-- CHECK: rope_head: "abcdefghij"
-- CHECK: rope_tail: "abcdefghij"

import Html exposing (text)


main =
    let
        chunk =
            String.repeat 10 "abcdefghij"

        big =
            List.foldl (\_ acc -> acc ++ chunk) "" (List.range 1 1400)

        _ =
            Debug.log "rope_len" (String.length big)

        _ =
            Debug.log "rope_head" (String.left 10 big)

        _ =
            Debug.log "rope_tail" (String.right 10 big)
    in
    text "done"
