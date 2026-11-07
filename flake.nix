{
  description = "nixpkgs Rust packages rebuilt for x86_64-unknown-linux-none on the libc-free std";

  inputs = {
    rust-std.url = "git+file:///home/j/src/rust-std";
    nixpkgs.follows = "rust-std/nixpkgs";
  };

  outputs = { self, nixpkgs, rust-std }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      inherit (rust-std.packages.${system}) toolchain xtask std-src;
      target = "x86_64-unknown-linux-none";

      # Rebuild a nixpkgs `buildRustPackage` package from its own source and
      # vendored crates, with std built from the patched tree. Only the
      # binaries are kept: no man pages, completions or wrappers.
      linuxNone = pkg: { extraCargoFlags ? [ ] }:
        let
          deps = pkg.cargoDeps;
          # crates.io: the package's crates plus std's (rust-src vendors them).
          # libc gets std's fixup (musl's types and constants, nothing to
          # link), so its checksums of the files go.
          registry = pkgs.runCommand "${pkg.pname}-linux-none-registry" { nativeBuildInputs = [ xtask pkgs.jq ]; } ''
            mkdir $out
            for d in ${deps}/source-registry-0/* ${std-src}/library/vendor/*; do
              n=$(basename $d)
              [ -e $out/$n ] && continue
              case $n in
                libc-*)
                  cp -r $d $out/$n
                  chmod -R u+w $out/$n
                  xtask libc-fixup $out/$n
                  jq -c '.files = {}' $d/.cargo-checksum.json > $out/$n/.cargo-checksum.json
                  ;;
                *) ln -s $d $out/$n ;;
              esac
            done
          '';
          flags = lib.escapeShellArgs (
            (lib.optional (pkg.buildNoDefaultFeatures or false) "--no-default-features")
            ++ (lib.optionals ((pkg.buildFeatures or [ ]) != [ ]) [ "--features" (lib.concatStringsSep "," pkg.buildFeatures) ])
            ++ (pkg.cargoBuildFlags or [ ])
            ++ extraCargoFlags);
        in
        pkgs.stdenv.mkDerivation {
          pname = "${pkg.pname}-linux-none";
          inherit (pkg) version src;
          sourceRoot = pkg.sourceRoot or null;
          cargoRoot = pkg.cargoRoot or null;
          patches = pkg.patches or [ ];
          nativeBuildInputs = [ toolchain ];
          # static binaries: nothing for strip / patchelf to do
          dontFixup = true;
          configurePhase = ''
            runHook preConfigure
            export CARGO_HOME=$TMPDIR/cargo-home
            mkdir -p $CARGO_HOME
            # the package's own source replacements (git sources included),
            # with crates.io pointed at the merged registry
            sed -e 's|@vendor@|${deps}|' \
                -e 's|^directory = "${deps}/source-registry-0"$|directory = "${registry}"|' \
                ${deps}/.cargo/config.toml > $CARGO_HOME/config.toml
            cat >> $CARGO_HOME/config.toml <<'EOF'

            [net]
            offline = true

            [unstable]
            build-std = ["std", "panic_abort"]
            build-std-features = ["compiler-builtins-mem", "backtrace"]

            # static, non-PIE: the runtime does not relocate itself
            [target.${target}]
            rustflags = ["-C", "target-feature=+crt-static", "-C", "relocation-model=static", "-C", "link-arg=-no-pie"]
            EOF
            export __CARGO_TESTS_ONLY_SRC_ROOT=${std-src}/library
            export CARGO_TARGET_DIR=$NIX_BUILD_TOP/cargo-target
            runHook postConfigure
          '';
          buildPhase = ''
            runHook preBuild
            ${lib.optionalString ((pkg.cargoRoot or null) != null) "cd ${pkg.cargoRoot}"}
            ${lib.optionalString ((pkg.buildAndTestSubdir or null) != null) "cd ${pkg.buildAndTestSubdir}"}
            cargo build --release --frozen --target ${target} ${flags}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            find $CARGO_TARGET_DIR/${target}/release -maxdepth 1 -type f -executable -exec cp {} $out/bin/ \;
            runHook postInstall
          '';
          meta = lib.filterAttrs (n: _: lib.elem n [ "description" "homepage" "license" "mainProgram" ]) (pkg.meta or { }) // { platforms = [ system ]; };
        };

      # name -> smoke test, run in a directory with the package's bin/ on
      # PATH; the package is pkgs.<name>. See the README for the packages
      # that don't build yet, and why.
      selection = {
        sd = ''
          [ "$(echo hello world | sd world nix)" = "hello nix" ]
          echo foo > f && sd foo bar f && [ "$(cat f)" = bar ]
        '';
        hexyl = ''
          printf 'linux-none' | hexyl --plain | grep -q '6c 69 6e 75 78 2d 6e 6f'
        '';
        grex = ''
          [ "$(grex foo foobar)" = '^foo(?:bar)?$' ]
        '';
        shellharden = ''
          echo 'echo $1' > s.sh
          [ "$(shellharden --transform s.sh)" = 'echo "$1"' ]
        '';
        rnr = ''
          mkdir d && touch d/a-1 d/a-2
          rnr regex -f a- b- d/a-1 d/a-2
          [ -e d/b-1 ] && [ -e d/b-2 ] && [ ! -e d/a-1 ]
        '';
        ruplacer = ''
          mkdir r && echo hello world > r/t
          ruplacer world nix r --go
          [ "$(cat r/t)" = "hello nix" ]
        '';
      };

      built = lib.mapAttrs (name: _: linuxNone pkgs.${name} { }) selection;

      # static, non-PIE executables with no PT_INTERP / PT_DYNAMIC and no
      # undefined symbol, that pass the smoke test
      check = name: test: pkgs.runCommand "${name}-linux-none-check" { nativeBuildInputs = [ pkgs.binutils ]; } ''
        for f in ${built.${name}}/bin/*; do
          readelf -hW $f | grep -q "Type: *EXEC" || { echo "$f: not ET_EXEC"; exit 1; }
          ! readelf -lW $f | grep -qE "INTERP|DYNAMIC" || { echo "$f: dynamically linked"; exit 1; }
          [ -z "$(nm -u $f 2>/dev/null)" ] || { echo "$f: undefined symbols:"; nm -u $f; exit 1; }
        done
        export PATH=${built.${name}}/bin:$PATH
        cd $TMPDIR
        set -e
        ${test}
        touch $out
      '';
    in
    {
      lib.${system}.linuxNone = linuxNone;

      checks.${system} = lib.mapAttrs check selection;

      packages.${system} = built // {
        default = pkgs.symlinkJoin { name = "linux-none-pkgs"; paths = lib.attrValues built; };
      };
    };
}
