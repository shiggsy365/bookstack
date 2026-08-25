"""Small shared SQLite cache, request coalescing, and provider metrics."""

import json
import os
import sqlite3
import threading
import time
import uuid

CACHE_PATH = os.environ.get('APP_CACHE_PATH', '/data/app-cache.sqlite3')
_LOCAL_LOCKS = {}
_LOCAL_LOCKS_GUARD = threading.Lock()
_INITIALIZED = False
_INIT_LOCK = threading.Lock()


def _connect():
    directory = os.path.dirname(CACHE_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    connection = sqlite3.connect(CACHE_PATH, timeout=10)
    connection.execute('PRAGMA busy_timeout=10000')
    return connection


def initialize_cache():
    global _INITIALIZED
    if _INITIALIZED:
        return
    with _INIT_LOCK:
        if _INITIALIZED:
            return
        with _connect() as connection:
            connection.execute('PRAGMA journal_mode=WAL')
            connection.execute(
                'CREATE TABLE IF NOT EXISTS app_cache '
                '(cache_key TEXT PRIMARY KEY, data TEXT NOT NULL, expires_at REAL NOT NULL, stale_at REAL NOT NULL)'
            )
            connection.execute(
                'CREATE TABLE IF NOT EXISTS cache_locks '
                '(cache_key TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at REAL NOT NULL)'
            )
            connection.execute(
                'CREATE TABLE IF NOT EXISTS provider_metrics '
                '(provider TEXT PRIMARY KEY, calls INTEGER NOT NULL DEFAULT 0, errors INTEGER NOT NULL DEFAULT 0, '
                'cache_hits INTEGER NOT NULL DEFAULT 0, cache_misses INTEGER NOT NULL DEFAULT 0, '
                'total_ms REAL NOT NULL DEFAULT 0, updated_at REAL NOT NULL)'
            )
        _INITIALIZED = True


def cache_get(cache_key, allow_stale=False):
    initialize_cache()
    now = time.time()
    try:
        with _connect() as connection:
            row = connection.execute(
                'SELECT data, expires_at, stale_at FROM app_cache WHERE cache_key = ?', (cache_key,)
            ).fetchone()
        if not row or (row[2] <= now) or (not allow_stale and row[1] <= now):
            return None
        return json.loads(row[0])
    except (OSError, sqlite3.Error, ValueError, TypeError):
        return None


def cache_set(cache_key, data, ttl, stale_ttl=None):
    initialize_cache()
    now = time.time()
    stale_ttl = stale_ttl if stale_ttl is not None else ttl
    with _connect() as connection:
        connection.execute(
            'INSERT OR REPLACE INTO app_cache (cache_key, data, expires_at, stale_at) VALUES (?, ?, ?, ?)',
            (cache_key, json.dumps(data, separators=(',', ':')), now + ttl, now + ttl + stale_ttl)
        )
        connection.execute('DELETE FROM app_cache WHERE stale_at <= ?', (now,))


def _metric(provider, calls=0, errors=0, hits=0, misses=0, elapsed_ms=0):
    initialize_cache()
    try:
        with _connect() as connection:
            connection.execute(
                'INSERT INTO provider_metrics '
                '(provider,calls,errors,cache_hits,cache_misses,total_ms,updated_at) VALUES (?,?,?,?,?,?,?) '
                'ON CONFLICT(provider) DO UPDATE SET calls=calls+excluded.calls, errors=errors+excluded.errors, '
                'cache_hits=cache_hits+excluded.cache_hits, cache_misses=cache_misses+excluded.cache_misses, '
                'total_ms=total_ms+excluded.total_ms, updated_at=excluded.updated_at',
                (provider, calls, errors, hits, misses, elapsed_ms, time.time())
            )
    except (OSError, sqlite3.Error):
        pass


def provider_metrics():
    initialize_cache()
    with _connect() as connection:
        rows = connection.execute(
            'SELECT provider,calls,errors,cache_hits,cache_misses,total_ms,updated_at FROM provider_metrics ORDER BY provider'
        ).fetchall()
    return [
        {'provider': row[0], 'calls': row[1], 'errors': row[2], 'cache_hits': row[3],
         'cache_misses': row[4], 'average_ms': round(row[5] / row[1], 1) if row[1] else 0,
         'updated_at': row[6]}
        for row in rows
    ]


def _local_lock(cache_key):
    with _LOCAL_LOCKS_GUARD:
        return _LOCAL_LOCKS.setdefault(cache_key, threading.Lock())


def _claim(cache_key, owner, lock_seconds):
    initialize_cache()
    now = time.time()
    with _connect() as connection:
        connection.execute('DELETE FROM cache_locks WHERE expires_at <= ?', (now,))
        cursor = connection.execute(
            'INSERT OR IGNORE INTO cache_locks (cache_key, owner, expires_at) VALUES (?, ?, ?)',
            (cache_key, owner, now + lock_seconds)
        )
        return cursor.rowcount == 1


def _release(cache_key, owner):
    try:
        with _connect() as connection:
            connection.execute('DELETE FROM cache_locks WHERE cache_key = ? AND owner = ?', (cache_key, owner))
    except (OSError, sqlite3.Error):
        pass


def cached_load(cache_key, provider, ttl, loader, stale_ttl=None, lock_seconds=130):
    if cache_get(f'error:{cache_key}') is not None:
        raise RuntimeError(f'{provider} is temporarily unavailable')
    data = cache_get(cache_key)
    if data is not None:
        _metric(provider, hits=1)
        return data
    _metric(provider, misses=1)

    with _local_lock(cache_key):
        data = cache_get(cache_key)
        if data is not None:
            _metric(provider, hits=1)
            return data
        stale = cache_get(cache_key, allow_stale=True)
        owner = f'{os.getpid()}-{threading.get_ident()}-{uuid.uuid4().hex}'
        if not _claim(cache_key, owner, lock_seconds):
            if stale is not None:
                _metric(provider, hits=1)
                return stale
            deadline = time.time() + min(lock_seconds, 120)
            while time.time() < deadline:
                time.sleep(0.1)
                data = cache_get(cache_key)
                if data is not None:
                    _metric(provider, hits=1)
                    return data
            if stale is not None:
                return stale

        started = time.monotonic()
        try:
            data = loader()
            resolved_ttl = ttl(data) if callable(ttl) else ttl
            resolved_stale_ttl = stale_ttl(data) if callable(stale_ttl) else stale_ttl
            cache_set(cache_key, data, resolved_ttl, resolved_stale_ttl)
            _metric(provider, calls=1, elapsed_ms=(time.monotonic() - started) * 1000)
            return data
        except Exception:
            _metric(provider, calls=1, errors=1, elapsed_ms=(time.monotonic() - started) * 1000)
            if stale is not None:
                return stale
            cache_set(f'error:{cache_key}', {'failed': True}, 60, 0)
            raise
        finally:
            _release(cache_key, owner)
