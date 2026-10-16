# Crystal 1.21.1: SIGSEGV в once-campfire-crails — форензика

Сегфолт-баг, найденный в once-campfire-crails (parity-сьют capybara-tests).
Этот каталог — материалы для репорта в crystal-lang/crystal (и/или в
кристальные шарды db/active_record_cr).

## Статус

**Минимальный автономный repro ещё НЕ получен.** Проверенные синтетики
(`repro.cr`, итерации v1–v3: churn фибер + Channel/select/timeout + GC
давление + HTTP-сервер с обрывающимися клиентами + пул SQLite с WAL)
не крашатся по 4×120 с, тогда как приложение падает за 20–40 с.
Работающий воспроизводитель на сегодня — приложение целиком (см. ниже).

## Приложение-репродюсер (надёжный)

```bash
git clone <crails-repo> && cd once-campfire-crails/capybara-tests
PARITY_KEEP=1 TARGET=crails bin/run -n /LiveTest/
```

Краш (signal 11) в 1–2 прогонах (под gdb — в каждом прогоне, см. ниже).
Сервер поднимается сам (`bin/app`, сборка
`crystal build --release -Dwithout_mt src/app.cr`). Окружение:
Crystal 1.21.1, Linux x86_64, Ubuntu (libsqlite3 3.50-series).

## Механизм (по состоянию на 2026-10-16, раунд «где конкретно»)

Под gdb (ASLR off) краш **полностью детерминирован**: каждый прогон,
одинаковые регистры, стабильный оффсет жертвы от вершины стек-региона
(`top-0xAE18`); меняется только абсолютный адрес mmap-региона.

Финальная сигнатура краша:

- rip = entry+14 виртуального метода
  `DB::Statement#exec:args<Array(Int64)>` (bin+0x265af0);
  первая же инструкция `mov 0x4(%rsi),%r15d` читает адрес **0x5** —
  это и есть «fault address 0x5»: rsi=1.
- Полностью мусорный контекст: rsi=1, rbp=r15=0x29, r12=0, rdx=-17,
  r8/r9 — хэш-подобный мусор; под rsp **нет return address**
  ([rsp] = указатель на тот же стек) → в функцию вошли НЕ через call.
- Сигнатура стабильна между прогонами, rdi=rbx=0x555555a93f48.

### Что доказано экспериментально (раунд 2026-10-16)

1. **Старая теория «мусорный ret в swapcontext» опровергнута.**
   Условный bp на `ret` в `Fiber::swapcontext` (bin+0x72e0a) с
   python-фильтром «цель ret ∉ .text» прогнал ~2000 resume за прогон —
   все без исключения корректны (initial-resume: rsp=first_addressable
   = top-0x10 региона, цель = thunk fiber_main, rdi=Fiber). Ни одного
   плохого resume не наблюдалось, включая прогон, завершившийся крашем.
