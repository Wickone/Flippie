# Flippie: аудит и план улучшений

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Этот документ — план; реализация начинается отдельным запросом пользователя.

**Goal:** Сделать Flippie надёжным инструментом импорта, проверки, редактирования и экспорта Lottie с предсказуемым нативным интерфейсом.

**Architecture:** Оставить `AnimationDocument` моделью документа, выделить владельца плеера `PlaybackSession` и координатор модальных экранов. Разделить импорт пакетов, выбор рендерера и кодирование экспорта; превью, сравнение и экспорт должны получать один и тот же подготовленный документ и набор ресурсов.

**Tech Stack:** SwiftUI, UIKit, WebKit, AVFoundation, ImageIO; встроенные lottie-ios 3.0.0 / 3.5.0 / 4.0.0 / 4.6.1 и lottie-web SVG.

**Spec:** Запрос пользователя от 19.10.2026: проанализировать существующий код, определить улучшения и составить план. Продуктовые ограничения и критерии приведены ниже; отдельного утверждённого нового дизайна в этой задаче нет.

## Основание и ограничения

- Проверена локальная ветка `main`, коммит `6fcf071` (`Clean repository files`). До аудита рабочая копия чистая.
- Путь проекта: `/Users/Wickone/Documents/iOS/Flippie/Flippie.xcodeproj`.
- Deployment target сейчас iOS 17.5; нативный Liquid Glass используется на iOS 26+. Сохранить fallback для более ранних поддерживаемых версий.
- Сохранить переключение четырёх встроенных версий в одном приложении и существующие форматы JSON/GIF/MP4/MOV.
- Сохранить нативные sheets с detents `.medium` / `.large`, светлую тему и открытие Edit/Export модально.
- Подготовка плана не разрешает менять приложение, обновлять библиотеки, коммитить или отправлять изменения в GitHub.
- Результат чтения кода не равен визуально воспроизведённому дефекту. Ниже отдельно указаны ограничения проверки.

## Что уже реализовано

- Импорт JSON и `.lottie`, stored/deflate ZIP, выбор начальной анимации по manifest v1/v2, копирование внешних изображений и поиск недостающих ресурсов.
- Валидация базовых полей, ограничения размера JSON/архива/распаковки и защита путей ZIP от обычного traversal.
- Четыре namespaced native runtime; при Gaussian Blur выбирается общий SVG fallback.
- Замена статических и keyframed fill/stroke цветов, обход групп и precomp assets; добавление настоящего solid-слоя фона.
- Общий frame renderer для GIF и видео, `AVAssetWriter`, выбор размера/FPS/скорости/фона, MOV HEVC with Alpha, прогресс, базовая отмена и удаление частичных файлов.
- 32 XCTest-метода: базовые загрузки runtime, импорт пакетов/изображений, blur, правки цветов, фон, экспорт и отмена.

Это существующие реализации, а не подтверждение безошибочной работы всех сценариев.

## Проверка 19.10.2026

- `xcodebuild build -project Flippie.xcodeproj -scheme Flippie -destination 'generic/platform=iOS' ... CODE_SIGNING_ALLOWED=NO` завершился с кодом 0; `.app`, исполняемый файл и debug dylib созданы во временной DerivedData.
- В логе есть предупреждения старых vendored Lottie и сообщения инструментария `command failed with exit code 0`; сборку нельзя называть свободной от диагностик.
- `xcodebuild test ...` завершился с кодом 70 до выполнения тестов: Xcode 27.1 ожидает CoreSimulator 1174.9.2, установлен 1171.7.0. Прохождение 32 тестов сейчас не подтверждено.
- Точное выражение web-моста `JSON.parse(atob(base64UTF8))` проверено отдельно в Node: строка `Привет 👋` повреждается. Это воспроизведение преобразования данных, не UI-тест WebKit.
- Результаты: `/tmp/flippie-audit-device-20261019.log`, `/tmp/flippie-audit-20261019.log`, `/tmp/flippie-audit-20261019.xcresult`.
- Pixel-perfect соответствие Figma, физическое устройство, peak memory и поведение при длинных экспортных задачах в этом аудите не проверялись.

## Подтверждённые проблемы и ограничения

