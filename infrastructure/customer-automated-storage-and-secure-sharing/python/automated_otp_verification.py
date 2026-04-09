import os
import re
import json
import base64
import urllib.parse
import hashlib
import hmac
import time
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

# ========= Environment =========
OTP_TABLE          = os.environ["OTP_TABLE"]
FROM_EMAIL         = os.environ["FROM_EMAIL"]
DEFAULT_ORG_TIMEZONE = os.getenv("DEFAULT_ORG_TIMEZONE", "Africa/Lagos")
INVITE_TTL_HOURS   = int(os.getenv("INVITE_TTL_HOURS", "48"))
OTP_TTL_MINUTES    = int(os.getenv("OTP_TTL_MINUTES", "5"))
MAX_OTPS_PER_DAY   = int(os.getenv("MAX_OTPS_PER_DAY", "2"))

SOCIAL_ACCOUNT_ID  = os.getenv("SOCIAL_ACCOUNT_ID", "383531456861")
SOCIAL_ROLE_NAME   = os.getenv("SOCIAL_ROLE_NAME", "DevSocialSenderRole")
MAILHUB_ACCOUNT_ID = os.getenv("MAILHUB_ACCOUNT_ID")
MAILHUB_ROLE_NAME  = os.getenv("MAILHUB_ROLE_NAME", "centralized-ses-role")
MAILHUB_REGION     = os.getenv("MAILHUB_REGION", "us-east-1")

WHATSAPP_TEMPLATE_OTP                = os.getenv("WHATSAPP_TEMPLATE_OTP", "otpverification")
WHATSAPP_LOCALE                      = os.getenv("WHATSAPP_LOCALE", "en_US")
WHATSAPP_ORIGINATION_PHONE_NUMBER_ID = os.environ["WHATSAPP_ORIGINATION_PHONE_NUMBER_ID"]
WHATSAPP_META_API_VERSION            = os.getenv("WHATSAPP_META_API_VERSION", "v20.0")

# ========= Clients =========
s3     = boto3.client("s3")
dynamo = boto3.client("dynamodb")
sts    = boto3.client("sts")

# ========= Helpers =========
def _now():
    return datetime.now(timezone.utc)

def _sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

def _cteq(a: str, b: str) -> bool:
    return hmac.compare_digest(a, b)

def _parse_form_urlencoded(body: str) -> dict:
    return {k: v[0] if isinstance(v, list) else v
            for k, v in urllib.parse.parse_qs(body or "", keep_blank_values=True).items()}

