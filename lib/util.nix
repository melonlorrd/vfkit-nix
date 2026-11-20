{ lib }:
rec {
  # Lists are appended, attrsets merged recursively, anything else replaced by the right side.
  mergeCloudConfig = a: b:
    a // lib.mapAttrs
      (k: bv:
        if !(a ? ${k}) then bv
        else
          let av = a.${k}; in
          if builtins.isList av && builtins.isList bv then av ++ bv
          else if builtins.isAttrs av && builtins.isAttrs bv then mergeCloudConfig av bv
          else bv)
      b;

  # ipAdd "10.0.0.11" 2 == "10.0.0.13" (stays inside the last octet)
  ipAdd = ip: n:
    let
      parts = lib.splitString "." ip;
      last = lib.toInt (lib.last parts) + n;
    in
    assert lib.assertMsg (builtins.length parts == 4 && last <= 254) "vfkit-nix: ${ip} + ${toString n} is not a valid address in the same /24";
    lib.concatStringsSep "." (lib.take 3 parts ++ [ (toString last) ]);

  # Stable, locally administered MAC address derived from a string.
  macFor = s:
    let h = builtins.hashString "sha256" s; in
    "02:" + lib.concatMapStringsSep ":" (i: builtins.substring (i * 2) 2 h) [ 0 1 2 3 4 ];
}
