module TailRecMultiCaseWhileTest exposing (main)

{-| Tail-recursive function with outer constructor case containing nested
string case. The nested string case forces eco.case to survive
EcoControlFlowToSCF, then CaseOpLowering in EcoToLLVM creates multiple
blocks inside the scf.while after-region (Bug 2).
-}

-- CHECK: total: 10
-- CHECK: special: 2

import Html exposing (text)


type Item
    = Named String Int
    | Plain Int
    | Skip


processItems : List Item -> Int -> Int -> ( Int, Int )
processItems items total specialCount =
    case items of
        [] ->
            ( total, specialCount )

        (Named tag n) :: rest ->
            case tag of
                "bonus" ->
                    processItems rest (total + n * 2) (specialCount + 1)

                "penalty" ->
                    processItems rest (total - n) (specialCount + 1)

                _ ->
                    processItems rest (total + n) specialCount

        (Plain n) :: rest ->
            processItems rest (total + n) specialCount

        Skip :: rest ->
            processItems rest total specialCount


main =
    let
        items =
            [ Plain 3, Named "bonus" 2, Skip, Named "penalty" 1, Plain 2 ]

        ( t, s ) =
            processItems items 0 0

        _ = Debug.log "total" t
        _ = Debug.log "special" s
    in
    text "done"
