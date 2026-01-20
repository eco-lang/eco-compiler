module CaseCustomType4WildcardTest exposing (main)

{-| Test case on custom type with 4 constructors, 2 explicit cases and wildcard.
-}

-- CHECK: card1: "hearts"
-- CHECK: card2: "spades"
-- CHECK: card3: "other"
-- CHECK: card4: "other"

import Html exposing (text)


type Suit
    = Hearts
    | Diamonds
    | Clubs
    | Spades


suitToStr suit =
    case suit of
        Hearts -> "hearts"
        Spades -> "spades"
        _ -> "other"


main =
    let
        _ = Debug.log "card1" (suitToStr Hearts)
        _ = Debug.log "card2" (suitToStr Spades)
        _ = Debug.log "card3" (suitToStr Diamonds)
        _ = Debug.log "card4" (suitToStr Clubs)
    in
    text "done"