def _assume_role_with(creds, role_arn, session_name):
    client = sts if creds is None else boto3.client(
        "sts", aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"], region_name=MAILHUB_REGION)
    return client.assume_role(RoleArn=role_arn, RoleSessionName=session_name)["Credentials"]

def _assume_mailhub(session_name):
    return _assume_role_with(None, f"arn:aws:iam::{MAILHUB_ACCOUNT_ID}:role/{MAILHUB_ROLE_NAME}", session_name)

def _mailhub_ses():
    c = _assume_mailhub("cs-auto-otp-ses")
    return boto3.client("ses", region_name=MAILHUB_REGION,
        aws_access_key_id=c["AccessKeyId"], aws_secret_access_key=c["SecretAccessKey"],
        aws_session_token=c["SessionToken"])

def _mailhub_social():
    hop1 = _assume_mailhub("cs-auto-social-hop1")
    hop2 = _assume_role_with(hop1, f"arn:aws:iam::{SOCIAL_ACCOUNT_ID}:role/{SOCIAL_ROLE_NAME}", "cs-auto-social-hop2")
    return boto3.client("socialmessaging", region_name=MAILHUB_REGION,
        aws_access_key_id=hop2["AccessKeyId"], aws_secret_access_key=hop2["SecretAccessKey"],
        aws_session_token=hop2["SessionToken"])

def _send_with_retry(fn, attempts=3, base_delay=0.4):
    for i in range(1, attempts + 1):
        try:
            return fn()
        except ClientError as e:
            print(f"[retry] attempt {i} failed:", getattr(e, "response", {}))
            if i == attempts:
                raise
            time.sleep(base_delay * (2 ** (i - 1)))

# ========= Event Parsing =========
def _get_path(event):
    http = (event.get("requestContext") or {}).get("http") or {}
    return (event.get("rawPath") or http.get("path") or event.get("path") or "").rstrip("/")

def _get_method(event):
    http = (event.get("requestContext") or {}).get("http") or {}
    return (http.get("method") or event.get("httpMethod") or "GET").upper()

def _get_query(event):
    if event.get("rawQueryString"):
        return urllib.parse.parse_qs(event["rawQueryString"])
    qsp = event.get("queryStringParameters") or {}
    return {k: [v] for k, v in qsp.items() if v is not None}

# ========= DDB Helpers =========
def _ddb_get(rid):
    return dynamo.get_item(TableName=OTP_TABLE, Key={"requestId": {"S": rid}}).get("Item")

def _ddb_create_otp_with_quota(rid, otp_hash, otp_expires_at, max_otps):
    now = int(_now().timestamp())
    window_end = now + 86400

    try:
        dynamo.update_item(TableName=OTP_TABLE, Key={"requestId": {"S": rid}},
            ConditionExpression="(attribute_not_exists(otpHash) OR :now > otpExpiresAt) AND (attribute_not_exists(otpDailyWindowEnd) OR :now >= otpDailyWindowEnd)",
            UpdateExpression="SET #s=:otpsent, otpHash=:h, otpExpiresAt=:e, otpDailyWindowEnd=:win_end, otpDailyCount=:one",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":otpsent": {"S": "OTP_SENT"}, ":h": {"S": otp_hash}, ":e": {"N": str(otp_expires_at)},
                ":now": {"N": str(now)}, ":win_end": {"N": str(window_end)}, ":one": {"N": "1"}})
        return True
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise

    try:
        dynamo.update_item(TableName=OTP_TABLE, Key={"requestId": {"S": rid}},
            ConditionExpression="(attribute_not_exists(otpHash) OR :now > otpExpiresAt) AND attribute_exists(otpDailyWindowEnd) AND :now < otpDailyWindowEnd AND otpDailyCount < :max",
            UpdateExpression="SET #s=:otpsent, otpHash=:h, otpExpiresAt=:e, otpDailyCount = if_not_exists(otpDailyCount,:z) + :one",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":otpsent": {"S": "OTP_SENT"}, ":h": {"S": otp_hash}, ":e": {"N": str(otp_expires_at)},
                ":now": {"N": str(now)}, ":z": {"N": "0"}, ":one": {"N": "1"}, ":max": {"N": str(max_otps)}})
        return True
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise

def _ddb_clear_otp(rid, rollback_quota=False):
    try:
        if rollback_quota:
            try:
                dynamo.update_item(TableName=OTP_TABLE, Key={"requestId": {"S": rid}},
                    ConditionExpression="attribute_exists(otpDailyCount) AND otpDailyCount > :z",
                    UpdateExpression="SET #s=:inv, otpDailyCount = otpDailyCount - :one REMOVE otpHash, otpExpiresAt",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":inv": {"S": "INVITED"}, ":z": {"N": "0"}, ":one": {"N": "1"}})
                return
            except ClientError as e:
                if e.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                    raise
        dynamo.update_item(TableName=OTP_TABLE, Key={"requestId": {"S": rid}},
            UpdateExpression="SET #s=:inv REMOVE otpHash, otpExpiresAt",
            ExpressionAttributeNames={"#s": "status"}, ExpressionAttributeValues={":inv": {"S": "INVITED"}})
    except Exception as e:
        print("Clear OTP failed:", repr(e))

def _ddb_mark_verified(rid):
    dynamo.update_item(TableName=OTP_TABLE, Key={"requestId": {"S": rid}},
        UpdateExpression="SET #s=:v, verifiedAt=:ts", ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":v": {"S": "VERIFIED"}, ":ts": {"S": _now().isoformat()}})

