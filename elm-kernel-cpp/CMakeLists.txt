# Elm Kernel C++ Implementation
# Stub implementations of Elm kernel functions

add_library(elm-kernel
    # Core
    src/core/Basics.cpp
    src/core/Bitwise.cpp
    src/core/Char.cpp
    src/core/Debug.cpp
    src/core/Debugger.cpp
    src/core/JsArray.cpp
    src/core/List.cpp
    src/core/Platform.cpp
    src/core/Process.cpp
    src/core/Scheduler.cpp
    src/core/String.cpp
    src/core/Utils.cpp

    # Browser
    src/browser/Browser.cpp

    # Bytes
    src/bytes/Bytes.cpp

    # File
    src/file/File.cpp

    # HTTP
    src/http/Http.cpp

    # JSON
    src/json/Json.cpp

    # Parser
    src/parser/Parser.cpp

    # Regex
    src/regex/Regex.cpp

    # Time
    src/time/Time.cpp

    # URL
    src/url/Url.cpp

    # Virtual DOM
    src/virtual-dom/VirtualDom.cpp
)

target_include_directories(elm-kernel
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_features(elm-kernel PUBLIC cxx_std_20)

# Keep asserts enabled even in release builds
target_compile_options(elm-kernel PRIVATE -UNDEBUG)
