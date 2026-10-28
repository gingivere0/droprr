#!/usr/bin/env python3
"""Regenerates Shared/ThemePalettes.swift from design-system/droprr/tokens.json ("themes").

Run from apple/ after changing theme colors in tokens.json:

    python3 scripts/generate_theme_palettes.py
"""
import json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
t = json.load(open(os.path.join(root, '..', 'design-system', 'droprr', 'tokens.json')))
th, b = t['themes'], t['bento']
roles = ['surface', 'tile', 'border', 'textPrimary', 'textSecondary', 'primaryButton', 'onPrimaryButton',
         'accent', 'onAccent', 'accentText', 'accentTint', 'secondary', 'secondaryTint', 'secondaryText']

def r(d):
    return 'Roles(' + ', '.join(f'{x}: 0x{d[x][1:]}' for x in roles) + ')'

lines = ['// Generated from design-system/droprr/tokens.json ("themes") by scripts/generate_theme_palettes.py.',
         '// Keep in sync with Windows: edit tokens.json, then rerun the script.', 'import SwiftUI', '',
         'extension ThemePalette {', '    static let all: [ThemePalette] = [']
for k in th['order']:
    v = th['list'][k]
    lines += [f'        ThemePalette(id: "{k}", name: "{v["name"]}",',
              f'                     light: {r(v["light"])},',
              f'                     dark: {r(v["dark"])}),']
lines += ['    ]', '', f'    static let defaultID = "{th["default"]}"',
          f'    static let successFill: (light: UInt32, dark: UInt32) = (light: 0x{b["successFill"]["light"][1:]}, dark: 0x{b["successFill"]["dark"][1:]})',
          f'    static let successText: (light: UInt32, dark: UInt32) = (light: 0x{b["successText"]["light"][1:]}, dark: 0x{b["successText"]["dark"][1:]})',
          '}', '']
open(os.path.join(root, 'Shared', 'ThemePalettes.swift'), 'w').write('\n'.join(lines))
