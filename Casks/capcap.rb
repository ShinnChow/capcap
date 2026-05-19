cask "capcap" do
  version "1.3.2"
  sha256 "1c1d8b84aaaaa0314eac0d8b51cadeba479e3bd8e6723333c0f8baac78587040"

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
