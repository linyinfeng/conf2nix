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
      message "usage: conf2nix <kconfig-config> --arg kernel <nix-expr> <extra args to nix>..."
    }

    function nix_wrapper {
      nix --extra-experimental-features "nix-command flakes" "$@"
    }

    if [ $# -lt 1 ]; then
      usage
      exit 1
    fi

    original_config_path="$1"
    shift 1
    nix_args=("$@")
    config=$(realpath "$original_config_path")

    tmp=$(mktemp --directory -t "conf2nix.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT

    # create template
    cat >"$tmp/conf2nix.nix" <<EOF
      { pkgs ? import <nixpkgs> { }, ... }@args:
      let
        inherit (pkgs) lib;
        conf2nix = import "${self}/conf2nix" { inherit lib; };
        configFile = builtins.path { name = "config"; path = /. + "$config"; };
        conf2nixArgs = lib.attrsets.removeAttrs args [ "pkgs" ];
      in
      conf2nix ({
        inherit configFile;
      } // conf2nixArgs)
    EOF

    message "about to evaluate and build"
    message "---------------------------"
    cat "$tmp/conf2nix.nix" >&2
    message "---------------------------"
    message "building..."
    derivation=$(nix_wrapper path-info --file "$tmp/conf2nix.nix" --derivation "''${nix_args[@]}")
    if nix_wrapper build  "$derivation^out" --out-link "$tmp/config.nix"; then
      message "done."
      message "---------------------------"
      cat "$tmp/config.nix"
    else
      function warning_filter {
        export original_config_path
        perl -p -e 's/\.config:/$ENV{original_config_path}:/g'
      }
      message "log substitution: '.config:' -> '$(echo ".config:" | warning_filter)'"
      nix_wrapper log "$derivation" | warning_filter >&2
      exit 1
    fi
  '';
}
