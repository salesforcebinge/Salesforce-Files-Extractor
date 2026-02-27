#!/bin/bash
# =============================================================================
# Salesforce Files Extractor
# Downloads ContentVersion files from Salesforce with optional size filtering
#
# Usage:
#   ./extract-files.sh              # Extract ALL files (no size filter)
#   ./extract-files.sh 10           # Files over 10 MB
#   ./extract-files.sh 5 ./my-dir   # Files over 5 MB, custom output directory
#
# Prerequisites:
#   - sf CLI v2 authenticated to target org (sf org login web)
#   - jq installed (brew install jq)
#   - curl (pre-installed on macOS)
# =============================================================================

set -euo pipefail

# --- Configuration ---
MIN_SIZE_MB="${1:-}"
OUTPUT_DIR="${2:-./extracted-files}"
API_VERSION="v62.0"

echo "==========================================="
echo " Salesforce File Extractor"
echo "==========================================="
if [ -z "$MIN_SIZE_MB" ] || [ "$MIN_SIZE_MB" -eq 0 ] 2>/dev/null; then
    MIN_SIZE_BYTES=0
    echo " Filter    : ALL files (no size filter)"
else
    MIN_SIZE_BYTES=$((MIN_SIZE_MB * 1024 * 1024))
    echo " Min size  : ${MIN_SIZE_MB} MB (${MIN_SIZE_BYTES} bytes)"
fi
echo " Output    : ${OUTPUT_DIR}"
echo ""

# --- Preflight checks ---
if ! command -v sf &> /dev/null; then
    echo "ERROR: sf CLI not found. Install via: npm install -g @salesforce/cli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq not found. Install via: brew install jq"
    exit 1
fi

# --- Get org credentials ---
echo "[1/4] Authenticating with Salesforce..."
ORG_INFO=$(sf org display --json 2>/dev/null)

ACCESS_TOKEN=$(echo "$ORG_INFO" | jq -r '.result.accessToken')
INSTANCE_URL=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "ERROR: Not authenticated. Run: sf org login web"
    exit 1
fi

ORG_NAME=$(echo "$ORG_INFO" | jq -r '.result.alias // .result.username')
echo "  Connected to: ${ORG_NAME}"
echo ""

# --- Query ContentVersion ---
if [ "$MIN_SIZE_BYTES" -eq 0 ]; then
    echo "[2/4] Querying ALL ContentVersion records..."
    QUERY="SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId, CreatedDate, Owner.Name FROM ContentVersion WHERE IsLatest = true ORDER BY ContentSize DESC LIMIT 2000"
else
    echo "[2/4] Querying ContentVersion records over ${MIN_SIZE_MB} MB..."
    QUERY="SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId, CreatedDate, Owner.Name FROM ContentVersion WHERE ContentSize > ${MIN_SIZE_BYTES} AND IsLatest = true ORDER BY ContentSize DESC LIMIT 2000"
fi

RESULT=$(sf data query --query "$QUERY" --json 2>/dev/null)
TOTAL=$(echo "$RESULT" | jq '.result.totalSize')

if [ "$TOTAL" -eq 0 ]; then
    echo "  No files found."
    exit 0
fi

echo "  Found ${TOTAL} file(s)"
echo ""

# --- Display summary ---
echo "[3/4] File inventory:"
echo "-------------------------------------------"
printf "  %-40s %10s %s\n" "TITLE" "SIZE" "OWNER"
echo "-------------------------------------------"

echo "$RESULT" | jq -c '.result.records[]' | while read -r record; do
    TITLE=$(echo "$record" | jq -r '.Title')
    EXT=$(echo "$record" | jq -r '.FileExtension // "bin"')
    SIZE=$(echo "$record" | jq -r '.ContentSize')
    OWNER=$(echo "$record" | jq -r '.Owner.Name // "Unknown"')
    SIZE_MB=$(echo "scale=1; $SIZE / 1048576" | bc)

    DISPLAY_TITLE="${TITLE}.${EXT}"
    if [ ${#DISPLAY_TITLE} -gt 38 ]; then
        DISPLAY_TITLE="${DISPLAY_TITLE:0:35}..."
    fi
    printf "  %-40s %7s MB  %s\n" "$DISPLAY_TITLE" "$SIZE_MB" "$OWNER"
done

echo "-------------------------------------------"
echo ""

# --- Download files ---
echo "[4/4] Downloading files..."
mkdir -p "$OUTPUT_DIR"

# Write metadata CSV
META_FILE="${OUTPUT_DIR}/_file_manifest.csv"
echo "ContentVersionId,ContentDocumentId,Title,Extension,SizeBytes,SizeMB,Owner,CreatedDate,LocalFilename" > "$META_FILE"

COUNT=0
FAILED=0

echo "$RESULT" | jq -c '.result.records[]' | while read -r record; do
    COUNT=$((COUNT + 1))
    ID=$(echo "$record" | jq -r '.Id')
    DOC_ID=$(echo "$record" | jq -r '.ContentDocumentId')
    TITLE=$(echo "$record" | jq -r '.Title')
    EXT=$(echo "$record" | jq -r '.FileExtension // "bin"')
    SIZE=$(echo "$record" | jq -r '.ContentSize')
    OWNER=$(echo "$record" | jq -r '.Owner.Name // "Unknown"')
    CREATED=$(echo "$record" | jq -r '.CreatedDate')
    SIZE_MB=$(echo "scale=2; $SIZE / 1048576" | bc)

    # Sanitize filename — remove special chars, replace spaces with underscores
    SAFE_TITLE=$(echo "$TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g')
    FILENAME="${SAFE_TITLE}.${EXT}"

    # Handle duplicate filenames
    if [ -f "${OUTPUT_DIR}/${FILENAME}" ]; then
        FILENAME="${SAFE_TITLE}_${ID}.${EXT}"
    fi

    echo -n "  [${COUNT}/${TOTAL}] ${TITLE}.${EXT} (${SIZE_MB} MB) ... "

    # Download via REST API
    HTTP_CODE=$(curl -s -w "%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -o "${OUTPUT_DIR}/${FILENAME}" \
        "${INSTANCE_URL}/services/data/${API_VERSION}/sobjects/ContentVersion/${ID}/VersionData")

    if [ "$HTTP_CODE" -eq 200 ]; then
        echo "OK"
        # Append to manifest
        echo "${ID},${DOC_ID},\"${TITLE}\",${EXT},${SIZE},${SIZE_MB},\"${OWNER}\",${CREATED},${FILENAME}" >> "$META_FILE"
    else
        echo "FAILED (HTTP ${HTTP_CODE})"
        FAILED=$((FAILED + 1))
        rm -f "${OUTPUT_DIR}/${FILENAME}"
    fi
done

echo ""
echo "==========================================="
echo " Complete!"
echo " Downloaded: ${OUTPUT_DIR}/"
echo " Manifest:  ${META_FILE}"
if [ "$FAILED" -gt 0 ]; then
    echo " Failed: ${FAILED} file(s)"
fi
echo "==========================================="
