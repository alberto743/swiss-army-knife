#!/bin/bash

# SPDX-FileCopyrightText: © 2023 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail
#set -x

wrkdir=$(pwd)
mkdir -p pdfprotect
newdir=$(realpath -- "$wrkdir/pdfnew")

password=$(pwgen -s 32 1)
tmpdir=$(mktemp --directory)

cp *.pdf "$tmpdir"/
cd "$tmpdir"
for FILE in *.pdf
do
  echo "> ""$FILE"
  pdf2a.sh "$FILE"
  pdftk "$FILE" output "$newdir""/""$FILE" owner_pw "$password" allow printing
done

cd "$wrkdir"
rm -rf "$tmpdir"
