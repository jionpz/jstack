#!/usr/bin/env bash
set -eu
git diff --quiet "${EVAL_BASE:-HEAD}" -- src bin test
test -z "$(git ls-files --others --exclude-standard -- src bin test)"
