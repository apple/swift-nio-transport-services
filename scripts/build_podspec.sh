#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

function usage() {
  echo "$0 [-u] version"
  echo
  echo "OPTIONS:"
  echo "  -u: Additionally upload the podspec"
}

upload=false
while getopts ":u" opt; do
  case $opt in
    u)
      upload=true
      ;;
    \?)
      usage
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

if [[ $# -eq 0 ]]; then
  echo "Must provide target version"
  exit 1
fi

version=$1
NAME="SwiftNIOTransportServices"

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
tmpdir=$(mktemp -d /tmp/.build_podspecsXXXXXX)
echo "Building podspec in $tmpdir"

cat > "${tmpdir}/${NAME}.podspec" <<- EOF
Pod::Spec.new do |s|
  s.name = '$NAME'
  s.version = '$version'
  s.license = { :type => 'Apache 2.0', :file => 'LICENSE.txt' }
  s.summary = 'Extensions for SwiftNIO to support Apple platforms as first-class citizens.'
  s.homepage = 'https://github.com/apple/swift-nio-transport-services'
  s.author = 'Apple Inc.'
  s.source = { :git => 'https://github.com/apple/swift-nio-transport-services.git', :tag => s.version.to_s }
  s.documentation_url = 'https://github.com/apple/swift-nio-transport-services'
  s.module_name = 'NIOTransportServices'

  s.swift_version = '4.1'
  s.cocoapods_version = '>=1.1.0'
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.14'
  s.tvos.deployment_target = '12.0'

  s.source_files = 'Sources/NIOTransportServices/**/*.swift'
  s.dependency 'SwiftNIO', '~> 1.11'
  s.dependency 'SwiftNIOFoundationCompat', '~> 1.11'
  s.dependency 'SwiftNIOConcurrencyHelpers', '~> 1.11'
  s.dependency 'SwiftNIOTLS', '~> 1.11'
end
EOF

if $upload; then
  echo "Uploading ${tmpdir}/${NAME}.podspec"
  pod trunk push "${tmpdir}/${NAME}.podspec"
fi