# ========= WhatsApp OTP =========
def _send_whatsapp_otp(phone, template, locale, otp_code):
    sm = _mailhub_social()
    payload_btn = {"messaging_product": "whatsapp", "to": phone, "type": "template",
        "template": {"name": template, "language": {"code": locale}, "components": [
            {"type": "body", "parameters": [{"type": "text", "text": otp_code}]},
            {"type": "button", "sub_type": "url", "index": "0", "parameters": [{"type": "text", "text": otp_code}]}]}}
    payload_body = {"messaging_product": "whatsapp", "to": phone, "type": "template",
        "template": {"name": template, "language": {"code": locale}, "components": [
            {"type": "body", "parameters": [{"type": "text", "text": otp_code}]}]}}

    def _send(p):
        return _send_with_retry(lambda: sm.send_whatsapp_message(
            originationPhoneNumberId=WHATSAPP_ORIGINATION_PHONE_NUMBER_ID,
            message=json.dumps(p).encode("utf-8"), metaApiVersion=WHATSAPP_META_API_VERSION))
    try:
        return _send(payload_btn)
    except ClientError as e:
        msg = str(getattr(e, "response", {}).get("Error", {}).get("Message", ""))
        if any(s in msg.lower() for s in ["button", "sub_type", "url", "parameter", "not allowed"]):
            return _send(payload_body)
        raise

# ========= Non-Repudiation Email =========
EMAIL_REGEX = r"[^@]+@[^@]+\.[^@]+"

def _send_nonrepudiation_email(org_email: str, org_name: str, recipient_name: str | None, local_tz: str):
    ses = _mailhub_ses()
    ts = _now().astimezone(timezone.utc).isoformat()
    name_row = f'<tr><td style="padding:12px 16px;font-weight:600;color:#1e40af;font-size:14px;text-transform:uppercase;letter-spacing:0.5px;">Recipient Name</td><td style="padding:12px 16px;color:#16a34a;font-size:17px;font-weight:700;">{recipient_name}</td></tr>' if recipient_name else ""
    html = f"""
    <html><body style="font-family:'Segoe UI',Roboto,Arial,sans-serif;line-height:1.7;color:#1e293b;margin:0;padding:0;background:#f1f5f9;">
      <div style="max-width:600px;margin:40px auto;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 8px 30px rgba(0,0,0,.1);">
        <div style="background:linear-gradient(135deg,#16a34a,#22c55e,#4ade80);padding:32px;text-align:center;">
          <div style="font-size:36px;margin-bottom:8px;">\u2705</div>
          <h1 style="margin:0;color:#ffffff;font-size:22px;font-weight:700;">Delivery Confirmation</h1>
        </div>
        <div style="padding:36px 32px 28px;">
          <p style="font-size:17px;color:#1e293b;font-weight:600;">This is to confirm that a secured file delivery was completed.</p>
          <div style="border:1px solid #e2e8f0;border-radius:12px;overflow:hidden;margin:20px 0;">
            <table style="width:100%;border-collapse:collapse;background:#fafbfc;">
              {name_row}
              <tr style="border-top:1px solid #e2e8f0;"><td style="padding:12px 16px;font-weight:600;color:#1e40af;font-size:14px;text-transform:uppercase;letter-spacing:0.5px;">Date Delivered (UTC)</td><td style="padding:12px 16px;color:#16a34a;font-size:17px;font-weight:700;">{ts}</td></tr>
            </table>
          </div>
          <p style="font-size:15px;color:#1e40af;font-weight:600;font-style:italic;">This email serves as an official record of delivery.</p>
          <div style="margin-top:24px;padding-top:16px;border-top:1px solid #e2e8f0;">
            <p style="font-size:17px;color:#16a34a;font-weight:600;margin:0;">Thank you,</p>
            <p style="font-size:17px;font-weight:700;color:#16a34a;margin:4px 0 0 0;">The Cloud Sentrics Team</p>
          </div>
        </div>
        <div style="background:#f0fdf4;padding:20px 32px;text-align:center;border-top:1px solid #dcfce7;">
          <p style="margin:0;font-size:13px;font-weight:600;color:#16a34a;">
            \U0001f6e1\ufe0f Secure delivery powered by Cloud Sentrics
          </p>
        </div>
      </div>
    </body></html>
    """
    source_header = f"Cloud Sentrics <{FROM_EMAIL}>"
    ses.send_email(
        Source=source_header,
        Destination={"ToAddresses": [org_email]},
        Message={"Subject": {"Data": "Delivery confirmation"}, "Body": {"Html": {"Data": html}}}
    )

