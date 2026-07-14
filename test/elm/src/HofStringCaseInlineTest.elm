module HofStringCaseInlineTest exposing (main)

{-| H2.0 dialect-corner pin (plans/hof-elimination-closure-alloc-reduction.md):
a STRING-case-bodied helper inlined UNDER an outer ctor case. Nested string
cases inside SCF-converted outer cases are rejected by dynamic legality
(EcoToLLVMControlFlow.cpp — string cases need CF lowering), so the pass must
keep the outer case on the CF path. This shape only becomes reachable once
the inliner may put case bodies in branch positions.

Behavioral: Tagged "beta" -> 2, Plain -> 0; 2*100 + 0 + rank "alpha" = 201.

-}

-- CHECK: result: 201


import Html exposing (text)


type Item
    = Tagged String
    | Plain


rank : String -> Int
rank s =
    case s of
        "alpha" ->
            1

        "beta" ->
            2

        _ ->
            0


score : Item -> Int
score item =
    case item of
        Tagged name ->
            rank name * 100

        Plain ->
            0


main =
    let
        _ =
            Debug.log "result" (score (Tagged "beta") + score Plain + rank "alpha")
    in
    text "done"
