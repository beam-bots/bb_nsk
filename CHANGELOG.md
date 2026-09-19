<!--
SPDX-FileCopyrightText: 2026 James Harton

SPDX-License-Identifier: Apache-2.0
-->
# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.1.0](https://github.com/beam-bots/bb_nsk/compare/v0.1.0...v0.1.0) (2026-09-19)




### Features:

* add the panel, the LEDs, the network and the web interface by James Harton

* add the installer, its subsystem tasks, cheat and doctor by James Harton

* add the drivers, sensors and balance loop by James Harton

### Improvements:

* ship the drive pad hook, and record why not igniter_js by James Harton

* stop rescoping the asset tools by James Harton

* drop `dns_cluster`, and keep asset watchers off the board by James Harton

* fetch `phx_install` during the install rather than after it by James Harton

* have `bb_nsk.install` add the `phx_install` dependency by James Harton

### Bug Fixes:

* give the robot its own name, and make the drive pad respond by James Harton

* build assets into the firmware, and load fonts from this package by James Harton

* make `bb_nsk.add_web` safe to run twice by James Harton

* bring the access point up instead of waiting out a timeout by James Harton
