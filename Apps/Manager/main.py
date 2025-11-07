# Launches FastAPI using values from Configs/Manager.ini (no CLI flags needed)
from __future__ import annotations

import asyncio
import datetime
import logging
import logging.config
import sys
import threading
import traceback
from pathlib import Path
from typing import Any, Dict, Optional

try:
    import servicemanager  # type: ignore
    import win32service  # type: ignore
    import win32serviceutil  # type: ignore
except ImportError:  # pragma: no cover - pywin32 not installed
    servicemanager = None
    win32service = None
    win32serviceutil = None

if __package__ is None:  # running as a script: ensure Apps/ is on sys.path
    sys.path.append(str(Path(__file__).resolve().parents[1]))

import uvicorn
from Manager import config
from Manager import logging_utils as _logging_utils  # noqa: F401
from Manager.server import app as manager_app

_LOGGER = logging.getLogger("manager.service")
_RUN_MODE: str = "unknown"


class SkipSuccessfulUploads(logging.Filter):
    """Filter out records explicitly marked as console-only."""

    def filter(self, record: logging.LogRecord) -> bool:
        return not getattr(record, "skip_file", False)


class DropAccess200(logging.Filter):
    """Suppress uvicorn access logs ending with HTTP 200 from file output."""

    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        if record.name == "uvicorn.access" and msg.rstrip().endswith(" 200"):
            return False
        return True


class DropServiceConsoleHint(logging.Filter):
    """Hide uvicorn's CTRL+C hint when running as a Windows service."""

    def filter(self, record: logging.LogRecord) -> bool:
        if _RUN_MODE == "service" and "Press CTRL+C to quit" in record.getMessage():
            return False
        return True


def _is_frozen() -> bool:
    return getattr(sys, "frozen", False)


def _base_dir() -> Path:
    if _is_frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def _should_log_to_console() -> bool:
    return not _is_frozen() and sys.stderr.isatty()


def _build_log_config() -> Dict[str, Any]:
    logs_dir = _base_dir() / "Logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    formatter_standard = "%(asctime)s %(levelname)s %(name)s: %(message)s"

    handlers: Dict[str, Any] = {
        "file": {
            "class": "Manager.logging_utils.DailyFileHandler",
            "formatter": "standard",
            "directory": str(logs_dir),
            "retention_days": 14,
            "encoding": "utf-8",
            "level": "INFO",
            "filters": ["skip_success", "drop_200", "drop_ctrl_c"],
        }
    }

    handler_names = ["file"]

    if _should_log_to_console():
        handlers["console"] = {
            "class": "logging.StreamHandler",
            "formatter": "standard",
            "stream": "ext://sys.stderr",
            "level": "INFO",
            "filters": ["drop_ctrl_c"],
        }
        handler_names.append("console")

    loggers = {
        "": {"handlers": handler_names, "level": "INFO"},
        "uvicorn": {"handlers": handler_names, "level": "INFO", "propagate": False},
        "uvicorn.error": {
            "handlers": handler_names,
            "level": "INFO",
            "propagate": False,
        },
        "uvicorn.access": {
            "handlers": handler_names,
            "level": "WARNING",
            "propagate": False,
        },
        "manager": {"handlers": handler_names, "level": "INFO", "propagate": False},
    }

    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "standard": {"format": formatter_standard},
        },
        "handlers": handlers,
        "filters": {
            "skip_success": {"()": SkipSuccessfulUploads},
            "drop_200": {"()": DropAccess200},
            "drop_ctrl_c": {"()": DropServiceConsoleHint},
        },
        "loggers": loggers,
    }


def _build_server(current_cfg: Optional[config.Cfg] = None) -> uvicorn.Server:
    log_config = _build_log_config()
    logging.config.dictConfig(log_config)
    cfg_obj = current_cfg or config.get_cfg()
    uv_config = uvicorn.Config(
        manager_app,
        host=cfg_obj.bind_host,
        port=cfg_obj.bind_port,
        log_config=log_config,
        log_level="info",
        loop="asyncio",
        lifespan="on",
    )
    return uvicorn.Server(uv_config)