| Приоритет | Наблюдение | Основание в коде | Последствие |
|---|---|---|---|
| P0 | CI ссылается на старый проект и схему; выбран Xcode 16.4 | `.github/workflows/ios.yml:16–24,49–56`; `Views/FlippieSharedComponents.swift:123–130` | Workflow не найдёт проект. Для сборки кода с Liquid Glass нужен SDK с этими API; runtime `#available` не заменяет новый SDK. |
| P0 | Базовая валидация допускает значения, приводящие к trap | `Services/LottieImportService.swift:249–261`; `Models/AnimationDocument.swift:292–313,324,684–685` | `w=1e20` доходит до `Int(Double)`; повторяющиеся asset ID — до `Dictionary(uniqueKeysWithValues:)`. Ошибка входного файла может завершить приложение. |
| P0 | Лимит распаковки основан на размере из ZIP header | `Services/LottieImportService.swift:773–779,923–943` | Реальный output накапливается без лимита, сравнение выполняется в конце: поддельный размер в header позволяет исчерпать память до отказа. |
| P0 | Web readiness/snapshot ждут continuation без deadline и обработки отмены | `Views/LottieWebPlayerView.swift:156–180,205–211,255–259` | Потерянное сообщение JS или завершение web-процесса может оставить экспорт в ожидании; поздний waiter не получает сохранённую ошибку. |
| P1 | Alpha MOV проверяется неверным идентификатором | `Services/AnimationExporter.swift:476–486`; `FlippieTests/FlippieSmokeTests.swift:728–761` | `kCMVideoCodecType_HEVCWithAlpha` выбирает encoder, тогда как профиль Apple требует `hvc1` в sample entry. Проверка может отвергать корректный результат; тест принимает этот отказ как допустимый. Нужны characteristic/format extensions и декодирование alpha. |
| P1 | Security-scoped grant может не активироваться | `Services/LottieImportService.swift:522–537` | `fileExists` ошибочно делает любой видимый внешний URL «локальным»; file provider может показывать metadata, но требовать scope для чтения. Нужен тест через реальный picker/provider. |
| P1 | Относительный путь изображения уступает поиску по имени | `Services/LottieImportService.swift:699–705`; `Views/LottieView.swift:363–369` | При `photo.png` и `icons/photo.png` два разных assets могут получить один root файл. |
| P1 | Имя нормализованного JSON может затереть manifest | `Services/LottieImportService.swift:291–296` | `manifest.lottie` приводит к записи анимации поверх извлечённого `manifest.json` внутри нового пакета. |
| P1 | Native и web по-разному трактуют `currentFrame` при ненулевом `ip` | `ContentView.swift:1372–1397,1505–1509`; `Views/LottieWebPlayerView.swift:88–107,125–135,202–204` | При `ip=60, op=120` UI добавляет 60 к относительному кадру web; покадровый переход и счётчик работают неверно. |
| P1 | Web `.autoReverse` реализован как `loop=true` | `Views/LottieWebPlayerView.swift:143–152` | Настройка Back-and-Forth обещает другой режим воспроизведения. |
| P1 | UTF-8 JSON декодируется через `atob` как строка байтов | `Views/LottieWebPlayerView.swift:281` | Кириллица, emoji и другие не-ASCII строки в text layers меняются до передачи Lottie. |
| P1 | `isPlaying` — отдельный bool без события завершения | `ContentView.swift:1350–1369,1448–1466`; `Views/LottieView.swift:205–215` | После Play Once UI может продолжать показывать Pause и держать timer; ручной переход по кадрам тоже требует согласованного pause state. |
| P1 | Экспорт JSON записывает только JSON, ресурсы не переносятся | `Services/AnimationExporter.swift:283–288`; `Views/MainExportView.swift:363–376` | JSON с внешними изображениями не становится переносимым при отправке одного файла. |
| P1 | Правки сохраняются только в памяти документа | `Models/AnimationDocument.swift:541–592,613–619`; `FlippieTests/FlippieSmokeTests.swift:582–598` | Повторное открытие sheet работает, но восстановление после перезапуска не реализовано; текущий тест проверяет только тот же объект. |
| P1 | Нижняя панель — кастомные HStack/Button, всегда выбран Preview | `ContentView.swift:610–663` | `UITabBar.appearance()` её не настраивает; системных tab selection жестов и поведения нет. |
| P1 | Верстка привязана к ширине 393 и абсолютным координатам | `ContentView.swift:387–428,683–737` | Нет устойчивого layout-контракта для landscape, iPad, небольших высот и Dynamic Type. Например, при 844×390 расчёт центра контролов выходит за высоту экрана. |
| P1 | `Pass` означает успешную загрузку, без ожидания и проверки кадра | `ContentView.swift:1287–1326` | Успешный decode может выглядеть как подтверждённая визуальная совместимость. Для blur честно указан fallback, но native runtime не сравниваются. |
| P2 | Renderer comparison не получает `baseURL` изображений | `Views/LottieView.swift:486–488,595–612`; `ContentView.swift:1007–1010` | В основной сцене изображения могут быть доступны, а в сравнении их provider не подключён. |
| P2 | Редактор работает с глобальными заменами fl/st | `Models/AnimationDocument.swift:151–154,977–1008`; `Models/LottieAnalyzer.swift:115–146` | Нельзя отдельно изменить два одинаковых цвета в разных слоях; gradient/text/solid/effect colors не имеют того же механизма редактирования. |
| P2 | Повторные JSON-проходы и тяжёлая работа на UI actor | `Models/AnimationDocument.swift:558–560,630–633`; `ContentView.swift:1215–1225,1287–1326`; `Services/AnimationExporter.swift:269–270,326–344` | `renderedData` пересобирает JSON при каждом обращении; совместимость и кодирование могут конкурировать с интерфейсом. Нужны замеры, а не обещания ускорения. |