2. **Вход в `exec:args` произошёл не через call/jmp по значению из
   памяти.** Значение-цель `0x5555557b9af0` (entry) отсутствует
   ВО ВСЕЙ памяти процесса на момент краша: Boehm-кучи, malloc-арены,
   RELRO/rodata бинаря (статически relocated-слотов тоже нет —
   `readelf -r` без релокаций с таким addend), все стеки фибер,
   sqlite3-shm. Ни один регистр его не держит. → Переход был
   **вычисленным**, значение нигде не материализовано.
   Главные кандидаты: landing pad libunwind (адрес считается из
   DWARF-offset'ов при unwind исключения Crystal) либо другой
   контекстно-восстанавливающий механизм.
3. **`sqlite3_close` не вызывался ни разу** до краша (PLT-лог с
   ring-буфером) — «закрытие соединения при живом statement» отпадает.
4. **`sqlite3WalSavepointUndo` в падавшем процессе не выполнялся**
   (bp на entry, взведён до краша) — кадр libsqlite3 на стеке жертвы
   (return 0x11a15d в `sqlite3OsShmBarrier`-сайт) — stale-мусор от
   предыдущего исполнения этого стек-региона.
5. «sqlite3_file» по rdi и его «pMethods» — **сироты**: ни одна ячейка
   памяти процесса на них не ссылается (полный скан держателей).
6. Стек-регион жертвы рециклирован; на нём stale-кадры предыдущих
   исполнений: `RoomsController#destroy` → `ActiveRecord::Base.__current_tx`
   (bin+0x265ae5 — return после `call __current_tx` в конце
   *RoomsController#destroy), `DB::PoolStatement#exec`
   (pool_statement.cr:19), `select_impl` (channel/select.cr:102),
   `GC_malloc_kind`, `Thread::current`/`current_fiber`.
7. За прогон всего 3 исключения (`unexpected_char`, обрабатываются) —
   прямой корреляции с крашем нет, но unwind-механизм остаётся
   главным кандидатом источника вычисленного прыжка (см. п.2).

### Рабочая гипотеза

Исполнение продолжается на рециклированном стеке с полностью
восстановленным из мусора контекстом (регистры+rip вычислены
механизмом, не оставляющим значения в памяти — как unwind/longjmp).
Триггер — в базовом HTTP-пути запроса (request fiber + AR/crystal-db
пул + middleware) при churn'е соединений.

## Что исключено bisect'ом приложения (краш остаётся)

- пул соединений sqlite (`max_pool_size=1` и 5/5);
- fair_busy usleep-хендлер (пересборка без него);
- jobs-воркеры (`JOB_CONCURRENCY=0`);
- Action Cable целиком (WS-хендлер → call_next);
- ping-loop кабеля;
- WriteQueue (writer-фибера + замыкания в стек паркованных фибер);
- libc-overflow (`MALLOC_CHECK_=3` молчит), REGEXP-колбэк sqlite;
- `sqlite3_close` при живом statement (лог PLT — вызовов нет).

## Инструментарий

- `bpx.py` (этот каталог) — адаптивный gdb-python-скрипт:
  - ловля SIGSEGV post-mortem с дампами;
  - фильтрованный bp «плохой resume» (ret в swapcontext);
  - фильтрованный bp на entry `exec:args` (ловит мусорный вход
    ДО падения) — с него основной дамп;
  - PLT-лог `sqlite3_close`, ring-лог `__crystal_raise`;
  - сканы держателей значений по всей памяти (кучи/арены/RELRO/
    стеки/shm).
  Использование: `bin/app` → `exec gdb -q -batch -x <path>/bpx.py
  --args <release-binary> "$@"`; дампы пишутся в `/tmp/segv-dump-<pid>.txt`
  (per-PID: харнесс перезапускает сервер и затирает общий файл).
- `dumps/bad-exec-entry.txt` — эталонный дамп мусорного входа.

## История расследования (сжато)

- Раунд 1: бинарные дампы, формула региона (частично неверна —
  вершины mmap-регионов НЕ выровнены на 8MiB, регион надо брать из
  /proc/maps). Вывод «resume мёртвой фиберы» — опровергнут в раунде 3.
- Раунд 2 (python-bp): «новая подпись unix/fiber.cr:11» оказалась
  ложным срабатыванием на первом легитимном resume (условие bp матчило
  почти все resume; gdb-условия с разыменованием `*(unsigned long*)$rsp`
  в spec-строке python-Breakpoint не применяются — вешать через
  `.condition` или фильтровать в `stop()`).
- Раунд 3 (текущий): см. «Что доказано».

## Дальше

1. Ловить вычисленный переход: bp на `_Unwind_RaiseException` /
   landing-pad трапы; либо catchpoint на `SIGSEGV` с анализом
   `$rax`-цепочки в момент падения (rdi→[rdi]→…: rax ≠ [rdi] на
   мусорном entry — «thunk OsShmBarrier» отпадает окончательно).
2. Проверить многопоточность процесса на момент краша (`info threads`) —
   возможна гонка второго потока, затирающего источник перехода между
   прыжком и остановкой.
3. Autonomный repro: ингредиенты-кандидаты — crystal-db retry-семантика
   после ошибок, middleware railties_cr, nodelay accept-loop,
   исключения в select/каналах на рециклированном стеке.
