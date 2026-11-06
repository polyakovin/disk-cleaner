# Лендинг Disk Manage

Язык сайта и приложения: английский. При правках переводить также метаданные, подписи доступности и иллюстрацию интерфейса; `lang="en"`, `og:locale="en_US"`. Начиная с v0.2.0 архив содержит английское приложение `Disk Manage.app`.

Адрес: <https://diskmanage.pro/>. Старый адрес <https://polyakovin.github.io/disk-cleaner/> перенаправляется GitHub Pages на этот домен.

`site/` содержит статический сайт без сборщика и внешних шрифтов. Workflow `.github/workflows/pages.yml` публикует только этот каталог при изменениях сайта в `main`; доступен и ручной запуск. В настройках репозитория источником GitHub Pages должен быть GitHub Actions (`build_type: workflow`).

Домен `diskmanage.pro` задан в Settings → Pages → Custom domain. При публикации через Actions файл `CNAME` не нужен и игнорируется GitHub, см. [настройку собственного домена](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site). В Pages должен быть включён Enforce HTTPS после завершения выпуска сертификата. DNS корневого домена использует четыре A-записи GitHub Pages: `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`. Для `www` нужна CNAME-запись на `polyakovin.github.io`, без имени репозитория.

В `site/index.html` задан `<base href="/">`: стили, иконки и якоря разрешаются от корня домена. `canonical`, `og:url`, `robots.txt` и `sitemap.xml` используют `https://diskmanage.pro/`. При смене домена обновлять их вместе с настройками Pages и DNS.

Cloudflare Web Analytics подключена в `site/index.html` перед `</body>` через официальный модуль `beacon.min.js`. Для `diskmanage.pro` создан отдельный счётчик; его идентификатор в HTML публичный и не является API-ключом. В кабинете Cloudflare откройте Web Analytics → `diskmanage.pro`. Прежний общий счётчик `polyakovin.github.io` сохранён для остальных проектов. Порядок ручного подключения описан в [документации Cloudflare](https://developers.cloudflare.com/web-analytics/get-started/).

Локальный просмотр:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Лендинг закреплён за проверенным preview `v0.2.0`. Последующие автоматические patch-релизы доступны в GitHub Releases; сайт обновляется отдельно при смене закреплённого preview. Макет отчёта содержит иллюстративные данные, не снимок пользовательского диска. Иконка повторяет исходную иконку Disk Manage из `DiskLens/scripts/make-icon.swift`.

С 5 ноября 2026 года сервис называется Disk Manage. Исторический архив v0.1.0 сохраняет имя `DiskLens.app`; v0.2.0 использует `Disk Manage.app`. При обновлении закреплённой версии менять ссылки и инструкции вместе.

При обновлении закреплённого preview менять в `site/index.html` номер версии, прямые ссылки на ZIP и SHA-256, размер архива, возможности и ограничения проверки. Ссылки закреплены за конкретным релизом: endpoint `releases/latest/download` пропускает предварительные выпуски. Порядок автоматической публикации описан в `docs/RELEASE.md`.

Проверить ресурсы от корня `/`, якоря, скачивание из GitHub Releases, мобильную вёрстку и переходы с клавиатуры. Выполнить канонические проверки из корневого `AGENTS.md`. После публикации проверить успешный workflow, HTTP 200 для страницы и ресурсов, редиректы HTTP → HTTPS и со старого адреса, а также новый счётчик в HTML.

При изменении `site/styles.css` обновить параметр `v` у ссылки на него в `site/index.html` первыми 12 символами SHA-256 файла. Это обновляет стили и у посетителей с закэшированной версией.
