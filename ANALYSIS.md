# Разбор системы ключа/подписи и причин краша после патча

Файл анализа: `GameBlaster Pro_7.0.apk` (package: `kentos.loader`, version `7.0/31`).

## 1) Что проверяется перед входом (Java-уровень)

### Обнаруженные точки проверки
- `LoginActivity.onCreate(...)` вызывает `checkSignature()` ещё на раннем этапе запуска.
- В `LoginActivity` есть `showInvalidKeyDialog()` и native-мост `native_Check(Context, String, String)`.
- В `App` есть:
  - `expectedSignatureSha256` (эталон ожидаемой подписи),
  - `getApkSignatureSha256()` (чтение текущего signer-сертификата через `SigningInfo` + `MessageDigest`),
  - `checkRootAccess()` (через `com.topjohnwu.superuser.Shell.rootAccess()`).

### Важная деталь по обфускации
Строки и часть логики скрыты через `org.lsposed.lsparanoid.Deobfuscator$...->getString(long)` (включая эталон подписи). Из‑за этого «быстрый smali-патч» часто оставляет живыми другие проверки.

## 2) Проверка ключа и краш-триггеры в native (`libclient.so`, `libBlackBox.so`)

### `libclient.so` (основная логика ключа)
Найдены JNI-точки:
- `native_Check`
- `Java_kentos_loader_server_ApiServer_ApiKeyBox`
- `Java_kentos_loader_server_ApiServer_FixCrash`
- `Java_com_rei_pro_Component_Utils_sign`

И диагностические строки:
- `User key verification failed. Exiting.`
- `User key verified successfully.`

Это указывает, что при невалидном результате процесс завершается на native-уровне.

### `libBlackBox.so` (anti-tamper/anti-debug слой)
Найдены функции:
- `checkDebugger`
- `verifyUrlAndReturn`
- `hideXposed`
- `loadEmptyDex`

И строки:
- `Debugger detected! Exiting application.`
- `jni hook error. class`

То есть помимо ключа есть отдельный слой аварийного выхода при дебаге/хуках/нештатной среде.

## 3) `assets` (два архива)

В `assets` находятся:
- `empty.jar` — маленький dex-стаб;
- `junit.jar` — JUnit dex.

Прямых признаков, что именно они содержат основную логику key-check, не выявлено. Критичные гейты расположены в `LoginActivity` + native `.so`.

## 4) Почему падает после патча

1. **Изменилась подпись APK** после перепаковки.
2. **Обойдён только Java-слой**, а native-проверка осталась.
3. **Сработал anti-debug/anti-hook** слой.
4. **JNI-несовместимость** после правок (сигнатуры/имена/порядок загрузки).

## 5) Патч (стабилизация, без обхода защиты)

Ниже — безопасный путь для автора приложения, чтобы сборка после изменений не падала из-за рассинхрона проверок.

1. **Зафиксировать единый ключ подписи для debug/release pipeline**
   - Переупаковка должна подписываться тем же ключом, который ожидается приложением.
   - Если ключ изменён легитимно, обновить ожидаемый fingerprint в исходниках (а не “ломать” проверку в рантайме).

2. **Синхронизировать Java и native конфигурацию проверки**
   - Если меняется формат/источник ключа, обновлять обе стороны:
     - Java (`checkSignature`, `getApkSignatureSha256`),
     - native (`native_Check`/`ApiKeyBox`).
   - Иначе одна из сторон продолжит вызывать аварийный выход.

3. **Не ломать JNI-контракт при патче**
   - Не менять сигнатуры native-методов в Java-классах без зеркального обновления в `.so`.
   - Проверить порядок `System.loadLibrary(...)` и факт загрузки всех требуемых библиотек до вызова native.

4. **Убрать ложные anti-debug срабатывания на dev-сборках**
   - Разнести поведение по build flavor (`dev`/`prod`), чтобы dev-сборка не завершалась принудительно от инструментов диагностики.

5. **Минимальный чек-лист перед запуском патча**
   - `adb logcat | rg -i "kentos|JNI|UnsatisfiedLinkError|verification failed|Debugger detected|FATAL EXCEPTION|SIGSEGV"`
   - Проверить, какой гейт падает первым (подпись / ключ / anti-debug / JNI).

## 6) Ключевой вывод

Падение после патча в этом APK почти наверняка многослойное: Java signature gate + native key gate + anti-debug слой. Поэтому правка только одной точки редко устраняет краш полностью.


## 7) Готовый патч-инструмент

Добавлен скрипт `patch_stabilization.sh`, который сравнивает оригинальный и пропатченный APK по `assets/*.jar`, `lib/**/*.so`, проверяет JNI-экспорты и crash-маркеры в `.so`, и выводит команды для проверки подписи и runtime-диагностики.

Запуск:

```bash
./patch_stabilization.sh "GameBlaster Pro_7.0.apk" "patched.apk"
```


## 8) Альтернативный патч (другой формат)

Добавлен второй инструмент `apk_patch_audit.sh` (альтернатива `patch_stabilization.sh`).
Он формирует markdown-отчёт (`APK_PATCH_AUDIT.md`) с:
- diff инвентаря `assets/*.jar`, `lib/**/*.so`, `classes*.dex`;
- таблицей изменений размеров критичных файлов;
- JNI/crash-маркерами для `libclient.so` и `libBlackBox.so`;
- подсказками по проверке подписи и runtime-триажу.

Запуск:

```bash
./apk_patch_audit.sh "GameBlaster Pro_7.0.apk" "patched.apk"
# или
./apk_patch_audit.sh "GameBlaster Pro_7.0.apk" "patched.apk" my_report.md
```
