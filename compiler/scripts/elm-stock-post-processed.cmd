@rem Launcher of elm-stock-post-processed.js (plans/stage1-direct-kernel-linking.md, D2, D8): stock elm,
@rem then the post-processing every stock-Elm build of the compiler gets. Give it to elm-test-rs with --compiler.
@node "%~dp0elm-stock-post-processed.js" %*
@exit /b %ERRORLEVEL%
