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

      # Empty libc.a, libdl.a, ...: some crates ask the linker for them, and
      # on linux-none the runtime provides their functions (as musl's libc
      # holds libdl's, libm's and libpthread's)
      emptyLibs = pkgs.runCommand "linux-none-empty-libs" { } ''
        mkdir -p $out/lib
        for l in c dl m pthread rt util; do printf '!<arch>\n' > $out/lib/lib$l.a; done
      '';

      # Rebuild a nixpkgs `buildRustPackage` package from its own source and
      # vendored crates, with std built from the patched tree. Only the
      # binaries are kept: no man pages, completions or wrappers.
      linuxNone = pkg: { extraCargoFlags ? [ ] }:
        let
          deps = pkg.cargoDeps;
          # crates.io: the package's crates plus std's (rust-src vendors them).
          # libc gets std's fixup (musl's types and constants, nothing to
          # link); crates that pick libc's glibc or musl definitions by
          # target_env get musl's. Patched crates lose their file checksums.
          registry = pkgs.runCommand "${pkg.pname}-linux-none-registry" { nativeBuildInputs = [ xtask pkgs.jq ]; } ''
            mkdir $out
            for d in ${deps}/source-registry-0/* ${std-src}/library/vendor/*; do
              n=$(basename $d)
              [ -e $out/$n ] && continue
              case $n in
                libc-*) fixup=libc-fixup ;;
                *) grep -rqs 'target_env = "musl"' $d/src && fixup=musl-cfg || fixup= ;;
              esac
              if [ -z "$fixup" ]; then
                ln -s $d $out/$n
                continue
              fi
              cp -r $d $out/$n
              chmod -R u+w $out/$n
              xtask $fixup $out/$n
              jq -c '.files = {}' $d/.cargo-checksum.json > $out/$n/.cargo-checksum.json
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
            rustflags = ["-C", "target-feature=+crt-static", "-C", "relocation-model=static", "-C", "link-arg=-no-pie", "-L", "native=${emptyLibs}/lib"]
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
        fd = ''
          mkdir -p a/b && touch a/b/m.rs a/x.txt
          [ "$(fd -e rs . a)" = a/b/m.rs ]
        '';
        dust = ''
          mkdir -p a && head -c 100000 /dev/zero > a/f
          dust -b -c a | grep -q ' a$'
        '';
        choose = ''
          [ "$(echo 'a b c' | choose 1)" = b ]
        '';
        typos = ''
          echo 'teh word' > t.txt
          ! typos t.txt > out
          grep -q '`teh` should be `the`' out
        '';
        stylua = ''
          [ "$(echo 'local x   =  1' | stylua -)" = "local x = 1" ]
        '';
        htmlq = ''
          [ "$(echo '<p><a href=x>hi</a></p>' | htmlq --text a)" = hi ]
        '';
        pastel = ''
          [ "$(pastel format hex 'rgb(255,0,0)')" = "#ff0000" ]
        '';
        fastmod = ''
          mkdir m && echo 'teh word' > m/t.txt
          fastmod --accept-all teh the m
          [ "$(cat m/t.txt)" = "the word" ]
        '';
        zoxide = ''
          export _ZO_DATA_DIR=$PWD/z
          mkdir -p some/dir
          zoxide add some/dir
          [ "$(zoxide query dir)" = "$PWD/some/dir" ]
        '';
        ripgrep = ''
          mkdir s && printf 'a\nneedle here\n' > s/f.txt
          [ "$(rg -n needle s)" = "s/f.txt:2:needle here" ]
        '';
        tokei = ''
          mkdir t && printf 'fn main() {\n    // hi\n}\n' > t/m.rs
          tokei t | grep -E '^ *Rust +1 +3 +2 +1 +0'
        '';
        hyperfine = ''
          hyperfine -N --runs 3 --export-json h.json true
          grep -q '"command": "true"' h.json
        '';
        dua = ''
          mkdir u && head -c 10000 /dev/zero > u/f
          dua u | grep -q 'KiB f$'
        '';
        just = ''
          printf 'hello:\n\techo hi-from-just\n' > justfile
          [ "$(just hello 2>/dev/null)" = hi-from-just ]
        '';
        mdbook = ''
          mkdir -p book/src && printf '[book]\ntitle = "t"\n' > book/book.toml
          printf '# Summary\n\n- [Ch](ch.md)\n' > book/src/SUMMARY.md && echo '# Ch' > book/src/ch.md
          mdbook build book && grep -q '<h1' book/book/ch.html
        '';
        # interactive: check that it starts
        broot = ''
          broot --print-shell-function bash | grep -q broot
        '';
        procs = ''
          procs --no-header --color disable --pager disable $$ | grep -q "$$"
        '';
        # a terminal UI: check that it starts
        bottom = ''
          btm --version | grep -q bottom
        '';
      };

      # packages changed for linux-none: without their C parts
      overrides = {
        # pcre2 is C
        ripgrep = pkgs.ripgrep.overrideAttrs { buildFeatures = [ ]; };
      };

      built = lib.mapAttrs (name: _: linuxNone (overrides.${name} or pkgs.${name}) { }) selection;

      # packages tried that don't build yet (see the README), to retry with
      # `nix build .#candidates.<name>`
      candidates = lib.genAttrs [
        "jaq" "taplo" "hck"
        "huniq" "jql" "tealdeer" "oxipng" "eza" "lsd"
        "bat" "gitui" "delta" "xh" "fselect" "skim"
      ] (name: linuxNone pkgs.${name} { });

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

      legacyPackages.${system}.candidates = candidates;

      checks.${system} = lib.mapAttrs check selection;

      packages.${system} = built // {
        default = pkgs.symlinkJoin { name = "linux-none-pkgs"; paths = lib.attrValues built; };
      };
    };
}
