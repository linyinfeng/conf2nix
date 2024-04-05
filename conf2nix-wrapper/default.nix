{
  self,
  perl,
  writeShellApplication,
}:
writeShellApplication {
  name = "conf2nix";
  runtimeInputs = [ perl ];
  text = ''
    function message {
      echo "$@" >&2
    }

    function usage {
      message "usage: conf2nix <kernel-src> <kconfig-config> <extra args to nix>..."
    }

    function nix_wrapper {
      nix --extra-experimental-features "nix-command flakes" "$@"
    }

    if [ $# -lt 2 ]; then
      usage
      exit 1
    fi

    kernel_src=$(realpath "$1")
    original_config_path="$2"
    shift 2
    nix_args=("$@")
    config=$(realpath "$original_config_path")

    tmp=$(mktemp --directory -t "conf2nix.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT

    # create template
    cat >"$tmp/conf2nix.nix" <<EOF
      { pkgs ? import <nixpkgs> { }, ... }@args:
      let
        inherit (pkgs) lib;
        conf2nix = pkgs.callPackage "${self}/conf2nix" { };
        configFile = builtins.path { name = "config"; path = /. + "$config"; };
        originalSrc = "$kernel_src";
        src = if lib.isStorePath originalSrc then builtins.storePath originalSrc else lib.cleanSource originalSrc;
        conf2nixArgs = lib.attrsets.removeAttrs args [ "pkgs" ];
      in
      (conf2nix {
        inherit configFile src;
        patches = [];
      }).override conf2nixArgs
    EOF

    message "about to evaluate and build"
    message "---------------------------"
    cat "$tmp/conf2nix.nix" >&2
    message "---------------------------"
    message "setting up log path filter..."
    function warning_filter {
      export original_config_path
      perl -p -e 's/\.config:/$ENV{original_config_path}:/g'
    }
    message "log substitution: '.config:' -> '$(echo ".config:" | warning_filter)'"
    message "building..."
    nix_wrapper build \
      --file "$tmp/conf2nix.nix" \
      --out-link "$tmp/config.nix" \
      --print-build-logs \
      "''${nix_args[@]}" \
      2>&1 | warning_filter >&2
    message "done."
    message "---------------------------"
    cat "$tmp/config.nix"
  '';
}
