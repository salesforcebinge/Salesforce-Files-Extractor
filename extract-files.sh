#!/bin/bash
# =============================================================================
# Salesforce File Extractor
# Downloads ContentVersion files from Salesforce with optional size filtering
#
# Features:
#   - Parallel downloads (configurable concurrency)
#   - Resume mode (re-run to pick up where you left off)
#   - Checksum validation (MD5 verified against Salesforce)
#   - CSV manifest with full metadata and verification status
#
# Usage:
#   ./extract-files.sh                    # Extract ALL files
#   ./extract-files.sh 10                 # Files over 10 MB
#   ./extract-files.sh 5 ./my-dir         # Custom output directory
#   ./extract-files.sh 5 ./my-dir 10      # 10 parallel downloads
#
# Prerequisites:
#   - sf CLI v2 authenticated to target org (sf org login web)
#   - jq installed (brew install jq)
#   - curl (pre-installed on macOS)
#   - User must have "Query All Files" permission to access all org files
# =============================================================================

set -uo pipefail

# --- Configuration ---
MIN_SIZE_MB="${1:-}"
OUTPUT_DIR="${2:-./extracted-files}"
PARALLEL="${3:-5}"
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
echo " Parallel  : ${PARALLEL} concurrent downloads"
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

# --- MD5 utility (cross-platform) ---
compute_md5() {
    if command -v md5sum &> /dev/null; then
        md5sum "$1" | cut -d' ' -f1
    elif command -v md5 &> /dev/null; then
        md5 -q "$1"
    else
        echo ""
    fi
}

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

# --- Query ContentVersion (includes Checksum for validation) ---
if [ "$MIN_SIZE_BYTES" -eq 0 ]; then
    echo "[2/4] Querying ALL ContentVersion records..."
    QUERY="SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId, Checksum, CreatedDate, Owner.Name FROM ContentVersion WHERE IsLatest = true ORDER BY ContentSize DESC LIMIT 2000"
else
    echo "[2/4] Querying ContentVersion records over ${MIN_SIZE_MB} MB..."
    QUERY="SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId, Checksum, CreatedDate, Owner.Name FROM ContentVersion WHERE ContentSize > ${MIN_SIZE_BYTES} AND IsLatest = true ORDER BY ContentSize DESC LIMIT 2000"
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
echo "[4/4] Downloading files (${PARALLEL} parallel)..."
mkdir -p "$OUTPUT_DIR"

# Manifest CSV
META_FILE="${OUTPUT_DIR}/_file_manifest.csv"
HEADER="ContentVersionId,ContentDocumentId,Title,Extension,SizeBytes,SizeMB,Owner,CreatedDate,Checksum,Verified,LocalFilename"

# Resume: check for existing manifest and collect already-downloaded IDs
SKIP_IDS=""
SKIP_COUNT=0
if [ -f "$META_FILE" ]; then
    SKIP_IDS=$(cut -d',' -f1 "$META_FILE" | tail -n +2 || true)
    SKIP_COUNT=$(echo "$SKIP_IDS" | grep -c . 2>/dev/null || echo "0")
    if [ "$SKIP_COUNT" -gt 0 ]; then
        echo "  Resume mode: ${SKIP_COUNT} files already downloaded, skipping."
        echo ""
    fi
else
    echo "$HEADER" > "$META_FILE"
fi

# Tally directory for counting results across parallel subshells
TALLY_DIR=$(mktemp -d)

# Process records in parallel batches
BATCH=0

