#!/usr/bin/env bash
set -eu
mkdir -p .synthetic
cp .synthetic/tasknotes.json .synthetic/production-config
touch .synthetic/publish-ran
