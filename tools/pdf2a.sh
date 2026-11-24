#!/bin/bash

# SPDX-FileCopyrightText: © 2024 alberto743
#
# SPDX-License-Identifier: MPL-2.0

# Sanitise a PDF (strip metadata), convert it to PDF/A-2b with an ICC
# OutputIntent, keep hyperlinks (optional), restore selected metadata and dates,
# linearise, and validate with veraPDF (native or via a throw-away podman container).
# The input file is replaced; the original is kept as <file>.old.
#
# Usage:  pdf2a.sh file.pdf
# Env:    ICC_PROFILE=/path/to/profile.icc   override ICC profile lookup
#         KEEP_LINKS=0|1                     1 (default): keep only Link annotations
#                                            (adds the Print flag required by PDF/A);
#                                            every other annotation is removed;
#                                            0: remove all annotations
#         STRICT=1                           abort (original untouched) if validation
#                                            fails or cannot be run, or if the
#                                            annotation check fails
#         SHOW_META=1                        print final metadata to stderr
#         KEEP_TMP=1                         keep the temporary directory (debugging)
#         VERAPDF_IMAGE=...                  override the veraPDF container image

set -e -u -o pipefail
#set -x

VERAPDF_IMAGE="${VERAPDF_IMAGE:-docker.io/verapdf/cli:latest}"
STRICT="${STRICT:-0}"
SHOW_META="${SHOW_META:-0}"
KEEP_TMP="${KEEP_TMP:-0}"
KEEP_LINKS="${KEEP_LINKS:-1}"

# ---------------------------------------------------------------- helpers

