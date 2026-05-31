#!/usr/bin/env python3
"""
Send F10 to ZZZ (3DMigoto mod reload) on Linux/Hyprland.
Focuses the game window, waits 1s for compositor focus to settle, then
injects F10 via ydotool (uinput/hardware level, which Wine/Proton accepts).
"""

import sys
import subprocess
import time
import os
from pathlib import Path

GAME_WINDOW_NAMES = ['ZenlessZoneZero', 'Zenless Zone Zero', 'Zenless', 'ZZZ']


def cmd_exists(cmd):
    try:
        subprocess.run(['which', cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    except subprocess.CalledProcessError:
        return False


def focus_game_window():
    """Raise and focus the game window so compositor input focus follows."""
    # wmctrl sends _NET_ACTIVE_WINDOW which XWayland propagates to the compositor
    if cmd_exists('wmctrl'):
        for name in GAME_WINDOW_NAMES:
            r = subprocess.run(['wmctrl', '-a', name],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if r.returncode == 0:
                print(f'✓ Focused via wmctrl: {name}')
                return True

    if cmd_exists('xdotool'):
        for name in GAME_WINDOW_NAMES:
            r = subprocess.run(['xdotool', 'search', '--name', '--onlyvisible', name],
                               capture_output=True, text=True)
            if r.stdout.strip():
                wid = r.stdout.strip().split('\n')[0]
                subprocess.run(['xdotool', 'windowactivate', '--sync', wid],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print(f'✓ Focused via xdotool: {name} (id {wid})')
                return True

    print('⚠ Could not auto-focus game window — switch to it manually')
    return False


def send_f10():
    if cmd_exists('ydotool'):
        r = subprocess.run(['ydotool', 'key', '68:1', '68:0'])
        if r.returncode == 0:
            print('✓ F10 sent via ydotool')
            return True
        print(f'❌ ydotool failed (exit {r.returncode})')

    if cmd_exists('xdotool'):
        r = subprocess.run(['xdotool', 'key', 'F10'])
        if r.returncode == 0:
            print('✓ F10 sent via xdotool')
            return True

    if cmd_exists('wtype'):
        r = subprocess.run(['wtype', '-k', 'F10'])
        if r.returncode == 0:
            print('✓ F10 sent via wtype')
            return True

    return False


def main():
    if len(sys.argv) < 2:
        print('Usage: python3 f10_reload.py <mods_path>')
        sys.exit(1)

    mods_path = sys.argv[1]
    if not Path(mods_path).exists():
        print(f'❌ Mods path does not exist: {mods_path}')
        sys.exit(1)

    print(f'🔄 Reloading mods in {mods_path}')

    # Write timestamp files for 3DMigoto signal
    ts = str(int(time.time() * 1000))
    try:
        (Path(mods_path) / '.reload_signal').write_text(ts)
        (Path(mods_path) / '.mod_timestamp').write_text(ts)
    except Exception as e:
        print(f'⚠ Signal file error: {e}')

    focus_game_window()

    # Wait for the Wayland compositor to actually give input focus to the game.
    # 1 second matches the manually-confirmed working case (sleep 1 && ydotool key 68:1 68:0).
    print('⏳ Waiting for focus to settle...')
    time.sleep(1.0)

    if send_f10():
        print('✅ Mod reload triggered')
        sys.exit(0)
    else:
        print('❌ Failed to send F10')
        print('   Make sure ydotool is installed and ydotoold is running:')
        print('   sudo systemctl enable --now ydotool.service')
        sys.exit(1)


if __name__ == '__main__':
    main()
