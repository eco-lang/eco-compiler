module CharFromCodeWideIntTest exposing (main)

{-| DEAD-01 guard (plans/kernel-lib-bug-fixes.md, group 01). `Char.fromCode` of a code outside
0..0x10FFFF gives U+FFFD in Elm (JS `_Char_fromCode` range-checks the whole number), including
codes that only fit a 64-bit Int and negative ones. The dead `Elm::Kernel::Char::fromCode(int32_t)`
that DEAD-01 deletes would have truncated 0x100000041 to 0x41 ('A'); this pins the live export's
semantics so the deletion (and any later rewrite) keeps them. It passes today: dead code cannot
be exposed by a program. Expectations recorded from Elm.
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
