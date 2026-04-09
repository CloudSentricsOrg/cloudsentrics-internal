# Customer Dashboard

Enterprise web portal for customers to manage their files, deliveries, users, and account. Fully serverless, automated deployment, per-customer isolation.

## Features

### Authentication & Security
- **Cognito Login** — email/password authentication
- **Multi-Factor Authentication (MFA)** — TOTP-based (Google/Microsoft Authenticator), QR code setup, required for all users
- **First Login Password Change** — new users must set their own password (strength indicator + match indicator)
- **Password Eye Icons** — show/hide toggle on all password fields (login, change password, first login)
- **Forgot Password** — email verification code flow
- **Change Password** — update from within the dashboard with match indicator
- **Session Timeout Warning** — banner at 55 min, auto-logout at 60 min
- **Global 401 Handling** — expired sessions redirect to login gracefully
- **Confirm Before Logout** — prevents accidental sign-outs

### File Management
- **Storage Browser** — browse, search, download, delete files with breadcrumb navigation
- **File Preview** — inline preview for PDFs and images (png, jpg, gif, svg, webp)
- **File Size Preview** — shows file name and size before upload with Upload Now / Cancel
- **Upload Here** — upload files directly from the folder you're browsing (button + drag & drop)
- **Upload to Storage** — dedicated upload tab with folder dropdown and destination breadcrumb
- **Create Folder** — create folders at any depth from Storage Browser or Upload tab (nested paths supported)
- **Delete Folder** — delete folders and all contents (with confirmation)
- **Presigned Uploads** — files >5MB upload directly to S3 (no size limit)
- **Access Badges** — folders show Full Access ✅ or Read Only 🔒 based on user permissions

### Deleted Files & Recovery
- **Deleted Files View** — list all soft-deleted files (S3 versioning)
- **Deletion Audit Trail** — tracks who deleted each file and when
- **One-Click Restore** — restore deleted files by removing S3 delete marker
- **Access-Scoped** — admins see all deleted files, regular users only see files they deleted

### Delivery
- **Upload Spreadsheet** — drag & drop CSV/JSON/Excel to Secure Delivery Center (shows destination folder)
- **Recent Uploads** — shows files already in the delivery folder (admin only)
- **Delivery History** — searchable table of all deliveries (filtered by folder access, 30-day window)
- **Delivery History Export** — CSV, JSON, and PDF export

#### CSV Format
```csv
RecipientName,RecipientEmail,RecipientPhone,ID,Resend,Note
Amara Ojo,parent@gmail.com,+2348012345678,MAT-001,,Your child scored 280 in JAMB.
```
- `RecipientName`, `RecipientEmail`, `RecipientPhone`, `ID`, `Resend` — control fields
- `Note` (or any extra column) — included as sensitive data in the delivery email
- Multiple users can upload different CSV files (e.g. `maternity-deliver.csv`, `pediatrics-deliver.csv`) without conflicts

### User Management (Admin Only)
- **Create Users** — full name, email, auto-generated or custom password, folder access, optional admin role
- **Auto-Generated Password** — 12-char strong password option, or custom with show/hide toggle
- **Welcome Message** — copy button with credentials + dashboard URL for sharing
- **Per-Folder Permissions** — Read Only (view + download) or Full Access (view + upload + delete) per folder
- **Folder Access Control** — expandable folder tree picker with permission dropdown per folder
- **Edit Access** — update existing user's folder permissions
- **Change Email** — copies name, role, folder access to new email, deletes old user
- **Actions Dropdown** — Make Admin, Remove Admin, Edit Access, Change Email, Disable, Enable, Reset MFA, Delete
- **Bulk Delete** — select multiple users with checkboxes, delete in one action
- **MFA Management** — view MFA status per user, reset MFA for users who lose their phone
- **Last Login Tracking** — see when each user last logged in
- **Self-Delete Protection** — admins cannot delete themselves
- **User Credential Report** — generate and download full user report (CSV/PDF) with roles, MFA, access, status

### Activity Log (Admin Only)
- **Full Audit Trail** — every action logged: login (MFA), upload, download, view, delete, restore, create folder, user management
- **Searchable** — filter by user, action, or detail
- **Exportable** — CSV, JSON, and PDF export with separate Name and Email columns
- **30-Day Retention** — DynamoDB TTL auto-deletes old entries

