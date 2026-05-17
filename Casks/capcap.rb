cask "capcap" do
  version "1.1.6"
  sha256 "e0b12dd43436c01f6a9e8d4a64d2bf55ee295d528f15b68ab27589faeb54ab46"

  url "https://github.com/realskyrin/capcap/releases/download/release-v#{version}/capcap-#{version}-macos.zip"
  name "capcap"
  desc "Lightweight native macOS menu bar screenshot tool"
  homepage "https://github.com/realskyrin/capcap"

  depends_on macos: ">= :sonoma"

  app "capcap.app"

  uninstall quit: "cn.skyrin.capcap"

  zap trash: [
    "~/Library/Preferences/cn.skyrin.capcap.plist",
  ]
end
