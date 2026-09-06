{
  description = "vicemergency — a DuckDB database of every change to the Victorian emergency feed";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs =
    inputs:
    let
      lib = inputs.nixpkgs.lib;

      eachSystem =
        f:
        lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system: f (import inputs.nixpkgs { inherit system; })
        );

      ingest = ./ingest;

      perSystem = eachSystem (
        pkgs:
        let
          # extract.sh shells out to all of these, and split/nproc/find/mktemp
          # come from coreutils and findutils.
          tools = with pkgs; [
            bash
            coreutils
            findutils
            git
            jq
            duckdb
          ];

          extract = pkgs.writeShellApplication {
            name = "vicemergency-extract";
            runtimeInputs = tools;
            text = ''
              export VICEMERGENCY_INGEST_DIR=${ingest}
              exec bash ${ingest}/extract.sh "$@"
            '';
          };

          build-db = pkgs.writeShellApplication {
            name = "vicemergency-build-db";
            runtimeInputs = [ pkgs.duckdb ];
            text = ''
              usage="usage: vicemergency-build-db <out.duckdb> <shards-glob>"
              db=''${1:?$usage}
              shards=''${2:?$usage}
              exec duckdb "$db" -c "SET VARIABLE shards='$shards'" -f ${ingest}/build-db.sql
            '';
          };

          # The pipeline over ingest/test/fixture.bundle: 200 real snapshots
          # replayed into their own repo, so this needs neither the network nor
          # the surrounding checkout's history.
          check = pkgs.writeShellApplication {
            name = "vicemergency-check";
            runtimeInputs = tools;
            text = ''
              export VICEMERGENCY_EXTRACT=${extract}/bin/vicemergency-extract
              exec bash ${ingest}/test/check.sh "$@"
            '';
          };

          app = drv: {
            type = "app";
            program = lib.getExe drv;
          };
        in
        {
          packages = {
            default = extract;
            vicemergency-extract = extract;
            vicemergency-build-db = build-db;
            vicemergency-check = check;
          };

          apps = {
            extract = app extract // {
              meta.description = "parquet shards from every events.json commit in a repo";
            };
            build-db = app build-db // {
              meta.description = "derived DuckDB tables from parquet shards";
            };
            check = app check // {
              meta.description = "run the pipeline over the bundled slice of history";
            };
          };

          checks = {
            inherit extract build-db;
            pipeline = pkgs.runCommand "vicemergency-pipeline" { } ''
              ${lib.getExe check} > $out
            '';
          };

          devShells.default = pkgs.mkShell {
            packages = tools ++ [ pkgs.zstd ];
          };
        }
      );

      collect = output: lib.mapAttrs (_: v: v.${output}) perSystem;
    in
    {
      packages = collect "packages";
      apps = collect "apps";
      checks = collect "checks";
      devShells = collect "devShells";
    };
}
