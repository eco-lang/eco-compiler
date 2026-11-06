module ParserChompIfAstralTest exposing (main)

{-| `Parser.chompIf` treats a character outside the Basic Multilingual Plane as a single `Char`, while parser offsets count it as two UTF-16 code units.

The input uses U+1F600 (an emoji), which UTF-16 stores as a surrogate pair.

- `emoji_ok`: a predicate matching U+1F600 accepts the emoji.
- `emoji_chomped_ok`: `getChompedString` of that `chompIf` on `"😀x"` is
  `Ok "😀"`, the whole emoji.
- `emoji_offset`: after chomping the emoji, `getOffset` is 2.
- `half_fail`: a predicate accepting only surrogate code points (U+D800 to
  U+DFFF) fails on the emoji, so the predicate never sees half of the pair.
- `emoji_then_a_ok`: chomping the emoji, then `'a'`, then `end` succeeds on
  `"😀a"`, so parsing resumes after the whole pair.
-}

-- CHECK: emoji_ok: True
-- CHECK: emoji_chomped_ok: True
-- CHECK: emoji_offset: 2
-- CHECK: half_fail: True
-- CHECK: emoji_then_a_ok: True


import Html exposing (text)
import Parser exposing ((|.), (|=))


{-| Accepts only U+1F600.
-}
isEmoji : Char -> Bool
isEmoji c =
    Char.toCode c == 0x0001F600


{-| Accepts only surrogate code points, U+D800 to U+DFFF.
-}
isSurrogate : Char -> Bool
isSurrogate c =
    let
        n =
            Char.toCode c
    in
    n >= 0xD800 && n <= 0xDFFF


{-| Chomps one U+1F600 and returns the offset reached.
-}
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
