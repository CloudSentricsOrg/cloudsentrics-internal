import os
import json
import base64
import hmac
import hashlib
import time

import boto3
from botocore.exceptions import ClientError

# ========= Environment =========
COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]
COGNITO_CLIENT_ID    = os.environ["COGNITO_CLIENT_ID"]
COGNITO_CLIENT_SECRET = os.environ.get("COGNITO_CLIENT_SECRET", "")
DELIVERY_BUCKET      = os.environ["DELIVERY_BUCKET"]
DELIVERY_TABLE       = os.environ["DELIVERY_TABLE"]
DELIVERY_FOLDER      = os.getenv("DELIVERY_FOLDER", "secure-delivery-center")
STORAGE_BUCKET       = os.environ["STORAGE_BUCKET"]
DELETION_LOG_TABLE   = os.environ.get("DELETION_LOG_TABLE", "cloudsentrics-deletion-log")
ACTIVITY_LOG_TABLE   = os.environ.get("ACTIVITY_LOG_TABLE", "cloudsentrics-activity-log")
NOTIFICATIONS_TABLE  = os.environ.get("NOTIFICATIONS_TABLE", "cloudsentrics-notifications")
MAILHUB_ACCOUNT_ID   = os.environ.get("MAILHUB_ACCOUNT_ID", "076609871004")
MAILHUB_ROLE_NAME    = os.environ.get("MAILHUB_ROLE_NAME", "centralized-ses-role")
FROM_EMAIL           = os.environ.get("FROM_EMAIL", "secure-file-delivery@cloudsentrics.org")
STORAGE_LIMIT_RAW    = os.environ.get("STORAGE_LIMIT", "0")

def _parse_size(s):
    s = s.strip().upper()
    if not s or s == "0":
        return 0
    try:
        if s.endswith("TB"):
            return int(float(s[:-2]) * 1099511627776)
        if s.endswith("GB"):
            return int(float(s[:-2]) * 1073741824)
        if s.endswith("MB"):
            return int(float(s[:-2]) * 1048576)
        if s.endswith("KB"):
            return int(float(s[:-2]) * 1024)
        return int(s)
    except Exception:
        return 0

STORAGE_LIMIT = _parse_size(STORAGE_LIMIT_RAW)
DASHBOARD_URL        = os.environ.get("DASHBOARD_URL", "")

# ========= Clients =========
cognito = boto3.client("cognito-idp")
s3      = boto3.client("s3")
dynamo  = boto3.client("dynamodb")
sts     = boto3.client("sts")

# ========= Helpers =========
def _resp(code, body, cors=True):
    headers = {"Content-Type": "application/json"}
    if cors:
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Headers"] = "Content-Type,Authorization"
        headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
    return {"statusCode": code, "headers": headers, "body": json.dumps(body)}

