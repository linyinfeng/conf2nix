# SPDX-License-Identifier: MIT

{ lib }:
let
  helpMissingArgument = arg: ''
    missing argument '${arg}', please pass this argument or pass a 'preset' argument.
    - preset 'standalone': suitable for `.config` files which will be used in make oldconfig sololy
    - preset 'partial': suitable for fragments which will be merged into other `.config` file

    `lib.conf2nix` example:

        lib.conf2nix {
          ...
          ${arg} = ...;
          # or
          preset = "standalone"|"partial";
          ...
        }

    `conf2nix-wrapper` example:

        con2nix src .config --argstr preset standalone|partial ...
        con2nix src .config --arg ${arg} ...

    read `conf2nix/default.nix` for more information.
  '';
  argDefault =
    arg: preset: defined:
    assert lib.assertMsg (preset != null) (helpMissingArgument arg);
    defined.${preset};
  boolToEnv = b: if b then "1" else "0";
in
lib.makeOverridable (
  {
    pkgs ? import <nixpkgs> { },
    configFile,
    kernel ? null,
    src ? kernel.src,
    patches ? kernel.patches,
    kernelArch ? pkgs.stdenv.hostPlatform.linuxArch,

    preset ? null, # possible values: "standalone"|"partial"|null

    # in kconfig
    # '# CONFIG_XXX is not set' is the same as
    # 'CONFIG_XXX=n'
    stripComments ? argDefault "stripComments" preset {
      standalone = false; # respect make oldconfig behavior (`is not set` comments are no)
      partial = true;
    },
    ignoreInvisible ? argDefault "ignoreInvisible" preset {
      standalone = true;
      partial = false; # we do not have the full information for visiblilty in partial config
    },
    warnUnused ? true,
    outputN ? "no",
    warningAsError ? true,
    emptyStringWorkaround ? true,
    withPrompt ? true,
  }:
  let
    inherit (pkgs)
      stdenv
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

    makeFlags = [ "ARCH=${kernelArch}" ] ++ (stdenv.hostPlatform.linux-kernel.makeFlags or [ ]);

    env = {
      CONF2NIX_IGNORE_INVISIBLE = boolToEnv ignoreInvisible;
      CONF2NIX_OUTPUT_EMPTY_STRING = boolToEnv (!emptyStringWorkaround);
      CONF2NIX_OUTPUT_N = outputN;
      CONF2NIX_WARN_UNUSED = boolToEnv warnUnused;
      CONF2NIX_WITH_PROMPT = boolToEnv withPrompt;
    };

    buildPhase = ''
      runHook preBuild

      make $makeFlags build_nixconfig
      make $makeFlags nixconfig >config.nix \
        2> >(tee warnings >&2)

      if [ -s warnings ]; then
        ${
          if warningAsError then
            ''
              echo "warning as error enabled" >&2
              echo "please review symbols mentioned in warnings (if any)" >&2
              exit 1
            ''
          else
            "# do noting"
        }
      fi

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
