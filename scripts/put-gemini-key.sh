#!/usr/bin/env bash
# Кладёт ключ Gemini в SSM Parameter Store как SecureString.
# Ключ вводится скрыто и не попадает ни в историю shell, ни в Terraform state.
#   ./scripts/put-gemini-key.sh            # регион us-east-1
#   AWS_REGION=eu-central-1 ./scripts/put-gemini-key.sh
set -euo pipefail

NAME="${PARAM_NAME:-/fct-adgen/gemini-api-key}"
REGION="${AWS_REGION:-us-east-1}"

read -r -s -p "Вставьте ключ Gemini и нажмите Enter: " KEY
echo
[ -n "$KEY" ] || { echo "Пустой ключ"; exit 1; }

aws ssm put-parameter \
  --region "$REGION" \
  --name "$NAME" \
  --type SecureString \
  --value "$KEY" \
  --overwrite \
  --description "Gemini API key for the ad creative generator" >/dev/null

unset KEY
echo "Готово: $NAME ($REGION)"
aws ssm describe-parameters --region "$REGION" \
  --parameter-filters "Key=Name,Values=$NAME" \
  --query 'Parameters[0].[Name,Type,LastModifiedDate]' --output text
