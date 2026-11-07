const fs = require('node:fs');
const path = require('node:path');

function defaultFile() {
  return process.env.TASKNOTES_FILE || path.join(process.cwd(), 'tasks.json');
}

function load(file = defaultFile()) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return [];
  }
}

function save(file, tasks) {
  fs.writeFileSync(file, JSON.stringify(tasks, null, 2) + '\n');
}

module.exports = { defaultFile, load, save };
