# Builds Zaslon from source on the user's Mac, so macOS has no reason to question the app.
#   brew tap eruma1ra/zaslon https://github.com/eruma1ra/zaslon
#   brew trust eruma1ra/zaslon
#   brew install zaslon
class Zaslon < Formula
  desc "VPN kill switch for AI apps: ChatGPT and Claude only through the WARP tunnel"
  homepage "https://github.com/eruma1ra/zaslon"
  url "https://github.com/eruma1ra/zaslon/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "c4345de75b9b02458f1fd2f5faf7b63441c3373f0ae25c49a4359d8471c233cf"
  license "MIT"
  head "https://github.com/eruma1ra/zaslon.git", branch: "main"

  depends_on macos: :sonoma

  def install
    # Homebrew builds inside its own sandbox, and SwiftPM cannot start a second one in it.
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "./build.sh"
    prefix.install "build/Zaslon.app"
    # `zaslon` opens the menu bar app; `zaslon --selftest` and the other checks go to the binary.
    (bin/"zaslon").write <<~SH
      #!/bin/sh
      if [ $# -eq 0 ]; then exec open "#{opt_prefix}/Zaslon.app"; fi
      exec "#{opt_prefix}/Zaslon.app/Contents/MacOS/Zaslon" "$@"
    SH
    chmod 0755, bin/"zaslon"
  end

  def caveats
    <<~EOS
      Start Zaslon with:
        zaslon
      It lives in the menu bar and offers to start at login.

      After `brew upgrade zaslon`, run `zaslon` once more: macOS starts the
      launch agent of a rebuilt app only after the app has registered it again.

      Zaslon needs Cloudflare WARP (warp-cli).
    EOS
  end

  test do
    assert_match "0 processes", shell_output("#{bin}/zaslon --cover zaslon-no-such-program")
  end
end
