# Homebrew formula for the Bento daemon + CLI.
#
# Distributed via this repo as a "single-file tap":
#   brew install NovaShang/bento/bento-terminal
#
# The formula is named bento-terminal (not bento) because homebrew-core
# ships an unrelated formula called `bento` (WarpStream's stream
# processor) — a bare `brew install bento` resolves to that one. The
# installed binaries keep their short names: bento + bento-daemon.
#
# Stable URLs point at the prebuilt tarballs uploaded by
# `.github/workflows/release.yml`. The version + checksums are rewritten
# by that workflow after each tagged release; do not edit by hand.
#
# The HEAD spec lets developers track main directly: `brew install --HEAD
# NovaShang/bento/bento-terminal` builds from source instead of pulling a
# release tarball.
class BentoTerminal < Formula
  desc "Bento daemon + CLI: relay-routed SSH bridge for the Bento iOS app"
  homepage "https://github.com/NovaShang/bento"
  license  "Apache-2.0"

  # homebrew-core's `bento` (unrelated) also installs a `bento` binary.
  conflicts_with "bento", because: "both install a `bento` executable"

  # Stable tarballs (filled in by .github/workflows/release.yml).
  version "0.1.1"

  on_macos do
    on_arm do
      url "https://github.com/NovaShang/bento/releases/download/v0.1.1/bento-darwin-arm64.tar.gz"
      sha256 "65bae4fab90bbbb8226a6cd290d3f68faeacbfe1f1c6b3619728e40a80783384"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/NovaShang/bento/releases/download/v0.1.1/bento-linux-x86_64.tar.gz"
      sha256 "074b84e1ff8a2408f9a7a3e0f269fdecf835ae56b75bca0cee5b898b1cb15cb4"
    end
    on_arm do
      url "https://github.com/NovaShang/bento/releases/download/v0.1.1/bento-linux-arm64.tar.gz"
      sha256 "a646c77d51cf1d57fdf6b83a1397264cc673f482b27c949dc2b836380a9b8738"
    end
  end

  # HEAD spec — `brew install --HEAD NovaShang/bento/bento-terminal`
  # builds from source. Useful for contributors and for users who want to
  # track main between releases. Stable users get the prebuilt tarball.
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
