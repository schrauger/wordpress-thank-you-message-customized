# wordpress-thank-you-message-customized

Personalised thank-you pages and adoption certificates for donors, reached through permanent private links. Terms used here are defined in [GLOSSARY.md](GLOSSARY.md).

A Donor Link looks like `<thank-you page path>?donorid=<token>`. Tokens and Donor Links never change, because they are written onto physical NFC tags.

## Certificates

- Certificates are private attachments, so they do not appear in the REST media API, attachment pages or other listings for anonymous visitors.
- The exact PDF URL stays public, because donors open it without logging in. The token in the filename makes it unguessable.
- Existing Certificates are protected automatically, once, after the plugin is updated. Only their status and meta change; files and URLs do not. `wp option get donor_thank_you_backfill_report` shows the result, and `unresolved` should be `0`.
- A PDF uploaded from a Donor Message edit screen becomes a Certificate. The token is added to its filename unless the filename already contains it. A PDF uploaded directly to the Media Library has no Donor Message to belong to, so it is left as an ordinary file.
- Certificates are hidden from the Media Library by default. A notice at the top of the Media Library lets each user show or hide them. They always appear in the media picker on a Donor Message edit screen.

## API

Base path: `/wp-json/donor-thank-you/v1`

| Route | Purpose |
|---|---|
| `POST /messages` | Create a Donor Message (multipart) |
| `GET /messages/{token}` | Fetch one |
| `PATCH` or `POST /messages/{token}` | Update `name` or `content` |
| `POST /messages/{token}/pdf` | Reissue the Certificate (multipart) |

`POST` is accepted for updates because some shared-host firewalls block `PATCH`. PHP only parses multipart bodies on `POST`, so send JSON with `PATCH`.

### Authentication

The API uses [Application Passwords](https://developer.wordpress.org/advanced-administration/security/application-passwords/) over HTTPS. Create one service account with the `donor_api_service` role, which holds only the API capability:

```sh
wp user create donor-api donor-api@example.org --role=donor_api_service
wp user application-password create donor-api "API client" --porcelain
```

Keep the password in the API client's credential store. Apache must pass the `Authorization` header through to PHP.

### Create

| Field | Required | Notes |
|---|---|---|
| `name` | Yes | The donor's name, used as the title |
| `pdf` | Yes | The Certificate |
| `filename_base` | Yes | Readable start of the filename, capped at 80 characters |
| `external_ref` | Yes | The External Reference, up to 191 characters |
| `content` | No | HTML placed above the certificate link |

```sh
curl -u 'donor-api:APPLICATION_PASSWORD' \
  -F 'name=DONOR NAME' \
  -F 'external_ref=platform:12345' \
  -F 'filename_base=Donor-Name-Adoption-Certificate' \
  -F 'pdf=@certificate.pdf;type=application/pdf' \
  https://example.org/wp-json/donor-thank-you/v1/messages
```

The response is `201` for a new Donor Message:

```json
{
  "id": 123,
  "token": "TOKEN",
  "page_url": "https://example.org/thank-you?donorid=TOKEN",
  "pdf_url": "https://example.org/wp-content/uploads/YYYY/MM/Donor-Name-Adoption-Certificate-TOKEN.pdf",
  "created": true
}
```

Retries are safe. A request repeating an `external_ref` returns the existing record with `200` and `"created": false`, ignores the rest of the payload, and never creates a duplicate. This holds even if the record was later trashed. New records publish immediately.

### Fetch

```sh
curl -u 'donor-api:APPLICATION_PASSWORD' \
  https://example.org/wp-json/donor-thank-you/v1/messages/TOKEN
```

`pdf_url` is `null` for an older record that does not have exactly one Certificate.

### Update

```sh
curl -u 'donor-api:APPLICATION_PASSWORD' -X PATCH \
  -H 'Content-Type: application/json' \
  -d '{"name":"NEW NAME","content":"<p>NEW CONTENT</p>"}' \
  https://example.org/wp-json/donor-thank-you/v1/messages/TOKEN
```

`content` replaces the text above the certificate link. The link itself is always kept.

### Reissue

```sh
curl -u 'donor-api:APPLICATION_PASSWORD' \
  -F 'pdf=@corrected.pdf;type=application/pdf' \
  https://example.org/wp-json/donor-thank-you/v1/messages/TOKEN/pdf
```

The new Certificate is named `<base>-<token>-r2.pdf`, then `-r3`, so browsers cannot serve a cached copy. Send `filename_base` to change the base; otherwise it comes from the current Certificate. The token and Donor Link do not change. The earlier Certificate is kept, unlinked, and still opens at its old URL.

### PDF rules

A file must start with `%PDF-`, be identified as a PDF from its content, and contain `%%EOF` near its end. The limit is 64 MB, adjustable with the `donor_thank_you_pdf_max_bytes` filter.

### Errors

| Status | Meaning |
|---|---|
| `400` | Missing or invalid field, or not a valid PDF |
| `401` / `403` | Not authenticated, or the account lacks the API capability |
| `404` | No Donor Message has this token |
| `409` | The filename is already taken, or an older record links two PDFs so the one to replace is ambiguous. Nothing changes |
| `413` | The PDF is over the size limit |
| `503` | Another request holds the lock; retry shortly |

## Tests

`tests/integration.sh` needs only bash, curl and WP-CLI. It runs against a local site with synthetic records, removes them afterwards, and refuses to run unless WordPress reports the environment type `local`.

```sh
WP_URL=http://localhost:8080 WP_CLI="wp --path=/path/to/site" tests/integration.sh
```

Pass slice names, such as `reissue`, to run part of the suite.
