# SPDX-License-Identifier: MIT

{
  stdenv,
  makeWrapper,
  flex,
  bison,
  lib,
}:
lib.makeOverridable (
  {
    configFile,
    kernel ? null,
    src ? kernel.src,
    patches ? kernel.patches,
    # in kconfig
    # '# CONFIG_XXX is not set' is the same as
    # 'CONFIG_XXX=n'
    stripComments ? true,
    outputN ? "no",
    warnUnused ? true,
    warningAsError ? true,
    emptyStringWorkaround ? true,
    withPrompt ? true,
  }:
  stdenv.mkDerivation (finalAttrs: {
    name = "config.nix";
    inherit src patches;

    nativeBuildInputs = [
      makeWrapper
      flex
      bison
    ];
    postPatch = ''
      cp -v ${./conf2nix.c} scripts/kconfig/conf2nix.c
      echo "include ${./Makefile.conf2nix}" >> scripts/kconfig/Makefile
      cp -v ${configFile} .config
    '';
    env =
      lib.optionalAttrs emptyStringWorkaround {
        NIX_CFLAGS_COMPILE = "-DCONF2NIX_EMPTY_STRING_WORKAROUND=1";
      }
      // {
        CONF2NIX_WARN_UNUSED = if warnUnused then "1" else "0";
        CONF2NIX_WITH_PROMPT = if withPrompt then "1" else "0";
      };
    buildPhase = ''
      runHook preBuild
      make build_nixconfig
      ${lib.optionalString stripComments ''
        sed --in-place=original 's/^#.*$//g' .config
      ''}
      CONF2NIX_OUTPUT_N="${outputN}" make nixconfig >config.nix 2>conf2nix_warnings
      ${lib.optionalString warningAsError ''
        if [ -s conf2nix_warnings ]; then
          echo "--- warnings ---"
          cat conf2nix_warnings
          exit 1
        fi
      ''}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp config.nix "$out"
      runHook postInstall
    '';
    passthru = {
      inherit kernel;
    };
  })
)
