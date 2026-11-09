tasknotes 现在只管一次性的任务，我要它管周期性的事：

- `add` 加 `--repeat weekly|monthly`，必须同时给 `--due`；日期要真实存在（2026-02-30 这种直接报错退出）。没给 repeat 的还跟现在一样。
- 新命令 `agenda`：列出今天到期和已经过期的未完成任务，按 due 从早到晚排。行格式跟 list 一样，过期的在行尾再加 ` (overdue)`。`agenda --json` 输出数组，每项 `{"id":…,"title":…,"due":…,"repeat":…,"overdue":…}`，没有 repeat 就是 null，overdue 是布尔。
- `done` 一个重复任务时不要标完成，而是把它推到下一次：weekly 加 7 天；monthly 保持原来的日号，短月用月末，下个月恢复原日号（1/31 → 2/28 → 3/31）。如果推出来的日期还是早于今天，就继续往后推，直到不早于今天。
- list 里重复任务在行尾显示 ` (repeats weekly)` 或 ` (repeats monthly)`。
- 老文件里没有 due / repeat 字段的任务照常读写。测试补上。
