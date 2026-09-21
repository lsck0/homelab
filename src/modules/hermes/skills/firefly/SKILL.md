---
name: firefly
description: Query and edit finances in Firefly III.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Firefly, Finance]
    related_skills: [homelab-ops, bills]
---

# Firefly III (vm-124, on demand, http://10.100.0.124:8080, https://firefly.lsck0.dev)

Before any call: `vm start 123` and wait for HTTP. Headers:
`Authorization: Bearer $(lab-token firefly-token)`, `Accept: application/json`,
`Content-Type: application/json`. API base `/api/v1`.

- Accounts: `GET /accounts?type=asset` (balances in `current_balance`), `type=expense|revenue|liabilities`.
- Transactions: `GET /transactions?start=YYYY-MM-DD&end=YYYY-MM-DD&type=withdrawal`;
  create `POST /transactions` (see `bills`); edit `PUT /transactions/<id>`; delete `DELETE /transactions/<id>`.
- Spending summary: `GET /insight/expense/category?start=..&end=..` and `/insight/expense/expense` (per payee);
  `GET /summary/basic?start=..&end=..`.
- Budgets: `GET /budgets`, limits `GET /budgets/<id>/limits`; create `POST /budgets {"name":...}`.
- Categories/tags: `GET /categories`, `GET /tags`.
- Recurring: `GET /recurrences`; bills (subscriptions): `GET /bills`.

Answer money questions with exact numbers and the period used. If the token
file is missing, the owner has not registered in Firefly yet.
