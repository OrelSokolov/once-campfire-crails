#!/usr/bin/env bash
# Сборка образа once-campfire-crails:app. Все зависимости — публичные
# git-шарды, ставятся shards install прямо в build-стадии; контекст —
# каталог приложения (.dockerignore отсекает lib/, базы, артефакты).
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"
exec docker build -t once-campfire-crails:app "$APP"
