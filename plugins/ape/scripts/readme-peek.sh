#!/usr/bin/env bash
# Phase 1 helper for gibbon-scout — peeks at a repo's README headline as a
# single preapprovable command instead of a multi-stage pipe chain.
#
# Usage: readme-peek.sh <owner/repo>
# fail-soft: report available README content, tolerate fetch/decode failures
set -uo pipefail

gh api "repos/$1/readme" -q .content 2>&1 | base64 -d 2>/dev/null | head -40
