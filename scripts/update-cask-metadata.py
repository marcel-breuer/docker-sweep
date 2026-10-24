#!/usr/bin/env python3
import pathlib
import re
import sys

version, checksum = sys.argv[1:3]
path = pathlib.Path("Casks/dockersweep.rb")
text = path.read_text()
text, version_count = re.subn(r'^  version ".*"$', f'  version "{version}"', text, count=1, flags=re.M)
text, sha_count = re.subn(r'^  sha256 ".*"$', f'  sha256 "{checksum}"', text, count=1, flags=re.M)
text = re.sub(r'/DockerSweep-[^/]+-(?:arm64|universal)\.zip', '/DockerSweep-#{version}-universal.zip', text)
text = re.sub(r'^  depends_on arch: :arm64\n', '', text, flags=re.M)
text = re.sub(r'\n  caveats <<~EOS\n.*?^  EOS\n', '\n', text, flags=re.M | re.S)
if version_count != 1 or sha_count != 1 or "universal.zip" not in text:
    raise SystemExit("Could not update all expected Homebrew cask fields")
path.write_text(text)
