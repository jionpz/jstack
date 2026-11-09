# tasknotes conventions

## Order of `tasknotes list`

`tasknotes list` prints tasks in this order. The keys are compared in sequence:

1. Open tasks come before completed tasks.
2. Within a group, tasks with a due date come first, earliest date first.
3. Tasks without a due date come after the dated ones in the same group.
4. Tasks that compare equal keep the order they were added (stable sort).
