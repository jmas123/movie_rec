# Binged — Privacy Policy

**Unpublished.** `SupportLinks.privacyPolicy` points at
`https://trybinged.com/privacy`. The page to serve there is
`docs/public/privacy/index.html` — this file is the same text in Markdown, kept
for review; edit both or neither. App Store review follows that link and a 404
is a rejection.

**Last updated: 24 August 2026**

---

## The short version

Binged works fully without an account, and without an account **nothing you
do leaves your phone**.

If you create an account, your library is saved to it so it follows you between
devices. That is a backup, not a broadcast: **nothing is visible to anyone else
until you turn on sharing**, and turning sharing off hides it again without
deleting anything.

We do not track you, we do not run ads, and there is no analytics or
advertising SDK in the app.

## What we collect, and only if you sign up

- **Your email address** — to create and recover your account.
- **Your handle and display name** — how other people find and address you.
  Your handle is public by design; that is what makes an account findable.
- **Your library** — the films and series you have marked watched, the
  sentiment you gave each one, the position your comparisons put them in, your
  want-to-watch list, and any reviews you write.
- **What you post publicly** — comments, reactions, and who you follow.

We do not collect your contacts, your location, your photos, your advertising
identifier, or any device identifier used for tracking.

## What never leaves your phone

- **Everything, while you are signed out.** The whole app works this way:
  search, ranking, comparisons, recommendations, your profile.
- **Titles our catalogue could not identify.** These have nothing to key them
  to a server record, so they stay on the device. The app tells you how many
  there are rather than leaving a silent gap when you sign in elsewhere.
- **Your comparison history.** Only the resulting order is saved, never the
  individual "which did you prefer?" answers.

## Sharing is separate from saving, and it is off by default

This is the distinction that matters most, so it is stated plainly:

| | Who can see it | Do you choose? |
|---|---|---|
| Saved to your account | only you, on your own devices | no — it is what makes sync work |
| Shared to your profile | people who can view your profile | **yes, and it is off until you say so** |

Turning sharing off **hides** your rankings from other people. It does not
delete them, because that would destroy the backup you did not ask to lose.

If your account is private, only followers you have approved can see anything
you share. Blocking someone is mutual: they disappear from your view and you
from theirs.

## Where it is stored

On Supabase (PostgreSQL), hosted in the United States, encrypted in transit and
at rest. Access is enforced by row-level security in the database itself, not
by the app — the app cannot grant itself permission to read anything you have
not shared.

We use no third-party analytics, advertising, or attribution services. Film and
series metadata comes from TMDB; those requests carry no account identifier and
tell TMDB nothing about who you are.

## How long we keep it

As long as your account exists. **Deleting your account deletes what you
published** — profile, shared rankings, comments, follows — and leaves the
library on your phone untouched and fully usable signed out.

## Your choices

- **Export everything.** Settings → Export My Data gives you a JSON file of
  everything the app knows about your taste, including titles that were never
  shared.
- **Stop sharing** at any time: Settings → Sharing.
- **Delete your account** at any time: Settings → Delete Account.
- **Use the app with no account at all** — a supported, complete way to use it,
  not a degraded one.

## Children

Binged is not directed at children under 13 and we do not knowingly collect
their information.

## Changes

If this policy changes in a way that affects what we collect or who can see it,
the app will tell you in the app before the change takes effect — not only by
updating this page.

## Contact

`support@trybinged.com`, forwarded to a monitored mailbox by Cloudflare Email
Routing. Guideline 1.2 requires this to be reachable for an app carrying
user-generated content, and a reviewer will test it.