# ========= HTML Responses =========
def _resp_html(code, html):
    return {"statusCode": code, "headers": {"Content-Type": "text/html; charset=utf-8"}, "body": html}

def _mask_phone(phone):
    if not phone or len(phone) < 7:
        return phone
    keep_prefix = 3 if phone[0] == '+' else 2
    return phone[:keep_prefix] + '\u2022' * max(0, len(phone) - keep_prefix - 4) + phone[-4:]

def _page_otp(rid, phone_label, error_msg=None):
    esc_rid = urllib.parse.quote(rid)
    error_html = f'<div style="background:#fef2f2;color:#991b1b;border:1px solid #fecaca;padding:10px 12px;border-radius:8px;margin-bottom:12px;">{error_msg}</div>' if error_msg else ""
    return f"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1"/><title>Verify to continue</title></head>
<body style="font-family:'Segoe UI',Roboto,Arial,sans-serif;background:#f1f5f9;color:#1e293b;margin:0;">
  <div style="max-width:600px;margin:40px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 8px 30px rgba(0,0,0,.1);">
    <div style="background:linear-gradient(135deg,#1e40af,#3b82f6,#0ea5e9);padding:32px;text-align:center;">
      <div style="font-size:40px;margin-bottom:8px;">\U0001f512</div>
      <h1 style="margin:0;color:#ffffff;font-size:22px;font-weight:700;">Enter One Time Passcode</h1>
    </div>
    <div style="padding:36px 32px 28px;">
      <p style="font-size:17px;color:#475569;">We have sent a one-time passcode to your WhatsApp number <strong style="color:#1e293b;">{phone_label}</strong>.</p>
      {error_html}
      <form method="POST" action="verify" style="margin-top:16px;" novalidate>
        <input type="hidden" name="rid" value="{esc_rid}">
        <input id="otp" name="otp" type="tel" inputmode="numeric" autocomplete="one-time-code"
               maxlength="6" aria-label="6-digit code"
               oninput="this.value=this.value.replace(/\\D/g,'').slice(0,6)"
               style="font-size:18px;padding:12px 14px;border:1px solid #cbd5e1;border-radius:8px;width:280px;"
               placeholder="Enter 6-digit code" required>
        <button type="submit" style="margin-left:8px;padding:12px 20px;border:none;border-radius:8px;background:linear-gradient(135deg,#16a34a,#22c55e);color:#fff;font-weight:700;font-size:15px;cursor:pointer;">
          Verify
        </button>
      </form>
    </div>
    <div style="background:#f8fafc;padding:20px 32px;text-align:center;border-top:1px solid #e2e8f0;">
      <p style="margin:0;font-size:13px;font-weight:600;color:#3b82f6;">\U0001f6e1\ufe0f Secure delivery powered by Cloud Sentrics</p>
    </div>
  </div>
