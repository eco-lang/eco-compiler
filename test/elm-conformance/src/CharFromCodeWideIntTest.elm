module CharFromCodeWideIntTest exposing (main)

{-| `Char.fromCode` of a code outside 0 to 0x10FFFF gives the replacement character U+FFFD
(65533), even when the code's low 32 bits are a valid code point.

Each row logs `Char.toCode (Char.fromCode n)`:

  - `wide` and `low 32 bits A`: 0x100000041, written once in hex and once as 2^32 + 65, whose low
    32 bits are 0x41 (`'A'`), gives 65533.
  - `neg`: -1 gives 65533.
  - `max`: 0x10FFFF, the largest code point, is kept.
  - `above max`: 0x110000 gives 65533.

Among what is not tested: surrogate code points (0xD800 to 0xDFFF).
-}

-- CHECK: wide: 65533
-- CHECK: neg: 65533
-- CHECK: max: 1114111
-- CHECK: above max: 65533
-- CHECK: low 32 bits A: 65533


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "wide" (Char.toCode (Char.fromCode 0x000100000041))

                    _ =
                        Debug.log "neg" (Char.toCode (Char.fromCode -1))

                    _ =
                        Debug.log "max" (Char.toCode (Char.fromCode 0x0010FFFF))

                    _ =
                        Debug.log "above max" (Char.toCode (Char.fromCode 0x00110000))

                    _ =
                        Debug.log "low 32 bits A" (Char.toCode (Char.fromCode (4294967296 + 65)))
                in
                ( (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
