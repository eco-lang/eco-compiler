module TailRecDeciderSearchTest exposing (main)

{-| A local function defined in a `let` that calls itself both in a tail position and in a
non-tail position, as the scrutinee of a `case`, gives the right result.

`firstInlineExpr` searches a binary tree of `Decider` values for the leftmost
`Leaf (Inline n)`. On a `Chain yes no` it first searches `yes` (the non-tail call) and,
when that finds nothing, searches `no` (the tail call). In the test tree the only `Inline`
leaf is the rightmost one, so both calls are taken and the result is 42.

The module defines its own `Maybe_` type instead of using `Maybe`.
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
