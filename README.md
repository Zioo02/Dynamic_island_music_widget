# Now Playing Island

A Dynamic Island–style "now playing" widget for the macOS menu bar.
It shows the current track from any player, including web apps such as YouTube Music installed from Chrome, with round artwork and equalizer bars that follow the music.

[Polska wersja](README.pl.md)

![The island in the menu bar](docs/island.png)

![The panel shown on click](docs/panel.png)

## Features

- **Any player.** Reads the system "Now Playing" information, so it works with YouTube Music (also as a browser web app), Spotify, Apple Music, browser tabs and more.
- **Music-reactive equalizer.** Bars follow the low, mid and high bands of what is playing (macOS 14.2+), tinted with a colour taken from the artwork.
- **Glass island.** A frosted capsule that matches the height of your menu bar.
- **Now Playing panel.** Click the island for large artwork, playback controls and a progress bar you can drag to seek. Click the artwork or title to open the player.
- **Lightweight.** A single native Swift app, no Electron, no background services besides itself.
- **English and Polish**, picked from your system language.

## Requirements

- macOS 13 Ventura or later (music-reactive bars need macOS 14.2 or later)
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`); the full Xcode is not needed

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/now-playing-island.git
cd now-playing-island
./install.sh
```

The script installs [media-control](https://github.com/ungive/media-control) if needed, builds the app on your Mac, puts it in `~/Applications` and sets it to open at login.

After it starts, **hold ⌘ and drag the island** to where you want it in the menu bar.

### Audio permission

On first launch macOS asks for permission to record system audio. The app needs it only to measure how loud the bass, mids and highs are so the bars can move with the music. **Nothing is recorded, saved or sent anywhere.** While music plays, macOS may show its recording indicator in the menu bar; listening stops when playback is paused.

If you decline, everything else works and the bars use a calm idle animation. You can disable the feature entirely with `reactToMusic = false` (see below).

## Configuration

Settings live at the top of [`Sources/main.swift`](Sources/main.swift). Change them and run `./install.sh` again.

| Setting | Default | Description |
|---|---|---|
| `islandWidth` | `250` | Island width in points |
| `islandHeight` | `0` | `0` matches the menu bar; any other value is a fixed height |
| `verticalInset` | `4` | Gap above and below the island (automatic height only) |
| `innerPadding` | `5` | Gap between the island edge and its content |
| `glassTint` | `0.25` | Glass darkening, from `0` (clear) to `1` (black) |
| `showArtist` | `true` | Show "Title – Artist" instead of only the title |
| `showControls` | `false` | Show playback buttons on the island itself |
| `showBars` | `true` | Show the equalizer bars |
| `reactToMusic` | `true` | Make the bars follow the audio |
| `playerAppName` | `"YouTube Music"` | App opened from the panel |

## Uninstall

```bash
./uninstall.sh
```

This removes the app and the login item. media-control stays installed; remove it with `brew uninstall media-control` if you don't need it.

## Troubleshooting

**The island disappears or shows up on the far left.**
On Macs with a notch, menu bar icons only fit to the right of it. Lower `islandWidth` (for example to `220`) or hide a few other icons with a menu bar manager.

**The bars don't react to the music.**
Check System Settings → Privacy & Security → Screen & System Audio Recording and allow Now Playing Island under system audio. Reinstalling creates a new build, so macOS may ask again. Quit the island from its panel and open it again after granting access.

**The glass looks wrong on a second display.**
macOS draws menu bar icons on inactive displays as a copy of the main one, so the blur there is taken from the main screen's background. This is a system limitation.

**Nothing shows up at all.**
Run `media-control get` in Terminal while music plays. If it prints nothing, macOS isn't reporting what's playing; see the [media-control](https://github.com/ungive/media-control) project for details.

## How it works

The app polls `media-control get` once a second for the current track, artwork and playback position, and sends playback commands through it. For the equalizer it creates a Core Audio process tap on the system output, splits the signal into three bands with simple filters and compares each band against its recent average. The UI is SwiftUI inside an `NSStatusItem`.

## Credits

- [media-control](https://github.com/ungive/media-control) by [@ungive](https://github.com/ungive), which makes reading "Now Playing" possible on recent macOS versions.

## License

[MIT](LICENSE)

Not affiliated with Apple, Google or YouTube.
