# Quas ADB Commander
### (English manual below)

**Двухпанельный файловый менеджер для Meta Quest / Android устройств через ADB**

Часть инструментария [QUAS](https://github.com/Varsett/ADBFileManager).

---

## Возможности

- Двухпанельный интерфейс: PC (слева) и Android (справа)
- Просмотр, копирование, перемещение, переименование, удаление файлов на обоих устройствах
- Встроенный редактор текста и скриптов с подсветкой синтаксиса
- Поддержка архивов (7z, zip, rar, gz, tar...) через 7z.exe
- Установка APK с автоматическим копированием OBB
- Предпросмотр медиафайлов с Android (видео, фото, аудио)
- Поиск с поддержкой подстановочных символов
- Выделение файлов и пакетные операции
- Тёмная тема с цветовой маркировкой типов файлов

---

## Требования

- Windows 10/11
- PowerShell 5.1
- `adb.exe` (Android Debug Bridge)
- USB-отладка включена на устройстве Quest/Android
- **Опционально:** `aapt2.exe` — определение имени пакета APK
- **Опционально:** `7z.exe` + `7z.dll` — поддержка архивов

---

## Установка

1. Поместите `adbfm.ps1` в любую папку на ПК
2. Положите рядом `adb.exe`, `aapt2.exe`, `7z.exe`, `7z.dll`
   - или укажите путь через параметр `-ToolsPath`
   - или добавьте в `%PATH%`
   - или задайте переменную среды `%myfiles%`
3. Подключите Quest/Android через USB с включённой отладкой

---

## Запуск

```batch
powershell -ExecutionPolicy Bypass -File adbfm.ps1
```

С параметрами:
```batch
powershell -ExecutionPolicy Bypass -File adbfm.ps1 -ToolsPath "C:\Tools" -WorkDir "D:\Temp"
```

Рекомендуемый bat-файл запуска:
```batch
set toolspath=%~dp0
set workdir=%TEMP%
powershell -ExecutionPolicy Bypass -File "%~dp0adbfm.ps1" -ToolsPath "%toolspath%" -WorkDir "%workdir%"
```

---

## Параметры запуска

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `-ToolsPath` | Папка с `adb.exe`, `aapt2.exe`, `7z.exe` | Папка скрипта |
| `-WorkDir` | Временная папка для работы с архивами | `%TEMP%` |

---

## Горячие клавиши

### Навигация
| Клавиша | Действие |
|---------|----------|
| `Tab` | Переключить активную панель |
| `Enter` / двойной клик | Открыть папку / Запустить файл / Войти в архив |
| `Space` | Отметить/снять отметку (жёлтая подсветка) |
| `*` (Numpad) | Отметить ВСЁ / Снять все отметки (переключение) |
| `Alt+X` | Выход |
| `F9` | Перейти в Android/data |
| `F10` | Перейти в Android/obb |

### Файловые операции
| Клавиша | Действие |
|---------|----------|
| `F2` | Переименовать |
| `F3` | Поиск (поддерживается `*`) |
| `F4` | Открыть во встроенном редакторе |
| `F5` | Копировать на противоположную панель / Извлечь из архива |
| `F6` | Переместить / Переименовать |
| `F7` | Создать новую папку |
| `F8` / `Delete` | Удалить выделенные элементы |

### Редактор
| Клавиша | Действие |
|---------|----------|
| `Ctrl+S` / `F2` | Сохранить файл |
| `Esc` | Закрыть (спрашивает при несохранённых изменениях) |
| Кнопка Wrap | Переключить перенос строк |

---

## Контекстное меню (правая кнопка мыши)

| Пункт | Описание |
|-------|----------|
| Run | Запустить файл (только PC) |
| Edit (built-in) | Открыть во встроенном редакторе |
| Edit (pull-edit-push) | Скачать с Android, отредактировать, загрузить обратно |
| Open with default | Открыть системным приложением |
| Install APK | Установить APK + автокопирование OBB |
| Copy | Отметить + скопировать в буфер обмена |
| Paste | Вставить (все направления: PC↔Android, PC→PC, Android→Android) |
| Unpack archive | Распаковать архив на PC или Android |
| Pack selected | Запаковать отмеченное в `.7z` |

---

## Работа с архивами

Архивы открываются двойным кликом или Enter — отображаются как виртуальные папки.

**Внутри архива:**

| Действие | Результат |
|----------|-----------|
| `F4` на файле | Открыть текстовый/скриптовый файл в редакторе |
| `F5` (отмечены файлы) | Извлечь файлы без структуры папок |
| `F5` (отмечена папка) | Извлечь папку вместе с содержимым |
| `*` затем `F5` | Отметить всё + извлечь всё |
| `[Close Archive]` | Выйти из архива или подняться на уровень выше |

**Контекстное меню на файле архива:**
- **Unpack archive** — распаковать ВСЁ в указанную папку PC (путь редактируется) или в текущую папку Android (создаётся подпапка с именем архива)
- **Pack selected** — запаковать отмеченные элементы в `.7z` в текущей папке

**Поддерживаемые форматы:** `zip 7z rar gz tar bz2 xz cab iso tgz`

---

## Цвета файлов

| Цвет | Тип |
|------|-----|
| Голубой (Cyan) | Исполняемые (.exe .bat .ps1...) |
| Зелёный | Текстовые (.txt .log .ini...) |
| Синий | Медиа (.mp4 .jpg .mp3...) |
| Фиолетовый | APK пакеты |
| Ярко-зелёный | Архивы (.zip .7z .rar...) |
| Белый | Папки |
| Жёлтый | Отмеченные элементы |
| Серый | Остальные файлы |

---

## Подсветка синтаксиса (редактор)

| Формат | Что подсвечивается |
|--------|-------------------|
| `.ps1` | Ключевые слова, `$переменные`, строки, `#комментарии`, операторы |
| `.bat` `.cmd` | `rem`/`::`, `echo`, `%переменные%`, ключевые слова |
| `.sh` `.bash` | Аналогично ps1 |
| `.ini` `.cfg` `.conf` | `[секции]`, `ключ=`, `=значение`, `;комментарии` |
| `.log` `.nfo` | ERROR (красный), WARN (оранжевый), INFO (зелёный), DEBUG (серый) |

Максимум строк для подсветки: 3000 (для производительности).

---

## Предпросмотр медиа (Android)

Двойной клик на видео/изображении/аудио в панели Android — файл скачивается во `%TEMP%` и открывается системным приложением по умолчанию.
Файлы размером более **500 МБ** требуют подтверждения.

---

## Примечания

- Пути с пробелами и спецсимволами `[]` поддерживаются полностью
- Кириллические имена файлов в архивах поддерживаются
- Статус подключения ADB обновляется каждые 3 секунды
- Копирование в той же панели: PC→PC через `Copy-Item`, Android→Android через `adb shell cp`
- Файл `$null` в папке скрипта не создаётся (исправлено перенаправление stderr)

---

## Ссылки

- **GitHub / Документация:** https://github.com/Varsett/ADBFileManager
- **Скачать ADB Tools:** https://developer.android.com/tools/releases/platform-tools
- **Скачать 7-Zip:** https://www.7-zip.org/download.html

---

*(c) 2026 Varset — Часть инструментария QUAS*

---

---
# Quas ADB Commander
**Dual-panel file manager for Meta Quest / Android devices via ADB**

Part of the [QUAS](https://github.com/Varsett/ADBFileManager) toolkit.

---

## Features

- Dual-panel interface: PC (left) and Android (right)
- Browse, copy, move, rename, delete files on both sides
- Built-in text/script editor with syntax highlighting
- Archive support (7z, zip, rar, gz, tar...) via 7z.exe
- APK installation with automatic OBB copying
- Media preview for Android files (video, photo, audio)
- Search with wildcard support
- File marking and batch operations
- Dark theme with colored file types

---

## Requirements

- Windows 10/11
- PowerShell 5.1
- `adb.exe` (Android Debug Bridge)
- USB debugging enabled on your Quest/Android device
- **Optional:** `aapt2.exe` — APK package name detection
- **Optional:** `7z.exe` + `7z.dll` — archive support

---

## Installation

1. Place `adbfm.ps1` anywhere on your PC
2. Put `adb.exe`, `aapt2.exe`, `7z.exe`, `7z.dll` in the **same folder**
   - or use `-ToolsPath` parameter
   - or add to `%PATH%`
   - or set `%myfiles%` environment variable
3. Connect your Quest/Android device via USB with USB Debugging enabled

---

## Launch

```batch
powershell -ExecutionPolicy Bypass -File adbfm.ps1
```

With parameters:
```batch
powershell -ExecutionPolicy Bypass -File adbfm.ps1 -ToolsPath "C:\Tools" -WorkDir "D:\Temp"
```

Recommended batch file launcher:
```batch
set toolspath=%~dp0
set workdir=%TEMP%
powershell -ExecutionPolicy Bypass -File "%~dp0adbfm.ps1" -ToolsPath "%toolspath%" -WorkDir "%workdir%"
```

---

## Launch Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ToolsPath` | Folder with `adb.exe`, `aapt2.exe`, `7z.exe` | Script folder |
| `-WorkDir` | Temp folder for archive operations | `%TEMP%` |

---

## Keyboard Shortcuts

### Navigation
| Key | Action |
|-----|--------|
| `Tab` | Switch active panel |
| `Enter` / Double-click | Open folder / Run file / Enter archive |
| `Space` | Toggle mark (yellow highlight) |
| `*` (Numpad) | Mark ALL / Unmark ALL (toggle) |
| `Alt+X` | Exit |
| `F9` | Jump to Android/data |
| `F10` | Jump to Android/obb |

### File Operations
| Key | Action |
|-----|--------|
| `F2` | Rename |
| `F3` | Search (wildcard `*` supported) |
| `F4` | Open in built-in editor |
| `F5` | Copy to opposite panel / Extract from archive |
| `F6` | Move / Rename |
| `F7` | Create new folder |
| `F8` / `Delete` | Delete selected items |

### Editor
| Key | Action |
|-----|--------|
| `Ctrl+S` / `F2` | Save file |
| `Esc` | Close (prompts if unsaved) |
| Wrap button | Toggle word wrap |

---

## Context Menu (Right Click)

| Option | Description |
|--------|-------------|
| Run | Execute file (PC only) |
| Edit (built-in) | Open in built-in editor |
| Edit (pull-edit-push) | Pull from Android, edit, push back |
| Open with default | Open with system app |
| Install APK | Install APK + auto-copy OBB |
| Copy | Mark + copy to system clipboard |
| Paste | Paste (all directions: PC↔ADB, PC→PC, ADB→ADB) |
| Unpack archive | Extract archive to PC or Android |
| Pack selected | Pack marked items to `.7z` |

---

## Archive Support

Open archives by double-clicking or Enter — they appear as virtual folders.

**Inside an archive:**

| Action | Result |
|--------|--------|
| `F4` on file | Open text/script in editor |
| `F5` (files marked) | Extract files flat (no folder structure) |
| `F5` (folder marked) | Extract folder with its contents |
| `*` then `F5` | Mark all + extract everything |
| `[Close Archive]` | Exit archive or go up one level |

**Context menu on archive file:**
- **Unpack archive** — extract ALL to chosen PC path (editable) or current Android folder (named after archive)
- **Pack selected** — pack marked items to `.7z` in current folder

**Supported:** `zip 7z rar gz tar bz2 xz cab iso tgz`

---

## File Colors

| Color | Type |
|-------|------|
| Cyan | Executables (.exe .bat .ps1...) |
| Green | Text files (.txt .log .ini...) |
| Blue | Media (.mp4 .jpg .mp3...) |
| Purple | APK packages |
| Bright Green | Archives (.zip .7z .rar...) |
| White | Directories |
| Yellow | Marked items |
| Gray | Other |

---

## Syntax Highlighting (Editor)

| Format | Highlighted |
|--------|-------------|
| `.ps1` | Keywords, `$variables`, strings, `#comments`, operators |
| `.bat` `.cmd` | `rem`/`::`, `echo`, `%variables%`, keywords |
| `.sh` `.bash` | Similar to ps1 |
| `.ini` `.cfg` `.conf` | `[sections]`, `key=value`, `;comments` |
| `.log` `.nfo` | ERROR (red), WARN (orange), INFO (green), DEBUG (gray) |

---

## Media Preview (Android)

Double-click video/image/audio on the Android panel to pull and open with system default app.
Files over **500 MB** require confirmation.

---

## Notes

- Paths with spaces and special characters `[]` are fully supported
- Cyrillic filenames in archives are supported
- ADB connection status updates every 3 seconds
- Same-side copy: PC→PC via `Copy-Item`, ADB→ADB via `adb shell cp`

---

## Links

- **GitHub / Documentation:** https://github.com/Varsett/ADBFileManager
- **ADB Tools:** https://developer.android.com/tools/releases/platform-tools
- **7-Zip:** https://www.7-zip.org/download.html

---

*(c) 2026 Varset — Part of QUAS toolkit*