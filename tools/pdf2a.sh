#!/bin/bash

# SPDX-FileCopyrightText: © 2024 alberto743
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
pdftk "$tmpdir""/doc1.pdf" output - uncompress | sed '/^\/Annots/d' | pdftk - output "$tmpdir""/doc2.pdf" compress
qpdf --linearize "$tmpdir""/doc2.pdf" "$tmpdir""/doc3.pdf"

gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -dCompatibilityLevel=1.7 -sOutputFile="$tmpdir""/doc4.pdf" \
   -sColorConversionStrategy=RGB -sProcessColorModel=DeviceRGB \
   -dSubsetFonts=true -dEmbedAllFonts=true \
   -c '<</NeverEmbed []>> setdistillerparams' \
   -f "$tmpdir""/doc3.pdf"

gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
   -dPDFA=2 -sPDFACompatibilityPolicy=2 -dCompatibilityLevel=1.7 \
   -sColorConversionStrategy=RGB -sProcessColorModel=DeviceRGB \
   -sOutputFile="$tmpdir""/doc5.pdf" \
   -f "$tmpdir""/doc4.pdf"

mv "$tmpdir""/doc5.pdf" "$dirout""/""$fname""_2a.pdf"
rm "$tmpdir""/doc1.pdf" "$tmpdir""/doc1.pdf_original" "$tmpdir""/doc2.pdf" "$tmpdir""/doc3.pdf" "$tmpdir""/doc4.pdf"
rmdir "$tmpdir"