## Review Focus

Проверки, которые должны появиться в соответствующих этапах:

1. Открытие/закрытие sheets во время native/web playback, отмена и поздний callback: один живой preview, отсутствие белой вспышки и потерянных задач (этапы 3, 7).
2. Blur + ненулевой `ip` + русский текст: одинаковые кадры, читаемый текст и настоящий ping-pong во всех поддерживаемых режимах (этап 4).
3. Пакет с изображениями, несколькими анимациями, повреждённым ZIP и неверным manifest: детерминированный выбор, отсутствие потерянных ресурсов и остатков после ошибки (этап 2).
4. Нецелая длительность, FPS, alpha-края и ошибка encoder: проверяются декодированные кадры/таймкоды, а не только размер файла (этап 5).
5. Перезапуск после правок и большие шрифты/короткий экран: правки восстанавливаются, интерфейс остаётся доступным (этапы 6, 7).

## Порядок работ

### Этап 1 — восстановить проверяемую базу (P0)

**Файлы:** `.github/workflows/ios.yml`, `README.md`, `DEVELOPMENT.md`, `Flippie.xcodeproj/xcshareddata/xcschemes/Flippie.xcscheme`.

**Interfaces:** существующие scheme `Flippie` и package targets `Lottie300`, `Lottie350`, `Lottie400`, `Lottie461`; новые runtime не добавляются.

- [x] Исправить ссылки `LottieLab` → `Flippie`, выбрать доступный CI runner/toolchain с iOS 26+ SDK; точную установленную версию закрепить после проверки образа runner.
- [x] Согласовать локальные Xcode/CoreSimulator по инструкции диагностики. Переустановка системных компонентов — отдельная операция с разрешением пользователя.
- [x] Запустить существующие 32 теста, выделить реальные провалы отдельно от отсутствующих simulator/codec capabilities.
- [x] Проверить, что version matrix действительно собирает каждую доступную scheme; переименовать `Snapshot build`, пока job не создаёт snapshots.
- [x] Сохранять `.xcresult` и логи в CI; актуализировать документацию SDK, импорта `.lottie` и MP4/MOV.
- [x] Зафиксировать этап отдельным коммитом после разрешённого начала реализации.

**Проверка:** `xcodebuild -list -project Flippie.xcodeproj`; `xcodebuild test -project Flippie.xcodeproj -scheme Flippie -destination 'platform=iOS Simulator,id=<проверенный UDID>' CODE_SIGNING_ALLOWED=NO`. Готовность: успешный полный прогон и реально работающие CI jobs, а не только исправленный YAML.

