# Donor Thank You

Personalised thank-you pages and adoption certificates for donors, reached through permanent private links.

## Language

**Donor Message**:
One personalised thank-you, with its own Donor Link. A repeat donor has one for each thank-you.
_Avoid_: Donor, donor page, donor record

**Donor Token**:
The secret value that identifies one Donor Message. It never changes.
_Avoid_: Donor ID, hash

**Donor Link**:
The full, permanent address of a Donor Message, as written onto NFC tags.
_Avoid_: Donor URL, thank-you link

**Generic Thank-You**:
The content shown when a Donor Link is missing or invalid.
_Avoid_: Default message, fallback page

**Certificate**:
The adoption certificate PDF belonging to a Donor Message.
_Avoid_: Attachment, file, document

**Reissue**:
A replacement Certificate for the same Donor Message. The Donor Link stays the same and the earlier Certificate is retained.
_Avoid_: Update, overwrite, re-upload

**External Reference**:
The identifier a donation platform gives a thank-you, which stops retries creating a second Donor Message.
_Avoid_: Donation ID, idempotency key
