# Company & contact data verification

Checks the shared Supabase catalog (`companies`, `recruiters`) and fixes it so
that **every work mail domain maps to exactly one company, and the right one**.
A separate, more conservative pass fixes person names derived from addresses.

Run from this folder. Outputs go to `data_verification/` and backups to
`db_backups/` at the repo root; both are git-ignored because they hold people's
addresses and sent mail.

```bash
python3 backup.py                          # snapshot every table
python3 verify_companies.py                # dry run: plan + simulated result
python3 verify_companies.py --apply        # back up, apply, re-verify
python3 verify_names.py                    # dry run of the name pass
python3 verify_names.py --apply            # back up, apply, re-check
python3 audit.py ../../db_backups/<original>  # independent check vs a backup
python3 -m unittest -v test_pipeline       # the rules, pinned to cases
```

**Before `--apply`, always:** read the dry run's `report.md` (plan, moved
contacts, deletions), then run `audit.py` against the oldest backup. The
pipeline refuses to apply a plan whose simulated result has any violation.

`--snapshot <db_backups/…>` runs either dry run against a backup instead of the
live DB.

## Company pass (`verify_companies.py`)

1. Each contact's address is reduced to the domain its owner registers
   (`ny.email.gs.com` → `gs.com`, `in.pwc.com` → `pwc.com`, `mail.iitb.ac.in`
   → `iitb.ac.in`).
2. The verified rules in `decisions.json` are applied: duplicate companies to
   merge (and what to call the survivor), renames, host-level exceptions
   (`med.ge.com` is GE HealthCare, not GE), typo domains (moved to the real
   company and marked invalid), personal-mail buckets, junk rows, recruiting
   agencies whose contacts stay under the company they hire for, and domains
   left unresolved on purpose.
3. Every other registrable domain gets one owner — the company it's the main
   domain of — and stray contacts move there. A company is folded into another
   only once all of its contacts have moved; one misfiled contact never merges
   two companies.
4. Before anything is written the plan is simulated locally and re-verified;
   `--apply` refuses to run if the simulated result isn't clean.
5. Apply order matters because **deleting a company cascades to its contacts
   and their sent mail**: contacts move first, then tracked rows, then a
   company is deleted only after the DB confirms it has no contacts and no
   trackers left. Renames run last so a survivor can take a deleted row's name.
6. Afterwards the live DB is re-read and checked: invariants (no domain split
   across companies, no subdomain-named companies, typo contacts invalid, junk
   gone) plus conservation (same contacts minus junk, same sends, every
   tracked company still tracked or tracked via its successor).

Outputs per run: `plan.json`, and for `before/`, `simulated_after/` and
`after/`: `report.md`, `domain_map.csv|json` (domain → company, sector,
contacts, valid contacts, sends, who tracks it, kind), and
`fix_company_domains.sql`.

`fix_company_domains.sql` removes what shouldn't be in `companies.domains`: a
recruiting agency's domain on a client company, and typo domains. Mail hosts
like `ext.airbnb.com` stay — the app looks a company up by exact host. Run it
in the Supabase SQL editor; it's empty (just `begin; commit;`) when there's
nothing to fix.

### Personal mailboxes

`decisions.json` → `personal_contacts: delete` (the account owner's call,
2026-09-25): gmail/yahoo/outlook/… contacts are removed from the catalog. A
personal contact **with send history is held, never deleted** — deleting it
would cascade to its `mail_sends`, and that record is what stops a duplicate
cold mail if it's re-imported. The held ones are listed in the report.
"Personal" is the verified list in `domains.py`; a provider's *own* staff
domain (`titan.email`) or a company that also ran free mail (`sify.com`) is
not on it.

### Judgement calls need evidence

Merging two *different* domains is a claim that one employer owns both. A
second verification pass (2026-09-25) checked every such claim against the
web and found 12 of ~250 wrong or unsupported — e.g. `uste3.com` is a
logistics firm, not UST; `meta.com.br` is a Brazilian IT firm, not Meta;
`cms.co.in` is CMS Computers, not CMS Info Systems. Those rows were restored
with their original ids. Put the evidence in the rule's `"why"`, and when it
can't be found, leave the domain as its own company and list it under
`unresolved`.

Rules resolve companies through the ids pinned in `_ids`, never by name alone:
after renames a name can belong to a different row (the "Yahoo" and
"Indus Valley Partners" cases in `test_pipeline.py`).

## Independent audit (`audit.py`)

Compares an original backup with the live DB (or another backup) row by row
and checks every difference against the rules, without reusing the pipeline's
planning code: no contact invented or lost except junk and send-less personal
mailboxes, every move explained by a rule or by domain evidence, every deleted
company either junk or fully absorbed by one other, every send intact, every
tracked company still tracked (or its successor), and every changed name read
off the address.

## Name pass (`verify_names.py`)

Learns given names and surnames from the catalog's own `first.last` addresses,
then derives a name and greeting for each mailbox (`akushwah` → "A Kushwah",
greeted "Kushwah" like the app's `RecipientName`; `nehamathur` → "Neha
Mathur"; `careers@` → "Team"). It changes a row only when that derivation is
high-confidence **and** the stored value is empty, a role word, a one- or
two-letter fragment, or just the mailbox re-spaced by an importer. A
human-entered name is never overwritten; leetspeak mailboxes
(`talk2saravanan`) are left alone.

## Extending `decisions.json`

Names in it are `companies.name` values; the pipeline stops if one doesn't
resolve. Add a merge as `{"into": <survivor>, "name": <final name>, "from":
[...]}`, and put a `"why"` on anything that isn't obvious from the names.
