# Dynamic Island — website source

Use this file as the only product source for a **2-page marketing site**: **Product** (`/`) and **Pricing** (`/pricing`). Keep the site short. Do not invent features, platforms, browsers, or permissions that are not listed here.

**How to use:** paste this whole file into Claude and ask it to build the site from it.

---

## Site instructions (for the builder)

- Two pages only. Shared header + footer. Product page is the homepage.
- Tone: direct, Apple-like, no hype adjectives. Short sentences. No “revolutionize,” “delight,” or “seamless.”
- Audience: people on a notched MacBook who already use Claude / ChatGPT / Gemini in Chrome, and who play music or video while they work.
- Visual: dark page, black island, sparse layout. The product *is* a black pill under the Mac notch — show that, don’t decorate around it.
- Do not add a blog, changelog, docs portal, or feature comparison table unless it fits on the pricing page.
- Do not claim App Store, Setapp, or a download URL unless the placeholders below are filled in.
- Do not claim Safari, Arc, or Firefox for **AI chat**. Chat monitoring is **Google Chrome only**.
- Do not claim the app talks to Claude / OpenAI / Google APIs. It never does. It watches open Chrome tabs on this Mac.
- Do not claim lock-screen widgets or loginwindow UI. The island **hides while the Mac is locked** and comes back on unlock.
- Mark every `PLACEHOLDER` in the live site so it is obvious what still needs a real value.

---

## Product

**Name:** Dynamic Island  
**What it is:** A native macOS menu-bar app that puts a live island in the hardware notch — the same idea as iPhone Dynamic Island, for Mac.

**One line:** Media, charging, volume, screen recording, and “your AI reply is ready” — in the notch, not in the middle of the screen.

**Slightly longer:** Dynamic Island sits in the MacBook notch. Compact, it shows what’s playing. Hover and it expands into a player. Plug in, turn Focus on, change volume, or start a recording — the island is the HUD. Keep Claude, ChatGPT, or Gemini open in Chrome and it banners when a reply finishes, then one click jumps you to that tab.

**Who it’s for:** MacBook Pro (notched) users who keep music or a show running and wait on AI chats in Chrome.

**What it is not:** Not a notification center replacement. Not a chat client. Not a cloud service. Nothing leaves the Mac for the AI banners.

---

## Page 1 — Product

### Hero

- Headline: **The notch, used.**
- Subhead: Dynamic Island for Mac. Now Playing, system HUDs, and AI reply banners — under the camera, not over your work.
- Primary CTA: `PLACEHOLDER` — e.g. “Download for Mac” (link: `PLACEHOLDER_DOWNLOAD_URL`)
- Secondary CTA: Pricing
- Platform line: Native macOS app. Built for notched MacBooks.

### How it works (3 steps, keep it this short)

1. **It lives in the notch.** A black island, aligned with the camera housing. The menu-bar strip is tinted black so the island reads as part of the display, not a floating widget.
2. **Hover to expand.** Compact: artwork + waveform. Expanded: title, artist, scrubber, play / pause / skip. Drop a file on the notch to hold it.
3. **Banners when something finishes.** Charging, low battery, volume, brightness, Focus, screen recording, and AI replies in Chrome. Click a chat banner to open that tab.

### Features (use these, not extras)

#### Now Playing

- Compact island: album art on the left, animated waveform on the right. Waveform color comes from the artwork.
- Hover to expand: title, artist, elapsed / remaining, scrubbable progress, previous / play-pause / next.
- Click the island (outside the transport controls) to bring the playing app — or the matching browser tab — to the front.
- Works with macOS Now Playing: Spotify, Apple Music, Apple TV, YouTube, YouTube Music, Netflix, Prime Video, Disney+, JioHotstar, Hulu, Max, Crunchyroll, Twitch, SonyLIV, Zee5, JioSaavn, SoundCloud, Vimeo, Plex, and other apps that publish Now Playing.
- YouTube / YouTube Music in the browser: play, pause, seek, and playlist next/prev go to the tab that is actually playing — without stealing focus to the first YouTube tab.

#### AI reply banners (Chrome)

- Watches open **Claude**, **ChatGPT**, and **Gemini** tabs in **Google Chrome**.
- When a reply **finishes**, the island expands with the provider logo, a short preview, and **Check Now**. Click it to jump to that exact tab.
- Does **not** banner while the model is still thinking. Does **not** re-banner a reply you already looked at. Does **not** banner if Chrome is frontmost and that tab is already on screen.
- If music is playing at the same time, the island splits: player on the left, chat on the right.
- The app does **not** call those companies’ APIs and does **not** send chat text anywhere. It only reads the tab already open on this Mac.
- Optional **Chrome helper** (load-unpacked extension) for instant banners. Without it, the app polls Chrome. Helper is one-time setup from Settings.

#### Charging and battery

- Plug in: Charging banner with percent.
- Unplugged: Low Battery banner at **20%** and again at **10%**. Click opens Battery settings.

#### Sound and brightness

- Volume and brightness keys expand the island (level + mute). The gray macOS HUD in the center of the screen is suppressed once Accessibility is granted in Settings.

#### Focus

- Turning Focus on or off in Control Center shows a short island banner (mode name + On / Off).

#### File shelf

- Drop a screenshot, recording, or any Finder file onto the notch. It holds there (up to **8** items).
- Drag out later to copy it somewhere else. The original file is **never deleted**.
- Optional auto-remove from the shelf after 15 minutes, 1 hour, 6 hours, or 24 hours (toggle in Settings). Removing from the shelf does not delete the file.

#### Screen recording

