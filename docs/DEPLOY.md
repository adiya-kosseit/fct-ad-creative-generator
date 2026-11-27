# Развёртывание

## Структура

```
terraform/
  bootstrap/        один раз: S3 для state, DynamoDB для блокировки, IAM команды (локальный state)
  envs/dev/         приложение целиком (remote state в S3)
  modules/
    network/        VPC, 2 публичные + 2 приватные подсети, SG, NAT-инстанс, VPC endpoints
    iam/            роль Lambda с минимальными правами
    storage/        DynamoDB (история) + S3 (архив генераций)
    lambda/         функция бэкенда
    api/            API Gateway HTTP API, CORS, троттлинг, access-логи
    frontend/       S3 + CloudFront (или запасной S3 website)
    monitoring/     SNS, алармы, дашборд
    team-access/    IAM-группы и пользователи команды
src/
  backend/          Lambda на Python (handler, gemini, storage, prompts, system_prompt.txt)
  frontend/         index.html
scripts/            put-gemini-key.sh, smoke-test.sh
tests/              тесты бэкенда (pytest + moto)
```

## Что нужно на компьютере

1. Terraform 1.6 или новее: `terraform -version`
2. AWS CLI v2, настроенный под админ‑пользователя (не root): `aws sts get-caller-identity`
3. Для тестов: Python 3.11+

Если что‑то из этого не готово, сначала пройдите [OWNER_CHECKLIST.md](OWNER_CHECKLIST.md), пункт 1.

## Шаг 1. Ключ Gemini

```bash
./scripts/put-gemini-key.sh
```

Или через консоль, см. OWNER_CHECKLIST.md, пункт 2. Делается один раз: `destroy` параметр не удаляет.

## Шаг 2. Bootstrap (один раз)

```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output -raw backend_hcl > ../envs/dev/backend.hcl
```

Создаются: бакет `fct-adgen-tfstate-<номер аккаунта>` (версионирование, шифрование, закрыт от публичного доступа, только HTTPS), таблица `fct-adgen-tf-lock`, три IAM‑группы и пользователи `dayana`, `raushan`, `arailym`.

Локальный `terraform.tfstate` из этой папки **не коммитить** (он в .gitignore), но и не удалять: храните копию у себя.

## Шаг 3. Приложение

```bash
cd ../envs/dev
cp terraform.tfvars.example terraform.tfvars     # вписать alert_email
terraform init -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

Первый `apply` идёт 5–15 минут, дольше всего создаётся CloudFront. В конце:

```
app_url  = "https://dxxxxxxxx.cloudfront.net"   ← публичный адрес для демо
api_url  = "https://xxxx.execute-api.us-east-1.amazonaws.com"
```

Файл `.terraform.lock.hcl`, который появится после `init`, **закоммитить**: он фиксирует версии провайдеров для всей команды.

Перед каждым коммитом Terraform‑кода: `terraform fmt -recursive terraform` из корня репозитория. CI проверяет форматирование (`fmt -check`) и `validate` для обоих корней, плюс гоняет тесты бэкенда.

## Шаг 4. Проверка

```bash
cd ../../..
./scripts/smoke-test.sh
```

Скрипт проверяет сайт, config.js, `GET /history`, валидацию и реальный вызов Gemini. Потом открыть `app_url` в браузере и сгенерировать сценарий руками.

## Обновления

| Что поменялось | Что делать |
|---|---|
| код в `src/backend/` | `terraform apply` в `envs/dev`: zip пересоберётся, Lambda обновится |
| `src/frontend/index.html` | `terraform apply`; кэш CloudFront для index.html — 1 секунда, сброс не нужен |
| `system_prompt.txt` | то же, это часть кода Lambda |
| модель Gemini | `gemini_model` в terraform.tfvars → `apply` |

## Проверка destroy → apply

Обязательный пункт сдачи: инфраструктура поднимается с нуля одной командой.

```bash
cd terraform/envs/dev
terraform destroy          # 10–40 минут, см. ниже
terraform apply            # заново
cd ../../.. && ./scripts/smoke-test.sh
```

Что остаётся после destroy: state‑бакет, таблица блокировок, IAM команды (bootstrap) и ключ Gemini в SSM. Что теряется: история запросов в DynamoDB и архив в S3. Так и задумано: окружение одноразовое.

Почему destroy долгий:

1. CloudFront сначала отключается, потом удаляется (5–15 минут).
2. Lambda в VPC держит сетевые интерфейсы ещё до 20–40 минут после удаления функции. Пока они не освобождены, AWS не даёт удалить security group и подсети. Terraform ждёт сам, **не прерывайте его Ctrl+C**.

Зафиксируйте результат для документации: время destroy, время apply, вывод smoke‑test (скриншот).

## Экономия между демо

Единственное, что стоит денег вне free tier, — NAT‑инстанс и его публичный IPv4 (≈ $0,4 в сутки, если кредиты и free tier не покрывают). Когда приложение не нужно неделю и больше, делайте `terraform destroy` и поднимайте за день до демо.

## Запасные режимы

| Проблема | Переменная в terraform.tfvars |
|---|---|
| `Your account must be verified before you can add new CloudFront resources` | `frontend_mode = "s3_website"` → сайт по HTTP прямо из S3 |
| NAT‑инстанс не поднялся, а демо через час | `lambda_in_vpc = false` → Lambda без VPC, NAT не создаётся |

После правки: `terraform apply`. Обе настройки потом можно вернуть.
