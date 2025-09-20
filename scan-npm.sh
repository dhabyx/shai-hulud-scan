#!/usr/bin/env bash
set -Eeuo pipefail

# scan-npm.sh — lockfile, global npm, NVM, and Nave scanner
# Version: 2025-09-19
# Changes: Nave support adjusted to the real ~/.nave/installed/* structure
#          (searches global packages in any .../installed/*/lib/node_modules/*/package.json)
# Quick usage:
#   ./scan-npm.sh -t "@ctrl/tinycolor@4.1.1,ngx-toastr@19.0.2" -d /project/path -g --nvm --nave
#   ./scan-npm.sh -f iocs.txt -d ~/repos --nvm --nave --nave-root "$HOME/.nave"

print_help() {
  cat <<'EOF'
npm package scanner (lockfiles, global -g, NVM, Nave, and suspicious script/code patterns)

USAGE:
  scan-npm.sh [options]

OPTIONS:
  -t "TERM1,TERM2,..."     Comma-separated list of search terms (e.g., "pkg@1.2.3,other")
  -f FILE                  File with search terms (one per line)
  -d DIR                   Directory to scan (can be repeated)
  -g                       Include global packages check (npm -g)
  --nvm[=PATH]             Include NVM check (auto: $NVM_DIR or ~/.nvm). You may pass an explicit path.
  --nave                   Include Nave check using ~/.nave by default
  --nave-root PATH         Base path for Nave (defaults to ~/.nave)
  -o FILE                  Also save report to FILE (TSV)
  --suspicious             Enable built-in suspicious scripts/code scan (package.json scripts + code under -d)
  --suspicious-all         Scan all readable text files under -d (ignores common vendor paths); otherwise only package.json and a small set
  -q                       Quiet (fewer logs)
  -h                       Help

FORMATS SEARCHED IN DIRECTORIES:
  package-lock.json, pnpm-lock.yaml, yarn.lock

NAVE SPECIAL NOTES:
  Global packages are inspected in any path matching:
    <NAVE_ROOT>/installed/*/lib/node_modules/*/package.json
  This covers both version directories (e.g., 22.19.0) and named environments (e.g., "mifos", "ui4p").

EXAMPLES:
  # Search for two terms in two projects and in global:
  scan-npm.sh -t "@ctrl/tinycolor@4.1.1,ngx-toastr@19.0.2" -d ~/projA -d ~/projB -g

  # Terms from a file, and include NVM and Nave (autodetect by default):
  scan-npm.sh -f iocs.txt -d /srv/repos --nvm --nave

  # Check a custom NVM and Nave path:
  scan-npm.sh -t "koa2-swagger-ui@5.11.2" --nvm=/opt/nvm --nave-root /home/user/.nave
EOF
}

# ---------- options ----------
TERMS_STR=""
TERMS_FILE=""
DIRS=()
CHECK_GLOBAL=false
NVM_FLAG=false
NVM_PATH=""
NAVE_FLAG=false
NAVE_ROOT="${HOME}/.nave"
OUTFILE=""
QUIET=false
SUSPICIOUS=false
SUSPICIOUS_ALL=false

for arg in "$@"; do
  case "$arg" in
    -h|--help) print_help; exit 0 ;;
  esac
done

# manual parsing for long options with =
while (( "$#" )); do
  case "$1" in
    -t) TERMS_STR="${2:-}"; shift 2;;
    -f) TERMS_FILE="${2:-}"; shift 2;;
    -d) DIRS+=("${2:-}"); shift 2;;
    -g) CHECK_GLOBAL=true; shift ;;
    --nvm) NVM_FLAG=true; NVM_PATH=""; shift ;;
    --nvm=*) NVM_FLAG=true; NVM_PATH="${1#--nvm=}"; shift ;;
    --nave) NAVE_FLAG=true; shift ;;
    --nave-root) NAVE_FLAG=true; NAVE_ROOT="${2:-}"; shift 2;;
    -o) OUTFILE="${2:-}"; shift 2;;
    --suspicious) SUSPICIOUS=true; shift ;;
    --suspicious-all) SUSPICIOUS=true; SUSPICIOUS_ALL=true; shift ;;
    -q) QUIET=true; shift ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 1;;
    *)  # positional (directory)
        DIRS+=("$1"); shift ;;
  esac
