#!/bin/sh
# Fetch CPython for iOS (BeeWare's Python-Apple-support, PEP 730) and the two pure-Python packages the reader needs, into the folder this
# is run from, before `xcodegen generate`. The same versions the measured try used (the reader matched the PC on 250 of 250 lines).
set -eu
PY_SUPPORT_URL="https://github.com/beeware/Python-Apple-support/releases/download/3.13-b16/Python-3.13-iOS-support.b16.tar.gz"
curl -fL -o py-support.tar.gz "$PY_SUPPORT_URL"
shasum -a 256 py-support.tar.gz
tar xzf py-support.tar.gz Python.xcframework
rm -rf app_packages
python3 -m pip install --quiet --target app_packages --only-binary=:all: lark==1.3.1 python-dateutil==2.9.0.post0 six
find app_packages -name __pycache__ -type d -prune -exec rm -rf {} +
# pure Python only: a compiled file here would not run on a phone
if find app_packages -name '*.so' | grep -q .; then echo "app_packages has compiled files"; exit 1; fi
