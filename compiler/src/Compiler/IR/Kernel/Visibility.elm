module Compiler.IR.Kernel.Visibility exposing
    ( TypeRef, KernelUse(..)
    , kernelOwned, isKernelOwned, checkedSafe
    , kernelUse, managerUses
    )

{-| What the C++ kernels know about Elm values, for the passes that change how
a custom type is represented (plans/constructor-representation-levels.md §4).

A pass may change a type's representation only if no kernel builds, reads, or
receives a value of that type in a known shape. This module is the table those
passes consult; `Compiler.MonoOpt.KernelVisible` turns it into the set of type
constructors a program must leave alone.

A type is named by a `TypeRef`, the pair of its home module as
`ModuleName.toComparableCanonical` writes it (`"elm/core:Platform"`) and its
type name.

  - `kernelOwned` lists types whose values a kernel produces or reads by name.
    Their representation never changes, and a `Maybe` of one never becomes
    nullable, because the kernel chooses the value's word, which can be the
    Empty constant (`type Bytes = Bytes`). The list holds every type with one
    constructor declared in a module that imports a kernel module, as
    `scripts/check-kernel-opaque.py` finds them, except those in
    `checkedSafe`, plus the types compiler or kernel code matches by name.
  - `checkedSafe` lists the types of that scan that were read and found not to
    be built or read by any kernel, each with the reason.
  - `kernelUse` says, for a kernel function, whether it is `Transparent`
    (it only moves its type-variable values, or compares them generically) or
    `Inspects` a known list of types. A kernel it has no entry for is treated
    as building and reading every type in its signature.
  - `managerUses` lists, for an effect manager's home module, the types its
    C++ manager reads or builds.

Every entry cites the C++ that justifies it.

@docs TypeRef, KernelUse
@docs kernelOwned, isKernelOwned, checkedSafe
@docs kernelUse, managerUses

-}

import Dict exposing (Dict)
import Set exposing (Set)


{-| A type, by its home module (`ModuleName.toComparableCanonical`) and name.
-}
type alias TypeRef =
    ( String, String )


{-| What a kernel function does with the values it is given and returns.
`Transparent` means it never builds or looks inside a custom value;
`Inspects` lists the types it does build or look inside.
-}
type KernelUse
    = Transparent
    | Inspects (List TypeRef)


{-| Returns whether the type `home`.`name` is in `kernelOwned`.
-}
isKernelOwned : String -> String -> Bool
isKernelOwned home name =
    Set.member ( home, name ) kernelOwned


