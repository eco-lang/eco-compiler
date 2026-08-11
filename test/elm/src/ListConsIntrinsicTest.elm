module ListConsIntrinsicTest exposing (main)

{-| kernel-opt-01: saturated `x :: xs` lowers to `eco.construct.list` under
`ECO_LIST_CONS_INTRINSIC=1`; flag-off it stays `Elm_Kernel_List_cons*`.

Behaviour must be IDENTICAL in both flavours, so this fixture pins behaviour.
It deliberately carries no `head_kind` CHECK-MLIR directives: list _literals_
already emit `eco.construct.list` with the same head kinds flag-off, so such a
directive would pass vacuously in both flavours and give false confidence. The
authoritative encoding evidence is the emission-delta reconciliation on the
self-compile module (plan §4.1) plus the `IntrinsicsListConsTest` unit table.

Shapes exercised:

  - boxed heads (String) — `head_kind = 0`, the `!eco.value` slot
  - Int heads — the `_Int` ABI axis
  - Float heads — the `_Float` axis (no such kernel instance exists in the
    self-compile module today, so this is the only place it is exercised)
  - Char heads — the `_Char` axis
  - a `List.foldl (\x acc -> x :: acc)` accumulator loop — the EcoListTemplate
    chunk-rewrite shape, whose parity is this item's hard gate
  - `(::)` passed as a function VALUE to a HOF — the LSS devirtualization path
    (MonoSolver/Translate.elm:1782-1830), which rewrites to a saturated
    MonoVarKernel call and so must also intrinsify

-}

-- CHECK: boxed: ["a", "b", "c"]
-- CHECK: ints: 6
-- CHECK: floats: 6.5
-- CHECK: chars: "abc"
-- CHECK: viaFoldl: 55
-- CHECK: devirt: 15
-- CHECK: mixedTail: 3
-- CHECK-MLIR: eco.construct.list

import Html exposing (text)


{-| Boxed head slot: String heads go through `boxToEcoValue` unchanged.
-}
boxedHeads : List String
boxedHeads =
    "a" :: "b" :: [ "c" ]


{-| Int heads — the `_Int` suffix axis.
-}
intHeads : List Int
intHeads =
    1 :: 2 :: [ 3 ]


{-| Float heads — the `_Float` axis.
-}
floatHeads : List Float
floatHeads =
    1.5 :: 2.0 :: [ 3.0 ]


{-| Char heads — the `_Char` axis.
-}
charHeads : List Char
charHeads =
    'a' :: 'b' :: [ 'c' ]


{-| The cons-accumulator loop EcoListTemplate rewrites to scratch chunks.
-}
reverseViaFoldl : List Int -> List Int
reverseViaFoldl xs =
    List.foldl (\x acc -> x :: acc) [] xs


{-| `(::)` as a function value handed to a HOF: LSS devirtualizes this to a
saturated kernel call, which must then intrinsify like any other.
-}
viaDevirt : List Int -> List Int
viaDevirt xs =
    List.foldr (::) [] xs


{-| A cons whose tail is produced by a call rather than a literal.
-}
mixedTail : Int -> List Int
mixedTail n =
    n :: List.filter (\x -> x > 0) [ 1, 2 ]


main : Html.Html msg
main =
    let
        _ =
            Debug.log "boxed" boxedHeads

        _ =
            Debug.log "ints" (List.sum intHeads)

        _ =
            Debug.log "floats" (List.sum floatHeads)

        _ =
            Debug.log "chars" (String.fromList charHeads)

        _ =
            Debug.log "viaFoldl" (List.sum (reverseViaFoldl (List.range 1 10)))

        _ =
            Debug.log "devirt" (List.sum (viaDevirt (List.range 1 5)))

        _ =
            Debug.log "mixedTail" (List.length (mixedTail 7))
    in
    text "done"
