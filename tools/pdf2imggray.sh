#!/bin/bash

# SPDX-FileCopyrightText: © 2025 alberto743
#
# SPDX-License-Identifier: MPL-2.0

set -e -u -o pipefail
set -x

filename=$(basename -- "$1")
fext="${filename##*.}"
fname="${filename%.*}"
dirout="$(realpath "$(dirname "$1")")"
tmpdir=$(mktemp --directory)

cp "$filename" $tmpdir/input.pdf
cd $tmpdir

pdftocairo -gray -png input.pdf

for img in *.png
do
    img2texpdf.sh $img
done

pdftk $(ls input-*.pdf) cat output output.pdf

pdf2a.sh output.pdf

mv output_2a.pdf "$dirout"/"$fname"-new.pdf

cd -
rm -rf $tmpdir