while IFS= read -r record; do
    ID=$(echo "$record" | jq -r '.Id')

    # Resume: skip already-downloaded files
    if [ -n "$SKIP_IDS" ] && echo "$SKIP_IDS" | grep -q "^${ID}$" 2>/dev/null; then
        touch "${TALLY_DIR}/skip_${ID}"
        continue
    fi

    # Launch download in background subshell
    (
        DOC_ID=$(echo "$record" | jq -r '.ContentDocumentId')
        TITLE=$(echo "$record" | jq -r '.Title')
        EXT=$(echo "$record" | jq -r '.FileExtension // "bin"')
        SIZE=$(echo "$record" | jq -r '.ContentSize')
        OWNER=$(echo "$record" | jq -r '.Owner.Name // "Unknown"')
        CREATED=$(echo "$record" | jq -r '.CreatedDate')
        SF_CHECKSUM=$(echo "$record" | jq -r '.Checksum // ""')
        SIZE_MB=$(echo "scale=2; $SIZE / 1048576" | bc)

        # Sanitize filename
        SAFE_TITLE=$(echo "$TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g')
        FILENAME="${SAFE_TITLE}.${EXT}"

        # Handle duplicate filenames
        if [ -f "${OUTPUT_DIR}/${FILENAME}" ]; then
            FILENAME="${SAFE_TITLE}_${ID}.${EXT}"
        fi

        # Download via REST API
        HTTP_CODE=$(curl -s -w "%{http_code}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -o "${OUTPUT_DIR}/${FILENAME}" \
            "${INSTANCE_URL}/services/data/${API_VERSION}/sobjects/ContentVersion/${ID}/VersionData" || echo "000")

        if [ "$HTTP_CODE" -eq 200 ]; then
            # Checksum validation
            VERIFIED="skipped"
            if [ -n "$SF_CHECKSUM" ]; then
                LOCAL_MD5=$(compute_md5 "${OUTPUT_DIR}/${FILENAME}")
                if [ -n "$LOCAL_MD5" ]; then
                    if [ "$LOCAL_MD5" = "$SF_CHECKSUM" ]; then
                        VERIFIED="ok"
                        touch "${TALLY_DIR}/chk_ok_${ID}"
                    else
                        VERIFIED="MISMATCH"
                        touch "${TALLY_DIR}/chk_fail_${ID}"
                    fi
                fi
            fi

            echo "  OK: ${TITLE}.${EXT} (${SIZE_MB} MB) [checksum: ${VERIFIED}]"
            echo "${ID},${DOC_ID},\"${TITLE}\",${EXT},${SIZE},${SIZE_MB},\"${OWNER}\",${CREATED},${SF_CHECKSUM},${VERIFIED},${FILENAME}" >> "$META_FILE"
            touch "${TALLY_DIR}/ok_${ID}"
        else
            echo "  FAILED: ${TITLE}.${EXT} (HTTP ${HTTP_CODE})"
            rm -f "${OUTPUT_DIR}/${FILENAME}"
            touch "${TALLY_DIR}/fail_${ID}"
        fi
    ) &

    BATCH=$((BATCH + 1))
    if [ "$BATCH" -ge "$PARALLEL" ]; then
        wait
        BATCH=0
    fi
done < <(echo "$RESULT" | jq -c '.result.records[]')
wait

# Count results from tally files
DOWNLOADED=$(find "$TALLY_DIR" -name "ok_*" 2>/dev/null | wc -l | tr -d ' ')
FAILED=$(find "$TALLY_DIR" -name "fail_*" 2>/dev/null | wc -l | tr -d ' ')
SKIPPED=$(find "$TALLY_DIR" -name "skip_*" 2>/dev/null | wc -l | tr -d ' ')
CHK_OK=$(find "$TALLY_DIR" -name "chk_ok_*" 2>/dev/null | wc -l | tr -d ' ')
CHK_FAIL=$(find "$TALLY_DIR" -name "chk_fail_*" 2>/dev/null | wc -l | tr -d ' ')

# Cleanup temp files
rm -rf "$TALLY_DIR"

echo ""
echo "==========================================="
echo " Complete!"
echo " Downloaded : ${DOWNLOADED}"
[ "$SKIPPED" -gt 0 ] && echo " Skipped    : ${SKIPPED} (resumed)"
[ "$FAILED" -gt 0 ] &&  echo " Failed     : ${FAILED}"
[ "$CHK_OK" -gt 0 ] &&  echo " Verified   : ${CHK_OK} checksums OK"
[ "$CHK_FAIL" -gt 0 ] && echo " MISMATCH   : ${CHK_FAIL} checksum failures — review manifest"
echo " Manifest   : ${META_FILE}"
echo " Output     : ${OUTPUT_DIR}/"
echo "==========================================="
