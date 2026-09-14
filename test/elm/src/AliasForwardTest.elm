module AliasForwardTest exposing (main)

{-| Pre-mono alias forwarding, runtime differential
(`plans/pre-mono-lss-transforms-04-alias-forwarding.md` §6).

Every alias shape the pass admits, used in every position it rewrites, with
the numbers as the guard: the pin must print the same values with
`ECO_INLINE_ALIAS_FORWARD` on and off, and in the `ECO_INLINE_THRESHOLD=0`
leg.

  - `dup = twice`: a `ToGlobal` alias of a local function, CALLED at two
    instantiations (`Int` and `String`) and passed as a VALUE.
  - `plus = (+)`: `(+)` canonicalizes to `VarGlobal Basics.add`, whose node is
    the kernel alias `add = Elm.Kernel.Basics.add` — a CHAIN
    (`plus ↦ Basics.add ↦ Elm.Kernel.Basics.add`). Saturated calls forward to
    the kernel; the R2 pin applies it at `Int` AND `Float`, so the
    `_Int`/`_Float` kernel-variant selection is exercised on the forwarded
    call.
  - `plus 1` inside `List.map`: an UNDER-applied kernel-alias call, which the
    §3.2 amendment keeps as a call of the alias.
  - `plus` as a VALUE in `List.foldl`: kept in v1 (R6).

Results are reduced to Ints before `Debug.log`.

-}

import Html exposing (text)



-- CHECK: dupInt: 3
-- CHECK: dupStr: 3
-- CHECK: foldInt: 6
-- CHECK: foldFloat: 45
-- CHECK: mapPartial: 5
-- CHECK: value: 4


twice : (a -> a) -> a -> a
twice f x =
    f (f x)


dup : (a -> a) -> a -> a
dup =
    twice


plus : number -> number -> number
plus =
    (+)


inc : Int -> Int
inc n =
    plus n 1


bang : String -> String
bang s =
    s ++ "!"


main =
    let
        _ =
            Debug.log "dupInt" (dup inc 1)

        _ =
            Debug.log "dupStr" (String.length (dup bang "a"))

        _ =
            Debug.log "foldInt" (List.foldl plus 0 [ 1, 2, 3 ])

        _ =
            Debug.log "foldFloat" (round (List.foldl plus 0.5 [ 1.5, 2.5 ] * 10))

        _ =
            Debug.log "mapPartial" (List.sum (List.map (plus 1) [ 1, 2 ]))

        _ =
            Debug.log "value" (List.sum (List.map dup [ inc ] |> List.map (\g -> g 2)))
    in
    text "done"
