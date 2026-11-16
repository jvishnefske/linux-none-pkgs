{
  description = "A Rust crate built for x86_64-unknown-linux-none (std without a libc)";

  inputs.linux-none-pkgs.url = "github:jvishnefske/linux-none-pkgs";

  outputs = { self, linux-none-pkgs }:
    let
      pkgs = linux-none-pkgs.inputs.nixpkgs.legacyPackages.x86_64-linux;
      # the crate as nixpkgs would build it; buildLinuxNone rebuilds it with
      # std for linux-none, from the same sources and vendored crates
      crate = pkgs.rustPlatform.buildRustPackage {
        pname = "hello";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;
      };
    in
    {
      # static, non-PIE executables in result/bin; the second argument can
      # set `extraCargoFlags` and `tests` (cargo test flags)
      packages.x86_64-linux.default = linux-none-pkgs.lib.buildLinuxNone crate { };
    };
}
