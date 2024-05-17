{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    crane.url = "github:ipetkov/crane";
    crane.inputs.nixpkgs.follows = "nixpkgs";

    flake-compat.url = "github:edolstra/flake-compat";
    flake-compat.flake = false;
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      {
        self,
        inputs,
        lib,
        ...
      }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        imports = [
          inputs.flake-parts.flakeModules.easyOverlay
          inputs.treefmt-nix.flakeModule
        ];
        flake.lib.conf2nix = import ./conf2nix { inherit (inputs.nixpkgs) lib; };
        perSystem =
          {
            config,
            self',
            pkgs,
            system,
            ...
          }:
          let
            craneLib = inputs.crane.lib.${system};
            src = craneLib.cleanCargoSource (craneLib.path ./nconf2nix);
            bareCommonArgs = {
              inherit src;
              nativeBuildInputs = with pkgs; [ installShellFiles ];
              buildInputs = [ ];
            };
            cargoArtifacts = craneLib.buildDepsOnly bareCommonArgs;
            commonArgs = bareCommonArgs // {
              inherit cargoArtifacts;
            };

            linuxEditorSettings =
              pkgs.runCommand "linux-editor-settings" { inherit (pkgs.linux_latest) src; }
                ''
                  runPhase unpackPhase
                  mkdir -p "$out"
                  cp ".clang-format" "$out/"
                  cp ".editorconfig" "$out/"
                '';
          in
          {
            packages = {
              conf2nix-wrapper = pkgs.callPackage ./conf2nix-wrapper { inherit self; };
              nconf2nix = craneLib.buildPackage (
                commonArgs
                // {
                  postInstall = ''
                    installShellCompletion --cmd conf2nix \
                      --bash <($out/bin/conf2nix completion bash) \
                      --fish <($out/bin/conf2nix completion fish) \
                      --zsh  <($out/bin/conf2nix completion zsh)
                  '';
                }
              );
            };
            overlayAttrs = {
              inherit (config.packages) nconf2nix conf2nix-wrapper;
            };
            checks =
              {
                # checks for nconf2nix
                inherit (self'.packages) nconf2nix;
                nconf2nix-doc = craneLib.cargoDoc commonArgs;
                nconf2nix-fmt = craneLib.cargoFmt { inherit src; };
                nconf2nix-nextest = craneLib.cargoNextest commonArgs;
                nconf2nix-clippy = craneLib.cargoClippy (
                  commonArgs // { cargoClippyExtraArgs = "--all-targets -- --deny warnings"; }
                );
              }
              // (
                # checks for conf2nix
                let
                  testKernels = {
                    linux = pkgs.linux;
                    linux_latest = pkgs.linux_latest;
                  };
                in
                lib.fold lib.recursiveUpdate { } (
                  lib.mapAttrsToList (kernelName: kernel: {
                    "conf2nix-${kernelName}" = self.lib.conf2nix {
                      # test build on a generated full kernel configuration
                      configFile = kernel.configfile;
                      kernel = kernel;
                      preset = "standalone";
                    };
                    "conf2nix2conf-${kernelName}" =
                      (pkgs.buildLinux {
                        inherit (kernel) src version patches;
                        structuredExtraConfig = import self'.checks."conf2nix-${kernelName}" { inherit lib; };
                        # since we generate on the final kernel configuration with preset standalone
                        # it is already included in self'.checks..conf2nix
                        enableCommonConfig = false;
                      }).configfile;
                    "confEqualsToConf2nix2conf-${kernelName}" = pkgs.runCommand "conf-equal-test" { } ''
                      diff "${kernel.configfile}" "${self'.checks."conf2nix2conf-${kernelName}"}"
                      touch "$out"
                    '';
                  }) testKernels
                )
              );
            treefmt = {
              projectRootFile = "flake.nix";
              programs = {
                nixfmt-rfc-style.enable = true;
                rustfmt.enable = true;
                prettier.enable = true;
                taplo.enable = true;
                clang-format.enable = true;
              };
              settings.formatter.clang-format = {
                options = [ "-style=file:${linuxEditorSettings}/.clang-format" ];
              };
            };
            devShells.default = pkgs.mkShell {
              inputsFrom = lib.attrValues self'.checks;
              packages = with pkgs; [
                rustup
                rust-analyzer
              ];
              shellHook = ''
                ln -sf "${linuxEditorSettings}/"{.clang-format,.editorconfig} .
              '';
            };
          };
      }
    );
}
