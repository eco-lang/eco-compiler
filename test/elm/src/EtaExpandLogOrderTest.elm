module EtaExpandLogOrderTest exposing (main)

{-| η-expansion does not move observable evaluation
(`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md` §2.5, §5).

The `CHECK-NEXT` chain pins the EXACT interleaving of `Debug.log` output, and
it must print identically with `etaExpand` on and off. That is the guard: the
transform reassociates nothing and re-times nothing.

`counted` is a definition of alias-arrow type whose body the gate refuses. It
is evaluated once, as Elm evaluates it: `GlobalOptimize` makes a function-typed
definition a closure, but one whose body computes its value is first moved into
a memoised CAF that the closure calls (MONO\_004), so `init` is logged once.

`chained` is the positive arm: a cheap two-of-three chain the pass DOES expand,
printing the same numbers either way.

-}
import Html exposing (text)



-- CHECK: init: 0
-- CHECK-NEXT: a: 1
-- CHECK-NEXT: b: 2
-- CHECK-NEXT: c: 3
-- CHECK-NEXT: chained: [11,12,13]


type alias St a =
    Int -> ( Int, a )


andThen : (a -> St b) -> St a -> St b
andThen f ma s0 =
    let
        ( s1, a ) =
            ma s0
    in
    f a s1


pure : a -> St a
pure x s =
    ( s, x )


tick : St Int
tick s =
    ( s + 1, s )


{-| REFUSED by the gate (`Debug.log` is a `VarDebug` call and no cheap arm
admits one), so the pass leaves this definition exactly as written.
It logs `init` once, as the module comment describes.
-}
counted : St Int
counted =
    let
        _ =
            Debug.log "init" 0
    in
    tick


{-| ADMITTED by the gate: two of three arguments at `andThen`, and a
one-parameter continuation. Nothing left of the new binder but the PAP the call
was about to apply.
-}
chained : St Int
chained =
    tick |> andThen (\a -> pure (a + 10))


runChained : Int -> Int
runChained n =
    Tuple.second (chained n)


main =
    let
        _ =
            Debug.log "a" (Tuple.second (counted 1))

        _ =
            Debug.log "b" (Tuple.second (counted 2))

        _ =
            Debug.log "c" (Tuple.second (counted 3))

        _ =
            Debug.log "chained" (List.map runChained [ 1, 2, 3 ])
    in
    text "done"
