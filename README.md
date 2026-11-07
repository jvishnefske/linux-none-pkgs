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
  `target_env`;
- the rustflags are those of rust-std's `apps/.cargo/config.toml`
  (`+crt-static`, static relocation model, `-no-pie`).

Only the executables are installed: no man pages, shell completions or
wrappers from the nixpkgs `postInstall`.

To add a package, add its nixpkgs attribute name to `selection` in
`flake.nix` with a smoke test.

## What builds

Six of the 39 packages tried. Each one is a static ELF with no
undefined symbols, and passes a smoke test (`checks` in `flake.nix`).

| package | version | smoke test |
|---|---|---|
| sd | 1.0.0 | replace on stdin, and in a file in place |
| hexyl | 0.17.0 | hex dump of stdin |
| grex | 1.4.6 | regex from examples |
| shellharden | 4.3.2 | quote a variable |
| rnr | 0.5.1 | rename files by regex |
| ruplacer | 0.10.0 | replace in a directory tree |

## What doesn't, and why

The other 33, by cause (as of nixpkgs `1d06008`):

- **Calls libc functions.** The libc crate gives the types and
  constants, but there is no libc to supply its functions, so the link
  fails on undefined symbols. Some only need a few that are thin
  syscall wrappers:
  - `choose`: `isatty`
  - `tokei`: `ioctl`, `syscall`
  - `stylua`: `isatty`, `sched_getaffinity`, `sysconf`
  - `typos`: `mmap`, `munmap`, `uname`, `dl_iterate_phdr`
  - `zoxide`: `getuid`, `getpwuid_r`, `sysconf`, `exp`
  - `htmlq`: `isatty`, `pow`
  - `fastmod`, `dust`, `fd`, `dua`, `tealdeer`, `jql`, `pastel`: more
    (signals, semaphores, epoll, `fork`/`execvp`, `dlsym`, ...)
- **C code**, which needs a C library: `ripgrep` (pcre2), `bat`, `eza`
  and `lsd` (libgit2/oniguruma), `oxipng`, `hck` (zlib-ng), `taplo` and
  `xh` (OpenSSL), `bottom` (`-ldl`).
- **The `nix` crate has no linux-none arm** (`__fsword_t`, `O_FSYNC`
  missing): `hyperfine`, `jaq`, `just`, `delta`, `fselect`, `broot`.
- **`socket2` has no linux-none arm** (`IovLen`): `mdbook`, `procs`,
  `skim`.
- **Other:** `huniq` uses the removed `stdsimd` feature (an old `ahash`
  on a new nightly); `gitui`'s build script wants environment the
  nixpkgs derivation sets, which `linuxNone` doesn't copy.

A Rust implementation of the common libc functions on top of the
runtime's syscalls, and the libc-style fixup for `nix` and `socket2`,
would cover most of the first, third and fourth groups.

The `rust-std` input is `git+file:///home/j/src/rust-std`: it builds from
the committed state of that repo. Run `nix flake update rust-std` after
committing there.
