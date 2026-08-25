# JTracker

An iOS app for running and tracking cold-mail job outreach. Track the companies
you're targeting, keep recruiter contacts for each, and send cold emails
straight from your own Gmail account using reusable templates — with a running
activity feed of everything you've sent.

Built with SwiftUI, backed by [Supabase](https://supabase.com) for data and
Google (Gmail) OAuth for sending mail.

## Features

- **Companies & contacts** — track target companies and the recruiters/contacts
  at each one.
- **Cold mail via Gmail** — connect your Google account (OAuth + PKCE) and send
  mail on your own behalf through the Gmail API.
- **Templates** — reusable subject/body templates with placeholders, rendered
  per contact before sending.
- **Profile** — your details are merged into templates so mails are personalized
  automatically.
- **Activity feed** — a per-send history that stays visible even after a company
  drops off the Home list.
- **Invalid contacts** — mark a contact invalid when the address bounces or the
  person has left. They drop to their own group at the bottom of the company
  page, are never suggested, and can no longer be mailed — reversibly, and for
  every user, since a dead address is dead for everyone.
- **Reply tracking** — every send records the Gmail thread it started, and the
  app reads those threads back to see who answered. Replies show up in Activity
  and drive Insights.
- **Insights** — Home's headline: reply rate, who has gone quiet longest,
  who answered (with the first lines of what they said), every unanswered mail
  by company, and who hasn't been contacted yet.

## Architecture

| Layer | Details |
|-------|---------|
| UI | SwiftUI (`JTracker/Views`), tab-based `RootView` |
| State | Observable stores — `JobStore`, `ProfileStore`, `TemplateStore`, `GmailAuthStore` (`JTracker/Models`) |
| Backend | Supabase (Postgres + Row Level Security), accessed via `SupabaseAPI` |
| Auth / mail | Google OAuth for sign-in and Gmail send (`GmailAuth`) |
| Local storage | Keychain for tokens, JSON files for cached state (`JTracker/Support`) |

Data is stored server-side in Supabase tables (`companies`, `recruiters`,
`mail_sends`, profiles, templates). The shared recruiter rows are read by all
users; per-user send state is overlaid from `mail_sends` after decoding.

The valid/invalid flag is the shared `recruiters.is_valid` column, not per-user
state — ruling a contact out is a fact about the address, so it applies to
everyone. It's written only by the dedicated `setRecruiterValidity` call, never
as part of an ordinary field edit, so correcting a bad address can't silently
put the contact back in circulation.

Reply state is the opposite: per-user, on `mail_sends`, because whether someone
wrote back is a fact about one mailbox. `ReplySync` runs two passes over Gmail —
it recovers the thread id for sends made before the app captured them (an exact
`in:sent to:… after:… before:…` lookup, not a guess), then reads each unanswered
thread's headers for a message that isn't ours. Matching inbound mail by sender
address was the obvious alternative and is worse: replies routinely arrive from a
colleague or an applicant-tracking system, and both keep the thread id while
neither keeps the address. Our own messages, out-of-office auto-replies and
bounces are excluded on three different header signals — see `ReplySync`.

## Design

The interface is warm and paper-like rather than the iOS default of neutral greys
on white: an ivory ground, warm near-black ink, hairline rules, and a single clay
accent. Two files hold all of it — `Support/Palette.swift` (colour and type) and
`Support/DesignSystem.swift` (surfaces, metrics, chips, the selector) — so a
screen never picks a colour or a corner radius of its own.

Three rules the components encode:

- **One surface.** Anything raised is the same paper at the same radius behind
  the same hairline. Depth is a rule, not a shadow.
- **Colour is information.** A card is coloured only when its colour means
  something, and then only as a rule down its leading edge: olive for a reply,
  a heat scale for how long a silence has run, faint for a contact ruled out.
  Decorative tint was removed — when every card was tinted, the tint that
  mattered was invisible.
- **Serif for titles and figures.** Navigation titles, the reply rate, and the
  day counts are set in the system serif; everything else is the system sans. A
  serif numeral among sans labels reads as a headline without being large.

## Requirements

- Xcode (iOS 27 SDK)
- iOS 27.0+ deployment target
- Swift 5
- A Supabase project and a Google Cloud OAuth iOS client

## Getting started

1. Clone the repo and open `JTracker.xcodeproj` in Xcode.
2. Configure your backend credentials in
   [`JTracker/AppConfig.swift`](JTracker/AppConfig.swift):
   - `supabaseURL` and `supabaseAnonKey` (anon public key — protected by RLS)
   - `googleClientID` and `googleRedirectScheme` (from your Google Cloud OAuth
     iOS client; the redirect scheme is the reversed client ID)
3. Apply any pending schema changes to your Supabase project (see
   [Database schema](#database-schema)).
4. Select an iOS Simulator or device and run (`⌘R`).

## Database schema

Schema changes the app expects, newest first. Run them in the Supabase SQL
editor; each is safe to re-run.

```sql
-- Reply tracking. Gmail's ids for each send, and what came back.
alter table mail_sends
  add column if not exists gmail_message_id text,
  add column if not exists gmail_thread_id  text,
  add column if not exists replied_at       timestamptz,
  add column if not exists reply_from       text,
  add column if not exists reply_snippet    text;

create index if not exists mail_sends_thread_idx
  on mail_sends (user_email, gmail_thread_id);

-- Contacts that bounce, or whose owner has left the company.
alter table recruiters
  add column if not exists is_valid boolean not null default true;
```

Until the first block is applied the app still runs — sends are recorded without
their Gmail ids and Insights shows no replies — and it says so on the Insights
panel rather than failing.

### Google OAuth

Reply tracking reads the mailbox, so the app requests `gmail.readonly` alongside
`gmail.send`. Two consequences:

- **Reconnect once after updating.** An existing token was minted without the
  read scope; Gmail rejects reads with a 403 until you disconnect and reconnect
  Gmail from the Profile tab.
- **`gmail.readonly` is a restricted scope.** While the OAuth consent screen is
  in *Testing* it works for listed test users as-is. Publishing an app that uses
  it requires Google's verification and an annual security assessment.

> **Note:** The Supabase anon key and the Google iOS client ID are not secrets —
> iOS clients ship them and rely on Row Level Security and PKCE. Do not, however,
> commit any service-role keys, client secrets, or provisioning profiles (see
> `.gitignore`).

## Project layout

```
JTracker/
├─ JTrackerApp.swift        App entry point
├─ AppConfig.swift          Supabase + Google OAuth configuration
├─ Models/                  Data models and observable stores
├─ Views/                   SwiftUI screens
├─ Support/                 Keychain, JSON persistence, theming
└─ Assets.xcassets/         App icon and colors
```