# Hex-encode raw bytes (body of a PostScript hex string).
to_hex() {
    printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

# UTF-8 text -> PDF text string (UTF-16BE with BOM) as a PostScript hex string.
to_pdf_text() {
    printf '<FEFF%s>' \
        "$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16BE | od -An -v -tx1 | tr -d ' \n')"
}

# ExifTool date ("YYYY:MM:DD HH:MM:SS[.fff][Z|+HH:MM]") -> PostScript string
# "(D:YYYYMMDDHHmmSS+HH'mm')". Returns 1 if the input cannot be parsed.
to_pdf_date() {
    local s="$1" d
    local re='^([0-9]{4}):([0-9]{2}):([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|([+-])([0-9]{2}):([0-9]{2}))?$'
    [[ $s =~ $re ]] || return 1
    d="D:${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    d+="${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
    if [[ "${BASH_REMATCH[8]}" == "Z" ]]; then
        d+="Z00'00'"
    elif [[ -n "${BASH_REMATCH[9]}" ]]; then
        d+="${BASH_REMATCH[9]}${BASH_REMATCH[10]}'${BASH_REMATCH[11]}'"
    fi
    # No timezone in the source: leave it out (allowed by the PDF spec)
    printf '(%s)' "$d"
}

# Append a text entry to the DOCINFO accumulator (skipped if the value is empty).
# $1 = DOCINFO key, $2 = UTF-8 value
add_text() {
    [[ -n "$2" ]] || return 0
    docinfo+=" /$1 $(to_pdf_text "$2")"
}

# Append a date entry to the DOCINFO accumulator (skipped if empty or unparsable).
# $1 = DOCINFO key, $2 = ExifTool date string
add_date() {
    [[ -n "$2" ]] || return 0
    local pd
    if pd=$(to_pdf_date "$2"); then
        docinfo+=" /$1 $pd"
    else
        echo "WARNING: cannot parse $1 '$2', skipping." >&2
    fi
}

# Locate an sRGB ICC profile (first match wins; ICC_PROFILE overrides the lookup).
find_icc() {
    local c
    if [[ -n "${ICC_PROFILE:-}" ]]; then
        [[ -r "$ICC_PROFILE" ]] && { printf '%s\n' "$ICC_PROFILE"; return 0; }
        return 1
    fi
    for c in \
        /usr/share/color/icc/ghostscript/srgb.icc \
        /usr/share/ghostscript/*/iccprofiles/srgb.icc \
        /usr/share/color/icc/colord/sRGB.icc \
        /usr/share/color/icc/sRGB.icc \
        /usr/share/color/icc/ghostscript/default_rgb.icc \
        /usr/share/ghostscript/*/iccprofiles/default_rgb.icc
    do
        if [[ -r "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# qpdf exits with 3 when it completed with warnings only: treat that as success.
qpdf_tolerant() {
    local rc=0
    qpdf "$@" || rc=$?
    [[ $rc -eq 0 || $rc -eq 3 ]]
}

# Count occurrences of a literal string in the QDF (plain-text) form of a PDF.
# $1 = PDF file, $2 = fixed string. Prints a number.
count_in_qdf() {
    qpdf --qdf --object-streams=disable "$1" - 2>/dev/null \
        | grep -a -F -c -- "$2" || true
}

# jq prelude shared by the annotation filters. Input: qpdf --json=2 output.
# is_link: true if the annotation (indirect ref or direct dict) is a Link.
# annots:  the page's /Annots as an array (resolves an indirect array), or [].
JQ_ANNOT_DEFS='
  .qpdf[1] as $o
  | def res: if type == "string" and test("^[0-9]+ [0-9]+ R$")
             then ($o["obj:" + .].value // null) else . end;
    def is_link: (res | type == "object" and .["/Subtype"] == "/Link");
    def annots: ((.["/Annots"] // []) | res) | if type == "array" then . else [] end;
    def pages: [ $o[] | .value | select(type == "object" and .["/Type"] == "/Page") ];
'

# Number of non-Link annotations reachable from page /Annots arrays. $1 = PDF file.
count_nonlink_annots() {
    local j
    j=$(mktemp)
    qpdf_tolerant --json=2 "$1" "$j"
    jq "$JQ_ANNOT_DEFS"'
        [ pages[] | annots[] | select(is_link | not) ] | length' "$j"
    rm -f -- "$j"
}

# Run veraPDF natively if available, otherwise through a throw-away podman container.
# Returns non-zero on non-compliance, on execution failure, or if no validator exists.
# Known-noisy parser warnings (unbalanced EMC in LibreOffice output) are summarised.
run_verapdf() {
    local pdf="$1" vdir errf rc=0 noisy
    errf=$(mktemp)
    if command -v verapdf >/dev/null 2>&1; then
        verapdf --flavour 2b --format text "$pdf" 2>"$errf" || rc=$?
    elif command -v podman >/dev/null 2>&1; then
        vdir=$(mktemp -d)
        # The container runs as uid 100 (verapdf): directory and file must be
        # world-readable, since mktemp -d creates a 0700 directory.
        chmod 755 "$vdir"
        cp -- "$pdf" "$vdir/doc.pdf"
        chmod 644 "$vdir/doc.pdf"
        podman run --rm --network=none -v "$vdir":/data:ro,Z \
            "$VERAPDF_IMAGE" --flavour 2b --format text /data/doc.pdf 2>"$errf" || rc=$?
        rm -rf -- "$vdir"
    else
        echo "WARNING: neither verapdf nor podman found, cannot validate." >&2
        rm -f -- "$errf"
        return 3
    fi
    noisy=$(grep -c 'EMC operator does not have a balancing' "$errf" || true)
    grep -v -E 'EMC operator does not have a balancing|OperatorParser parseOperator|^[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{4}' "$errf" >&2 || true
    [[ "$noisy" -eq 0 ]] || echo "(veraPDF: $noisy unbalanced-EMC parser warnings suppressed; they come from the source file)" >&2
    rm -f -- "$errf"
    return $rc
}

# ------------------------------------------------------------------ setup

if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: ${0##*/} file.pdf" >&2
    exit 2
fi

# Add pdftk to this list if the legacy annotation removal (step 2, commented) is re-enabled.
for cmd in gs exiftool qpdf iconv od realpath; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: required command '$cmd' not found." >&2
        exit 1
    }
done
if [[ "$KEEP_LINKS" == "1" ]]; then
    command -v jq >/dev/null 2>&1 || {
        echo "Error: required command 'jq' not found (needed for KEEP_LINKS=1)." >&2
        exit 1
    }
fi

filein=$(realpath -- "$1")
backup="${filein}.old"

# Refuse to overwrite a previous backup (it may be the only original copy).
if [[ -e "$backup" ]]; then
    echo "Error: $backup already exists, not overwriting." >&2
    exit 1
fi

icc=$(find_icc) || {
    echo "Error: no sRGB ICC profile found (set ICC_PROFILE=/path/file.icc)." >&2
    exit 1
}

tmpdir=$(mktemp -d)
trap 'if [[ "$KEEP_TMP" == "1" ]]; then echo "Kept: $tmpdir" >&2; else rm -rf -- "$tmpdir"; fi' EXIT

# ----------------------------- save original metadata (restored in step 4)

md_title=$(exiftool -s3 -PDF:Title "$filein"); [[ -n "$md_title" ]] || md_title=$(exiftool -s3 -XMP-dc:Title "$filein" || true)
md_author=$(exiftool -s3 -PDF:Author     "$filein" || true)
md_subject=$(exiftool -s3 -PDF:Subject   "$filein" || true)
md_keywords=$(exiftool -b -PDF:Keywords "$filein" || true)   # -b: raw string (-s3 splits/rejoins the list)
md_creator=$(exiftool -s3 -PDF:Creator   "$filein" || true)
md_create=$(exiftool -s3 -PDF:CreateDate "$filein" || true)
md_modify=$(exiftool -s3 -PDF:ModifyDate "$filein" || true)

docinfo=""
add_text Title    "$md_title"
add_text Author   "$md_author"
add_text Subject  "$md_subject"
add_text Keywords "$md_keywords"
add_text Creator  "$md_creator"
add_date CreationDate "$md_create"
add_date ModDate      "$md_modify"

# -------------------------------- build PDFA_def.ps (OutputIntent + DOCINFO)

pdfa_def="$tmpdir/PDFA_def.ps"
{
    echo '%!'
    echo '% ICC profile and OutputIntent (generated)'
    echo "/ICCProfile <$(to_hex "$icc")> def"
    echo '[/_objdef {icc_PDFA} /type /stream /OBJ pdfmark'
    echo '[{icc_PDFA} <</N 3>> /PUT pdfmark'
    echo '[{icc_PDFA} ICCProfile (r) file /PUT pdfmark'
    echo '[/_objdef {OutputIntent_PDFA} /type /dict /OBJ pdfmark'
    echo '[{OutputIntent_PDFA} <<'
    echo '  /Type /OutputIntent'
    echo '  /S /GTS_PDFA1'
    echo '  /DestOutputProfile {icc_PDFA}'
    echo '  /OutputConditionIdentifier (sRGB)'
    echo '>> /PUT pdfmark'
    echo '[{Catalog} <</OutputIntents [ {OutputIntent_PDFA} ]>> /PUT pdfmark'
    if [[ -n "$docinfo" ]]; then
        echo '% Document information restored from the original file'
        printf '[%s /DOCINFO pdfmark\n' "$docinfo"
    fi
} > "$pdfa_def"

# --------------------------------------------------------------- pipeline

cp -- "$filein" "$tmpdir/doc1.pdf"

# 1. Strip metadata from the file seen by Ghostscript. ExifTool's edit is
#    incremental (reversible), but it hides the old Info dictionary from gs,
#    which would otherwise take precedence over /DOCINFO (e.g. Creator "Impress").
#    -m: ignore the minor "edits are reversible" warning.
exiftool -q -m -overwrite_original -all= "$tmpdir/doc1.pdf"

# 2. Annotations.
src3="$tmpdir/doc1.pdf"
gs_annot_opts=(-dPreserveAnnots=false -dShowAnnots=false)   # default: remove all
n_links=0
n_other=0

if [[ "$KEEP_LINKS" == "1" ]]; then
    # PDF/A-2 (ISO 19005-2, 6.3.2) requires the Print flag (bit 3, value 4) on every
    # annotation, and Ghostscript drops non-printing ones. Fix Link annotations via
    # qpdf JSON (v2) + jq (see the /F normalisation below).
    # The same JSON update also strips every non-Link annotation: each page's
    # /Annots is rewritten to its Link entries only (dropped if none). The removed
    # annotation objects become unreferenced and are not written out.
    qpdf_tolerant --json=2 "$tmpdir/doc1.pdf" "$tmpdir/doc1.json"

    # /F is normalised to what PDF/A-2 requires: Print set; Invisible (1), Hidden (2)
    # and NoView (32) cleared. Direct (non-indirect) Link dictionaries in /Annots are
    # normalised in place, indirect ones through their own object.
    jq "$JQ_ANNOT_DEFS"'
        def bit($n): ((. / $n) | floor) % 2;
        def normf: . as $f | $f + (if ($f | bit(4)) == 0 then 4 else 0 end)
                                - ($f | bit(1)) - 2 * ($f | bit(2)) - 32 * ($f | bit(32));
        def fix_link: if (.["/F"] // 0 | type) == "number"
                      then . + {"/F": ((.["/F"] // 0) | normf)} else . end;
        def bad_f: (.["/F"] // 0) as $f
                   | ($f | type) == "number" and ($f | normf) != $f;
        ( [ pages[] | annots[] | select(is_link | not) ] | length ) as $n_other
        | ( $o | with_entries(
              select(
                ((.value.value | type) == "object")
                and (.value.value["/Subtype"] == "/Link")
                and (.value.value | bad_f)
              )
            )
            | map_values({value: (.value | fix_link)})
          ) as $print
        | ( $o | with_entries(
              select(
                ((.value.value | type) == "object")
                and (.value.value["/Type"] == "/Page")
                and (.value.value | annots | any(is_link | not or type == "object"))
              )
            )
            | map_values(
                ([ .value | annots[] | select(is_link)
                   | if type == "object" then fix_link else . end ]) as $keep
                | {value: (if ($keep | length) > 0
                           then .value + {"/Annots": $keep}
                           else .value | del(.["/Annots"]) end)}
              )
          ) as $pages
        | { n_links: ($print | length),
            n_other: $n_other,
            update:  {qpdf: [{jsonversion: 2}, ($print + $pages)]} }
        ' "$tmpdir/doc1.json" > "$tmpdir/annot_plan.json"

    n_links=$(jq '.n_links' "$tmpdir/annot_plan.json")
    n_other=$(jq '.n_other' "$tmpdir/annot_plan.json")
    jq '.update' "$tmpdir/annot_plan.json" > "$tmpdir/links_update.json"
    echo "Link annotations needing /F normalisation: $n_links" >&2
    echo "Non-link annotations to remove: $n_other" >&2

    if [[ "$n_links" -gt 0 || "$n_other" -gt 0 ]]; then
        qpdf_tolerant "$tmpdir/doc1.pdf" \
            --update-from-json="$tmpdir/links_update.json" "$tmpdir/doc2.pdf"
        src3="$tmpdir/doc2.pdf"
    fi
    gs_annot_opts=()    # let gs keep the (now printable) links
fi

# Legacy annotation removal via pdftk + sed (disabled; fragile: assumes /Annots
# sits on its own line in the uncompressed output).
# To re-enable: uncomment, set src3 accordingly, add pdftk to the dependency list.
#
# pdftk "$tmpdir/doc1.pdf" output - uncompress \
#     | LC_ALL=C sed '/^\/Annots/d' \
#     | pdftk - output "$tmpdir/doc2.pdf" compress
# qpdf_tolerant --check "$tmpdir/doc2.pdf" >/dev/null 2>&1 || {
#     echo "Error: PDF is structurally broken after annotation removal." >&2
#     exit 1
# }
# src3="$tmpdir/doc2.pdf"

# 3. Colour normalisation (RGB) and font embedding (+ annotation removal if
#    KEEP_LINKS=0; PreserveAnnots is the pdfwrite parameter, ShowAnnots the one of
#    the native PDF interpreter of gs 10.x).
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -dCompatibilityLevel=1.7 \
   "${gs_annot_opts[@]}" \
   -sOutputFile="$tmpdir/doc3.pdf" \
   -sColorConversionStrategy=RGB -sProcessColorModel=DeviceRGB \
   -dSubsetFonts=true -dEmbedAllFonts=true \
   -c '<</NeverEmbed []>> setdistillerparams' \
   -f "$src3"

# Check that the annotation outcome is what was asked for
annot_problem=0
if [[ "$KEEP_LINKS" == "1" ]]; then
    n_kept=$(count_in_qdf "$tmpdir/doc3.pdf" '/Subtype /Link')
    echo "Link annotations after Ghostscript: $n_kept" >&2
    if [[ "$n_links" -gt 0 && "$n_kept" -eq 0 ]]; then
        echo "WARNING: links were present in the input but none survived Ghostscript." >&2
        annot_problem=1
    fi
    n_left=$(count_nonlink_annots "$tmpdir/doc3.pdf")
    if [[ "$n_left" -gt 0 ]]; then
        echo "WARNING: $n_left non-link annotation(s) still present after Ghostscript." >&2
        annot_problem=1
    fi
else
    n_annots=$(count_in_qdf "$tmpdir/doc3.pdf" '/Annots')
    if [[ "$n_annots" -gt 0 ]]; then
        echo "WARNING: $n_annots '/Annots' occurrence(s) still present after annotation removal." >&2
        annot_problem=1
    fi
fi
if [[ "$annot_problem" -eq 1 && "$STRICT" == "1" ]]; then
    echo "STRICT=1: original file left untouched." >&2
    exit 1
fi

# 4. PDF/A-2 conversion with ICC OutputIntent; metadata and dates restored via DOCINFO
#    (the ICC file must be explicitly readable under SAFER)
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
   -dPDFA=2 -dPDFACompatibilityPolicy=2 -dCompatibilityLevel=1.7 \
   -sColorConversionStrategy=RGB \
   --permit-file-read="$icc" \
   -sOutputFile="$tmpdir/doc4.pdf" \
   "$pdfa_def" "$tmpdir/doc3.pdf"

# 5. Linearise last: any later rewrite would destroy linearisation.
#    --newline-before-endstream is required: without it qpdf writes streams that
#    violate PDF/A (ISO 19005-2, 6.1.7.1).
qpdf_tolerant --linearize --newline-before-endstream "$tmpdir/doc4.pdf" "$tmpdir/doc5.pdf"

# 6. Validation
if [[ "$SHOW_META" == "1" ]]; then
    exiftool -a -G1 -s "$tmpdir/doc5.pdf" >&2 || true
fi

if ! run_verapdf "$tmpdir/doc5.pdf" >&2; then
    echo "WARNING: veraPDF reported non-compliance or could not run." >&2
    if [[ "$STRICT" == "1" ]]; then
        echo "STRICT=1: original file left untouched." >&2
        exit 1
    fi
fi

# 7. Replace the original, keeping a backup.
#    Hardlink backup + mv -f over the original: the replacement is atomic.
#    (hardlinks may fail on some mounts, e.g. /mnt/<drive> in WSL: fall back to a copy)
cp -- "$tmpdir/doc5.pdf" "${filein}.new"
chmod --reference="$filein" -- "${filein}.new"
ln -- "$filein" "$backup" 2>/dev/null || cp -p -- "$filein" "$backup"
mv -f -- "${filein}.new" "$filein"
