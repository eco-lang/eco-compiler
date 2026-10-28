module ParserChompIfAstralTest exposing (main)

{-| `Parser.chompIf` hands its predicate the whole code point of an astral
character (Char is a Unicode code point in i32; the parser kernel's isSubChar
passes the code point, not a UTF-16 unit), so a predicate on the emoji matches
it and the parser's offset then advances by 2 UTF-16 units, as in Elm's JS.
-}

-- CHECK: emoji_ok: True
-- CHECK: emoji_chomped_ok: True
-- CHECK: emoji_offset: 2
-- CHECK: half_fail: True
-- CHECK: emoji_then_a_ok: True


import Html exposing (text)
import Parser exposing ((|.), (|=))


isEmoji : Char -> Bool
isEmoji c =
    Char.toCode c == 0x0001F600


isSurrogate : Char -> Bool
isSurrogate c =
    let
        n =
            Char.toCode c
    in
    n >= 0xD800 && n <= 0xDFFF


emojiOffset : Parser.Parser Int
emojiOffset =
    Parser.succeed identity
        |. Parser.chompIf isEmoji
        |= Parser.getOffset


main =
    let
        _ =
            Debug.log "emoji_ok"
                (case Parser.run (Parser.chompIf isEmoji) "😀" of
                    Ok _ ->
                        True

                    Err _ ->
                        False
                )

        _ =
            Debug.log "emoji_chomped_ok"
                (Parser.run (Parser.getChompedString (Parser.chompIf isEmoji)) "😀x" == Ok "😀")

        _ =
            Debug.log "emoji_offset"
                (case Parser.run emojiOffset "😀x" of
                    Ok n ->
                        n

                    Err _ ->
                        -1
                )

        _ =
            Debug.log "half_fail"
                (case Parser.run (Parser.chompIf isSurrogate) "😀" of
                    Err _ ->
                        True

                    Ok _ ->
                        False
                )

        _ =
            Debug.log "emoji_then_a_ok"
                (case Parser.run (Parser.chompIf isEmoji |. Parser.chompIf (\c -> c == 'a') |. Parser.end) "😀a" of
                    Ok _ ->
                        True

                    Err _ ->
                        False
                )
    in
    text "done"
