import os
import re
import json
import base64
from datetime import datetime, timezone

import boto3

# ========= Environment =========
CUSTOMER_TABLE = os.environ["CUSTOMER_TABLE"]

# ========= Clients =========
s3     = boto3.client("s3")
dynamo = boto3.client("dynamodb")

# ========= Helpers =========
def _now():
    return datetime.now(timezone.utc)

def _sanitize_path(value: str) -> str:
    """Sanitize a string for use as an S3 key component."""
    return re.sub(r'[^a-zA-Z0-9_\-.]', '-', value.strip()).strip('-')

def _lookup_customer(api_key: str) -> dict | None:
    """Look up customer config by API key."""
    try:
        resp = dynamo.get_item(
            TableName=CUSTOMER_TABLE,
            Key={"apiKey": {"S": api_key}}
        )
        item = resp.get("Item")
        if not item:
            return None
        return {
            "bucket_name": item["bucketName"]["S"],
            "customer_name": item.get("customerName", {}).get("S", "Unknown"),
            "root_folder": item.get("rootFolder", {}).get("S", "records"),
        }
    except Exception as e:
        print(f"Customer lookup failed: {e}")
        return None

def _resp(code: int, body: dict) -> dict:
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
        "body": json.dumps(body)
    }

# ========= Internal Normalized Format =========
def _empty_record() -> dict:
    return {
        "patient_id": "",
        "patient_name": "",
        "file_name": "",
        "file": "",
        "group": "",
        "document_type": "",
        "report_date": "",
    }

# ========= Format Detectors =========
def _detect_and_extract(data) -> tuple[dict, str]:
    """Detect the incoming format and extract fields into internal format.
    Returns (record, format_name). Raises ValueError if format unknown or fields missing."""

    # 1. FHIR DocumentReference
    if isinstance(data, dict) and data.get("resourceType") == "DocumentReference":
        return _extract_fhir(data), "FHIR"

    # 2. HL7v2 (string starting with MSH|)
    if isinstance(data, str) and data.startswith("MSH|"):
        return _extract_hl7v2(data), "HL7v2"

    # 3. LIS/LIMS JSON — has "patient" object with "id"
    if isinstance(data, dict) and isinstance(data.get("patient"), dict) and data["patient"].get("id"):
        return _extract_lis_json(data), "LIS/LIMS"

    # 4. Imaging/EMS JSON — has "patient_id" at top level and "document" object
    if isinstance(data, dict) and data.get("patient_id") and isinstance(data.get("document"), dict):
        return _extract_imaging_json(data), "Imaging/EMS"

    # 5. Cloud Sentrics simple format — has "identifier"
    if isinstance(data, dict) and data.get("identifier"):
        return _extract_simple(data), "Simple"

    # 6. Fuzzy scan — last resort, scan entire payload for recognizable fields
    if isinstance(data, dict):
        rec = _extract_fuzzy(data)
        if rec["patient_id"] and rec["file"]:
            return rec, "Fuzzy"

    raise ValueError("Unrecognized payload format — could not find patient_id and file content")

def _extract_fhir(data: dict) -> dict:
    """Extract from FHIR DocumentReference."""
    rec = _empty_record()
    subject = data.get("subject") or {}
    ref = subject.get("reference") or ""
    rec["patient_id"] = ref.split("/")[-1] if "/" in ref else ref
    rec["patient_name"] = subject.get("display") or ""
    rec["document_type"] = (data.get("type") or {}).get("text") or ""
    rec["report_date"] = data.get("date") or ""

    content_list = data.get("content") or []
    if content_list:
        attachment = content_list[0].get("attachment") or {}
        rec["file_name"] = attachment.get("title") or ""
        rec["file"] = attachment.get("data") or ""

    return rec

