module CrossSpecTupleEscapesTest exposing (main)

{-| Phase 3.1 #5 negative fixture: a top-level helper takes a tuple
and stores it in a List — the tuple escapes into a polymorphic
container, so cross-spec must conservatively NOT specialise the
function. The wrapper-only path runs; behaviour stays correct
because the heap-allocator path is intact.

The CHECK-NOT directive verifies no `$unboxed` worker was created
for `boxPair` — its tuple param flows into List.singleton (an
escaping non-projection use), which blocks specialisation.

-}

-- CHECK: result: 7
-- CHECK-NOT: boxPair$unboxed


import Html exposing (text)


boxPair : ( Int, Int ) -> List ( Int, Int )
boxPair pair =
    [ pair ]


main =
    let
        result =
            case boxPair ( 7, 23 ) of
                p :: _ ->
                    case p of
                        ( a, _ ) ->
                            a

                [] ->
                    0

        _ =
            Debug.log "result" result
    in
    text "done"
