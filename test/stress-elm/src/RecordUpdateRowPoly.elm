module RecordUpdateRowPoly exposing (main)

-- CHECK: smallFinal: -1
-- CHECK: bigFinal: (-1, 20, 30)

import Html exposing (text)


{-| A row-polymorphic bump function: { r | a : Int } -> { r | a : Int }.
Invoked via a polymorphic wrapper on two record shapes ({ a } and
{ a, b, c }) to ensure the MonoRecordUpdate specialization for each
call-site uses the *source* record's layout, not a narrowed one.
-}
flipA : { r | a : Int } -> { r | a : Int }
flipA r =
    { r | a = -r.a }


apply : (a -> a) -> a -> a
apply f v =
    f v


main =
    let
        small =
            { a = 1 }

        big =
            { a = 1, b = 20, c = 30 }

        smallFinal =
            (apply flipA small).a

        bigAfter =
            apply flipA big

        _ =
            Debug.log "smallFinal" smallFinal

        _ =
            Debug.log "bigFinal" ( bigAfter.a, bigAfter.b, bigAfter.c )
    in
    text "done"
