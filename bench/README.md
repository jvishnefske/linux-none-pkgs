# Benchmarks

`nix run .#bench` builds ripgrep, fd, static-web-server (hyper and rustls)
and middleware's `payload-sim` three ways: linux-none (this flake's
builder), musl static (`pkgsStatic`) and glibc (nixpkgs). It then
measures them on the machine it runs on and writes
[`results.md`](results.md). Run it on an idle machine: the server and the
tree walks are sensitive to load. `BENCH_RUNS` and `BENCH_SECS` set the
repetitions and the server's load duration.

## What the numbers say (2026-11-16, `results.md`)

Measured on an 18-CPU VM that was not idle (load average about 6), with
rust-std at `8527031` (`--override-input rust-std`), which adds the
allocator caches to the locked revision.

- **Startup** is where linux-none wins clearly: 0.25–0.41 ms for
  `--version`, against 0.5–1.2 ms for musl and 0.8–1.0 ms for glibc. There
  is no dynamic loader and almost no libc initialization.
- **Syscall surface**: linux-none makes the fewest distinct syscalls in
  every workload. ripgrep makes 26, against 33 for musl and 38 for glibc;
  the web server 39, against 49 and 51. That small, complete set is what
  `cargo xtask syscalls` and rt's `LINUX_NONE_SECCOMP` (rust-std) turn
  into a sandbox.
- **Throughput** beats musl everywhere. Against glibc it is even on the
  parallel tree walks (fd 42 vs 43 ms, ripgrep 89 vs 96 ms) and ahead
  on the single-threaded WASM interpreter (262 vs 274 ms). These numbers
  come after rt got per-thread allocator caches. Before that, its single
  lock made fd and ripgrep 3–6× slower than glibc, so the first run of
  this benchmark found that. musl's own allocator is why musl fd takes
  435 ms. musl ripgrep uses jemalloc, which ripgrep selects on musl.
- **The web server** is the exception: linux-none serves 3585 requests/s,
  against glibc's 4801 (and musl's 2591), while making about 1.5× as many
  syscalls per request (futex, most likely, from the runtime's locks under
  tokio). Its peak RSS is 20 MiB, where glibc's and musl's are 167 and
  276 MiB, which suggests their allocators keep per-thread arenas that
  linux-none's doesn't.
- **Size** is a wash: within ±10% of the others, smaller than musl's for
  ripgrep (no jemalloc) and payload-sim.

The pitch, then, is not "faster than glibc". It is a static binary that
starts 2–3× faster than musl or glibc builds, matches glibc's throughput
(beating musl's), and whose whole syscall surface is known and
enforceable. The web server's gap to glibc is the next thing to look at.

Not measured: Eyra, which the plan listed as best effort. It was not
attempted.
