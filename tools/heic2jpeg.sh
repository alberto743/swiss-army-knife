#!/bin/bash

# SPDX-FileCopyrightText: © 2025 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail
#set -x

mkdir -p heifconv

find . -name "*.heic" -print0 | parallel -0 'heif-convert "{}" "heifconv/$(basename "{}" .heic).jpeg"'
