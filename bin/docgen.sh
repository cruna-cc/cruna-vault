#!/usr/bin/env bash

root_dir=$(dirname $(realpath $(dirname "$0")))
# if not run from the root, we cd into the root
cd $root_dir

SKIP_CRYPTOENV=true npx hardhat docgen
node scripts/docs-index.js

