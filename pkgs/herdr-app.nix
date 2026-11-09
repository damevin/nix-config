{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation rec {
  pname = "herdr-app";
  version = "0.1.14";

  src = fetchurl {
    url = "https://releases.herdr.dev/app/${version}/herdr-app-macos-aarch64.tar.gz";
    sha256 = "0da6ca214214389ca39e05fdf6523fd6e4be423a4be7dfd39b677d68a410fa8b";
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # the bundle is Developer ID signed; any rewrite breaks it

  installPhase = ''
    mkdir -p $out/Applications $out/bin
    cp -R Herdr.app $out/Applications/
    ln -s $out/Applications/Herdr.app/Contents/MacOS/Herdr $out/bin/herdr-app
  '';

  meta = {
    description = "Herdr Desktop: native app for terminals and coding agents";
    homepage = "https://github.com/herdrdev/herdr-app";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
