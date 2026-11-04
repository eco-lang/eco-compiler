module Compiler.Type.State.IOTest exposing (suite)

{-| Checks the provenance code that `Compiler.Type.State.IO.lsTopContentK`
stores in the top lambda set it returns, for every code from -2 to 22.

The function keeps one shared content per code, so that the solver does not
allocate a new top lambda set at each join. Codes 1 to 9 and 11 to 20 come
back unchanged. A code of 0 or below comes back as 0, the poison code, and
10 and any code above 20 come back as 10, the code of `lsTopContent`. The
solver's programs only produce some of the codes, so the test calls the
function directly. The group label contains `coverage run`, so that the
coverage loop's quick runs count it.

-}

import Compiler.IR.Typed.TypeVars exposing (Content(..), FlatType(..), LambdaSet(..))
import Compiler.Type.State.IO as IO
import Expect
import Test exposing (Test)


{-| The group "coverage run: top lambda-set codes".
-}
suite : Test
suite =
    Test.describe "coverage run: top lambda-set codes"
        [ Test.test "each code reads back as itself, 0 or 10" <|
            \_ ->
                List.range -2 22
                    |> List.map (\k -> ( k, codeOf (IO.lsTopContentK k) ))
                    |> Expect.equalLists (List.map (\k -> ( k, Just (expected k) )) (List.range -2 22))
        ]


expected : Int -> Int
expected k =
    if k <= 0 then
        0

    else if k == 10 || k > 20 then
        10

    else
        k


codeOf : Content -> Maybe Int
codeOf content =
    case content of
        Structure (LambdaSet1 (LsTop code)) ->
            Just code

        _ ->
            Nothing
