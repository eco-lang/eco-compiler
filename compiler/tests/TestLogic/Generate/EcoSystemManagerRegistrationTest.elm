module TestLogic.Generate.EcoSystemManagerRegistrationTest exposing (suite)

{-| Pins the registration of eco/system effect managers in the
`@__eco_register_ports` preamble (plans/eco-system-library.md §3.6, Phase 1
step 1.6).

An effect-manager leaf (`Mono.MonoManagerLeaf`) whose home module belongs to
package `eco/system` makes the generated module call
`@Eco_System_registerManager_<Home with . replaced by _>()` once, as the first
operation of `@__eco_register_ports`, so that the C++ manager is in the
runtime's table before `initWorker` reads it. A leaf of any other package
(elm/time's `Time`) registers nothing; its manager is built into the runtime.

The fixtures are hand-built `MonoGraph`s run through
`Compiler.Generate.MLIR.Backend.generateMlirModule`, the same per-node code
generator and context threading the streaming writers use. The checks read the
printed MLIR text.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.Backend as Backend
import Compiler.Generate.Mode as Mode
import Compiler.Monomorphize.Registry as Registry
import Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "eco/system effect-manager registration (eco-system-library §3.6)"
        [ Test.test "two eco/system leaves of one home emit exactly one registration call, inside the preamble" <|
            \_ ->
                let
                    preamble =
                        registerPortsBody (generate [ ecoSystemLeaf "System" "command", ecoSystemLeaf "System" "subscription" ] False)
                in
                Expect.all
                    [ \body -> Expect.equal (Just [ "Eco_System_registerManager_System" ]) (Maybe.map (List.filter isManagerRegistration << callees) body)
                    , \body -> Expect.equal (Just (Just "Eco_System_registerManager_System")) (Maybe.map (List.head << callees) body)
                    ]
                    preamble
        , Test.test "a dotted home maps . to _ in the symbol" <|
            \_ ->
                registerPortsBody (generate [ ecoSystemLeaf "System.Process" "command" ] False)
                    |> Maybe.map (List.filter isManagerRegistration << callees)
                    |> Expect.equal (Just [ "Eco_System_registerManager_System_Process" ])
        , Test.test "the registration comes first, before the flags decoder registration" <|
            \_ ->
                case registerPortsBody (generate [ ecoSystemLeaf "System" "command" ] True) of
                    Nothing ->
                        Expect.fail "no @__eco_register_ports function was emitted"

                    Just body ->
                        -- The flags decoder's value thunk is the leaf spec here.
                        Expect.equal
                            [ "Eco_System_registerManager_System", "System_command_$_0", "Elm_Kernel_Platform_registerFlagsDecoder" ]
                            (callees body)
        , Test.test "the main entry calls the preamble when only a manager needs it" <|
            \_ ->
                generate [ ecoSystemLeaf "System" "command" ] False
                    |> funcBody "main"
                    |> Maybe.map callees
                    |> Expect.equal (Just [ "__eco_register_ports", "Main_main_$_1" ])
        , Test.test "a non-eco/system leaf (elm/time Time) emits no registration and no preamble" <|
            \_ ->
                let
                    text =
                        generate [ timeLeaf ] False
                in
                Expect.all
                    [ \t -> Expect.equal [] (String.indexes "Eco_System_registerManager_" t)
                    , \t -> Expect.equal Nothing (registerPortsBody t)
                    , \t -> Expect.equal (Just [ "Main_main_$_1" ]) (Maybe.map callees (funcBody "main" t))
                    ]
                    text
        ]



-- ====== FIXTURES ======


type alias Leaf =
    { pkg : Pkg.Name
    , home : String
    , name : String
    }


ecoSystemLeaf : String -> String -> Leaf
ecoSystemLeaf home name =
    { pkg = Pkg.ecoSystem, home = home, name = name }


timeLeaf : Leaf
timeLeaf =
    { pkg = ( "elm", "time" ), home = "Time", name = "every" }


{-| A leaf's type: one boxed argument to a boxed result, as `Elm_Kernel_Platform_leaf`
expects.
-}
leafType : Mono.MonoType
leafType =
    Mono.mFunction Mono.topPoison [ Mono.MString ] Mono.MString


{-| Builds a graph with the given leaves plus a `Main.main` (an extern, so it
needs no body), and, when `withFlags`, a flags decoder (the first leaf's spec,
which only has to name a function), then prints the generated module.
-}
generate : List Leaf -> Bool -> String
generate leaves withFlags =
    let
        ( leafIds, registry1 ) =
            List.foldl
                (\leaf ( ids, reg ) ->
                    let
                        ( id, reg1 ) =
                            Registry.getOrCreateSpecId
                                (Mono.Global (ModuleName.Canonical leaf.pkg leaf.home) leaf.name)
                                leafType
                                reg
                    in
                    ( ids ++ [ ( id, leaf ) ], reg1 )
                )
                ( [], Registry.emptyRegistry )
                leaves

        ( mainId, registry2 ) =
            Registry.getOrCreateSpecId
                (Mono.Global (ModuleName.Canonical Pkg.dummyName "Main") "main")
                Mono.MUnit
                registry1

        nodes =
            Array.fromList
                (List.map (\( _, leaf ) -> Just (Mono.MonoManagerLeaf leaf.home leafType)) leafIds
                    ++ [ Just (Mono.MonoExtern Mono.MUnit) ]
                )

        graph =
            Mono.MonoGraph
                { nodes = nodes
                , main = Just (Mono.StaticMain mainId)
                , registry = registry2
                , ctorShapes = Mono.layoutMapEmpty
                , nextLambdaIndex = 0
                , callEdges = Array.repeat (Array.length nodes) Nothing
                , specHasEffects = BitSet.empty
                , specValueUsed = BitSet.empty
                , ports = []
                , flagsDecoder =
                    if withFlags then
                        List.head (List.map Tuple.first leafIds)

                    else
                        Nothing
                , lssMemberOrigins = Dict.empty
                , lssMemberKinds = Dict.empty
                , lssBlockedMembers = Dict.empty
                }
    in
    Backend.generateProgram Config.default (Mode.Dev Nothing) graph



-- ====== TEXT HELPERS ======


{-| The printed body of the top-level `func.func` whose `sym_name` is `name`,
or `Nothing` when the module has none. The generic MLIR form prints each
function as `"func.func"() ({ body }) {attrs}`, so the module text splits into
one chunk per function on that prefix.
-}
funcBody : String -> String -> Maybe String
funcBody name text =
    String.split "\"func.func\"() (" text
        |> List.filter (String.contains ("sym_name = \"" ++ name ++ "\""))
        |> List.head


registerPortsBody : String -> Maybe String
registerPortsBody =
    funcBody "__eco_register_ports"


{-| The callees of the `eco.call`s in a function body, in order.
-}
callees : String -> List String
callees body =
    String.split "callee = @" body
        |> List.drop 1
        |> List.map (String.split "}" >> List.head >> Maybe.withDefault "")


isManagerRegistration : String -> Bool
isManagerRegistration =
    String.startsWith "Eco_System_registerManager_"
