const store = require('./store');
const { addTask, completeTask, removeTask } = require('./tasks');

const USAGE = `Usage:
  tasknotes add <title> [--due YYYY-MM-DD]
  tasknotes list
  tasknotes done <id>
  tasknotes rm <id>`;

function formatTask(task) {
  const box = task.done ? '[x]' : '[ ]';
  const due = task.due ? ` (due ${task.due})` : '';
  return `${box} ${task.id} ${task.title}${due}`;
}

function parseAdd(args) {
  const words = [];
  let due = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--due') {
      due = args[++i];
      if (!/^\d{4}-\d{2}-\d{2}$/.test(due || '')) {
        throw new Error('--due expects a date like 2026-01-31');
      }
    } else {
      words.push(args[i]);
    }
  }
  const title = words.join(' ').trim();
  if (!title) throw new Error('add needs a title');
  return { title, due };
}

function parseId(arg) {
  const id = Number(arg);
  if (!Number.isInteger(id) || id < 1) throw new Error(`Not a task id: ${arg}`);
  return id;
}

function run(command, args) {
  const file = store.defaultFile();
  const tasks = store.load(file);

  switch (command) {
    case 'add': {
      const next = addTask(tasks, parseAdd(args));
      store.save(file, next);
      console.log(`Added ${formatTask(next[next.length - 1])}`);
      return;
    }
    case 'list': {
      if (tasks.length === 0) {
        console.log('Nothing to do.');
        return;
      }
      for (const task of tasks) console.log(formatTask(task));
      return;
    }
    case 'done': {
      const id = parseId(args[0]);
      store.save(file, completeTask(tasks, id));
      console.log(`Completed ${id}`);
      return;
    }
    case 'rm': {
      const id = parseId(args[0]);
      store.save(file, removeTask(tasks, id));
      console.log(`Removed ${id}`);
      return;
    }
    default:
      throw new Error(USAGE);
  }
}

function main(argv) {
  const [command, ...args] = argv;
  try {
    run(command, args);
  } catch (err) {
    console.error(err.message);
    process.exitCode = 1;
  }
}

module.exports = { main, formatTask };
