"""Lambda-бэкенд генератора сценариев видеокреативов.

Маршруты (контракт с фронтендом):
    POST /generate              -> {requestId, createdAt, model, variants: [{title, script}]}
    GET  /history?limit=20      -> {items: [{requestId, client, niche, createdAt, count, variants, ...}]}
    PUT  /history/{requestId}   -> {ok, requestId, updatedAt}
Ошибки всегда в виде {"error": {"message": "..."}} с кодом 4xx/5xx.
"""

import base64
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import gemini
import prompts
import storage

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MAX_SCENARIOS = int(os.environ.get("MAX_SCENARIOS", "4"))
APP_ENV = os.environ.get("APP_ENV", "dev")
METRICS_NAMESPACE = os.environ.get("METRICS_NAMESPACE", "AdCreativeGenerator")

MAX_BODY_BYTES = 200_000
MAX_TITLE = 200
MAX_SCRIPT = 12_000
REQUEST_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# Поле брифа -> (подпись для сообщений об ошибке, максимальная длина)
TEXT_FIELDS = {
    "client": ("Клиент / бренд", 200),
    "niche": ("Ниша", 200),
    "product": ("Продукт или услуга", 500),
    "goal": ("Цель рекламы", 200),
    "lang": ("Язык", 30),
    "audience": ("Целевая аудитория и боли", 3000),
    "offer": ("Оффер и уникальность", 3000),
    "price": ("Цена, акция, условия", 500),
    "objections": ("Возражения клиентов", 3000),
    "task": ("Задача креатива", 100),
    "avoid": ("Не повторять", 2000),
    "fullText": ("Полный текст брифа", 30_000),
}


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    route = event.get("routeKey", "")
    started = time.monotonic()

    try:
        if route == "POST /generate":
            status, body = handle_generate(event, context)
        elif route == "GET /history":
            status, body = handle_history_list(event)
        elif route == "PUT /history/{requestId}":
            status, body = handle_history_update(event)
        else:
            raise ApiError(404, "Маршрут не найден")
    except ApiError as err:
        status, body = err.status, {"error": {"message": err.message}}
    except Exception:  # noqa: BLE001 — последняя линия обороны
        logger.exception("Unhandled error on %s", route)
        status, body = 500, {"error": {"message": "Внутренняя ошибка сервиса. Подробности в логах CloudWatch."}}

    log_event(
        "request",
        route=route,
        status=status,
        durationMs=int((time.monotonic() - started) * 1000),
        awsRequestId=getattr(context, "aws_request_id", None),
    )
    return response(status, body)


