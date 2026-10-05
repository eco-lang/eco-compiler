# Vendored image inputs

`tla2tools.jar`: TLA+ tools 1.8.0, TLC 2026.09.25.163503 (rev 8f4bc8b), SHA256
`ab4694601923fd5ac06452abbf847c366a5054a3d739552085edd6ed986c29ec`. This is the build the
models under `test/tla/` were checked with. Upstream publishes 1.8.0 only as a rolling
pre-release whose jar is re-uploaded in place, so a pinned download stops matching.

`docker/eco-dev.Dockerfile` installs it (skipped with `--build-arg INSTALL_TLA=0`); its TLA+
section says how to move to a newer TLC.
