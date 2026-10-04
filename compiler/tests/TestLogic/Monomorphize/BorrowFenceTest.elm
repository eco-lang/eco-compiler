module TestLogic.Monomorphize.BorrowFenceTest exposing (suite)

{-| Tests that borrow inference does not report a parameter of a lambda-set
member as borrowed when only some of the member's closures borrow it. Without
them, a member whose closures differ could have its borrow signature taken
from one closure alone, and an argument would be reported borrowed by a callee
that takes ownership of it.

A _lambda-set member_ is a number naming one function value, and the graph can
hold several closures that are all instances of the same member. A parameter
is _borrowed_ when the callee does not take ownership of the argument.
`Compiler.GlobalOpt.Borrow.deriveFacts` stores one borrow signature per member.
When the member has one instance, or all its instances have the same
`Compiler.GlobalOpt.AbiCloning.instanceFingerprint`, that signature is the
first instance's. Otherwise it is the _meet_ of all of them, in which a
parameter is borrowed only if every instance borrows it. `Compiler.GlobalOpt.Borrow`
owns this rule.

Each reading is taken by `borrowedOf`, which builds a graph whose only node is
a definition holding a list of closures. Every closure is an instance of the
one member `member` and takes one `String` parameter, `x`. Its body is either
`owningBody`, which returns `x`, or `borrowingBody`, which ignores `x` and
returns a string literal. `borrowedOf` runs `deriveFacts` on the graph and
reads the member's wholly borrowed parameters (as
`Compiler.GlobalOpt.Borrow.Facts` defines them) with
`Facts.borrowedParamsOfLambda`. The last test takes two readings, each on its
own graph, and compares them.

  - A borrowing instance alone reads back parameter 0 as wholly borrowed. This
    shows the fixture can produce a borrowed reading, so the empty readings
    below are not empty by default.
  - An owning instance alone reads back no wholly borrowed parameter.
  - An owning instance followed by a borrowing one reads back no wholly
    borrowed parameter.
  - A borrowing instance followed by an owning one also reads back none.
    Swapping the order swaps which instance comes first, so if the stored
    signature were the first instance's alone, one of these two tests would
    read back parameter 0.
  - Two instances with the borrowing body, differing only in lambda number,
    read back the same set as one borrowing instance.

Among what is not tested: whether identical instances take the
single-signature path or the meet, since the meet of two equal signatures
gives the same reading; the meet of result modes; a member with more than two
instances, captures or more than one parameter; and the count of members that
took the meet.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.Borrow.Facts as Facts
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import Set
import Test exposing (Test)


{-| The five tests, in the order the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "LSS_024 Borrow fence (buildLambdaSigs)"
        [ Test.test "borrowing-only instance alone: param reads back borrowed" <|
            \() ->
                Expect.equal (Set.fromList [ 0 ])
                    (borrowedOf [ mkClosure 1 borrowingBody ])
        , Test.test "owning-only instance alone: param reads back NOT borrowed" <|
            \() ->
                Expect.equal Set.empty
                    (borrowedOf [ mkClosure 1 owningBody ])
        , Test.test "divergent pair, owning FIRST: meet — param not borrowed" <|
            \() ->
                Expect.equal Set.empty
                    (borrowedOf [ mkClosure 1 owningBody, mkClosure 2 borrowingBody ])
        , Test.test "divergent pair, borrowing FIRST: meet — param STILL not borrowed (order-independent)" <|
            \() ->
                Expect.equal Set.empty
                    (borrowedOf [ mkClosure 1 borrowingBody, mkClosure 2 owningBody ])
        , Test.test "verbatim clones: fence passes, facts equal the single-instance build" <|
            \() ->
                Expect.equal
                    (borrowedOf [ mkClosure 1 borrowingBody ])
                    (borrowedOf [ mkClosure 1 borrowingBody, mkClosure 2 borrowingBody ])
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
and parameter 0 is not wholly borrowed.
-}
owningBody : Mono.MonoExpr
owningBody =
    Mono.MonoVarLocal "x" Mono.MString


{-| A body that ignores the parameter `x` and returns the string literal `"k"`,
so parameter 0 is wholly borrowed.
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


{-| Returns the positions of the parameters of `member` that `deriveFacts`
reports wholly borrowed, on a graph built from `exprs` by `graphOf`.
-}
borrowedOf : List Mono.MonoExpr -> Set.Set Int
borrowedOf exprs =
    Facts.borrowedParamsOfLambda (Borrow.deriveFacts (graphOf exprs)) member


{-| Builds a graph whose only node is a definition of a list holding `exprs`,
in order. The list and the definition are typed `List String`, not as lists
of functions. The graph has no main, ports or call edges, and its registry
and lambda-set tables are empty.
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
        , main = Nothing
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