</body></html>"""

def _page_download(presigned_url, recipient_name=None):
    esc = urllib.parse.quote(presigned_url, safe=":/?&=%")
    greeting = f"<p style=\"font-size:17px;margin-top:0;color:#1e40af;font-weight:600;\">Hello {recipient_name},</p>" if recipient_name else ""
    return f"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1"/><title>File Ready</title></head>
<body style="font-family:'Segoe UI',Roboto,Arial,sans-serif;background:#f1f5f9;color:#1e293b;margin:0;">
  <div style="max-width:600px;margin:40px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 8px 30px rgba(0,0,0,.1);">
    <div style="background:linear-gradient(135deg,#1e40af,#3b82f6,#0ea5e9);padding:32px;text-align:center;">
      <div style="font-size:40px;margin-bottom:8px;">\u2705</div>
      <h1 style="margin:0;color:#ffffff;font-size:22px;font-weight:700;">\u2713 Identity Verified</h1>
    </div>
    <div style="padding:36px 32px 28px;">
      {greeting}
      <p style="font-size:17px;color:#475569;">Your file is ready for download.</p>
      <div style="text-align:center;margin:24px 0;">
        <a href="{esc}" target="_blank"
           style="background:linear-gradient(135deg,#16a34a,#22c55e);color:#ffffff;padding:14px 40px;border-radius:50px;text-decoration:none;font-weight:700;font-size:15px;display:inline-block;box-shadow:0 4px 14px rgba(22,163,74,.35);">
          \U0001f4e5 Download File
        </a>
      </div>
      <p style="font-size:15px;color:#1e40af;font-weight:600;text-align:center;">This link expires automatically</p>
    </div>
    <div style="background:#f8fafc;padding:20px 32px;text-align:center;border-top:1px solid #e2e8f0;">
      <p style="margin:0;font-size:13px;font-weight:600;color:#3b82f6;">\U0001f6e1\ufe0f Secure delivery powered by Cloud Sentrics</p>
    </div>
  </div>
</body></html>"""

def _page_message(title, msg):
    return f"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1"/></head>
<body style="font-family:'Segoe UI',Roboto,Arial,sans-serif;background:#f1f5f9;color:#1e293b;margin:0;">
  <div style="max-width:600px;margin:40px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 8px 30px rgba(0,0,0,.1);">
    <div style="padding:36px 32px;">
      <h2 style="color:#1e293b;margin-top:0;">{title}</h2>
      <p style="font-size:17px;color:#475569;">{msg}</p>
    </div>
    <div style="background:#f8fafc;padding:20px 32px;text-align:center;border-top:1px solid #e2e8f0;">
      <p style="margin:0;font-size:13px;font-weight:600;color:#3b82f6;">\U0001f6e1\ufe0f Secure delivery powered by Cloud Sentrics</p>
    </div>
  </div>
