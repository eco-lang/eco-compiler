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
        -- core/SeqDict.hpp's validateSeqDict (ECO_SEQDICT_VALIDATE=1) also reads SeqDict internals, but
        -- through heap tags, word tag bits and slot kinds only, so it pins no representation.
        , ( "elm/core:Dict", "Dict" )
        , ( "eco/system:SeqDict", "SeqDict" )

        -- SeqDict's trie types (Node, Slot, Entry) are not kernel-owned: no C++ reads them in a fixed
        -- shape (the validator reads every representation), so the representation passes may tag
        -- Slot and make Maybe (Entry k v) nullable (plans/seq-data-structures-performance.md §4.1).

        -- From scripts/check-kernel-opaque.py: dummy declarations of kernel-produced values,
        -- and types the kernels build or read.
        , ( "eco/system:ChildProcess", "MyCmd" )
        , ( "eco/system:FileSystem", "Event" )
        , ( "eco/system:FileSystem", "MySub" )
        , ( "eco/system:FileSystem.Handle", "Handle" )
        , ( "eco/system:FileSystem.Handle", "ReadAccess" )
        , ( "eco/system:FileSystem.Handle", "WriteAccess" )
        -- Hash.Hashed is a Tag_Hashed heap object (HEAP_089) that FNVExports.cpp builds and reads;
        -- ValueHash.cpp, Utils.cpp (eqHelp) and RuntimeExports.cpp (Debug.toString) read it by its tag.
        , ( "eco/system:Hash", "Hashed" )
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
    , ( ( "eco/kernel:Eco.MVar", "MVar" ), "MVarExports.cpp:30 takes the raw Int id; Elm code wraps it" )
    ]


{-| What each kernel function, by home and name, does with custom values. A
kernel absent from this table is treated as building and reading every type
in its signature.

Every kernel in `design_docs/elm_kernel_functions.csv` was reviewed against
its C++ body (2026-11-20); the CSV records each one's verdict, inspected
types, C++ location and the evidence. The kernels left out are those with no
C++ body (linear-algebra, WebGL and the JavaScript-only listener functions of
eco/system), `Debugger.unsafeCoerce` (it changes a value's type without
touching its word, so both types keep their layout), the dead
`Bytes.write_*` (their C++ does not match how elm/bytes calls them), and
`Platform.leaf`, which only port code calls and ports are deny-all roots.
The key has no prefix: the one name both kernels define, `File.size`, is
`Transparent` in both.

-}
kernelUse : Dict ( String, String ) KernelUse
kernelUse =
    Dict.fromList
        (List.concatMap (\( home, names ) -> List.map (\n -> ( ( home, n ), Transparent )) names) transparentKernels
            ++ List.concat inspectingKernels
            ++ browserProgramKernels
        )


