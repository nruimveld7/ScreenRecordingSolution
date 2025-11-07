from __future__ import annotations

import configparser
import logging
import sys
import threading
import time
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Callable, List, Optional

_LOGGER = logging.getLogger("manager.config")


def _find_manager_ini() -> Path:
    """
    Search order:
      1) Next to the running binary/module.
      2) ../../Configs/Manager.ini when running from source.
    """
    if getattr(sys, "frozen", False):
        base_dir = Path(sys.executable).resolve().parent
    else:
        base_dir = Path(__file__).resolve().parent

    local_ini = base_dir / "Manager.ini"
    if local_ini.exists():
        return local_ini

    dev_root = Path(__file__).resolve().parents[2]
    dev_ini = dev_root / "Configs" / "Manager.ini"
    if dev_ini.exists():
        return dev_ini

    raise FileNotFoundError(
        "Manager.ini not found.\n"
        f"Checked:\n"
        f"  - {local_ini}\n"
        f"  - {dev_ini}\n"
        "Place Manager.ini next to the EXE for production, "
        "or at repo-root/Configs/ for development."
    )


def _parse_duration(raw: str) -> timedelta:
    s = raw.strip().lower()
    if s.endswith("ms"):
        return timedelta(milliseconds=int(s[:-2]))
    if s.endswith("s"):
        return timedelta(seconds=int(s[:-1]))
    if s.endswith("m"):
        return timedelta(minutes=int(s[:-1]))
    if s.endswith("h"):
        return timedelta(hours=int(s[:-1]))
    if s.endswith("d"):
        return timedelta(days=int(s[:-1]))
    return timedelta(seconds=int(s))


@dataclass(frozen=True)
class Cfg:
    bind_host: str
    bind_port: int
    auth_token: str
    gc_interval: timedelta
    retention: timedelta
    source_path: Path


class ConfigManager:
    def __init__(self, poll_interval: float = 1.0) -> None:
        self._poll_interval = poll_interval
        self._config_path = _find_manager_ini()
        self._lock = threading.RLock()
        self._cfg = self._load()
        self._mtime = self._config_path.stat().st_mtime
        self._callbacks: List[Callable[[Cfg, bool], None]] = []
        self._stop_event = threading.Event()
        self._watch_thread = threading.Thread(
            target=self._watch_loop,
            name="ManagerConfigWatcher",
            daemon=True,
        )
        self._watch_thread.start()

    def _load(self) -> Cfg:
        parser = configparser.ConfigParser()
        parser.read(self._config_path, encoding="utf-8")
        sect = parser["manager"]

        bind_host = sect.get("bind_host", "127.0.0.1").strip() or "127.0.0.1"
        bind_port = sect.getint("bind_port", fallback=8080)
        auth_token = sect.get("auth_token", "").strip()
        if not auth_token:
            raise ValueError(f"[manager].auth_token must be set in {self._config_path}")
        gc_interval = _parse_duration(sect.get("gc_interval", "1h"))
        retention = _parse_duration(sect.get("retention", "24h"))

        return Cfg(
            bind_host=bind_host,
            bind_port=bind_port,
            auth_token=auth_token,
            gc_interval=gc_interval,
            retention=retention,
            source_path=self._config_path,
        )

    def get_cfg(self) -> Cfg:
        with self._lock:
            return self._cfg

    def add_listener(self, callback: Callable[[Cfg, bool], None]) -> Callable[[], None]:
        with self._lock:
            self._callbacks.append(callback)

        def _remove() -> None:
            with self._lock:
                if callback in self._callbacks:
                    self._callbacks.remove(callback)

        return _remove

    def stop(self) -> None:
        self._stop_event.set()
        self._watch_thread.join(timeout=2)

    def _watch_loop(self) -> None:
        while not self._stop_event.wait(self._poll_interval):
            try:
                mtime = self._config_path.stat().st_mtime
            except FileNotFoundError:
                continue

            if mtime == self._mtime:
                continue

            try:
                new_cfg = self._load()
            except Exception:
                _LOGGER.exception("Failed to reload Manager.ini; keeping previous configuration.")
                self._mtime = mtime
                continue

            with self._lock:
                old_cfg = self._cfg
                self._cfg = new_cfg
                self._mtime = mtime
                callbacks_snapshot = list(self._callbacks)

            requires_restart = (
                new_cfg.bind_host != old_cfg.bind_host
                or new_cfg.bind_port != old_cfg.bind_port
            )

            _LOGGER.info(
                "Reloaded Manager.ini (%s); restart required=%s",
                self._config_path,
                requires_restart,
            )

            for cb in callbacks_snapshot:
                try:
                    cb(new_cfg, requires_restart)
                except Exception:
                    _LOGGER.exception("Config change listener raised an exception.")


_manager = ConfigManager()


def get_cfg() -> Cfg:
    return _manager.get_cfg()


def add_listener(callback: Callable[[Cfg, bool], None]) -> Callable[[], None]:
    return _manager.add_listener(callback)


def stop_watcher() -> None:
    _manager.stop()