def _get_secret_hash(username):
    if not COGNITO_CLIENT_SECRET:
        return None
    msg = username + COGNITO_CLIENT_ID
    dig = hmac.new(COGNITO_CLIENT_SECRET.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(dig).decode()

def _get_path(event):
    http = (event.get("requestContext") or {}).get("http") or {}
    return (event.get("rawPath") or http.get("path") or event.get("path") or "").rstrip("/")

def _get_method(event):
    http = (event.get("requestContext") or {}).get("http") or {}
    return (http.get("method") or event.get("httpMethod") or "GET").upper()

def _get_token(event):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth = headers.get("authorization", "")
    return auth.replace("Bearer ", "").strip() if auth.startswith("Bearer ") else ""

def _verify_token(token):
    try:
        resp = cognito.get_user(AccessToken=token)
        email = ""
        allowed_folders = ""
        full_name = ""
        for attr in resp.get("UserAttributes", []):
            if attr["Name"] == "email":
                email = attr["Value"]
            if attr["Name"] == "custom:allowed_folders":
                allowed_folders = attr["Value"]
            if attr["Name"] == "name":
                full_name = attr["Value"]
        return {"username": resp["Username"], "email": email, "allowed_folders": allowed_folders, "name": full_name}
    except Exception:
        return None

def _parse_folder_permissions(folders_str):
    """Parse folder permissions string into list of (folder, permission) tuples.
    Supports both old format (students/) and new format (students/:full, patients/:read)."""
    if not folders_str:
        return []
    result = []
    for entry in folders_str.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if ":" in entry:
            parts = entry.rsplit(":", 1)
            result.append((parts[0], parts[1]))
        else:
            result.append((entry, "full"))
    return result

def _check_folder_access(user, prefix, action="view"):
    """Check if user has access to the given prefix. action can be 'view' or 'write'."""
    folders = user.get("allowed_folders", "")
    if not folders:
        return True
    perms = _parse_folder_permissions(folders)
    if not perms:
        return True
    for folder, perm in perms:
        if prefix.startswith(folder) or folder.startswith(prefix):
            if action == "write" and perm == "read":
                return False
            return True
    return False

def _filter_folders(user, folders, current_prefix):
    """Filter folder list based on user's allowed folders."""
    af = user.get("allowed_folders", "")
    if not af:
        return folders
    perms = _parse_folder_permissions(af)
    if not perms:
        return folders
    result = []
    for folder in folders:
        full_path = current_prefix + folder
        for a, p in perms:
            if a.startswith(full_path) or full_path.startswith(a):
                result.append(folder)
                break
    return result

def _filter_files(user, files):
    """Filter file list based on user's allowed folders."""
    af = user.get("allowed_folders", "")
    if not af:
        return files
    perms = _parse_folder_permissions(af)
    if not perms:
        return files
    return [f for f in files if any(f["key"].startswith(a) for a, p in perms)]

def _log_activity(user_email, action, detail="", user_name=""):
    try:
        activity_id = f"{int(time.time()*1000)}-{user_email}-{action}"
        expires = int(time.time()) + (30 * 24 * 60 * 60)  # 30 days
        dynamo.put_item(TableName=ACTIVITY_LOG_TABLE, Item={
            "activityId": {"S": activity_id},
            "user": {"S": user_name or user_email},
            "email": {"S": user_email},
            "action": {"S": action},
            "detail": {"S": detail},
            "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
            "expiresAt": {"N": str(expires)}
        })
    except Exception:
        pass  # Don't fail the request if logging fails

def _get_ses_client():
    creds = sts.assume_role(RoleArn=f"arn:aws:iam::{MAILHUB_ACCOUNT_ID}:role/{MAILHUB_ROLE_NAME}", RoleSessionName="dashboard-ses")["Credentials"]
    return boto3.client("ses", region_name="us-east-1", aws_access_key_id=creds["AccessKeyId"], aws_secret_access_key=creds["SecretAccessKey"], aws_session_token=creds["SessionToken"])

def _get_total_storage():
    total = 0
    buckets = s3.list_buckets().get("Buckets", [])
    for bucket in buckets:
        params = {"Bucket": bucket["Name"]}
        while True:
            try:
                resp = s3.list_object_versions(**params)
                for obj in resp.get("Versions", []):
                    total += obj.get("Size", 0)
                if resp.get("IsTruncated"):
                    params["KeyMarker"] = resp.get("NextKeyMarker", "")
                    params["VersionIdMarker"] = resp.get("NextVersionIdMarker", "")
                else:
                    break
            except Exception:
                break
    return total

def _fmt_size(b):
    if b >= 1073741824: return f"{b/1073741824:.2f} GB"
    if b >= 1048576: return f"{b/1048576:.1f} MB"
    if b >= 1024: return f"{b/1024:.1f} KB"
    return f"{b} B"

def _check_storage_limit_and_notify(user_email=""):
    if STORAGE_LIMIT <= 0:
        return {"status": "ok", "usage": 0, "limit": 0, "pct": 0}
    try:
        total = _get_total_storage()
        pct = (total / STORAGE_LIMIT) * 100
        print(f"Storage check: {total} bytes / {STORAGE_LIMIT} bytes = {pct:.1f}%")
        status = "ok"
        if pct >= 100:
            status = "blocked"
        elif pct >= 90:
            status = "critical"
        elif pct >= 80:
            status = "warning"
        print(f"Storage status: {status}")
        if status != "ok":
            notif_id = f"storage-{status}"
            try:
                existing = dynamo.get_item(TableName=NOTIFICATIONS_TABLE, Key={"notificationId": {"S": notif_id}})
                existing_item = existing.get("Item")
                # Only create if doesn't exist, or exists but was read (remind again)
                should_notify = not existing_item
                if existing_item and existing_item.get("read", {}).get("S") == "true":
                    # Re-notify if last notification was more than 24 hours ago
                    last_ts = existing_item.get("timestamp", {}).get("S", "")
                    if last_ts:
                        import datetime
                        try:
                            last_dt = datetime.datetime.strptime(last_ts, "%Y-%m-%dT%H:%M:%SZ")
                            if (datetime.datetime.utcnow() - last_dt).total_seconds() > 86400:
                                should_notify = True
                        except Exception:
                            should_notify = True
                if should_notify:
                    remaining = max(STORAGE_LIMIT - total, 0)
                    msgs = {
                        "warning": f"⚠️ Storage at {pct:.0f}% capacity ({_fmt_size(total)} of {_fmt_size(STORAGE_LIMIT)}). {_fmt_size(remaining)} remaining.",
                        "critical": f"🔴 Storage at {pct:.0f}% capacity ({_fmt_size(total)} of {_fmt_size(STORAGE_LIMIT)}). Please contact support to upgrade your storage plan.",
                        "blocked": f"🚫 Your storage plan limit has been reached ({_fmt_size(total)} of {_fmt_size(STORAGE_LIMIT)}). Your files are safe and uploads will continue. Please contact support to upgrade your storage plan."
                    }
                    msg = msgs.get(status, "")
                    dynamo.put_item(TableName=NOTIFICATIONS_TABLE, Item={
                        "notificationId": {"S": notif_id},
                        "type": {"S": status},
                        "message": {"S": msg},
                        "read": {"S": "false"},
                        "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                        "expiresAt": {"N": str(int(time.time()) + 30*24*60*60)}
                    })
                    print(f"Notification written: {notif_id}")
                    try:
                        ses = _get_ses_client()
                        admin_users = cognito.list_users_in_group(UserPoolId=COGNITO_USER_POOL_ID, GroupName="admin").get("Users", [])
                        for au in admin_users:
                            admin_email = ""
                            for attr in au.get("Attributes", []):
                                if attr["Name"] == "email": admin_email = attr["Value"]
                            if admin_email:
                                sc = {"warning": "#f59e0b", "critical": "#dc2626", "blocked": "#7c3aed"}.get(status, "#1e40af")
                                si = {"warning": "⚠️", "critical": "🔴", "blocked": "🚫"}.get(status, "ℹ️")
                                sb = {"warning": "#fffbeb", "critical": "#fef2f2", "blocked": "#f5f3ff"}.get(status, "#eff6ff")
                                email_html = f'<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;"><div style="background:linear-gradient(135deg,#1e40af,#3b82f6);padding:24px 32px;border-radius:12px 12px 0 0;"><h1 style="color:#fff;margin:0;font-size:22px;">Cloud Sentrics</h1><p style="color:rgba(255,255,255,0.8);margin:4px 0 0;font-size:14px;">Securing Tomorrow, One Cloud At A Time!</p></div><div style="background:#fff;padding:32px;border:1px solid #e2e8f0;"><div style="background:{sb};border-left:4px solid {sc};padding:16px 20px;border-radius:0 8px 8px 0;margin-bottom:20px;"><p style="font-size:18px;font-weight:700;color:{sc};margin:0 0 8px;">{si} Storage {status.title()} Alert</p><p style="font-size:15px;color:#334155;margin:0;">{msg}</p></div><p style="font-size:14px;color:#64748b;margin:16px 0;">Log in to your dashboard to view storage details and manage your files.</p><a href="{DASHBOARD_URL}" style="display:inline-block;background:linear-gradient(135deg,#1e40af,#3b82f6);color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:700;font-size:14px;">Open Dashboard</a></div><div style="background:#f8fafc;padding:16px 32px;border-radius:0 0 12px 12px;border:1px solid #e2e8f0;border-top:none;"><p style="font-size:12px;color:#94a3b8;margin:0;">This is an automated alert from Cloud Sentrics. Do not reply to this email.</p></div></div>'
                                ses.send_email(Source=FROM_EMAIL, Destination={"ToAddresses": [admin_email]}, Message={"Subject": {"Data": f"Cloud Sentrics — Storage {status.title()} Alert"}, "Body": {"Html": {"Data": email_html}}})
                                print(f"Alert email sent to {admin_email}")
                    except Exception as e:
                        print(f"Notification email error: {e}")
            except Exception as e:
                print(f"Notification write error: {e}")
        else:
            # Storage back to normal — notify if there was a previous alert
            today = time.strftime("%Y-%m-%d", time.gmtime())
            resolved_id = f"storage-resolved"
            try:
                existing = dynamo.get_item(TableName=NOTIFICATIONS_TABLE, Key={"notificationId": {"S": resolved_id}})
                if not existing.get("Item"):
                    # Check if there were any recent alerts
                    for level in ["warning", "critical", "blocked"]:
                        prev = dynamo.get_item(TableName=NOTIFICATIONS_TABLE, Key={"notificationId": {"S": f"storage-{level}"}})
                        if prev.get("Item"):
                            dynamo.put_item(TableName=NOTIFICATIONS_TABLE, Item={
                                "notificationId": {"S": resolved_id},
                                "type": {"S": "resolved"},
                                "message": {"S": f"✅ Storage usage is now within normal limits. Current usage: {_fmt_size(total)} of {_fmt_size(STORAGE_LIMIT)} ({pct:.0f}%)."},
                                "read": {"S": "false"},
                                "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                                "expiresAt": {"N": str(int(time.time()) + 30*24*60*60)}
                            })
                            print("Storage resolved notification written")
                            break
            except Exception as e:
                print(f"Resolved notification error: {e}")
        return {"status": status, "usage": total, "limit": STORAGE_LIMIT, "pct": round(pct, 1)}
    except Exception as e:
        print(f"Storage check error: {e}")
        return {"status": "error", "usage": 0, "limit": STORAGE_LIMIT, "pct": 0, "error": str(e)}

# ========= Main Handler =========
def lambda_handler(event, context):
    path = _get_path(event)
    method = _get_method(event)

    # CORS preflight
    if method == "OPTIONS":
        return _resp(200, {})

    # POST /auth/login
    if path.endswith("/auth/login") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            password = body.get("password", "")

            auth_params = {"USERNAME": email, "PASSWORD": password}
            secret_hash = _get_secret_hash(email)
            if secret_hash:
                auth_params["SECRET_HASH"] = secret_hash

            resp = cognito.admin_initiate_auth(
                UserPoolId=COGNITO_USER_POOL_ID,
                ClientId=COGNITO_CLIENT_ID,
                AuthFlow="ADMIN_USER_PASSWORD_AUTH",
                AuthParameters=auth_params
            )

            result = resp.get("AuthenticationResult", {})
            if not result.get("AccessToken"):
                # Check for NEW_PASSWORD_REQUIRED challenge
                if resp.get("ChallengeName") == "NEW_PASSWORD_REQUIRED":
                    return _resp(200, {
                        "challenge": "NEW_PASSWORD_REQUIRED",
                        "session": resp["Session"],
                        "email": email
                    })
                # Check for MFA setup challenge
                if resp.get("ChallengeName") == "MFA_SETUP":
                    # Associate software token to get secret
                    token_resp = cognito.associate_software_token(Session=resp["Session"])
                    return _resp(200, {
                        "challenge": "MFA_SETUP",
                        "session": token_resp["Session"],
                        "secretCode": token_resp["SecretCode"],
                        "email": email
                    })
                # Check for MFA verification challenge
                if resp.get("ChallengeName") == "SOFTWARE_TOKEN_MFA":
                    return _resp(200, {
                        "challenge": "SOFTWARE_TOKEN_MFA",
                        "session": resp["Session"],
                        "email": email
                    })
                return _resp(401, {"error": "Authentication failed"})

            _log_activity(email, "Login", "Successful login (MFA verified)")
            # Store last login time
            try:
                dynamo.put_item(TableName=ACTIVITY_LOG_TABLE, Item={
                    "activityId": {"S": f"lastlogin-{email}"},
                    "user": {"S": email},
                    "action": {"S": "LastLogin"},
                    "detail": {"S": ""},
                    "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                })
            except Exception:
                pass
            return _resp(200, {
                "token": result["AccessToken"],
                "expiresIn": result.get("ExpiresIn", 3600)
            })
        except cognito.exceptions.NotAuthorizedException:
            return _resp(401, {"error": "Invalid email or password"})
        except cognito.exceptions.UserNotFoundException:
            return _resp(401, {"error": "Invalid email or password"})
        except Exception as e:
            print(f"Login error: {e}")
            return _resp(500, {"error": "Authentication service error"})

    # POST /auth/forgot
    if path.endswith("/auth/forgot") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            if not email:
                return _resp(400, {"error": "Email required"})
            cognito.forgot_password(ClientId=COGNITO_CLIENT_ID, Username=email)
            return _resp(200, {"message": "Code sent"})
        except Exception as e:
            print(f"Forgot password error: {e}")
            return _resp(200, {"message": "If the email exists, a code has been sent"})

    # POST /auth/reset
    if path.endswith("/auth/reset") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            code = body.get("code", "").strip()
            password = body.get("password", "")
            if not email or not code or not password:
                return _resp(400, {"error": "All fields required"})
            cognito.confirm_forgot_password(
                ClientId=COGNITO_CLIENT_ID, Username=email,
                ConfirmationCode=code, Password=password
            )
            return _resp(200, {"message": "Password reset successfully"})
        except cognito.exceptions.CodeMismatchException:
            return _resp(400, {"error": "Invalid verification code"})
        except cognito.exceptions.ExpiredCodeException:
            return _resp(400, {"error": "Code has expired. Please request a new one"})
        except Exception as e:
            print(f"Reset error: {e}")
            return _resp(400, {"error": "Password reset failed"})

    # POST /auth/new-password
    if path.endswith("/auth/new-password") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            new_pw = body.get("newPassword", "")
            session = body.get("session", "")
            if not email or not new_pw or not session:
                return _resp(400, {"error": "All fields required"})
            resp = cognito.respond_to_auth_challenge(
                ClientId=COGNITO_CLIENT_ID,
                ChallengeName="NEW_PASSWORD_REQUIRED",
                Session=session,
                ChallengeResponses={"USERNAME": email, "NEW_PASSWORD": new_pw}
            )
            result = resp.get("AuthenticationResult", {})
            if result.get("AccessToken"):
                return _resp(200, {"token": result["AccessToken"], "expiresIn": result.get("ExpiresIn", 3600)})
            # After password change, MFA setup may be required
            if resp.get("ChallengeName") == "MFA_SETUP":
                token_resp = cognito.associate_software_token(Session=resp["Session"])
                return _resp(200, {
                    "challenge": "MFA_SETUP",
                    "session": token_resp["Session"],
                    "secretCode": token_resp["SecretCode"],
                    "email": email
                })
            return _resp(400, {"error": "Failed to set new password"})
        except Exception as e:
            print(f"New password error: {e}")
            return _resp(400, {"error": "Failed to set new password"})

    # POST /auth/verify-mfa-setup
    if path.endswith("/auth/verify-mfa-setup") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            session = body.get("session", "")
            code = body.get("code", "").strip()
            if not email or not session or not code:
                return _resp(400, {"error": "All fields required"})
            # Verify the TOTP token
            verify_resp = cognito.verify_software_token(Session=session, UserCode=code)
            if verify_resp.get("Status") != "SUCCESS":
                return _resp(400, {"error": "Invalid code"})
            # Complete the MFA setup challenge
            challenge_resp = cognito.respond_to_auth_challenge(
                ClientId=COGNITO_CLIENT_ID,
                ChallengeName="MFA_SETUP",
                Session=verify_resp.get("Session", session),
                ChallengeResponses={"USERNAME": email, "SOFTWARE_TOKEN_MFA_CODE": code}
            )
            result = challenge_resp.get("AuthenticationResult", {})
            if result.get("AccessToken"):
                # Explicitly set MFA preference
                try:
                    cognito.admin_set_user_mfa_preference(
                        UserPoolId=COGNITO_USER_POOL_ID, Username=email,
                        SoftwareTokenMfaSettings={"Enabled": True, "PreferredMfa": True})
                except Exception:
                    pass
                # Track MFA enabled
                try:
                    dynamo.put_item(TableName=ACTIVITY_LOG_TABLE, Item={
                        "activityId": {"S": f"mfa-enabled-{email}"},
                        "user": {"S": email}, "action": {"S": "MFA Enabled"},
                        "detail": {"S": "TOTP"}, "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                    })
                except Exception:
                    pass
                _log_activity(email, "Login (MFA)", "MFA setup completed")
                try:
                    dynamo.put_item(TableName=ACTIVITY_LOG_TABLE, Item={
                        "activityId": {"S": f"lastlogin-{email}"},
                        "user": {"S": email}, "action": {"S": "LastLogin"},
                        "detail": {"S": ""}, "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                    })
                except Exception:
                    pass
                return _resp(200, {"token": result["AccessToken"], "expiresIn": result.get("ExpiresIn", 3600)})
            return _resp(400, {"error": "MFA setup failed"})
        except Exception as e:
            print(f"MFA setup error: {e}")
            return _resp(400, {"error": "MFA setup failed"})

    # POST /auth/verify-mfa
    if path.endswith("/auth/verify-mfa") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            session = body.get("session", "")
            code = body.get("code", "").strip()
            if not email or not session or not code:
                return _resp(400, {"error": "All fields required"})
            resp = cognito.respond_to_auth_challenge(
                ClientId=COGNITO_CLIENT_ID,
                ChallengeName="SOFTWARE_TOKEN_MFA",
                Session=session,
                ChallengeResponses={"USERNAME": email, "SOFTWARE_TOKEN_MFA_CODE": code}
            )
            result = resp.get("AuthenticationResult", {})
            if result.get("AccessToken"):
                _log_activity(email, "Login (MFA)", "Successful login with MFA")
                try:
                    dynamo.put_item(TableName=ACTIVITY_LOG_TABLE, Item={
                        "activityId": {"S": f"lastlogin-{email}"},
                        "user": {"S": email}, "action": {"S": "LastLogin"},
                        "detail": {"S": ""}, "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                    })
                    # Ensure MFA tracking record exists
                    dynamo.put_item(TableName=ACTIVITY_LOG_TABLE, Item={
                        "activityId": {"S": f"mfa-enabled-{email}"},
                        "user": {"S": email}, "action": {"S": "MFA Enabled"},
                        "detail": {"S": "TOTP"}, "timestamp": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                    })
                except Exception:
                    pass
                return _resp(200, {"token": result["AccessToken"], "expiresIn": result.get("ExpiresIn", 3600)})
            return _resp(400, {"error": "Invalid MFA code"})
        except Exception as e:
            print(f"MFA verify error: {e}")
            return _resp(400, {"error": "MFA verification failed"})

    # All other endpoints require auth
    token = _get_token(event)
    user = _verify_token(token) if token else None
    if not user:
        return _resp(401, {"error": "Unauthorized"})

    def _is_admin():
        try:
            groups = cognito.admin_list_groups_for_user(
                UserPoolId=COGNITO_USER_POOL_ID, Username=user["username"])
            return any(g["GroupName"] == "admin" for g in groups.get("Groups", []))
        except Exception:
            return False

    # GET /dashboard/home
    if path.endswith("/dashboard/home") and method == "GET":
        try:
            user_email = user["email"]
            # Count folders user has access to
            resp = s3.list_objects_v2(Bucket=STORAGE_BUCKET, Delimiter="/")
            all_folders = [p["Prefix"] for p in resp.get("CommonPrefixes", [])]
            accessible = len(_filter_folders(user, [f.rstrip("/").split("/")[-1] + "/" for f in all_folders], ""))
            # Count files
            file_count = 0
            s3_params = {"Bucket": STORAGE_BUCKET}
            while True:
                resp = s3.list_objects_v2(**s3_params)
                file_count += len([o for o in resp.get("Contents", []) if not o["Key"].endswith("/")])
                if resp.get("IsTruncated"):
                    s3_params["ContinuationToken"] = resp["NextContinuationToken"]
                else:
                    break
            # Count uploads this week
            week_ago = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7*24*60*60))
            uploads_this_week = 0
            # Get recent activity (last 7 days, this user only, max 10)
            recent = []
            scan_params = {"TableName": ACTIVITY_LOG_TABLE, "Limit": 500}
            while True:
                resp = dynamo.scan(**scan_params)
                for item in resp.get("Items", []):
                    ts = item.get("timestamp", {}).get("S", "")
                    email_val = item.get("email", {}).get("S", "") or item.get("user", {}).get("S", "")
                    action = item.get("action", {}).get("S", "")
                    if ts >= week_ago and (email_val == user_email or item.get("user", {}).get("S", "") == user_email):
                        if action in ("Uploaded", "Downloaded", "Viewed", "Deleted", "Restored", "Created", "Created User", "Disabled User", "Enabled User", "Deleted User", "Made Admin", "Removed Admin", "Updated Access", "Changed Email", "Reset MFA", "Login (MFA)", "Login"):
                            recent.append({
                                "action": action,
                                "detail": item.get("detail", {}).get("S", ""),
                                "timestamp": ts
                            })
                        if action == "Uploaded":
                            uploads_this_week += 1
                if resp.get("LastEvaluatedKey"):
                    scan_params["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
                else:
                    break
            recent.sort(key=lambda x: x["timestamp"], reverse=True)
            return _resp(200, {
                "folders": accessible,
                "files": file_count,
                "uploadsThisWeek": uploads_this_week,
                "recentActivity": recent[:10]
            })
        except Exception as e:
            print(f"Home error: {e}")
            return _resp(500, {"error": "Failed to load home"})

    # GET /dashboard/me
    if path.endswith("/dashboard/me") and method == "GET":
        storage_status = None
        if _is_admin():
            storage_status = _check_storage_limit_and_notify(user.get("email", ""))
        return _resp(200, {
            "email": user["email"],
            "name": user.get("name", ""),
            "allowedFolders": user.get("allowed_folders", ""),
            "isAdmin": _is_admin(),
            "storageStatus": storage_status
        })

    # POST /auth/change-password
    if path.endswith("/auth/change-password") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            old_pw = body.get("oldPassword", "")
            new_pw = body.get("newPassword", "")
            if not old_pw or not new_pw:
                return _resp(400, {"error": "Both passwords required"})
            cognito.change_password(
                PreviousPassword=old_pw, ProposedPassword=new_pw,
                AccessToken=token
            )
            return _resp(200, {"message": "Password changed"})
        except cognito.exceptions.NotAuthorizedException:
            return _resp(400, {"error": "Current password is incorrect"})
        except Exception as e:
            print(f"Change password error: {e}")
            return _resp(400, {"error": "Failed to change password"})

    # POST /dashboard/upload
    if path.endswith("/dashboard/upload") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            file_name = body.get("fileName", "spreadsheet.csv")
            file_content = body.get("fileContent", "")

            if not file_content:
                return _resp(400, {"error": "No file content"})

            file_bytes = base64.b64decode(file_content)
            s3_key = f"{DELIVERY_FOLDER}/{file_name}"

            s3.put_object(Bucket=DELIVERY_BUCKET, Key=s3_key, Body=file_bytes)

            print(f"Spreadsheet uploaded: s3://{DELIVERY_BUCKET}/{s3_key} by {user['email']}")
            _log_activity(user["email"], "Uploaded", f"Spreadsheet: {s3_key}", user_name=user.get("name", ""))
            return _resp(200, {"message": "Spreadsheet uploaded successfully", "key": s3_key})
        except Exception as e:
            print(f"Upload error: {e}")
            return _resp(500, {"error": "Failed to upload spreadsheet"})

    # GET /dashboard/delivery-files
    if path.endswith("/dashboard/delivery-files") and method == "GET":
        try:
            resp = s3.list_objects_v2(Bucket=DELIVERY_BUCKET, Prefix=DELIVERY_FOLDER + "/")
            files = [{"name": o["Key"].split("/")[-1], "key": o["Key"], "size": o["Size"],
                      "lastModified": o["LastModified"].isoformat()}
                     for o in resp.get("Contents", []) if not o["Key"].endswith("/") and o["Key"].split("/")[-1]]
            files.sort(key=lambda x: x["lastModified"], reverse=True)
            return _resp(200, {"files": files})
        except Exception as e:
            print(f"Delivery files error: {e}")
            return _resp(500, {"error": "Failed to list delivery files"})

    # GET /dashboard/history
    if path.endswith("/dashboard/history") and method == "GET":
        try:
            items = []
            scan_params = {"TableName": DELIVERY_TABLE, "Limit": 500}
            while True:
                resp = dynamo.scan(**scan_params)
                for item in resp.get("Items", []):
                    items.append({
                        "identifier": item.get("identifier", {}).get("S", ""),
                        "fileKey": item.get("fileKey", {}).get("S", ""),
                        "recipientEmail": item.get("recipientEmail", {}).get("S", ""),
                        "deliveredAt": item.get("deliveredAt", {}).get("S", ""),
                    })
                if resp.get("LastEvaluatedKey"):
                    scan_params["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
                else:
                    break
            items.sort(key=lambda x: x.get("deliveredAt", ""), reverse=True)
            # Filter to last 30 days
            cutoff = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 30*24*60*60))
            items = [i for i in items if i.get("deliveredAt", "") >= cutoff]
            # Filter by folder access
            allowed = user.get("allowed_folders", "")
            if allowed:
                perms = _parse_folder_permissions(allowed)
                items = [i for i in items if any(i.get("fileKey", "").startswith(a) or i.get("identifier", "").startswith(a) for a, p in perms)]
            return _resp(200, {"items": items})
        except Exception as e:
            print(f"History error: {e}")
            return _resp(500, {"error": "Failed to load history"})

    # POST /dashboard/upload-storage
    if path.endswith("/dashboard/upload-storage") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            file_name = body.get("fileName", "")
            file_content = body.get("fileContent", "")
            folder = body.get("folder", "").strip("/")
            if not file_name or not file_content:
                return _resp(400, {"error": "fileName and fileContent required"})
            file_bytes = base64.b64decode(file_content)
            s3_key = f"{folder}/{file_name}" if folder else file_name
            if not _check_folder_access(user, s3_key, "write"):
                return _resp(403, {"error": "You have read-only access to this folder."})
            s3.put_object(Bucket=STORAGE_BUCKET, Key=s3_key, Body=file_bytes)
            print(f"Storage upload: s3://{STORAGE_BUCKET}/{s3_key} by {user['email']}")
            _log_activity(user["email"], "Uploaded", s3_key, user_name=user.get("name", ""))
            return _resp(200, {"message": "File uploaded", "key": s3_key})
        except Exception as e:
            print(f"Storage upload error: {e}")
            return _resp(500, {"error": "Failed to upload file"})

    # POST /dashboard/delete-folder
    if path.endswith("/dashboard/delete-folder") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            prefix = body.get("prefix", "").strip()
            if not prefix or not prefix.endswith("/"):
                return _resp(400, {"error": "Folder prefix required"})
            if not _check_folder_access(user, prefix, "write"):
                return _resp(403, {"error": "You have read-only access to this folder."})
            # List and delete all objects under this prefix
            objects_to_delete = []
            resp = s3.list_objects_v2(Bucket=STORAGE_BUCKET, Prefix=prefix)
            for obj in resp.get("Contents", []):
                objects_to_delete.append({"Key": obj["Key"]})
                dynamo.put_item(TableName=DELETION_LOG_TABLE, Item={
                    "fileKey": {"S": obj["Key"]},
                    "deletedBy": {"S": user["email"]},
                    "deletedAt": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                    "expiresAt": {"N": str(int(time.time()) + 30*24*60*60)}
                })
            if objects_to_delete:
                s3.delete_objects(Bucket=STORAGE_BUCKET, Delete={"Objects": objects_to_delete})
            print(f"Folder deleted: s3://{STORAGE_BUCKET}/{prefix} ({len(objects_to_delete)} objects) by {user['email']}")
            _log_activity(user["email"], "Deleted", f"Folder: {prefix} ({len(objects_to_delete)} files)", user_name=user.get("name", ""))
            return _resp(200, {"message": "Folder deleted", "count": len(objects_to_delete)})
        except Exception as e:
            print(f"Delete folder error: {e}")
            return _resp(500, {"error": "Failed to delete folder"})

    # POST /dashboard/create-folder
    if path.endswith("/dashboard/create-folder") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            folder = body.get("folder", "").strip()
            if not folder or not folder.endswith("/"):
                return _resp(400, {"error": "Folder path required (must end with /)"})
            if not _check_folder_access(user, folder, "write"):
                return _resp(403, {"error": "You have read-only access to this folder."})
            s3.put_object(Bucket=STORAGE_BUCKET, Key=folder, Body=b"")
            print(f"Folder created: s3://{STORAGE_BUCKET}/{folder} by {user['email']}")
            _log_activity(user["email"], "Created", f"Folder: {folder}", user_name=user.get("name", ""))
            return _resp(200, {"message": "Folder created", "folder": folder})
        except Exception as e:
            print(f"Create folder error: {e}")
            return _resp(500, {"error": "Failed to create folder"})

    # POST /dashboard/upload-presign
    if path.endswith("/dashboard/upload-presign") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            file_name = body.get("fileName", "")
            folder = body.get("folder", "").strip("/")
            bucket = body.get("bucket", "storage")
            if not file_name:
                return _resp(400, {"error": "fileName required"})
            if bucket == "delivery":
                s3_key = f"{DELIVERY_FOLDER}/{file_name}"
                target_bucket = DELIVERY_BUCKET
            else:
                s3_key = f"{folder}/{file_name}" if folder else file_name
                target_bucket = STORAGE_BUCKET
                if not _check_folder_access(user, s3_key, "write"):
                    return _resp(403, {"error": "You have read-only access to this folder."})
            url = s3.generate_presigned_url("put_object",
                Params={"Bucket": target_bucket, "Key": s3_key}, ExpiresIn=3600)
            return _resp(200, {"url": url, "key": s3_key})
        except Exception as e:
            print(f"Presign error: {e}")
            return _resp(500, {"error": "Failed to generate upload URL"})

    # GET /dashboard/deleted
    if path.endswith("/dashboard/deleted") and method == "GET":
        try:
            params = event.get("queryStringParameters") or {}
            page_token = params.get("pageToken", "")
            s3_params = {"Bucket": STORAGE_BUCKET, "MaxKeys": 100}
            if page_token:
                s3_params["KeyMarker"] = params.get("keyMarker", "")
                s3_params["VersionIdMarker"] = page_token
            resp = s3.list_object_versions(**s3_params)
            deleted = []
            for marker in resp.get("DeleteMarkers", []):
                if marker.get("IsLatest"):
                    deleted.append({
                        "key": marker["Key"],
                        "name": marker["Key"].split("/")[-1],
                        "deletedAt": marker["LastModified"].isoformat(),
                        "versionId": marker["VersionId"]
                    })
            for item in deleted:
                try:
                    log = dynamo.get_item(TableName=DELETION_LOG_TABLE, Key={"fileKey": {"S": item["key"]}})
                    rec = log.get("Item")
                    item["deletedBy"] = rec["deletedBy"]["S"] if rec else "Unknown"
                except Exception:
                    item["deletedBy"] = "Unknown"
            deleted.sort(key=lambda x: x["deletedAt"], reverse=True)
            # Filter by folder access
            allowed = user.get("allowed_folders", "")
            if allowed:
                perms = _parse_folder_permissions(allowed)
                deleted = [d for d in deleted if any(d["key"].startswith(a) for a, p in perms)]
            # Non-admin users only see files they deleted
            if not _is_admin():
                deleted = [d for d in deleted if d.get("deletedBy") == user["email"]]
            result = {"files": deleted}
            if resp.get("IsTruncated"):
                result["nextPageToken"] = resp.get("NextVersionIdMarker", "")
                result["nextKeyMarker"] = resp.get("NextKeyMarker", "")
            return _resp(200, result)
        except Exception as e:
            print(f"Deleted files error: {e}")
            return _resp(500, {"error": "Failed to list deleted files"})

    # POST /dashboard/restore
    if path.endswith("/dashboard/restore") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            key = body.get("key", "").strip()
            version_id = body.get("versionId", "").strip()
            if not key or not version_id:
                return _resp(400, {"error": "key and versionId required"})
            s3.delete_object(Bucket=STORAGE_BUCKET, Key=key, VersionId=version_id)
            dynamo.delete_item(TableName=DELETION_LOG_TABLE, Key={"fileKey": {"S": key}})
            print(f"File restored: s3://{STORAGE_BUCKET}/{key} by {user['email']}")
            _log_activity(user["email"], "Restored", key, user_name=user.get("name", ""))
            return _resp(200, {"message": "File restored", "key": key})
        except Exception as e:
            print(f"Restore error: {e}")
            return _resp(500, {"error": "Failed to restore file"})

    # GET /dashboard/files
    if path.endswith("/dashboard/files") and method == "GET":
        try:
            prefix = event.get("queryStringParameters", {}).get("prefix", "") if event.get("queryStringParameters") else ""
            if not _check_folder_access(user, prefix):
                return _resp(403, {"error": "Access denied"})
            resp = s3.list_objects_v2(Bucket=STORAGE_BUCKET, Prefix=prefix, Delimiter="/")
            
            folders = [p["Prefix"].rstrip("/").split("/")[-1] + "/" for p in resp.get("CommonPrefixes", [])]
            files = [{"name": o["Key"].split("/")[-1], "key": o["Key"], "size": o["Size"], 
                      "lastModified": o["LastModified"].isoformat()} 
                     for o in resp.get("Contents", []) if not o["Key"].endswith("/")]
            
            folders = _filter_folders(user, folders, prefix)
            files = _filter_files(user, files)
            
            return _resp(200, {"folders": folders, "files": files, "prefix": prefix})
        except Exception as e:
            print(f"Files error: {e}")
            return _resp(500, {"error": "Failed to list files"})

    # POST /dashboard/delete
    if path.endswith("/dashboard/delete") and method == "POST":
        try:
            body = json.loads(event.get("body") or "{}")
            file_key = body.get("key", "").strip()
            if not file_key:
                return _resp(400, {"error": "Missing file key"})
            if not _check_folder_access(user, file_key, "write"):
                return _resp(403, {"error": "You have read-only access to this folder."})
            s3.delete_object(Bucket=STORAGE_BUCKET, Key=file_key)
            dynamo.put_item(TableName=DELETION_LOG_TABLE, Item={
                "fileKey": {"S": file_key},
                "deletedBy": {"S": user["email"]},
                "deletedAt": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                "expiresAt": {"N": str(int(time.time()) + 30*24*60*60)}
            })
            print(f"File deleted: s3://{STORAGE_BUCKET}/{file_key} by {user['email']}")
            _log_activity(user["email"], "Deleted", file_key, user_name=user.get("name", ""))
            return _resp(200, {"message": "File deleted", "key": file_key})
        except Exception as e:
            print(f"Delete error: {e}")
            return _resp(500, {"error": "Failed to delete file"})

    # GET /dashboard/download
    if path.endswith("/dashboard/download") and method == "GET":
        try:
            params = event.get("queryStringParameters") or {}
            file_key = params.get("key", "").strip()
            mode = params.get("mode", "download")
            if not file_key:
                return _resp(400, {"error": "Missing file key"})
            if not _check_folder_access(user, file_key):
                return _resp(403, {"error": "Access denied"})
            s3_params = {"Bucket": STORAGE_BUCKET, "Key": file_key}
            if mode == "preview":
                s3_params["ResponseContentDisposition"] = "inline"
                ext = file_key.rsplit(".", 1)[-1].lower() if "." in file_key else ""
                content_types = {"pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp"}
                if ext in content_types:
                    s3_params["ResponseContentType"] = content_types[ext]
            url = s3.generate_presigned_url("get_object", Params=s3_params, ExpiresIn=3600)
            if mode != "preview":
                _log_activity(user["email"], "Downloaded", file_key, user_name=user.get("name", ""))
            else:
                _log_activity(user["email"], "Viewed", file_key, user_name=user.get("name", ""))
            return _resp(200, {"url": url})
        except Exception as e:
            print(f"Download error: {e}")
            return _resp(500, {"error": "Failed to generate download link"})

    # GET /dashboard/snapshot
    if path.endswith("/dashboard/snapshot") and method == "GET":
        try:
            total_size = 0
            total_count = 0
            bucket_sizes = {}
            buckets = s3.list_buckets().get("Buckets", [])
            for bucket in buckets:
                bucket_name = bucket["Name"]
                bucket_size = 0
                bucket_count = 0
                ver_params = {"Bucket": bucket_name}
                while True:
                    try:
                        resp = s3.list_object_versions(**ver_params)
                        for obj in resp.get("Versions", []):
                            bucket_size += obj.get("Size", 0)
                            bucket_count += 1
                        for marker in resp.get("DeleteMarkers", []):
                            bucket_count += 1
                        if resp.get("IsTruncated"):
                            ver_params["KeyMarker"] = resp.get("NextKeyMarker", "")
                            ver_params["VersionIdMarker"] = resp.get("NextVersionIdMarker", "")
                        else:
                            break
                    except Exception:
                        break
                total_size += bucket_size
                total_count += bucket_count
                bucket_sizes[bucket_name] = bucket_size
            avg_size = total_size / total_count if total_count > 0 else 0
            # Bucket breakdown
            bucket_list = sorted(bucket_sizes.items(), key=lambda x: x[1], reverse=True)
            # Folder breakdown for storage bucket only
            folder_sizes = {}
            try:
                s3_params = {"Bucket": STORAGE_BUCKET}
                while True:
                    resp = s3.list_objects_v2(**s3_params)
                    for obj in resp.get("Contents", []):
                        parts = obj["Key"].split("/")
                        folder = parts[0] + "/" if len(parts) > 1 else "(root)"
                        folder_sizes[folder] = folder_sizes.get(folder, 0) + obj["Size"]
                    if resp.get("IsTruncated"):
                        s3_params["ContinuationToken"] = resp["NextContinuationToken"]
                    else:
                        break
            except Exception:
                pass
            folders = sorted(folder_sizes.items(), key=lambda x: x[1], reverse=True)
            storage_check = _check_storage_limit_and_notify(user.get("email", ""))
            return _resp(200, {
                "totalStorage": total_size, "objectCount": total_count, "avgObjectSize": avg_size,
                "bucketBreakdown": [{"bucket": b, "size": s} for b, s in bucket_list],
                "folderBreakdown": [{"folder": f, "size": s} for f, s in folders],
                "storageLimit": storage_check
            })
        except Exception as e:
            print(f"Snapshot error: {e}")
            return _resp(500, {"error": "Failed to load storage snapshot"})

    # GET /dashboard/activity
    if path.endswith("/dashboard/activity") and method == "GET":
        try:
            items = []
            scan_params = {"TableName": ACTIVITY_LOG_TABLE, "Limit": 500}
            while True:
                resp = dynamo.scan(**scan_params)
                for item in resp.get("Items", []):
                    items.append({
                        "user": item.get("user", {}).get("S", ""),
                        "email": item.get("email", {}).get("S", ""),
                        "action": item.get("action", {}).get("S", ""),
                        "detail": item.get("detail", {}).get("S", ""),
                        "timestamp": item.get("timestamp", {}).get("S", ""),
                    })
                if resp.get("LastEvaluatedKey"):
                    scan_params["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
                else:
                    break
            items.sort(key=lambda x: x.get("timestamp", ""), reverse=True)
            return _resp(200, {"activities": items})
        except Exception as e:
            print(f"Activity log error: {e}")
            return _resp(500, {"error": "Failed to load activity log"})

    # GET /dashboard/notifications
    if path.endswith("/dashboard/notifications") and method == "GET":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            items = []
            scan_params = {"TableName": NOTIFICATIONS_TABLE}
            while True:
                resp = dynamo.scan(**scan_params)
                for item in resp.get("Items", []):
                    nid = item.get("notificationId", {}).get("S", "")
                    # Clean up old date-based notifications
                    import re
                    if re.match(r"storage-\w+-\d{4}-\d{2}-\d{2}", nid):
                        try:
                            dynamo.delete_item(TableName=NOTIFICATIONS_TABLE, Key={"notificationId": {"S": nid}})
                        except Exception:
                            pass
                        continue
                    items.append({
                        "id": nid,
                        "type": item.get("type", {}).get("S", ""),
                        "message": item.get("message", {}).get("S", ""),
                        "read": item.get("read", {}).get("S", "false") == "true",
                        "timestamp": item.get("timestamp", {}).get("S", "")
                    })
                if resp.get("LastEvaluatedKey"):
                    scan_params["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
                else:
                    break
            items.sort(key=lambda x: x["timestamp"], reverse=True)
            return _resp(200, {"notifications": items})
        except Exception as e:
            print(f"Notifications error: {e}")
            return _resp(500, {"error": "Failed to load notifications"})

    # POST /dashboard/notifications (mark as read)
    if path.endswith("/dashboard/notifications") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            action = body.get("action", "")
            print(f"Notifications POST action: {action}")
            if action == "markAllRead":
                scan_resp = dynamo.scan(TableName=NOTIFICATIONS_TABLE)
                for item in scan_resp.get("Items", []):
                    dynamo.update_item(
                        TableName=NOTIFICATIONS_TABLE,
                        Key={"notificationId": item["notificationId"]},
                        UpdateExpression="SET #r = :v",
                        ExpressionAttributeNames={"#r": "read"},
                        ExpressionAttributeValues={":v": {"S": "true"}}
                    )
                    print(f"Marked as read: {item['notificationId']['S']}")
            return _resp(200, {"message": "Notifications updated"})
        except Exception as e:
            print(f"Notifications update error: {e}")
            return _resp(500, {"error": "Failed to update notifications"})

    # ========= Admin Endpoints =========

    # GET /dashboard/users
    if path.endswith("/dashboard/users") and method == "GET":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            users_list = []
            list_params = {"UserPoolId": COGNITO_USER_POOL_ID, "Limit": 60}
            while True:
                resp = cognito.list_users(**list_params)
                for u in resp.get("Users", []):
                    email_attr = ""
                    allowed_folders_attr = ""
                    name_attr = ""
                    for attr in u.get("Attributes", []):
                        if attr["Name"] == "email":
                            email_attr = attr["Value"]
                        if attr["Name"] == "custom:allowed_folders":
                            allowed_folders_attr = attr["Value"]
                        if attr["Name"] == "name":
                            name_attr = attr["Value"]
                    groups = cognito.admin_list_groups_for_user(
                        UserPoolId=COGNITO_USER_POOL_ID, Username=u["Username"])
                    role = "Admin" if any(g["GroupName"] == "admin" for g in groups.get("Groups", [])) else "User"
                    users_list.append({
                        "username": u["Username"],
                        "email": email_attr,
                        "name": name_attr,
                        "status": u.get("UserStatus", ""),
                        "enabled": u.get("Enabled", True),
                        "created": u.get("UserCreateDate", "").isoformat() if hasattr(u.get("UserCreateDate", ""), "isoformat") else str(u.get("UserCreateDate", "")),
                        "role": role,
                        "allowedFolders": allowed_folders_attr,
                        "lastLogin": "",
                        "mfaEnabled": False
                    })
                    # Get last login
                    try:
                        ll = dynamo.get_item(TableName=ACTIVITY_LOG_TABLE, Key={"activityId": {"S": f"lastlogin-{email_attr}"}})
                        if ll.get("Item"):
                            users_list[-1]["lastLogin"] = ll["Item"].get("timestamp", {}).get("S", "")
                    except Exception:
                        pass
                    # Check MFA status - use our own tracking
                    try:
                        mfa_log = dynamo.get_item(TableName=ACTIVITY_LOG_TABLE, Key={"activityId": {"S": f"mfa-enabled-{email_attr}"}})
                        users_list[-1]["mfaEnabled"] = bool(mfa_log.get("Item"))
                    except Exception:
                        pass
                if resp.get("PaginationToken"):
                    list_params["PaginationToken"] = resp["PaginationToken"]
                else:
                    break
            return _resp(200, {"users": users_list})
        except Exception as e:
            print(f"List users error: {e}")
            return _resp(500, {"error": "Failed to list users"})

    # POST /dashboard/users/create
    if path.endswith("/users/create") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            email = body.get("email", "").strip()
            temp_pw = body.get("tempPassword", "")
            make_admin = body.get("makeAdmin", False)
            allowed_folders = body.get("allowedFolders", "")
            full_name = body.get("fullName", "").strip()
            if not email or not temp_pw:
                return _resp(400, {"error": "Email and temporary password required"})
            user_attrs = [
                {"Name": "email", "Value": email},
                {"Name": "email_verified", "Value": "true"}
            ]
            if full_name:
                user_attrs.append({"Name": "name", "Value": full_name})
            if allowed_folders:
                user_attrs.append({"Name": "custom:allowed_folders", "Value": allowed_folders})
            cognito.admin_create_user(
                UserPoolId=COGNITO_USER_POOL_ID,
                Username=email,
                TemporaryPassword=temp_pw,
                UserAttributes=user_attrs,
                MessageAction="SUPPRESS"
            )
            if make_admin:
                cognito.admin_add_user_to_group(
                    UserPoolId=COGNITO_USER_POOL_ID, Username=email, GroupName="admin")
            print(f"User created: {email} by {user['email']} (admin={make_admin}, folders={allowed_folders})")
            _log_activity(user["email"], "Created User", email, user_name=user.get("name", ""))
            return _resp(200, {"message": "User created", "email": email, "welcomeMessage": f"Welcome! Your dashboard is ready.\n\nEmail: {email}\nTemporary Password: {temp_pw}\n\nPlease log in and set your new password."})
        except cognito.exceptions.UsernameExistsException:
            return _resp(400, {"error": "User already exists"})
        except Exception as e:
            print(f"Create user error: {e}")
            return _resp(500, {"error": "Failed to create user"})

    # POST /dashboard/users/update-access
    if path.endswith("/users/update-access") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            allowed_folders = body.get("allowedFolders", "")
            if not username:
                return _resp(400, {"error": "Username required"})
            cognito.admin_update_user_attributes(
                UserPoolId=COGNITO_USER_POOL_ID,
                Username=username,
                UserAttributes=[{"Name": "custom:allowed_folders", "Value": allowed_folders}]
            )
            print(f"Folder access updated: {username} -> {allowed_folders} by {user['email']}")
            _log_activity(user["email"], "Updated Access", f"{username}: {allowed_folders or 'Full Access'}", user_name=user.get("name", ""))
            return _resp(200, {"message": "Folder access updated"})
        except Exception as e:
            print(f"Update access error: {e}")
            return _resp(500, {"error": "Failed to update folder access"})

    # POST /dashboard/users/change-email
    if path.endswith("/users/change-email") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            old_username = body.get("username", "").strip()
            new_email = body.get("newEmail", "").strip()
            temp_pw = body.get("tempPassword", "")
            if not old_username or not new_email or not temp_pw:
                return _resp(400, {"error": "Username, new email, and temp password required"})
            # Get old user's attributes
            old_user = cognito.admin_get_user(UserPoolId=COGNITO_USER_POOL_ID, Username=old_username)
            old_attrs = {a["Name"]: a["Value"] for a in old_user.get("UserAttributes", [])}
            old_name = old_attrs.get("name", "")
            old_folders = old_attrs.get("custom:allowed_folders", "")
            # Check old user's groups
            old_groups = cognito.admin_list_groups_for_user(UserPoolId=COGNITO_USER_POOL_ID, Username=old_username)
            was_admin = any(g["GroupName"] == "admin" for g in old_groups.get("Groups", []))
            # Create new user
            new_attrs = [{"Name": "email", "Value": new_email}, {"Name": "email_verified", "Value": "true"}]
            if old_name:
                new_attrs.append({"Name": "name", "Value": old_name})
            if old_folders:
                new_attrs.append({"Name": "custom:allowed_folders", "Value": old_folders})
            cognito.admin_create_user(
                UserPoolId=COGNITO_USER_POOL_ID, Username=new_email,
                TemporaryPassword=temp_pw, UserAttributes=new_attrs, MessageAction="SUPPRESS")
            if was_admin:
                cognito.admin_add_user_to_group(UserPoolId=COGNITO_USER_POOL_ID, Username=new_email, GroupName="admin")
            # Delete old user
            cognito.admin_delete_user(UserPoolId=COGNITO_USER_POOL_ID, Username=old_username)
            print(f"Email changed: {old_username} -> {new_email} by {user['email']}")
            _log_activity(user["email"], "Changed Email", f"{old_username} -> {new_email}", user_name=user.get("name", ""))
            welcome = f"Your email has been updated.\n\nNew Email: {new_email}\nTemporary Password: {temp_pw}\n\nPlease log in and set your new password."
            return _resp(200, {"message": "Email changed", "welcomeMessage": welcome})
        except cognito.exceptions.UsernameExistsException:
            return _resp(400, {"error": "New email already exists"})
        except Exception as e:
            print(f"Change email error: {e}")
            return _resp(500, {"error": "Failed to change email"})

    # POST /dashboard/users/disable
    if path.endswith("/users/disable") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            if not username:
                return _resp(400, {"error": "Username required"})
            cognito.admin_disable_user(UserPoolId=COGNITO_USER_POOL_ID, Username=username)
            print(f"User disabled: {username} by {user['email']}")
            _log_activity(user["email"], "Disabled User", username, user_name=user.get("name", ""))
            return _resp(200, {"message": "User disabled"})
        except Exception as e:
            print(f"Disable user error: {e}")
            return _resp(500, {"error": "Failed to disable user"})

    # POST /dashboard/users/delete
    if path.endswith("/users/delete") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            if not username:
                return _resp(400, {"error": "Username required"})
            if username == user["username"]:
                return _resp(400, {"error": "Cannot delete yourself"})
            cognito.admin_delete_user(UserPoolId=COGNITO_USER_POOL_ID, Username=username)
            print(f"User deleted: {username} by {user['email']}")
            _log_activity(user["email"], "Deleted User", username, user_name=user.get("name", ""))
            return _resp(200, {"message": "User deleted"})
        except Exception as e:
            print(f"Delete user error: {e}")
            return _resp(500, {"error": "Failed to delete user"})

    # POST /dashboard/users/enable
    if path.endswith("/users/enable") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            if not username:
                return _resp(400, {"error": "Username required"})
            cognito.admin_enable_user(UserPoolId=COGNITO_USER_POOL_ID, Username=username)
            print(f"User enabled: {username} by {user['email']}")
            _log_activity(user["email"], "Enabled User", username, user_name=user.get("name", ""))
            return _resp(200, {"message": "User enabled"})
        except Exception as e:
            print(f"Enable user error: {e}")
            return _resp(500, {"error": "Failed to enable user"})

    # POST /dashboard/users/make-admin
    if path.endswith("/users/make-admin") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            if not username:
                return _resp(400, {"error": "Username required"})
            cognito.admin_add_user_to_group(
                UserPoolId=COGNITO_USER_POOL_ID, Username=username, GroupName="admin")
            print(f"User promoted to admin: {username} by {user['email']}")
            _log_activity(user["email"], "Made Admin", username, user_name=user.get("name", ""))
            return _resp(200, {"message": "User promoted to admin"})
        except Exception as e:
            print(f"Make admin error: {e}")
            return _resp(500, {"error": "Failed to promote user"})

    # POST /dashboard/users/remove-admin
    if path.endswith("/users/remove-admin") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            if not username:
                return _resp(400, {"error": "Username required"})
            cognito.admin_remove_user_from_group(
                UserPoolId=COGNITO_USER_POOL_ID, Username=username, GroupName="admin")
            print(f"User demoted from admin: {username} by {user['email']}")
            _log_activity(user["email"], "Removed Admin", username, user_name=user.get("name", ""))
            return _resp(200, {"message": "Admin role removed"})
        except Exception as e:
            print(f"Remove admin error: {e}")
            return _resp(500, {"error": "Failed to remove admin role"})

    # POST /dashboard/users/reset-mfa
    if path.endswith("/users/reset-mfa") and method == "POST":
        if not _is_admin():
            return _resp(403, {"error": "Admin access required"})
        try:
            body = json.loads(event.get("body") or "{}")
            username = body.get("username", "").strip()
            if not username:
                return _resp(400, {"error": "Username required"})
            cognito.admin_set_user_mfa_preference(
                UserPoolId=COGNITO_USER_POOL_ID,
                Username=username,
                SoftwareTokenMfaSettings={"Enabled": False, "PreferredMfa": False}
            )
            # Remove MFA tracking record
            try:
                dynamo.delete_item(TableName=ACTIVITY_LOG_TABLE, Key={"activityId": {"S": f"mfa-enabled-{username}"}})
            except Exception:
                pass
            print(f"MFA reset: {username} by {user['email']}")
            _log_activity(user["email"], "Reset MFA", username, user_name=user.get("name", ""))
            return _resp(200, {"message": "MFA reset. User will set up MFA on next login."})
        except Exception as e:
            print(f"Reset MFA error: {e}")
            return _resp(500, {"error": "Failed to reset MFA"})

    return _resp(404, {"error": "Not found"})
