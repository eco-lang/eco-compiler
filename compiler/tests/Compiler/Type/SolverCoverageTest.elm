module Compiler.Type.SolverCoverageTest exposing (suite)

{-| Type checks programs built to reach the less common paths of the type
checker's unifier and solver: every pairing of the constrained type
variables `number`, `comparable`, `appendable` and `compappend`, constrained
variables against lists and tuples, rigid variables and aliases against a
variable whose unification already failed, extensible records whose extension
is an alias, constructors whose types use constrained or extensible type
variables, and `let`s nested deeper than the solver's initial eight ranks.

Each case is the source text of a module named `Test`, parsed as an
application module and canonicalized against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`, with the default imports of modules
those interfaces lack dropped. A case is either accepted or rejected:

  - an accepted case must type check along the erased path
    (`Compiler.Type.Solve.run`, as `Compiler.Compile.typeCheck` runs it) and
    along the typed path (`TestLogic.TestPipeline.runToPostSolve`);
  - a rejected case must fail type checking along the erased path. Which
    error is reported is not checked here; the reports are the business of
    `Compiler.Type.ErrorReportCoverageTest`.

Among what is not tested: lambda sets and set-carrying arrows, which only the
monomorphizer's solver creates in the shared store.

-}

import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Solve as Solve
import Compiler.Type.State.IO as IO
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| Whether a case must type check or must be rejected.
-}
type Outcome
    = Accepted
    | Rejected


{-| One case: its label, what type checking must do with it, and its source
after the header `module Test exposing (..)`.
-}
type alias Case =
    { label : String
    , outcome : Outcome
    , body : String
    }


{-| One test per case, under a label that contains "coverage run" so that the
coverage loop's quick run includes it.
-}
suite : Test
suite =
    Test.describe "Solver paths (coverage run)"
        (List.map caseTest allCases)


{-| The test of one case: see the module documentation.
-}
caseTest : Case -> Test
caseTest c =
    Test.test c.label <|
        \_ ->
            case parse c.body of
                Err message ->
                    Expect.fail message

                Ok srcModule ->
                    case ( c.outcome, erasedCheck srcModule ) of
                        ( Accepted, Ok () ) ->
                            case Pipeline.runToPostSolve srcModule of
                                Ok _ ->
                                    Expect.pass

                                Err message ->
                                    Expect.fail ("typed path: " ++ message)

                        ( Accepted, Err message ) ->
                            Expect.fail message

                        ( Rejected, Ok () ) ->
                            Expect.fail "the case type checks"

                        ( Rejected, Err _ ) ->
                            Expect.pass


{-| Parses `body` after the module header, keeping only the imports the mock
interfaces can resolve.
-}
parse : String -> Result String Src.Module
parse body =
    case Parse.fromByteString Parse.Application ("module Test exposing (..)\n\n" ++ body) of
        Err _ ->
            Err "the case does not parse"

        Ok (Src.Module m) ->
            Ok (Src.Module { m | imports = List.filter isMockImport m.imports })


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| Canonicalizes `srcModule` and type checks it along the erased path, giving
a message when either step fails.
-}
erasedCheck : Src.Module -> Result String ()
erasedCheck srcModule =
    case RResult.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        Err _ ->
            Err "the case does not canonicalize"

        Ok canonical ->
            case IO.unsafePerformIO (TypeErased.constrain canonical |> IO.andThen Solve.run) of
                Ok _ ->
                    Ok ()

                Err _ ->
                    Err "type checking fails"


{-| Every case, by group.
-}
allCases : List Case
allCases =
    superCases ++ structureCases ++ errorCases ++ recordCases ++ declarationCases



-- ============================================================================
-- CONSTRAINED TYPE VARIABLES
-- ============================================================================


{-| A local function's two parameters, each constrained by how it is used, put
in one list in both orders, so that unification meets each pair of
constraints with either one first. `n` is a `number` (`n + 1`), `c` a
`comparable` (`c < c`), `p` an `appendable` (`p ++ p`) and `q` a `compappend`
(`q ++ q` and `q < q`).
-}
superCases : List Case
superCases =
    let
        num =
            "(n + 1)"

        cmp =
            "(if c < c then c else c)"

        app =
            "(p ++ p)"

        cap =
            "(if q ++ q < q then q else q)"

        pair outcome x y labelX labelY =
            [ Case (labelX ++ " then " ++ labelY) outcome ("f n c p q = [ " ++ x ++ ", " ++ y ++ " ]\n")
            , Case (labelY ++ " then " ++ labelX) outcome ("f n c p q = [ " ++ y ++ ", " ++ x ++ " ]\n")
            ]
    in
    pair Accepted cmp cap "comparable" "compappend"
        ++ pair Accepted app cap "appendable" "compappend"
        ++ pair Accepted cap cap "compappend" "second compappend"
        ++ pair Accepted cmp app "comparable" "appendable"
        ++ pair Accepted num cmp "number" "comparable"
        ++ pair Rejected num cap "number" "compappend"
        ++ pair Rejected num app "number" "appendable"



-- ============================================================================
-- STRUCTURES
-- ============================================================================


{-| Constrained variables against lists and tuples, and a `comparable` that
would have to contain itself.
-}
structureCases : List Case
structureCases =
    [ Case "compappend as a list" Accepted "f q = [ (if q ++ q < q then q else q), [ 1 ] ]\n"
    , Case "list as a compappend" Accepted "f q = [ [ 1 ], (if q ++ q < q then q else q) ]\n"
    , Case "appendable as a tuple" Rejected "f p = [ p ++ p, ( 1, 2 ) ]\n"
    , Case "tuple as an appendable" Rejected "f p = [ ( 1, 2 ), p ++ p ]\n"
    , Case "compappend as a tuple" Rejected "f q = [ (if q ++ q < q then q else q), ( 1, 2 ) ]\n"
    , Case "tuple as a compappend" Rejected "f q = [ ( 1, 2 ), (if q ++ q < q then q else q) ]\n"
    , Case "comparable as a tuple" Accepted "f c = [ (if c < c then c else c), ( 1, 2 ) ]\n"
    , Case "comparable containing itself" Rejected "f x = x < [ x ]\n"
    , Case "comparable list containing itself" Rejected "f x = [ x ] < x\n"
    , Case "empty record under an empty record annotation" Accepted "x : {}\nx = {}\n"
    , Case "empty record as an argument" Accepted "f : {} -> Int\nf r = 0\n\ny = f {}\n"
    , Case "rigid var then rigid number" Rejected "f : a -> number -> List a\nf x y = [ x, y ]\n"
    , Case "rigid number then rigid var" Rejected "f : a -> number -> List a\nf x y = [ y, x ]\n"
    , Case "deeply nested lets" Accepted deepLets
    , Case "second compappend variable" Accepted "f q r = [ (if q ++ q < q then q else q), (if r ++ r < r then r else r) ]\n"
    , Case "comparable of a cyclic list" Rejected "f x = if x == [ x ] then x < x else False\n"
    , Case "empty record against an emptied extension" Accepted "g : { r | a : Int } -> r -> Int\ng x y = 0\n\nz = g { a = 1 } {}\n"
    , Case "emptied extension against an empty record" Accepted "g : r -> { r | a : Int } -> Int\ng y x = 0\n\nz = g {} { a = 1 }\n"
    , Case "let-polymorphic function returning a unit" Accepted "f x =\n    let\n        g y = ( y, () )\n    in\n    ( g 1, g \"a\" )\n"
    , Case "let-polymorphic function returning an empty record" Accepted "f x =\n    let\n        g y = ( y, {} )\n    in\n    ( g 1, g \"a\" )\n"
    , Case "shader of every GLSL type" Accepted shader
    , Case "rigid var then alias" Rejected "type alias N = Int\n\nn : N\nn = 1\n\nf : a -> List a\nf x = [ x, n ]\n"
    , Case "alias then rigid var" Rejected "type alias N = Int\n\nn : N\nn = 1\n\nf : a -> List a\nf x = [ n, x ]\n"
    ]


{-| A shader whose attributes, uniforms and varyings use every GLSL type the
type checker maps to an Elm type.
-}
shader : String
shader =
    "s =\n    [glsl|\nattribute vec2 a2;\nattribute vec3 a3;\nattribute vec4 a4;\nuniform mat4 m;\nuniform int i;\nuniform float f;\nuniform sampler2D t;\nuniform bool b;\nvarying vec3 v;\nvoid main () { gl_Position = vec4(a3, 1.0); }\n|]\n"


{-| A function whose local function's body defines a local function, and so
on twelve deep, so that solving the innermost definition needs more ranks than
the solver's initial eight pools.
-}
deepLets : String
deepLets =
    let
        level i inner =
            "let g"
                ++ String.fromInt i
                ++ " y"
                ++ String.fromInt i
                ++ " = "
                ++ inner
                ++ " in g"
                ++ String.fromInt i
                ++ " y"
                ++ String.fromInt (i - 1)
    in
    "f y0 =\n    " ++ List.foldr level "y12" (List.range 1 12) ++ "\n"



-- ============================================================================
-- FAILED UNIFICATIONS
-- ============================================================================


{-| A rigid variable and an alias unified, in either order, with the element
of a list whose two entries could not be unified, which leaves the element's
variable holding `Error`.
-}
errorCases : List Case
errorCases =
    let
        withHead annotation result =
            annotation
                ++ "f x =\n    case [ 1, \"a\" ] of\n        h :: _ ->\n            "
                ++ result
                ++ "\n\n        [] ->\n            []\n"
    in
    [ Case "rigid var then unknown" Rejected (withHead "f : a -> List a\n" "[ x, h ]")
    , Case "unknown then rigid var" Rejected (withHead "f : a -> List a\n" "[ h, x ]")
    , Case "alias then unknown" Rejected ("type alias N = Int\n\nn : N\nn = 1\n\n" ++ withHead "" "[ n, h ]")
    , Case "unknown then alias" Rejected ("type alias N = Int\n\nn : N\nn = 1\n\n" ++ withHead "" "[ h, n ]")
    ]



-- ============================================================================
-- RECORDS
-- ============================================================================


{-| Extensible records whose extension is itself an alias.
-}
recordCases : List Case
recordCases =
    [ Case "field of an alias extension"
        Accepted
        "type alias P = { age : Int }\n\ntype alias Named r = { r | name : Int }\n\nv : Named P\nv = { name = 1, age = 2 }\n\nx = v.age\n"
    , Case "alias extension passed on"
        Accepted
        "type alias P = { age : Int }\n\ntype alias Named r = { r | name : Int }\n\nv : Named P\nv = { name = 1, age = 2 }\n\ng : { r | age : Int } -> Int\ng r = r.age\n\nx = g v\n"
    ]



-- ============================================================================
-- DECLARATIONS
-- ============================================================================


{-| Constructors whose types use a `compappend` type variable, an extensible
record and an alias without parameters, so that the solver instantiates each
from the constructor's annotation.
-}
declarationCases : List Case
declarationCases =
    [ Case "constructor with a compappend variable" Accepted "type Box compappend = Box compappend\n\nx = Box \"a\"\n"
    , Case "constructor with an extensible record" Accepted "type W r = W { r | a : Int }\n\nx = W { a = 1, b = 2 }\n"
    , Case "constructor with an alias argument" Accepted "type alias P = { a : Int }\n\ntype T = T P\n\nx = T { a = 1 }\n"
    , Case "constructor with a parameterised alias argument" Accepted "type alias Q a = { a : a }\n\ntype T = T (Q Int)\n\nx = T { a = 1 }\n"
    , Case "unnamed comparable in an error" Rejected "f x = ( [ x ] < [ x ], not x, x ++ \"s\" )\n"
    , Case "flex var named twice in an error" Rejected "id1 : a -> a\nid1 v = v\n\nx : Int\nx = id1\n"
    ]