**Статус 19.10.2026:** локальные проверки — 32/32 теста, 4/4 отдельных сборки, actionlint и проверки схем прошли. CI настроен на Xcode 26.3 / iOS 26.2; удалённый прогон GitHub Actions ожидается после отправки ветки. Подробности: [отчёт этапа 1](2026-10-19-stage-1-verification.md). Историческое ограничение CoreSimulator из раздела аудита выше устранено средствами выбранного Xcode.

### Этап 2 — безопасный импорт и переносимый пакет (P0/P1)

**Файлы:** `Flippie/Services/LottieImportService.swift`, `Flippie/Views/LottieView.swift`, `Flippie/Models/ContentViewSupport.swift`; создать `Flippie/Services/LottieAssetResolver.swift`, `FlippieTests/LottieImportTests.swift`.

**Interfaces:** общий `LottieAssetResolver` используется отчётом, плеером и экспортом. Результат разрешения возвращает asset ID, URL/status и исходный относительный путь; пакет владеет JSON, manifest и ресурсами выбранной анимации.

- [ ] Добавить фикстуры `.lottie` v1/v2 с несколькими анимациями, вложенными/одноимёнными изображениями, обычным JSON с соседними assets, повреждёнными данными и отменой.
- [ ] Первыми добавить `testOversizedNumericFieldsReturnRecoverableError` и `testDuplicateAssetIDsReturnRecoverableError`; запретить trapping conversion и duplicate-key construction на недоверенном JSON. Диапазоны должны быть representable и ограничены согласованным ресурсным бюджетом, а не только условием `>0`.
- [ ] Добавить `testInflateRejectsForgedUncompressedSizeDuringStreaming`: перед каждым append проверять реальный `produced` против ожидаемого размера и оставшегося бюджета 300 MiB. Ошибка останавливает распаковку до превышения лимита.
- [ ] Активировать security scope для внешних file/folder URL, балансировать release при любом исходе; не считать file existence признаком sandbox-local URL. Проверить Files/iCloud и repair выбранной папки на устройстве.
- [ ] Упорядочить поиск: точный `u+p` раньше basename fallback; отчёт `Found` должен соответствовать ресурсу, который реально декодируется renderer.
- [ ] Развести extracted entries и служебный normalized JSON: `testImportNamedManifestPreservesManifestBytes` и тест root JSON с тем же basename проверяют отсутствие перезаписи.
- [ ] Сделать импорт/repair транзакционными: временная staging-папка, commit после валидации, удаление только staging на ошибке или отмене. Ограничения проверять до дорогого чтения/распаковки, насколько позволяет provider.
- [ ] Добавить cooperative cancellation, проверки целостности ZIP и тесты существующих path/size ограничений. Не писать новый архиватор без необходимости: оценить уже vendored ZIP реализацию перед выбором.
- [ ] Добавить выбор анимации из `.lottie`; сохранить manifest/themes/fonts как данные пакета. Явно показывать неподдерживаемые возможности вместо молчаливой потери.
- [ ] Подключить общий resolver в renderer comparison и передавать `baseURL`.
- [ ] Коммит этапа после round-trip тестов пакета.

**Готовность:** загруженный пакет работает после потери доступа к исходной папке; отчёт и изображение совпадают; ошибка/отмена не оставляет незавершённый пакет. Themes/state machines — отдельный последующий этап исполнения, не побочный рефакторинг импортера.

### Этап 3 — единый жизненный цикл плеера и модальных экранов (P0/P1)

**Файлы:** изменить `Flippie/ContentView.swift`, `Flippie/Views/LottieView.swift`; создать `Flippie/Models/PlaybackSession.swift`, `Flippie/Models/SheetRoute.swift`, `FlippieTests/PlaybackSessionTests.swift`.

**Interfaces:** `@MainActor PlaybackSession` владеет одним `VersionedLottiePlayerView`; методы `load(data: Data, runtime: LottieRuntimeVersion, baseURL: URL?) async throws`, `play()`, `pause()`, `seek(progress: Double)`, `close()`; публикует playback state, progress и readiness. `SheetRoute` представляет один активный sheet.

