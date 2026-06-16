# Homebrew formula for the Bento daemon + CLI.
#
# Distributed via this repo as a "single-file tap":
#   brew tap NovaShang/bento https://github.com/NovaShang/bento
#   brew install bento
#
# Stable URLs point at the prebuilt tarballs uploaded by
# `.github/workflows/release.yml`. The version + checksums are rewritten
# by that workflow after each tagged release; do not edit by hand.
#
# The HEAD spec lets developers track main directly: `brew install --HEAD
# bento` builds from source instead of pulling a release tarball.
class Bento < Formula
  desc "Bento daemon + CLI: relay-routed SSH bridge for the Bento iOS app"
  homepage "https://github.com/NovaShang/bento"
  license  "Apache-2.0"

  # Stable tarballs (filled in by .github/workflows/release.yml).
  version "0.0.1-rc3"

  on_macos do
    on_arm do
      url "https://github.com/NovaShang/bento/releases/download/v0.0.1-rc3/bento-darwin-arm64.tar.gz"
      sha256 "1f7ccfafa6d87dff5272f03d4d6e6e5ce34d8d87555d5af356ec51ebaeec7750"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/NovaShang/bento/releases/download/v0.0.1-rc3/bento-linux-x86_64.tar.gz"
      sha256 "5591ca4e7021ee663e1778c8ea8386aa362496947c49546dbc2c7161cc9fa23e"
    end
    on_arm do
      url "https://github.com/NovaShang/bento/releases/download/v0.0.1-rc3/bento-linux-arm64.tar.gz"
      sha256 "f17810f48399f4f16694f3980519e589c1906a0c21995da0893b764fa92842fe"
    end
  end

  # HEAD spec — `brew install --HEAD bento` builds from source. Useful
  # for contributors and for users who want to track main between
  # releases. Stable users get the prebuilt tarball above.
  head do
    url "https://github.com/NovaShang/bento.git", branch: "main"
    depends_on "go" => :build
  end

  def install
    if build.head?
      # Build daemon + CLI from source.
      cd "desktop" do
        system "go", "build", "-ldflags=-s -w -X main.version=#{version}",
               "-o", "bento-daemon", "./cmd/bento-daemon"
        system "go", "build", "-ldflags=-s -w -X main.version=#{version}",
               "-o", "bento", "./cmd/bento"
        bin.install "bento-daemon"
        bin.install "bento"
      end
    else
      # Prebuilt tarball: bento + bento-daemon at the archive root; the
      # optional bundled tmux lives under bundled/ so it stays off PATH and
      # never shadows the user's own tmux. `bento tmux` resolves to it.
      bin.install "bento-daemon"
      bin.install "bento"
      (bin/"bundled").install "bundled/tmux" if File.exist?("bundled/tmux")
    end
  end

  test do
    assert_match(/^bento /, shell_output("#{bin}/bento version"))
    assert_match(/^bento-daemon /, shell_output("#{bin}/bento-daemon version"))
  end
end