{-| Types whose representation must never change; see the module docs.
-}
kernelOwned : Set TypeRef
kernelOwned =
    Set.fromList
        [ -- Matched by name in compiler or C++ code.
          -- BytesFusion (Reify.elm isBytesDecodeGlobal "Decoder"), Expr.elm projects field 0.
          ( "elm/bytes:Bytes.Decode", "Decoder" )

        -- JsonExports.cpp builds Array_elm_builtin; RuntimeExports.cpp builtin_container_of prints it.
        , ( "elm/core:Array", "Array" )

        -- Reserved tags (CtorTag.elm), Utils.cpp eqHelp/FNV special cases, HttpExports.cpp builds nodes.
        , ( "elm/core:Dict", "Dict" )
        , ( "eco/system:SeqDict", "SeqDict" )
        , ( "eco/system:SeqDict", "Node" )

        -- From scripts/check-kernel-opaque.py: dummy declarations of kernel-produced values,
        -- and types the kernels build or read.
        , ( "eco/system:ChildProcess", "MyCmd" )
        , ( "eco/system:FileSystem", "Event" )
        , ( "eco/system:FileSystem", "MySub" )
        , ( "eco/system:FileSystem.Handle", "Handle" )
        , ( "eco/system:FileSystem.Handle", "ReadAccess" )
        , ( "eco/system:FileSystem.Handle", "WriteAccess" )
        , ( "eco/system:Html.Dom", "Handler" )
        , ( "eco/system:Html.Dom", "Tagger" )
        , ( "eco/system:Http.Server", "Error" )
        , ( "eco/system:Http.Server", "Event" )
        , ( "eco/system:Http.Server", "MyCmd" )
        , ( "eco/system:Http.Server", "MySub" )
        , ( "eco/system:Http.Server", "Server" )
        , ( "eco/system:Http.Stream", "Expect" )
        , ( "eco/system:Http.Stream", "Resolver" )
        , ( "eco/system:JsArray2", "JsArray2" )
        , ( "eco/system:Socket", "Event" )
        , ( "eco/system:Socket", "MySub" )
        , ( "eco/system:Socket.Udp", "Event" )
        , ( "eco/system:Socket.Udp", "MySub" )
        , ( "eco/system:System", "MyCmd" )
        , ( "eco/system:Terminal", "Event" )
        , ( "eco/system:Terminal", "MySub" )
        , ( "eco/system:WebSocket", "Streamed" )
        , ( "eco/system:WebSocket", "Whole" )
        , ( "elm-explorations/linear-algebra:Math.Matrix4", "Mat4" )
        , ( "elm-explorations/linear-algebra:Math.Vector2", "Vec2" )
        , ( "elm-explorations/linear-algebra:Math.Vector3", "Vec3" )
        , ( "elm-explorations/linear-algebra:Math.Vector4", "Vec4" )
        , ( "elm-explorations/webgl:WebGL", "Entity" )
        , ( "elm-explorations/webgl:WebGL", "Shader" )
        , ( "elm-explorations/webgl:WebGL.Texture", "Bigger" )
        , ( "elm-explorations/webgl:WebGL.Texture", "Resize" )
        , ( "elm-explorations/webgl:WebGL.Texture", "Smaller" )
        , ( "elm-explorations/webgl:WebGL.Texture", "Texture" )
        , ( "elm-explorations/webgl:WebGL.Texture", "Wrap" )

        -- BrowserExports.cpp:27 builds NotFound.
        , ( "elm/browser:Browser.Dom", "Error" )
        , ( "elm/browser:Browser.Events", "MySub" )
        , ( "elm/browser:Browser.Navigation", "Key" )
        , ( "elm/browser:Debugger.Main", "Popout" )
        , ( "elm/bytes:Bytes", "Bytes" )
        , ( "elm/core:Elm.JsArray", "JsArray" )
        , ( "elm/core:Platform", "ProcessId" )
        , ( "elm/core:Platform", "Program" )
        , ( "elm/core:Platform", "Router" )
        , ( "elm/core:Platform", "Task" )
        , ( "elm/core:Platform.Cmd", "Cmd" )
        , ( "elm/core:Platform.Sub", "Sub" )

        -- TaskEffectManager.cpp:105,155,171 reads and rebuilds Perform.
        , ( "elm/core:Task", "MyCmd" )
        , ( "elm/file:File", "File" )
        , ( "elm/http:Http", "Body" )
        , ( "elm/http:Http", "Expect" )
        , ( "elm/http:Http", "Header" )
        , ( "elm/http:Http", "MySub" )
        , ( "elm/http:Http", "Part" )
        , ( "elm/http:Http", "Resolver" )
        , ( "elm/json:Json.Decode", "Decoder" )
        , ( "elm/json:Json.Encode", "Value" )
        , ( "elm/regex:Regex", "Regex" )

        -- TimeEffectManager.cpp:209-215 builds Posix; TimeExports.cpp:56-77 builds Zone.
        , ( "elm/time:Time", "MySub" )
        , ( "elm/time:Time", "Posix" )
        , ( "elm/time:Time", "Zone" )
        , ( "elm/virtual-dom:VirtualDom", "Attribute" )
        , ( "elm/virtual-dom:VirtualDom", "Node" )
        ]


