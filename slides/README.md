<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->

# Achieving Balance

The workshop deck from [Goatmire 2026](https://goatmire.com), where about thirty
people built a balance bot from a pile of parts and programmed it, in four
hours. By James Harton and Gus Workman.

Four hours, an hour to a part:

| Hour | What happens |
|---|---|
| 1 | Who we are, what's in front of you, assembly, and getting a project on disk |
| 2 | How to describe a robot — links, joints, sensors, actuators, parameters |
| 3 | How to describe *your* robot — wheels, the IMU, and the first flash over USB |
| 4 | Putting it all together — wifi, the dashboard, the balance loop, and tuning it |

Each hour opens with five or ten minutes of slides and then leaves an
instruction slide up while everybody works, so the deck is meant to be read
alongside a robot rather than straight through.

## What's here

| File | |
|---|---|
| `balance-bot-workshop.pdf` | The deck, 80 pages, no speaker notes |
| `index.html` | The same deck for a browser |
| `presentation.md` | The source, *with* the speaker notes |
| `themes/workshop.css` | The theme it's set in |
| `assets/` | Assembly renders, part photographs, joint diagrams |

The speaker notes are worth reading if you're running this yourself or want the
reasoning behind a slide — they carry the measured numbers, the things that bit
us, and what to say when somebody's robot won't stand up.

## Rebuilding it

Needs [Marp CLI](https://github.com/marp-team/marp-cli). Build from *this*
directory — Marp only reads `.marprc.yml` from the current working directory,
and without it you get the default theme and no images:

```bash
marp presentation.md -o index.html
marp presentation.md --pdf -o balance-bot-workshop.pdf
```

Neither export includes the speaker notes. `marp --pdf-notes` would add them.

## A note on the images

Everything here is ours except two. The opening slide is Campus Varberg's
artwork, reproduced with their permission because they hosted us, and the
closing slide carries the Alembic logo. Both are marked as such in their
`.license` files and neither is covered by this repository's licence.