# ---------------------------------------------------------------------------
# POST /generate
# ---------------------------------------------------------------------------
def handle_generate(event, context):
    brief = validate_brief(parse_body(event))
    request_id = str(uuid.uuid4())
    created_at = now_iso()

    # Сколько времени осталось у Lambda; оставляем запас на запись в DynamoDB/S3
    remaining_ms = context.get_remaining_time_in_millis() if context else 28_000
    gemini_timeout = max(3.0, (remaining_ms - 2_500) / 1000)

    user_prompt = prompts.build_user_prompt(brief)
    t0 = time.monotonic()
    try:
        result = gemini.generate(
            system_prompt=prompts.get_system_prompt(),
            user_prompt=user_prompt,
            timeout_s=gemini_timeout,
        )
    except gemini.GeminiError as err:
        latency = int((time.monotonic() - t0) * 1000)
        emit_metrics(GeminiErrors=1, GeminiLatencyMs=latency)
        log_event("gemini_error", requestId=request_id, status=err.status, detail=err.detail[:500], latencyMs=latency)
        raise ApiError(err.status, err.user_message) from err

    latency = int((time.monotonic() - t0) * 1000)
    variants = normalize_variants(result.variants, brief["count"])
    if not variants:
        emit_metrics(GeminiErrors=1, GeminiLatencyMs=latency)
        raise ApiError(502, "Модель вернула пустой ответ. Попробуйте ещё раз.")

    item = {
        "requestId": request_id,
        "createdAt": created_at,
        "updatedAt": created_at,
        "client": brief["client"],
        "niche": brief["niche"],
        "count": len(variants),
        "variants": variants,
        "brief": brief,
        "model": result.model,
        "latencyMs": latency,
        "edited": False,
    }

    payload = {
        "requestId": request_id,
        "createdAt": created_at,
        "model": result.model,
        "variants": variants,
    }

    try:
        storage.save_generation(item)
    except Exception:  # noqa: BLE001 — сценарии уже готовы, не теряем их из-за истории
        logger.exception("Failed to save generation %s", request_id)
        payload["warning"] = "Сценарии готовы, но не сохранились в историю."

    try:
        storage.archive_generation(
            request_id,
            created_at,
            {**item, "prompt": user_prompt, "usage": result.usage},
        )
    except Exception:  # noqa: BLE001 — архив вторичен
        logger.exception("Failed to archive generation %s", request_id)

    emit_metrics(GeminiErrors=0, GeminiLatencyMs=latency, ScenariosGenerated=len(variants))
    log_event(
        "generated",
        requestId=request_id,
        count=len(variants),
        latencyMs=latency,
        model=result.model,
        promptTokens=result.usage.get("promptTokenCount"),
        outputTokens=result.usage.get("candidatesTokenCount"),
    )
    return 200, payload


def validate_brief(body):
    if not isinstance(body, dict):
        raise ApiError(400, "Ожидался JSON-объект с брифом")

    brief = {}
    for field, (label, limit) in TEXT_FIELDS.items():
        value = body.get(field, "")
        if value is None:
            value = ""
        if not isinstance(value, (str, int, float)) or isinstance(value, bool):
            raise ApiError(400, f"Поле «{label}» должно быть строкой")
        value = str(value).strip()
        if len(value) > limit:
            raise ApiError(400, f"Поле «{label}» слишком длинное: максимум {limit} символов")
        brief[field] = value

    if not brief["client"]:
        raise ApiError(400, "Укажите клиента или бренд")
    brief["lang"] = brief["lang"] or "русский"
    brief["task"] = brief["task"] or "авто"

    brief["formats"] = _string_list(body.get("formats"), "Формат подачи", max_items=10, max_len=60)
    brief["focus"] = _string_list(body.get("focus"), "Фокус", max_items=MAX_SCENARIOS, max_len=300)

    count = body.get("count", 3)
    if isinstance(count, bool):
        raise ApiError(400, "Количество сценариев должно быть числом")
    try:
        count = int(count)
    except (TypeError, ValueError):
        raise ApiError(400, "Количество сценариев должно быть числом") from None
    if not 1 <= count <= MAX_SCENARIOS:
        raise ApiError(400, f"Количество сценариев: от 1 до {MAX_SCENARIOS}")
    brief["count"] = count
    return brief


def _string_list(value, label, max_items, max_len):
    if value in (None, ""):
        return []
    if not isinstance(value, list):
        raise ApiError(400, f"Поле «{label}» должно быть списком")
    result = []
    for v in value:
        if not isinstance(v, str):
            raise ApiError(400, f"Поле «{label}» должно содержать строки")
        v = v.strip()
        if not v:
            continue
        if len(v) > max_len:
            raise ApiError(400, f"Поле «{label}»: значение длиннее {max_len} символов")
        result.append(v)
    if len(result) > max_items:
        raise ApiError(400, f"Поле «{label}»: не больше {max_items} значений")
    return result


def normalize_variants(raw, limit):
    variants = []
    for v in raw or []:
        if isinstance(v, str):
            v = {"title": "", "script": v}
        if not isinstance(v, dict):
            continue
        script = str(v.get("script") or "").strip()
        if not script:
            continue
        variants.append({
            "title": str(v.get("title") or "").strip()[:MAX_TITLE],
            "script": script[:MAX_SCRIPT],
        })
    return variants[:limit]


