module EraseWrapperMoveOnlyTest exposing (main)

{-| Single-constructor wrappers stored in `Array`s and in lists joined with
`++`, compared with `==` and printed with `Debug.toString`.

  - `P Int`: an `Array P` built with `push`, read with `get`, changed with
    `set`, summed with `foldl`, mapped and appended.
  - `R Int`: an `Array R` sliced.
  - `Q Float`: a list of `Q` joined with `++`, compared and printed.
  - `Box { n : Int }`: an `Array Box` mapped, and a `Box` compared.

## eco

Each wrapper is met through a type variable only in the shared specialization
of a kernel alias (`Elm.JsArray.push`, `List.append`, …), which never looks
inside the element (plans/constructor-representation-followups.md F4). So `P`
is erased to an `Int` and `Q` to a `Float`: neither constructor is built.

`R` stays a heap value: `Array.slice` reaches elm/core's `sliceLeft`, whose
let-bound `helper` keeps a type variable nothing fixes (MONO_021), met by a call
argument (`repr-meets-var: other:callArg`), which F4's rule does not cover.

-}

-- CHECK: got: Just (P 2)
-- CHECK: set: [P 1,P 20,P 3]
-- CHECK: sum: 6
-- CHECK: mapped: [P 10,P 20,P 30]
-- CHECK: sliced: [R 2,R 3]
-- CHECK: appended: 6
-- CHECK: qs: [Q 1.5,Q 2.5,Q 3.5]
-- CHECK: qsEq: True
-- CHECK: boxes: [Box { n = 2 },Box { n = 4 }]
-- CHECK: boxEq: True
-- CHECK-MLIR-NOT: constructor = "P"
-- CHECK-MLIR-NOT: constructor = "Q"

import Array exposing (Array)
import Html exposing (text)


type P
    = P Int


type Q
    = Q Float


type R
    = R Int


type Box
    = Box { n : Int }


unP : P -> Int
unP (P x) =
    x


main =
    let
        ps : Array P
        ps =
            Array.empty |> Array.push (P 1) |> Array.push (P 2) |> Array.push (P 3)

        _ =
            Debug.log "got" (Array.get 1 ps)

        _ =
            Debug.log "set" (Array.toList (Array.set 1 (P 20) ps))

        _ =
            Debug.log "sum" (Array.foldl (\p acc -> unP p + acc) 0 ps)

        _ =
            Debug.log "mapped" (Array.toList (Array.map (\p -> P (unP p * 10)) ps))

        _ =
            Debug.log "sliced" (Array.toList (Array.slice 1 3 (Array.fromList [ R 1, R 2, R 3 ])))

        _ =
            Debug.log "appended" (Array.length (Array.append ps ps))

        qs =
            [ Q 1.5 ] ++ [ Q 2.5, Q 3.5 ]

        _ =
            Debug.log "qs" qs

        _ =
            Debug.log "qsEq" (qs == [ Q 1.5, Q 2.5, Q 3.5 ])

        boxes =
            Array.fromList [ Box { n = 1 }, Box { n = 2 } ]
                |> Array.map (\(Box r) -> Box { n = r.n * 2 })

        _ =
            Debug.log "boxes" (Array.toList boxes)

        _ =
            Debug.log "boxEq" (Array.get 0 boxes == Just (Box { n = 2 }))
    in
    text "done"
