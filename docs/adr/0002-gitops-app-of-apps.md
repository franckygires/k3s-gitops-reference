# 0002: Argo CD, app of apps, ordered by sync wave

## Constraint

Every change must be reviewable, repeatable and reversible, and the whole platform must be rebuildable from nothing. Components depend on each other: a database cannot be declared before the operator that understands it is running.

## Decision

Argo CD is installed by a script, and is the last thing installed that way. It reads `gitops/apps`, a Helm chart that renders one Application per component. Applications are grouped in four sync waves:

| Wave | Content | Why here |
|---|---|---|
| 0 | cert-manager, CloudNativePG, External Secrets, Vault | Operators and their CRDs |
| 1 | Certificate issuers, secret store | Need the CRDs from wave 0 |
| 2 | PostgreSQL | Needs credentials from the secret store |
| 3 | API, ingress, network policies | Needs the database |

Every Application syncs automatically, prunes what was removed from Git, and reverts manual changes.

Argo CD does not consider an Application's health by default, which makes waves between Applications meaningless. `bootstrap/argocd-values.yaml` restores that health check so that each wave really waits for the previous one.

## Consequence

- Bootstrap order is explicit and lives in Git, instead of being a sequence of commands someone remembers.
- A manual `kubectl edit` in production does not last. That is the point, and it has to be accepted by everyone who operates the platform.
- Argo CD itself is not managed by Argo CD here. Upgrading it means changing `versions.env` and running `make up`.
