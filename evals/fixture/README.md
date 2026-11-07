# tasknotes

A tiny command-line todo list. Tasks live in `tasks.json` in the current directory, or in the file named by `TASKNOTES_FILE`.

```sh
tasknotes add "Buy milk" --due 2026-11-10
tasknotes list
tasknotes done 1
tasknotes rm 1
```

Run the tests with `npm test`.