### Storage Snapshot (Admin Only)
- **Live Metrics** — total storage, object count, average object size
- **Storage by Bucket** — CloudWatch-style vertical bar chart with Y-axis, gridlines, color-coded bars
- **Storage by Folder** — vertical bar chart for storage bucket folders with tooltips
- **All Versions** — includes current objects, old versions, and delete markers
- **Real-Time** — calculated on every view (more current than AWS Storage Lens)

### Storage Limit Notifications (Admin Only)
- **Configurable Limit** — human-readable format (50GB, 100MB, 1TB) in terraform.tfvars
- **Notification Bell** — 🔔 in nav bar with unread count badge
- **Email Alerts** — branded HTML email to all admins via cross-account SES
- **Alert Thresholds** — warning (80%), critical (90%), limit reached (100%), resolved (below 80%)
- **No Upload Blocking** — uploads always work, notifications are for billing follow-up
- **One Per Day** — each threshold triggers once per day, not every login

### Portal Experience
- **Sidebar Navigation** — color-coded sections: blue (File Management), green (Delivery), purple (Admin), orange (Support)
- **Organization Branding** — customer name in welcome banner (via Terraform variable)
- **Custom Subdomain** — `{customer}.cloudsentrics.org` with auto-provisioned SSL
- **Branded Login Page** — blue gradient background with Cloud Sentrics slogan
- **Logo in Nav Bar** — Cloud Sentrics logo with white background + company name
- **User Name in Nav Bar** — shows "Name | email" for logged-in user
- **Favicon** — Cloud Sentrics logo in browser tab
- **Contact Support** — link to support portal in sidebar
- **Mobile Responsive** — hamburger menu on phones/tablets
- **Loading Spinners** — visual feedback on all data loads
- **Toast Notifications** — success messages on all admin actions
- **Empty State Guidance** — action buttons when no files exist
- **Hash Navigation** — browser back button switches views
- **Session Persistence** — survives page refresh (sessionStorage)
- **Smooth Transitions** — fade-in animations, hover effects on buttons and table rows
- **Footer** — "Cloud Sentrics v1.0 — Securing Tomorrow, One Cloud At A Time!"

## Architecture

```
{customer}.cloudsentrics.org
        ↓
CloudFront (HTTPS + ACM cert)
        ↓
S3 (index.html + logo + favicon)
        ↓
User's Browser
        ↓
API Gateway
        ↓
Dashboard Lambda
  ↓         ↓         ↓         ↓
Cognito    S3        DynamoDB   DynamoDB
(auth)   (files)   (deletion)  (activity)
```

## Infrastructure

| Resource | Name |
|---|---|
| Cognito User Pool | `cloudsentrics-dashboard-users` |
| Cognito Group | `admin` |
| Lambda | `cloudsentrics-dashboard-api` |
| API Gateway | `cloudsentrics-dashboard-api` |
| S3 Website | `cloudsentrics-dashboard-website` |
| CloudFront | HTTPS distribution with custom domain |
| ACM Certificate | `{customer}.cloudsentrics.org` (auto-provisioned, free) |
| DynamoDB | `cloudsentrics-deletion-log` (who deleted files) |
| DynamoDB | `cloudsentrics-activity-log` (all user activity) |
| DynamoDB | `cloudsentrics-notifications` (storage alerts) |

