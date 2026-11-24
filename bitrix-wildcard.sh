#!/usr/bin/env bash
# BitrixVM 9 / Rocky Linux 9. Run as root: bash bitrix-wildcard.sh
# Cloudflare: API token, Zone / DNS / Edit, restricted to this domain.
# Covers example.com and *.example.com (one subdomain level).
# Select the nginx file containing exactly one certificate/key pair.
# All virtual hosts using that file will receive the new certificate.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Запустите от root.'
[[ -t 0 ]] || fail 'Запустите в интерактивном SSH-терминале.'
source /etc/os-release
[[ $ID == rocky && $VERSION_ID == 9* ]] || fail 'Нужна Rocky Linux 9.'
exec 9>/run/lock/bitrix-wildcard.lock
flock -n 9 || fail 'Другой экземпляр скрипта уже работает.'
command -v nginx >/dev/null || fail 'Nginx не найден.'
nginx -t || fail 'Сначала исправьте существующие ошибки Nginx.'

read -r -p 'Домен без https:// и без * (пример site.ru): ' domain
domain=${domain,,}
[[ ${#domain} -le 253 && $domain == *.* ]] || fail 'Некорректный домен.'
IFS=. read -r -a labels <<< "$domain"
for label in "${labels[@]}"; do
  [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail 'Используйте обычный домен или punycode.'
done
[[ $domain != *. ]] || fail 'Уберите точку в конце домена.'
read -r -p 'Email для аккаунта Let’s Encrypt: ' email
[[ $email == ?*@?*.?* && $email != *[[:space:]]* ]] || fail 'Некорректный email.'
read -r -p 'Файл с ssl_certificate [/etc/nginx/bx/conf/ssl.conf]: ' conf
conf=${conf:-/etc/nginx/bx/conf/ssl.conf}
[[ $conf == /etc/nginx/* && -f $conf ]] || fail 'Укажите существующий файл внутри /etc/nginx/.'
conf=$(readlink -f -- "$conf")
[[ $conf == /etc/nginx/* ]] || fail 'Файл должен находиться внутри /etc/nginx/.'

work=$(mktemp -d /root/bitrix-wildcard.XXXXXXXX)
rollback=0
backup=''
cleanup() {
  result=$?
  trap - EXIT INT TERM
  if [[ $rollback == 1 ]]; then
    printf 'Возвращаю конфигурацию из %s\n' "$backup" >&2
    if cp --preserve=all -- "$backup" "$conf"; then
      nginx -t && systemctl reload nginx || true
    else
      printf 'Не удалось восстановить конфиг! Резервная копия: %s\n' "$backup" >&2
    fi
  fi
  rm -rf -- "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
nginx -T >"$work/nginx.txt" 2>"$work/nginx.err"
grep -Fqx "# configuration file $conf:" "$work/nginx.txt" || fail 'Этот путь не найден в активной конфигурации nginx -T. Укажите путь из вывода nginx -T.'

printf '\nВыбран файл: %s\n' "$conf"
grep -nE '^[[:space:]]*ssl_(certificate|certificate_key|trusted_certificate)[[:space:]]' "$conf" || true
printf '\nСертификат: %s и *.%s\n' "$domain" "$domain"
printf 'Изменение затронет ВСЕ сайты, использующие этот файл.\n'
printf 'Если они принадлежат другим доменам, остановитесь и выберите отдельный конфиг.\n'
printf 'Продолжая, вы соглашаетесь с условиями Let’s Encrypt: https://letsencrypt.org/repository/\n'
read -r -p 'Подключить сертификат в этом файле? Введите YES: ' answer
[[ $answer == YES ]] || fail 'Отменено без изменения конфигурации.'

dnf install -y epel-release
dnf install -y certbot python3-certbot-dns-cloudflare python3
systemctl cat certbot-renew.timer >/dev/null || fail 'Пакет не установил certbot-renew.timer. Автопродление не настроено.'

# Prepare a candidate; preserve other directives, comments and file metadata.
cp --preserve=all -- "$conf" "$work/candidate"
python3 - "$work/candidate" "$domain" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
base = '/etc/letsencrypt/live/' + sys.argv[2]
text = p.read_text()
for name, filename, required in (
    ('ssl_certificate', 'fullchain.pem', True),
    ('ssl_certificate_key', 'privkey.pem', True),
    ('ssl_trusted_certificate', 'chain.pem', False),
):
    pattern = re.compile(r'(?m)^([ \t]*' + name + r'[ \t]+)[^;\r\n]+;')
    count = len(pattern.findall(text))
    if (required and count != 1) or count > 1:
        raise SystemExit('Остановка: неоднозначная конфигурация ' + name + '. Нужна одна пара сертификат/ключ в выбранном файле.')
    text = pattern.sub(lambda m: m[1] + base + '/' + filename + ';', text)
p.write_text(text)
PY
original_hash=$(sha256sum -- "$conf")

install -d -m 700 /etc/letsencrypt/cloudflare
credentials="/etc/letsencrypt/cloudflare/$domain.ini"
[[ ! -L $credentials ]] || fail 'Файл токена не должен быть символической ссылкой.'
if [[ ! -f $credentials ]]; then
  read -r -s -p 'Cloudflare API Token (ввод скрыт): ' cf_token
  printf '\n'
  [[ $cf_token =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Некорректный формат токена.'
  printf 'dns_cloudflare_api_token = %s\n' "$cf_token" >"$credentials"
  unset cf_token
else
  printf 'Используется сохранённый токен: %s\n' "$credentials"
fi
chown root:root "$credentials"
chmod 600 "$credentials"

certbot certonly --non-interactive --agree-tos --email "$email" \
  --cert-name "$domain" --keep-until-expiring \
  --dns-cloudflare --dns-cloudflare-credentials "$credentials" \
  --dns-cloudflare-propagation-seconds 60 \
  -d "$domain" -d "*.$domain"

[[ -s /etc/letsencrypt/live/$domain/fullchain.pem && -s /etc/letsencrypt/live/$domain/privkey.pem ]] || fail 'Файлы сертификата не найдены.'

# Domain-specific hook: nginx uses live symlinks, so no certificate copying.
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
hook="/etc/letsencrypt/renewal-hooks/deploy/bitrix-$domain.sh"
cat >"$work/hook" <<EOF
#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "\${RENEWED_LINEAGE:-}" = '/etc/letsencrypt/live/$domain' ] || exit 0
nginx -t
systemctl reload nginx
EOF
install -m 700 "$work/hook" "$hook"

printf '\nПроверка тестового продления (может занять несколько минут)...\n'
certbot renew --cert-name "$domain" --dry-run
[[ $(sha256sum -- "$conf") == "$original_hash" ]] || fail 'Конфигурация изменилась во время работы. Запустите скрипт снова.'

install -d -m 700 /root/bitrix-ssl-backups
backup=$(mktemp /root/bitrix-ssl-backups/ssl.XXXXXXXX.conf)
cp --preserve=all -- "$conf" "$backup"
rollback=1
cp --preserve=all -- "$work/candidate" "$conf"
nginx -t || fail 'Проверка Nginx не прошла.'
systemctl reload nginx || fail 'Nginx не смог применить конфигурацию.'
systemctl enable --now certbot-renew.timer
systemctl is-active --quiet certbot-renew.timer || fail 'Таймер продления не запущен.'
rollback=0

printf '\nГОТОВО: %s и *.%s\n' "$domain" "$domain"
printf 'Конфиг: %s\nРезервная копия: %s\n' "$conf" "$backup"
printf 'Автопродление: certbot-renew.timer; после обновления выполняется reload Nginx.\n'
printf 'Токен хранится в %s — он нужен для продления.\n' "$credentials"
printf 'DNS-записи поддоменов и server_name Nginx настраиваются отдельно.\n'
