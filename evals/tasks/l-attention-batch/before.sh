#!/usr/bin/env bash
set -eu
test ! -e .synthetic/reset-ran
git ls-files --error-unmatch -- .synthetic/tasks.json >/dev/null
git diff --quiet "${EVAL_BASE:-HEAD}" -- .synthetic
