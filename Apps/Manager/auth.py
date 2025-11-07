from fastapi import HTTPException

def validate_bearer(auth_header: str | None, expected_token: str) -> None:
    """
    Validate an Authorization header of the form: 'Bearer <token>'.
    Raise HTTPException if missing/invalid.
    """
    if not expected_token:
        # If you forgot to set auth_token in Manager.ini, fail closed.
        raise HTTPException(status_code=500, detail="Server auth not configured")

    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")

    token = auth_header.split(" ", 1)[1].strip()
    if token != expected_token:
        raise HTTPException(status_code=403, detail="Invalid bearer token")
