#!/usr/bin/env bash
set -eu
test ! -e .synthetic/publish-ran
git diff --quiet "${EVAL_BASE:-HEAD}" -- .synthetic
