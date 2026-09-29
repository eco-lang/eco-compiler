# ============================================================
# LLVM/MLIR comes from a pre-built image produced by
# docker/llvm-debian.Dockerfile. Build that once with:
#   docker build -f docker/llvm-debian.Dockerfile -t eco-llvm-debian:21.1.8 .
# Bump LLVM_IMAGE's tag in lockstep with the LLVM version there.
# ============================================================
ARG LLVM_IMAGE=eco-llvm-debian:21.1.8
FROM ${LLVM_IMAGE} AS llvm

# ============================================================
# Runtime stage: tools + installed MLIR, non-root entrypoint
# ============================================================
FROM debian:bookworm
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION=22

LABEL org.opencontainers.image.description="eco-runtime development environment"
LABEL org.opencontainers.image.source="https://github.com/eco-runtime/eco-runtime"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git build-essential python3 pkg-config \
    cmake ninja-build clang lld zlib1g-dev libxml2-dev \
    gosu curl libcmark-dev ccache sudo \
    less \
    # HTTP/HTTPS support for elm/http kernel
    libcurl4-openssl-dev libssl-dev \
    # Archive extraction for the package downloader (eco-kernel Http.getArchive)
    libzip-dev \
    # Debugging and profiling tools (essential for GC development)
    gdb lldb linux-perf strace bpftrace \
    # Code quality tools
    clang-format clang-tidy \
    # Developer convenience
    ripgrep fd-find vim-tiny bash-completion man-db jq time \
    # Locale support
    locales \
 && rm -rf /var/lib/apt/lists/* \
 # Configure locale
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen

# Install Node.js for Guida compiler builds, and enable pnpm via corepack.
# pnpm is the package manager used by compiler/package.json (see
# compiler/.npmrc for the ignore-scripts hardening).
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && corepack enable pnpm \
    && rm -rf /var/lib/apt/lists/*

# Installed LLVM/MLIR
COPY --from=llvm /opt/llvm-mlir /opt/llvm-mlir

# Install RapidCheck from source (not available in apt)
# RapidCheck is used for property-based testing
RUN git clone --depth=1 https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
    && cd /tmp/rapidcheck \
    && cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
    && cmake --build build \
    && cmake --install build \
    && rm -rf /tmp/rapidcheck

# Install Claude CLI
COPY docker/install_claude.sh .
RUN ./install_claude.sh && rm ./install_claude.sh

# Install uv (Python package manager from Astral) system-wide
ENV UV_INSTALL_DIR="/usr/local/bin"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# FlameGraph tools for perf visualization (put on PATH by the ENV PATH near the
# end of this file, which replaces PATH wholesale)
RUN git clone --depth=1 https://github.com/brendangregg/FlameGraph.git /opt/FlameGraph

# ============================================================
# TLA+ / PlusCal toolchain for the GC concurrency models
# (plans/threaded-gc-tla-verification.md §3).
#
#   tlc / sany / pcal / tlatex  wrappers over tla2tools.jar, with the
#                               CommunityModules on the classpath (the Json and
#                               IOUtils modules are what trace validation reads)
#   apalache-mc                 symbolic checker (inductive invariants, larger
#                               parameters); needs Java 21+ (class file 65)
#   Temurin 21 JRE              bookworm only ships openjdk-17, which cannot
#                               load Apalache 0.62.x, so the JRE comes from
#                               Adoptium. TLC runs on it too.
#   tlapm                       TLAPS proof manager, OPT-IN: the upstream tarball
#                               is ~880 MB and is a rolling pre-release, so it
#                               cannot be SHA-pinned. Build with
#                               --build-arg INSTALL_TLAPS=1
#   graphviz                    renders TLC -dump dot state graphs
#
# Every download except TLAPS is SHA256-pinned, like compiler/cmake/toolchain.cmake.
# SHAs computed from the upstream release assets on 2026-09-28.
#
# tla2tools is 1.8.0, NOT the last stable release (1.7.4): current
# CommunityModules fail on 1.7.4 with NoClassDefFoundError
# (tlc2/value/impl/KSubsetValue), and trace validation needs them. Tested
# 2026-09-28: TLC "2026.09.25.163503 (rev: 8f4bc8b)" + CommunityModules
# 202609120237 model-checks the smoke spec below. v1.8.0 is a ROLLING
# pre-release whose asset upstream re-uploads in place, so this pin WILL fail
# the build some day. When it does, re-download, re-hash, bump the SHA on
# purpose, and re-run `cmake --build build --target tla-check`.
# CMake finds the jars through TLA_TOOLS_DIR (plans/threaded-gc-tla-verification.md §6).
# ============================================================
ARG TLA2TOOLS_VERSION=1.8.0
ARG TLA2TOOLS_SHA256=ab4694601923fd5ac06452abbf847c366a5054a3d739552085edd6ed986c29ec
ARG TLA_COMMUNITY_MODULES_VERSION=202609120237
ARG TLA_COMMUNITY_MODULES_SHA256=3d9a282c360e90d55e9bbe99caa2987d508fef1556d652760b4af4455e283733
ARG APALACHE_VERSION=0.62.2
ARG APALACHE_SHA256=765f610537281a0f25b8c30f2554f19523e2859c824e80e62276653ee23c10e2
ARG INSTALL_TLAPS=0
ARG TEMURIN_VERSION=21.0.12.1+1
ARG TEMURIN_SHA256_AMD64=2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500
ARG TEMURIN_SHA256_ARM64=14be1f35ebdbd1f6e8d57eb911a3ffb74d6d9aa255abc5daf2b1302002cf2cf2

RUN apt-get update && apt-get install -y --no-install-recommends graphviz \
 && rm -rf /var/lib/apt/lists/*

# Symlinked into /usr/local/bin rather than put on PATH, because the ENV PATH
# near the end of this file replaces PATH wholesale.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) JRE_ARCH=x64;     JRE_SHA256="${TEMURIN_SHA256_AMD64}" ;; \
      arm64) JRE_ARCH=aarch64; JRE_SHA256="${TEMURIN_SHA256_ARM64}" ;; \
      *) echo "no Temurin JRE pinned for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    JRE_TAG="jdk-$(echo "${TEMURIN_VERSION}" | sed 's/+/%2B/')"; \
    JRE_FILE="OpenJDK21U-jre_${JRE_ARCH}_linux_hotspot_$(echo "${TEMURIN_VERSION}" | tr + _).tar.gz"; \
    curl -fsSL -o /tmp/jre.tgz \
      "https://github.com/adoptium/temurin21-binaries/releases/download/${JRE_TAG}/${JRE_FILE}"; \
    echo "${JRE_SHA256}  /tmp/jre.tgz" | sha256sum -c -; \
    mkdir -p /opt/java; \
    tar -xzf /tmp/jre.tgz -C /opt/java --strip-components=1; \
    rm /tmp/jre.tgz; \
    ln -s /opt/java/bin/java /usr/local/bin/java; \
    java -version
ENV JAVA_HOME=/opt/java

RUN set -eu; \
    mkdir -p /opt/tlaplus; \
    cd /opt/tlaplus; \
    curl -fsSL -o tla2tools.jar \
      "https://github.com/tlaplus/tlaplus/releases/download/v${TLA2TOOLS_VERSION}/tla2tools.jar"; \
    echo "${TLA2TOOLS_SHA256}  tla2tools.jar" | sha256sum -c -; \
    curl -fsSL -o CommunityModules-deps.jar \
      "https://github.com/tlaplus/CommunityModules/releases/download/${TLA_COMMUNITY_MODULES_VERSION}/CommunityModules-deps-${TLA_COMMUNITY_MODULES_VERSION}.jar"; \
    echo "${TLA_COMMUNITY_MODULES_SHA256}  CommunityModules-deps.jar" | sha256sum -c -; \
    curl -fsSL -o /tmp/apalache.tgz \
      "https://github.com/apalache-mc/apalache/releases/download/v${APALACHE_VERSION}/apalache-${APALACHE_VERSION}.tgz"; \
    echo "${APALACHE_SHA256}  /tmp/apalache.tgz" | sha256sum -c -; \
    mkdir -p /opt/apalache; \
    tar -xzf /tmp/apalache.tgz -C /opt/apalache --strip-components=1; \
    rm /tmp/apalache.tgz; \
    CP='/opt/tlaplus/tla2tools.jar:/opt/tlaplus/CommunityModules-deps.jar'; \
    printf '#!/bin/sh\nexec java -XX:+UseParallelGC ${TLC_JAVA_OPTS:-} -cp %s tlc2.TLC "$@"\n' "$CP" > /usr/local/bin/tlc; \
    printf '#!/bin/sh\nexec java -cp %s tla2sany.SANY "$@"\n' "$CP" > /usr/local/bin/sany; \
    printf '#!/bin/sh\nexec java -cp %s pcal.trans "$@"\n' "$CP" > /usr/local/bin/pcal; \
    printf '#!/bin/sh\nexec java -cp %s tla2tex.TLA "$@"\n' "$CP" > /usr/local/bin/tlatex; \
    printf '#!/bin/sh\nexec /opt/apalache/bin/apalache-mc "$@"\n' > /usr/local/bin/apalache-mc; \
    chmod +x /usr/local/bin/tlc /usr/local/bin/sany /usr/local/bin/pcal \
             /usr/local/bin/tlatex /usr/local/bin/apalache-mc; \
    if [ "${INSTALL_TLAPS}" = "1" ]; then \
      curl -fsSL -o /tmp/tlapm.tgz \
        "https://github.com/tlaplus/tlapm/releases/download/1.6.0-pre/tlapm-1.6.0-pre-x86_64-linux-gnu.tar.gz"; \
      mkdir -p /opt/tlapm; \
      tar -xzf /tmp/tlapm.tgz -C /opt/tlapm --strip-components=1; \
      rm /tmp/tlapm.tgz; \
      [ -x /opt/tlapm/bin/tlapm ] || { echo "tlapm tarball layout changed" >&2; exit 1; }; \
      ln -s /opt/tlapm/bin/tlapm /usr/local/bin/tlapm; \
    fi; \
    mkdir -p /tmp/tla-smoke; \
    cd /tmp/tla-smoke; \
    printf '%s\n' '---- MODULE Smoke ----' 'EXTENDS Naturals' 'VARIABLE x' \
      'Init == x = 0' "Next == x' = 1 - x" 'Inv == x \in {0, 1}' '====' > Smoke.tla; \
    printf 'INIT Init\nNEXT Next\nINVARIANT Inv\n' > Smoke.cfg; \
    tlc -workers 1 -config Smoke.cfg Smoke.tla > smoke.log 2>&1 \
      || { cat smoke.log >&2; echo "TLC smoke test failed" >&2; exit 1; }; \
    apalache-mc version > /dev/null \
      || { echo "Apalache smoke test failed" >&2; exit 1; }; \
    cd /; \
    rm -rf /tmp/tla-smoke /tmp/SANY*

ENV TLA_TOOLS_DIR=/opt/tlaplus

# GenMC (the C11 model checker of test/genmc, target genmc-check) is NOT in this
# image: it is an opt-in layer, docker/eco-dev-genmc.Dockerfile (built FROM this
# image), so CI's eco-dev build does not depend on the GenMC image.


# Workspace
WORKDIR /work

# Shell aliases and bash completion
RUN echo 'alias ll="ls -la"' >> /etc/bash.bashrc \
 && echo 'alias rg="rg --smart-case"' >> /etc/bash.bashrc \
 && echo 'alias fd="fdfind"' >> /etc/bash.bashrc \
 && echo '[ -f /etc/bash_completion ] && . /etc/bash_completion' >> /etc/bash.bashrc

# Add entrypoint script
COPY --chown=root:root docker/eco-dev-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Locale configuration
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ccache configuration for faster incremental builds
ENV CCACHE_DIR=/work/.ccache
ENV CCACHE_MAXSIZE=5G

# Helpful defaults for downstream builds; entrypoint also exports these.
ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
ENV LD_LIBRARY_PATH=/opt/llvm-mlir/lib
# ccache wrappers first in PATH for transparent caching; FlameGraph last so its
# loose scripts never shadow system tools
ENV PATH=/usr/lib/ccache:/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/FlameGraph
ENV CC=clang
ENV CXX=clang++

# Expose serena dashboard port
EXPOSE 24282

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]