- Red pulse on the compact island while macOS is capturing (or while the user is picking a screen).
- Hover to expand: elapsed time + **Stop**.

#### Spaces and lock

- Switching desktops: the island follows the swipe and drops onto the Space you land on.
- Lock the Mac: the island hides. Unlock: it comes back. It does not draw on the lock screen.

#### Settings

- Menu bar extra → Settings. Preview buttons for every banner. Chrome helper install. Automation / Accessibility status. Shelf on/off and expiry.

### Requirements (footer or a thin strip on the product page)

- **Hardware:** MacBook with a notch.
- **OS:** macOS `PLACEHOLDER` (the current build targets a current macOS; fill the public minimum before launch).
- **Chrome:** required only for AI reply banners. Now Playing does not need Chrome.
- **Permissions, only as needed:**
  - **Automation → Google Chrome** — so the island can read chat tabs and jump to them.
  - **Accessibility** — so volume/brightness keys use the island instead of the system HUD, and so Stop recording can click the system control.
  - **Screen Recording** — so the menu-bar band can be painted black to match the notch (wallpaper tint). The app does not record your screen as a product feature; screen-recording *detection* is separate.
- The app does not show Apple’s Accessibility permission sheet on launch. You grant it from Settings when you want the keyboard HUD.

### What we do not claim

- No iPhone / iPad / Windows.
- No Safari / Arc / Firefox / Brave / Edge for **AI chat** (those browsers can still show in Now Playing).
- No API keys, accounts, or cloud sync.
- No lock-screen island.
- No replacing Notification Center, Slack, Mail, or calendar.

---

## Page 2 — Pricing

All numbers and plan names below are **placeholders**. The shipping app is currently **one binary with every feature unlocked** — there is no paywall in code. Until you decide, present **one paid product** plus a trial, not a fake Free vs Pro split.

### Recommended structure (one product)

| | **Dynamic Island** |
|---|---|
| **Price** | `PLACEHOLDER` — e.g. **$29** one-time |
| **What you get** | Everything on the product page, including AI reply banners and the Chrome helper |
| **Trial** | `PLACEHOLDER` — e.g. 14 days, all features |
| **Updates** | `PLACEHOLDER` — e.g. all 1.x updates included |
| **License** | `PLACEHOLDER` — e.g. one Mac / one person, or family of 3 |
| **Refunds** | `PLACEHOLDER` |

CTA: `PLACEHOLDER_BUY_URL` — “Buy” / “Download trial”

### If you later want tiers (do not use until real)

Only then split. Suggested (still placeholder — **not how the app works today**):

| | **Island** | **Island + AI** |
|---|---|---|
| Price | `PLACEHOLDER` | `PLACEHOLDER` |
| Now Playing, HUDs, shelf, recording | Yes | Yes |
| Claude / ChatGPT / Gemini banners | No | Yes |
| Chrome helper | — | Yes |

Do not invent a “Team” or “Enterprise” plan.

### Pricing page copy

- Headline: **One app. One price.**
- Subhead: Every island surface included. No account. No subscription unless you replace this sentence.
- Fine print: `PLACEHOLDER` — tax, currency, “macOS only,” “notch required.”
- FAQ (keep to 4):
  1. **Does it need Chrome?** Only for AI banners. Music, volume, charging, recording, and the shelf work without it.
  2. **Does it send my chats anywhere?** No. It reads the tab on this Mac. It does not call Claude, OpenAI, or Gemini APIs.
  3. **Will it cover the menu bar?** The island sits in the notch. Menu items stay clickable. A black wallpaper band makes the notch and island look like one piece.
  4. **What if I deny Accessibility?** The island still runs. Volume/brightness will keep using the system HUD until you grant it in Settings.

---

## Shared chrome

**Nav:** Dynamic Island · Features (anchor on `/`) · Pricing · Download (`PLACEHOLDER`)

**Footer:** © `PLACEHOLDER_YEAR` `PLACEHOLDER_COMPANY` · Privacy (`PLACEHOLDER` — suggested: “Runs on your Mac. No analytics in this brief; don’t invent a tracker.”) · Support email `PLACEHOLDER`

**Download line:** Apple Silicon `PLACEHOLDER` (Intel: `PLACEHOLDER` yes/no). Direct `.dmg` / Sparkle / Gumroad: `PLACEHOLDER`.

---

## Design notes for the builder

- Product page length: one screen of hero + a tight feature list. No 12-section storytelling.
- Show 4–6 island states as stills or a short loop if assets exist; otherwise use simple black pills with labels: Now Playing, Claude ready, Charging, Volume, Recording.
- Feature section: name + one sentence each. No icons-for-the-sake-of-icons grid of 20.
- Pricing page: one card, one CTA, short FAQ. That’s the whole page.
- Type: SF Pro or a close system sans. Dark background `#000` / `#0A0A0A`. Island fill black, hairline `#191919`. Accent only where the product uses it (recording red, charging green, Focus `#5853D7`).
- Motion: if any, match a notch expand — short, no bounce.

---

## Copy you can use as-is

**Product meta title:** Dynamic Island for Mac — Now Playing and AI banners in the notch  
**Product meta description:** A native island in the MacBook notch. Control what’s playing, replace the volume HUD, and get a banner when Claude, ChatGPT, or Gemini finishes in Chrome.

**Pricing meta title:** Pricing — Dynamic Island for Mac  
**Pricing meta description:** One-time `PLACEHOLDER` for the Mac notch island. All features included.

**Hero CTA helper:** Requires a notched MacBook. Chrome optional, except for AI banners.
