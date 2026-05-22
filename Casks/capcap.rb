cask "capcap" do
  version "1.3.10"
  sha256 "c2c95e266fd26460793e7fd88f5f9996950824b3e3d7840ebf2b806e3594772a"

  url "https://github.com/realskyrin/capcap/releases/download/release-v#{version}/capcap-#{version}-macos.zip"
  name "capcap"
  desc "Lightweight native menu bar screenshot tool"
  homepage "https://github.com/realskyrin/capcap"

  depends_on macos: :sonoma

  app "capcap.app"

  uninstall quit: "cn.skyrin.capcap"

  zap trash: "~/Library/Preferences/cn.skyrin.capcap.plist"
end
