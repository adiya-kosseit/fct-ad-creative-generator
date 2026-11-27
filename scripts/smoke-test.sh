#!/usr/bin/env bash
# Проверка развёрнутого приложения: сайт отдаётся, API живой, Gemini реально отвечает.
# Запуск из корня репозитория после terraform apply:
#   bash scripts/smoke-test.sh
set -euo pipefail

cd "$(dirname "$0")/../terraform/envs/dev"
API_URL=$(terraform output -raw api_url)
APP_URL=$(terraform output -raw app_url)
cd - >/dev/null

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }

echo "Сайт: $APP_URL"
echo "API:  $API_URL"
echo

code=$(curl -s -o /dev/null -w '%{http_code}' "$APP_URL/")
[ "$code" = "200" ] && ok "index.html отдаётся ($code)" || fail "сайт вернул $code"

curl -s "$APP_URL/config.js" | grep -q "$API_URL" && ok "config.js содержит адрес API" || fail "config.js без адреса API"

code=$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/history?limit=1")
[ "$code" = "200" ] && ok "GET /history ($code)" || fail "GET /history вернул $code"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/generate" \
  -H 'Content-Type: application/json' -d '{"client":""}')
[ "$code" = "400" ] && ok "валидация брифа (пустой клиент -> 400)" || fail "ожидали 400, получили $code"

echo "  ...  POST /generate с реальным вызовом Gemini (до 30 с)"
start=$(date +%s)
resp=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/generate" \
  -H 'Content-Type: application/json' \
  -d '{"client":"Smoke test","niche":"coffee shop","product":"coffee to go","goal":"sales","lang":"\u0440\u0443\u0441\u0441\u043a\u0438\u0439","count":1}')
code=$(echo "$resp" | tail -n1)
body=$(echo "$resp" | sed '$d')
took=$(( $(date +%s) - start ))
if [ "$code" = "200" ]; then
  ok "Gemini ответил за ${took} с"
  echo "       ответ: $(echo "$body" | head -c 400) ..."
else
  echo "$body"
  fail "POST /generate вернул $code"
fi

echo
echo "Всё работает."