def _extract_hl7v2(raw: str) -> dict:
    """Extract from HL7v2 message (pipe-delimited)."""
    rec = _empty_record()
    segments = raw.strip().split("\n")

    for seg in segments:
        fields = seg.split("|")
        seg_type = fields[0] if fields else ""

        if seg_type == "PID" and len(fields) > 5:
            rec["patient_id"] = fields[3].split("^")[0] if len(fields) > 3 else ""
            name_parts = fields[5].split("^") if len(fields) > 5 else []
            last = name_parts[0] if len(name_parts) > 0 else ""
            first = name_parts[1] if len(name_parts) > 1 else ""
            rec["patient_name"] = f"{first} {last}".strip()

        elif seg_type == "OBR" and len(fields) > 4:
            rec["document_type"] = fields[4] if len(fields) > 4 else ""

        elif seg_type == "OBX" and len(fields) > 5:
            rec["file"] = fields[5] if len(fields) > 5 else ""

    if not rec["file_name"] and rec["document_type"]:
        safe_type = _sanitize_path(rec["document_type"].lower().replace(" ", "_"))
        rec["file_name"] = f"{safe_type}_{_now().strftime('%Y%m%d')}.dat"
    elif not rec["file_name"]:
        rec["file_name"] = f"document_{_now().strftime('%Y%m%d')}.dat"

    rec["report_date"] = _now().isoformat()
    return rec

def _extract_lis_json(data: dict) -> dict:
    """Extract from LIS/LIMS JSON format."""
    rec = _empty_record()
    patient = data.get("patient") or {}
    rec["patient_id"] = patient.get("id") or ""
    rec["patient_name"] = patient.get("name") or ""

    result = data.get("result") or {}
    rec["file_name"] = result.get("file_name") or ""
    rec["file"] = result.get("file") or ""
    rec["document_type"] = result.get("report_type") or ""
    rec["report_date"] = data.get("date") or ""
    return rec

def _extract_imaging_json(data: dict) -> dict:
    """Extract from Imaging/EMS JSON format."""
    rec = _empty_record()
    rec["patient_id"] = data.get("patient_id") or ""
    rec["patient_name"] = data.get("patient_name") or ""

    doc = data.get("document") or {}
    rec["file_name"] = doc.get("file_name") or ""
    rec["file"] = doc.get("file") or ""

    study = data.get("study") or {}
    rec["document_type"] = study.get("type") or study.get("description") or ""
    rec["report_date"] = data.get("date") or ""
    return rec

def _extract_simple(data: dict) -> dict:
    """Extract from Cloud Sentrics simple format."""
    rec = _empty_record()
    rec["patient_id"] = data.get("identifier") or ""
    rec["patient_name"] = data.get("name") or ""
    rec["file_name"] = data.get("file_name") or ""
    rec["file"] = data.get("file") or ""
    rec["group"] = data.get("group") or ""
    rec["document_type"] = data.get("document_type") or ""
    rec["report_date"] = data.get("report_date") or ""
    return rec


# ========= Fuzzy Field Scanner =========
_ID_KEYS = {"patient_id", "patientid", "pat_id", "mrn", "medical_record_number",
            "sample_id", "specimen_id", "accession", "accession_number", "order_id",
            "reference", "subject_id", "incident_id", "run_number", "case_id",
            "identifier", "id", "record_id", "chart_number", "encounter_id"}

_NAME_KEYS = {"patient_name", "patientname", "pat_name", "name", "display",
              "full_name", "fullname", "subject_name", "client_name",
              "recipient_name", "person_name"}

_FILE_KEYS = {"file", "data", "content", "attachment", "base64",
              "payload", "document_data", "file_data", "file_content",
              "encoded_file", "report_data"}

_FILENAME_KEYS = {"file_name", "filename", "title", "document_name",
                  "report_name", "name", "file_title", "doc_name"}

_GROUP_KEYS = {"group", "family", "family_name", "household", "group_name",
               "family_id", "household_id"}

_DOCTYPE_KEYS = {"document_type", "doc_type", "type", "report_type",
                 "category", "test", "study_type", "description"}

_DATE_KEYS = {"date", "report_date", "created_date", "collected_date",
              "authored_on", "effective_date", "timestamp", "created_at"}

def _is_base64(value: str) -> bool:
    """Check if a string looks like base64 encoded content."""
    if not isinstance(value, str) or len(value) < 20:
        return False
    try:
        base64.b64decode(value, validate=True)
        return True
    except Exception:
        return False