- [ ] Добавить регрессии `testFailedRuntimeSwitchPreservesFrameAndPlayback`, `testPlayOncePublishesStoppedState`, `testFrameStepPausesPlayback`, `testOpeningSheetKeepsPreviewIdentity`.
- [ ] Перенести player state/timer из ContentView в session; сохранить одну и ту же UIView при открытии Edit/Export. Заменять engine только после успешной подготовки кандидата.
- [ ] Централизовать презентацию sheets; переход Playback Settings → Renderer Test выполнять после dismiss, без конкурирующих presentation bool.
- [ ] Добавить completion события плеера и политику background/foreground; остановить polling там, где воспроизведение завершено или неактивно.
- [ ] Прогнать регрессии и цикл Import → Play → Edit → dismiss → Export → dismiss → смена runtime → Back для native и blur fixtures; сохранить видео UI-прогона для проверки вспышек.
- [ ] Коммит этапа после прохождения проверок.

**Готовность:** открытие sheets не пересоздаёт preview, failed switch сохраняет видимый кадр, Play Once корректно меняет кнопку обратно на Play.

### Этап 4 — согласованное воспроизведение native/web (P1)

**Файлы:** `Flippie/Views/LottieView.swift`, `Flippie/Views/LottieWebPlayerView.swift`, `Flippie/Models/AnimationDocument.swift`; создать `Flippie/Models/AnimationTimeline.swift`, `FlippieTests/PlaybackTimelineTests.swift`, `FlippieTests/WebRendererTests.swift`.

**Interfaces:** `AnimationTimeline(startFrame: Double, endFrame: Double, frameRate: Double)`; методы `absoluteFrame(forProgress: Double) -> Double` и `progress(forAbsoluteFrame: Double) -> Double`. Публичный `currentFrame` всех engines — абсолютный кадр; JS relative frame преобразуется на границе bridge.

- [ ] Регрессия `ip=60, op=120, fr=60`: progress 0/0.5 соответствует frame 60/90; step 60→61 одинаков для native/web; последний экспортный кадр не выходит за `op`.
- [ ] Добавить readiness state с сохранением failure, deadline и cancellation handler для ready/frame/snapshot continuations; обработать navigation failure и завершение web-процесса.
- [ ] Проверить `testWebSnapshotCancellationFinishes`, `testReadyFailureIsReturnedToLateWaiter`, `testWebProcessTerminationFailsPendingRequests`.
- [ ] Исправить UTF-8 decode и проверить `Привет 👋` как actual text-layer content через bridge, а не только JSON parse в Swift.
- [ ] Реализовать web autoReverse с переключением направления по завершению сегмента; `testWebAutoReverseVisitsFramesInBothDirections` проверяет последовательность кадров.
- [ ] Заменить фиксированное ожидание 100 ms на подтверждение подготовленного кадра. Ровность кадра проверить снимками движущегося объекта.
- [ ] Коммит этапа после тестов с blur, masks и ненулевым `ip`.

### Этап 5 — достоверный и управляемый экспорт (P1)

**Файлы:** `Flippie/Services/AnimationExporter.swift`, `Flippie/Views/MainExportView.swift`; использовать `AnimationTimeline` этапа 4 и resolver этапа 2; создать `FlippieTests/ExportFidelityTests.swift`.

**Interfaces:** сохранить `AnimationExportRequest` / `AnimationExportPlan` как точку входа; timeline строит timestamps из `frameIndex/fps`. Захват UIKit/WebKit остаётся MainActor, encoding worker принимает готовый кадр с ограниченной очередью.

