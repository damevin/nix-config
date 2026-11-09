{ lib, stdenvNoCC, fetchurl, unzip }:
stdenvNoCC.mkDerivation rec {
  pname = "magpie";
  version = "0.1.3413";

  src = fetchurl {
    url = "https://github.com/yetone/magpie-releases/releases/download/v${version}/magpie-darwin-arm64.zip";
    sha256 = "77ef2aa04c3d646677f6245fefa1dea377fb7ff8e204d11132ff679379545e8f";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # the bundle is signed and notarised; any rewrite breaks it

  installPhase = ''
    mkdir -p $out/Applications $out/bin
    cp -R magpie.app $out/Applications/
    ln -s $out/Applications/magpie.app/Contents/MacOS/magpie $out/bin/magpie
  '';

  meta = {
    description = "One local gateway and model switcher for coding agents";
    homepage = "https://usemagpie.ai";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