done

log() { $QUIET || echo -e "$*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- terms ----------
TERMS=()

if [[ -n "$TERMS_STR" ]]; then
  IFS=',' read -r -a arr <<<"$TERMS_STR"
  for t in "${arr[@]}"; do
    t="${t//[[:space:]]/}"
    [[ -n "$t" ]] && TERMS+=("$t")
  done
fi

if [[ -n "$TERMS_FILE" ]]; then
  [[ -f "$TERMS_FILE" ]] || die "Terms file does not exist: $TERMS_FILE"
  while IFS= read -r line; do
    line="${line%%#*}"             # strip end-of-line comments
    line="${line//[[:space:]]/}"   # remove whitespace
    [[ -n "$line" ]] && TERMS+=("$line")
  done < "$TERMS_FILE"
fi

if [[ ${#TERMS[@]} -eq 0 ]]; then
  die "You must provide terms with -t or -f (e.g., -t \"@ctrl/tinycolor@4.1.1,ngx-toastr@19.0.2\")."
fi

# build a safe regex for grep -E (escape regex characters in each term)
escape_regex() {
  local s="$1"
  # escape: . \ + * ? [ ^ ] $ ( ) { } = ! < > | : -
  s="${s//\\/\\\\}"; s="${s//\./\\.}"; s="${s//\+/\\+}"; s="${s//\*/\\*}"
  s="${s//\?/\\?}"; s="${s//\[/\\[}"; s="${s//\^/\\^}"; s="${s//\]/\\]}"
  s="${s//\$/\\$}"; s="${s//\(/\\(}"; s="${s//\)/\\)}"; s="${s//\{/\\{}"
  s="${s//\}/\\}}"; s="${s//\=/\\=}"; s="${s//\!/\\!}"; s="${s//\</\\<}"
  s="${s//\>/\\>}"; s="${s//\|/\\|}"; s="${s//\:/\\:}"; s="${s//\-/\\-}"
  echo "$s"
}

PATTERNS=()
for t in "${TERMS[@]}"; do
  PATTERNS+=("$(escape_regex "$t")")
  # Also match by name only (if provided with @version), for broader coverage
  if [[ "$t" == *@* ]]; then
    name_only="${t%@*}"
    [[ -n "$name_only" ]] && PATTERNS+=("$(escape_regex "$name_only")@")
  fi

done
COMBINED_REGEX="$(IFS='|'; echo "${PATTERNS[*]}")"

# ---------- output ----------
emit_header=true
emit() {
  local scope="$1" path="$2" match="$3"
  if [[ -n "$OUTFILE" ]]; then
    if $emit_header; then
      printf "SCOPE\tLOCATION\tMATCH\n" > "$OUTFILE"
      emit_header=false
    fi
    printf "%s\t%s\t%s\n" "$scope" "$path" "$match" >> "$OUTFILE"
  fi
  printf "%-12s | %-60s | %s\n" "$scope" "$path" "$match"
}

# ---------- Suspicious patterns (built-in) ----------
SUSP_ETH="0xFc4a4858bafef54D1b1d7697bfb5c52F4c166976"
# regex groups for grep -E
SUSP_GLOBALS_RE="stealthProxyControl|runmask|checkethereumw"
SUSP_TOOLS_RE="trufflehog|TruffleHog"
# Common crypto-stealer/script patterns in npm scripts
SUSP_SCRIPT_RE="(curl|wget).*(https?|ipfs)://|bash\s+-c\s+|node\s+-e\s+|powershell\s+-|Invoke-WebRequest|setInterval\(.*(fetch|XMLHttpRequest)|eval\(|Function\(|require\(['\"]child_process['\"]\)"

# ---------- 1) Directory scan ----------
scan_dirs() {
  [[ ${#DIRS[@]} -gt 0 ]] || return 0
  log "📁 Scanning directories: ${DIRS[*]}"
  for dir in "${DIRS[@]}"; do
    [[ -d "$dir" ]] || { log "  (skipped) Does not exist: $dir"; continue; }
    while IFS= read -r -d '' f; do
      if grep -E -Hn "$COMBINED_REGEX" "$f" >/dev/null 2>&1; then
        while IFS= read -r line; do
          emit "LOCKFILE" "$f" "$line"
        done < <(grep -E -n "$COMBINED_REGEX" "$f" | cut -c -200)
      fi
    done < <(find "$dir" -type f \( -name "package-lock.json" -o -name "pnpm-lock.yaml" -o -name "yarn.lock" \) -print0 2>/dev/null)
  done
}

# ---------- 2) npm global ----------
scan_global() {
  $CHECK_GLOBAL || return 0
  if ! command -v npm >/dev/null 2>&1; then
    log "⚠️  npm is not available in PATH; skipping global check."
    return 0
  fi
  log "🌐 Checking npm global (-g) ..."
  local list
  if ! list="$(node -e 'try{const o=JSON.parse(require("child_process").execSync("npm ls -g --depth=0 --json",{stdio:["ignore","pipe","ignore"]}).toString());for(const [k,v] of Object.entries(o.dependencies||{})){console.log(`${k}@${v.version||""}`)}}catch(e){process.exit(0)}' 2>/dev/null)"; then
    log "⚠️  Could not read npm -g."
    return 0
  fi
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if [[ "$pkg" =~ $COMBINED_REGEX ]]; then
      emit "NPM-GLOBAL" "(npm -g)" "$pkg"
    fi
  done <<< "$list"
}

# ---------- 3) NVM ----------
scan_nvm() {
  $NVM_FLAG || return 0
  local base="${NVM_PATH:-${NVM_DIR:-$HOME/.nvm}}"
  if [[ ! -d "$base" ]]; then
    log "⚠️  NVM not found at: $base"
    return 0
  fi
  log "🟣 Checking NVM at: $base"
  while IFS= read -r -d '' pkgjson; do
    local nv
    nv="$(node -e 'try{const p=require(process.argv[1]); console.log(`${p.name||""}@${p.version||""}`)}catch(e){process.exit(0)}' "$pkgjson" 2>/dev/null || true)"
    [[ -z "$nv" ]] && continue
    if [[ "$nv" =~ $COMBINED_REGEX ]]; then
      emit "NVM" "$(dirname "$pkgjson")" "$nv"
    fi
  done < <(find "$base/versions/node" -type f -path "*/lib/node_modules/*/package.json" -print0 2>/dev/null)
}

# ---------- 4) Nave (real structure ~/.nave/installed/*) ----------
scan_nave() {
  $NAVE_FLAG || return 0
  local base="$NAVE_ROOT"
  if [[ ! -d "$base" ]]; then
    log "⚠️  Nave not found at: $base"
    return 0
  fi
  local installed_dir="$base/installed"
  if [[ ! -d "$installed_dir" ]]; then
    log "⚠️  'installed' directory does not exist at: $base"
    return 0
  fi
  log "🔵 Checking Nave at: $installed_dir"

  # Search any package.json under .../installed/*/lib/node_modules/*/
  # This covers both version directories (e.g., 22.19.0) and named environments (e.g., mifos, ui4p, etc.)
  local found=false
  while IFS= read -r -d '' pkgjson; do
    found=true
    local nv
    nv="$(node -e 'try{const p=require(process.argv[1]); console.log(`${p.name||""}@${p.version||""}`)}catch(e){process.exit(0)}' "$pkgjson" 2>/dev/null || true)"
    [[ -z "$nv" ]] && continue
    if [[ "$nv" =~ $COMBINED_REGEX ]]; then
      emit "NAVE" "$(dirname "$pkgjson")" "$nv"
    fi
  done < <(find "$installed_dir" -type f -path "*/lib/node_modules/*/package.json" -print0 2>/dev/null)

  # Additionally, some setups use different prefixes (e.g., share/node/v*/lib/node_modules). Explore generic patterns:
  while IFS= read -r -d '' pkgjson; do
    local nv
    nv="$(node -e 'try{const p=require(process.argv[1]); console.log(`${p.name||""}@${p.version||""}`)}catch(e){process.exit(0)}' "$pkgjson" 2>/dev/null || true)"
    [[ -z "$nv" ]] && continue
    if [[ "$nv" =~ $COMBINED_REGEX ]]; then
      emit "NAVE" "$(dirname "$pkgjson")" "$nv"
    fi
  done < <(find "$installed_dir" -type f -path "*/node_modules/*/package.json" -not -path "*/.cache/*" -print0 2>/dev/null)

  if ! $found; then
    log "ℹ️  No typical global paths found in Nave (lib/node_modules). If you use a different convention, pass --nave-root <PATH>."
  fi
}

# ---------- 5) Suspicious scripts and code ----------
scan_suspicious() {
  $SUSPICIOUS || return 0
  [[ ${#DIRS[@]} -gt 0 ]] || return 0
  log "🕵️  Scanning suspicious scripts/code in: ${DIRS[*]}"
  for dir in "${DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    # 1) package.json scripts
    while IFS= read -r -d '' pkg; do
      # Extract scripts (key and value) using node for robust JSON parsing
      while IFS= read -r line; do
        # line format: key\tvalue
        key="${line%%$'\t'*}"; val="${line#*$'\t'}"
        if echo "$val" | grep -E -qi "$SUSP_SCRIPT_RE"; then
          emit "SCRIPTS" "$pkg" "${key}=${val:0:180}"
        fi
        if echo "$val" | grep -E -qi "$SUSP_GLOBALS_RE"; then
          emit "SCRIPTS" "$pkg" "${key}=${val:0:180} (suspicious global)"
        fi
        if echo "$val" | grep -E -qi "$SUSP_TOOLS_RE"; then
          emit "SCRIPTS" "$pkg" "${key}=${val:0:180} (trufflehog ref)"
        fi
        if echo "$val" | grep -qi "$SUSP_ETH"; then
          emit "SCRIPTS" "$pkg" "${key}=${val:0:180} (eth addr)"
        fi
      done < <(node -e 'try{const p=require(process.argv[1]);const s=p.scripts||{};for(const [k,v] of Object.entries(s)){console.log(`${k}\t${String(v)}`)}}catch(e){}' "$pkg" 2>/dev/null)
    done < <(find "$dir" -type f -name package.json -not -path "*/node_modules/*" -print0 2>/dev/null)

    # 2) Code files: search selected extensions by default; if --suspicious-all, search all text files
    if $SUSPICIOUS_ALL; then
      find_expr=( -type f ! -path "*/node_modules/*" ! -path "*/.git/*" ! -name "*.lock" )
    else
      find_expr=( -type f \( -name "*.js" -o -name "*.ts" -o -name "*.mjs" -o -name "*.cjs" -o -name "*.jsx" -o -name "*.tsx" -o -name "*.sh" -o -name "*.bash" -o -name "*Dockerfile*" -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" \) ! -path "*/node_modules/*" ! -path "*/.git/*" )
    fi
    while IFS= read -r -d '' f; do
      # skip likely binary
      if file -b --mime "$f" 2>/dev/null | grep -qE 'charset=(binary|unknown)'; then continue; fi
      if grep -E -Hn "$SUSP_GLOBALS_RE" "$f" >/dev/null 2>&1; then
        while IFS= read -r line; do emit "CODE" "$f" "$line"; done < <(grep -E -n "$SUSP_GLOBALS_RE" "$f" | cut -c -200)
      fi
      if grep -E -Hn "$SUSP_TOOLS_RE" "$f" >/dev/null 2>&1; then
        while IFS= read -r line; do emit "CODE" "$f" "$line"; done < <(grep -E -n "$SUSP_TOOLS_RE" "$f" | cut -c -200)
      fi
      if grep -Hn "$SUSP_ETH" "$f" >/dev/null 2>&1; then
        while IFS= read -r line; do emit "CODE" "$f" "$line"; done < <(grep -n "$SUSP_ETH" "$f" | cut -c -200)
      fi
    done < <(find "$dir" "${find_expr[@]}" -print0 2>/dev/null)
  done
}

# ---------- run ----------
scan_dirs
scan_global
scan_nvm
scan_nave
scan_suspicious

log "✅ Scan finished."
if [[ -n "$OUTFILE" ]]; then
  log "📝 Report saved to: $OUTFILE"
fi

