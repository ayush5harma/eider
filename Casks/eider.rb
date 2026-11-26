cask "eider" do
  version "0.1.9"
  sha256 "d53b4bd8e3f172ec0cbde7c95bfc4f742e3d441386c38512a01eba05aa3dfbe2"

  url "https://github.com/ayush5harma/eider/releases/download/v#{version}/Eider-#{version}.zip"
  name "Eider"
  desc "Install iOS apps from sources as Mac apps on Apple silicon"
  homepage "https://github.com/ayush5harma/eider"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Eider.app"
  binary "#{appdir}/Eider.app/Contents/Resources/cli/bin/eider"

  zap trash: "~/Library/Application Support/Eider"

  caveats <<~EOS
    Eider is ad hoc signed, not notarized. Approve it once in
    System Settings > Privacy & Security the first time you open it.
  EOS
end
