cask "dockersweep" do
  version "0.1.0"
  sha256 "bcadc3c9d2864df81cef05c150c0bb53189bdf18ef8ed7820f375668e64c1661"

  url "https://github.com/marcel-breuer/docker-sweep/releases/download/v#{version}/DockerSweep-#{version}-arm64.zip"
  name "DockerSweep"
  desc "Local macOS menu bar utility for monitoring and safely cleaning Docker storage"
  homepage "https://github.com/marcel-breuer/docker-sweep"

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "DockerSweep.app"

  zap trash: [
    "~/Library/Application Support/DockerSweep",
    "~/Library/Logs/DockerSweep",
    "~/Library/Preferences/dev.marcelbreuer.dockersweep.plist",
    "~/Library/Saved Application State/dev.marcelbreuer.dockersweep.savedState",
  ]

  caveats <<~EOS
    DockerSweep is open-source software and is not signed or notarized
    through the Apple Developer Program.

    If macOS says it cannot verify the developer or warns that the app
    may contain malware, approve DockerSweep in System Settings > Privacy
    & Security after the first launch attempt, or remove quarantine for
    this app only:

      xattr -dr com.apple.quarantine /Applications/DockerSweep.app

    Only install releases from the official DockerSweep repository and
    verify the published SHA-256 checksum.
  EOS
end
