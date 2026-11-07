const test = require('node:test');
const assert = require('node:assert');
const { addTask, completeTask, removeTask } = require('../src/tasks');

test('addTask numbers tasks from 1', () => {
  const tasks = addTask(addTask([], { title: 'Buy milk' }), { title: 'Call mom', due: '2026-11-10' });
  assert.deepStrictEqual(tasks, [
    { id: 1, title: 'Buy milk', done: false, due: null },
    { id: 2, title: 'Call mom', done: false, due: '2026-11-10' },
  ]);
});

test('addTask continues after the highest id', () => {
  const tasks = addTask([{ id: 7, title: 'Old', done: true, due: null }], { title: 'New' });
  assert.strictEqual(tasks[1].id, 8);
});

test('completeTask marks only the matching task', () => {
  const tasks = completeTask(addTask(addTask([], { title: 'A' }), { title: 'B' }), 2);
  assert.deepStrictEqual(tasks.map((t) => t.done), [false, true]);
});

test('removeTask drops the matching task', () => {
  const tasks = removeTask(addTask(addTask([], { title: 'A' }), { title: 'B' }), 1);
  assert.deepStrictEqual(tasks.map((t) => t.title), ['B']);
});

test('unknown ids are rejected', () => {
  assert.throws(() => completeTask([], 3), /No task with id 3/);
  assert.throws(() => removeTask([], 3), /No task with id 3/);
});