- [ ] Добавить проверку кадров движущегося разноцветного объекта: декодировать GIF/видео, сравнить начало/середину/конец, фон, canvas, alpha и изменения из редактора.
- [ ] Исправить выбор source progress для нецелого `duration*fps`; согласовать ожидаемую длительность файла с точностью до одного output frame. Тест `duration=1.01, fps=30` должен проверять timestamps и положение объекта.
- [ ] Контролировать состояние writer и deadline в ожидании готовности; ошибка должна завершать задачу с удалением partial output. Отмену проверить во время render, wait и finalize.
- [ ] Исправить проверку alpha MOV: использовать `asset.loadTracks(withMediaCharacteristic: .containsAlphaChannel)` / соответствующие format description extensions, затем проверить декодированные pixels. Проверка sample-entry subtype на `muxa` не доказывает alpha. Отделить ошибку проверки от реального отсутствия encoder; существующий тест не должен молча принимать обе ситуации.
- [ ] Сделать JSON с external assets переносимым: явный self-contained JSON с embedded images либо пакет `.lottie`; round-trip из изолированной папки обязателен. Выбранный режим виден пользователю.
- [ ] Проверять alpha по пикселям и краям после декодирования, а не только по fourCC; сохранить честную ошибку, если устройство не поддерживает alpha codec.
- [ ] Для GIF проверить фактическое влияние Quality, палитру, прозрачность и delay; показывать только настройки с проверяемым результатом.
- [ ] Выносить encoding из MainActor по профилю; ограничить объём кадров в полёте, добавить preflight размера/числа кадров и понятные состояния Preparing / Rendering / Finalizing.
- [ ] Временные экспорты хранить и очищать по явной политике share/save; не копить каждый результат в Documents без управления.
- [ ] Коммит этапа после round-trip и cancellation tests.

**Готовность:** файл открывается автономно, содержит ожидаемые движущиеся кадры и длительность; отказ/отмена завершаются без зависания и остатков.

### Этап 6 — сохранение рабочего проекта и редактора (P1)

**Файлы:** `Flippie/Models/AnimationDocument.swift`, `Flippie/Views/EditPropertiesSheet.swift`; создать `Flippie/Models/FlippieProject.swift`, `Flippie/Services/ProjectStore.swift`, `FlippieTests/ProjectPersistenceTests.swift`.

**Interfaces:** `FlippieProject: Codable` содержит schemaVersion, относительные ссылки внутри пакета, edits, runtime и playback options. `ProjectStore.save(_ project: FlippieProject, at url: URL) async throws` / `load(from url: URL) async throws -> FlippieProject`; `AnimationEdits` получает Codable.

- [ ] Тест `testReopenedProjectPreservesEditsAndAssets`: создать проект, изменить цвет/фон/скорость/runtime, сохранить, удалить все in-memory объекты, загрузить новый документ и сравнить данные/кадр.
- [ ] Добавить атомарную запись и восстановление последнего проекта; original JSON хранить отдельно от edits, пути ресурсов — относительные.
- [ ] Проверить повреждённую запись и неизвестную schemaVersion; ошибка сохранения не должна показывать успех или разрушать предыдущую валидную версию.
- [ ] Разделить Apply draft и сохранение проекта; добавить undo/redo для последовательности правок и явную отмену изменений sheet.
- [ ] Проверить экспорт восстановленного проекта после перезапуска и обновления приложения.
- [ ] Коммит этапа после persistence tests.

**Готовность:** закрытие sheet и перезапуск приложения одинаково сохраняют применённые правки и работоспособность assets.

### Этап 7 — нативный адаптивный интерфейс (P1)

**Файлы:** `Flippie/ContentView.swift`, `Flippie/FlippieApp.swift`, `Flippie/Views/FlippieSharedComponents.swift`; создать `Flippie/Views/LoadedPreviewScreen.swift`, `Flippie/Views/NativePreviewTabs.swift` и UI-test target.

**Interfaces:** preview получает стабильную `PlaybackSession` этапа 3; Edit/Export обращаются к общему `SheetRoute`. Настоящий `UITabBarController`/`UITabBar` предоставляет системное взаимодействие; delegate перехватывает Edit/Export как команды sheets, сохраняя Preview. Сначала проверить этот сценарий на минимальном прототипе.

