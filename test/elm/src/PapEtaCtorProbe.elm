module PapEtaCtorProbe exposing (main)

{-| Coverage probe: top-level eta-reduced PAPs of a two-stage global
(`bumpA = bumpWith (\st -> ...)`) stored inside a constructor, extracted,
and applied — the record-update-callback shape AbiCloning's decline
census uses. Written while hunting the escaped-taildef Char-capture ABI
bug (see CharCaptureEscapedTailDefTest); this shape does NOT trigger it —
kept because nothing else in the corpus pins ctor-stored point-free PAPs
end-to-end.
-}

import Html exposing (text)

-- CHECK: final: { depth = 9, stats = { a = 2, b = 2, shape = 4 } }


type alias Stats =
    { a : Int, b : Int, shape : Int }


type alias Ctx =
    { stats : Stats, depth : Int }


type Resolution
    = Stamp Int
    | Decline (Ctx -> Ctx)


bumpWith : (Stats -> Stats) -> Ctx -> Ctx
bumpWith sub ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = sub { stats | shape = stats.shape + 1 } }


bumpA : Ctx -> Ctx
bumpA =
    bumpWith (\st -> { st | a = st.a + 1 })


bumpB : Ctx -> Ctx
bumpB =
    bumpWith (\st -> { st | b = st.b + 1 })


resolve : Int -> Resolution
resolve n =
    if n > 4 then
        Stamp n

    else if modBy 2 n == 0 then
        Decline bumpA

    else
        Decline bumpB


step : Int -> Ctx -> Ctx
step n ctx =
    case resolve n of
        Stamp k ->
            { ctx | depth = ctx.depth + k }

        Decline bump ->
            bump ctx


main =
    let
        init =
            { stats = { a = 0, b = 0, shape = 0 }, depth = 0 }

        _ =
            Debug.log "final" (List.foldl step init [ 1, 2, 3, 4, 9 ])
    in
    text "done"