# ---------------------------------------------------------------------------
# GET /history
# ---------------------------------------------------------------------------
def handle_history_list(event):
    qs = event.get("queryStringParameters") or {}
    raw_limit = qs.get("limit", "20")
    try:
        limit = int(raw_limit)
    except (TypeError, ValueError):
        raise ApiError(400, "Параметр limit должен быть числом") from None
    limit = min(max(limit, 1), 50)

    items = [
        {
            "requestId": it.get("requestId"),
            "client": it.get("client", ""),
            "niche": it.get("niche", ""),
            "createdAt": it.get("createdAt"),
            "updatedAt": it.get("updatedAt"),
            "count": it.get("count", len(it.get("variants") or [])),
            "edited": bool(it.get("edited", False)),
            "variants": it.get("variants") or [],
        }
        for it in storage.list_history(limit)
    ]
    return 200, {"items": items}


# ---------------------------------------------------------------------------
# PUT /history/{requestId}
# ---------------------------------------------------------------------------
def handle_history_update(event):
    request_id = ((event.get("pathParameters") or {}).get("requestId") or "").strip().lower()
    if not REQUEST_ID_RE.match(request_id):
        raise ApiError(400, "Некорректный идентификатор запроса")

    body = parse_body(event)
    variants = body.get("variants") if isinstance(body, dict) else None
    if not isinstance(variants, list) or not 1 <= len(variants) <= MAX_SCENARIOS:
        raise ApiError(400, f"Нужен список variants из 1–{MAX_SCENARIOS} сценариев")

    clean = []
    for v in variants:
        if not isinstance(v, dict) or not isinstance(v.get("script"), str):
            raise ApiError(400, "Каждый сценарий должен содержать текст script")
        script = v["script"].strip()
        title = v.get("title") or ""
        if not isinstance(title, str):
            raise ApiError(400, "Поле title должно быть строкой")
        if not script:
            raise ApiError(400, "Текст сценария не может быть пустым")
        if len(script) > MAX_SCRIPT or len(title) > MAX_TITLE:
            raise ApiError(400, f"Сценарий слишком длинный: максимум {MAX_SCRIPT} символов")
        clean.append({"title": title.strip(), "script": script})

    updated_at = now_iso()
    if not storage.update_variants(request_id, clean, updated_at):
        raise ApiError(404, "Запрос не найден в истории")

    log_event("edited", requestId=request_id, count=len(clean))
    return 200, {"ok": True, "requestId": request_id, "updatedAt": updated_at}


# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------
def parse_body(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(body).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "Не удалось прочитать тело запроса") from None
    if len(body.encode("utf-8")) > MAX_BODY_BYTES:
        raise ApiError(413, "Бриф слишком большой. Сократите полный текст брифа.")
    if not body:
        raise ApiError(400, "Пустое тело запроса")
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        raise ApiError(400, "Тело запроса должно быть в формате JSON") from None


def response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body, ensure_ascii=False, default=_json_default),
    }


def _json_default(obj):
    # DynamoDB возвращает числа как Decimal
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    raise TypeError(f"Not serializable: {type(obj).__name__}")


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def log_event(kind, **fields):
    """Структурированный лог одной строкой JSON — удобно искать в Logs Insights.
    Текст брифа и сценариев в логи не пишем."""
    print(json.dumps({"event": kind, **fields}, ensure_ascii=False, default=str))


def emit_metrics(**metrics):
    """Метрики через CloudWatch Embedded Metric Format: строка JSON в логе
    превращается в метрику без вызова PutMetricData и без лишних IAM-прав."""
    doc = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": METRICS_NAMESPACE,
                "Dimensions": [["Environment"]],
                "Metrics": [
                    {"Name": name, "Unit": "Milliseconds" if name.endswith("Ms") else "Count"}
                    for name in metrics
                ],
            }],
        },
        "Environment": APP_ENV,
        **metrics,
    }
    print(json.dumps(doc))
