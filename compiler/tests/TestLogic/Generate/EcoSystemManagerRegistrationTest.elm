module TestLogic.Generate.EcoSystemManagerRegistrationTest exposing (suite)

{-| Tests that the generated module registers each eco/system effect manager
before the program starts.

An _effect-manager leaf_ is a `Mono.MonoManagerLeaf` node: a command or
subscription of a module with an effect manager. When the registry key of a
leaf names a module of package eco/system, the generated preamble
`@__eco_register_ports` calls `@Eco_System_registerManager_<home>`, where
`<home>` is the module name with every `.` replaced by `_`.

The fixtures are graphs built by `generate`, holding only the given leaves, an
extern `Main.main` and, optionally, a flags decoder. Each is printed with
`Backend.generateProgram`, and the tests read the printed MLIR text.

  - Two eco/system leaves of the module `System` give exactly one registration
    call in the preamble, and it is the preamble's first call.
  - A leaf of `Socket.Udp` registers `Eco_System_registerManager_Socket_Udp`.
  - With a flags decoder, the preamble's calls are, in order, the registration,
    the decoder's value (the leaf's own specialization), and
    `Elm_Kernel_Platform_registerFlagsDecoder`.
  - With a manager leaf and no ports or flags, `main` calls the preamble and then
    `Main.main`.
  - An elm/time `Time` leaf gives no registration symbol anywhere in the text, no
    preamble, and a `main` that calls only `Main.main`.

Among what is not tested: ports alongside a manager, leaves of two different
eco/system modules, and the streaming writers.

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
                registerPortsBody (generate [ ecoSystemLeaf "Socket.Udp" "subscription" ] False)
                    |> Maybe.map (List.filter isManagerRegistration << callees)
                    |> Expect.equal (Just [ "Eco_System_registerManager_Socket_Udp" ])
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


{-| An effect-manager leaf to put in a fixture: the package and module that own
it and the name of the command or subscription.
-}
type alias Leaf =
    { pkg : Pkg.Name
    , home : String
    , name : String
    }


{-| Returns a leaf named `name` in module `home` of package eco/system.
-}
ecoSystemLeaf : String -> String -> Leaf
ecoSystemLeaf home name =
    { pkg = Pkg.ecoSystem, home = home, name = name }


{-| A leaf of elm/time: `Time.every`.
-}
timeLeaf : Leaf
timeLeaf =
    { pkg = ( "elm", "time" ), home = "Time", name = "every" }


{-| A leaf's type: one boxed argument to a boxed result, as `Elm_Kernel_Platform_leaf`
expects.
-}
leafType : Mono.MonoType
leafType =
    Mono.mFunction Mono.topPoison [ Mono.MString ] Mono.MString


{-| Returns the printed MLIR module for a graph holding `leaves`, in order, and
an extern `Main.main` as the static main. When `withFlags` is true, the graph's
flags decoder is the first leaf's specialization, which serves only as a
function to name.
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


{-| Returns the printed text of the function whose `sym_name` is `name`, or
`Nothing` when `text` has none. The text is split at each `"func.func"() (`, the
prefix the generic MLIR form prints before every function, and the first chunk
containing the symbol name is returned.
-}
funcBody : String -> String -> Maybe String
funcBody name text =
    String.split "\"func.func\"() (" text
        |> List.filter (String.contains ("sym_name = \"" ++ name ++ "\""))
        |> List.head


{-| Returns the printed text of the `@__eco_register_ports` preamble, if any.
-}
registerPortsBody : String -> Maybe String
registerPortsBody =
    funcBody "__eco_register_ports"


{-| Returns the callee symbols named in `body`, in the order they appear, each
read from a `callee = @` up to the next `}`.
-}
callees : String -> List String
callees body =
    String.split "callee = @" body
        |> List.drop 1
        |> List.map (String.split "}" >> List.head >> Maybe.withDefault "")


{-| Tells whether a callee symbol is an eco/system manager registration.
-}
isManagerRegistration : String -> Bool
isManagerRegistration =
    String.startsWith "Eco_System_registerManager_"
