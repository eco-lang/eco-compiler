module ListMapTemplateCtorTest exposing (main)

{-| F-5B's ctor-as-callback fixture (`plans/list-map-mlir-template.md` F-5B).

Three unary-constructor callbacks, one per origin flavour the licence must
now admit:

1.  `Just` — an elm/core ctor, minted as a `g|` member (only nullary-enum
    and box ctors get `c|`), which is exactly why F-5A's origin taxonomy is
    the precondition.
2.  `Tagged` — a user-defined unary ctor of a multi-constructor union.
3.  `Wrap` — a BOX ctor (single-constructor, single-field), the `TOpt.Box`
    node F-5A also reclassifies.

Behaviourally a licensed and a declined map compute the same list, so the
CHECK lines pin the values only. The absolute pins live in the F-5B landing
note's compile-and-grep: on this compile `licensed = 3`,
`declinedNoStamp = 0`, `declinedUnresolvedMember = 0`,
`declinedCtorUnresolved = 0`, and the artifact carries `eco.list.map` with
all three ctor callee symbols.

-}

-- CHECK: justs: 3
-- CHECK-NEXT: tagged: 60
-- CHECK-NEXT: wrapped: 6

import Html exposing (text)


type Tagged
    = Tagged Int
    | Untagged


type Wrap
    = Wrap Int


untag : Tagged -> Int
untag t =
    case t of
        Tagged n ->
            n * 10

        Untagged ->
            0


unwrap : Wrap -> Int
unwrap (Wrap n) =
    n


main : Html.Html msg
main =
    let
        justs : List (Maybe Int)
        justs =
            List.map Just [ 1, 2, 3 ]

        tagged : List Tagged
        tagged =
            List.map Tagged [ 1, 2, 3 ]

        wrapped : List Wrap
        wrapped =
            List.map Wrap [ 1, 2, 3 ]

        _ =
            Debug.log "justs" (List.length justs)

        -- Folds, not maps: an extra `List.map` here would add recognized
        -- specs with global-function callbacks and blur the absolute census
        -- pin this fixture exists to carry.
        _ =
            Debug.log "tagged" (List.foldl (\t acc -> acc + untag t) 0 tagged)

        _ =
            Debug.log "wrapped" (List.foldl (\w acc -> acc + unwrap w) 0 wrapped)
    in
    text "done"
