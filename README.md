# builtbystef/skills

Skills that I use daily for software development with coding agents. They drive a simple pipeline: plan → spec → issues → implement → review. They are based on [Matt Pocock's skills](https://github.com/mattpocock/skills). See [Credits](#credits).

## Installation

Install all skills directly from this GitHub repository:

```bash
npx skills add builtbystef/skills
```

To inspect the available skills first:

```bash
npx skills add builtbystef/skills --list
```

Or install a specific skill:

```bash
npx skills add builtbystef/skills --skill set-up-sandbox
```

## Skills

| Skill                                                 | Purpose                                                            | Invoked by   |
| ----------------------------------------------------- | ------------------------------------------------------------------ | ------------ |
| [set-up-for-agents](set-up-for-agents/SKILL.md)       | Create `docs/` and the tracker doc                                 | User         |
| [set-up-sandbox](set-up-sandbox/SKILL.md)             | Set up native, OS-enforced sandboxing for agent sessions           | User         |
| [create-plan](create-plan/SKILL.md)                   | Interview until a goal is planned, or create a roadmap DAG         | User         |
| [advance-plan](advance-plan/SKILL.md)                 | Advance a roadmap by one node; extend the DAG as it becomes sharp  | User         |
| [grill-me](grill-me/SKILL.md)                         | Stress-test a plan or design, in rounds of questions               | User & model |
| [create-specification](create-specification/SKILL.md) | Turn the session's planning context into a spec issue              | User         |
| [create-issues](create-issues/SKILL.md)               | Break a spec issue into small, ordered sub-issues                  | User         |
| [implement](implement/SKILL.md)                       | Complete one issue from start to end, tests first                  | User         |
| [implement-loop](implement-loop/SKILL.md)             | Drive a queue of issues to done, one fresh session for each issue  | User         |
| [maintain-codebase](maintain-codebase/SKILL.md)       | Audit the codebase for rot; file the findings as issues            | User         |
| [handoff](handoff/SKILL.md)                           | Compact the session into a file that a fresh session continues from | User        |
| [test](test/SKILL.md)                                 | TDD reference: good tests, seams, red → green rules                | User & model |
| [review-code](review-code/SKILL.md)                   | Review a diff against the spec and the coding standards            | User & model |
| [research](research/SKILL.md)                         | Answer a question from primary sources, with citations             | User & model |
| [prototype](prototype/SKILL.md)                       | Disposable code that answers a design question                     | User & model |

## Additional Information

Skill instructions use host-neutral wording. Invoke a skill by name, or use the host's explicit syntax when passing arguments:

```text
Claude Code: /implement ISSUE-123
Codex CLI: $implement ISSUE-123
```

## Credits

This collection is largely based on [Matt Pocock's skills repository](https://github.com/mattpocock/skills), adjusted to my own workflow.

The core ideas are his: the agent asks questions until both sides agree on the task; feedback loops stay fast; tests come first; and architecture must not rot.

## License

MIT License: see [LICENSE](LICENSE). Portions derive from Matt Pocock's MIT-licensed skills repository, and his copyright notice stays in the license file.