## API Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/auth/login` | No | Cognito login (handles NEW_PASSWORD_REQUIRED) |
| POST | `/auth/forgot` | No | Send password reset code |
| POST | `/auth/reset` | No | Confirm reset with code + new password |
| POST | `/auth/new-password` | No | Complete forced password change on first login |
| POST | `/auth/change-password` | Yes | Change password (current + new) |
| GET | `/dashboard/files?prefix=` | Yes | Browse files/folders (filtered by access) |
| GET | `/dashboard/download?key=&mode=` | Yes | Presigned download URL (mode=preview for inline) |
| POST | `/dashboard/upload` | Yes | Upload spreadsheet to delivery center |
| POST | `/dashboard/upload-storage` | Yes | Upload file to storage bucket |
| POST | `/dashboard/upload-presign` | Yes | Presigned upload URL for large files |
| POST | `/dashboard/create-folder` | Yes | Create folder in storage bucket |
| POST | `/dashboard/delete` | Yes | Soft delete file |
| POST | `/dashboard/delete-folder` | Yes | Delete folder and all contents |
| GET | `/dashboard/deleted` | Yes | List deleted files (admin: all, user: own) |
| POST | `/dashboard/restore` | Yes | Restore deleted file |
| GET | `/dashboard/history` | Yes | Delivery history (filtered by access) |
| GET | `/dashboard/snapshot` | Yes | Storage metrics (all buckets + versions) |
| GET | `/dashboard/activity` | Yes | Activity log |
| GET | `/dashboard/users` | Admin | List all users with roles, access, last login |
| POST | `/dashboard/users/create` | Admin | Create user with name, access, optional admin |
| POST | `/dashboard/users/delete` | Admin | Permanently delete user (cannot delete self) |
| POST | `/dashboard/users/disable` | Admin | Disable user account |
| POST | `/dashboard/users/enable` | Admin | Enable user account |
| POST | `/dashboard/users/make-admin` | Admin | Promote to admin group |
| POST | `/dashboard/users/remove-admin` | Admin | Remove from admin group |
| POST | `/dashboard/users/update-access` | Admin | Update folder access permissions |
| POST | `/dashboard/users/change-email` | Admin | Change user's email (copies settings) |
| POST | `/dashboard/users/reset-mfa` | Admin | Reset user's MFA |
| GET | `/dashboard/notifications` | Admin | List notifications |
| POST | `/dashboard/notifications` | Admin | Mark notifications as read |
| GET | `/dashboard/delivery-files` | Yes | List files in delivery folder |
| GET | `/dashboard/me` | Yes | Current user info and storage status |
| POST | `/auth/verify-mfa-setup` | No | Complete MFA setup with QR code |
| POST | `/auth/verify-mfa` | No | Verify MFA code on login |
| POST | `/dashboard/users/change-email` | Admin | Change user's email (copies settings, deletes old) |

## Terraform Variables

| Variable | Description |
|---|---|
| `admin_email` | Initial admin email |
| `admin_temp_password` | Temporary password (changed on first login) |
| `org_name` | Organization name on dashboard (default: "Your Secure Portal") |
| `customer_subdomain` | Subdomain for `{value}.cloudsentrics.org` (empty = CloudFront URL only) |
| `cert_validated` | Set to `true` after DNS validation (default: `false`) |
| `storage_limit` | Storage limit in human-readable format: `50GB`, `100MB`, `1TB`. Set to `0` for unlimited. |

Example `terraform.tfvars`:
```hcl
admin_email         = "admin@acmehealth.com"
admin_temp_password = "AcmeTemp2026!"
org_name            = "Acme Health Services"
customer_subdomain  = "acmehealth"
cert_validated      = true
storage_limit       = "50GB"
```

## Custom Domain Setup

Each customer gets: `https://{customer}.cloudsentrics.org`

**⚠️ Two-step process — SSL cert must be validated before CloudFront can use it.**

### Step 1: Create certificate (first pipeline run)
1. Set `customer_subdomain` and `cert_validated = false` in terraform.tfvars
2. Push → pipeline creates ACM certificate
3. Pipeline outputs `dns_validation_records` and `cloudfront_domain`

### Step 2: Validate certificate (manual, one-time)
1. Log in to Hostinger → Domains → cloudsentrics.org → DNS Records
2. Add two CNAME records:
   - **Cert validation:** Name and Target from `dns_validation_records` output
   - **Subdomain:** Name = customer subdomain, Target = `cloudfront_domain` output
3. Wait 5-10 minutes
4. Verify in AWS Console → ACM (us-east-1) → status changes to "Issued"

### Step 3: Enable custom domain (second pipeline run)
1. Set `cert_validated = true` in terraform.tfvars
2. Push → CloudFront accepts the custom domain
3. Dashboard live at `https://{customer}.cloudsentrics.org`

**One-time per customer.** Cert auto-renews. Update `CUSTOMERS.md` after setup.

## Environment Variables (Lambda)

