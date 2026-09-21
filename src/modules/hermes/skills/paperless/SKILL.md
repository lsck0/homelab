---
name: paperless
description: Search, tag and manage documents in Paperless.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Paperless, Documents]
    related_skills: [homelab-ops, bills]
---

# Paperless-ngx (vm-121, http://10.100.0.121:8080, https://paperless.lsck0.dev)

Header: `Authorization: Token $(lab-token paperless-key)`. API docs: `/api/schema/view/`.

- Search: `GET /api/documents/?query=<full text>&page_size=10` (fields: id, title, created, correspondent, tags).
- Content (OCR text): `GET /api/documents/<id>/` -> `.content`.
- Download: `GET /api/documents/<id>/download/` (original) or `/preview/`.
- Upload: `POST /api/documents/post_document/` multipart `document=@file`, optional `title`, `created`,
  `correspondent`, `document_type`, `tags` (ids). Returns a task id; poll `GET /api/tasks/?task_id=<id>`.
- Metadata: `GET/POST /api/tags/`, `/api/correspondents/`, `/api/document_types/`;
  update a document `PATCH /api/documents/<id>/ {"tags":[..], "correspondent":<id>}`.
- Bulk: `POST /api/documents/bulk_edit/ {"documents":[ids], "method":"add_tag", "parameters":{"tag":<id>}}`.
- Files dropped into the NAS `documents` share are consumed automatically (polled every 30 s).
- Send the owner a document: download it and attach it in Telegram.

Bills -> also book them in Firefly: skill `bills`.