{-| Types the kernel scan finds that no kernel builds or reads, with the reason.
`scripts/check-kernel-opaque.py` accepts a type listed here or in
`kernelOwned`.
-}
checkedSafe : List ( TypeRef, String )
checkedSafe =
    [ ( ( "elm/core:Basics", "Int" ), "primitive" )
    , ( ( "elm/core:Basics", "Float" ), "primitive" )
    , ( ( "elm/core:Basics", "Never" ), "uninhabited" )
    , ( ( "elm/core:Char", "Char" ), "primitive" )
    , ( ( "elm/core:String", "String" ), "primitive" )
    , ( ( "elm/parser:Parser.Advanced", "Parser" ), "Elm.Kernel.Parser takes and returns strings, ints and tuples only (ParserExports.cpp)" )
    , ( ( "elm/parser:Parser.Advanced", "Token" ), "built and read by Elm code only" )
    , ( ( "eco/kernel:Eco.Console", "Handle" ), "the kernel takes and returns the raw Int id; Elm code wraps it" )
    , ( ( "eco/kernel:Eco.File", "Handle" ), "the kernel takes and returns the raw Int id; Elm code wraps it" )
    , ( ( "eco/kernel:Eco.MVar", "MVar" ), "MVarExports.cpp:30 takes the raw Int id; Elm code wraps it" )
    , ( ( "eco/kernel:Eco.Process", "ProcessHandle" ), "the kernel takes and returns the raw Int id; Elm code wraps it" )
    ]


{-| What each kernel function, by home and name, does with custom values. A
kernel absent from this table is treated as building and reading every type
in its signature.
-}
kernelUse : Dict ( String, String ) KernelUse
kernelUse =
    Dict.fromList
        ([ -- ListExports.cpp:546-552 stores the head without looking at it; the other list
           -- kernels move cells (ListOps) or call closures (map2..map5, sortBy/sortWith compare keys).
           ( "List", [ "cons", "reverse", "append", "concat", "take", "drop", "fromArray", "toArray", "map2", "map3", "map4", "map5", "sortBy", "sortWith" ] )

         -- JsArrayExports.cpp:383-938 store, move and pass elements to closures.
         , ( "JsArray", [ "empty", "singleton", "length", "initialize", "initializeFromList", "unsafeGet", "unsafeSet", "push", "foldl", "foldr", "map", "indexedMap", "slice", "appendN" ] )

         -- SchedulerExports.cpp:16-55 wrap the value in a private Task.
         , ( "Scheduler", [ "succeed", "fail", "andThen", "onError", "spawn", "kill", "sleep", "rawSpawn", "rawSend", "send", "binding", "receive" ] )

         -- MVarExports.cpp:22-67 keep the value off-heap without looking at it (a primitive is boxed
         -- first, by the `put_Int`/`put_Float`/`put_Char` variants) and hand it back in a Task.
         , ( "MVar", [ "new", "read", "take", "put", "drop" ] )

         -- PlatformExports.cpp:97-102 pass the message along.
         , ( "Platform", [ "sendToApp", "sendToSelf" ] )

         -- Generic walks (Utils.cpp:533-700): agnostic while both sides share one representation,
         -- which the representation passes guarantee for every view of a value (MONO_029).
         , ( "Utils", [ "equal", "notEqual", "compare", "cmp3", "lt", "le", "gt", "ge", "append" ] )

         -- Number dispatch only.
         , ( "Basics", [ "add", "sub", "mul", "fdiv", "idiv", "pow", "modBy", "remainderBy", "negate", "abs", "toFloat", "round", "floor", "ceiling", "truncate", "sqrt", "logBase", "e", "pi", "cos", "sin", "tan", "acos", "asin", "atan", "atan2", "isNaN", "isInfinite", "and", "or", "xor", "not", "max", "min", "clamp", "identity", "always" ] )

         -- Ignores its argument.
         , ( "Debug", [ "todo" ] )

         -- Never return: `System.Crash.crash : String -> a` reports and exits (eco/kernel), and
         -- `Bytes.decodeFailure` throws BytesDecodeFailure (BytesOps.hpp); neither builds or reads a
         -- value of the type variable.
         , ( "Crash", [ "crash" ] )
         , ( "Bytes", [ "decodeFailure" ] )

         -- Print through the type table, which describes erased wrappers and nullable Maybes
         -- (plans/constructor-representation-levels.md E2, N1).
         , ( "Debug", [ "log", "toString" ] )
         ]
            |> List.concatMap (\( home, names ) -> List.map (\n -> ( ( home, n ), Transparent )) names)
        )
        |> Dict.union
            (Dict.fromList
                [ -- PlatformRuntime.cpp:736-762 reads the flags decoder's Result; init/update/subscriptions
                  -- are called with and return the model as an opaque boxed word (HEAP_045).
                  ( ( "Platform", "worker" ), Inspects platformTypes )

                -- PlatformExports.cpp: bag building; a command or subscription is kept, and a tagger
                -- stored, without either being looked into.
                , ( ( "Platform", "batch" ), Inspects platformTypes )
                , ( ( "Platform", "map" ), Inspects platformTypes )
                , ( ( "Browser", "element" ), Inspects (( "elm/virtual-dom:VirtualDom", "Node" ) :: platformTypes) )
                , ( ( "Browser", "document" ), Inspects (( "elm/virtual-dom:VirtualDom", "Node" ) :: platformTypes) )
                , ( ( "Browser", "application" )
                  , Inspects
                        (( "elm/virtual-dom:VirtualDom", "Node" )
                            :: ( "elm/browser:Browser", "UrlRequest" )
                            :: ( "elm/url:Url", "Protocol" )
                            :: ( "elm/core:Maybe", "Maybe" )
                            :: platformTypes
                        )
                  )
                ]
            )


