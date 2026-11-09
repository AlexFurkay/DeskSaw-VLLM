# Авторы и права / Credits

**DeskSaw VLLM** ("Version with LLM") — некоммерческий фанатский проект AlexFurkay (Alexander Furkay), бесплатный.
Он основан на **DeskSaw** от **DeeDee14** — https://github.com/dee-dee-catorce/desksaw (лицензия MIT; автор разрешает форки).
Буквы «DD» в имени папки данных (`DDnAKFRK`) и в подписи на иконке — в честь DeeDee14.

## Код

| Что | Автор | Лицензия |
|---|---|---|
| DeskSaw (оригинал) | DeeDee14 | MIT |
| DeskSaw VLLM: ИИ-персонажи, разговоры, механики, интерфейс | AlexFurkay | MIT (см. `LICENSE`) |
| Godot Engine 4.7 | Juan Linietsky, Ariel Manzur и контрибьюторы | MIT |
| godot-console (`addons/godot-console`) | Mansur Isaev и контрибьюторы | MIT |
| godot-rapier2d (`addons/godot-rapier2d`) | Fabrice Cipolla, Sp3ctralCat, Dragos Daian | MIT |
| SoupIK (`addons/soupik`) | ZedManul | MIT |
| Rapier (физический движок внутри godot-rapier2d) | Dimforge | Apache 2.0 |
| .NET (среда для C#-скриптов, встроена в сборку) | .NET Foundation и Microsoft | MIT |

## Персонажи, рисунки и звуки (НЕ MIT)

Лицензия MIT в этом репозитории распространяется **только на код**. Персонажи, их внешность, рисунки, звуки и предметы
принадлежат своим авторам и используются с их разрешения, в некоммерческом фанатском проекте:

- **Персонажи (савиане), их рисунки и голоса** — из игры **Gunsaw** и **Casualties: Unknown** (авторы — Orsonik, https://orsonik.itch.io, и Moffee).
  Автор не против их использования в DeskSaw VLLM.
- **Предметы** (еда, аптечки, мебель и др.) — по большей части из **Casualties: Unknown**
  (https://casualtiesunknown.miraheze.org/wiki/).
- Базовый персонаж Experiment и графика оригинального DeskSaw — DeeDee14 / Gunsaw.

Их нельзя продавать или использовать в коммерческих целях. Если вы автор и хотите, чтобы что-то было убрано или подписано
иначе, — напишите, исправлю.

## Шрифты

| Шрифт | Автор | Лицензия |
|---|---|---|
| Retro Gaming Extended | Vasily Draigo (Daymarius), изменения Ivan Stoilov и Azurian | бесплатный шрифт (pixel-forge.com) |
| Liberation Mono, Liberation Sans | Red Hat | SIL Open Font License 1.1 |
| Open Sans | Steve Matteson / Google | Apache 2.0 |

## ИИ-модели (не входят в сборку)

Игра не содержит моделей: их скачивает сам игрок через **Ollama** (https://ollama.com, MIT).
Рекомендуемые модели — **qwen3-vl:8b-instruct** (Alibaba Qwen, Apache 2.0) и **gemma4:12b** (Google, Apache 2.0).
Скриншоты экрана передаются только локальной модели на твоём компьютере и никуда не отправляются.

## Статистика запусков

При запуске игра отправляет на счётчик **GoatCounter** (https://www.goatcounter.com) одну анонимную отметку: версию игры и название модели ИИ.
Ни имени, ни данных компьютера, ни того, что происходит в игре. Отключается в Настройки → Общее.
