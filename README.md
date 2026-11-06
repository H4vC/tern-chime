# Chime for Tern

A sound when something needs you: a pane's unseen alert (terminal bell, agent
waiting or finished out of sight, exited program), an omp agent yielding its
turn, or a long shell command finishing. Chimes never overlap, and one
window's chime suppresses the same moment's chime in every other window. A
chime that would land while one is already sounding is dropped; **Chime: Play
test sound** waits its turn instead, so it is always heard.

## Install

```sh
tern plugin install https://github.com/H4vC/tern-chime
```

For development, `tern plugin link /path/to/tern-chime`.

## Platforms

| OS | Player | Notes |
|---|---|---|
| Windows | `Media.SoundPlayer` via a hidden `wscript` launcher | WAV only; no console flash |
| macOS | `afplay` (ships with the OS) | Plays whatever afplay reads |
| Linux | `pw-play` → `paplay` → `aplay` → `ffplay` → `play`, first found wins | PipeWire-native first; on a bare server install one of `pipewire-bin`, `pulseaudio-utils`, `alsa-utils`, `ffmpeg` or `sox` |
| iOS | — | Silent; sound playback isn't available to plugins |

On Linux without any player, Chime logs one warning and stays silent rather
than erroring on every trigger.

## Sounds

Custom sounds are the point. `sounds.toml` in the plugin folder names the
audio file per trigger, and `<plugin data>/sounds.toml` overrides it so a
reinstall keeps your sounds. In your override, paths can be absolute,
`~/`-relative, or relative to the plugin data folder (handy for a `sounds/`
folder next to the config); an empty path silences that trigger. The config
re-reads every few seconds, and **Chime: Reload sounds** refreshes it at once.

The bundled chimes in `sounds/` are synthesized in-repo and free to keep, but
they are just defaults. To use the Mac "Funk" alert sound, for example:

1. Save a `Funk.aiff` (from `/System/Library/Sounds` on a Mac, or any
   recording of it) next to your override config:
   `<plugin data>/sounds/Funk.aiff`. (`tern plugin dir` shows the plugins
   folder; plugin data lives under Tern's local data folder, e.g.
   `%LOCALAPPDATA%\Tern\plugin-data\chime` on Windows.)
2. On Windows, convert it to WAV first — `Media.SoundPlayer` plays WAV only:
   `ffmpeg -i Funk.aiff -ar 44100 -ac 1 Funk.wav`. macOS and Linux play
   whatever their player reads (see Platforms above).
3. Point the triggers at it:

```toml
# <plugin data>/sounds.toml
alert = "sounds/Funk.wav"   # terminal bell, agent waiting, pane alert
yield = "sounds/Funk.wav"    # omp agent yielded its turn
done = ""                     # long commands: silent
only_unfocused = true         # chime only for panes you aren't looking at
min_seconds = 30              # commands running this long chime done
```

More recipes:

```toml
# One shared chime for everything, including the focused pane:
alert = "~/sounds/ping.wav"
yield = "~/sounds/ping.wav"
done = "~/sounds/ping.wav"
only_unfocused = false
min_seconds = 0
```

```toml
# Silent agent yields; only waiting agents and long builds make noise:
alert = "C:/sounds/alarm.wav"
yield = ""
done = "C:/sounds/ta-da.wav"
min_seconds = 120
```

## Palette

**Chime: Mute / unmute** (the status line shows `chime muted` while muted),
**Chime: Play test sound**, **Chime: Reload sounds**, **Chime: Diagnose panes
and agents** (writes what Chime sees to `<plugin data>/diagnose.txt`).
