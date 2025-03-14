#!/bin/bash

# SPDX-FileCopyrightText: © 2025 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail
set -x

eqntex="$1"
eqnpng=$(mktemp -p $(pwd) -u)".png"

tmpdir=$(mktemp --directory)
tmptex=$(mktemp -p "$tmpdir" --suffix .tex)

cat << EOF > "$tmptex"
\documentclass[preview]{standalone}
\usepackage{amsmath}
\usepackage{amssymb}
\usepackage{amsthm}
\begin{document}
\begin{equation*}
$eqntex
\end{equation*}
\end{document}
EOF

pdflatex -interaction=batchmode -output-format=pdf -output-directory="$tmpdir" -jobname="eqn" "$tmptex"
pdfcrop "$tmpdir"/eqn.pdf

gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
   -dPDFA=2 -sPDFACompatibilityPolicy=2 -dCompatibilityLevel=1.7 \
   -sColorConversionStrategy=RGB -sProcessColorModel=DeviceRGB \
   -sOutputFile="$tmpdir"/"eqn2.pdf" \
   -f "$tmpdir"/"eqn-crop.pdf"

gs -q -dBATCH -dNOPAUSE -sDEVICE=pngalpha \
   -sOutputFile="$eqnpng" -r300 "$tmpdir"/"eqn2.pdf"

rm -rf "$tmpdir"

echo "$eqnpng"