| Variable | Description |
|---|---|
| `COGNITO_USER_POOL_ID` | Cognito user pool ID |
| `COGNITO_CLIENT_ID` | Cognito app client ID |
| `DELIVERY_BUCKET` | Delivery bucket for spreadsheets |
| `DELIVERY_TABLE` | DynamoDB delivery tracking table |
| `DELIVERY_FOLDER` | Folder in delivery bucket (secure-delivery-center) |
| `STORAGE_BUCKET` | Storage bucket for files |
| `DELETION_LOG_TABLE` | DynamoDB deletion tracking table |
| `ACTIVITY_LOG_TABLE` | DynamoDB activity log table |
| `NOTIFICATIONS_TABLE` | DynamoDB notifications table |
| `MAILHUB_ACCOUNT_ID` | SES cross-account ID (076609871004) |
| `MAILHUB_ROLE_NAME` | SES cross-account role (centralized-ses-role) |
| `FROM_EMAIL` | SES sender email |
| `STORAGE_LIMIT` | Storage limit (human-readable: 50GB, 100MB) |
| `DASHBOARD_URL` | Dashboard URL for email links |

## Security

- Cognito authentication on all endpoints
- **MFA required for all users** (TOTP-based)
- Admin endpoints verify group membership server-side
- **Per-folder Read Only / Full Access** enforced server-side
- Folder access enforced on files, download, delete, upload
- Delivery history and deleted files filtered by user access
- Regular users only see files they deleted
- Access tokens expire after 1 hour with session timeout warning
- HTTPS enforced via CloudFront with TLS 1.2 minimum
- S3 bucket private — only CloudFront can read
- Password policy: 8+ chars, uppercase, lowercase, numbers
- Temporary passwords with forced change on first login
- No self-signup — only admins create accounts
- Self-delete protection for admins
- Soft delete with S3 versioning (files always recoverable)
- Full activity audit trail with 30-day retention
- Deletion audit trail (who deleted what and when)
- Per-customer AWS account isolation
- Per-customer SSL certificate

### Important Notes
- **"Unknown" in Deleted By** — means the file was deleted outside the dashboard (directly from S3 Console, CLI, or another tool). All deletions should go through the dashboard for proper audit tracking.
- **Direct S3 access** should be restricted to Cloud Sentrics only. Customers should only use the dashboard to manage files.

### Access Control by Role

| View | Admin | User (Full Access) | User (Read Only) | User (No Folder Set) |
|---|---|---|---|---|
| Storage Browser | All folders | Assigned folders only | Assigned folders only | All folders |
| Upload / Delete / Create Folder | ✅ All | ✅ Assigned folders | ❌ Blocked | ✅ All |
| Download / Preview | ✅ All | ✅ Assigned folders | ✅ Assigned folders | ✅ All |
| Deleted Files | All users' deletions | Own deletions only | Own deletions only | Own deletions only |
| Delivery History | All deliveries | Deliveries matching folders | Deliveries matching folders | All deliveries |
| Activity Log | ✅ All users | ❌ Hidden | ❌ Hidden | ❌ Hidden |
| User Management | ✅ Full control | ❌ Hidden | ❌ Hidden | ❌ Hidden |
| Storage Snapshot | ✅ Full metrics | ❌ Hidden | ❌ Hidden | ❌ Hidden |
| Notification Bell | ✅ Visible | ❌ Hidden | ❌ Hidden | ❌ Hidden |

## Dashboard Views

### All Users
| View | Description |
|---|---|
| 📂 Storage Browser | Browse, search, upload, download, preview, delete files and folders |
| 🗑️ Deleted Files | View and restore deleted files (own deletions only for regular users) |
| 📤 Upload to Storage | Upload with folder dropdown and destination breadcrumb |
| 📁 Upload Spreadsheet | Drag & drop to Secure Delivery Center |
| 📋 Delivery History | Searchable deliveries (filtered by folder access) |
| 🎧 Contact Support | Opens support portal in new tab |

### Admin Users (all above, plus)
| View | Description |
|---|---|
| 👥 User Management | Create, edit, disable, enable, delete users with Actions dropdown, bulk delete, credential report |
| 📊 Activity Log | Searchable audit trail with CSV/JSON/PDF export |
| 📸 Storage Snapshot | CloudWatch-style charts: Storage by Bucket, Storage by Folder |
| 📋 User Credential Report | Generate and download full user report (CSV/PDF) |
| 🔔 Notification Bell | Storage limit alerts with email notifications |

