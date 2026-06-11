# Compatibility floors for `eco` and its outputs

What `eco` and the binaries it produces require of the host to run. There are three
independent floors — CPU, kernel, and (for dynamic outputs only) glibc version — plus a
fixed architecture requirement. The CPU floor applies to everything `eco` emits; the glibc
floor applies only to the dynamic `.so`/`.node` outputs.

See also [distribution.md](distribution.md) (bundle ABI), the Stage D plan
[../plans/stage-d-hybrid-link-profiles.md](../plans/stage-d-hybrid-link-profiles.md) (the
dynamic-output link profile), and [../plans/static-link-eco-binary.md](../plans/static-link-eco-binary.md)
(the static musl bundle).

## Quick reference

| Artifact | Distro / libc | glibc version | Kernel | CPU |
|---|---|---|---|---|
| `eco` itself (musl-static) | any Linux, any libc | n/a (no host libc) | modest (see below) | **x86-64-v3** |
| Static executable outputs | any Linux, any libc | n/a (no host libc) | modest | **x86-64-v3** |
| Dynamic `.so`/`.node` outputs | any **glibc** Linux + **glibc Node** | **≥ 2.36** (today) | host's | **x86-64-v3** |

Architecture is **x86-64 only** for all of the above (no ARM64, no 32-bit).

## The CPU floor: x86-64-v3 (applies to everything)

The code generator pins the target CPU to `x86-64-v3` with no host detection
(`runtime/src/codegen/EcoBackend.h:47`, `kEcoTargetCPU`; matched by the `-march=x86-64-v3`
flag in `CMakePresets.json`). x86-64-v3 means SSE4.2 + **AVX2** + BMI1/2 + FMA — Intel
Haswell (2013) / AMD Excavator-Zen or later. This is baked into the codegen, so it applies
identically to static executables, dynamic `.so`/`.node`, and `eco`'s own C++.

Consequence: on a pre-2013 CPU, a low-end Atom/Celeron without AVX2, or a VM / cloud
instance that does not expose AVX2 to the guest, the binary **SIGILLs** (illegal
instruction) — there is no runtime fallback. "Runs on any Linux" therefore means "any Linux
on a v3-capable x86-64 CPU". The pin is deliberate: host-CPU detection
(`getHostCPUName`/`getHostCPUFeatures`) previously bootstrapped AVX-512 on a build machine
and SIGILL'd on plain v3 hosts (`EcoBackend.h:40-46`).

## Static outputs (and `eco` itself): portable across distro and libc

The musl-static bundle (`eco`) and the static executables it produces have **no host libc
dependency at all** — `-static`, no `PT_INTERP`, no `NEEDED` entries, no dynamic loader.
They do not consult the host's glibc version, distro, or libc implementation: the same
binary runs on RHEL 8, Alpine, Debian bullseye, Ubuntu 20.04, anything. There is no
glibc-version floor for these.

A genuine advantage over a *static glibc* build: glibc-static binaries notoriously break DNS
and NSS lookups (they cannot `dlopen` the NSS service modules). musl's resolver is built in,
so static musl does DNS / HTTPS resolution correctly on every distro. This is one of the
reasons the bundle is musl, not glibc-static (see the static-link plan).

### Kernel floor

A static binary issues syscalls directly, so its kernel floor is whatever the newest syscall
musl + the eco runtime actually uses. musl's own baseline is ancient (2.6-era); the
practical high-water mark in the runtime is `getrandom` (Linux 3.17, 2014), with
threads/futex/mmap/epoll all far older. Any 4.x+ kernel is comfortably fine, and on any
realistic deployment the CPU floor binds long before the kernel floor does. The kernel floor
is not a value we track or enforce.

### HTTPS / CA certificates (a function limit, not a "will it run" limit)

