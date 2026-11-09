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
          # the package's build tools (cmake, pkg-config, ...), not
          # nixpkgs' cargo and rustc and their hooks
          nativeBuildInputs = [ toolchain ]
            ++ lib.filter (d: !lib.any (p: lib.hasPrefix p (d.name or "")) [ "cargo" "auditable-cargo" "rustc" ])
              (pkg.nativeBuildInputs or [ ]);
          # static binaries: nothing for strip / patchelf to do
          dontFixup = true;
          # C code in crates (ring, zstd) is compiled with the host's gcc;
          # without the hardening flags, it needs no __stack_chk_fail or
          # *_chk functions, which there is no libc to provide
          hardeningDisable = [ "all" ];
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
            # for C libraries built with cmake (the cmake crate): there is no
            # libc.a for its compiler checks to link against, so they build a
            # static library instead
            cat > $TMPDIR/linux-none.cmake <<'EOF'
            set(CMAKE_SYSTEM_NAME Linux)
            set(CMAKE_SYSTEM_PROCESSOR ${builtins.head (lib.splitString "-" target)})
            set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
            EOF
            export CMAKE_TOOLCHAIN_FILE_${lib.replaceStrings [ "-" ] [ "_" ] target}=$TMPDIR/linux-none.cmake
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
        oxipng = ''
          echo iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg== | base64 -d > p.png
          oxipng -o 2 --out o.png p.png 2>&1 | grep -q 'Files processed: 1/1'
          [ "$(head -c 4 o.png | tail -c 3)" = PNG ]
        '';
        # it needs a network to fetch its pages
        tealdeer = ''
          tldr --version | grep -q tealdeer
        '';
        # C code in crates: oniguruma and libgit2, zlib-ng, mimalloc
        bat = ''
          printf 'fn main() {}\n' > m.rs
          [ "$(bat -p --color=never m.rs)" = "fn main() {}" ]
          bat -p --color=always m.rs | grep -q "$(printf '\033')\["
        '';
        eza = ''
          mkdir d && touch d/a d/b
          [ "$(eza -1 d)" = "$(printf 'a\nb')" ]
          eza -l --git d | grep -q ' b$'
        '';
        lsd = ''
          mkdir d && touch d/a d/b
          [ "$(lsd -1 --color never --icon never d)" = "$(printf 'a\nb')" ]
        '';
        delta = ''
          printf 'one\ntwo\n' > x && printf 'one\nthree\n' > y
          ! delta --no-gitconfig --color-only x y > o
          grep -q three o
        '';
        fselect = ''
          mkdir d && touch d/a.rs d/b.txt
          [ "$(fselect name from d where name like '%.rs')" = a.rs ]
        '';
        jaq = ''
          [ "$(echo '{"a":[1,2]}' | jaq -c '.a | map(. * 2)')" = "[2,4]" ]
        '';
        jql = ''
          [ "$(echo '{"a":{"b":3}}' | jql '"a" "b"')" = 3 ]
        '';
        skim = ''
          [ "$(printf 'apple\nbanana\n' | sk --filter ban)" = banana ]
        '';
        hck = ''
          [ "$(printf 'a b c\n' | hck -f2)" = b ]
          printf 'x\ty\n' | gzip > f.gz
          [ "$(hck -z -f2 f.gz)" = y ]
        '';
        taplo = ''
          printf 'a   =  1\n' > t.toml
          taplo fmt t.toml 2>/dev/null
          [ "$(cat t.toml)" = "a = 1" ]
        '';
        # an HTTPS client (rustls on aws-lc), against miniserve (rustls on ring)
        xh = serve 8445 "${built.miniserve}/bin/miniserve www -i 127.0.0.1 -p 8445 --tls-cert cert.pem --tls-key key.pem" + ''
          [ "$(xh --ignore-stdin --verify ca.pem --body https://127.0.0.1:8445/hi.txt)" = hello ]
          kill %1
        '';
        # web servers, over TLS with rustls: ring's crypto, then aws-lc's
        miniserve = https 8443 "miniserve www -i 127.0.0.1 -p 8443 --tls-cert cert.pem --tls-key key.pem";
        static-web-server = https 8444
          "static-web-server --host 127.0.0.1 --port 8444 --root www --http2 --http2-tls-cert cert.pem --http2-tls-key key.pem";
      };

      # serve www/hi.txt over TLS, with a certificate for localhost and
      # 127.0.0.1 from a test CA (ca.pem): rustls checks the subjectAltName
      # and wants a CA that is not the server's own certificate
      serve = port: server: ''
        key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out $1 2>/dev/null; }
        key ca.key && key key.pem
        openssl req -x509 -key ca.key -out ca.pem -days 1 -subj /CN=test-ca 2>/dev/null
        openssl req -new -key key.pem -subj /CN=localhost 2>/dev/null |
          openssl x509 -req -CA ca.pem -CAkey ca.key -days 1 -out cert.pem 2>/dev/null \
            -extfile <(echo "subjectAltName=DNS:localhost,IP:127.0.0.1")
        mkdir www && echo hello > www/hi.txt
        ${server} &
        for i in $(seq 100); do curl -sf -o /dev/null --cacert ca.pem https://127.0.0.1:${toString port}/hi.txt && break; sleep 0.1; done
      '';

      # fetch it with curl, over HTTP/1.1 and 2
      https = port: server: serve port server + ''
        get() { curl -sf --cacert ca.pem --resolve localhost:${toString port}:127.0.0.1 "$@" https://localhost:${toString port}/hi.txt; }
        [ "$(get --http1.1)" = hello ] && [ "$(get --http2)" = hello ]
        kill %1
      '';

      # packages changed for linux-none: without their C parts
      overrides = {
        # pcre2 is C
        ripgrep = pkgs.ripgrep.overrideAttrs { buildFeatures = [ ]; };
        # rustls, their default, rather than nixpkgs' native-tls (OpenSSL)
        xh = pkgs.xh.overrideAttrs { buildFeatures = [ ]; };
        taplo = pkgs.taplo.overrideAttrs (o: {
          buildFeatures = map (f: if f == "native-tls" then "rustls-tls" else f) o.buildFeatures;
        });
      };

      built = lib.mapAttrs (name: _: linuxNone (overrides.${name} or pkgs.${name}) { }) selection;

      # packages tried that don't build yet (see the README), to retry with
      # `nix build .#candidates.<name>`
      candidates = lib.genAttrs [
        "huniq" "gitui"
      ] (name: linuxNone (overrides.${name} or pkgs.${name}) { });

      # static, non-PIE executables with no PT_INTERP / PT_DYNAMIC and no
      # undefined symbol (but weak ones), that pass the smoke test
      check = name: test: pkgs.runCommand "${name}-linux-none-check" { nativeBuildInputs = with pkgs; [ binutils curl openssl ]; } ''
        for f in ${built.${name}}/bin/*; do
          readelf -hW $f | grep -q "Type: *EXEC" || { echo "$f: not ET_EXEC"; exit 1; }
          ! readelf -lW $f | grep -qE "INTERP|DYNAMIC" || { echo "$f: dynamically linked"; exit 1; }
          # weak ones (aws-lc's optional hooks) are null in a static binary
          [ -z "$(nm -u $f 2>/dev/null | grep -v ' w ')" ] || { echo "$f: undefined symbols:"; nm -u $f; exit 1; }
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
