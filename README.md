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
-- Contacts that bounce, or whose owner has left the company.
alter table recruiters
  add column if not exists is_valid boolean not null default true;
```

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
