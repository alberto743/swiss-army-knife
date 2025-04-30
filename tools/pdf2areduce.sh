#!/bin/bash

# SPDX-FileCopyrightText: © 2025 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail
#set -x

tmpdir=$(mktemp --directory)

filename=$(basename -- "$1")
fext="${filename##*.}"
fname="${filename%.*}"

filein=$(realpath -- "$1")
dirout="$(realpath "$(dirname "$1")")"

cp "$filein" "$tmpdir""/doc1.pdf"
exiftool -all= "$tmpdir""/doc1.pdf"
pdftk "$tmpdir""/doc1.pdf" output - uncompress | sed '/^\/Annots/d' > "$tmpdir""/doc2.pdf"

gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
   -dPDFA=2 -sPDFACompatibilityPolicy=2 -dCompatibilityLevel=1.7 \
   -sColorConversionStrategy=RGB -sProcessColorModel=DeviceRGB \
   -dSubsetFonts=true -dEmbedAllFonts=true \
   -dPDFSETTINGS=/screen \
   -sOutputFile="$tmpdir""/doc3.pdf" \
   -f "$tmpdir""/doc2.pdf"

mv "$filein" "$filein"".old"
mv "$tmpdir""/doc3.pdf" "$filein"
rm "$tmpdir""/doc1.pdf" "$tmpdir""/doc1.pdf_original" "$tmpdir""/doc2.pdf"
rmdir "$tmpdir"
