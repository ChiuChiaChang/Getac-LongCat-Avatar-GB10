#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="${1:-ChiuChiaChang/Getac-LongCat-Avatar-GB10}"
command -v git >/dev/null || { echo 'Git is required.' >&2; exit 1; }
if ! command -v gh >/dev/null; then
  echo 'GitHub CLI (gh) is required for automatic repository creation.' >&2
  echo 'Install gh and run: gh auth login' >&2
  echo "Or manually create a private GitHub repository named ${REPO} first." >&2
  exit 1
fi
gh auth status >/dev/null || { echo 'Please run: gh auth login' >&2; exit 1; }
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  echo "Creating PRIVATE repository: $REPO"
  gh repo create "$REPO" --private --description 'Getac LongCat Avatar 1.5 GB10 one-click Docker deployment'
fi
[[ -d .git ]] || git init -b main
if ! git config user.name >/dev/null; then echo 'Set git config user.name first.' >&2; exit 1; fi
if ! git config user.email >/dev/null; then echo 'Set git config user.email first.' >&2; exit 1; fi
git add README.md LICENSE-THIRD-PARTY.md .gitignore .env.example docker-compose.yml install.sh test.sh stop.sh logs.sh publish-github.sh gateway scripts tests
git diff --cached --quiet || git commit -m 'Getac LongCat Avatar GB10 installer v1.0.0.0'
if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "https://github.com/$REPO.git"; else git remote add origin "https://github.com/$REPO.git"; fi
git branch -M main
git push -u origin main
echo "Repository published: https://github.com/$REPO"
