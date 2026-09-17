---
name: bills
description: File a bill in Paperless and book it in Firefly III.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Finance, Paperless, Firefly]
    related_skills: [homelab-ops]
---

# Bills and receipts

When the owner sends a photo or PDF of a bill, invoice or receipt: store the
document in Paperless, then record the payment in Firefly III, then reply with
a one-line summary (payee, amount, date, links).

## 1. Read the document

- Image: use `vision_analyze` on the attachment.
- PDF: `pdftotext <file> -` via `terminal`; for scans, render a page with
  `pdftoppm -png -r 150 -f 1 -l 1 <file> /tmp/page` and use `vision_analyze`.
Extract: payee/vendor, total amount, currency, invoice date, due date,
invoice number, short description, and a category guess (Groceries, Rent,
Utilities, Insurance, Subscriptions, ...). If the total is unreadable, ask.

## 2. Upload to Paperless (vm-120)

```
curl -sf -H "Authorization: Token $(lab-token paperless-key)" \
  -F document=@<file> -F title="<Payee> <YYYY-MM-DD> <amount> <currency>" \
  -F created=<YYYY-MM-DD> \
  http://10.100.0.120:8080/api/documents/post_document/
```
The reply is a task UUID. Poll
`GET http://10.100.0.120:8080/api/tasks/?task_id=<uuid>` until `status` is
`SUCCESS`; `related_document` is the document id. Link:
`https://paperless.lsck0.dev/documents/<id>/details`. Optionally set tags /
correspondent with `PATCH /api/documents/<id>/`.

## 3. Book it in Firefly III (vm-123, on demand)

1. `vm start 123`, then wait until `curl -s -o /dev/null http://10.100.0.123:8080/` answers.
2. Token: `lab-token firefly-token`. If it does not exist, the owner has not
   registered in Firefly yet (https://firefly.lsck0.dev); tell them and stop here.
3. Asset account to pay from: `GET /api/v1/accounts?type=asset`, use the
   default/first one unless the bill says otherwise.
4. Create the transaction:
```
curl -sf -X POST http://10.100.0.123:8080/api/v1/transactions \
  -H "Authorization: Bearer $(lab-token firefly-token)" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"transactions":[{"type":"withdrawal","date":"<YYYY-MM-DD>","amount":"<12.34>",
       "currency_code":"<EUR>","description":"<Payee>: <short description>",
       "source_id":"<asset account id>","destination_name":"<Payee>",
       "category_name":"<Category>","notes":"Paperless: https://paperless.lsck0.dev/documents/<id>/details",
       "external_url":"https://paperless.lsck0.dev/documents/<id>/details"}]}'
```
For an unpaid invoice with a future due date, still book it on the due date
and say so. Link: `https://firefly.lsck0.dev/transactions/show/<journal id>`.
