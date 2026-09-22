"""Garmin Connect bridge for NotchMate (python-garminconnect).

    garmin_sync.py login  <tokens_dir>                 interactive: email/password or sign-in in the browser
    garmin_sync.py fetch  <tokens_dir> <out_dir> [days] saves raw JSON per day, prints one status line
    garmin_sync.py logout <tokens_dir>

The password is never stored: only Garmin's OAuth tokens land in <tokens_dir> (user-only permissions).
The app parses the raw JSON itself, so this script stays dumb and easy to update when Garmin changes things.
"""
import datetime as dt
import re
import subprocess
import getpass
import json
import os
import shutil
import sys
import time
from pathlib import Path


def status(**kw):
    print(json.dumps(kw, ensure_ascii=False), flush=True)


def classify(e):
    """auth | ratelimit | blocked | network — from the exception chain (garminconnect wraps causes)."""
    text = ""
    while e is not None:
        text += f" {type(e).__name__}: {e}"
        e = e.__cause__ or e.__context__
    low = text.lower()
    if "429" in low or "toomanyrequests" in low or "rate limit" in low:
        return "ratelimit", text.strip()
    if "captcha" in low or "cloudflare" in low or "bot challenge" in low:
        return "blocked", text.strip()
    if "401" in low or "authentication" in low or "credentials" in low or "password" in low:
        return "auth", text.strip()
    return "network", text.strip()


HINTS = {
    "ratelimit": "Garmin временно ограничил вход с этого IP (слишком много попыток).\n"
                 "  Подождите 1–2 часа и не повторяйте вход до этого — каждая попытка продлевает блок.\n"
                 "  Быстрее: подключитесь через другую сеть (раздача с телефона) и повторите.",
    "blocked": "Garmin показал проверку «не робот» (CAPTCHA/Cloudflare) — обычно это следствие того же ограничения.\n"
               "  Подождите 1–2 часа или попробуйте из другой сети.",
    "auth": "Неверный email или пароль (или код подтверждения).",
    "network": "Garmin Connect не ответил. Проверьте интернет и попробуйте позже.",
}


def private_dir(p):
    p = Path(p).expanduser()
    p.mkdir(parents=True, exist_ok=True)
    os.chmod(p, 0o700)
    return p


# The browser flow asks SSO for a ticket addressed to the mobile app's service URL: that page doesn't
# consume the ticket, so it can be copied from the address bar and exchanged for the app's tokens.
BROWSER_CLIENT = "GCM_IOS_DARK"
BROWSER_SERVICE = "https://mobile.integration.garmin.com/gcm/ios"


def save_profile(api, tokens):
    for f in tokens.iterdir():
        os.chmod(f, 0o600)
    name = ""
    try:
        name = api.get_full_name() or ""
    except Exception:
        pass
    (tokens / "profile.json").write_text(json.dumps({"fullName": name}, ensure_ascii=False))
    print(f"\n✓ Готово{', ' + name if name else ''}! Окно можно закрыть — NotchMate сам загрузит данные.")


def browser_login(tokens):
    """The user signs in on Garmin's own page (CAPTCHA, MFA and all) and pastes the final address."""
    from garminconnect import Garmin
    from urllib.parse import urlencode
    url = "https://sso.garmin.com/portal/sso/en-US/sign-in?" + urlencode({"clientId": BROWSER_CLIENT, "service": BROWSER_SERVICE})
    print("Открываю страницу входа Garmin в браузере.")
    print("  1. Войдите как обычно (если попросят — пройдите проверку «я не робот» и введите код).")
    print("  2. После входа браузер перейдёт на адрес с «ticket=ST-…» (страница может быть пустой или с ошибкой — это нормально).")
    print("  3. Скопируйте адрес из адресной строки целиком и вставьте сюда. Билет действует пару минут.\n")
    print(f"  Если браузер не открылся: {url}\n")
    subprocess.run(["open", url], check=False)
    pasted = input("Адрес после входа: ").strip()
    m = re.search(r"(ST-[A-Za-z0-9._-]+)", pasted)
    if not m:
        print("\n✗ В адресе нет «ticket=ST-…». Похоже, вход не завершился — попробуйте ещё раз.")
        sys.exit(1)
    api = Garmin()
    try:
        api.client._exchange_service_ticket(m.group(1), service_url=BROWSER_SERVICE)
        api.client.dump(str(tokens))
        api.login(str(tokens))   # loads the profile with the fresh token
    except Exception as e:
        kind, detail = classify(e)
        hint = HINTS[kind] if kind in ("ratelimit", "network") else "Билет не подошёл — он одноразовый и живёт пару минут. Войдите ещё раз и вставьте адрес сразу."
        print(f"\n✗ Не получилось. {hint}\n\n  Подробности: {detail[:400]}")
        sys.exit(1)
    save_profile(api, tokens)


