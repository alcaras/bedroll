# Bedroll

A WoW Forever addon for the Cozy Sleeping Bag. Lie in the bag and Well-Rested gives +1% quest and kill XP per stack,
up to 3 stacks, for 2 hours. Bedroll shows how long to rest for 3/3 and reminds you when the buff runs low.

## What it shows

- **The countdown:** while you lie on a bag (on it, not next to it: lying on it rests you, as an inn does), a thin
  line above your character counts down to 3/3 with a fresh 2 hours. Right after you unroll it, the line says
  "Lie on the bag" until you do. The stacks show above it and the time left on its right, with a notch per stack. When it's full the line
  turns green and you get one chat line and a chime: you can get up.
- **The reminder:** out of combat, the bag's own button appears above your character when the bag is ready and the
  buff is missing, below 3/3, or has less than 10 minutes left. Click it to unroll the bag. It stays away in inns and
  cities (the bag can't be unrolled there), while mounted, on a flight, dead, and at the level cap.
- **The XP it gave:** the button's tooltip and `/bedroll` show about how much XP the buff has given you.

## The trick

Each stack starts the 2 hours over. So while you still have 3/3, **one minute** in the bag gives you a fresh 2 hours.
Refresh before it runs out: 15 s to unroll plus 1 minute of rest, instead of 15 s plus 3 minutes from nothing. The
bag's 1 hour cooldown never gets in the way, since the buff lasts 2 hours.

Spend that minute on something you'd do anyway: mail, sorting bags, crafting, eating and drinking, waiting for the
group, or the last minute before you log out.

## Commands

- `/bedroll`: where you are (stacks, time left, the bag's cooldown, what a refresh takes).
- `/bedroll remind on | off`: the reminder button.
- `/bedroll lead 10`: how many minutes before Well-Rested ends the reminder shows (0-120).
- `/bedroll test`: a 15 s countdown, to see where the line sits.
- `/bedroll on | off`: everything.

## Install

Download `Bedroll-<version>.zip` from [Releases](https://github.com/alcaras/bedroll/releases) and unzip it into `World of Warcraft\_forever_\Interface\AddOns`, so
the folder `Bedroll` holds `Bedroll.toc`.

World of Warcraft is Blizzard Entertainment's. A fan project, not affiliated with Blizzard.
