module HofStringCaseInlineTest exposing (main)

{-| A helper that does a `case` on a String gives the right result when called from a branch of a `case` on a custom type.

`score` matches an `Item`, and its `Tagged` branch calls `rank`, which matches
its String argument against `"alpha"` and `"beta"`. The logged value is
`score (Tagged "beta")` (2 * 100) plus `score Plain` (0) plus `rank "alpha"`
(1), which is 201.

## eco

Exercises a dialect corner reached by the HOF-elimination inliner
(plans/hof-elimination-closure-alloc-reduction.md): a string-case-bodied helper inlined under an
outer constructor case. String cases need CF lowering, so a nested string case
inside an SCF-converted outer case is rejected by dynamic legality in
runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp; the outer case must stay
on the CF path. The shape only became reachable once the inliner could place
case bodies in branch positions.

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