def _walk_json(data, target_keys: set, base64_check: bool = False, _depth: int = 0) -> str:
    """Recursively walk JSON and find the first value matching any target key."""
    if _depth > 10 or not isinstance(data, (dict, list)):
        return ""

    if isinstance(data, dict):
        # Check current level first (prefer shallow matches)
        for k, v in data.items():
            if k.lower().replace(" ", "_") in target_keys:
                if isinstance(v, str) and v:
                    if base64_check and not _is_base64(v):
                        continue
                    return v
                elif isinstance(v, (int, float)):
                    return str(v)

        # Then recurse into nested objects
        for k, v in data.items():
            result = _walk_json(v, target_keys, base64_check, _depth + 1)
            if result:
                return result

    elif isinstance(data, list):
        for item in data:
            result = _walk_json(item, target_keys, base64_check, _depth + 1)
            if result:
                return result

    return ""

def _extract_fuzzy(data: dict) -> dict:
    """Fuzzy extraction — scan entire payload for recognizable field names."""
    rec = _empty_record()
    rec["patient_id"] = _walk_json(data, _ID_KEYS)
    rec["patient_name"] = _walk_json(data, _NAME_KEYS)
    rec["file"] = _walk_json(data, _FILE_KEYS, base64_check=True)
    rec["file_name"] = _walk_json(data, _FILENAME_KEYS)
    rec["group"] = _walk_json(data, _GROUP_KEYS)
    rec["document_type"] = _walk_json(data, _DOCTYPE_KEYS)
    rec["report_date"] = _walk_json(data, _DATE_KEYS)

    # Generate file_name if not found but we have a file
    if rec["file"] and not rec["file_name"]:
        doc_type = rec["document_type"] or "document"
        safe_type = re.sub(r'[^a-zA-Z0-9]', '_', doc_type.lower()).strip('_')
        rec["file_name"] = f"{safe_type}_{_now().strftime('%Y%m%d')}.dat"

    return rec

# ========= Main handler =========
def lambda_handler(event, context):
    # Extract API key
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    api_key = headers.get("x-api-key", "")

    if not api_key:
        return _resp(401, {"error": "Missing API key"})

    # Look up customer
    customer = _lookup_customer(api_key)
    if not customer:
        return _resp(403, {"error": "Invalid API key"})

    # Parse body
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(body).decode("utf-8")
        except Exception:
            return _resp(400, {"error": "Invalid request body"})

    # Try JSON first, fall back to raw string (for HL7v2)
    data = body
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        pass  # might be HL7v2 pipe-delimited text

    # Detect format and extract fields
    try:
        record, fmt = _detect_and_extract(data)
    except ValueError as e:
        return _resp(400, {"error": str(e)})

    print(f"Detected format: {fmt}")

    # Validate required fields
    if not record["patient_id"]:
        return _resp(400, {"error": f"Could not extract patient_id from {fmt} payload"})
    if not record["file_name"]:
        return _resp(400, {"error": f"Could not extract file_name from {fmt} payload"})
    if not record["file"]:
        return _resp(400, {"error": f"Could not extract file content from {fmt} payload"})

    # Decode file
    try:
        file_bytes = base64.b64decode(record["file"])
    except Exception:
        return _resp(400, {"error": "Invalid base64 file content"})

    # Build S3 path
    safe_id = _sanitize_path(record["patient_id"])
    if record["patient_name"]:
        safe_name = _sanitize_path(record["patient_name"].lower().replace(" ", "-"))
        folder = f"{safe_id}-{safe_name}"
    else:
        folder = safe_id

    safe_file = _sanitize_path(record["file_name"])
    group = record["group"]
    root = customer["root_folder"]

    if group:
        safe_group = _sanitize_path(group.lower().replace(" ", "-"))
        s3_key = f"{root}/{safe_group}/{folder}/{safe_file}"
    else:
        s3_key = f"{root}/{folder}/{safe_file}"

    # Upload to S3
    bucket = customer["bucket_name"]
    try:
        s3.put_object(
            Bucket=bucket,
            Key=s3_key,
            Body=file_bytes,
        )
    except Exception as e:
        print(f"S3 upload failed: {e}")
        return _resp(500, {"error": "Failed to store file"})

    print(f"File stored: s3://{bucket}/{s3_key} (customer={customer['customer_name']}, format={fmt})")

    return _resp(200, {
        "message": "File stored successfully",
        "format_detected": fmt,
        "bucket": bucket,
        "key": s3_key,
        "patient_id": record["patient_id"],
        "patient_name": record["patient_name"],
        "document_type": record["document_type"],
        "timestamp": _now().isoformat()
    })
