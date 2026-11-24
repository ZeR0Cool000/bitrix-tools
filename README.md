# bitrix-tools

Скрипты для BitrixVM 9 на Rocky Linux 9.

## Wildcard-сертификат через Cloudflare

`bitrix-wildcard.sh` выпускает сертификат Let's Encrypt для `site.ru` и `*.site.ru`, подключает его к Nginx и включает автоматическое продление.

### Запуск на каждом сервере

1. В аккаунте Cloudflare нужного домена создайте API Token: **My Profile → API Tokens → Create Token → Edit zone DNS**. Разрешение: **Zone / DNS / Edit**. В **Zone Resources** ограничьте доступ нужной зоной. DNS домена должен обслуживаться Cloudflare.
2. Подключитесь к серверу по SSH под `root` и выполните:

```bash
curl -fSL https://raw.githubusercontent.com/ZeR0Cool000/bitrix-tools/main/bitrix-wildcard.sh -o /root/bitrix-wildcard.sh && bash /root/bitrix-wildcard.sh
```

3. Введите домен без `https://` и `*.`, email, путь к конфигу и токен Cloudflare. Ввод токена скрыт.
4. Перед подтверждением `YES` проверьте выбранный конфиг. По умолчанию: `/etc/nginx/bx/conf/ssl.conf`. Он должен содержать ровно одну пару `ssl_certificate` / `ssl_certificate_key`. **Сертификат изменится для всех сайтов, использующих этот файл.** Если файл общий для разных доменов, выберите отдельный конфиг нужного сайта.
5. Дождитесь сообщения **ГОТОВО**. Выпуск и тест продления могут занять несколько минут.

Для разных аккаунтов Cloudflare используйте соответствующий токен на каждом сервере. При повторном запуске скрипт использует уже сохранённый токен.

### Что делает скрипт

- Проверяет Rocky Linux 9, запуск от root и существующую конфигурацию Nginx.
- Устанавливает Certbot и плагин Cloudflare из RPM-репозиториев.
- Выпускает сертификат с проверкой DNS-01.
- Проверяет продление командой `certbot renew --dry-run`.
- Сохраняет резервную копию SSL-конфига в `/root/bitrix-ssl-backups/`.
- Подключает файлы из `/etc/letsencrypt/live/ДОМЕН/` и проверяет `nginx -t`.
- Применяет настройки через `systemctl reload nginx`; при ошибке на этапе применения пытается восстановить прежний конфиг.
- Включает `certbot-renew.timer` и добавляет deploy hook для reload Nginx после продления.

Токен хранится на сервере в `/etc/letsencrypt/cloudflare/ДОМЕН.ini` с правами `600`. Не удаляйте его: он нужен для продления. Не загружайте токены, закрытые ключи и конфиги с секретами в этот публичный репозиторий.

### Проверка

```bash
systemctl list-timers certbot-renew.timer
certbot certificates
```

Проверка тестового продления конкретного домена:

```bash
certbot renew --cert-name site.ru --dry-run
```

Замените `site.ru` на свой домен.

### Ограничения

- `*.site.ru` покрывает один уровень поддоменов, например `www.site.ru` и `shop.site.ru`; `a.b.site.ru` не покрывается. Сам `site.ru` включается отдельно в тот же сертификат.
- Скрипт не создаёт DNS-записи поддоменов и виртуальные хосты Nginx.
- Нестандартные конфиги и файлы с несколькими парами сертификатов требуют отдельной настройки.
- Проверены синтаксис Bash и обработка конфигурации на тестовых примерах. Реальный выпуск на сервере пока не проверялся. Первый запуск выполните на одном сервере.

### Документация

- [Плагин Certbot для Cloudflare](https://certbot-dns-cloudflare.readthedocs.io/en/stable/)
- [Продление сертификатов Certbot](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates)
