#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

current_user="$(id -un)"
current_home="$(getent passwd "$current_user" | cut -d: -f6)"
current_shell="$(getent passwd "$current_user" | cut -d: -f7)"

export HOME="${HOME:-$current_home}"
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec "${current_shell}" -il
