import asyncio
import logging
from contextlib import suppress
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile, status

from . import auth, storage, config

logger = logging.getLogger("manager.server")

app = FastAPI()
_gc_task: asyncio.Task | None = None
_ALLOWED_EXTS = {".mkv"}


@app.on_event("startup")
async def _startup():
    global _gc_task
    recordings_root = storage.recordings_root()
    cfg = config.get_cfg()
    logger.info(
        "Manager starting on %s:%s; recordings stored under %s",
        cfg.bind_host,
        cfg.bind_port,
        recordings_root,
    )

    async def _gc_loop():
        while True:
            try:
                current_cfg = config.get_cfg()
                deleted = storage.rotate_by_age(recordings_root, current_cfg.retention)
                if deleted:
                    logger.info("GC removed %s expired recording(s)", deleted)
            except Exception:
                logger.exception("GC sweep failed")
            current_cfg = config.get_cfg()
            await asyncio.sleep(
                max(current_cfg.gc_interval.total_seconds(), 1)
            )

    _gc_task = asyncio.create_task(_gc_loop())


@app.on_event("shutdown")
async def _shutdown():
    global _gc_task
    logger.info("Manager shutting down")
    if _gc_task and not _gc_task.done():
        _gc_task.cancel()
        with suppress(asyncio.CancelledError):
            await _gc_task
    _gc_task = None


@app.post("/upload")
async def upload(
    file: UploadFile = File(...),
    systemName: str = Form(...),
    recordingUser: str = Form(...),
    authorization: str | None = Header(None),
):
    cfg = config.get_cfg()
    auth.validate_bearer(authorization, cfg.auth_token)

    ext = Path(file.filename).suffix.lower()
    if ext not in _ALLOWED_EXTS:
        logger.warning(
            "Rejected upload with unsupported extension '%s' from system=%s user=%s",
            ext,
            systemName,
            recordingUser,
        )
        allowed = ", ".join(sorted(_ALLOWED_EXTS))
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=f"Only {allowed} files are accepted",
        )

    saved = storage.save_upload_to_share(
        upload_filename=file.filename,
        computer_name=systemName,
        user_session=recordingUser,
        data_stream=file.file,
    )
    logger.info(
        "Stored upload from system=%s user=%s at %s",
        systemName,
        recordingUser,
        saved,
        extra={"skip_file": True},
    )

    return {"ok": True, "saved_to": str(saved)}


@app.post("/admin/gc")
async def admin_gc(authorization: str | None = Header(None)):
    cfg = config.get_cfg()
    auth.validate_bearer(authorization, cfg.auth_token)
    root = storage.recordings_root()
    deleted = storage.rotate_by_age(root, cfg.retention)
    if deleted:
        logger.info("Manual GC removed %s expired recording(s)", deleted)
    return {"ok": True, "deleted": deleted}
