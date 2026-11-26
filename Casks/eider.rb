cask "eider" do
  version "0.1.4"
  sha256 "b6096318b122750c7a37c67b340ba58496c234884fcfbe48f1cac33e6aa4c803"

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
