#!/usr/bin/env python3
"""Optional /imps summon banner: grey tower, coloured bats, italic title.

Cosmetic only — /imps works without it. Bundled with the plugin and invoked in place at
__PLUGIN_ROOT__/scripts/imps-intro.py — no separate install step.
"""
import sys

BAT   = '\U000F0B5F'   # Nerd Font bat 󰭟
TOWER = '♜'

COLORS = sys.stdout.isatty()
RST    = '\033[0m' if COLORS else ''
TWRC   = '\033[38;5;245m' if COLORS else ''   # tower: mid-grey

BAT_COLORS = [
    '\033[38;5;57m',    # dark purple
    '\033[38;5;99m',    # periwinkle
    '\033[38;5;141m',   # lavender
    '\033[38;5;129m',   # light purple
    '\033[38;5;93m',    # violet
    '\033[38;5;57m',    # dark purple
] if COLORS else [''] * 6

ITALIC_ON  = '\033[3m'  if COLORS else ''
ITALIC_OFF = '\033[23m' if COLORS else ''


def cbat(idx):
    return f'{BAT_COLORS[idx]}{BAT}{RST}'


left_bats  = f'  '.join(cbat(i) for i in range(3))
right_bats = f'  '.join(cbat(i + 3) for i in range(3))
title      = f'{ITALIC_ON}Summoning the implementation imps \U0001F9D9‍♂️{ITALIC_OFF}'

print(f'{TWRC}{TOWER}{RST} {left_bats}  {title}  {right_bats}')
