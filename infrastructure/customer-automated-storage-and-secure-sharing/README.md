# Customer Automated Storage & Secure Sharing

Two-bucket solution for automated file storage and secure delivery via spreadsheet-triggered OTP verification.

## Architecture

```
Software (CBT/EMR/LIS)                    Staff uploads spreadsheet
         ↓                                        ↓
   Storage Bucket                          Delivery Bucket
   students/STU-100/                       secure-delivery-center/spreadsheet.csv
     neco_result.pdf                              ↓
     jamb_result.pdf                       S3 Trigger → Lambda
         ↑                                        ↓
         |                                 Matches Student ID to files
         └──── Lambda finds files ────→    Creates OTP invite
                                                  ↓
                                           Sends notification email
                                                  ↓
                                           Recipient clicks link
                                                  ↓
                                           OTP Verification Lambda
                                           (/start → WhatsApp OTP)
                                           (/verify → download file)
                                                  ↓
                                           Non-repudiation email
                                           sent to organization
```

## Two Buckets

### Storage Bucket
- Receives files from software via API or manual upload
- Organized by `{rootFolder}/{identifier}-{name}/{file_name}`
- No triggers — just secure storage
- Restricted access — only API/admins

### Delivery Bucket (Secure Delivery Center)
> **Secure Delivery Center** — the designated folder where staff uploads spreadsheets to trigger secure file delivery to recipients. This is Cloud Sentrics' standard naming convention across all customer deployments.

- Staff uploads spreadsheets to trigger delivery
- S3 trigger fires the file delivery Lambda
- 7-day auto-cleanup on spreadsheets
- Accessible to staff who handle delivery

## Customer Instructions

### Sending Results to Recipients

1. **Upload your spreadsheet** to the delivery bucket — same one every time
2. **New results come out?** — upload the same spreadsheet again. Only new results get sent automatically. Already-delivered results are skipped.
3. **Need to resend everything for a student?** — add `Resend=true` next to that student, upload, then remove it after
4. **Need to resend a specific file?** — add the file name in the Resend column (e.g., `neco_result_2026.pdf`), upload, then remove it after

### Spreadsheet Format

**CSV:**
```csv
RecipientName,RecipientEmail,RecipientPhone,ID
Mr Adeyemi,dad@email.com,+1234567890,STU-100
Mrs Bello,mum@email.com,+1987654321,STU-101
```

**JSON:**
```json
[
  {"RecipientName": "Mr Adeyemi", "RecipientEmail": "dad@email.com", "RecipientPhone": "+1234567890", "ID": "STU-100"},
  {"RecipientName": "Mrs Bello", "RecipientEmail": "mum@email.com", "RecipientPhone": "+1987654321", "ID": "STU-101"}
]
```

**Excel (.xlsx):** Same columns, upload directly from Excel.

### Resend Examples

**Normal delivery (only new files):**
```csv
RecipientName,RecipientEmail,RecipientPhone,ID
Mrs Afolabi,parent@email.com,+1234567890,STU-300
```

**Resend all files for one student:**
```csv
RecipientName,RecipientEmail,RecipientPhone,ID,Resend
Mrs Afolabi,parent@email.com,+1234567890,STU-300,true
Mr Balogun,parent2@email.com,+1987654321,STU-301
```
→ STU-300 gets all files resent. STU-301 gets only new files.

**Resend specific file:**
```csv
RecipientName,RecipientEmail,RecipientPhone,ID,Resend
Mrs Afolabi,parent@email.com,+1234567890,STU-300,neco_result_2026.pdf
```
→ Only the NECO result is resent for STU-300.

### How Tracking Works

- Each file delivered is recorded per student
- Uploading the same spreadsheet again = no duplicates
- New files added to a student's folder are automatically detected and delivered
- Example: Maths result delivered Monday. English result arrives Wednesday. Upload same spreadsheet → only English gets sent.

### Required Columns

| Column | Description | Required |
|---|---|---|
| Email | Recipient email (any variation: `RecipientEmail`, `Email`, `ParentEmail`, etc.) | Yes |
| Phone | Recipient phone E.164 (any variation: `RecipientPhone`, `Phone`, `Mobile`, etc.) | Yes |
| ID | Student/Patient/Client ID (any variation: `ID`, `StudentID`, `PatientID`, etc.) | Yes |
| Name | Recipient name (any variation: `RecipientName`, `Name`, `ParentName`, etc.) | No |
| Resend | `true` for all files, or specific filename. Leave empty for normal delivery. | No |

### Secondary Recipient

Both parents can receive the same results independently:

```csv
RecipientName,RecipientEmail,RecipientPhone,ID,SecondaryRecipientName,SecondaryRecipientEmail,SecondaryRecipientPhone
Mr Adeyemi,dad@email.com,+1234567890,STU-100,Mrs Adeyemi,mum@email.com,+1987654321
```

## Supported File Formats for Spreadsheet

- **CSV** (.csv)
- **JSON** (.json)
- **Excel** (.xlsx)

## S3 Bucket Tags (on Storage Bucket)

| Tag | Description | Required |
|---|---|---|
| `Organization` | Organization display name (email branding) | Yes |
| `OrganizationEmail` | Email for delivery confirmation receipts | No |

## Software Integration (API)

Software systems send files to the storage bucket via REST API:

```
POST https://<api-endpoint>/v1/upload
x-api-key: <customer-api-key>
Content-Type: application/json

{
  "identifier": "STU-100",
  "name": "Amara Ojo",
  "file_name": "neco_result_2026.pdf",
  "file": "<base64-encoded-content>"
}
```

Auto-detects formats: FHIR, HL7v2, LIS/LIMS JSON, Imaging/EMS JSON, and unknown formats via fuzzy scanning.

## Testing

### Step 1: Send files via API
```bash
curl -X POST <api-endpoint> \
  -H "x-api-key: <key>" \
  -H "Content-Type: application/json" \
  -d '{"identifier":"STU-100","name":"Amara Ojo","file_name":"result.pdf","file":"<base64>"}'
```

### Step 2: Upload delivery spreadsheet
Upload CSV to the delivery bucket with recipient contacts and student IDs.

### Step 3: Verify
Check inbox for "A secure file is available" email → click Verify & Continue → WhatsApp OTP → download file.

### Step 4: Test tracking
Upload same spreadsheet again → no emails sent (all already delivered).

### Step 5: Test resend
Add `Resend=true` for a student → that student gets all files resent.

## Works For Any Industry

| Industry | Root Folder | Identifier | Recipient |
|---|---|---|---|
| School | `students` | StudentID | Parent |
| Hospital | `patients` | PatientID | Patient/Family |
| Lab | `specimens` | SpecimenID | Patient |
| Law Firm | `clients` | CaseID | Client |
| Insurance | `policies` | PolicyID | Policyholder |

## Security

- OTP verification via WhatsApp before file access
- SHA-256 hashed tokens and OTPs (never plaintext)
- Constant-time comparison prevents timing attacks
- 2 OTP codes max per 24-hour window
- Delivery tracking prevents duplicate sends
- 7-day auto-cleanup on delivery bucket
- Encryption at rest on all DynamoDB tables
- HTTPS-only bucket policies
- Presigned URLs for file download (time-limited)
- Non-repudiation email sent to organization after each delivery
- Two-bucket separation — delivery staff never sees storage bucket contents
