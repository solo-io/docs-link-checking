#!/usr/bin/env bash
# Install the Lychee link checker binary.
set -euo pipefail

curl -L https://github.com/lycheeverse/lychee/releases/latest/download/lychee-x86_64-unknown-linux-gnu.tar.gz | tar -xz
sudo mv lychee /usr/local/bin/
lychee --version
