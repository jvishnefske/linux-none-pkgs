# The same packages built three ways (linux-none, musl static, glibc) and
# measured side by side: `nix run .#bench` writes bench/results.md.
{ pkgs, lib, built, middlewareArgs, middleware, nixpkgs }:
let
  # as linux-none-pkgs builds them: ripgrep without pcre2 (C), and
  # middleware from its repository. Tests are skipped: they ran in the
  # linux-none builds' checks.
  variants = {
    linux-none = {
      ripgrep = built.ripgrep;
      fd = built.fd;
      static-web-server = built.static-web-server;
      middleware = built.middleware;
    };
    musl = with pkgs.pkgsStatic; {
      ripgrep = (ripgrep.override { withPCRE2 = false; }).overrideAttrs { doCheck = false; };
      inherit fd static-web-server;
      middleware = rustPlatform.buildRustPackage (middlewareArgs // { doCheck = false; });
    };
    glibc = with pkgs; {
      ripgrep = (ripgrep.override { withPCRE2 = false; }).overrideAttrs { doCheck = false; };
      inherit fd static-web-server;
      middleware = rustPlatform.buildRustPackage (middlewareArgs // { doCheck = false; });
    };
  };

  # one `<package> <variant> <bin dir>` line per build
  bins = pkgs.writeText "bench-bins" (lib.concatStrings (lib.concatMap
    (p: map (v: "${p} ${v} ${variants.${v}.${p}}/bin\n") [ "linux-none" "musl" "glibc" ])
    (lib.attrNames variants.linux-none)));

  echoWasm = pkgs.runCommand "echo.wasm" { nativeBuildInputs = [ pkgs.wabt ]; } ''
    wat2wasm ${middleware}/payloads/templates/echo.wat -o $out
  '';
in
pkgs.writeShellApplication {
  name = "linux-none-bench";
  runtimeInputs = with pkgs; [ hyperfine oha strace time binutils openssl curl jq coreutils gnugrep gnused gawk procps ];
  runtimeEnv = {
    BINS = bins;
    # a big tree for rg and fd to walk: nixpkgs' own source
    TREE = "${nixpkgs}";
    ECHO_WASM = echoWasm;
  };
  text = builtins.readFile ./bench.sh;
}