</body></html>"""

# ========= Main Handler =========
def lambda_handler(event, context):
    path = _get_path(event)
    method = _get_method(event)

    # GET /start — validate token, send OTP
    if path.endswith("/start") and method == "GET":
        try:
            params = _get_query(event)
            rid = (params.get("rid") or [""])[0]
            tok = (params.get("tok") or [""])[0]

            item = _ddb_get(rid)
            if not item:
                return _resp_html(400, _page_message("Invalid link", "This request could not be found."))

            invite_exp = int(item["inviteExpiresAt"]["N"])
            if _now().timestamp() > invite_exp:
                return _resp_html(400, _page_message("Link expired", "Your verification link has expired."))

            stored_hash = item.get("linkTokenHash", {}).get("S")
            if not tok or not stored_hash or not _cteq(_sha256(tok), stored_hash):
                return _resp_html(400, _page_message("Invalid link", "The link is invalid."))

            phone = item["recipientPhone"]["S"]
            phone_label = _mask_phone(phone)

            existing_hash = (item.get("otpHash") or {}).get("S")
            existing_exp = int((item.get("otpExpiresAt") or {}).get("N", "0"))
            if existing_hash and int(_now().timestamp()) < existing_exp:
                return _resp_html(200, _page_otp(rid, phone_label))

            otp = f"{int.from_bytes(os.urandom(3), 'big') % 1000000:06d}"
            otp_hash = _sha256(otp)
            otp_exp = int((_now() + timedelta(minutes=OTP_TTL_MINUTES)).timestamp())

            try:
                created = _ddb_create_otp_with_quota(rid, otp_hash, otp_exp, MAX_OTPS_PER_DAY)
            except Exception as e:
                print("Set OTP failed:", repr(e))
                return _resp_html(500, _page_message("Error", "Could not start verification. Try again later."))

            if created:
                try:
                    _send_whatsapp_otp(phone, WHATSAPP_TEMPLATE_OTP, WHATSAPP_LOCALE, otp)
                except Exception as e:
                    print("WhatsApp send failed:", repr(e))
                    _ddb_clear_otp(rid, rollback_quota=True)
                    return _resp_html(500, _page_message("Error", "Could not send OTP. Please try again later."))
            else:
                item2 = _ddb_get(rid) or {}
                ex_h = (item2.get("otpHash") or {}).get("S")
                ex_e = int((item2.get("otpExpiresAt") or {}).get("N", "0"))
                if ex_h and int(_now().timestamp()) < ex_e:
                    return _resp_html(200, _page_otp(rid, phone_label))
                return _resp_html(400, _page_message("Verification unavailable",
                    "You've maxed out your code requests for today. Please try again in 24 hours"))

            return _resp_html(200, _page_otp(rid, phone_label))
        except Exception as e:
            print("Unhandled /start error:", repr(e))
            return _resp_html(500, _page_message("Error", "We couldn't start verification. Please try again later."))

    # POST /verify — validate OTP, show download
    if path.endswith("/verify") and method == "POST":
        body = event.get("body") or ""
        if event.get("isBase64Encoded"):
            try:
                body = base64.b64decode(body).decode("utf-8", errors="ignore")
            except Exception:
                body = ""
        form = _parse_form_urlencoded(body)
        rid = (form.get("rid") or "").strip()
        otp = (form.get("otp") or "").strip()

        try:
            item = _ddb_get(rid)
        except Exception as e:
            print("DDB get failed:", repr(e))
            return _resp_html(500, _page_message("Error", "We couldn't verify your code. Please try again later."))

        if not item:
            return _resp_html(400, _page_message("Invalid session", "Please request a new link."))

        invite_exp = int(item["inviteExpiresAt"]["N"])
        if _now().timestamp() > invite_exp:
            return _resp_html(400, _page_message("Expired", "Your session has expired."))

        if not re.fullmatch(r"\d{6}", otp or ""):
            phone = item["recipientPhone"]["S"]
            return _resp_html(200, _page_otp(rid, _mask_phone(phone), error_msg="Please enter the 6-digit code."))

        otp_hash = item.get("otpHash", {}).get("S")
        otp_exp = int(item.get("otpExpiresAt", {}).get("N", "0"))
        if not otp_hash or _now().timestamp() > otp_exp:
            return _resp_html(400, _page_message("OTP expired", "Your code expired. Click your email link again to resend."))

        if not _cteq(_sha256(otp), otp_hash):
            phone = item["recipientPhone"]["S"]
            return _resp_html(200, _page_otp(rid, _mask_phone(phone), error_msg="That code didn't work. Please try again."))

        try:
            _ddb_mark_verified(rid)
        except Exception as e:
            print("Mark verified failed:", repr(e))

        bucket = item["bucket"]["S"]
        key = item["key"]["S"]
        try:
            presigned = s3.generate_presigned_url("get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=172800)
        except Exception as e:
            print(f"Presign failed: {e}")
            return _resp_html(500, _page_message("Error", "Could not generate download link."))

        # Non-repudiation email
        try:
            bucket = item["bucket"]["S"]
            btags = s3.get_bucket_tagging(Bucket=bucket).get("TagSet", [])
            org_email = None
            org_name = "Your Organization"
            org_tz = DEFAULT_ORG_TIMEZONE
            recipient_name = (item.get("recipientName") or {}).get("S")
            for t in btags:
                k = t["Key"].lower()
                if k == "organizationemail": org_email = t["Value"]
                elif k == "organization":    org_name  = t["Value"] or org_name
                elif k == "organizationtimezone": org_tz = t["Value"] or org_tz
            if org_email and re.match(EMAIL_REGEX, org_email):
                _send_nonrepudiation_email(org_email, org_name, recipient_name, org_tz)
        except Exception as e:
            print(f"Non-repudiation email failed: {e}")

        r_name = (item.get("recipientName") or {}).get("S")
        return _resp_html(200, _page_download(presigned, recipient_name=r_name))

    return _resp_html(404, _page_message("Not Found", "The requested resource was not found."))
