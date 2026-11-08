# 🧰 Hermes skills (shipped as ConfigMaps)

Skills that Hermes loads from `skills.external_dirs` (`/opt/skills`, see [`../config.yaml`](../config.yaml)). Each skill
is packed into a ConfigMap by [`../kustomization.yaml`](../kustomization.yaml) and mounted read-only into both
containers by [`../deployment.yaml`](../deployment.yaml). Only `SKILL.md` and the scripts are shipped: any other
`.md` file in a skill directory would become part of the skill's content, so the READMEs here stay in Git only.

| Skill | What it does (one line) |
|---|---|
| [`grafana-tempo-observability/`](grafana-tempo-observability/README.md) | Read-only Prometheus, Tempo and Grafana access: `diagnose` ranks suggested issues with evidence, root cause, file, fix and Grafana links |
