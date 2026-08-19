module NullConsNormalUnionTest exposing (main)

{-| Null-cons embedding (HEAP_044): a nullary ctor of a NORMAL (mixed-arity)
union — the RBEmpty shape — is an embedded constant while its sibling stays a
heap object. Construct, match, and compare both arms.
-}

-- CHECK: matchA: "a"
-- CHECK: matchB: 41
-- CHECK: eqAA: True
-- CHECK: eqAB: False
-- CHECK: eqBB: True
-- CHECK: eqB5B7: False
-- CHECK: inField: "a"
-- CHECK: printA: A
-- CHECK: printB: B 7

import Html exposing (text)


type T
    = A
    | B Int


describe : T -> String
describe t =
    case t of
        A ->
            "a"

        B n ->
            "b" ++ String.fromInt n


unwrapOr : Int -> T -> Int
unwrapOr fallback t =
    case t of
        A ->
            fallback

        B n ->
            n


mk : Int -> T
mk n =
    if n < 0 then
        A

    else
        B n


main =
    let
        _ =
            Debug.log "matchA" (describe (mk (negate 1)))

        _ =
            Debug.log "matchB" (unwrapOr 0 (mk 41))

        -- Equality: embedded-vs-embedded (word), embedded-vs-heap (unequal
        -- ctors), heap-vs-heap (structural).
        _ =
            Debug.log "eqAA" (mk (negate 1) == A)

        _ =
            Debug.log "eqAB" (mk (negate 1) == B 0)

        _ =
            Debug.log "eqBB" (mk 5 == B 5)

        _ =
            Debug.log "eqB5B7" (mk 5 == B 7)

        -- The embedded ctor stored in and read back from a heap field.
        _ =
            Debug.log "inField" (describe (Tuple.first ( A, B 1 )))

        -- Typed debug printing of both arms of a mixed-arity union: the
        -- embedded ctor names itself from its declaration index, the heap
        -- ctor from its Custom.ctor field.
        _ =
            Debug.log "printA" (mk (negate 1))

        _ =
            Debug.log "printB" (mk 7)
    in
    text "done"