- [ ] Заменить custom HStack tabbar нативным компонентом со светлой trait environment; убрать ставшие неиспользуемыми custom tab backgrounds. Не задавать материал через вручную нарисованную подложку.
- [ ] Перевести рабочий экран на navigation toolbar, safe areas и layout-ограничения; размер preview зависит от доступных ширины и высоты. Декоративные элементы пустого экрана отделить от интерактивного layout.
- [ ] Сохранить модальное открытие Edit/Export и одну идентичность preview; нативность жестов и presentation подтвердить на устройстве. Точный цвет системного материала зависит от платформы и backdrop — это проверка на целевой iOS, а не обещание произвольного hex.
- [ ] Проверить ширины 320/393/430/768 pt, landscape и accessibility Dynamic Type; все кнопки доступны, элементы не перекрываются, текст не обрезан.
- [ ] Добавить VoiceOver labels для play/pause/frame step, accessibility values для прогресса, Reduce Motion; профиль либо получает действие, либо явно обозначается как будущая функция.
- [ ] UI-регрессия многократного открытия/закрытия sheets: отсутствие вспышек проверять записью перехода, сохранение preview — также автоматическими assertions.
- [ ] Коммит этапа после согласованного визуального review на целевых устройствах.

### Этап 8 — честное сравнение и дальнейшее развитие (P2)

Этот этап — очередь независимых улучшений. Перед реализацией разделить сравнение кадров, расширение редактора и оптимизации на отдельные небольшие задачи с собственными критериями.

**Файлы:** `Flippie/Views/LottieView.swift`, `Flippie/Models/ContentViewSupport.swift`, `Flippie/Models/LottieAnalyzer.swift`, `Flippie/Models/AnimationDocument.swift`, `.github/workflows/ios.yml`; создать snapshot/performance fixtures и отдельные тестовые suites.

- [ ] Разделить статусы `decoded`, `ready`, `rendered`, `fallback`, `failed`; визуальный Pass выдавать только после проверки кадра. Показывать фактический runtime/engine.
- [ ] Снимать одинаковые progress 0/0.25/0.5/0.75/0.99, передавать один asset context и сравнивать с утверждёнными эталонами. Одного совпадения двух ошибочных renderers недостаточно.
- [ ] Начальный корпус: masks/mattes, precomps, blur, gradient, images, text, time remap, offsets; фиксировать ожидаемые различия версий вместо требования абсолютной идентичности.
- [ ] Объединить обнаружение и редактирование свойств в registry со стабильным JSON path: отдельно unique colors, occurrences и unsupported properties. Затем добавлять адресные изменения слоя и gradient/text/solid colors по одному виду.
- [ ] Кэшировать parsed metadata, capabilities и renderedData по revision документа; исключить повторные parse/serialize на playback ticks.
- [ ] Снять baseline времени импорта, переключения runtime, CPU/peak memory и экспорта на выбранном iPhone; бюджеты регрессии назначить по реальным измерениям.
- [ ] Удалить legacy views и неиспользуемые UI helpers после проверки references/build phases; синхронизировать документацию. Vendored библиотеки сохранить с версиями, LICENSE и описанием локальных patches.
- [ ] Новые runtime, исполнение themes/slots/state machines и новые форматы экспорта оценивать отдельными задачами после стабилизации предыдущих этапов.

## Правило выполнения

Выполнять по одному этапу, начиная с этапа 1. Каждый этап должен давать наблюдаемый результат и свой набор проверок. До следующих изменений интерфейса обязательно иметь рабочие baseline и регрессию жизненного цикла preview. Оценки производительности и сроков уточнять после первого зелёного прогона; обещание «лучший на рынке» без корпуса сравнений и замеров недоказуемо.

## Первичные внешние источники

- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) — системные компоненты и материалы; glass modifier сам по себе не превращает HStack в системный tab bar.
- [Apple: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) — TabView, navigation и sheets в новом системном дизайне.
- [Apple: AVAssetWriter.finishWriting](https://developer.apple.com/documentation/avfoundation/avassetwriter/finishwriting(completionhandler:)) — завершение записи после добавления samples.
- [Apple: HEVC Video with Alpha Interoperability Profile](https://developer.apple.com/av-foundation/HEVC-Video-with-Alpha-Interoperability-Profile.pdf) — sample entry `hvc1`; [containsAlphaChannel](https://developer.apple.com/documentation/avfoundation/avmediacharacteristic/containsalphachannel) — проверка наличия alpha, отдельная от выбора encoder.
- [dotLottie v2 specification](https://dotlottie.io/spec/2.0/) — animations, initial animation, themes/state machines и структура пакета. Поддержка чтения одного JSON не означает поддержку исполнения всего формата.
