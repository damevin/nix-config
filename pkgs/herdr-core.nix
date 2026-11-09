{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation rec {
  pname = "herdr-core";
  version = "0.1.19";

  src = fetchurl {
    url = "https://releases.herdr.dev/core/${version}/herdr-core-macos-aarch64.tar.gz";
    sha256 = "5338d900adadb6d273b9c8e97027247db3179ccffede10a1793358f16e08d683";
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # the bundle is Developer ID signed; any rewrite breaks it

  installPhase = ''
    mkdir -p $out/libexec $out/bin
    cp -R . $out/libexec/herdr-core
    ln -s $out/libexec/herdr-core/herdr-core $out/bin/herdr-core
    ln -s $out/libexec/herdr-core/herdr-core $out/bin/hc
  '';

  meta = {
    description = "Herdr core: runs the terminals and agents behind Herdr Desktop";
    homepage = "https://github.com/herdrdev/herdr-core";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
