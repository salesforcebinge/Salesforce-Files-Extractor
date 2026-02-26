# Salesforce Files Extractor

Extract ContentVersion files from any Salesforce org — locally or via GitHub Actions.

Queries the `ContentVersion` object, downloads the actual binary files via REST API, and generates a CSV manifest with full metadata. Optionally filter by file size.

---

> **IMPORTANT: If you plan to use the GitHub Action, make your cloned/forked repo private FIRST.**
>
> The GitHub Action extracts files from your Salesforce org and commits them to a branch in this repo. In a public repo, **all branches are visible to everyone** — including the `extracted-data` branch where your files are stored. Your Salesforce files (customer contracts, templates, internal documents) would be publicly accessible.
>
> **Before running the GitHub Action:**
> 1. Fork or clone this repo
> 2. Go to **Settings** > **General** > **Danger Zone** > **Change repository visibility** > **Make private**
> 3. Then set up the secret and run the workflow
>
> If you cannot make the repo private, use the **local script** (`extract-files.sh`) instead — it downloads files directly to your machine without committing anything to GitHub. See [Local Usage](#local-usage).

---

## How It Works

```
Salesforce Org
    │
    ├── ContentDocument (the logical file)
    │       └── ContentVersion (the actual versioned binary)
    │
    ▼
┌──────────────────────────────────┐
│  1. Authenticate with sf CLI     │
│  2. SOQL query ContentVersion    │
│  3. REST API: download each file │
│  4. Save locally + CSV manifest  │
└──────────────────────────────────┘
    │
    ▼
extracted-files/
  ├── _file_manifest.csv
  ├── Contract_ABC.docx
  ├── Product_Catalog.pdf
  └── Training_Manual.pptx
```

Salesforce stores files as `ContentDocument` → `ContentVersion` (one-to-many). This tool queries `ContentVersion` directly (filtering `IsLatest = true` to get only the current version), then hits the `/sobjects/ContentVersion/{Id}/VersionData` REST endpoint to stream the binary. No heap limits, no file size constraints.

---

## What's Included

| File | Purpose |
|------|---------|
| `.github/workflows/extract-files.yml` | GitHub Action — run on demand, files committed to repo automatically |
| `extract-files.sh` | Local script — run from terminal (macOS, Linux, Git Bash on Windows) |
| `list-files.apex` | Apex Anonymous — run in Developer Console to identify files without downloading |

---

## GitHub Action Usage

> **Reminder:** Make sure your repo is **private** before running the action. See the [security notice](#important-if-you-plan-to-use-the-github-action-make-your-clonedforked-repo-private-first) above.

The GitHub Action runs the extraction on demand and **commits the downloaded files to a separate `extracted-data` branch** — keeping `main` clean with only the tool's source code.

### How It Works

1. You click **Run workflow** in the GitHub Actions tab
2. The runner authenticates with Salesforce using a stored secret
3. It switches to the `extracted-data` branch (creates it on first run)
4. It queries ContentVersion, downloads all matching files
5. Files + manifest CSV are committed and pushed to `extracted-data`
6. You check out that branch to access the files

```
You (GitHub UI)
    │  "Run workflow" → min_size_mb: 5
    ▼
GitHub Actions Runner
    │  1. sf org login sfdx-url (from secret)
    │  2. git checkout extracted-data (or create it)
    │  3. SOQL → ContentVersion
    │  4. curl → download each file
    │  5. git add + git commit + git push → extracted-data
    ▼
Your Repo
    ├── main branch        ← source code only (what people clone)
    └── extracted-data     ← downloaded files live here
          ├── _file_manifest.csv
          ├── Contract_ABC.docx
          └── Product_Catalog.pdf
```

> **Why a separate branch?** Anyone who clones or forks the repo gets `main` by default — just the tool, no data. Your extracted files stay private on a branch you access when needed.

### One-Time Setup

**Step 1 — Get your SFDX Auth URL**

You must be authenticated to your org first (`sf org login web`). Then run:

**macOS / Linux / Git Bash:**
```bash
sf org display --verbose --json 2>/dev/null | jq -r '.result.sfdxAuthUrl'
```

**Windows PowerShell (no jq needed):**
```powershell
(sf org display --verbose --json 2>$null | ConvertFrom-Json).result.sfdxAuthUrl
```

This outputs a string like `force://PlatformCLI::xxxx@your-instance.my.salesforce.com`. Copy it.

**Step 2 — Add GitHub Secret**

1. Go to your GitHub repo
2. **Settings** > **Secrets and variables** > **Actions**
3. Click **New repository secret**
4. Name: `SFDX_AUTH_URL`
5. Value: paste the auth URL from Step 1
6. Click **Add secret**

**Step 3 — Push the repo** (including the `.github/workflows/` folder)

### Running the Action

1. Go to your repo on GitHub
2. Click the **Actions** tab
3. Select **Extract Salesforce Files** from the left sidebar
4. Click **Run workflow**
5. You'll see two inputs:

| Input | Default | Description |
|-------|---------|-------------|
| **Minimum file size in MB** | *(empty)* | Leave empty = extract ALL files. Enter a number (e.g., `5`) to filter by size. |
| **Folder in repo to store files** | `extracted-files` | Change if you want a different folder name in the repo. |

6. Click the green **Run workflow** button
7. Wait for the run to complete (check the Actions tab for progress)
8. Access the extracted files:

```bash
git fetch origin extracted-data
git checkout extracted-data
```

> These git commands work the same on all platforms (macOS, Linux, Windows).

### Commit Messages

The action auto-generates descriptive commit messages:

- `Extract 47 all files — 2026-02-14 10:30 UTC`
- `Extract 12 files over 5 MB — 2026-02-14 10:30 UTC`

All commits go to the `extracted-data` branch. If there are no new files, it skips the commit.

---

## Limits and Considerations

| Concern | Detail |
|---------|--------|
| **Data privacy** | The GitHub Action commits files to a branch in your repo. If your repo is public, those files are visible to everyone. **Make your repo private** or use the local script instead. |
| **Query limit** | The script queries up to 2,000 files per run (configurable `LIMIT` clause). Salesforce allows up to 50,000 rows per SOQL query. For orgs with more than 2,000 files, run multiple times with different size thresholds or increase the limit in the script/workflow. |
| **File size (local script)** | No per-file size limit — the REST API streams binary directly to disk. |
| **File size (GitHub Action)** | GitHub blocks files over **100 MB** per commit and warns at 50 MB. If your org has files larger than 100 MB, use the **local script** instead. |
| **GitHub repo size** | GitHub recommends repos stay under 5 GB total. For very large extractions, consider using Git LFS or a separate storage solution. |
| **Auth URL expiry** | SFDX Auth URLs use refresh tokens. These don't expire by default, but your Salesforce admin may enforce a Refresh Token Policy (e.g., 90-day expiry) in Session Settings. If authentication fails, regenerate the URL and update the GitHub secret. |
| **API calls** | Each file = 1 REST API call. Daily API limits vary by Salesforce edition: Developer Edition = 15,000/day, Enterprise = 100,000+/day, Unlimited = 100,000+/day. A run of 2,000 files is well within limits for most orgs. |
| **Duplicate filenames** | Handled — if two files share the same name, the ContentVersionId is appended to the second filename. |
| **Special characters** | File titles are sanitized (non-alphanumeric characters replaced with underscores). |

---

## Local Usage

### Prerequisites

| Tool | macOS | Linux | Windows |
|------|-------|-------|---------|
| **Salesforce CLI (sf)** | `npm install -g @salesforce/cli` | `npm install -g @salesforce/cli` | `npm install -g @salesforce/cli` |
| **jq** | `brew install jq` | `apt install jq` | `choco install jq` or [download from jqlang.org](https://jqlang.github.io/jq/download/) |
| **curl** | Pre-installed | Pre-installed | Pre-installed (Windows 10+) |
| **Git Bash** | Not needed (use Terminal) | Not needed (use Terminal) | Included with [Git for Windows](https://git-scm.com/download/win) — **required** to run the `.sh` script |

Verify installations:

```bash
sf --version
jq --version
curl --version
```

### One-Time Setup

These commands work on all platforms:

```bash
# Authenticate with your Salesforce org (opens browser)
sf org login web

# Set the target org so the script knows which org to query
sf config set target-org your-username@example.com
```

### Run

**macOS / Linux (Terminal) / Windows (Git Bash):**

```bash
cd sf-file-extractor

# Extract ALL files (no size filter)
./extract-files.sh

# Extract only files over 5 MB
./extract-files.sh 5

# Extract files over 10 MB into a custom folder
./extract-files.sh 10 ./my-output
```

> **Windows users:** Open **Git Bash** (not Command Prompt or PowerShell) to run the script. Right-click in the folder and select "Git Bash Here", or open Git Bash and `cd` to the folder.

### What You'll See

```
===========================================
 Salesforce File Extractor
===========================================
 Filter    : ALL files (no size filter)
 Output    : ./extracted-files

[1/4] Authenticating with Salesforce...
  Connected to: my-dev-org
[2/4] Querying ALL ContentVersion records...
  Found 23 file(s)
[3/4] File inventory:
-------------------------------------------
  TITLE                                        SIZE  OWNER
-------------------------------------------
  Product_Catalog.pdf                        12.4 MB  John Doe
  Contract_ABC.docx                      8.1 MB  Jane Smith
  ...
-------------------------------------------
[4/4] Downloading files...
  [1/23] Product_Catalog.pdf (12.40 MB) ... OK
  [2/23] Contract_ABC.docx (8.10 MB) ... OK
  ...

===========================================
 Complete!
 Downloaded: ./extracted-files/
 Manifest:  ./extracted-files/_file_manifest.csv
===========================================
```

### Output

The `_file_manifest.csv` contains full traceability:

| Column | Example |
|--------|---------|
| ContentVersionId | `068xx00000xxxxx` |
| ContentDocumentId | `069xx00000xxxxx` |
| Title | `Contract_ABC` |
| Extension | `docx` |
| SizeMB | `8.10` |
| Owner | `Jane Smith` |
| CreatedDate | `2026-01-15T09:30:00.000+0000` |
| LocalFilename | `Contract_ABC.docx` |

---

## Apex Anonymous (Identification Only)

If you just want to **list** files without downloading — run `list-files.apex` in Developer Console or VS Code. Works on any platform.

### How to Run

**Developer Console:**
1. Open Developer Console in Salesforce
2. Debug > Open Execute Anonymous Window
3. Paste the contents of `list-files.apex`
4. Change `minSizeMB` on line 11 if needed (default: `0` = all files)
5. Execute — check the debug log for results

**VS Code:**
1. Open the file in VS Code with Salesforce Extension Pack installed
2. `Ctrl+Shift+P` (Windows/Linux) or `Cmd+Shift+P` (macOS) > **SFDX: Execute Anonymous Apex with Currently Selected Text**

### Output

```
=====================================
 ALL FILES: 47 found
=====================================
8.10 MB | Contract_ABC.docx | DocId: 069xx... | Owner: Jane Smith | Created: 2026-01-15
6.30 MB | Product_Catalog.pdf    | DocId: 069xx... | Owner: John Doe   | Created: 2026-02-01
...
=====================================
 TOTAL: 47 files, 189.4 MB
=====================================
```

---

## Repo Structure

```
sf-file-extractor/
├── .github/
│   └── workflows/
│       └── extract-files.yml       # GitHub Action workflow
├── extract-files.sh                # Local extraction script
├── list-files.apex                 # Apex anonymous for identification
├── .gitignore
└── README.md
```

---

## License

MIT
