cask "eider" do
  version "0.1.10"
  sha256 "810db7eb44e94584688b4b51c8da8fc2abafa39fc4eeb39d35c2018f89e37293"

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