{-| The kernels that never build or look inside a custom value, by home. The
comment names the C++ the review read.
-}
transparentKernels : List ( String, List String )
transparentKernels =
    [ -- Basics: elm-kernel-cpp/src/core/BasicsExports.cpp
      ( "Basics", [ "acos", "add", "and", "asin", "atan", "atan2", "ceiling", "cos", "e", "fdiv", "floor", "idiv", "isInfinite", "isNaN", "log", "modBy", "mul", "not", "or", "pi", "pow", "remainderBy", "round", "sin", "sqrt", "sub", "tan", "toFloat", "truncate", "xor" ] )
    , -- Bitmap: system-kernel-cpp/src/eco-system/Bitmap/BitmapExports.cpp
      ( "Bitmap", [ "index", "popCount32" ] )
    , -- Bitwise: elm-kernel-cpp/src/core/BitwiseExports.cpp
      ( "Bitwise", [ "and", "complement", "or", "shiftLeftBy", "shiftRightBy", "shiftRightZfBy", "xor" ] )
    , -- Browser: elm-kernel-cpp/src/browser/BrowserExports.cpp
      ( "Browser", [ "decodeEvent", "doc", "getViewport", "go", "load", "now", "on", "pushUrl", "rAF", "reload", "replaceUrl", "setViewport", "visibilityInfo", "window", "withWindow" ] )
    , -- Bytes: elm-kernel-cpp/src/bytes/BytesExports.cpp
      ( "Bytes", [ "decodeFailure", "getStringWidth" ] )
    , -- Char: elm-kernel-cpp/src/core/CharExports.cpp
      ( "Char", [ "fromCode", "toCode", "toLocaleLower", "toLocaleUpper", "toLower", "toUpper" ] )
    , -- Crash: eco-kernel-cpp/src/eco-kernel/CrashExports.cpp
      -- Never returns: reports and exits without touching a value of the type variable.
      ( "Crash", [ "crash" ] )
    , -- Debug: elm-kernel-cpp/src/core/DebugExports.cpp
      -- log/toString print through the type table, which describes erased wrappers and
      -- nullable Maybes (plans/constructor-representation-levels.md E2, N1); todo ignores its argument.
      ( "Debug", [ "log", "toString", "todo" ] )
    , -- Debugger: elm-kernel-cpp/src/browser/BrowserExports.cpp
      ( "Debugger", [ "download", "init", "isOpen", "messageToString", "open", "scroll", "upload" ] )
    , -- FNV: system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp
      ( "FNV", [ "hash" ] )
    , -- SeqDictTrie: system-kernel-cpp/src/eco-system/SeqDictTrie/SeqDictTrieExports.cpp
      -- copies a SeqDict trie reading every representation of Slot and Maybe (Entry k v), and builds
      -- slots in the form of a probe slot compiled code passes, so it pins no representation.
      ( "SeqDictTrie", [ "remap" ] )
    , -- File: elm-kernel-cpp/src/file/FileExports.cpp
      ( "File", [ "decoder", "download", "downloadUrl", "lastModified", "makeBytesSafeForInternetExplorer", "mime", "name", "size", "toBytes", "toString", "toUrl", "uploadOne", "uploadOneOrMore" ] )
    , -- FileSystem: system-kernel-cpp/src/eco-system/FileSystem/FileSystemExports.cpp
      ( "FileSystem", [ "access", "chmod", "chown", "close", "copyFile", "currentWorkingDirectory", "devNull", "fchmod", "fchown", "fdatasync", "fstat", "fsync", "ftruncate", "futimes", "homeDirectory", "link", "listDirectory", "makeDirectory", "makeTempDirectory", "open", "readFileStream", "readLink", "realpath", "remove", "rename", "stat", "symlink", "tmpDirectory", "truncate", "unlink", "utimes", "writeFileStream" ] )
    , -- GC: eco-kernel-cpp/src/eco-kernel/GCExports.cpp
      ( "GC", [ "majorGC", "minorGC" ] )
    , -- Hash: eco-kernel-cpp/src/eco-kernel/HashExports.cpp
      ( "Hash", [ "string64", "stringWithSeed" ] )
    , -- Http: elm-kernel-cpp/src/http/HttpExports.cpp
      ( "Http", [ "bytesToBlob", "toDataView", "toFormData" ] )
    , -- HttpServer: system-kernel-cpp/src/eco-system/HttpServer/HttpServerExports.cpp
      ( "HttpServer", [ "closeServer", "createServer", "takeUpgrade" ] )
    , -- List: elm-kernel-cpp/src/core/ListExports.cpp
      -- append/concat/drop/reverse/take are the chunked-list shunts codegen calls
      -- (GenerateMlir/Functions.elm listShuntKernels); no Elm source names them.
      ( "List", [ "append", "concat", "cons", "drop", "fromArray", "map2", "map3", "map4", "map5", "reverse", "sortBy", "take", "toArray" ] )
    , -- MVar: eco-kernel-cpp/src/eco-kernel/MVarExports.cpp
      -- Keep the value off-heap without looking at it (a primitive is boxed first, by the
      -- put_Int/put_Float/put_Char variants) and hand it back in a Task.
      ( "MVar", [ "drop", "new", "put", "read", "take" ] )
    , -- NativeDriver: eco-kernel-cpp/src/eco-kernel/NativeDriverExports.cpp
      ( "NativeDriver", [ "lowerAndLink" ] )
    , -- Parser: elm-kernel-cpp/src/parser/ParserExports.cpp
      ( "Parser", [ "chompBase10", "consumeBase", "consumeBase16", "findSubString", "isAsciiCode", "isSubChar", "isSubString" ] )
    , -- Regex: elm-kernel-cpp/src/regex/RegexExports.cpp
      ( "Regex", [ "infinity" ] )
    , -- Socket: system-kernel-cpp/src/eco-system/Socket/SocketExports.cpp, system-kernel-cpp/src/eco-system/Socket/UdpExports.cpp
      ( "Socket", [ "accept", "close", "closeListener", "lookup", "peerCredentials", "reset", "setKeepAlive", "setNoDelay", "tcpConnect", "tcpListen", "udpBind", "udpClose", "udpMembership", "unixConnect", "unixListen" ] )
    , -- Stream: system-kernel-cpp/src/eco-system/Stream/StreamExports.cpp
      ( "Stream", [ "compressor", "custom", "decompressor", "identity", "textDecoder", "textEncoder" ] )
    , -- String: elm-kernel-cpp/src/core/StringExports.cpp
      ( "String", [ "all", "any", "append", "cons", "contains", "endsWith", "filter", "foldl", "foldr", "fromList", "fromNumber", "indexes", "join", "length", "lines", "map", "reverse", "slice", "split", "startsWith", "toLower", "toUpper", "trim", "trimLeft", "trimRight", "words" ] )
    , -- System: system-kernel-cpp/src/eco-system/System/SystemExports.cpp
      ( "System", [ "environment", "environmentNow", "exitWithCode", "getEnvironmentVariables", "rearmEmptyEventLoop", "setExitCode" ] )
    , -- Terminal: system-kernel-cpp/src/eco-system/Terminal/TerminalExports.cpp
      ( "Terminal", [ "isTerminal", "setStdInRawMode", "setTitle" ] )
    , -- Tls: system-kernel-cpp/src/eco-system/Tls/TlsExports.cpp
      ( "Tls", [ "connect", "listen" ] )
    , -- Url: elm-kernel-cpp/src/url/UrlExports.cpp
      ( "Url", [ "percentEncode" ] )
    , -- Utils: elm-kernel-cpp/src/core/UtilsExports.cpp
      -- equal/notEqual/compare and friends walk values generically: agnostic while every view of
      -- a value shares one representation, which the passes guarantee (MONO_029). cmp3 is
      -- the comparison helper behind the intrinsics.
      ( "Utils", [ "append", "cmp3", "ge", "gt", "le", "lt" ] )
    , -- VirtualDom: elm-kernel-cpp/src/virtual-dom/VirtualDomExports.cpp
      ( "VirtualDom", [ "lazy", "lazy2", "lazy3", "lazy4", "lazy5", "lazy6", "lazy7", "lazy8", "noInnerHtmlOrFormAction", "noJavaScriptOrHtmlUri", "noJavaScriptUri", "noOnOrFormAction", "noScript" ] )
    , -- WebSocket: system-kernel-cpp/src/eco-system/WebSocket/WebSocketExports.cpp
      ( "WebSocket", [ "abandon", "acceptFor", "close", "closed", "dial", "handshakeKey", "openOutgoing", "ping", "readUpgrade", "reject" ] )
    ]


