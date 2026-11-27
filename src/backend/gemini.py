"""Вызов Gemini API через REST без внешних библиотек.

Ключ берётся из SSM Parameter Store (SecureString) один раз на «холодный»
старт и кэшируется в памяти контейнера Lambda.
"""

import json
import logging
import os
import socket
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger()

API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
TIMEOUT_MESSAGE = "Модель не успела ответить за отведённое время. Попробуйте ещё раз или уменьшите количество сценариев."

# Структурированный ответ: модель обязана вернуть JSON ровно такого вида
RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "variants": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "title": {"type": "STRING"},
                    "script": {"type": "STRING"},
                },
                "required": ["title", "script"],
                "propertyOrdering": ["title", "script"],
            },
        }
    },
    "required": ["variants"],
}

_api_key = None


class GeminiError(Exception):
    """status — какой HTTP-код отдать клиенту, user_message — что показать в интерфейсе."""

    def __init__(self, status, user_message, detail=""):
        super().__init__(user_message)
        self.status = status
        self.user_message = user_message
        self.detail = detail


@dataclass
class GeminiResult:
    variants: list
    model: str
    usage: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Ключ
# ---------------------------------------------------------------------------
def get_api_key():
    global _api_key
    if _api_key:
        return _api_key

    param_name = os.environ.get("GEMINI_PARAM_NAME", "")
    if param_name:
        ssm = boto3.client("ssm", config=Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 2}))
        try:
            value = ssm.get_parameter(Name=param_name, WithDecryption=True)["Parameter"]["Value"]
        except ClientError as err:
            code = err.response.get("Error", {}).get("Code", "")
            if code == "ParameterNotFound":
                raise GeminiError(
                    500,
                    f"Ключ Gemini не найден в Parameter Store ({param_name}). Его должен добавить владелец аккаунта.",
                    code,
                ) from err
            raise GeminiError(500, "Не удалось прочитать ключ Gemini из Parameter Store.", code) from err
        except BotoCoreError as err:
            # Чаще всего: Lambda в VPC, а NAT-инстанс не работает
            raise GeminiError(
                502,
                "Нет связи с Parameter Store. Проверьте NAT-инстанс и маршрут приватной подсети.",
                str(err),
            ) from err
    else:
        # Только для локального запуска и тестов
        value = os.environ.get("GEMINI_API_KEY", "")

    value = (value or "").strip()
    if not value:
        raise GeminiError(500, "Ключ Gemini не настроен.")
    _api_key = value
    return _api_key


# ---------------------------------------------------------------------------
# Запрос
# ---------------------------------------------------------------------------
def build_request(system_prompt, user_prompt, thinking_level=None):
    generation_config = {
        "responseMimeType": "application/json",
        "responseSchema": RESPONSE_SCHEMA,
        "maxOutputTokens": 8192,
    }
    if thinking_level:
        generation_config["thinkingConfig"] = {"thinkingLevel": thinking_level}

    return {
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
        "generationConfig": generation_config,
    }


def generate(system_prompt, user_prompt, timeout_s, model=None, thinking_level=None):
    model = model or os.environ.get("GEMINI_MODEL", "gemini-3.8-flash")
    if thinking_level is None:
        thinking_level = os.environ.get("GEMINI_THINKING_LEVEL", "low")

    key = get_api_key()
    deadline = time.monotonic() + timeout_s

    payload = build_request(system_prompt, user_prompt, thinking_level)
    status, body = _post(model, key, payload, deadline - time.monotonic())

    # Если модель не поддерживает thinkingConfig — повторяем без него
    if status == 400 and thinking_level and "thinking" in body.lower():
        logger.warning("Model %s rejected thinkingConfig, retrying without it", model)
        payload = build_request(system_prompt, user_prompt, None)
        status, body = _post(model, key, payload, deadline - time.monotonic())

    if status != 200:
        raise _map_http_error(status, body, model)
    return parse_response(body, model)


def _post(model, key, payload, timeout):
    if timeout < 1:
        raise GeminiError(504, TIMEOUT_MESSAGE, "no time left")

    req = urllib.request.Request(
        f"{API_BASE}/{model}:generateContent",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "x-goog-api-key": key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode("utf-8", "replace")
    except (socket.timeout, TimeoutError) as err:
        raise GeminiError(504, TIMEOUT_MESSAGE, "timeout") from err
    except urllib.error.URLError as err:
        if isinstance(err.reason, (socket.timeout, TimeoutError)):
            raise GeminiError(504, TIMEOUT_MESSAGE, "timeout") from err
        raise GeminiError(
            502,
            "Не удалось подключиться к Gemini. Проверьте выход в интернет из VPC (NAT-инстанс).",
            str(err.reason),
        ) from err


def _map_http_error(status, body, model):
    detail = f"HTTP {status}: {body[:800]}"
    text = body.lower()

    if "api key not valid" in text or "api_key_invalid" in text or status == 401:
        return GeminiError(500, "Ключ Gemini недействителен. Обновите его в Parameter Store.", detail)
    if "location is not supported" in text:
        return GeminiError(502, "Gemini API недоступен из региона, где работает сервис.", detail)
    if status == 403:
        return GeminiError(500, "Нет доступа к Gemini API с этим ключом.", detail)
    if status == 404:
        return GeminiError(500, f"Модель {model} не найдена. Проверьте переменную gemini_model.", detail)
    if status == 429:
        return GeminiError(429, "Лимит запросов к Gemini исчерпан. Подождите минуту и повторите.", detail)
    if status == 400:
        return GeminiError(502, "Модель отклонила запрос. Подробности в логах.", detail)
    return GeminiError(502, "Gemini временно недоступен. Попробуйте ещё раз через минуту.", detail)


# ---------------------------------------------------------------------------
# Разбор ответа
# ---------------------------------------------------------------------------
BLOCKED_REASONS = {"SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY"}


def parse_response(body, model):
    try:
        data = json.loads(body)
    except json.JSONDecodeError as err:
        raise GeminiError(502, "Gemini вернул некорректный ответ.", body[:500]) from err

    candidates = data.get("candidates") or []
    if not candidates:
        block = (data.get("promptFeedback") or {}).get("blockReason")
        if block:
            raise GeminiError(422, "Модель отказалась работать с этим брифом (фильтр безопасности). Переформулируйте бриф.", block)
        raise GeminiError(502, "Модель вернула пустой ответ. Попробуйте ещё раз.", body[:500])

    candidate = candidates[0]
    finish = candidate.get("finishReason", "")
    parts = (candidate.get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in parts if not p.get("thought"))

    if finish in BLOCKED_REASONS:
        raise GeminiError(422, "Ответ модели заблокирован фильтром безопасности. Переформулируйте бриф.", finish)
    if finish == "MAX_TOKENS":
        raise GeminiError(502, "Ответ модели обрезан по длине. Уменьшите количество сценариев.", finish)

    obj = _loads_lenient(text)
    if isinstance(obj, dict):
        variants = obj.get("variants")
    elif isinstance(obj, list):
        variants = obj
    else:
        variants = None
    if not isinstance(variants, list):
        raise GeminiError(502, "Модель вернула ответ в неожиданном формате. Попробуйте ещё раз.", text[:500])

    return GeminiResult(
        variants=variants,
        model=data.get("modelVersion") or model,
        usage=data.get("usageMetadata") or {},
    )


def _loads_lenient(text):
    text = (text or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None