## Data Retention

| Data | Retention |
|---|---|
| Activity log entries | 30 days (DynamoDB TTL) |
| Deletion log entries | 30 days (DynamoDB TTL) |
| Deleted files (S3 versions) | Permanent (recoverable via restore) |
| Delivery history | 30 days (filtered in dashboard) |
| Notifications | 30 days (DynamoDB TTL) |

## Production Scalability

| Feature | How it scales |
|---|---|
| File uploads | Files >5MB use presigned S3 URLs (no size limit) |
| Deleted files | Paginated (100 per page, Load More button) |
| User list | Paginated (handles 60+ Cognito users) |
| Delivery history | Full DynamoDB scan with continuation tokens |
| Storage snapshot | Paginated across all buckets and versions |
| CloudFront cache | Invalidated on every deploy |
| Serverless | All services auto-scale, no servers to manage |
| Cost | $0-5/month per customer at normal usage |

## Pipeline & Deployment Order

```
1. KICS scan + guards
        ↓
2. Independent solutions in parallel:
   - Email+OTP, WhatsApp, Storage-only, Monthly welcome, Storage integration
   - Automated storage & secure sharing  ←── creates buckets + tables
        ↓
3. Customer dashboard  ←── depends on step 2
```

### Feature Flags
```yaml
enable_email_otp=true
enable_whatsapp=false
enable_storage_only=false
enable_monthly_welcome=true
enable_storage_integration=true
enable_automated_sharing=true
enable_dashboard=true
```

## TODO

- [x] Sidebar navigation layout
- [x] Deleted files view (S3 versioning)
- [x] Upload files directly to storage bucket
- [x] Admin tab for user management
- [x] Folder-level access control
- [x] Delete user capability
- [x] Automated admin user creation
- [x] CloudFront cache invalidation
- [x] Presigned S3 uploads for large files
- [x] Pagination (deleted files, users, delivery history)
- [x] Pipeline deployment ordering
- [x] Activity log with export
- [x] Storage snapshot
- [x] Custom subdomain with SSL
- [x] Organization branding
- [x] Mobile responsive
- [x] File preview
- [x] Drag and drop upload
- [x] Last login tracking
- [x] Session timeout warning
- [x] Favicon
- [x] Contact Support link
- [x] Welcome message with copy button
- [x] Password strength indicator
- [x] Empty state guidance
- [x] Confirm before logout
- [x] Branded login page
- [x] Color-coded sidebar sections
- [x] Auto-generate password option
- [x] Change email for users
- [x] Delivery history 30-day filter
- [x] Per-folder Read Only / Full Access permissions
- [x] Storage limit notifications (bell + email)
- [x] CloudWatch-style storage graphs (bucket + folder)
- [x] Password eye icons and match indicator
- [x] User name in nav bar
- [x] MFA (TOTP) for all users
- [x] Per-folder Read Only / Full Access permissions
- [x] Actions dropdown (AWS-style) in User Management
- [x] Bulk delete users with checkboxes
- [x] User Credential Report (CSV/PDF)
- [x] Delivery History export (CSV/JSON/PDF)
- [x] File size preview before upload
- [x] Toast confirmations on admin actions
- [x] Recent uploads in Secure Delivery Center
- [x] Storage by Bucket and Storage by Folder charts
- [x] Notification bell with email alerts
- [ ] Phase 2: Block software uploads (storage ingestion Lambda) when storage limit reached
- [ ] Phase 2: Add recipient name to delivery tracking table
- [ ] Setup script for new customer onboarding

## New Customer Onboarding

### Time: ~30 minutes

1. Create customer AWS account
2. Clone template repo → new customer repo
3. Update resource names and terraform.tfvars
4. Push → pipeline deploys everything
5. Get DNS records from pipeline output
6. Add CNAME records in Hostinger (cert validation + subdomain)
7. Wait for cert validation → set `cert_validated = true` → push again
8. Share `https://{customer}.cloudsentrics.org` + admin temp password
9. Update `CUSTOMERS.md`

### After Onboarding
- Admin logs in → sets password → creates users → fully self-service
- Cloud Sentrics never touches the account again for user management
- Infrastructure cost: $0-5/month per customer
