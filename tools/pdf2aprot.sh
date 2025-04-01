#!/bin/bash

# SPDX-FileCopyrightText: © 2023 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail
#set -x

wrkdir=$(pwd)
mkdir -p pdfprotect
newdir=$(realpath -- "$wrkdir/pdfprotect")

password=$(pwgen -s 32 1)
tmpdir=$(mktemp --directory)

cp *.pdf "$tmpdir"/
cd "$tmpdir"
for FILE in *.pdf
do
  echo "> ""$FILE"
  pdftk "$FILE" dump_data | grep -F -w -e "InfoKey: Author" -e "InfoKey: Title" -A 1 -B 1 > "$FILE".info
  pdf2a.sh "$FILE"
  pdftk "$FILE" update_info_utf8 "$FILE".info output "$newdir""/""$FILE" owner_pw "$password" allow printing
done

cd "$wrkdir"
rm -rf "$tmpdir"
