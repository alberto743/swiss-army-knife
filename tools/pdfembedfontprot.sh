#!/bin/bash

# SPDX-FileCopyrightText: © 2023 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail

mkdir -p pdfnew
password=$(pwgen -s 32 1)
TMPDIR=$(mktemp --directory)

for FILE in *.pdf
do
  echo ">""$FILE"
  gs -q -dBATCH -dNOPAUSE -sColorConversionStrategy=RGB -sDEVICE=pdfwrite -dSubsetFonts=true -dEmbedAllFonts=true -dCompatibilityLevel=1.4 -dPDFSETTINGS=/prepress -sOutputFile="$TMPDIR/doc1.pdf" "$FILE"
  pdftk "$TMPDIR/doc1.pdf" output "$TMPDIR/doc2.pdf" owner_pw "$password" allow printing
  mv "$TMPDIR/doc2.pdf" "pdfnew/$FILE"
done

rm "$TMPDIR/doc1.pdf"
rmdir "$TMPDIR"
