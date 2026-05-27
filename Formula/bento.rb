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
  version "0.0.0"

  on_macos do
    on_arm do
      url "https://github.com/NovaShang/bento/releases/download/v0.0.0/bento-darwin-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/NovaShang/bento/releases/download/v0.0.0/bento-linux-x86_64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_arm do
      url "https://github.com/NovaShang/bento/releases/download/v0.0.0/bento-linux-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
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
      # Prebuilt tarball: binaries are at the archive root.
      bin.install "bento-daemon"
      bin.install "bento"
      bin.install "bento-tmux" if File.exist?("bento-tmux")
    end
  end

  test do
    assert_match(/^bento /, shell_output("#{bin}/bento version"))
    assert_match(/^bento-daemon /, shell_output("#{bin}/bento-daemon version"))
  end
end