platformTypes : List TypeRef
platformTypes =
    [ ( "elm/core:Result", "Result" ), ( "elm/core:Platform.Cmd", "Cmd" ), ( "elm/core:Platform.Sub", "Sub" ) ]


{-| The types each effect manager's C++ code reads or builds, by the manager's
home module (`ModuleName.toComparableCanonical`).
-}
managerUses : Dict String (List TypeRef)
managerUses =
    Dict.fromList
        [ ( "elm/core:Task", [ ( "elm/core:Task", "MyCmd" ) ] )
        , ( "elm/time:Time", [ ( "elm/time:Time", "MySub" ), ( "elm/time:Time", "Posix" ) ] )
        , ( "elm/http:Http", [ ( "elm/http:Http", "MyCmd" ), ( "elm/http:Http", "MySub" ), ( "elm/http:Http", "Response" ), ( "elm/http:Http", "Progress" ), ( "elm/http:Http", "Request" ) ] )
        , ( "elm/browser:Browser.Events", [ ( "elm/browser:Browser.Events", "MySub" ) ] )
        , ( "eco/system:System", [ ( "eco/system:System", "MyCmd" ) ] )
        , ( "eco/system:FileSystem", [ ( "eco/system:FileSystem", "MySub" ), ( "eco/system:FileSystem", "Event" ) ] )
        , ( "eco/system:Socket", [ ( "eco/system:Socket", "MySub" ), ( "eco/system:Socket", "Event" ) ] )
        , ( "eco/system:Socket.Udp", [ ( "eco/system:Socket.Udp", "MySub" ), ( "eco/system:Socket.Udp", "Event" ) ] )
        , ( "eco/system:Terminal", [ ( "eco/system:Terminal", "MySub" ), ( "eco/system:Terminal", "Event" ) ] )
        , ( "eco/system:Http.Server", [ ( "eco/system:Http.Server", "MyCmd" ), ( "eco/system:Http.Server", "MySub" ), ( "eco/system:Http.Server", "Event" ) ] )
        , ( "eco/system:ChildProcess", [ ( "eco/system:ChildProcess", "MyCmd" ) ] )
        ]
