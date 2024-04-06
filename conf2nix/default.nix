# SPDX-License-Identifier: MIT

{ lib }:
lib.makeOverridable (
  {
    pkgs ? import <nixpkgs> { },
    configFile,
    kernel ? null,
    src ? kernel.src,
    patches ? kernel.patches,
    stdenv ? pkgs.stdenv,
    kernelArch ? stdenv.hostPlatform.linuxArch,
    # in kconfig
    # '# CONFIG_XXX is not set' is the same as
    # 'CONFIG_XXX=n'
    stripComments ? false,
    outputN ? "no",
    warnUnused ? true,
    warningAsError ? true,
    emptyStringWorkaround ? true,
    withPrompt ? true,
  }:
  let
    inherit (pkgs)
      buildPackages
      makeWrapper
      flex
      bison
      ;
  in
  stdenv.mkDerivation (finalAttrs: {
    name = "config.nix";
    inherit src patches;

    depsBuildBuild = [ buildPackages.stdenv.cc ];
    nativeBuildInputs = [
      makeWrapper
      flex
      bison
    ];

    postPatch = ''
      [[ -f scripts/ld-version.sh ]] && patchShebangs scripts/ld-version.sh

      cp -v ${./conf2nix.c} scripts/kconfig/conf2nix.c
      echo "include ${./Makefile.conf2nix}" >> scripts/kconfig/Makefile
      cp -v ${configFile} .config

      ${lib.optionalString stripComments ''
        echo "stripping line comments from .conifg..."
        sed --in-place=original 's/^#.*$//g' .config
      ''}
    '';

    makeFlags =
      [ "ARCH=${kernelArch}" ]
      ++ (stdenv.hostPlatform.linux-kernel.makeFlags or [ ]);

    env = {
      CONF2NIX_OUTPUT_EMPTY_STRING = if emptyStringWorkaround then "0" else "1";
      CONF2NIX_OUTPUT_N = outputN;
      CONF2NIX_WARN_UNUSED = if warnUnused then "1" else "0";
      CONF2NIX_WITH_PROMPT = if withPrompt then "1" else "0";
    };

    buildPhase = ''
      runHook preBuild

      make $makeFlags build_nixconfig
      make $makeFlags nixconfig >config.nix 2>conf2nix_warnings

      ${
        if warningAsError then
          ''
            if [ -s conf2nix_warnings ]; then
              echo "--- errors ---"
              cat conf2nix_warnings
              exit 1
            fi
          ''
        else
          ''
            if [ -s conf2nix_warnings ]; then
              echo "--- warnings ---"
              cat conf2nix_warnings
            fi
          ''
      }

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp config.nix "$out"
      runHook postInstall
    '';

    dontFixup = true;
  })
)
