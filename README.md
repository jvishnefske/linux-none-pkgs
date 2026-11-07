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
- C code in crates (ring, aws-lc, zstd, ...) is compiled by their build
  scripts with the host's gcc, with Nix's hardening flags off: rt has no
  `__stack_chk_fail` or `_FORTIFY_SOURCE`'s `__*_chk` functions. It links
  where rt's C functions (`malloc`, pthread mutexes, ...) are all it calls;
- the rustflags are those of rust-std's `apps/.cargo/config.toml`
  (`+crt-static`, static relocation model, `-no-pie`).

`overrides` in `flake.nix` changes a package first where needed: ripgrep
is built without its pcre2 feature, which is C.

Only the executables are installed: no man pages, shell completions or
wrappers from the nixpkgs `postInstall`.

To add a package, add its nixpkgs attribute name to `selection` in
`flake.nix` with a smoke test. The packages that don't build yet are in
`candidates`: `nix build .#candidates.bat` shows why.

## What builds

28 of the 41 packages tried. Each one is a static ELF with no
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

## What doesn't, and why

The other 13, by cause (as of nixpkgs `1d06008`):

- **C code that needs more of a C library** than rt has:
  - `bat`, `eza`, `lsd`, `delta`: libgit2 or oniguruma (`strncpy`,
    `strncasecmp`, `mkdir`, ...)
  - `fselect` (`pthread_rwlock_*`), `jaq` (`pthread_key_*`, `select`),
    `jql` (`pthread_getattr_np`, ...), `skim` (`killpg`, `mkfifo`)
  - `hck` (zlib-ng), `taplo` and `xh` (OpenSSL): their build scripts look
    for the C library and fail
- **Other:** `huniq` uses the removed `stdsimd` feature (an old `ahash`
  on a new nightly); `gitui`'s build script wants environment the
  nixpkgs derivation sets, which `linuxNone` doesn't copy.

Some of these may have cargo features that drop their C parts, as
ripgrep's pcre2 feature does; an override in `overrides` would then get
them building.

The `rust-std` input is `git+file:///home/j/src/rust-std`: it builds from
the committed state of that repo. Run `nix flake update rust-std` after
committing there.
