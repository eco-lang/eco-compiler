module CompilerIssue1491PhantomTupleUnsoundTest exposing (..)

{-| A phantom type parameter `( m, m )` is accepted where `( OnePlus m, m )` is required.

<https://github.com/elm/compiler/issues/1491>

Elm 0.19.1 accepts `head nil`, although `Vect ( m, m ) a` and `Vect ( OnePlus m, m ) a` do not
unify (`m` would have to equal `OnePlus m`). It should report a type error.

-}

-- COMPILE-ERROR: (m, m) does not unify with (OnePlus m, m)
-- CHECK: {{-- [A-Z ]+ -}}

import Html


type OnePlus m
    = OnePlus


type Vect m a
    = Vect (List a)


nil : Vect ( m, m ) a
nil =
    Vect []


head : Vect ( OnePlus m, m ) a -> Maybe a
head (Vect xs) =
    List.head xs


broken =
    head nil


main =
    Html.text ""
