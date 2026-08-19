import json
import os
import re
import sqlite3
import time
from urllib.parse import urljoin

from .config import GOOGLE_BOOKS_API_KEY
from .discovery import (
    GOOGLE_BOOKS_BASE_URL, GOOGLE_BOOKS_ORIGINS, OPENLIBRARY_BASE_URL,
    OPENLIBRARY_ORIGINS, get_cached_json, openlibrary_headers
)
from .matching import normalize_title, title_words
from .providers import metadata_fields, normalize_google_book, normalize_openlibrary_book

METADATA_CACHE_SECONDS = 30 * 24 * 60 * 60
EMPTY_METADATA_CACHE_SECONDS = 6 * 60 * 60
METADATA_CACHE_PATH = os.environ.get('METADATA_CACHE_PATH', '/data/metadata-cache.sqlite3')
METADATA_CACHE = {}


def initialize_metadata_cache():
    directory = os.path.dirname(METADATA_CACHE_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with sqlite3.connect(METADATA_CACHE_PATH, timeout=10) as connection:
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute(
            'CREATE TABLE IF NOT EXISTS metadata_cache '
            '(cache_key TEXT PRIMARY KEY, data TEXT NOT NULL, expires_at REAL NOT NULL)'
        )


def persistent_cache_get(cache_key, now):
    try:
        initialize_metadata_cache()
        with sqlite3.connect(METADATA_CACHE_PATH, timeout=10) as connection:
            row = connection.execute(
                'SELECT data, expires_at FROM metadata_cache WHERE cache_key = ?', (cache_key,)
            ).fetchone()
            if not row:
                return None
            if row[1] <= now:
                connection.execute('DELETE FROM metadata_cache WHERE cache_key = ?', (cache_key,))
                return None
            return {'data': json.loads(row[0]), 'expires_at': row[1]}
    except (OSError, sqlite3.Error, ValueError) as e:
        print(f'[Metadata] Persistent cache read failed: {e}', flush=True)
        return None


def persistent_cache_set(cache_key, data, expires_at):
    try:
        initialize_metadata_cache()
        with sqlite3.connect(METADATA_CACHE_PATH, timeout=10) as connection:
            connection.execute(
                'INSERT OR REPLACE INTO metadata_cache (cache_key, data, expires_at) VALUES (?, ?, ?)',
                (cache_key, json.dumps(data), expires_at)
            )
            connection.execute('DELETE FROM metadata_cache WHERE expires_at <= ?', (time.time(),))
    except (OSError, sqlite3.Error, TypeError, ValueError) as e:
        print(f'[Metadata] Persistent cache write failed: {e}', flush=True)


def metadata_match_score(query_title, result_title):
    query, result = normalize_title(query_title), normalize_title(result_title)
    if not query or not result:
        return 0
    if query == result:
        return 100
    if query in result or result in query:
        return 80
    query_words, result_words = title_words(query), title_words(result)
    return int((len(query_words & result_words) / max(len(query_words), len(result_words))) * 100)


def clean_isbn(isbn):
    return re.sub(r'[^0-9Xx]', '', isbn or '')


def google_books_metadata(title, author='', isbn=''):
    terms = [f'isbn:{clean_isbn(isbn)}'] if clean_isbn(isbn) else [f'intitle:{title}']
    if author:
        terms.append(f'inauthor:{author}')
    params = {'q': ' '.join(terms), 'maxResults': 5, 'printType': 'books'}
    if GOOGLE_BOOKS_API_KEY:
        params['key'] = GOOGLE_BOOKS_API_KEY
    data = get_cached_json(
        f'googlebooks:metadata:{params["q"]}', urljoin(GOOGLE_BOOKS_BASE_URL, '/books/v1/volumes'),
        GOOGLE_BOOKS_ORIGINS, headers={'User-Agent': 'Bookstack Kindle Browser'},
        params=params, cache_seconds=METADATA_CACHE_SECONDS
    )
    best, best_score = {}, 0
    for item in data.get('items', []):
        normalized = normalize_google_book(item)
        score = metadata_match_score(title, normalized['title'])
        if score > best_score:
            best = metadata_fields(normalized)
            best_score = score
    return best if best_score >= 70 else {}


def openlibrary_metadata(title, author='', isbn=''):
    query = f'isbn:{clean_isbn(isbn)}' if clean_isbn(isbn) else f'title:"{title}"'
    if author:
        query += f' author:"{author}"'
    data = get_cached_json(
        f'openlibrary:metadata:{query}', urljoin(OPENLIBRARY_BASE_URL, '/search.json'),
        OPENLIBRARY_ORIGINS, headers=openlibrary_headers(),
        params={'q': query, 'fields': 'title,author_name,isbn,cover_i,first_publish_year', 'limit': 5},
        cache_seconds=METADATA_CACHE_SECONDS
    )
    best, best_score = {}, 0
    for item in data.get('docs', []):
        normalized = normalize_openlibrary_book(item)
        score = metadata_match_score(title, normalized['title'])
        if score > best_score:
            best = metadata_fields(normalized)
            best_score = score
    return best if best_score >= 70 else {}


def resolve_metadata(title, author='', isbn=''):
    cache_parts = (normalize_title(title), normalize_title(author), clean_isbn(isbn))
    cache_key = json.dumps(cache_parts, separators=(',', ':'))
    now = time.time()
    cached = METADATA_CACHE.get(cache_key)
    if cached and cached['expires_at'] > now:
        return cached['data']
    persistent_cached = persistent_cache_get(cache_key, now)
    if persistent_cached is not None:
        METADATA_CACHE[cache_key] = persistent_cached
        return persistent_cached['data']
    metadata = {}
    try:
        metadata = google_books_metadata(title, author, isbn)
        if not metadata and author:
            metadata = google_books_metadata(title, '', isbn)
    except Exception as e:
        print(f'[Metadata] Google Books lookup failed: {e}', flush=True)
    if not metadata.get('cover_url'):
        try:
            fallback = openlibrary_metadata(title, author, isbn)
            if not fallback and author:
                fallback = openlibrary_metadata(title, '', isbn)
            if fallback:
                fallback.update({key: value for key, value in metadata.items() if value})
                metadata = fallback
        except Exception as e:
            print(f'[Metadata] Open Library lookup failed: {e}', flush=True)
    cache_seconds = METADATA_CACHE_SECONDS if metadata else EMPTY_METADATA_CACHE_SECONDS
    expires_at = now + cache_seconds
    METADATA_CACHE[cache_key] = {'data': metadata, 'expires_at': expires_at}
    persistent_cache_set(cache_key, metadata, expires_at)
    return metadata
