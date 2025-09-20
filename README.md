# Shai-Hulud npm Scanner

A simple, fast Bash script to search for known-compromised npm packages and versions across:

- Project lockfiles (package-lock.json, pnpm-lock.yaml, yarn.lock)
- Globally installed npm packages (npm -g)
- NVM installations
- Nave installations

This repository also includes a ready-to-use IoC list: `iocs-shai-hulud.txt`.

## Why

Use this tool to quickly assess exposure during npm supply-chain incidents (e.g., when specific package@version pairs
are reported as compromised).

## Requirements

- Bash (Linux/macOS)
- For global scan Node.js and npm installed to check global packages or parse package.json in NVM/Nave scans
- Optional: NVM (~/.nvm) and/or Nave (~/.nave) if you want those scopes scanned

## Quick start

1) Clone or copy this folder.
2) Make the script executable:
   chmod +x ./scan-npm.sh
3) Run with the provided indicators of compromise (IoCs):
   ./scan-npm.sh -f iocs-shai-hulud.txt -d /path/to/projects -g --nvm --nave

- Use -d multiple times to scan multiple roots.
- Use -g to include global npm packages.
- Use --nvm to include NVM installations (auto-detects $NVM_DIR or ~/.nvm). You can also specify a path: --nvm=/opt/nvm
- Use --nave to include Nave; defaults to ~/.nave. You can customize with --nave-root PATH

## Usage

Run without arguments to see help:
./scan-npm.sh -h

Key options:

- -t "TERM1,TERM2,..."   Comma-separated list of search terms. Each term should be either a full name@version (
  recommended) or just a package name.
- -f FILE File with one term per line (lines starting with # are treated as comments). Example: iocs-shai-hulud.txt
- -d DIR Directory to scan for lockfiles (can be repeated).
- -g Include npm global (-g) packages.
- --nvm[=PATH]            Include NVM installations. If PATH is omitted, auto-detects $NVM_DIR or ~/.nvm.
- --nave Include Nave installations.
- --nave-root PATH Base directory for Nave (defaults to ~/.nave).
- -o FILE Save results as TSV to FILE in addition to console output.
- -q Quiet logging (reduces non-essential logs).
- -h Show help.

## What gets scanned

- Lockfiles in directories provided via -d: package-lock.json, pnpm-lock.yaml, yarn.lock
- npm global packages: via `npm ls -g --depth=0 --json`
- NVM: any package.json under `$NVM_DIR/versions/node/*/lib/node_modules/*/package.json`
- Nave: any package.json under `~/.nave/installed/*/lib/node_modules/*/package.json` and a few generic
  `*/node_modules/*/package.json` paths under `installed/`

## Output

Console output shows three columns:
SCOPE | LOCATION | MATCH

If you pass -o report.tsv, a TSV with header will be written:
SCOPE LOCATION MATCH

Typical scopes: LOCKFILE, NPM-GLOBAL, NVM, NAVE.

## Indicators file (iocs-shai-hulud.txt)

- One entry per line in the format name@version, for example:
  @ctrl/tinycolor@4.1.1
  koa2-swagger-ui@5.11.2
  ngx-toastr@19.0.2
- Lines starting with # are comments and are ignored.
- You can mix multiple versions of the same package on separate lines.

This repository already includes a curated list from recent public incident reports as of 2025-09-19. Update it as new
information becomes available.

## Examples

- Scan two repos plus global, NVM and Nave using provided IoCs:
  ./scan-npm.sh -f iocs-shai-hulud.txt -d ~/repoA -d ~/repoB -g --nvm --nave

- Provide terms inline and save to a TSV report:
  ./scan-npm.sh -t "@ctrl/tinycolor@4.1.1,ngx-toastr@19.0.2" -d ~/projects -g -o findings.tsv

- Use a custom NVM and Nave path:
  ./scan-npm.sh -t "koa2-swagger-ui@5.11.2" --nvm=/opt/nvm --nave --nave-root "$HOME/.nave"

## Exit codes

- 0 on successful execution (even if no matches found)
- Non-zero if there is an argument/IO error

## Troubleshooting

- npm not found: The global scan requires npm in PATH. Omit -g if not available.
- NVM/Nave not detected: Ensure the base directories exist or pass explicit paths (--nvm=/path, --nave-root /path).
- No matches: Verify the exact package@version pairs in your IoC list. The script matches exact strings in lockfiles and
  derived name@version strings for global scans.

## License

Copyright 2025 Dhaby Xiloj

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
