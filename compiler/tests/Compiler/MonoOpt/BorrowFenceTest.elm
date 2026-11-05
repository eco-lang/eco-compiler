module Compiler.MonoOpt.BorrowFenceTest exposing (suite)

{-| Tests that borrow inference combines the borrow signatures of a lambda-set
member's closures with a meet exactly when the closures differ. Without the
meet, a member whose closures differ could have its borrow signature taken
from one closure alone, and an argument would be reported borrowed by a callee
that takes ownership of it.

A _lambda-set member_ is a number naming one function value, and the graph can
hold several closures that are all instances of the same member.
`Compiler.MonoOpt.Borrow` gives each member one borrow signature. When the
member has one instance, or all its instances have the same
`Compiler.MonoOpt.AbiCloning.instanceFingerprint`, that signature is the
first instance's. Otherwise it is the _meet_ of all of them, in which a
parameter is borrowed only if every instance borrows it, and the run's census
counts the member in `lambdaSigMeets`.

Each reading is taken by `statsOf`, which builds a graph whose only node is a
definition holding a list of closures, and runs `Borrow.run` on it with the
census report on. Every closure is an instance of the one member `member` and
takes one `String` parameter, `x`. Its body is either `owningBody`, which
returns `x`, or `borrowingBody`, which ignores `x` and returns a string
literal.

  - A borrowing instance alone: the one definition is analysed, and no member
    takes the meet. This shows the fixture is analysed at all, so the zero
    counts below are not zero by default.
  - An owning instance followed by a borrowing one: one member takes the meet.
  - A borrowing instance followed by an owning one: one member takes the meet,
    whichever instance comes first.
  - Two instances with the borrowing body, differing only in lambda number:
    their fingerprints agree, so no member takes the meet.

Among what is not tested: the signature the meet produces (that is
`Compiler.MonoOpt.Borrow.LssFacts.meetSig`'s), a member with more than two
instances, captures or more than one parameter.

-}

import Array
import Compiler.Config as Config
import Compiler.Core.Annotation as A
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.Borrow as Borrow
import Data.BitSet as BitSet
import Dict
import Expect
import Test exposing (Test)


{-| The four tests, in the order the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "Fingerprint-fence Borrow meet (buildLambdaSigs)"
        [ Test.test "borrowing-only instance alone: analysed, no meet" <|
            \() ->
                Expect.equal ( 1, 0 )
                    (statsOf [ mkClosure 1 borrowingBody ]
                        |> (\stats -> ( stats.defsAnalyzed, stats.lambdaSigMeets ))
                    )
        , Test.test "divergent pair, owning FIRST: meet" <|
            \() ->
                Expect.equal 1
                    (statsOf [ mkClosure 1 owningBody, mkClosure 2 borrowingBody ]).lambdaSigMeets
        , Test.test "divergent pair, borrowing FIRST: meet (order-independent)" <|
            \() ->
                Expect.equal 1
                    (statsOf [ mkClosure 1 borrowingBody, mkClosure 2 owningBody ]).lambdaSigMeets
        , Test.test "verbatim clones: fence passes, no meet" <|
            \() ->
                Expect.equal 0
                    (statsOf [ mkClosure 1 borrowingBody, mkClosure 2 borrowingBody ]).lambdaSigMeets
        ]



-- ====== FIXTURE MACHINERY ======


{-| The lambda-set member id that every fixture closure is an instance of. The
number has no meaning; no other member appears in the graph.
-}
member : Int
member =
    88881


{-| The module the fixture's anonymous lambdas are named in.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


{-| A body that returns the parameter `x`, so the result aliases the argument
and parameter 0 is owned.
-}
owningBody : Mono.MonoExpr
owningBody =
    Mono.MonoVarLocal "x" Mono.MString


{-| A body that ignores the parameter `x` and returns the string literal `"k"`,
so parameter 0 is borrowed.
-}
borrowingBody : Mono.MonoExpr
borrowingBody =
    Mono.MonoLiteral (Mono.LStr "k") Mono.MString


{-| Builds an instance of `member` with lambda number `uid` and the given
`body`. It takes one `String` parameter, `x`, and has no captures, and its
type's lambda-set annotation names only `member`.
-}
mkClosure : Int -> Mono.MonoExpr -> Mono.MonoExpr
mkClosure uid body =
    Mono.MonoClosure
        { lambdaId = Mono.AnonymousLambda home uid
        , srcLambda = Nothing
        , lssMember = Just member
        , captures = []
        , params = [ ( "x", Mono.MString ) ]
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction (Mono.LSet [ member ]) [ Mono.MString ] Mono.MString)


{-| Returns the census of a borrow-inference run, with the report on, over the
graph `graphOf` builds from `exprs`.
-}
statsOf : List Mono.MonoExpr -> Borrow.BorrowStats
statsOf exprs =
    Tuple.second
        (Borrow.run
            { enabled = True, reify = Config.ROff, report = True, validate = False }
            (graphOf exprs)
        )


{-| Builds a graph whose only node is a definition of a list holding `exprs`,
in order. The list and the definition are typed `List String`, not as lists
of functions. The graph has a dummy main (spec 0) and no ports or call
edges, and its registry and lambda-set tables are empty.
-}
graphOf : List Mono.MonoExpr -> Mono.MonoGraph
graphOf exprs =
    Mono.MonoGraph
        { nodes =
            Array.fromList
                [ Just
                    (Mono.MonoDefine
                        (Mono.MonoList A.zero exprs (Mono.mList Mono.MString))
                        (Mono.mList Mono.MString)
                    )
                ]
        , main = Mono.StaticMain 0
        , registry =
            { nextId = 0
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping = Array.empty
            , countByGlobal = Dict.empty
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 100
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        }