def login(tokens):
    from garminconnect import Garmin
    tokens = private_dir(tokens)
    print("Вход в Garmin Connect. Пароль не сохраняется — только токен доступа на этом Mac.\n")
    print("  1 — email и пароль здесь")
    print("  2 — через браузер (если Garmin просит проверку «я не робот» или ограничил вход)\n")
    if input("Выберите [1]: ").strip() == "2":
        print()
        browser_login(tokens)
        return
    email = input("Email Garmin: ").strip()
    password = getpass.getpass("Пароль (символы не отображаются): ")
    # One attempt per strategy: retries only deepen Garmin's IP rate limit.
    api = Garmin(email, password, prompt_mfa=lambda: input("Код подтверждения (MFA): ").strip(), retry_attempts=1)
    try:
        api.login(str(tokens))
    except Exception as e:
        kind, detail = classify(e)
        print(f"\n✗ Не получилось войти. {HINTS[kind]}\n\n  Подробности: {detail[:400]}")
        if kind in ("ratelimit", "blocked") and input("\nВойти через браузер и пройти проверку самому? [Y/n]: ").strip().lower() in ("", "y", "д", "да", "yes"):
            print()
            browser_login(tokens)
            return
        sys.exit(1)
    try:
        api.client.dump(str(tokens))
    except Exception:
        pass
    save_profile(api, tokens)


def fetch(tokens, out, days):
    from garminconnect import Garmin
    out = private_dir(out)
    tokens = Path(tokens).expanduser()
    if not tokens.exists():
        status(ok=False, error="auth", message="Нет токена — войдите в Garmin Connect")
        return 2
    api = Garmin()
    try:
        api.login(str(tokens))
    except Exception as e:
        kind, detail = classify(e)
        status(ok=False, error=kind, message=detail[:300])
        return 2

    today = dt.date.today()
    fetched, failed = [], []
    for back in range(days):
        day = today - dt.timedelta(days=back)
        path = out / f"garmin-{day.isoformat()}.json"
        # Past days don't change once synced; today and yesterday (sleep, late sync) are refreshed.
        if path.exists() and back >= 2:
            continue
        d = day.isoformat()
        raw = {"date": d, "fetchedAt": dt.datetime.now().astimezone().isoformat()}
        calls = {
            "summary": lambda: api.get_user_summary(d),
            "stress": lambda: api.get_stress_data(d),
            "heartRate": lambda: api.get_heart_rates(d),
            "sleep": lambda: api.get_sleep_data(d),
            "hrv": lambda: api.get_hrv_data(d),
            "readiness": lambda: api.get_training_readiness(d),
            "respiration": lambda: api.get_respiration_data(d),
        }
        errors = 0
        for key, call in calls.items():
            try:
                raw[key] = call()
            except Exception as e:
                raw[key] = None
                errors += 1
                if "401" in str(e) or "Authentication" in type(e).__name__:
                    status(ok=False, error="auth", message=str(e)[:300])
                    return 2
            time.sleep(0.25)
        if errors == len(calls):
            failed.append(d)
            continue
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(raw, ensure_ascii=False))
        tmp.replace(path)
        fetched.append(d)
    try:
        api.client.dump(str(tokens))
    except Exception:
        pass
    status(ok=True, fetched=fetched, failed=failed)
    return 0


def logout(tokens):
    shutil.rmtree(Path(tokens).expanduser(), ignore_errors=True)
    status(ok=True)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    cmd, tokens = sys.argv[1], sys.argv[2]
    try:
        if cmd == "login":
            login(tokens)
        elif cmd == "fetch":
            sys.exit(fetch(tokens, sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 14))
        elif cmd == "logout":
            logout(tokens)
        else:
            print(__doc__)
            sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        if cmd == "login":
            print(f"\n✗ Не получилось войти: {e}")
            sys.exit(1)
        status(ok=False, error="crash", message=f"{type(e).__name__}: {e}"[:300])
        sys.exit(3)
