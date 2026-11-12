{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation rec {
  pname = "omp";
  version = "18.18.6";

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-darwin-arm64";
    hash = "sha256-7S5j60OIjrdssUCbJFsdtFV8lN+tUtxUXJqsoB686C0=";
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
