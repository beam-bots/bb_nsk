# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

import Config

# `nerves_runtime` is an optional dependency, so it is compiled and started
# here even though nothing in the suite runs on a board. Left unset it warns on
# every run about udev, which it does not manage in a project that has no device
# to manage it for.
config :nerves_uevent, manage_udev: false
