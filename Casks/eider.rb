cask "eider" do
  version "0.1.7"
  sha256 "befea0d36524ea8cd13489a958c6866d74b345d2b2e42e1dbe07e9172a6ea872"

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
