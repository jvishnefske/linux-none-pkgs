# linux-none-pkgs

Rust packages from nixpkgs, rebuilt for `x86_64-unknown-linux-none` on
the real `std` from [rust-std](../rust-std). The binaries are static
non-PIE ELF files with no libc: std talks to the kernel through raw
syscalls.

```sh
nix build            # every package, binaries in result/bin
nix build .#sd       # one package
nix flake check      # static-ELF check and smoke test of every package
```

## How it works

`lib.x86_64-linux.linuxNone pkg { extraCargoFlags ? [] }` takes a nixpkgs
`buildRustPackage` package and rebuilds it with the same source, patches,
features and vendored crates (`pkg.cargoDeps`). The difference is the
toolchain and std:

- the toolchain is the pinned nightly from rust-std;
- `-Zbuild-std` builds std from the patched tree (`rust-std#std-src`);
- crates.io is the package's vendored crates merged with std's own
  (`library/vendor` in rust-src), so the build is offline;
- every vendored `libc` gets the fixup std's own libc gets
  (`xtask libc-fixup`): musl's types and constants for linux-none,
  and no `-lc`. Without it libc does not compile for an empty
  `target_env`. Other crates that pick libc's glibc or musl definitions
  by `target_env` (`nix`, `socket2`, ...) get musl's (`xtask musl-cfg`);
- the libc functions crates call (`isatty`, `mmap`, `sigaction`,
  `getpwuid_r`, ...) come from rust-std's runtime (`rt/src/clib.rs`), and
  empty `libc.a`, `libdl.a`, ... satisfy crates that ask the linker for
  them;
- C code in crates (ring, aws-lc, zstd, libgit2, oniguruma, mimalloc,
  zlib-ng, ...) is compiled by their build scripts with the host's gcc and
  glibc's headers, with Nix's hardening flags off: rt has no
  `__stack_chk_fail` or `_FORTIFY_SOURCE`'s `__*_chk` functions. It links
  against rt's C functions (`rt/src/clib.rs` and `rt/src/clib/`: strings,
  ctype, printf, `malloc`, pthread keys and locks, directories, ...), so
  it builds where those are all it calls;
- the package's own build tools (`nativeBuildInputs`, such as cmake) are
  kept; C libraries built with cmake get a toolchain file whose compiler
  checks build a static library, as there is no `libc.a` to link;
- the rustflags are those of rust-std's `apps/.cargo/config.toml`
  (`+crt-static`, static relocation model, `-no-pie`).

`overrides` in `flake.nix` changes a package first where needed: ripgrep
is built without its pcre2 feature, which is C, and xh and taplo with
rustls rather than the native-tls (OpenSSL) nixpkgs picks.

The binaries have no undefined symbols but weak ones (aws-lc's optional
memory hooks), which are null in a static executable.

Only the executables are installed: no man pages, shell completions or
wrappers from the nixpkgs `postInstall`.

To add a package, add its nixpkgs attribute name to `selection` in
`flake.nix` with a smoke test. The packages that don't build yet are in
`candidates`: `nix build .#candidates.gitui` shows why.

## What builds

40 of the 42 packages tried. Each one is a static ELF with no
undefined symbols, and passes a smoke test (`checks` in `flake.nix`).

| package | version | smoke test |
|---|---|---|
| sd | 1.0.0 | replace on stdin, and in a file in place |
| hexyl | 0.17.0 | hex dump of stdin |
| grex | 1.4.6 | regex from examples |
| shellharden | 4.3.2 | quote a variable |
| rnr | 0.5.1 | rename files by regex |
| ruplacer | 0.10.0 | replace in a directory tree |
| fd | 10.5.0 | find files by extension |
| dust | 1.2.7 | directory sizes |
| choose | 1.3.7 | pick a field |
| typos | 1.51.1 | find a typo |
| stylua | 2.6.0 | format Lua |
| htmlq | 0.4.0 | query HTML |
| pastel | 0.12.0 | convert a color |
| fastmod | 0.4.4 | replace in a directory tree |
| zoxide | 0.10.0 | add and query a directory |
| ripgrep | 15.2.0 | search (without pcre2) |
| tokei | 15.0.0 | count lines of code |
| hyperfine | 2.0.0 | benchmark a command, export JSON |
| dua | 2.46.0 | disk usage |
| just | 1.59.0 | run a recipe |
| mdbook | 0.5.4 | build a book |
| broot | 1.61.0 | print its shell function (it needs a terminal) |
| procs | 0.14.12 | list a process |
| bottom | 0.15.0 | `--version` (a terminal UI) |
| tealdeer | 1.9.1 | `--version` (it fetches its pages) |
| oxipng | 10.2.1 | optimize a PNG |
| miniserve | 0.35.0 | serve a file over HTTPS: rustls on ring, HTTP/1.1 and 2 |
| static-web-server | 2.44.1 | serve a file over HTTPS: rustls on aws-lc |
| xh | 0.26.3 | fetch a file over HTTPS from miniserve, verifying its certificate |
| bat | 0.26.1 | print and highlight a file (oniguruma) |
| eza | 0.23.5 | list a directory, with `--git` (libgit2) |
| lsd | 1.2.0 | list a directory |
| delta | 0.20.1 | diff two files |
| fselect | 0.10.3 | query files by name |
| jaq | 3.1.2 | a jq filter (mimalloc) |
| jql | 8.1.2 | a JSON query |
| skim | 5.7.4 | filter lines (`--filter`; it is interactive) |
| hck | 0.11.6 | cut a field, and from a gzip file (zlib-ng) |
| taplo | 0.10.0 | format TOML |
| [middleware] | 0.4.0 | not from nixpkgs: see below |

[middleware]: https://github.com/jvishnefske/middleware

middleware, a pub/sub and request/response library, is built from its own
repository (the `middleware` input) with all its features: the Zenoh and
gRPC (tonic) transports on tokio, the `mwctl` serial CLI and the
`payload-sim` WASM payload simulator (wasmi). Its own test suites run as it
is built, 367 tests, the Zenoh and gRPC ones over loopback. The smoke test
makes an Ed25519 key with `mwctl` and runs the `echo.wat` payload template
in `payload-sim`.

Its tests run on linux-none with `-Zpanic-abort-tests` (each test in a child
process), which cargo passes on to rustc only when the profile says
`panic = "abort"`: the target's default isn't enough, so the builder sets
it. Without it, libtest runs the tests in-process, and the first panic
aborts the whole run before its message is printed.

## What doesn't, and why

The other 2 (as of nixpkgs `1d06008`):

- `huniq` uses the removed `stdsimd` feature (an old `ahash` on a new
  nightly);
- `gitui` builds OpenSSL from source (`vendor-openssl`), which
  `openssl-src` doesn't know how to configure for linux-none, and which
  would need much more of a C library than rt has.

The `rust-std` input is `github:jvishnefske/rust-std`. Run
`nix flake update rust-std` to build on its latest commit, or
`--override-input rust-std git+file://$PWD/../rust-std` to build on a local
checkout, uncommitted changes included. (Not `path:`, which copies its
`target/` directories into the store.)
