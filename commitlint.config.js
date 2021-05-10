module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [1, 'always', ['feat', 'fix', 'refactor', 'perf', 'docs', 'style', 'test', 'chore', 'ci']],
    'scope-case': [2, 'always', ['camel-case', 'pascal-case', 'lowercase']]
  }
}
