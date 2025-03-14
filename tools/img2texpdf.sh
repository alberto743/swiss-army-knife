#!/bin/bash

# SPDX-FileCopyrightText: © 2025 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail -x


if ! [ -f "$1" ]; then
  echo "File does not exist."
  exit 1
fi

filename="$(basename -- "$1")"
fnamefull="$(realpath -- "$1")"
extname="${filename##*.}"
fname="${filename%.*}"
dname="$(realpath "$(dirname "$1")")"

tmpdir=$(mktemp --directory)
tmptex=$(mktemp -p "$tmpdir" --suffix .tex)

cat << EOF > "$tmptex"
\documentclass{standalone}
\usepackage{graphicx}
\begin{document}
\includegraphics{$fnamefull}
\end{document}
EOF

pdflatex -interaction=batchmode -output-format=pdf -output-directory="$tmpdir" -jobname="$fname" "$tmptex"

gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
   -dPDFA=2 -sPDFACompatibilityPolicy=2 -dCompatibilityLevel=1.7 \
   -sColorConversionStrategy=RGB -sProcessColorModel=DeviceRGB \
   -sOutputFile="$dname"/"$fname"".pdf" \
   -f "$tmpdir"/"$fname"".pdf"

rm -rf "$tmpdir"