{-| The kernels that build or read custom values, each with the types it
touches, as the review found them.
-}
inspectingKernels : List (List ( ( String, String ), KernelUse ))
inspectingKernels =
    [ -- Browser: elm-kernel-cpp/src/browser/BrowserExports.cpp
      List.map (\n -> ( ( "Browser", n ), Inspects [ ( "elm/browser:Browser.Dom", "Error" ), ( "elm/core:Platform", "Task" ) ] )) [ "call", "getElement", "getViewportOf", "setViewportOf" ]
    , -- Bytes: elm-kernel-cpp/src/bytes/BytesExports.cpp
      List.map (\n -> ( ( "Bytes", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "read_bytes", "read_f32", "read_f64", "read_i16", "read_i32", "read_i8", "read_string", "read_u16", "read_u32", "read_u8", "width" ]
    , -- Bytes: elm-kernel-cpp/src/bytes/BytesExports.cpp
      List.map (\n -> ( ( "Bytes", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ), ( "elm/bytes:Bytes", "Endianness" ), ( "elm/bytes:Bytes.Encode", "Encoder" ) ] )) [ "encode" ]
    , -- Bytes: elm-kernel-cpp/src/bytes/BytesExports.cpp
      List.map (\n -> ( ( "Bytes", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ) ] )) [ "decode" ]
    , -- Bytes: elm-kernel-cpp/src/bytes/BytesExports.cpp
      List.map (\n -> ( ( "Bytes", n ), Inspects [ ( "elm/core:Platform", "Task" ) ] )) [ "getHostEndianness" ]
    , -- ChildProcess: system-kernel-cpp/src/eco-system/ChildProcess/ChildProcessExports.cpp
      List.map (\n -> ( ( "ChildProcess", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "run" ]
    , -- Dom: system-kernel-cpp/src/eco-system/Dom/DomExports.cpp
      List.map (\n -> ( ( "Dom", n ), Inspects [ ( "eco/system:Html.Dom", "Fact" ), ( "elm/virtual-dom:VirtualDom", "Attribute" ) ] )) [ "fromAttribute" ]
    , -- Dom: system-kernel-cpp/src/eco-system/Dom/DomExports.cpp
      List.map (\n -> ( ( "Dom", n ), Inspects [ ( "eco/system:Html.Dom", "Node" ), ( "elm/virtual-dom:VirtualDom", "Node" ) ] )) [ "fromNode" ]
    , -- Dom: system-kernel-cpp/src/eco-system/Dom/DomExports.cpp
      List.map (\n -> ( ( "Dom", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ), ( "elm/json:Json.Encode", "Value" ), ( "elm/virtual-dom:VirtualDom", "Attribute" ), ( "elm/virtual-dom:VirtualDom", "Node" ) ] )) [ "toString" ]
    , -- FileSystem: system-kernel-cpp/src/eco-system/FileSystem/FileSystemExports.cpp
      List.map (\n -> ( ( "FileSystem", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "appendFile", "readFile", "readFromOffset", "writeFile", "writeFromOffset" ]
    , -- Http: elm-kernel-cpp/src/http/HttpExports.cpp
      List.map (\n -> ( ( "Http", n ), Inspects [ ( "elm/core:Dict", "Dict" ), ( "elm/core:Maybe", "Maybe" ), ( "elm/core:Platform", "Task" ), ( "elm/http:Http", "Body" ), ( "elm/http:Http", "Expect" ), ( "elm/http:Http", "Header" ), ( "elm/http:Http", "Part" ), ( "elm/http:Http", "Progress" ), ( "elm/http:Http", "Resolver" ), ( "elm/http:Http", "Response" ) ] )) [ "toTask" ]
    , -- Http: elm-kernel-cpp/src/http/HttpExports.cpp
      List.map (\n -> ( ( "Http", n ), Inspects [ ( "elm/http:Http", "Body" ) ] )) [ "emptyBody" ]
    , -- Http: elm-kernel-cpp/src/http/HttpExports.cpp
      List.map (\n -> ( ( "Http", n ), Inspects [ ( "elm/http:Http", "Body" ), ( "elm/http:Http", "Part" ) ] )) [ "pair" ]
    , -- Http: elm-kernel-cpp/src/http/HttpExports.cpp
      List.map (\n -> ( ( "Http", n ), Inspects [ ( "elm/http:Http", "Expect" ) ] )) [ "mapExpect" ]
    , -- Http: elm-kernel-cpp/src/http/HttpExports.cpp
      List.map (\n -> ( ( "Http", n ), Inspects [ ( "elm/http:Http", "Expect" ), ( "elm/http:Http", "Resolver" ), ( "elm/http:Http", "Response" ) ] )) [ "expect" ]
    , -- HttpServer: system-kernel-cpp/src/eco-system/HttpServer/HttpServerExports.cpp
      List.map (\n -> ( ( "HttpServer", n ), Inspects [ ( "eco/system:Html.Dom", "Fact" ), ( "eco/system:Html.Dom", "Node" ), ( "elm/core:Maybe", "Maybe" ), ( "elm/json:Json.Encode", "Value" ) ] )) [ "respondHtml" ]
    , -- HttpServer: system-kernel-cpp/src/eco-system/HttpServer/HttpServerExports.cpp
      List.map (\n -> ( ( "HttpServer", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "respond" ]
    , -- HttpServer: system-kernel-cpp/src/eco-system/HttpServer/HttpServerExports.cpp
      List.map (\n -> ( ( "HttpServer", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ) ] )) [ "createServerWith" ]
    , -- HttpStream: system-kernel-cpp/src/eco-system/HttpStream/HttpStreamExports.cpp
      List.map (\n -> ( ( "HttpStream", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ), ( "elm/http:Http", "Header" ) ] )) [ "send" ]
    , -- JsArray: elm-kernel-cpp/src/core/JsArrayExports.cpp
      List.map (\n -> ( ( "JsArray", n ), Inspects [ ( "elm/core:Elm.JsArray", "JsArray" ) ] )) [ "appendN", "empty", "foldl", "foldr", "indexedMap", "initialize", "initializeFromList", "length", "map", "push", "singleton", "slice", "unsafeGet", "unsafeSet" ]
    , -- FNV: system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp builds and reads Hash.Hashed (HEAP_089);
      -- its value is a type-variable value only moved.
      List.map (\n -> ( ( "FNV", n ), Inspects [ ( "eco/system:Hash", "Hashed" ) ] )) [ "hashed", "value" ]
    , -- JsArray2: system-kernel-cpp/src/eco-system/JsArray2/JsArray2Exports.cpp
      List.map (\n -> ( ( "JsArray2", n ), Inspects [ ( "eco/system:JsArray2", "JsArray2" ) ] )) [ "appendN", "empty", "foldl", "foldr", "indexedMap", "initialize", "initializeFromList", "length", "map", "push", "removeIndex", "singleton", "slice", "unsafeGet", "unsafeInsert", "unsafeSet" ]
    , -- Json: elm-kernel-cpp/src/json/JsonExports.cpp
      List.map (\n -> ( ( "Json", n ), Inspects [ ( "elm/core:Array", "Array" ), ( "elm/core:Array", "Node" ), ( "elm/core:Elm.JsArray", "JsArray" ), ( "elm/core:Result", "Result" ), ( "elm/json:Json.Decode", "Decoder" ), ( "elm/json:Json.Decode", "Error" ), ( "elm/json:Json.Encode", "Value" ) ] )) [ "run", "runOnString" ]
    , -- Json: elm-kernel-cpp/src/json/JsonExports.cpp
      List.map (\n -> ( ( "Json", n ), Inspects [ ( "elm/json:Json.Decode", "Decoder" ) ] )) [ "andThen", "decodeArray", "decodeBool", "decodeField", "decodeFloat", "decodeIndex", "decodeInt", "decodeKeyValuePairs", "decodeList", "decodeNull", "decodeString", "decodeValue", "fail", "map1", "map2", "map3", "map4", "map5", "map6", "map7", "map8", "oneOf", "succeed" ]
    , -- Json: elm-kernel-cpp/src/json/JsonExports.cpp
      List.map (\n -> ( ( "Json", n ), Inspects [ ( "elm/json:Json.Encode", "Value" ) ] )) [ "addEntry", "addField", "emptyArray", "emptyObject", "encode", "encodeNull", "wrap" ]
    , -- List: elm-kernel-cpp/src/core/ListExports.cpp
      List.map (\n -> ( ( "List", n ), Inspects [ ( "elm/core:Basics", "Order" ) ] )) [ "sortWith" ]
    , -- NativeDriver: eco-kernel-cpp/src/eco-kernel/NativeDriverExports.cpp
      List.map (\n -> ( ( "NativeDriver", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "lowerAndLinkBytes" ]
    , -- Platform: elm-kernel-cpp/src/core/PlatformExports.cpp
      List.map (\n -> ( ( "Platform", n ), Inspects [ ( "elm/core:Platform", "Program" ), ( "elm/core:Platform.Cmd", "Cmd" ), ( "elm/core:Platform.Sub", "Sub" ), ( "elm/core:Result", "Result" ) ] )) [ "worker" ]
    , -- Platform: elm-kernel-cpp/src/core/PlatformExports.cpp
      List.map (\n -> ( ( "Platform", n ), Inspects [ ( "elm/core:Platform", "Router" ), ( "elm/core:Platform", "Task" ) ] )) [ "sendToApp", "sendToSelf" ]
    , -- Platform: elm-kernel-cpp/src/core/PlatformExports.cpp
      List.map (\n -> ( ( "Platform", n ), Inspects [ ( "elm/core:Platform.Cmd", "Cmd" ), ( "elm/core:Platform.Sub", "Sub" ) ] )) [ "batch", "map" ]
    , -- Process: elm-kernel-cpp/src/core/ProcessExports.cpp
      List.map (\n -> ( ( "Process", n ), Inspects [ ( "elm/core:Platform", "Task" ) ] )) [ "sleep" ]
    , -- Regex: elm-kernel-cpp/src/regex/RegexExports.cpp
      List.map (\n -> ( ( "Regex", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ), ( "elm/regex:Regex", "Regex" ) ] )) [ "findAtMost", "fromStringWith", "replaceAtMost" ]
    , -- Regex: elm-kernel-cpp/src/regex/RegexExports.cpp
      List.map (\n -> ( ( "Regex", n ), Inspects [ ( "elm/regex:Regex", "Regex" ) ] )) [ "contains", "never", "splitAtMost" ]
    , -- Scheduler: elm-kernel-cpp/src/core/SchedulerExports.cpp
      List.map (\n -> ( ( "Scheduler", n ), Inspects [ ( "elm/core:Platform", "ProcessId" ), ( "elm/core:Platform", "Task" ) ] )) [ "kill", "spawn" ]
    , -- Scheduler: elm-kernel-cpp/src/core/SchedulerExports.cpp
      List.map (\n -> ( ( "Scheduler", n ), Inspects [ ( "elm/core:Platform", "Task" ) ] )) [ "andThen", "fail", "onError", "succeed" ]
    , -- Socket: system-kernel-cpp/src/eco-system/Socket/SocketExports.cpp, system-kernel-cpp/src/eco-system/Socket/UdpExports.cpp
      List.map (\n -> ( ( "Socket", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "udpReceive", "udpSend" ]
    , -- Stream: system-kernel-cpp/src/eco-system/Stream/StreamExports.cpp
      List.map (\n -> ( ( "Stream", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "cancelReadable", "cancelWritable", "carryAppend", "closeWritable", "enqueue", "pipeThrough", "pipeTo", "read", "readChunk", "stringToUtf8", "write" ]
    , -- Stream: system-kernel-cpp/src/eco-system/Stream/StreamExports.cpp
      List.map (\n -> ( ( "Stream", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ), ( "elm/core:Maybe", "Maybe" ) ] )) [ "carryLine", "utf8ToString" ]
    , -- String: elm-kernel-cpp/src/core/StringExports.cpp
      List.map (\n -> ( ( "String", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ) ] )) [ "toFloat", "toInt", "uncons" ]
    , -- Terminal: system-kernel-cpp/src/eco-system/Terminal/TerminalExports.cpp
      List.map (\n -> ( ( "Terminal", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ) ] )) [ "getConfiguration" ]
    , -- Time: elm-kernel-cpp/src/time/TimeExports.cpp
      List.map (\n -> ( ( "Time", n ), Inspects [ ( "elm/core:Platform", "Task" ) ] )) [ "now" ]
    , -- Time: elm-kernel-cpp/src/time/TimeExports.cpp
      List.map (\n -> ( ( "Time", n ), Inspects [ ( "elm/core:Platform", "Task" ), ( "elm/time:Time", "Zone" ) ] )) [ "here" ]
    , -- Time: elm-kernel-cpp/src/time/TimeExports.cpp
      List.map (\n -> ( ( "Time", n ), Inspects [ ( "elm/core:Platform", "Task" ), ( "elm/time:Time", "ZoneName" ) ] )) [ "getZoneName" ]
    , -- Time: elm-kernel-cpp/src/time/TimeExports.cpp
      List.map (\n -> ( ( "Time", n ), Inspects [ ( "elm/time:Time", "MySub" ) ] )) [ "setInterval" ]
    , -- Tls: system-kernel-cpp/src/eco-system/Tls/TlsExports.cpp
      List.map (\n -> ( ( "Tls", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ) ] )) [ "info" ]
    , -- Url: elm-kernel-cpp/src/url/UrlExports.cpp
      List.map (\n -> ( ( "Url", n ), Inspects [ ( "elm/core:Maybe", "Maybe" ) ] )) [ "percentDecode" ]
    , -- Utils: elm-kernel-cpp/src/core/UtilsExports.cpp
      List.map (\n -> ( ( "Utils", n ), Inspects [ ( "eco/system:SeqDict", "SeqDict" ), ( "elm/core:Dict", "Dict" ) ] )) [ "equal", "notEqual" ]
    , -- Utils: elm-kernel-cpp/src/core/UtilsExports.cpp
      List.map (\n -> ( ( "Utils", n ), Inspects [ ( "elm/core:Basics", "Order" ) ] )) [ "compare" ]
    , -- VirtualDom: elm-kernel-cpp/src/virtual-dom/VirtualDomExports.cpp
      List.map (\n -> ( ( "VirtualDom", n ), Inspects [ ( "eco/system:Html.Dom", "Fact" ), ( "elm/virtual-dom:VirtualDom", "Attribute" ) ] )) [ "attribute", "attributeNS", "mapAttribute", "on", "property", "style" ]
    , -- VirtualDom: elm-kernel-cpp/src/virtual-dom/VirtualDomExports.cpp
      List.map (\n -> ( ( "VirtualDom", n ), Inspects [ ( "eco/system:Html.Dom", "Node" ), ( "elm/core:Maybe", "Maybe" ), ( "elm/virtual-dom:VirtualDom", "Node" ) ] )) [ "keyedNode", "keyedNodeNS", "node", "nodeNS" ]
    , -- VirtualDom: elm-kernel-cpp/src/virtual-dom/VirtualDomExports.cpp
      List.map (\n -> ( ( "VirtualDom", n ), Inspects [ ( "eco/system:Html.Dom", "Node" ), ( "elm/virtual-dom:VirtualDom", "Node" ) ] )) [ "map", "text" ]
    , -- VirtualDom: elm-kernel-cpp/src/virtual-dom/VirtualDomExports.cpp
      List.map (\n -> ( ( "VirtualDom", n ), Inspects [ ( "elm/json:Json.Encode", "Value" ) ] )) [ "noJavaScriptOrHtmlJson" ]
    , -- WebSocket: system-kernel-cpp/src/eco-system/WebSocket/WebSocketExports.cpp
      List.map (\n -> ( ( "WebSocket", n ), Inspects [ ( "elm/bytes:Bytes", "Bytes" ) ] )) [ "open" ]
    ]


{-| `Browser.element`, `document` and `application`. Natively their C++ only
returns the program record (BrowserExports.cpp:35-45), but these entries keep
the types a runtime that drives such a program touches: the view's nodes, the
URL request, the flags decoder's `Result` and the commands and subscriptions.
-}
browserProgramKernels : List ( ( String, String ), KernelUse )
browserProgramKernels =
    [ ( ( "Browser", "element" ), Inspects (( "elm/virtual-dom:VirtualDom", "Node" ) :: platformTypes) )
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