The static binary bundles its own OpenSSL but reads the **host's** CA trust store to verify
TLS certificates, and that path differs by distro (Debian `/etc/ssl/certs/...`, RHEL
`/etc/pki/tls/certs/...`). If `eco` (or a produced binary) does HTTPS on a distro whose CA
layout does not match OpenSSL's compiled-in `OPENSSLDIR`, certificate verification can fail
even though the binary itself runs fine. The escape hatch is the standard
`SSL_CERT_FILE` / `SSL_CERT_DIR` environment variables.

## Dynamic outputs (`.so`/`.node`): cross-distro glibc, gated by a glibc version floor

The dynamic outputs are produced by the Stage D `GlibcBundleShared` link profile. The
builder's Debian-ness does **not** leak into the artifact as paths or library names: a
produced `.node`/`.so` has **zero `NEEDED` entries, no `RUNPATH`, and no Debian filenames**.
It statically embeds libc++ / libc++abi / libunwind / compiler-rt + curl / ssl / zip / z
(hidden via a scoped `--exclude-libs`) and leaves libc / libm / pthread / dl undefined to
bind from the host process at load. So these are genuinely portable across glibc distros —
**not** tied to Debian.

What does leak is the build host's **glibc version, as a floor.** Because libc is unlinked,
the addon references libc symbols *unversioned* and carries no `DT_VERNEED` table; each
reference binds to whatever version the host glibc provides by default. Any symbol absent on
an older host fails at `dlopen`. Today exactly one referenced symbol sets the bar:
**`arc4random`, introduced in glibc 2.36** (pulled in transitively via curl/openssl). So the
shipped dynamic outputs require **host glibc ≥ 2.36**:

| Distro | glibc | `.node` runs? |
|---|---|---|
| Debian 12 bookworm / 13 trixie | 2.36 / 2.41 | yes |
| Ubuntu 24.04 LTS, 22.10+ | 2.39 / 2.36 | yes |
| Fedora 37+ | 2.36+ | yes |
| Arch / openSUSE Tumbleweed | rolling | yes |
| Ubuntu 22.04 LTS | 2.35 | **no** (`undefined symbol: arc4random`) |
| RHEL / Rocky / Alma 9.x | 2.34 (whole 9 lifecycle) | **no** |
| RHEL 8 / Amazon Linux 2023 | 2.28 / 2.34 | **no** |
| Debian 11 bullseye / Ubuntu 20.04 | 2.31 | **no** |

So: cross-distro within **glibc ≥ 2.36**, which excludes some common enterprise targets —
notably *all* of RHEL 9 (pinned at 2.34 for its lifetime) and Ubuntu 22.04 LTS.

Two further requirements specific to `.node`:

- **glibc-based Node.** The addon is glibc-ABI; it will not load on Alpine / musl Node. The
  generated sibling `.js` shim detects musl Node (via the absence of
  `process.report`'s `glibcVersionRuntime`) and throws a clear message instead of the raw
  loader error.
- **x86-64-v3 CPU**, as for all outputs.

### How the floor is computed

The floor is not assumed — the `eco-glibc-runtime-tree` staging step
(`cmake/GlibcRuntimeAudit.cmake` → `cmake/glibc_floor.sh`) scans the staged archives'
undefined symbols, looks each up in the build host's libc/libm default-version export tables,
and records the maximum as `lib/eco-runtime/glibc/GLIBC_FLOOR`. On the current Debian
bookworm builder that value is `2.36`, driven by `arc4random`.

### Lowering the floor

The floor equals the build host's glibc. Building the `glibc-runtime` Docker stage on an
older base lowers it: Debian bullseye (~2.31), or a manylinux_2_28-style sysroot (2.28). On
an older glibc the source would not reference `arc4random` at all (it falls back to
`getrandom` / `/dev/urandom`), so the floor drops to roughly the libpthread-merge era. The
trade is build-host age versus deployment reach; bookworm simply happens to expose
`arc4random`. This is a tracked follow-up in the Stage D plan, not a fundamental limit.