def run_server() -> None:
    global _RUN_MODE
    if _RUN_MODE == "unknown":
        _RUN_MODE = "console"

    while True:
        cfg_obj = config.get_cfg()
        restart_needed = threading.Event()
        server_holder: Dict[str, Optional[uvicorn.Server]] = {"server": None}

        def _on_config_change(new_cfg: config.Cfg, requires_restart: bool) -> None:
            if requires_restart:
                _LOGGER.info(
                    "Manager.ini updated (bind host/port changed). Scheduling server restart."
                )
                restart_needed.set()
                server = server_holder["server"]
                if server:
                    server.should_exit = True
            else:
                _LOGGER.info(
                    "Manager.ini reloaded; new settings applied without restart."
                )

        unsubscribe = config.add_listener(_on_config_change)
        server = _build_server(cfg_obj)
        server_holder["server"] = server
        try:
            server.run()
        except KeyboardInterrupt:
            _LOGGER.info("SRS Manager stopped via keyboard interrupt.")
            restart_needed.clear()
        except asyncio.CancelledError:
            _LOGGER.info("SRS Manager event loop cancelled during shutdown.")
        finally:
            server_holder["server"] = None
            unsubscribe()

        if restart_needed.is_set():
            _LOGGER.info("Restarting SRS Manager to apply new bind settings.")
            continue
        break


def _service_capable() -> bool:
    return win32serviceutil is not None


if _service_capable():

    class SRSManagerService(win32serviceutil.ServiceFramework):  # type: ignore[misc]
        _svc_name_ = "SRSManager"
        _svc_display_name_ = "SRS Manager"
        _svc_description_ = (
            "Receives and stores screen recordings from remote recorder agents."
        )

        def __init__(self, args):
            super().__init__(args)
            self.server: Optional[uvicorn.Server] = None

        def SvcStop(self) -> None:
            self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)  # type: ignore[attr-defined]
            if self.server is not None:
                self.server.should_exit = True

        def SvcDoRun(self) -> None:
            if servicemanager:
                servicemanager.LogInfoMsg("SRS Manager service starting")  # type: ignore[attr-defined]
            try:
                global _RUN_MODE
                _RUN_MODE = "service"
                first_iteration = True
                while True:
                    cfg_obj = config.get_cfg()
                    restart_flag = {"value": False}

                    def _on_change(new_cfg: config.Cfg, requires_restart: bool) -> None:
                        if requires_restart:
                            restart_flag["value"] = True
                            if self.server:
                                self.server.should_exit = True

                    unsubscribe = config.add_listener(_on_change)
                    self.server = _build_server(cfg_obj)
                    if first_iteration:
                        self.ReportServiceStatus(win32service.SERVICE_RUNNING)  # type: ignore[attr-defined]
                        first_iteration = False
                    try:
                        self.server.run()
                    except KeyboardInterrupt:
                        _LOGGER.info(
                            "SRS Manager service stopped via keyboard interrupt."
                        )
                        restart_flag["value"] = False
                    except asyncio.CancelledError:
                        _LOGGER.info(
                            "SRS Manager service loop cancelled during shutdown."
                        )
                    finally:
                        unsubscribe()
                        self.server = None

                    if not restart_flag["value"]:
                        break
                    _LOGGER.info(
                        "Restarting service host to apply updated bind settings."
                    )
            except (
                Exception
            ):  # pragma: no cover - service errors should surface in logs
                message = "SRS Manager service encountered an unexpected error:"
                if servicemanager:
                    servicemanager.LogErrorMsg(f"{message}\n{traceback.format_exc()}")  # type: ignore[attr-defined]
                _LOGGER.exception(message)
                raise
            finally:
                self.ReportServiceStatus(win32service.SERVICE_STOPPED)  # type: ignore[attr-defined]


def main() -> None:
    global _RUN_MODE
    if len(sys.argv) > 1:
        cmd = sys.argv[1].lower()
        if cmd == "--console":
            sys.argv.pop(1)
            run_server()
            return
        if cmd == "--service":
            sys.argv.pop(1)
            if not _service_capable():
                raise RuntimeError(
                    "pywin32 is required to run SRS Manager as a service."
                )
            _RUN_MODE = "service"
            servicemanager.Initialize()  # type: ignore[attr-defined]
            servicemanager.PrepareToHostSingle(SRSManagerService)  # type: ignore[attr-defined]
            servicemanager.StartServiceCtrlDispatcher()  # type: ignore[attr-defined]
            return
        if not _service_capable():
            raise RuntimeError(
                "pywin32 is required to manage the SRS Manager Windows service."
            )
        win32serviceutil.HandleCommandLine(SRSManagerService)  # type: ignore[arg-type]
        return

    # Default to console mode when no arguments are supplied
    run_server()


if __name__ == "__main__":
    main()
