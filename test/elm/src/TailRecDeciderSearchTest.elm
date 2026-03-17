module TailRecDeciderSearchTest exposing (main)

{-| FAILING TEST: SSA dominance violation in let-bound tail-recursive function
with self-referencing non-tail recursive call.

Bug: When a let-bound tail-recursive function (MonoTailDef) makes a NON-tail
recursive call to itself inside the loop body, the self-reference resolves
to a stale sibling mapping SSA var from the outer scope, not the correct
closure reference.

Root cause: Lambdas.generateLambdaFunc merges siblingMappings into varMappings.
These sibling SSA vars come from the outer function's placeholder allocation.
Inside the compiled lambda, nextVar is reset, so fresh vars (doneInitVar,
resInitVar, scf.while results) alias with the sibling mapping vars.

The pattern requires:
  1. A let-bound tail-recursive function (MonoTailDef -> _tail_ prefix)
  2. A self-referencing non-tail recursive call in the body
     (e.g., case firstInlineExpr yes of Just e -> ...; Nothing -> firstInlineExpr no)
  3. The non-tail call uses eco.papExtend with the function closure as operand
  4. The closure reference resolves to a sibling mapping SSA var that has been
     overwritten by doneInitVar or another fresh var in the lambda function
-}

-- CHECK: found: 42

import Html exposing (text)


type Choice
    = Inline Int
    | Jump Int


type Decider
    = Leaf Choice
    | Chain Decider Decider


type Maybe_ a
    = Just_ a
    | Nothing_


search : Decider -> Maybe_ Int
search tree =
    let
        firstInlineExpr decider =
            case decider of
                Leaf choice ->
                    case choice of
                        Inline val ->
                            Just_ val

                        Jump _ ->
                            Nothing_

                Chain yes no ->
                    case firstInlineExpr yes of
                        Just_ e ->
                            Just_ e

                        Nothing_ ->
                            firstInlineExpr no
    in
    firstInlineExpr tree


unwrap : Maybe_ Int -> Int
unwrap m =
    case m of
        Just_ x -> x
        Nothing_ -> -1


main =
    let
        tree = Chain (Leaf (Jump 0)) (Chain (Leaf (Jump 1)) (Leaf (Inline 42)))
        result = unwrap (search tree)
        _ = Debug.log "found" result
    in
    text "done"
