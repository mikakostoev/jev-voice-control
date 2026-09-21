# Jev

**English** · [Русский](README.ru.md)

Always-listening voice control for macOS. Speech is recognised on the device, every utterance goes to the
[Jev](https://openrouter.ai/typesafe/jev-1.13) model (TypeSafe, via OpenRouter), and the model picks one command.
Jev does not generate text — it only chooses among options and returns probabilities — so a decision takes about half
a second and costs about $0.00002.

Commands are data, not code: the built-in ones live in [defaults.json](defaults.json), and you add your own in
`~/.config/jev/config.json` using the same format.

The built-in command descriptions carry Russian example phrases, because that is how the author talks to it. The model
matches by meaning across languages, so English commands work too (`open telegram`, `type in hello world`, `post`);
set the recognition language with `JEV_LOCALE` / `"locale"`.

## Quick start

You need macOS 14+, Apple's command line tools (`xcode-select --install`; full Xcode is not required) and an
[OpenRouter](https://openrouter.ai/keys) key with a little credit.

```bash
git clone https://github.com/mikakostoev/jev-voice-control.git
cd jev-voice-control
cp .env.example .env      # put your OPENROUTER_API_KEY in it; optionally change JEV_LOCALE (en-US, ru-RU, …)
./build.sh                # builds, signs, installs to ~/Applications/Jev.app and launches it
```

1. **Permissions.** On first launch macOS asks for Microphone and Speech Recognition — allow both. Then enable Jev in
   *System Settings → Privacy & Security → Accessibility* (without it only "open …", search and volume work; typing,
   shortcuts and clicks do not). Screen Recording is requested later, the first time you ask Jev to click inside an
   app that exposes nothing through Accessibility (Telegram, for one).
2. **Try it.** A **Jev** item appears in the menu bar and a "Jev is listening" pill shows at the bottom of the screen
   for a couple of seconds. Say "open calculator". Then, with a browser in front: "open youtube", "new tab",
   "scroll down", "go back".
3. **Keep permissions across rebuilds** by creating a signing certificate once: *Keychain Access → Keychain Access
   menu → Certificate Assistant → Create a Certificate…*, name **`Jev Dev`**, identity type "Self Signed Root",
   certificate type **"Code Signing"**. `build.sh` picks it up automatically; click "Always Allow" the first time it
   signs. Without the certificate the app is ad-hoc signed and macOS forgets its permissions after every build (see
   below).

Jev does nothing without a connection to OpenRouter: speech recognition is local, but the decision is the model's.

### Troubleshooting

| Symptom | What to do |
|---|---|
| No idea what is going on | Jev menu → **Open log** (`~/Library/Logs/Jev.log`): what was heard, what the model decided, how it ended. |
| After a rebuild Jev is enabled in Settings but neither types nor clicks (log says `accessibility trusted=false`) | The grant belongs to the previous signature. Run `tccutil reset Accessibility dev.kostoev.jev-hud`, relaunch Jev, enable it again. Same for `ScreenCapture`. The certificate from step 3 fixes this for good. |
| Log says `cannot listen …` | Microphone or Speech Recognition not granted, or the `JEV_LOCALE` language is not supported on this Mac. |
| Log says `jev request failed: HTTP 5xx / 529` | The model service is overloaded — it happens in bursts of a few minutes; Jev already retries up to three times. |
| `HTTP 401/402` | Wrong key, or the OpenRouter balance ran out. |
| It reacts to conversations around you | Menu → **Pause listening** (remembered across launches); raise `minConfidence` in the config. |

The Jev menu has: pause listening, "Edit commands…", "Open log", quit.

## Your own commands

Menu → **Edit commands…** creates and opens `~/.config/jev/config.json`. The file is reloaded when you save it; if it
has an error, Jev shows a card saying where and keeps running on the previous commands.

```json
{
  "locale": "en-US",
  "commands": [
    { "id": "standup",
      "say": "open everything for the daily call: standup, daily, open the meeting stuff",
      "do": [ { "open": "https://meet.google.com" }, { "wait": 1 }, { "open": "Notes" } ] },

    { "id": "next_chat", "app": "Telegram",
      "say": "go to the next chat in the list: next chat",
      "do": [ { "keys": "alt+down" } ] },

    { "id": "deploy",
      "say": "deploy the site to production: deploy the project, ship it",
      "do": [ { "shell": "cd ~/Projects/site && ./deploy.sh" } ] }
  ],
  "disable": ["lock_screen"],
  "sites": { "jira": "mycompany.atlassian.net" },
  "emoji": { "duck": "🦆" }
}
```

### Command fields

| Field | Meaning |
|---|---|
| `id` | Unique name. Using a built-in `id` replaces that built-in command. |
| `say` | What Jev reads: a description of the intent **plus example phrases**. Exact wording is not required — matching is by meaning. The more specific the description, the less it gets confused with neighbouring commands. |
| `do` | Steps, run in order (see below). |
| `app` | Optional. The command is only offered while this app is frontmost (substring match on the app name). |
| `title` | Optional. Card title; derived from `id` by default. |
| `confirm` | Ask for a spoken "yes / cancel" before running. Defaults to `true` when there is a `shell` or `applescript` step, otherwise `false`. |

### Steps (`do`)

Each step is an object with exactly one key.

| Step | Example | What it does |
|---|---|---|
| `keys` | `{"keys": "cmd+shift+t"}` | Keyboard shortcut in the frontmost app. Modifiers: `cmd`, `shift`, `alt`, `ctrl`, `fn`. Keys: letters, digits, `enter`, `esc`, `tab`, `space`, `delete`, `up/down/left/right`, `pageup/pagedown`, `home/end`, `f1`–`f12`, and `[ ] = - , . / ; ' \``. |
| `open` | `{"open": "https://x.com"}` | A URL, a path (`~/Projects`) or an application name (`Notes`). URLs open in the default browser. |
| `type` | `{"type": "Best regards, Ivan"}` | Types text into the focused field. |
| `click` | `{"click": "Send"}` | Clicks an on-screen item; name it the way you would say it. |
| `shell` | `{"shell": "say done"}` | A command run with `zsh -lc`. The tail of its output goes to the log. |
| `applescript` | `{"applescript": "tell application \"Music\" to play"}` | AppleScript. |
| `media` | `{"media": "next"}` | Media key: `play`, `next`, `previous`. |
| `wait` | `{"wait": 0.5}` | Pause, in seconds. |
| `builtin` | `{"builtin": "search"}` | One of Jev's smart actions that parse the spoken phrase themselves: `open_app`, `open_url`, `open_folder`, `search`, `type_text`, `click`, `emoji`, `set_volume`, `quit_app`, `screenshot`, `repeat`. |

### Other keys in the file

| Key | Default | |
|---|---|---|
| `locale` | `JEV_LOCALE` from `.env` | Speech recognition language (`en-US`, `ru-RU`, …). |
| `minConfidence` | `0.6` | Below this confidence Jev stays quiet (0.3–0.95). |
| `silence` | `0.9` | Seconds of silence that end an utterance (0.4–3). |
| `disable` | `[]` | `id`s of built-in commands to switch off. |
| `sites` | `{}` | Spoken name → domain for "open …". |
| `emoji` | `{}` | Name (or its beginning) → emoji. |

Unknown keys are ignored, so the JSON can hold notes (`"_readme"`) and parked drafts (`"_more_examples"`).

## Checking that a new command broke nothing

The more commands there are, the easier it is for Jev to confuse neighbours. Both test sets run the **real** model
with your config:

```bash
J=~/Applications/Jev.app/Contents/MacOS/Jev
$J --selftest                          # phrase parsing, config format, click geometry, one live request
$J --eval Tests/cases.tsv              # phrase → command (150+ phrases, including chatter that must be ignored)
$J --eval-clicks Tests/clicks.tsv      # app screen + phrase → the item that must be clicked
JEV_CONFIG=./my.json $J --eval my.tsv  # try a config without touching the real one
```

`cases.tsv` format: `phrase<TAB>expected id[<TAB>previous command[<TAB>frontmost app]]`; `a|b` means either is fine,
`none` means Jev must stay quiet. Give each command of yours at least three lines: two phrases that must trigger it
and one similar phrase that must not. The bundled test phrases are in Russian.

The model's answers wobble a little from run to run: a single miss with a confidence near the threshold is noise; a
repeating one means the `say` text needs sharpening.

## How it works

| File | Role |
|---|---|
| [Speech.swift](Sources/Jev/Speech.swift) | Continuous on-device speech recognition; an utterance ends with a pause. |
| [Jev.swift](Sources/Jev/Jev.swift) | Client for `POST /api/alpha/decisions`; phrase parsing (sites, folders, volume, dictated text). |
| [Config.swift](Sources/Jev/Config.swift) | Command format, merging `defaults.json` with the user file, error reporting. |
| [App.swift](Sources/Jev/App.swift) | The pipeline: utterance → decision (aware of what is on screen) → confirmation → steps. The `--eval` modes. |
| [Actions.swift](Sources/Jev/Actions.swift) | Shortcuts, typing, clicks through Accessibility, launching apps, shell. |
| [Screen.swift](Sources/Jev/Screen.swift) | Window screenshot + OCR for apps that expose no interface through Accessibility. |
| [HUD.swift](Sources/Jev/HUD.swift) | The overlay: pill/card morph, procedural noise, live probability curve. |

Clicking works in two stages. When an utterance starts, Jev reads what is visible in the frontmost app — the
Accessibility tree, or OCR of the window when the app exposes almost nothing. The first decision ("which action?")
sees that list, so "shuffle" or "allow" are understood as buttons rather than chatter. A second decision picks the
item, matching by meaning across languages ("перешли" → `Forward`).

Log: `~/Library/Logs/Jev.log` (it contains the text of everything the microphone made out).
`kill -USR1 $(pgrep -x Jev)` writes what Jev can see in the frontmost app to `~/Library/Logs/Jev-ui.log`.

## Known limits

- Unlabelled icon buttons in apps without Accessibility (Telegram) cannot be found — OCR only sees text.
- Ordinals ("open the first video") do not work: the model receives the items as an unordered set.
- The microphone is always on and there is no wake word: a stray phrase can match a command. Dangerous steps are
  guarded by a spoken confirmation; for everything else there is Pause in the menu.
- `shell` and `applescript` run arbitrary code as you. Do not set `"confirm": false` on them without a reason, and do
  not paste someone else's config without reading it.
- The decisions endpoint is an undocumented alpha API; its request format was worked out from validation errors and
  may change.
- Tested on macOS 26 (Apple Silicon); the declared minimum is macOS 14.

## License

[MIT](LICENSE)
