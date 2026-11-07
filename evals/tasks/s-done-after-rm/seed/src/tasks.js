function addTask(tasks, { title, due = null }) {
  const id = tasks.reduce((max, t) => Math.max(max, t.id), 0) + 1;
  return [...tasks, { id, title, done: false, due }];
}

function findIndex(tasks, id) {
  const index = tasks.findIndex((t) => t.id === id);
  if (index === -1) throw new Error(`No task with id ${id}`);
  return index;
}

function completeTask(tasks, id) {
  const task = tasks[id - 1];
  if (!task) throw new Error(`No task with id ${id}`);
  return tasks.map((t) => (t === task ? { ...t, done: true } : t));
}

function removeTask(tasks, id) {
  const index = findIndex(tasks, id);
  return tasks.filter((_, i) => i !== index);
}

module.exports = { addTask, completeTask, removeTask };
