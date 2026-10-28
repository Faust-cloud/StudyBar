<p align="center">
  <img src="icon.png" width="128" alt="StudyBar icon">
</p>

<h1 align="center">StudyBar</h1>

<p align="center">
  A study timer that lives in your Mac menu bar.<br>
  Track time by subject, plan your day, and keep your streak going.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138?style=flat-square" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-3c8d5a?style=flat-square" alt="MIT">
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="screenshot.png" width="680" alt="StudyBar running in the menu bar">
</p>

## Why

Most timers ask you to start a 25-minute countdown. Studying doesn't always work that way. Some days it's an hour of vocabulary, then a math chapter, then twenty minutes of something else, and at the end of the week you want to know where the time actually went.

StudyBar sits in the menu bar and does one thing well: it records how long you study each subject. Click "English" to start. Click "Math" and the English session is saved automatically. That's the whole workflow.

## Features

- **One click per subject.** Switching subjects closes the previous session for you.
- **Today's plan.** Write what you want to do, hit ▶ next to it, and the time goes to that task. Unfinished items roll over to tomorrow.
- **Daily goal and streak.** Set how long you want to study each day and watch the streak grow.
- **Optional Pomodoro.** Turn it on when you want it, with adjustable focus and break lengths.
- **Fair to paper work.** If you haven't touched the Mac for 10 minutes, StudyBar doesn't quietly cut your time. When you come back, it asks whether that stretch was study time.
- **Forgiving.** Add a session you forgot to track, fix a wrong duration, or delete one.
- **Your data stays on your Mac.** No account, no cloud. Copy every record as a table and paste it into Excel or Numbers whenever you like.

> [!NOTE]
> The interface is currently in Simplified Chinese. English is on the roadmap.

## Install

### Download

1. Download `StudyBar.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `StudyBar.app` to your Applications folder.
3. The first time, right-click the app and choose **Open**. The app isn't notarized yet, so macOS asks once.

To start it at login, add it in **System Settings → General → Login Items**.

### Build from source

StudyBar is a single Swift file with no dependencies.

1. In Xcode, create a new project: **macOS → App**, interface **SwiftUI**.
2. Delete the generated `ContentView.swift`.
3. Replace the contents of the generated `<Name>App.swift` with [`StudyBarApp.swift`](StudyBarApp.swift).
4. Press `⌘R`. A book icon appears in the menu bar.

## How it works

| Situation | What StudyBar does |
| --- | --- |
| You switch subjects | Saves the previous session, starts the new one |
| No keyboard or mouse input for 10 min | Keeps counting, asks you when you return |
| You close the lid | Same as above |
| You quit the app mid-session | Pauses at the last moment it was running |
| You study for 2 hours straight | Sends a reminder to take a break |
| You reach your daily goal | Sends a notification and extends your streak |

Records are stored in `UserDefaults` on your Mac. Deleting the app does not delete them.

## FAQ

**macOS says the app "can't be opened".**
Right-click the app and choose **Open**, or go to **System Settings → Privacy & Security** and click **Open Anyway**.

**I deleted a subject by mistake.**
Create a subject with the same name. It comes back with all of its history.

**How do I back up my records?**
Open **统计与设置** (Stats & Settings) and click **复制全部记录** (Copy all records). The data is copied as a table you can paste into any spreadsheet.

## Roadmap

- [ ] English interface
- [ ] Global keyboard shortcut to start and pause
- [ ] Launch at login toggle
- [ ] Monthly view and per-subject history
- [ ] Notarized builds and Homebrew

Ideas and bug reports are welcome in [Issues](../../issues).

## Motivation

I started studying English and math again and wanted a simple way to see how much time I was really putting in. The apps I tried were either Pomodoro timers that didn't care about subjects, or full time trackers that wanted an account. I wanted something that sits quietly in the menu bar and keeps an honest log, so I built it.

## License

[MIT](LICENSE)
