module Stage1.LinkedKernelsTest exposing (suite)

{-| The test bundle is built by stock `elm make`, like Stage 1, and must be post-processed like it
(plans/stage1-direct-kernel-linking.md): eco/system's JS kernels linked in, then the kernel overrides
applied. This is a guard of that build, not of a compiler module.

  - Without the post-processing the bundle crashes when it loads: the kernel stubs these modules reach
    are `Debug.todo`.
  - Without the overrides, or with them applied before the kernels are linked, the SeqDict equality and
    Hashed printing cases fail.

-}

import Expect
import Hash
import HashedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "eco kernels linked into the stock-Elm test bundle"
        [ Test.test "HashedDict get finds what insert put (FNV, SeqDict, JsArray2 kernels)" <|
            \_ ->
                HashedDict.empty
                    |> HashedDict.insert (Hash.hashed "a") 1
                    |> HashedDict.insert (Hash.hashed "b") 2
                    |> HashedDict.get (Hash.hashed "b")
                    |> Expect.equal (Just 2)
        , Test.test "== compares HashedDicts by their entries across a removal hole (the SeqDict equality override)" <|
            \_ ->
                let
                    withHole =
                        HashedDict.empty
                            |> HashedDict.insert (Hash.hashed "x") 0
                            |> HashedDict.insert (Hash.hashed "a") 1
                            |> HashedDict.remove (Hash.hashed "x")
                in
                withHole
                    |> Expect.equal (HashedDict.singleton (Hash.hashed "a") 1)
        , Test.test "Debug.toString of a \"Hashed\" value shows the value (the Hashed printing override)" <|
            \_ ->
                Debug.toString (Hash.hashed "a")
                    |> Expect.equal "\"a\""
        ]
