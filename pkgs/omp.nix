{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation rec {
  pname = "omp";
  version = "18.18.3";

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-darwin-arm64";
    sha256 = "87e8e593046dfb1047e359ad845648ffc8bda91aa59a9785690d5107f562c32d";
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # a compiled Bun binary: stripping or patching corrupts it

  installPhase = ''
    install -Dm755 $src $out/bin/omp
  '';

  meta = {
    description = "Oh My Pi: coding agent with the IDE wired in (release binary)";
    homepage = "https://github.com/can1357/oh-my-pi";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "omp";
  };
}
