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

        con2nix '...' .config --argstr preset standalone|partial ...
        con2nix '...' .config --arg ${arg} ...

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
    configFile,
    kernel,

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
    normalize ? argDefault "normalize" preset {
      standalone = true;
      partial = false;
    },
    warnUnused ? true,
    outputN ? "no",
    warningAsError ? true,
    emptyStringWorkaround ? true,
    withPrompt ? true,
  }:
  kernel.configfile.overrideAttrs (old: {
    name = "config.nix";

    # just use the full makeFlags from linuxManualConfig
    inherit (kernel) makeFlags;

    env = (old.env or { }) // {
      CONF2NIX_IGNORE_INVISIBLE = boolToEnv ignoreInvisible;
      CONF2NIX_OUTPUT_EMPTY_STRING = boolToEnv (!emptyStringWorkaround);
      CONF2NIX_OUTPUT_N = outputN;
      CONF2NIX_WARN_UNUSED = boolToEnv warnUnused;
      CONF2NIX_WITH_PROMPT = boolToEnv withPrompt;
      HOSTCFLAGS = lib.escapeShellArgs (
        (lib.optional (lib.versionAtLeast kernel.version "6.9") "-DCONF2NIX_LINUX_VERSION_GE_6_9_0")
        ++ (lib.optional (lib.versionAtLeast kernel.version "6.12") "-DCONF2NIX_LINUX_HAS_XALLOC_H")
      );
    };

    postPatch =
      (old.postPatch or "")
      + ''
        cp -v ${./conf2nix.c} scripts/kconfig/conf2nix.c
        echo "include ${./Makefile.conf2nix}" >> scripts/kconfig/Makefile
      '';

    buildPhase = ''
      make $makeFlags "''${makeFlagsArray[@]}" build_nixconfig

      cp -v ${configFile} .config
      ${lib.optionalString normalize ''
        make $makeFlags "''${makeFlagsArray[@]}" KCONFIG_CONFIG=.config olddefconfig
      ''}
      ${lib.optionalString stripComments ''
        echo "stripping line comments from .conifg..."
        sed --in-place=original 's/^#.*$//g' .config
      ''}
      make $makeFlags "''${makeFlagsArray[@]}" KCONFIG_CONFIG=.config nixconfig \
        >config.nix \
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
            ''
              echo "warning emitted" >&2
            ''
        }
      fi
    '';

    installPhase = ''
      cp config.nix "$out"
    '';

    dontFixup = true;
  })
)
