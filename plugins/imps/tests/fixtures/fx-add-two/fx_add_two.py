#!/usr/bin/env python3
"""Deliberately wrong on purpose: add_two() must return n + 2, not n.

This is an /imps opencode-harness fixture. The E2E asserts the *harness's*
behaviour (contract line, oracle loop, deterministic commit), not the model's
competence — which is why the task is this small.
"""


def add_two(n):
    return n
