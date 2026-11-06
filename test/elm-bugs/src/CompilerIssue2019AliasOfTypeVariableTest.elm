module CompilerIssue2019AliasOfTypeVariableTest exposing (..)

{-| An alias `MyType k = k` is not interchangeable with `k` in a result position.

<https://github.com/elm/compiler/issues/2019>

`MyType k` is just `k`, and `MyType k -> k` is accepted, but Elm 0.19.1 rejects `k -> MyType k`
("This `x` value is a: k ... should be: MyType k"). It should compile.

-}

-- CHECK: test: 1

import Html exposing (text)


type alias MyType k =
    k


testFailure1 : k -> MyType k
testFailure1 x =
    x


testFailure2 : MyType k -> k -> Bool
testFailure2 a b =
    a == b


main =
    let
        _ =
            Debug.log "test" (testFailure1 1)

        _ =
            Debug.log "equal" (testFailure2 1 1)
    in
    text "done"
